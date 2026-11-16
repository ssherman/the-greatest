# Discover Books Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `discover_books` (`GET /api/v1/discover/books`) and `list_languages`
(`GET /api/v1/languages`) to the public REST API and MCP. `discover_books` is a filtered book search,
in rank or seeded random order.

**Architecture:** Both endpoints sit on the existing saved-search engine:
- `Books::SavedSearchCriteria` → `Search::Books::Search::BookAdvanced` (+ `CriteriaClauses`) →
  `Books::SavedSearchQuery`.
- The engine gains a `min_ranked_position` criterion, an `order`/`seed` random sort, and an
  opt-in exact total.
- A new translator, `Api::DiscoverBookFilters`, turns API params into a criteria hash.
- MCP tools are generated from the `x-mcp` blocks in `config/api/v1/openapi.yaml`.

**Tech Stack:** Rails 8, OpenSearch, Alba resources, Minitest + Mocha, `mcp` gem catalogue built
from OpenAPI.

**Spec:** `docs/superpowers/specs/2026-11-15-discover-books-design.md`

## Global Constraints

**Commands and style**
- Run Rails commands from `web-app/`; docs live in `docs/` at the repo root.
- Lint with `bundle exec standardrb`. Never run brakeman.
- Inside `Api::V1::Books`, root-anchor every model reference (`::Books::…`, `::Search::…`).
- Controller tests assert behaviour (status, keys, ids, links), never copy.
- Minitest 6: use `assert_nil`, never `assert_equal nil`.

**Engine behaviour**
- A filter that is sent but can't be resolved never widens the result.
  - An unknown slug is `Api::UnknownFilter` (404 problem, as `list_books`).
  - A malformed value is `Api::Page::InvalidParameter` (400).
- Saved searches must not change behaviour. Every new engine argument defaults to today's behaviour:
  - `order: :rank`
  - `seed: nil`
  - `track_total_hits: false`
- Ranks and rank filters are the default primary ranking's only (`ranked_position` in the index).

**Parameter limits**

| Parameter | Limit |
|---|---|
| `category_id`, `exclude_category_id` | 6 slugs each (`Books::FilterParams::MAX_CATEGORIES`) |
| `country_id`, `exclude_country_id` | 10 each (`MAX_COUNTRIES`) |
| `language`, `exclude_language` | 10 each |
| `length` | the 6 enum names `very_short short medium moderate long very_long` |
| `seed` | integer 1..2_147_483_647 |
| `per_page` | 1..100, default 50 |

**Window:** 10,000 results (`BookAdvanced::MAX_RESULT_WINDOW`).
- Last reachable page = `(10_000.0 / per_page).ceil`.
- A higher `page` is a 400.

**Defaults**
- `category_match`: `all`.
- `ranked`: `all`.
- `order`: `rank`.

## Review Focus

1. **Paging one random shuffle.** Following `links.next` with the same seed must return every
   matching book exactly once. Test in Task 1 (engine) and Task 3 (links carry the seed).
2. **Merged or renamed category slugs.**
   - A merged slug in `exclude_category_id` must still exclude the target's books.
   - An include and an exclude that resolve to the same category must be a 400.

   Tests in Task 2.
3. **Rank bounds exclude unranked books.** `rank_min` alone must exclude unranked books (no
   `ranked_position`), not just `rank_max`. Test in Task 1.
4. **`hide_read` for a token whose user has no read list** returns 200 and the unchanged result.
   Test in Task 3.
5. **`per_page` that doesn't divide 10,000.**
   - For `per_page=30`, `total_pages` is 334, page 334 returns a short page, and page 335 is a 400.
   - `links.next` on page 334 is null.

   Test in Task 3.

---

### Task 1: Engine — rank floor, random order, exact totals

**Files:**
- Modify: `web-app/app/lib/books/saved_search_criteria.rb` (add `min_ranked_position`, include it in
  `UNPARSEABLE_KEYS`)
- Modify: `web-app/app/lib/search/books/search/criteria_clauses.rb` (`filter_clauses`)
- Modify: `web-app/app/lib/search/books/search/book_advanced.rb` (`call`, `build_query_definition`)
- Modify: `web-app/app/lib/books/saved_search_query.rb` (`call` passes the three new kwargs through)
- Test: `web-app/test/lib/books/saved_search_criteria_test.rb`,
  `web-app/test/lib/search/books/search/criteria_clauses_test.rb`,
  `web-app/test/lib/search/books/search/book_advanced_test.rb` (real OpenSearch, use its
  `index_book` helper), `web-app/test/lib/books/saved_search_query_test.rb`

**Interfaces:**
- Produces:
  - `SavedSearchCriteria#min_ranked_position -> Integer | nil`, read from the raw key
    `"min_ranked_position"`.
  - `BookAdvanced.call(criteria, page: 1, per_page: 50, excluded_book_ids: [], order: :rank, seed: nil, track_total_hits: false) -> {ids:, total:, total_relation:}`.
  - `BookAdvanced.build_query_definition(criteria, page:, per_page:, excluded_book_ids:, order:, seed:, track_total_hits:)`.
  - `Books::SavedSearchQuery.call(criteria:, owner:, ranking_configuration: nil, page: 1, per_page: 50, order: :rank, seed: nil, track_total_hits: false)`.
  - `order` is `:rank` or `:random`. Any other value is an `ArgumentError`, and so is `:random`
    with a nil seed.

- [ ] **Step 1: Write failing tests**
  - **Criteria:**
    - `min_ranked_position` reads `"5"` and `5` as 5.
    - `unparseable?("min_ranked_position")` is true for `"abc"`.
  - **CriteriaClauses:**
    - `{"min_ranked_position" => 5, "max_ranked_position" => 20}` produces
      `{range: {ranked_position: {gte: 5}}}` and `{range: {ranked_position: {lte: 20}}}`.
    - `min_ranked_position` alone produces only the `gte` clause.
  - **BookAdvanced** (real index):
    - `test "min_ranked_position excludes unranked books and ranks below the floor"`: index ids
      1–4 with `ranked_position` 1, 5, 10, nil. Then
      `ids_for({"min_ranked_position" => 5}) == [2, 3]`.
    - `test "random order with the same seed is stable and differs from rank order"`: index 12
      books with `ranked_position` 1..12.
      - Two calls with `order: :random, seed: 42` return equal ids.
      - That order is not `(1..12).to_a`.
      - `seed: 7` gives a different order from `seed: 42`.
    - `test "random pages with one seed cover every match exactly once"`: index 7 books. Pages
      1–3 at `per_page: 3`, `order: :random, seed: 9`, concatenate to 7 unique ids that equal
      the set of indexed ids.
    - `test "track_total_hits reports an exact total past 10,000"`: assert on
      `build_query_definition` only. With `track_total_hits: true` the definition has
      `track_total_hits: true`; without it, the key is absent.
    - `test "random order wraps the bool query in function_score"`: the definition's `query` is
      `{function_score: {query: <the bool query>, random_score: {seed: 42, field: "_seq_no"}, boost_mode: "replace"}}`
      and `sort` is `[{_score: {order: "desc"}}, {_id: {order: "asc"}}]`.
    - `test "random order without a seed raises ArgumentError"`.
  - **SavedSearchQuery** (stubbed `BookAdvanced.call`): it forwards
    `order: :random, seed: 3, track_total_hits: true` to `BookAdvanced.call`.

- [ ] **Step 2: Run them; expect failures.** From `web-app/`, run
  `bin/rails test test/lib/books/saved_search_criteria_test.rb test/lib/search/books/search/criteria_clauses_test.rb test/lib/search/books/search/book_advanced_test.rb test/lib/books/saved_search_query_test.rb`.
  Expected: FAIL on the new tests (`NoMethodError` / `ArgumentError: unknown keyword`).
- [ ] **Step 3: Implement.**
  - Keep `SORT` for `:rank`.
  - For `:random`, set `query` to the `function_score` above and `sort` to `[_score desc, _id asc]`.
  - Add `track_total_hits: true` to the definition only when asked.
  - Leave the class comments on the existing behaviour intact, and add one line each for the new
    options.
- [ ] **Step 4: Run the same command, then `bin/rails test test/lib/search test/lib/books test/controllers/books`; expect PASS.**
- [ ] **Step 5: Commit**
  `git commit -m "Search engine: rank floor, seeded random order, opt-in exact totals"`

### Task 2: `Api::DiscoverBookFilters` — API params to criteria

**Files:**
- Create: `web-app/app/lib/api/discover_book_filters.rb`
- Test: `web-app/test/lib/api/discover_book_filters_test.rb`

**Interfaces:**
- Consumes:
  - `Books::FilterParams.call(category_id:, country_id:, year:, published_start:, published_end:)`;
  - its `InvalidFilter` and `UnknownFilter` (each carries `#param`, and `UnknownFilter` also
    `#slug`);
  - `Api::UnknownFilter.new(param, slug)`;
  - `Api::Page::InvalidParameter`;
  - `Api::Page.integer(raw, name:, default:, min:, max:)`.
- Produces:
  - `Api::DiscoverBookFilters.call(params) -> Result` with
    `Result = Struct.new(:criteria, :order, :seed, :applied, keyword_init: true)`:
    - `criteria`: a String-keyed Hash that `Books::SavedSearchCriteria.new` reads;
    - `order`: `:rank` or `:random`;
    - `seed`: an Integer when `order == :random`. It's the sent seed, or
      `SecureRandom.random_number(2_147_483_647) + 1`.
    - `applied`: a Symbol-keyed Hash.
  - `applied` carries only the parameters that were sent, in canonical form:
    - slugs sorted and comma-joined;
    - `length` in enum order;
    - years as Integers;
    - `rank_min` / `rank_max` as Integers;
    - `hide_read: true` when sent true.

    It never contains `order` or `seed`.

**Mapping to the criteria hash.** Every key is a String, and the `ranked` and `genre_match_mode`
keys are always written.

| Criteria key | Comes from |
|---|---|
| `included_category_ids` / `excluded_category_ids` | category ids; excludes resolved through a second `FilterParams.call(category_id: params[:exclude_category_id])` |
| `included_country_ids` / `excluded_country_ids` | country ids; excludes the same way, through `country_id:` |
| `genre_match_mode` | `"all"` / `"any"` |
| `included_language_ids` / `excluded_language_ids` | `Language.where(slug:)` |
| `book_length` | the enum integers from `Books::Book.book_lengths` |
| `first_year_published_gt` / `first_year_published_lt` | FilterParams' `year_start` / `year_end` (inclusive bounds) |
| `ranked` | `"true"` for ranked; `"false"` for unranked; absent for all |
| `min_ranked_position` / `max_ranked_position` | `rank_min` / `rank_max` |
| `hide_read` | `"true"` or `"false"` |

Either rank bound sets `ranked: "true"`.

**Error mapping.** An error from the exclusion `FilterParams` calls must be re-raised with the API
param name (`exclude_category_id` / `exclude_country_id`), not `category_id` / `country_id`.

- [ ] **Step 1: Write failing tests** (fixtures: check `test/fixtures/categories.yml`,
  `books/countries.yml`, `languages.yml` for real names before use). One test per line:
  - The full happy path. Every parameter sent produces the exact criteria hash and `applied`.
  - No parameters gives `{"genre_match_mode" => "all", "hide_read" => "false"}` (and no
    `ranked`), `order == :rank`, `seed` nil and `applied` empty.
  - `order=random` without a seed: `seed` is between 1 and 2_147_483_647.
  - `order=random&seed=42`: `seed == 42`.
  - Each of these raises `Api::Page::InvalidParameter`:
    - blank `language`;
    - `language[]=x`;
    - 11 language slugs;
    - `length=huge`;
    - `ranked=maybe`;
    - `order=popular`;
    - `category_match=any` without `category_id`;
    - `year=1900&published_start=1800`;
    - `rank_min=10&rank_max=5`;
    - `rank_min=0`;
    - `rank_max=5&ranked=unranked`;
    - `seed=5` without `order=random`;
    - `order=random&seed=0`;
    - `hide_read=yes`;
    - `country_id=russia&exclude_country_id=russia`.
  - The exception message names the parameter in each of those cases.
  - Unknown slugs raise `Api::UnknownFilter` whose `param` is the API's own name:
    - `language=klingon` → `language`;
    - `exclude_category_id=nope` → `exclude_category_id`;
    - `exclude_country_id=nope` → `exclude_country_id`.
  - Review Focus 2:
    - A merged category's old slug in `exclude_category_id` puts the merge target's id in
      `excluded_category_ids`.
    - An include of the target together with an exclude of the merged slug is a 400.
- [ ] **Step 2: Run** `bin/rails test test/lib/api/discover_book_filters_test.rb`. Expected:
  FAIL (`NameError: uninitialized constant Api::DiscoverBookFilters`).
- [ ] **Step 3: Implement** `Api::DiscoverBookFilters`.
  - Copy `Api::RankedBookFilters`' single-value and blank checks.
  - Detect an include/exclude overlap on resolved ids, after merge resolution.
- [ ] **Step 4: Run it again; expect PASS.** Also run `bin/rails test test/lib/api/ranked_book_filters_test.rb`.
- [ ] **Step 5: Commit** `git commit -m "API: translate discover_books parameters into search criteria"`

### Task 3: `GET /api/v1/discover/books` and `discover_books`

**Files:**
- Modify: `web-app/app/lib/api/page.rb` (optional `max_page:`)
- Create: `web-app/app/controllers/api/v1/books/discover_books_controller.rb` (generate it:
  `bin/rails generate controller api/v1/books/discover_books --skip-routes --no-helper --no-assets`,
  then replace the body and remove any generated view folder)
- Modify: `web-app/config/routes.rb`. Add `get "discover/books", to: "discover_books#index", as: :discover_books`
  next to `search/books`.
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - the path `/api/v1/discover/books`, with `operationId: discoverBooks` and the `x-mcp` block;
  - `DiscoverBookCollection`, whose `meta` gains `filters` (`DiscoverFilters`), `order` (enum
    `rank, random`) and `seed` (integer, present only for random);
  - `DiscoverFilters`, with `additionalProperties: false` and a property for each `applied` key;
  - in `listBooks`' `x-mcp` description, one sentence pointing to discover_books for length,
    language, exclusions, unranked books, rank ranges or random order.
- Test:
  - `web-app/test/lib/api/page_test.rb`;
  - `web-app/test/controllers/api/v1/books/discover_books_controller_test.rb`;
  - `web-app/test/integration/api/v1/contract_coverage_test.rb`;
  - `web-app/test/integration/api/v1/operation_scope_contract_test.rb` (if it lists paths);
  - `web-app/test/controllers/api/v1/openapi_controller_test.rb` (both path lists);
  - `web-app/test/lib/mcp/tool_directory_test.rb` (27 → 28 entries, 26 → 27 non-composite);
  - `web-app/test/lib/mcp/catalog_test.rb`;
  - `web-app/test/controllers/api/mcp_controller_test.rb`.

**Interfaces:**
- Consumes:
  - `Api::DiscoverBookFilters.call(params)` (Task 2);
  - `Books::SavedSearchQuery.call(..., order:, seed:, track_total_hits: true)` (Task 1). Its
    `Result#books` rows respond to `ranked_position`.
- Produces: `Api::Page.new(page:, per_page:, total_count:, max_page: nil)`. When `max_page` is set,
  `total_pages` is `[computed, max_page].min`, and `next_page`/`last` follow it. Every existing
  caller is unchanged.

**Controller flow, in order:**
1. `filters = ::Api::DiscoverBookFilters.call(params)`.
2. Parse `page`/`per_page` with `::Api::Page.integer`, using the `from_params` bounds.
3. `max_page = (MAX_RESULT_WINDOW.to_f / per_page).ceil`. A larger `page` raises
   `InvalidParameter`, and the message says to narrow the filters.
4. Run `SavedSearchQuery`:
   - the criteria are `::Books::SavedSearchCriteria.new(filters.criteria)`;
   - the owner is `current_principal.user`.
5. Build `::Api::Page.new(..., total_count: result.total, max_page:)`.
6. Render `{data, meta, links}`:
   - `data`: `::Api::V1::Books::BookResource.new(book, params: {rank: book.ranked_position}).to_h`
     for each book.
   - `meta`: `page.meta`, plus `filters` (only when `applied` is non-empty), `order`, and `seed`
     for random.
   - `links`: built with `query: applied.merge(order: "random", seed:)` for random, else
     `applied`.

Include `::Api::SearchBacked` so an OpenSearch outage is the 503.

**`x-mcp` description:**
- when to use it rather than list_books;
- where the slugs come from (search_categories, list_categories, list_countries, list_languages);
- to pass `meta.seed` back to page a random order;
- that results are best-ranked first in `rank` order, and that `rank` is null for unranked books;
- that `meta.total_count` is exact, but at most the first 10,000 results can be paged.

- [ ] **Step 1: Write failing tests.**
  - **`page_test`:** `max_page: 334` with `total_count: 100_000, per_page: 30` gives
    `total_pages == 334`; on page 334, `next_page` is nil and `links[:last]` contains
    `page=334`. Without `max_page` the values are unchanged.
  - **Controller tests** (stub `::Search::Books::Search::BookAdvanced.call`, as
    `book_searches_controller_test.rb` stubs `BookGeneral`; use a member token as that test does):
    - 200 with the data ids in the stub's order and `rank` from the primary ranking;
    - `meta.filters` echoes the applied filters;
    - the stub receives `track_total_hits: true`;
    - `order=random&seed=5`: the stub receives `order: :random, seed: 5`, and `meta.seed == 5`,
      `meta.order == "random"`, and `links.next` contains `seed=5` and `order=random`;
    - `order=random` without a seed: `meta.seed` is an Integer and appears in `links.self`;
    - Review Focus 5: `per_page=30&page=334` with stub total 100_000 gives
      `meta.total_pages == 334` and a null `links.next`; `page=335` is a 400 and the stub is
      never called;
    - `hide_read=true`:
      - the stub receives `excluded_book_ids` containing a book on the token user's `:read`
        `Books::UserList` (find the fixture list, or create one in the test);
      - Review Focus 4: for a user with no read list it's 200 and `excluded_book_ids == []`;
    - an unknown language slug is a 404 problem;
    - `rank_min=10&rank_max=5` is a 400;
    - OpenSearch unavailable (stub raising `::Search::Shared::Client::UNAVAILABLE_ERRORS.first`)
      is a 503.
  - **Contract coverage:** add `GET /api/v1/discover/books` entries for 200, 400, 401, 403, 404,
    429 and 503, modelled on the `search/books` entries.
  - **MCP:**
    - `mcp_controller_test` lists `discover_books` in `tools/list`;
    - one `tools/call` of `discover_books` with `{"language": "<fixture slug>", "order": "random", "seed": 3}`
      returns data with `meta.seed == 3`, against the stubbed engine;
    - update the count pins named under Files.
- [ ] **Step 2: Run** `bin/rails test test/lib/api/page_test.rb test/controllers/api/v1/books/discover_books_controller_test.rb test/integration/api/v1 test/lib/mcp test/controllers/api`.
  Expected: FAIL on the new tests and pins.
- [ ] **Step 3: Implement** the route, controller, OpenAPI path and schemas, and the `list_books`
  pointer.
- [ ] **Step 4: Run the Step 2 command; expect PASS.**
- [ ] **Step 5: Commit** `git commit -m "Public API + MCP: discover_books"`

### Task 4: `GET /api/v1/languages` and `list_languages`

**Files:**
- Create: `web-app/app/controllers/api/v1/books/languages_controller.rb` (generate as in Task 3)
- Create: `web-app/app/lib/api/v1/books/language_resource.rb` (Alba; attributes `slug`, `name`,
  `book_count` from `params[:book_count]`). It mirrors `CountryResource`, without `url`.
- Modify: `web-app/config/routes.rb`. Add `get "languages", to: "languages#index"` next to
  `countries`.
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - path `/api/v1/languages`, `operationId: listLanguages`;
  - `sort` enum `[book_count, name]`, default `book_count`;
  - `page`/`per_page`;
  - 200 `LanguageCollection`, plus 400/401/403/429;
  - schemas `Language` (`slug, name, book_count`) and `LanguageCollection`;
  - `x-mcp`: "Lists the original languages of catalogue books, most books first, with their slugs
    and `book_count`. Use it to find the slugs `language` and `exclude_language` accept in
    discover_books, instead of guessing."
- Test: `web-app/test/controllers/api/v1/books/languages_controller_test.rb`, plus contract
  coverage, the openapi path lists and the MCP count pins (28 → 29 entries, 27 → 28 non-composite).

**Interfaces:**
- Produces: rows of `Language`, with a `book_count` select alias.
  - The count is `Books::Book.catalog` books whose `original_language_id` is that language.
  - Built as a joined subquery like `Books::BrowseQuery.countries`, so `count`, `offset` and
    `limit` work.
  - Only languages with at least one such book appear.
  - `sort=name` orders by `languages.name`; `book_count` orders by count desc, then name.
  - Served through `render_ranked_page`.

- [ ] **Step 1: Write failing tests:**
  - 200 lists only languages with catalogue books, with correct counts. A provisional book's
    language with no other book is absent.
  - Default order is most books first.
  - `sort=name` is alphabetical.
  - `sort=popularity` is a 400.
  - `links.next` carries `sort`.
  - Contract coverage entries for 200, 400, 401, 403 and 429.
  - `list_languages` appears in `tools/list`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/languages_controller_test.rb test/integration/api/v1 test/lib/mcp test/controllers/api`.
  Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the Step 2 command; expect PASS.**
- [ ] **Step 5: Commit** `git commit -m "Public API + MCP: list_languages"`

### Task 5: Instructions and docs, then the full suite

**Files:**
- Modify: `web-app/config/mcp/books/instructions.md`.
  - In the ordering sentence, add that `discover_books` is in rank order, or in random order when
    asked.
  - Change "use search_categories and list_countries rather than guessing a filter slug" to name
    `list_languages` too.
  - If `test/lib/mcp/sites/books_test.rb` pins phrases there, keep them true.
- Modify: `docs/features/public-api.md` and `docs/features/mcp-server.md`. Add both endpoints and
  tools: parameters, the window and seed behaviour, and the 404 for unknown slugs.
- Modify: `docs/features/saved_searches.md`.
  - The API shares the engine.
  - The new criterion is `min_ranked_position`.
  - The new `BookAdvanced` options are `order`/`seed` and `track_total_hits`, and saved searches
    keep the defaults.

- [ ] **Step 1: Edit the files above.**
- [ ] **Step 2: Run** `bin/rails test test/lib/mcp/sites/books_test.rb`. Expected: PASS.
- [ ] **Step 3: Run the full suite and the linter.** From `web-app/`, run `bin/rails test` and
  `bundle exec standardrb`. Expected: 0 failures, 0 errors, no new warning lines; standardrb
  clean.
- [ ] **Step 4: Commit** `git commit -m "discover_books and list_languages: instructions and docs"`
