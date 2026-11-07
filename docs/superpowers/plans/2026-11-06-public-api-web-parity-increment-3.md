# Public API web parity — increment 3 (lists, categories, countries, configuration on records) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the rest of the web-parity gap:
- lists take `sort` and `q`;
- members can search categories and list countries;
- a book, a book's lists and a list can be read through a named global ranking configuration.

Each new operation is also an MCP tool.

**Architecture:**
- Two parameter parsers move to `Api::V1::BaseController`, so every controller rejects bad input the same way:
  - `text_param!`: a free-text parameter, bounded;
  - `enum_param!`: one of a closed set. It is the categories controller's `param_in`, lifted.
  - `Api::SearchBacked#search_text!` calls `text_param!`.
- Category search and countries reuse `Books::BrowseQuery`, as the web's browse pages do.
- The configuration forms reuse the existing actions. `ranking_configuration` and `collection_path` already resolve the nested path (spec D9).

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, Alba, openapi_first, the `mcp` gem (tools generated from OpenAPI `x-mcp`).

**Spec:** `docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md`, increment 3 only. Background: `docs/features/public-api.md`, `docs/features/mcp-server.md`. Increment 2 (PR #454) is the pattern for this work. It added an `x-mcp` block to every new operation, and this plan does the same.

## Global Constraints

- Run every Rails command from `web-app/`. Lint with `bundle exec standardrb`. Never run rubocop or brakeman. Run one `bin/rails test` process at a time per worktree.
- Root-anchor model references inside `module Api`, e.g. `::Books::List`, because a bare `Books::` raises `NameError`. Never create an `Api::Books` module.
- Create a new controller with `bin/rails generate controller api/v1/books/<name> --no-helper --no-assets --skip-routes`. Delete any view directory it makes.
- Tests use Minitest 6 (`assert_nil`). Controller tests assert behaviour, never copy.
- Every API test request validates against `openapi.yaml`:
  - success: `assert_api_conform(status:)`;
  - deliberately invalid: `assert_api_response_conform(status:)`.
- Every documented (method, path, status) gets a row in `test/integration/api/v1/contract_coverage_test.rb` `EXERCISES`. The loop already clears the rate-limit store before each exercise; leave that alone.
- **Public-surface pin tests move once per added operation** (increment 2 learned this):
  - `test/controllers/api/v1/openapi_controller_test.rb`: both expected path lists, in document order;
  - `test/lib/mcp/tool_directory_test.rb`: entries and non-composite counts;
  - `test/lib/mcp/admin_catalog_test.rb`: the public catalogue size;
  - `test/controllers/developers_controller_test.rb`: the MCP tool count.
  
  Today the public catalogue is 21 operations and the tool directory has 22 entries. This plan adds 5 operations, so they end at 26 and 27.
- **No existing response body changes shape**, and an existing request returns what it returns today:
  - `GET /api/v1/lists` with no `sort` and no `q` is unchanged;
  - `GET /api/v1/books/{slug}` is unchanged;
  - `GET /api/v1/books/{slug}/lists` is unchanged;
  - `GET /api/v1/lists/{id}` is unchanged.
- **Every existing test passes untouched**, apart from the pin bumps above. That includes `categories_controller_test.rb` and `book_searches_controller_test.rb` after the parser lift. If one has to change, stop and report.
- **Errors:**
  - every new 400 is `invalid_parameter` and its `detail` names the parameter;
  - an unknown path resource keeps today's shared 404 body;
  - under `/ranking_configurations/{id}/`, an unknown, archived or member-owned configuration is a 404 that wins over everything else.
- `x-mcp` keys are `description` only. Each description is at least 60 characters, differs from the summary, and names the tools to use next.
- A clean `bin/rails test` prints no new warnings.

## Decisions this plan makes (spec leaves them to the builder)

- **D-a. One text parser and one enum parser** on `Api::V1::BaseController`, not one per controller. Lists, category search and book or author search all bound their text the same way.
- **D-b. Sort and search state goes in the links, not in `meta`.** The lists `sort` and `q`, and the category search `type`, ride on the paging `links`, and `meta` gets no `filters` key. That follows `/api/v1/categories`' `type` and `sort`, and D5 ("search endpoints do not echo `q`"). `AppliedFilters` stays the ranked-book filter schema.
- **D-c. The category search cap is enforced by loading first.** It loads `BrowseQuery.search` (its own `.limit(60)`, at most 60 rows, each carrying `ranked_count`), then pages `::Books::Category.where(id: ids).in_order_of(:id, ids)`. `book_count` comes from the loaded rows. That is one extra query of at most 60 ids. The spec asked for the cap to survive `render_page`'s `.offset().limit()`.
- **D-d. A list read through a configuration it does not feed is a 200 with `weight: null`.** That is what `/api/v1/lists/{id}` does off the primary, and what the web's `/rc/:id/list/:id` shows. A book's lists through a configuration are **only** that configuration's ranked lists (the spec says so).
- **D-e. `CountryResource` has exactly `slug, name, book_count, url`** (spec).
  - `url` is `Api::Host.base_url` + `::Books::FilterPath.call(countries: [country])`, the web's ranked page for that country.
  - `book_count` counts ranked books on the primary.
  - With no primary configuration, `data` is empty, as with `/api/v1/categories`.

## Review Focus

1. **`q` sent but empty or whitespace on lists** (`?q=`, `?q=%20`). This is a 400 naming `q`, never the unfiltered list (anti-goal: silent ignoring). An absent `q` is the unfiltered list. Owner: Task 1.
2. **Paging a sorted or searched list collection.** `links.next` carries `sort` and `q`, and under a configuration it stays nested. Following it gives page 2 of the same ordering. Owner: Task 1.
3. **Category search with a 1-character, 101-character, or array `q`, or an unknown `type`.** Each is a 400. A query matching more than 60 categories gives `total_count` 60 and pages stop there. Owner: Task 2.
4. **A configuration's book lists when the book is on lists outside that configuration.** Those lists are absent, `total_count` matches the rows, and a list the configuration feeds with a NULL weight comes last. Owner: Task 4.
5. **The bare and the nested form disagree only where they should.** For the same book, `GET /books/{slug}` and `/ranking_configurations/{primary_id}/books/{slug}` give the same `rank`. A configuration where the book is unranked gives `rank: null`, not the primary's rank. Owner: Task 4.

---

### Task 1: Shared parameter parsers; `sort` and `q` on lists

**Files:**
- Modify: `web-app/app/controllers/api/v1/base_controller.rb` (add `text_param!`, `enum_param!`)
- Modify: `web-app/app/controllers/concerns/api/search_backed.rb` (`search_text!` delegates)
- Modify: `web-app/app/controllers/api/v1/books/categories_controller.rb` (`param_in` → `enum_param!`; delete `param_in`)
- Modify: `web-app/app/controllers/api/v1/books/lists_controller.rb` (`index`)
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - add `sort` and `q` to `listLists` and `listRankingConfigurationLists`, with updated descriptions and `x-mcp` text;
  - define the parameters once under `components/parameters` as `list_sort` and `list_q`.
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb`, only if a new status appears (none expected: both operations already document 400)
- Test: `web-app/test/controllers/api/v1/base_controller_test.rb` if one exists, otherwise test through the lists tests; `web-app/test/controllers/api/v1/books/lists_controller_test.rb`

**Interfaces:**
- `Api::V1::BaseController#text_param!(name, required:, min_length: 1, max_length:)` is private. It returns a stripped String, or nil when the parameter is absent and not required. Otherwise it raises `::Api::Page::InvalidParameter` with exactly one of:
  - `"#{name} must be a single value"` (Array or Hash);
  - `"#{name} is required"` (required and absent or blank);
  - `"#{name} must not be blank"` (optional, but sent blank);
  - `"#{name} must be at least #{min_length} characters"`;
  - `"#{name} must be at most #{max_length} characters"`.
- `Api::V1::BaseController#enum_param!(name, allowed)` is private. It returns nil when absent, the value as a String when it is in `allowed`, and otherwise raises `InvalidParameter` with `"#{name} must be one of #{allowed.join(", ")}"`. That is today's `param_in` detail, so the categories tests stay untouched.
- `Api::SearchBacked#search_text!` becomes `text_param!(:q, required: true, max_length: MAX_QUERY_LENGTH)`. Book and author search bodies are unchanged.
- `ListsController#index`:
  - `sort = enum_param!(:sort, ::ListsQuery::SORTS)`;
  - `query = text_param!(:q, required: false, max_length: 200)`;
  - `::Books::ListsQuery.call(ranking_configuration:, sort: sort || "weight", query:)`;
  - links carry `{sort:, q:}.compact`, sent values only.
- OpenAPI:
  - `list_sort` is a string with `enum: [weight, newest]`, default `weight`. `newest` is newest by when the list became active.
  - `list_q` is a string, minLength 1, maxLength 200. It matches the list's name, source or URL, case-insensitively.
  - The `x-mcp` descriptions of `list_lists` and `list_ranking_configuration_lists` mention both.

- [ ] **Step 1: Write the failing tests** in `lists_controller_test.rb`:
  - `"sort=newest orders by activation date, newest first"`
  - `"q narrows to lists whose name, source or url contains it, case-insensitively"`
  - `"sort and q ride on the paging links, and under a configuration the links stay nested"`. Use `per_page=1`, follow `links.next`, and assert the page 2 row.
  - `"an unknown sort is a 400 naming sort"`, `"a blank q is a 400 naming q"` (`q=` and `q=%20`), `"an array q is a 400"`, `"q over 200 characters is a 400"`
  - `"no sort and no q returns exactly today's body"`. Assert the same ids and the same `links.self` as before the change, with no `sort` or `q` in the links.
  - Existing `categories_controller_test.rb` and `book_searches_controller_test.rb` run unedited and green.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/lists_controller_test.rb`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the parsers, the delegation, the categories refactor, the lists change and the OpenAPI edits.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/ test/integration/api/v1/ test/lib/mcp/`. Expected: PASS with no existing test edited.
- [ ] **Step 5: Commit**: `git commit -m "API: lists take sort and q; one text and one enum parser for every endpoint"`

---

### Task 2: `GET /api/v1/search/categories`

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/books/category_searches_controller.rb`
- Modify: `web-app/config/routes.rb`, beside `search/authors`: `get "search/categories", to: "category_searches#index", as: :search_categories`
- Modify: `web-app/config/api/v1/openapi.yaml`, adding path `/api/v1/search/categories` (`searchCategories`)
- Modify: the contract coverage test and the four pin tests (catalogue 21 → 22, directory 22 → 23 / non-composite 21 → 22, developers tool count 22 → 23, path lists)
- Test: `web-app/test/controllers/api/v1/books/category_searches_controller_test.rb`

**Interfaces:**
- Consumes `text_param!` and `enum_param!` (Task 1).
- `#index`:
  1. `query = text_param!(:q, required: true, min_length: ::Books::BrowseQuery::SEARCH_MIN_LENGTH, max_length: ::Books::BrowseQuery::SEARCH_MAX_LENGTH)`, which is 2 and 100.
  2. `type = enum_param!(:type, ::Books::BrowseQuery::TYPES)`.
  3. `configuration = ::Books::RankingConfiguration.default_primary`.
  4. Build `rows` per D-c, then `relation = ::Books::Category.where(id: ids).in_order_of(:id, ids).includes(parent: :merged_into)`. The relation is nil when there is no primary or there are no ids.
  5. `render_page(relation, path: "/api/v1/search/categories", query: {q: query, type: params[:type] && type}.compact)`, with each row `CategoryResource.new(row, params: {book_count: counts.fetch(row.id)})`.
  
  It does **not** include `Api::SearchBacked`: this is Postgres, not OpenSearch.
- OpenAPI `searchCategories` (`books:read`, `x-domain: books`):
  - `q` is required, minLength 2, maxLength 100;
  - `type` uses `enum: [genre, audience, location, subject]` and orders that type first; absent means genre first, as on the web;
  - also `page` and `per_page`;
  - responses: 200 `CategoryCollection`, 400, 401, 403, 429;
  - the description says: at most 60 matches, name matches before alias-only matches, only categories with ranked books, and `book_count` counts ranked books on the primary.
- The `x-mcp` description finds category slugs by name for the `category_id` filter of `list_books` and `list_category_books`. The tool is `search_categories`.
- Also update `list_books`' `x-mcp` text, which currently says "list_categories finds category slugs", to name `search_categories` as well.

- [ ] **Step 1: Write the failing tests.** Use real fixtures. `BrowseQuery.search` is Postgres, so no stubs.
  - `"returns name matches before alias-only matches, with ranked book_count"`
  - `"type orders that type first"`
  - `"links carry q and type"`
  - `"more than 60 matches cap total_count at 60"`. The cap lives in `BrowseQuery.search`'s own `.limit`, and what needs proving is that the controller does not lose it to `render_page`.
    - Create 61 active `::Books::Category` rows in the test.
    - Stub `::Books::BrowseQuery.search` to return `::Books::Category.where(id: those_ids).select("categories.*, 1 AS ranked_count").order(:id).limit(::Books::BrowseQuery::SEARCH_LIMIT)`.
    - Assert `total_count == 60`, and that page 2 at `per_page=50` holds 10 rows.
  - `"a 1-character q, a 101-character q, an array q and a missing q are each a 400 naming q"`
  - `"an unknown type is a 400 naming type"`
  - `"with no primary configuration the result is empty"`
  - 401 and 403
- [ ] **Step 2: Run** the new test file. Expected: FAIL (no route).
- [ ] **Step 3: Implement**, including the OpenAPI path, coverage rows (200, 400, 401, 403, 429) and pin bumps.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/ test/controllers/developers_controller_test.rb test/integration/api/v1/ test/lib/mcp/`. Expected: PASS.
- [ ] **Step 5: Commit**: `git commit -m "API: category search"`

---

### Task 3: `GET /api/v1/countries`

**Files:**
- Create: `web-app/app/lib/api/v1/books/country_resource.rb`
- Create (generator): `web-app/app/controllers/api/v1/books/countries_controller.rb`
- Modify: `web-app/config/routes.rb`: `get "countries", to: "countries#index"`
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - add path `/api/v1/countries` (`listCountries`), plus schemas `Country` and `CountryCollection`;
  - point the `country_id` parameter description and `list_books`' `x-mcp` text at `list_countries` for slugs. The descriptions currently send agents to a book's `countries`.
- Modify: the contract coverage test and the four pin tests (catalogue 22 → 23, directory 23 → 24 / 22 → 23, developers 23 → 24, path lists)
- Test: `web-app/test/controllers/api/v1/books/countries_controller_test.rb`, `web-app/test/lib/api/v1/books/country_resource_test.rb` (follow how `category_resource` is tested, if at all; otherwise test through the controller)

**Interfaces:**
- `Api::V1::Books::CountryResource` is an Alba resource with attributes in this order: `slug`, `name`, `book_count` (`params[:book_count] || 0`), `url` (D-e).
- `#index`:
  - `sort = enum_param!(:sort, ::Books::BrowseQuery::SORTS)`;
  - relation `::Books::BrowseQuery.countries(ranking_configuration: primary, sort:)`, or nil with no primary;
  - `render_ranked_page(relation, path: "/api/v1/countries", query: {sort:}.compact)`, with each row `CountryResource.new(row, params: {book_count: row.ranked_count})`.
- OpenAPI `listCountries` (`books:read`, `x-domain: books`):
  - `sort` with `enum: [book_count, name]`, default `book_count`, plus `page` and `per_page`;
  - responses: 200 `CountryCollection`, 400, 401, 403, 429;
  - the description says countries with ranked books only, `book_count` counts ranked books on the primary, and "unknown" is excluded.
- The `x-mcp` description says it gives country slugs for the `country_id` filter of `list_books`, most books first. The tool is `list_countries`.

- [ ] **Step 1: Write the failing tests**
  - `"returns countries with ranked books, most first, with slug, name, book_count and url"`. Assert `url` equals the base URL plus the web's country path.
  - `"sort=name orders by name"`
  - `"sort rides on the paging links"`
  - `"the unknown country is never listed"`
  - `"an unknown sort is a 400 naming sort"`
  - `"with no primary configuration data is empty"`
  - 401 and 403
- [ ] **Step 2: Run** the new test file. Expected: FAIL.
- [ ] **Step 3: Implement**, including coverage rows (200, 400, 401, 403, 429) and pin bumps.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/ test/controllers/developers_controller_test.rb test/integration/api/v1/ test/lib/mcp/`. Expected: PASS.
- [ ] **Step 5: Commit**: `git commit -m "API: countries index with ranked book counts"`

---

### Task 4: A book, a book's lists and a list through a ranking configuration

**Files:**
- Modify: `web-app/config/routes.rb`, adding beside the other nested configuration routes, each with `constraints: {ranking_configuration_id: /\d+/}`:
  - `get "ranking_configurations/:ranking_configuration_id/books/:slug", to: "books#show", as: :ranking_configuration_book`
  - `get "ranking_configurations/:ranking_configuration_id/books/:slug/lists", to: "book_lists#index", as: :ranking_configuration_book_lists`
  - `get "ranking_configurations/:ranking_configuration_id/lists/:id", to: "lists#show", as: :ranking_configuration_list`, which also takes `id: /\d+/`
- Modify: `web-app/app/controllers/api/v1/books/books_controller.rb` (`show`), `book_lists_controller.rb` (`index`, `listings_for`), `lists_controller.rb` (`show`; `primary_weight` becomes `weight_on(configuration, list)`)
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - add `/api/v1/ranking_configurations/{id}/books/{slug}` (`getRankingConfigurationBook`), `/api/v1/ranking_configurations/{id}/books/{slug}/lists` (`listRankingConfigurationBookLists`) and `/api/v1/ranking_configurations/{id}/lists/{list_id}` (`getRankingConfigurationList`);
  - the last path's second parameter is named `list_id`, because one path cannot declare two `id`s;
  - update the `List.weight` schema description so it names the nested forms.
- Modify: the contract coverage test and the four pin tests (catalogue 23 → 26, directory 24 → 27 / 23 → 26, developers 24 → 27, path lists)
- Test: `books_controller_test.rb`, `book_lists_controller_test.rb`, `lists_controller_test.rb` (add tests only)

**Interfaces:**
- Consumes `ranking_configuration`, `nested_configuration_id` and `collection_path` from `Api::V1::Books::BaseController`. The configuration is resolved **first** in each action, so its 404 wins.
- `BooksController#show`:
  - when nested, `BookResource.new(book, params: {rank: <that configuration's rank for the book, or nil>}, with_traits: :full)`. Read the rank with one query on `RankedItem` (`ranking_configuration_id`, `item`).
  - when bare, unchanged.
- `BookListsController#index`:
  - when bare, unchanged.
  - when nested, `listings_for` INNER JOINs `ranked_lists` on that configuration, so only its lists appear, with its weights. The order is `ranked_lists.weight DESC NULLS LAST, lists.id ASC`. The path is `collection_path("books/#{book.slug}/lists")`.
- `ListsController#show`: the weight is `weight_on(ranking_configuration, list)`. That is the primary when bare (today's behaviour), the named configuration when nested, and nil when the list does not feed it (D-d).
- The `x-mcp` descriptions name `list_ranking_configurations` as the source of `id`. The tools are `get_ranking_configuration_book`, `list_ranking_configuration_book_lists` and `get_ranking_configuration_list`. The last one takes both `id` and `list_id`; say which is which.

- [ ] **Step 1: Write the failing tests** (add to the three existing test files):
  - Book:
    - `"nested show carries that configuration's rank"`
    - `"nested show of a book unranked there has rank null"`
    - `"the primary's id nested gives the same rank as the bare show"`
    - `"an archived, member-owned or unknown configuration is a 404, even for a known book"`
    - `"nested show of an unknown or provisional book is a 404"`
  - Book lists:
    - `"nested lists only that configuration's lists, with its weights, NULL weight last"`
    - `"nested links stay nested"`
    - `"bare lists are unchanged"`. Assert today's ids and weights for a book on lists both in and out of the primary.
  - List:
    - `"nested show carries that configuration's weight"`
    - `"nested show of a list the configuration does not feed has weight null"`
    - `"nested show of an inactive list is a 404"`
    - `"a bad configuration beats an unknown list"`
- [ ] **Step 2: Run** the three files. Expected: the new tests FAIL.
- [ ] **Step 3: Implement**, including coverage rows for the three paths (200, 401, 403, 404, 429, plus 400 for the book lists' page) and pin bumps.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/ test/controllers/developers_controller_test.rb test/integration/api/v1/ test/lib/mcp/`. Expected: PASS, with no existing test edited beyond the pins.
- [ ] **Step 5: Commit**: `git commit -m "API: a book, its lists and a list read through a ranking configuration"`

---

### Task 5: MCP copy, end-to-end tool calls, docs, full verification

**Files:**
- Modify: `web-app/config/mcp/books/usage.md`, `instructions.md`, `ranking_methodology.md`
- Modify: `web-app/test/controllers/api/mcp_controller_test.rb`
- Modify: `docs/features/public-api.md`, and `docs/features/mcp-server.md` only where it names tools or rules that changed

**Interfaces:**
- Consumes the five tools: `search_categories`, `list_countries`, `get_ranking_configuration_book`, `list_ranking_configuration_book_lists`, `get_ranking_configuration_list`.
- Also consumes the `sort` and `q` arguments on `list_lists`.

- [ ] **Step 1: Write the tests** in `mcp_controller_test.rb`. They guard the generated tools end to end; they may pass on first run.
  - `"tools/list includes the category, country and configuration tools"`
  - `"get_ranking_configuration_list fills both path ids"`. Call it with `{id: <config>, list_id: <list>}`, assert the returned list's id, and assert that swapping the two ids gives a 404 error result. This proves `list_id` maps to the right path segment.
  - `"list_lists passes sort and q"`. Call it with `{sort: "newest", q: <fragment>}` and assert the rows are filtered and ordered. Assert the result contents, never just "no error".
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/mcp_controller_test.rb`. Expected: PASS. If a test fails, fix the operation, not the test.
- [ ] **Step 3: Update the copy.**
  - Order rules:
    - `search_categories` is name matches first;
    - `list_countries` is most books first;
    - `list_lists` with `sort=newest` is newest first.
  - Slug discovery: `search_categories` and `list_countries` give the filter slugs.
  - Configuration reads: the `get_ranking_configuration_*` tools answer "where does this rank on configuration X".
  - Keep `test/lib/mcp/sites/books_test.rb` green.
- [ ] **Step 4: Update `docs/features/public-api.md`.** Cover each endpoint, D-a to D-e in plain words, and the lists `sort` and `q` rules. Remove anything listed as not yet done that now exists.
- [ ] **Step 5: Run full verification:**
  - `bin/rails test`: green, with no new warnings;
  - `bundle exec standardrb`: clean;
  - `CI=1 bin/rails zeitwerk:check`: clean;
  - the E2E `yarn test:e2e e2e/tests/books/developers.spec.ts`. First run `yarn build:all`, and confirm port 3000 belongs to this worktree (AGENTS.md). If another checkout holds it, do not kill it; report the run as skipped. Stop any server you started.
- [ ] **Step 6: Commit**: `git commit -m "MCP: category, country and configuration tools in the usage rules; API docs for increment 3"`
