# Public API web parity — increment 1 (search + ranked-list filters) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members can search books (`GET /api/v1/search/books`) and filter every ranked book collection by the web's filters (categories, countries, years, collection), on the primary ranking or any global configuration.

**Architecture:** `Books::FilterParams` stays the one filter parser. It gains two error classes, both still `ActiveRecord::RecordNotFound`, so the web is untouched. A new `Api::RankedBookFilters` turns API params into `RankedBooksQuery` arguments plus the `meta.filters` echo, and maps parser errors onto API errors. Search reuses `Books::BookSearchQuery`'s OpenSearch call through a new public `hit_ids`. An OpenSearch outage becomes a 503 `search_unavailable`.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, Alba, openapi_first (contract validation), OpenSearch.

**Spec:** `docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md` (increment 1 only). Background: `docs/features/public-api.md`.

## Global Constraints

- Run every Rails command from `web-app/`. Lint: `bundle exec standardrb`. Not rubocop, not brakeman.
- Inside `Api::V1::Books` (and anywhere under `module Api`), root-anchor model references: `::Books::Book`, `::Books::FilterParams`. Do **not** create an `Api::Books` module: it would shadow `::Books` for every bare reference in `module Api`.
- Create controllers with the generator (`bin/rails generate controller ...`), then edit them. Never hand-create one.
- Tests: Minitest 6 (`assert_nil`, never `assert_equal nil`). Controller tests assert behaviour (status, data, meta, links), never copy. Every integration request validates against `openapi.yaml`:
  - success responses: `assert_api_conform(status:)`;
  - deliberately invalid requests: `assert_api_response_conform(status:)`.
- No existing response body changes shape. An unfiltered `GET /api/v1/books` returns exactly what it returns today: no `meta.filters` key (spec D5).
- Filter parameter names: `category_id`, `country_id`, `year`, `published_start`, `published_end`, `collection`. Slugs are comma-separated. Limits are 6 categories and 10 countries; years run from -4000 to (current year + 5) (spec D1, D2).
- Errors:
  - malformed input → 400 `invalid_parameter`, with a `detail` naming the parameter;
  - an unknown `category_id` or `country_id` slug → 404 `not_found`, with a `detail` naming the parameter and the slug;
  - an unknown path resource → today's shared 404 body;
  - an OpenSearch failure → 503 `search_unavailable` (spec D3, D8).
- The `collection` parameter, `year` combined with `published_start` or `published_end`, and `country_id` combined with `collection` are all 400s (spec D3, D10).
- Search: at most 100 hits per query; the normal collection envelope; catalog books only (spec D6, D7, increment-1 table).
- A clean `bin/rails test` prints no new warnings.

## Review Focus

1. **Repeated or empty slugs**, such as `category_id=fiction,fiction` or `category_id=fiction,,novels`. These should behave like the de-duplicated list (FilterParams already strips blanks and uniqs). A whole-blank value, `category_id=`, should be a 400, not an unfiltered list. Owner: Task 2.
2. **A merged category slug passed in `category_id` on the category-books path**, where it resolves to the path category itself. This should be one category, not a duplicate that counts twice toward the limit of 6. Owner: Task 4.
3. **Paging through a filtered collection.** `links.next` must carry every filter in canonical form; following it should give page 2 of the same filtered list. Owner: Task 3.
4. **A search whose top hits are all provisional or stale ids.** This should return the remaining catalog books, with `total_count` matching `data`, never a 500. Owner: Task 5.
5. **`per_page=100` search on a query with exactly 100 hits.** This should be one full page and `total_pages: 1`, not a phantom second page. Owner: Task 5.

---

### Task 1: FilterParams distinguishes malformed from unknown

**Files:**
- Modify: `web-app/app/lib/books/filter_params.rb`
- Test: `web-app/test/lib/books/filter_params_test.rb`

**Interfaces:**
- Produces two error classes:
  - `Books::FilterParams::InvalidFilter < ActiveRecord::RecordNotFound`
  - `Books::FilterParams::UnknownFilter < ActiveRecord::RecordNotFound`
- Each has `attr_reader :param` (a String: `"category_id"`, `"country_id"`, `"year"`, `"published_start"` or `"published_end"`). `UnknownFilter` also has `attr_reader :slug`.
- The constructors are `InvalidFilter.new(param, detail)` and `UnknownFilter.new(param, slug)`. `message` is human-readable and names the param (and the slug).

- [ ] **Step 1: Write the failing tests** (add to the existing test class)

```ruby
test "too many category slugs raises InvalidFilter naming category_id" do
  error = assert_raises(Books::FilterParams::InvalidFilter) { resolve(category_id: (1..7).map { "c#{it}" }.join(",")) }
  assert_equal "category_id", error.param
end

test "too many country slugs raises InvalidFilter naming country_id" do
  error = assert_raises(Books::FilterParams::InvalidFilter) { resolve(country_id: (1..11).map { "c#{it}" }.join(",")) }
  assert_equal "country_id", error.param
end

test "a malformed or out-of-range year raises InvalidFilter naming the param" do
  assert_equal "year", assert_raises(Books::FilterParams::InvalidFilter) { resolve(year: "18x5") }.param
  assert_equal "published_start", assert_raises(Books::FilterParams::InvalidFilter) { resolve(published_start: "-5000") }.param
  assert_equal "published_end", assert_raises(Books::FilterParams::InvalidFilter) { resolve(published_end: (Date.current.year + 6).to_s) }.param
end

test "an unknown category slug raises UnknownFilter with the slug" do
  error = assert_raises(Books::FilterParams::UnknownFilter) { resolve(category_id: "fiction,no-such-genre") }
  assert_equal ["category_id", "no-such-genre"], [error.param, error.slug]
end

test "an unknown country slug raises UnknownFilter with the slug" do
  error = assert_raises(Books::FilterParams::UnknownFilter) { resolve(country_id: "french,atlantis") }
  assert_equal ["country_id", "atlantis"], [error.param, error.slug]
end

test "both error classes are still RecordNotFound, so the web keeps its 404" do
  assert_operator Books::FilterParams::InvalidFilter, :<, ActiveRecord::RecordNotFound
  assert_operator Books::FilterParams::UnknownFilter, :<, ActiveRecord::RecordNotFound
end
```

- [ ] **Step 2: Run them to verify they fail.** Run `bin/rails test test/lib/books/filter_params_test.rb`. Expected: NameError for `Books::FilterParams::InvalidFilter`.

- [ ] **Step 3: Implement.**
  - Define both classes inside `Books::FilterParams`.
  - Make every `raise ActiveRecord::RecordNotFound` in the file raise one of them:
    - too many slugs → `InvalidFilter`;
    - a year failing `YEAR_FORMAT` or `YEAR_RANGE` → `InvalidFilter` for that param;
    - a country slug count mismatch → `UnknownFilter`, with the first missing slug (compare the input slugs with the found records' slugs);
    - a category slug the resolver cannot resolve → `UnknownFilter`.
  - `parse_slugs`, `resolve` and `validated_year` need the param name passed in.
  - Do not change what resolves, the sort order, or `redirect`.

- [ ] **Step 4: Run the tests, then confirm the web is unchanged.** Run `bin/rails test test/lib/books/filter_params_test.rb test/controllers/books/ranked_items_controller_test.rb test/controllers/books/filters_controller_test.rb`. Expected: all pass, with **no edits** to the two controller test files. If one needs an edit, stop and report it: the web's behaviour moved.

- [ ] **Step 5: Commit.** `git commit -m "FilterParams: tell malformed filters from unknown slugs"`

---

### Task 2: `Api::RankedBookFilters`, the unknown-filter 404, and `meta` on collections

**Files:**
- Create: `web-app/app/lib/api/ranked_book_filters.rb`
- Create: `web-app/app/lib/api/unknown_filter.rb`
- Modify: `web-app/app/controllers/concerns/api/error_rendering.rb` (add a rescue)
- Modify: `web-app/app/controllers/api/v1/base_controller.rb` (`render_page` / `render_ranked_page` take `meta:`)
- Test: `web-app/test/lib/api/ranked_book_filters_test.rb`

**Interfaces:**
- Consumes `Books::FilterParams` and its two error classes (Task 1), and `Collections::Registry.find(:books, slug)`.
- Produces:
  - `Api::RankedBookFilters.call(params, path_category: nil) -> Result`.
  - `Result = Struct.new(:categories, :countries, :year_start, :year_end, :collection, :applied, keyword_init: true)`.
  - `categories`, `countries` and `collection` are the records and the `Collections::Collection` (or nil) to pass to `Books::RankedBooksQuery.call`; `year_start` and `year_end` are passed through as FilterParams returns them.
  - `applied` is a `Hash{Symbol => String|Integer}` holding only the filter keys that were sent, in canonical form:
    - `category_id`: the sorted canonical slugs joined by `,`, excluding `path_category`;
    - `country_id`: the sorted slugs joined;
    - `year`, `published_start`, `published_end`: Integers;
    - `collection`: the slug.
  - Errors: raises `Api::Page::InvalidParameter` (already a 400) for malformed input, and `Api::UnknownFilter` for an unknown slug.
- `Api::UnknownFilter < StandardError` takes `(param, slug)`; its message is `"No #{param} matches \"#{slug}\""`.
- `Api::ErrorRendering` rescues `Api::UnknownFilter` → `Api::Problem.new(:not_found, detail: error.message)`.
- `render_page(relation, path:, query: {}, meta: {})` renders `meta: page.meta.merge(meta)`, and `render_ranked_page` takes and forwards `meta:`. Existing callers are unchanged.

- [ ] **Step 1: Write the failing tests** in `test/lib/api/ranked_book_filters_test.rb`. Build `ActionController::Parameters` the way `filter_params_test.rb` does. Cover:
  - no filter params → empty `applied`, empty `categories` and `countries`, nil years and collection;
  - `category_id: "novels,fiction"` → `applied[:category_id] == "fiction,novels"`;
  - a merged category's old slug comes back in `applied` as the target's slug;
  - `year: "1869"` → `year_start` and `year_end` are both `"1869"`, and `applied == {year: 1869}`;
  - `published_start: "1800", published_end: "1899"` → `applied == {published_start: 1800, published_end: 1899}`;
  - `year` together with `published_start` → `Api::Page::InvalidParameter`, message mentioning `year`;
  - `collection: "women"` → `collection.slug == "women"`, `applied[:collection] == "women"`;
  - `collection: "martians"` → `InvalidParameter` mentioning `collection`;
  - `country_id: "french", collection: "women"` → `InvalidParameter` mentioning both;
  - `category_id: ""` → `InvalidParameter` mentioning `category_id` (Review Focus 1);
  - `category_id: "fiction,fiction,,novels"` → the same as `"fiction,novels"` (Review Focus 1);
  - more than 6 categories → `InvalidParameter`;
  - `category_id: "no-such-genre"` → `Api::UnknownFilter` whose message contains `category_id` and `no-such-genre`;
  - `path_category:` given, with 6 other slugs → `InvalidParameter` (the path category counts toward 6);
  - `path_category: novels` with `category_id: "novels"` → `categories == [novels]`, and `applied` has no `:category_id` key: the key is omitted when nothing is left after excluding the path category (Review Focus 2).

- [ ] **Step 2: Run to verify they fail.** Run `bin/rails test test/lib/api/ranked_book_filters_test.rb`. Expected: NameError `Api::RankedBookFilters`.

- [ ] **Step 3: Implement `Api::RankedBookFilters`.**
  - Check the API-only rules first, in this order:
    - blank values;
    - `year` combined with a range parameter;
    - an unknown `collection` (`Collections::Registry.find`);
    - `country_id` combined with `collection`.
  - Then call `::Books::FilterParams.call`, with `category_id` rewritten to include `path_category.slug` when one is given, so the limit of 6 applies to the union.
  - Rescue `FilterParams::InvalidFilter` and re-raise it as `Api::Page::InvalidParameter`, with the error's message. Rescue `FilterParams::UnknownFilter` and re-raise it as `Api::UnknownFilter`, with its param and slug.
  - Then add `Api::UnknownFilter`, the `ErrorRendering` rescue, and the `meta:` keyword on `render_page` and `render_ranked_page`.

- [ ] **Step 4: Run the new tests and the existing API controller tests.** Run `bin/rails test test/lib/api/ranked_book_filters_test.rb test/controllers/api/v1`. Expected: all pass.

- [ ] **Step 5: Run `CI=1 bin/rails zeitwerk:check`.** Expected: "All is good!"

- [ ] **Step 6: Commit.** `git commit -m "API: RankedBookFilters maps web filters onto the ranked query"`

---

### Task 3: Filters on `GET /api/v1/books` and `/api/v1/ranking_configurations/{id}/books`

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/books_controller.rb` (`index`)
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - new `components/parameters`: `category_id`, `country_id`, `year`, `published_start`, `published_end`, `collection`;
  - new schemas `AppliedFilters` and `RankedBookCollection`;
  - `listBooks` and `listRankingConfigurationBooks` reference both, and `listBooks` gains a `"404"` response.
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb` (add `["GET", "/api/v1/books", "404"]`)
- Test: `web-app/test/controllers/api/v1/books/books_controller_test.rb`

**Interfaces:**
- Consumes `Api::RankedBookFilters.call(params)` and `render_ranked_page(..., meta:)` (Task 2).
- Produces the OpenAPI components that Task 4 reuses:
  - `#/components/parameters/{category_id,country_id,year,published_start,published_end,collection}`;
  - `#/components/schemas/AppliedFilters`;
  - `#/components/schemas/RankedBookCollection`.

OpenAPI shapes (exact):

```yaml
# parameters (each: in: query, required: false)
category_id:     {schema: {type: string, minLength: 1}, description: "Comma-separated category slugs, up to 6. A book must carry every one. Merged and renamed slugs resolve."}
country_id:      {schema: {type: string, minLength: 1}, description: "Comma-separated country slugs, up to 10. A book from any of them matches. Cannot be combined with collection."}
year:            {schema: {type: integer, minimum: -4000}, description: "Books first published in this year. Cannot be combined with published_start or published_end."}
published_start: {schema: {type: integer, minimum: -4000}, description: "Books first published in or after this year."}
published_end:   {schema: {type: integer, minimum: -4000}, description: "Books first published in or before this year."}
collection:      {schema: {type: string, enum: [women, africa, asia, latin-america, western, non-western]}, description: "A curated collection, as on the site."}
# schemas
AppliedFilters:   # only the keys that were sent; canonical slugs
  type: object
  additionalProperties: false
  properties:
    category_id: {type: string}
    country_id: {type: string}
    year: {type: integer}
    published_start: {type: integer}
    published_end: {type: integer}
    collection: {type: string}
RankedBookCollection:   # BookCollection whose meta may carry filters
  allOf:
    - $ref: "#/components/schemas/BookCollection"
    - type: object
      properties:
        meta:
          type: object
          properties:
            filters: {$ref: "#/components/schemas/AppliedFilters"}
```

Name the `collection` enum's source in its description, so a reviewer can check it against `Books::CollectionsRegistry`. A test asserts that the two agree (Step 1).

- [ ] **Step 1: Write the failing controller tests** (add to `books_controller_test.rb`). Set up ranked items for `war_and_peace` (1869, French, novels), `crime_and_punishment` (1866), `got` (1996, French) and `of_mice_and_men` (1937, Japanese) on `ranking_configurations(:books_global)`. Check the actual fixture category and country links before choosing expected slugs (`test/fixtures/category_items.yml`, `test/fixtures/books/book_countries.yml`). Cover:
  - `?country_id=french` → only the French books, in rank order; `meta.filters == {country_id: "french"}`; `links.self` contains `country_id=french`;
  - `?published_start=1800&published_end=1899` → only the 19th-century books;
  - `?year=1869` → only war_and_peace;
  - `?category_id=novels&country_id=french` → the intersection;
  - nested: `GET /api/v1/ranking_configurations/:id/books?country_id=french` reads that configuration, and its links stay nested;
  - an unfiltered `GET /api/v1/books` has **no** `filters` key in `meta` (Global Constraints);
  - paging (Review Focus 3): with `per_page=1&country_id=french`, `links.next` carries `country_id=french`; following it returns the second French book;
  - `?country_id=atlantis` → 404, `code == "not_found"`, `detail` contains `atlantis`;
  - `?year=1869&published_start=1800`, `?collection=martians` and `?country_id=french&collection=women` → 400 `invalid_parameter` (use `assert_api_response_conform`);
  - `OpenapiDocument.raw.dig("components", "parameters", "collection", "schema", "enum").sort == Books::CollectionsRegistry.all.map(&:slug).sort`.

- [ ] **Step 2: Run to verify they fail.** Run `bin/rails test test/controllers/api/v1/books/books_controller_test.rb`. Expected: the filter tests fail (the filters are ignored today).

- [ ] **Step 3: Implement.**
  - `index` calls `filters = ::Api::RankedBookFilters.call(params)` before building the relation, so a bad filter beats a bad page, as a bad slug already does.
  - It passes the filters into `::Books::RankedBooksQuery.call`.
  - It renders with `query: filters.applied, meta: (filters.applied.any? ? {filters: filters.applied} : {})`.
  - Edit the OpenAPI document as above, and add the coverage entry `["GET", "/api/v1/books", "404"] => -> { get "/api/v1/books?country_id=atlantis", headers: bearer(ApiTokenSecrets::MEMBER) }`.

- [ ] **Step 4: Run the tests.** Run `bin/rails test test/controllers/api/v1/books/books_controller_test.rb test/integration/api/v1/contract_coverage_test.rb`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "API: the web's filters on the ranked book collections"`

---

### Task 4: Filters and a ranking configuration on category books

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/category_books_controller.rb`
- Modify: `web-app/config/routes.rb`: add `get "ranking_configurations/:ranking_configuration_id/categories/:slug/books", to: "category_books#index", as: :ranking_configuration_category_books, constraints: {ranking_configuration_id: /\d+/}` next to the existing nested routes.
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - `listCategoryBooks` gains the six filter parameters and `RankedBookCollection`;
  - new path `/api/v1/ranking_configurations/{id}/categories/{slug}/books`, operationId `listRankingConfigurationCategoryBooks`, with responses 200, 400, 401, 403, 404 and 429. Model it on `listRankingConfigurationBooks`.
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb` (six entries for the new path)
- Test: `web-app/test/controllers/api/v1/books/category_books_controller_test.rb`

**Interfaces:**
- Consumes `Api::RankedBookFilters.call(params, path_category:)` (Task 2), the Task 3 OpenAPI components, and the `ranking_configuration` and `collection_path(suffix)` helpers in `Api::V1::Books::BaseController`.

- [ ] **Step 1: Write the failing tests.** Cover:
  - `GET /api/v1/categories/novels/books?country_id=french` → novels that are also French, with `meta.filters == {country_id: "french"}`;
  - nested: `/api/v1/ranking_configurations/:id/categories/novels/books` reads that configuration; links are nested and use the canonical slug;
  - an archived or unknown configuration id → 404;
  - `?category_id=novels` on the novels path (or a merged slug of novels) → the same rows as without it, and no `category_id` in `meta.filters` (Review Focus 2);
  - the path category plus 6 more slugs → 400;
  - the existing tests in this file still pass unedited.

- [ ] **Step 2: Run to verify they fail.** Run `bin/rails test test/controllers/api/v1/books/category_books_controller_test.rb`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - Use `ranking_configuration` (the nested path or the primary) instead of `default_primary`.
  - Pass `path_category: category` to `RankedBookFilters`.
  - Use `collection_path("categories/#{category.slug}/books")` for links.
  - Pass `query:` and `meta:` as in Task 3.
  - Add the route, the OpenAPI changes and the coverage entries.

- [ ] **Step 4: Run the tests.** Run `bin/rails test test/controllers/api/v1/books test/integration/api/v1/contract_coverage_test.rb`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "API: filters and ranking configuration on category books"`

---

### Task 5: `GET /api/v1/search/books` and the 503 `search_unavailable`

**Files:**
- Modify: `web-app/app/lib/books/book_search_query.rb`: add a public `self.hit_ids(text, size:)`; `call` uses it.
- Modify: `web-app/app/lib/search/shared/client.rb`: add `UNAVAILABLE_ERRORS = [::OpenSearch::Transport::Transport::Error, ::Faraday::Error].freeze`.
- Modify: `web-app/app/lib/api/problem.rb`: add `search_unavailable: [503, "Search unavailable"]`.
- Modify: `web-app/app/views/developers/show.html.erb`: add the `reasons` entry `search_unavailable: "Search is temporarily unavailable; retry shortly."`.
- Create, via `bin/rails generate controller api/v1/books/book_searches --skip-routes --no-helper`: `web-app/app/controllers/api/v1/books/book_searches_controller.rb`, then edit it to subclass `BaseController`. Delete any view directory the generator makes.
- Modify: `web-app/config/routes.rb`: `get "search/books", to: "book_searches#index", as: :search_books`, inside `scope module: :books`.
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - path `/api/v1/search/books` (`x-domain: books`, operationId `searchBooks`), with parameters `q` (query, required, `type: string, minLength: 1`), `page` and `per_page`;
  - responses 200 (`BookCollection`), 400, 401, 403, 429 and 503;
  - a new `components/responses/ServiceUnavailable`;
  - `search_unavailable` added to the `Problem.code` enum.
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb`: entries for all six responses. The 503 entry stubs `::Search::Books::Search::BookGeneral.stubs(:call).raises(Faraday::ConnectionFailed, "down")` inside the lambda and unstubs it afterwards. The 200 entry stubs `BookGeneral` to return war_and_peace's hit.
- Test: `web-app/test/controllers/api/v1/books/book_searches_controller_test.rb` (the generator creates it); `web-app/test/lib/books/book_search_query_test.rb`; `web-app/test/lib/api/problem_test.rb` if it enumerates codes.

**Interfaces:**
- Produces:
  - `Books::BookSearchQuery.hit_ids(text, size:) -> Array<Integer>`: the distinct hit ids in relevance order; `[]` for blank text. It uses `BookGeneral` defaults (standalone books, provisional excluded).
  - `Api::V1::Books::BookSearchesController::SEARCH_LIMIT = 100`.
  - `Search::Shared::Client::UNAVAILABLE_ERRORS`, which increment 2's similar-books endpoint will reuse.

- [ ] **Step 1: Write the failing tests.** Stub `::Search::Books::Search::BookGeneral.call` the way `test/controllers/api/v1/admin/books/books_controller_test.rb` does (a `hits(...)` helper). Cover:
  - `GET /api/v1/search/books?q=war` → `data` in hit order with the `Book` shape and `rank` from the primary; `links.self` carries `q=war`; and `BookGeneral` received `size: 100`;
  - a provisional book among the hits is absent, and so is a stale id; `total_count` equals the rows actually returned (Review Focus 4);
  - exactly 100 hits with `per_page=100` → `total_pages == 1`, and `links.next` is nil (Review Focus 5);
  - a missing `q`, or `q=%20`, → 400 `invalid_parameter` (`assert_api_response_conform`);
  - `BookGeneral` raising `Faraday::ConnectionFailed`, and separately `OpenSearch::Transport::Transport::Errors::ServiceUnavailable` → 503, `code == "search_unavailable"`;
  - `Books::BookSearchQuery.hit_ids("war", size: 7)` passes `size: 7` and returns distinct integer ids;
  - the existing `book_search_query_test.rb` tests pass unedited;
  - `test/controllers/developers_controller_test.rb`'s anchor test passes with the new code (it iterates `Api::Problem::DEFINITIONS`).

- [ ] **Step 2: Run to verify they fail.** Run `bin/rails test test/controllers/api/v1/books/book_searches_controller_test.rb test/lib/books/book_search_query_test.rb`. Expected: FAIL (no route, no `hit_ids`).

- [ ] **Step 3: Implement `index`.**
  - `q = params[:q].to_s.strip`; if it is blank, render the 400 `"q is required"`.
  - `ids = ::Books::BookSearchQuery.hit_ids(q, size: SEARCH_LIMIT)`.
  - The relation is `::Books::Book.catalog.where(id: ids).in_order_of(:id, ids).includes(:primary_ranked_item, {book_authors: :author}, {primary_image: {file_attachment: :blob}})`, or nil when `ids` is empty.
  - Render with `render_page(relation, path: "/api/v1/search/books", query: {q: q})`, mapping each row to `BookResource.new(book).to_h`.
  - Add `rescue_from(*::Search::Shared::Client::UNAVAILABLE_ERRORS)`, which renders `Api::Problem.new(:search_unavailable, detail: "Search is temporarily unavailable. Retry shortly.")` and logs the error class.

- [ ] **Step 4: Run the tests.** Run `bin/rails test test/controllers/api/v1 test/lib/books/book_search_query_test.rb test/controllers/developers_controller_test.rb test/integration/api/v1`. Expected: PASS.

- [ ] **Step 5: Run `CI=1 bin/rails zeitwerk:check`.** Expected: "All is good!"

- [ ] **Step 6: Commit.** `git commit -m "API: book search, with a 503 when search is down"`

---

### Task 6: Docs and the full verification

**Files:**
- Modify: `docs/features/public-api.md`:
  - add search;
  - add the filter parameters, with their rules and the 400-versus-404 split;
  - add `meta.filters`;
  - add the nested category-books path;
  - add `search_unavailable`.

  `/developers` renders from the OpenAPI document, so it needs no edit.

- [ ] **Step 1: Update the feature doc.** Keep it to behaviour, not class-by-class notes, per `docs/documentation.md`.
- [ ] **Step 2: Run the full suite.** Run `bin/rails test`. Expected: 0 failures, 0 errors, and no new warning lines.
- [ ] **Step 3: Lint.** Run `bundle exec standardrb`. Expected: no offences. Fix with `--fix` where safe.
- [ ] **Step 4: Run `/developers`'s existing E2E against this checkout's server.**
  - Build and start the server: `yarn build:all && bin/rails server`.
  - Check that port 3000 belongs to this worktree (the `ss`/`readlink` snippet in `AGENTS.md`). If another checkout holds it, stop and tell Shane.
  - Run `yarn test:e2e --grep developers`. Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "Docs: API search and filters"`
