# Public API web parity — increment 2 (authors and similar books) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members can search authors (`GET /api/v1/search/authors`), read an author's books in rank order (`GET /api/v1/authors/{slug}/books`, plus the ranking-configuration form), and get a book's similar books (`GET /api/v1/books/{slug}/similar`). Each one is an MCP tool as well.

**Architecture:**
- The author's books query moves out of `Books::AuthorsController` into `Books::AuthorBooksQuery`. The web pages and the API both call it.
- The book search's `q` validation and its 503 rescue move into one concern, `Api::SearchBacked`. Book search, author search and similar books all include it.
- `Services::Books::SimilarBooks` gains an opt-in `raise_on_failure:`. The API uses it to tell "none" from "search is down". The book page keeps the silent empty card.
- Each new operation carries an `x-mcp` block, so the MCP catalogue (generated from `openapi.yaml`) gains four tools with no MCP code.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, Alba, openapi_first (contract validation), OpenSearch, the `mcp` gem (catalogue generated from OpenAPI `x-mcp`).

**Spec:** `docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md`, increment 2 only. Background reading:
- `docs/features/public-api.md`
- `docs/features/mcp-server.md`
- the MCP spec, `docs/superpowers/specs/2026-11-02-mcp-server-design.md`, for `x-mcp`. That spec says the parity spec does not add `x-mcp`, but it was written before the MCP server existed. Every operation since carries the block, and so do these.

## Global Constraints

- Run every Rails command from `web-app/`. Lint with `bundle exec standardrb`. Do not run rubocop or brakeman.
- Root-anchor model references inside `module Api` (`::Books::Author`, `::Search::Books::Search::AuthorGeneral`). Never create an `Api::Books` module.
- Create a new controller with `bin/rails generate controller api/v1/books/<name> --no-helper --no-assets --skip-routes`, then edit it. Delete any view directory the generator makes. Never hand-create a controller.
- Tests use Minitest 6: `assert_nil`, never `assert_equal nil`. Controller tests assert behaviour (status, `data`, `meta`, `links`, `code`), never copy.
- Every API test request validates against `openapi.yaml`:
  - a success response: `assert_api_conform(status:)`;
  - a deliberately invalid request: `assert_api_response_conform(status:)`.
- Extend the contract coverage gate (`test/integration/api/v1/contract_coverage_test.rb`, `EXERCISES`) for every documented (method, path, status). It fails until you do.
- **No existing response body changes shape** (anti-goal). Only descriptions change: `getAuthor` stops saying "a later addition".
- **Every existing test of the web author pages and the book page passes untouched** (spec, Testing). If one has to change, stop and report it. Do not edit it.
- Search endpoints: at most 100 hits, `q` required and at most 200 characters after stripping, the normal collection envelope, and catalog records only (`.catalog`).
- An OpenSearch outage (`::Search::Shared::Client::UNAVAILABLE_ERRORS`) is a 503 `search_unavailable`. Any other exception is not rescued (spec D8; `Api::ErrorRendering`'s comment says why).
- `x-mcp` keys are `description` only (allowed keys: `name`, `description`, `destructive`). The tool name is the operationId underscored. A description is at least 60 characters, differs from the summary, and names the tools to use next.
- A clean `bin/rails test` prints no new warnings.

## Review Focus

1. **A book the author only edited, or a provisional book.** Neither may appear in `/authors/{slug}/books`, and `total_count` must match the rows. Owner: Task 1 (query) and Task 3 (endpoint).
2. **Paging an author's books under a configuration.** `links.next` must stay on `/api/v1/ranking_configurations/{id}/authors/{slug}/books`, and unranked books must come after every ranked one on every page. Owner: Task 3.
3. **A provisional author or book addressed directly.**
   - `/authors/{slug}/books` for a provisional author: 404.
   - `/books/{slug}/similar` for a provisional book: 404.
   - A provisional author among search hits: dropped, with `total_count` matching.
   - A provisional book the index still returns as similar: dropped.
   Owner: Tasks 2, 3, 4.
4. **`limit` on similar books at its edges:**
   - `0`, `26`, `abc`, `10.5` and `-1` are each a 400 naming `limit`;
   - `25` returns up to 25;
   - no `limit` means 10.
   Owner: Task 4.
5. **Search down while the book page renders.** `BookSimilar` raising `Faraday::ConnectionFailed` makes `/api/v1/books/{slug}/similar` a 503. `GET /book/{slug}` stays a 200 with no similar books. Owner: Task 4.

---

### Task 1: `Books::AuthorBooksQuery`, and the web author pages use it

**Files:**
- Create: `web-app/app/lib/books/author_books_query.rb`
- Modify: `web-app/app/controllers/books/authors_controller.rb` (delete `authored_books`, `ranked_books` and `all_books_relation`; call the query)
- Test: `web-app/test/lib/books/author_books_query_test.rb`

**Interfaces:**
- Produces `Books::AuthorBooksQuery.call(author:, ranking_configuration:, ranked_only: false)`. It returns an `ActiveRecord::Relation` of `Books::Book`, and every row responds to `ranked_position` (Integer or nil).
- Rows are:
  - **authored role only**: `books_book_authors.role = author`, so no editor-only books;
  - **`Books::Book.catalog` only**;
  - preloaded with `{book_authors: :author}` and `{primary_image: {file_attachment: :blob}}`;
  - ordered `ranked_items.rank ASC NULLS LAST, books_books.first_published_year ASC NULLS LAST, title`.
- `ranking_configuration` is any `Books::RankingConfiguration` (the web passes user-owned ones under `/rc/`).
  - When nil, every `ranked_position` is NULL (`NULL::integer`), ordered by year then title.
  - With `ranked_only: true` it is `Books::Book.none`.
- `ranked_only: true` keeps only rows whose rank on that configuration is non-null. This is the author page's list.
- The rank comes from a LEFT OUTER JOIN on `ranked_items` for that configuration id (`.to_i`, as the controller does today). Lift the SQL from the controller; do not write a second version.

- [ ] **Step 1: Write the failing tests** in `test/lib/books/author_books_query_test.rb`. Use fixtures and records created in the test. Look at `test/controllers/books/authors_controller_test.rb:104-140` and `:242` for how they build editor and provisional books.
  - `"ranked books come first in rank order, then unranked by first_published_year then title, each carrying ranked_position"`. Assert the ids in order and `[rank, ..., nil]` for `ranked_position`.
  - `"leaves out a book the author only edited"`.
  - `"leaves out a provisional book"`.
  - `"ranked_only keeps only books ranked on that configuration"`.
  - `"rank is read from the configuration passed, not the primary"`. Use two configurations with different ranks for the same book.
  - `"with no configuration every ranked_position is nil and ranked_only is empty"`.
  - `"count(:all) works on the relation"`. `render_page` counts it this way.
- [ ] **Step 2: Run** `bin/rails test test/lib/books/author_books_query_test.rb`. Expected: FAIL (`NameError: uninitialized constant Books::AuthorBooksQuery`).
- [ ] **Step 3: Implement the query, then switch `Books::AuthorsController`.**
  - `show` uses `ranked_only: true`.
  - `all_books` uses the default.
  - Both pass `@ranking_configuration`.
  - Keep the controller's comment about editor roles, moved onto the query.
- [ ] **Step 4: Run** `bin/rails test test/lib/books/author_books_query_test.rb test/controllers/books/authors_controller_test.rb`. Expected: PASS, with **no edits to the controller test**.
- [ ] **Step 5: Commit**: `git commit -m "Author books: one query for the author pages and the API"`

---

### Task 2: `Api::SearchBacked` and `GET /api/v1/search/authors`

**Files:**
- Create: `web-app/app/controllers/concerns/api/search_backed.rb`
- Modify: `web-app/app/controllers/api/v1/books/book_searches_controller.rb` (use the concern; behaviour unchanged)
- Create (generator): `web-app/app/controllers/api/v1/books/author_searches_controller.rb`
- Modify: `web-app/config/routes.rb` (beside `search/books`): `get "search/authors", to: "author_searches#index", as: :search_authors`
- Modify: `web-app/config/api/v1/openapi.yaml`, adding path `/api/v1/search/authors`
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb`
- Modify: `web-app/test/lib/mcp/admin_catalog_test.rb:108` (public catalogue size 17 → 18)
- Test: `web-app/test/controllers/api/v1/books/author_searches_controller_test.rb`

**Interfaces:**
- `Api::SearchBacked` is an `ActiveSupport::Concern`. It holds:
  - `SEARCH_LIMIT = 100` and `MAX_QUERY_LENGTH = 200`, moved from `BookSearchesController`;
  - the `rescue_from(*::Search::Shared::Client::UNAVAILABLE_ERRORS)` that renders `search_unavailable`, with the log line naming the controller instead of "book search";
  - a private `search_text!`, which returns the stripped `q` String or raises `::Api::Page::InvalidParameter`:
    - `"q must be a single value"` for an Array or Hash;
    - `"q is required"` when blank;
    - `"q must be at most 200 characters"` when longer.
    
    It gives the same 400 bodies book search returns today.
- `BookSearchesController` includes it and calls `search_text!`. Its existing test file passes **untouched**.
- `AuthorSearchesController#index`:
  1. Calls `::Search::Books::Search::AuthorGeneral.call(query, size: SEARCH_LIMIT)` and keeps the hits' ids as integers, unique, in hit order.
  2. Builds `::Books::Author.catalog.where(id: ids).in_order_of(:id, ids)`, including `:primary_ranked_item` and `{primary_image: {file_attachment: :blob}}`. The relation is nil when there are no ids.
  3. Renders `render_ranked_page(relation, path: "/api/v1/search/authors", query: {q: query})`, with each row as a compact `AuthorResource.new(author).to_h`.
- OpenAPI `searchAuthors`:
  - `security: [{bearerAuth: ["books:read"]}]`, `x-domain: books`;
  - the `q` parameter is copied from `searchBooks`, plus `page` and `per_page`;
  - 200 `AuthorCollection`; 400, 401, 403, 429, and 503 `ServiceUnavailable`;
  - the description follows `searchBooks`'s: at most 100 matches, catalog authors only, `rank` from the primary author ranking (null when unranked), 503 on outage.
- The `x-mcp` description says it finds authors by name or alternate name, best match first, and names the next tools: `get_author` for one author, `list_author_books` for their books. The tool is `search_authors`.

- [ ] **Step 1: Write the failing tests.** Stub `::Search::Books::Search::AuthorGeneral.call` the way `book_searches_controller_test.rb` stubs `BookGeneral`, with a `hits(*records)` helper.
  - `"returns the matches in hit order, in the Author shape, with the primary author rank"`
  - `"links carry q and the index is asked for at most 100 hits"`. Use `AuthorGeneral.expects(:call).with("tolstoy", size: 100)`.
  - `"a provisional author and a stale id among the hits are left out, and total_count matches the rows"`
  - `"a missing q is a 400 and never searches"`, `"an array q is a 400"`, `"q over 200 characters is a 400"`
  - `"an unreachable cluster is a 503 search_unavailable"` (`Faraday::ConnectionFailed`)
  - `"an unrelated error is not dressed up as a 503"`. A `NoMethodError` propagates, as in the book search test.
  - `"a token without books:read is refused"` (403) and `"an anonymous request is a 401"`
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/author_searches_controller_test.rb`. Expected: FAIL (no route).
- [ ] **Step 3: Implement** the concern, the refactor, the route, the controller, the OpenAPI path and the coverage rows: 200, 400, 401, 403, 429, 503. Copy `search/books`'s lambdas, stubbing `AuthorGeneral` for 200 and 503. Set the catalogue size to 18.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/books/ test/integration/api/v1/ test/lib/mcp/`. Expected: PASS, with `book_searches_controller_test.rb` unedited.
- [ ] **Step 5: Commit**: `git commit -m "API: author search; book and author search share one q parser and 503"`

---

### Task 3: `GET /api/v1/authors/{slug}/books`, plus the ranking-configuration form

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/books/author_books_controller.rb`
- Modify: `web-app/config/routes.rb`, adding beside the author and configuration routes:
  - `get "authors/:slug/books", to: "author_books#index", as: :author_books`
  - `get "ranking_configurations/:ranking_configuration_id/authors/:slug/books", to: "author_books#index", as: :ranking_configuration_author_books, constraints: {ranking_configuration_id: /\d+/}`
- Modify: `web-app/config/api/v1/openapi.yaml`, adding paths `/api/v1/authors/{slug}/books` (`listAuthorBooks`) and `/api/v1/ranking_configurations/{id}/authors/{slug}/books` (`listRankingConfigurationAuthorBooks`). Also edit `getAuthor`'s `description` and `x-mcp.description`: books are now at `/api/v1/authors/{slug}/books` / `list_author_books`, not "a later addition" or "use search_books".
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/lib/mcp/admin_catalog_test.rb` (18 → 20)
- Test: `web-app/test/controllers/api/v1/books/author_books_controller_test.rb`

**Interfaces:**
- Consumes `Books::AuthorBooksQuery.call(author:, ranking_configuration:)` (Task 1) and `ranking_configuration` / `collection_path` from `Api::V1::Books::BaseController`.
- `#index`:
  1. `configuration = ranking_configuration`. An unknown or archived configuration is a 404 before anything else.
  2. `author = ::Books::Author.catalog.find_by!(slug: params[:slug])`.
  3. `render_ranked_page(AuthorBooksQuery.call(author:, ranking_configuration: configuration), path: collection_path("authors/#{author.slug}/books"))`, with each row as `BookResource.new(book, params: {rank: book.ranked_position}).to_h`.
- Response schema: `BookCollection` (`rank` is nullable there). There are no filter parameters and no `meta.filters`.
- OpenAPI descriptions: authored books only (not edited), ranked books first in rank order, then unranked books (`rank` null) by first publication year then title. In the configuration form, `rank` is relative to that configuration.
- `x-mcp` descriptions:
  - `list_author_books`: the author's whole bibliography in rank order, unranked last; get the slug from `search_authors` or a book's `authors`.
  - `list_ranking_configuration_author_books`: the same on one configuration (an `id` from `list_ranking_configurations`).

- [ ] **Step 1: Write the failing tests**
  - `"returns the author's books, ranked first in rank order then unranked with a null rank"`. Assert ids in order and `rank` values.
  - `"leaves out edited and provisional books, and total_count matches"`
  - `"under a configuration, rank is relative to it and links stay nested"`. Use `per_page=1`, then assert `links.next` starts with `/api/v1/ranking_configurations/#{id}/authors/#{slug}/books`.
  - `"an unknown author is a 404, and so is a provisional one"`
  - `"an archived or unknown configuration is a 404 even for a known author"`
  - `"a bad page is a 400"`
  - `"with no primary configuration every rank is null"`. Follow how existing API tests remove the primary; grep `default_primary` in `test/controllers/api/v1/books/`.
  - `"query count does not grow with the number of books"`. Follow the web test's pattern at `test/controllers/books/authors_controller_test.rb:162`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/author_books_controller_test.rb`. Expected: FAIL (no route).
- [ ] **Step 3: Implement** the routes, the controller, both OpenAPI paths (responses: 200, 400, 401, 403, 404, 429), the `getAuthor` text, the coverage rows for both paths and every status, and the catalogue size of 20.
- [ ] **Step 4: Run** `bin/rails test test/controllers/api/v1/books/ test/integration/api/v1/ test/lib/mcp/`. Expected: PASS.
- [ ] **Step 5: Commit**: `git commit -m "API: an author's books, on the primary ranking or a named configuration"`

---

### Task 4: `GET /api/v1/books/{slug}/similar`

**Files:**
- Modify: `web-app/app/lib/services/books/similar_books.rb`
- Create (generator): `web-app/app/controllers/api/v1/books/similar_books_controller.rb`
- Modify: `web-app/config/routes.rb`: `get "books/:slug/similar", to: "similar_books#index", as: :similar_books`
- Modify: `web-app/config/api/v1/openapi.yaml`, adding path `/api/v1/books/{slug}/similar` (`listSimilarBooks`) and schema `SimilarBookCollection`
- Modify: `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/lib/mcp/admin_catalog_test.rb` (20 → 21)
- Test:
  - `web-app/test/lib/services/books/similar_books_test.rb` (add tests only)
  - `web-app/test/controllers/api/v1/books/similar_books_controller_test.rb`
  - `web-app/test/controllers/books/books_controller_test.rb` (add one test only)

**Interfaces:**
- `Services::Books::SimilarBooks.call(book, raise_on_failure: false, **options)`, and the same keyword on `new`.
  - `raise_on_failure` is kept out of `@options` and `@config`, so it never reaches `BookSimilar`.
  - When true, the rescue re-raises the original exception.
  - When false, behaviour is exactly today's. **Do not narrow the rescue**; its comment says why.
- **Ruling (spec leaves the how to the builder):** `load_books` adds `.catalog`.
  - `BookSimilar` already excludes provisional books in the query, but the index can lag. The API must not serve a provisional book.
  - For the web this is a fix, not a behaviour change.
  - If wrong, the cost is that a provisional book stops appearing on a similar card.
- `SimilarBooksController#index`:
  1. `book = ::Books::Book.catalog.find_by!(slug: params[:slug])`. A 404 beats a bad `limit`.
  2. `limit = ::Api::Page.integer(params[:limit], name: "limit", default: 10, min: 1, max: 25)`.
  3. `result = SimilarBooks.call(book, limit: limit, raise_on_failure: true)`.
  4. Batch-preload `primary_ranked_item` on `result.data[:books]` with `ActiveRecord::Associations::Preloader.new(records:, associations: :primary_ranked_item).call`. This avoids a query per book without changing the service's loads for the web.
  5. Render `{data: books.map { BookResource.new(it).to_h }, meta: {more_available: result.data[:more_available]}}`.
  
  It includes `Api::SearchBacked` for the 503 (Task 2).
- `SimilarBookCollection`: `required: [data, meta]`, `data` an array of `Book`, `meta` an object with `required: [more_available]`, `more_available` a boolean. It has no `links`: the result is a top-N, not paginated (spec).
- `limit` parameter: inline in the operation, integer, minimum 1, maximum 25, default 10.
- OpenAPI description:
  - books like this one, scored from shared genres, subjects and locations;
  - at most two books per author;
  - catalog books only, each with its primary `rank`;
  - `more_available` means the site's similar page would show more;
  - 503 when search is down.
- `x-mcp` description: books similar to one book (slug from `search_books` or `find_book`), most similar first, at most two per author; `limit` up to 25. The tool is `list_similar_books`.

- [ ] **Step 1: Write the failing tests**
  - In `similar_books_test.rb`:
    - `"raise_on_failure re-raises the search error"`;
    - `"raise_on_failure is not passed to the similarity query"` (`BookSimilar.expects(:call).with(@book, Not(has_key(:raise_on_failure)))`);
    - `"a provisional book among the hits is left out"`.
  - API controller tests (stub `::Search::Books::Search::BookSimilar.call`):
    - `"returns the similar books with their primary rank and more_available"`
    - `"limit defaults to 10 and caps the result"`. Use `SimilarBooks.expects(:call).with(book, limit: 10, raise_on_failure: true)` for the default, and real hits for the cap.
    - `"limit 25 is accepted"`
    - `"limit 0, 26, abc, 10.5 and -1 are each a 400 naming limit"`. Loop and assert `detail` includes `"limit"`.
    - `"an unknown or provisional book is a 404"`
    - `"an unreachable cluster is a 503 search_unavailable"`
    - `"an unrelated error is not dressed up as a 503"`
    - `"query count does not grow with the number of similar books"`
    - 401 and 403
  - In `books_controller_test.rb`: `"the book page still renders when the similarity search is down"`. Stub `BookSimilar.call` to raise `Faraday::ConnectionFailed`, `get book_path(...)`, and assert 200.
- [ ] **Step 2: Run** those three files. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the service change, the route, the controller, the OpenAPI path and schema (responses: 200, 400, 401, 403, 404, 429, 503), the coverage rows, and the catalogue size of 21.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/similar_books_test.rb test/controllers/books/ test/controllers/api/v1/books/ test/integration/api/v1/ test/lib/mcp/`. Expected: PASS, with no existing test edited.
- [ ] **Step 5: Commit**: `git commit -m "API: similar books; the service can report a failed search instead of an empty card"`

---

### Task 5: MCP copy, an end-to-end tool call, docs, full verification

**Files:**
- Modify: `web-app/config/mcp/books/usage.md`, `web-app/config/mcp/books/instructions.md`, `web-app/config/mcp/books/ranking_methodology.md`
- Modify: `web-app/test/controllers/api/mcp_controller_test.rb`
- Modify: `docs/features/public-api.md`
- Modify: `docs/features/mcp-server.md`, only if it names the tool set or its order rules

**Interfaces:** Consumes the four tools: `search_authors`, `list_author_books`, `list_ranking_configuration_author_books` and `list_similar_books`.

- [ ] **Step 1: Write the failing tests** in `mcp_controller_test.rb`, using the existing `test/support/mcp_rpc_helpers.rb`:
  - `"tools/list includes the author and similar tools"`. Assert the four names.
  - `"list_similar_books passes limit through to the endpoint"`. Call it with `{slug:, limit: 3}`, stub `BookSimilar`, and assert the result's `data` has at most 3 books and no error. The MCP `limit` rename applies only to `per_page`; this proves the operation's own `limit` survives it.
  - `"list_author_books pages with limit"`. Call it with `{slug:, limit: 1}` and assert `meta.per_page` is 1.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/mcp_controller_test.rb`. Expected: the new tests PASS if Tasks 2-4 are right. They guard against regressions and are not TDD drivers. If one fails, fix the cause in the operation, not the test.
- [ ] **Step 3: Update the copy.**
  - In the order rules of `usage.md`, `instructions.md` and `ranking_methodology.md`:
    - `list_author_books` is ranked first in rank order, then unranked (null `rank`);
    - `search_authors` is best match first;
    - `list_similar_books` is most similar first.
  - In the one-book paragraph of `usage.md`: use `list_author_books` for an author's books instead of searching their name.
  - Keep `test/lib/mcp/sites/books_test.rb` green.
- [ ] **Step 4: Update `docs/features/public-api.md`.**
  - Add the three endpoints with their rules to "Shape" and "Filters and search".
  - Remove "a paginated `/api/v1/authors/{slug}/books` is the planned follow-up" and the "Not yet" entry for it.
  - Note `raise_on_failure` and the `.catalog` ruling.
- [ ] **Step 5: Run full verification.**
  - `bin/rails test`: all green, no new warning lines.
  - `bundle exec standardrb`: clean.
  - `CI=1 bin/rails zeitwerk:check`: the new concern and controllers load.
  - Check port 3000 is this worktree's (AGENTS.md), then `yarn build:all` and `bin/rails server`. Run `yarn test:e2e e2e/tests/books/developers.spec.ts`: green, because `/developers` renders the new operations and tools from the document.
- [ ] **Step 6: Commit**: `git commit -m "MCP: author and similar tools in the usage rules; API docs for increment 2"`
