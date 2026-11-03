# Public API: web parity — design

Date: 2026-11-02. Builds on the public API (`docs/superpowers/specs/2026-09-12-public-api-framework-design.md`),
the lists/rankings increment (`docs/superpowers/specs/2026-09-20-public-api-lists-and-rankings-design.md`) and
the categories API (`docs/superpowers/specs/2026-11-02-categories-api-design.md`, merged as PR #442). Read
`docs/features/public-api.md` first.

This spec is the prerequisite for the MCP server (`docs/superpowers/specs/2026-11-02-mcp-server-design.md`):
MCP tools are generated from the API, so anything an agent should be able to do has to exist here first.

## Intent

Shane: "the API/MCP should support all the same parameters the web does." Today the public API accepts
`page` and `per_page` on every collection, plus `type` and `sort` on `/api/v1/categories`, and silently
ignores everything else. A member cannot search, cannot filter the ranking by country or year, and cannot
read an author's books. The website can do all of that.

A read-only survey of every public books page against the API (2026-11-02) found the gaps below. Shane
agreed the cut: the items under "Goals" are in, the items under "Non-goals" are out.

## Goals

1. **Search.** Members can search books (what `/search` does) and authors (which the public web does not
   offer, but Shane asked for it; the admin API already searches authors).
2. **Ranked-list filters.** Every filter the ranked index accepts on the web — several categories,
   countries, a year or year range, a collection — works on the API's ranked book collections, on the
   primary ranking and on any global ranking configuration.
3. **An author's books.** The books an author wrote, in rank order, ranked and unranked.
4. **Similar books** for a book.
5. **Lists** sort and text search.
6. **Category search** and a **countries index** with ranked book counts.
7. **Ranking configuration on single records.** A book's rank, a book's lists, a list's weight, an
   author's book ranks and a category's books follow a chosen global ranking configuration, as they do
   under `/rc/:id/...` on the web.
8. Every change is in `config/api/v1/openapi.yaml`, validated by `openapi_first` in the integration
   tests, and visible on `/developers` (which renders from that document).

## Non-goals

- Global canon (`/global-canon`), filter facets and counts (`/filters/categories`, `/filters/countries`,
  `/filters/count`). Website features, not data an agent needs. `meta.total_count` on a filtered
  collection already answers "how many".
- Scores (book or author) and ranking-algorithm internals. The September spec left these out on purpose.
- Reviews and review summaries. Other users' content; a separate policy decision.
- CSV export or any bulk endpoint.
- User-owned ranking configurations. The API stays limited to `global.active` configurations
  (`Api::V1::Books::BaseController#ranking_configuration`). The web also accepts archived global ones;
  the API does not, and this spec does not change that.
- Provisional books and authors. The API serves `.catalog` only, as today.
- An author's top five books embedded in `/api/v1/authors` rows. `GET /api/v1/authors/{slug}/books`
  covers the need with one call per author.
- The MCP server itself.
- Music and games. Only books ships, but nothing new may assume books forever (same rule as the
  categories spec).

## Anti-goals

- **A second filter parser.** `Books::FilterParams` is the one place that turns filter input into
  records. The API calls it; it does not reimplement slug splitting, limits, merged-slug resolution or
  year validation.
- **Web logic copied into API controllers.** Where the web controller holds the query (the author's
  books today lives in private methods of `Books::AuthorsController`), lift it into a query object both
  call. Same rule the categories spec applied to tagging.
- **Silently ignored parameters.** A filter the API accepts is validated; a malformed value is a 400
  naming the parameter, never "ignored and returned the unfiltered list".
- **An empty 200 that means "search is down".** An OpenSearch failure must not look like "no results".
- **Changing existing response shapes.** Every current endpoint keeps its current body. New behaviour is
  new parameters and new paths.

## Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | Filter parameter names are the web's query-string names from `Books::FilterParams`: `category_id`, `country_id`, `year`, `published_start`, `published_end`, plus `collection`. `category_id` and `country_id` take comma-separated **slugs**, as on the web. | One spelling per filter across the site and the API. The web's ranked pages carry filters as path segments; these are the names its CSV export links and `FilterParams` use (`ranked_items_controller.rb:126-139`). The `_id` name holding slugs is a wart, accepted for consistency (a recommendation from the review session Shane consulted; my call to adopt it). |
| D2 | Filter semantics are the web's: categories AND together (max 6), countries OR together (max 10), years filter on `first_published_year` within -4000..(current year + 5). `year` sets both ends. | Parity. The rules already live in `FilterParams` and `RankedBooksQuery`. |
| D3 | Malformed input is a 400 `invalid_parameter`; a **filter-parameter** slug (`category_id`, `country_id`) that names nothing is a 404 `not_found` whose `detail` names that parameter and slug (its own exception and handler). Unknown **path** resources (an author, a book, a configuration) keep the shared handler's existing body, which deliberately names neither (`app/controllers/concerns/api/error_rendering.rb:16-23`); a merged or renamed category slug resolves silently to its target (no redirect). Sending `year` together with `published_start` or `published_end` is a 400. `collection` is a closed set of six values, so an unknown one is a 400 like a bad `sort` (corrected while planning: D3 and the Testing list disagreed). | API convention (the web 404s everything and 301s merged slugs; neither fits an API). |
| D4 | `FilterParams` grows distinct error classes so callers can tell "malformed" from "unknown". The web keeps mapping both to 404, unchanged. | Anti-goal: one parser. The web's behaviour must not move. |
| D5 | A collection that received at least one filter parameter echoes it in `meta.filters`; an unfiltered request's body is unchanged (no `filters` key). Keys are the request parameter names that were sent; values are in request form with canonical slugs (`category_id: "russian-literature,novels"`, a merged slug replaced by its target's); `year` is echoed as `year`, not expanded into a range; `collection` is included. On `/categories/{slug}/books` the path category is not echoed. Search endpoints do not echo `q` (their `links` carry it). The paging `links` carry the filters in the same form. Defined once as a shared `AppliedFilters` schema in `openapi.yaml`, referenced from the filtered collections' meta. *(My call, settled after the builder check.)* | A client that sent an old slug learns the new one; `next` must not drop the filters (the bug Codex caught on #442's paging links); the existing unfiltered contract does not move. |
| D6 | Search lives under `/api/v1/search/`: `GET /api/v1/search/books?q=`, `/api/v1/search/authors?q=`, `/api/v1/search/categories?q=`. | `/api/v1/books/search` would collide with `/api/v1/books/{slug}` for any book slugged "search", and the same for categories. One namespace for all three. |
| D7 | Search results use the normal collection envelope (`page`, `per_page`, `meta`, `links`) over a capped hit list: at most 100 hits per query. | One envelope for every collection. The web shows 50; admin search caps at 1000. 100 = one full page at max `per_page`. |
| D8 | An OpenSearch failure on any search or similar-books endpoint is a **503** with a new problem code `search_unavailable`. | Anti-goal: empty is not "down". `Api::Problem` deliberately has no 500s (a 500 is a bug); a search outage is not a bug, it is a dependency being down, and 503 tells a client to retry. |
| D9 | `ranking_configuration` on single records is the existing nested-path form: `/api/v1/ranking_configurations/{id}/...`, never a query parameter. | `Api::V1::Books::BaseController#nested_configuration_id` reads the path only on purpose (its comment explains why). Same pattern as the existing nested books and lists indexes. |
| D10 | `country_id` together with `collection` is a 400. | The web's ranked index silently ignores the country on collection pages (its CSV export applies both; the inconsistency is the web's). Anti-goal: silent ignoring. |

## Endpoints

All on the books host, all `books:read`, all JSON, all in `openapi.yaml` with `x-domain: books`.
"RC" below means each path also exists under `/api/v1/ranking_configurations/{id}/` and then reads that
global, active configuration instead of the primary.

### Increment 1 — search and ranked-list filters

| Endpoint | Parameters | Backed by |
| --- | --- | --- |
| `GET /api/v1/search/books` | `q` (required, non-blank), `page`, `per_page` | `Books::BookSearchQuery` (the `/search` page's query: standalone books). Its size becomes the 100-hit cap. Rank comes from the primary, as on the web. Provisional books are excluded only inside the OpenSearch query; the hydrate step has no `.catalog`, so the API must apply `.catalog` itself (a stale index must not leak a provisional book). Whether the web's `/search` also gains it is the builder's call; it would be a fix, not a regression. |
| `GET /api/v1/books` (+ RC, which exists already) | adds `category_id`, `country_id`, `year`, `published_start`, `published_end`, `collection` | `Books::FilterParams` → `Books::RankedBooksQuery.call(ranking_configuration:, categories:, countries:, year_start:, year_end:, collection:)`. `collection` is a slug from `Books::CollectionsRegistry` (women, africa, asia, latin-america, western, non-western). |
| `GET /api/v1/categories/{slug}/books` (+ RC, new) | the same filters; the path category is ANDed with any `category_id` | Same query; the path category counts toward the 6-category limit. |

Plus: `FilterParams` error classes (D4); `search_unavailable` problem (D8) with its `/developers#errors-search_unavailable` anchor; `meta.filters` (D5).

### Increment 2 — authors and similar books

| Endpoint | Parameters | Backed by |
| --- | --- | --- |
| `GET /api/v1/search/authors` | `q`, `page`, `per_page` | `Search::Books::Search::AuthorGeneral`, hydrated and filtered to `Books::Author.catalog` (the index includes provisional authors; the public API must not). |
| `GET /api/v1/authors/{slug}/books` (+ RC) | `page`, `per_page` | A new shared query (builder names it, e.g. `Books::AuthorBooksQuery`) lifted from `Books::AuthorsController#authored_books` / `#all_books_relation`: authored role only, catalog only, ordered rank ASC NULLS LAST, then `first_published_year`, then title. Unranked books carry `rank: null`. The web's author page and all-books page switch to the shared query. |
| `GET /api/v1/books/{slug}/similar` | `limit` 1–25, default 10 | `Services::Books::SimilarBooks` (author cap of 2 included). Not paginated: the similarity query is a top-N, not a collection. Body: `{data: [BookResource...], meta: {more_available:}}`. |

`SimilarBooks` rescues every error and returns empty, deliberately, and its comment says not to narrow
that rescue. The API needs to tell "no similar books" from "search failed" (D8) without changing what the
book page does. How (a result flag, an error in `errors`, an opt-in option) is the builder's call, as long
as the web's behaviour is unchanged.

### Increment 3 — lists, categories, countries, ranking configuration on records

| Endpoint | Parameters | Backed by |
| --- | --- | --- |
| `GET /api/v1/lists` (+ RC, exists) | adds `sort` (`weight` default, `newest`; anything else 400) and `q` | `Books::ListsQuery.call(ranking_configuration:, sort:, query:)` |
| `GET /api/v1/search/categories` | `q` (required, 2–100 chars; outside that range is a 400 — the web trims and returns empty, which the no-silent-ignoring anti-goal rules out), `type` (one of `BrowseQuery::TYPES`; orders that type first, as the web's `filter` param does; named `type` to match `/api/v1/categories`), `page`, `per_page` | `Books::BrowseQuery.search`, capped at its own 60 hits as on the web. `render_page`'s `.offset().limit()` replaces the query's `.limit(60)`, so the cap must be enforced another way (builder's how). *(My call.)* |
| `GET /api/v1/countries` | `sort` (`book_count` default, `name`), `page`, `per_page` | `Books::BrowseQuery.countries`. New `CountryResource`: `slug`, `name`, `book_count` (ranked books on the primary), `url`. |
| `GET /api/v1/ranking_configurations/{id}/books/{slug}` | — | `getBook` with `rank` from that configuration. |
| `GET /api/v1/ranking_configurations/{id}/books/{slug}/lists` | `page`, `per_page` | Only lists in that configuration's ranked lists, its weights, as the web's `/rc/:id/book/:slug` does. The un-nested endpoint keeps today's behaviour (every active list, primary weight first). |
| `GET /api/v1/ranking_configurations/{id}/lists/{id}` | — | `getList` with that configuration's weight. |

## Errors

Unchanged machinery (`Api::Problem`, `Api::ErrorRendering`). New: `search_unavailable` (503). Every new
400 names the parameter in `detail`. A 404 for an unknown filter slug names the parameter and slug; a 404
for an unknown path resource keeps today's shared body (D3).

## Testing

As every API increment: integration tests validated by `openapi_first`, the contract coverage gate
(`test/integration/api/v1/contract_coverage_test.rb`) extended to the new operations, controller tests
assert behaviour only. Specifically:

- Each filter alone and combined, on the primary and nested under a configuration; `meta.filters` and
  `links` carry the canonical values; a merged category slug resolves.
- Each 400 (malformed year, year with a range, 7 categories, 11 countries, unknown collection, country
  with collection, blank `q`, bad `sort`) and each 404 (unknown category/country slug, unknown
  configuration, archived configuration).
- The web's ranked index, author page and all-books page are unchanged after the `FilterParams` and
  author-books refactors: their existing tests pass untouched, and any test that has to change is a red
  flag to raise, not to edit.
- OpenSearch down → 503 `search_unavailable` on search and similar, while the book page still renders
  with an empty similar card.
- Search tests stub OpenSearch the way `Books::BookSearchQuery`'s and the admin search tests already do;
  no second convention.

No new user-facing page, so no new Playwright spec; `/developers` renders the new operations from the
document, and its existing E2E must stay green.

## Docs

`docs/features/public-api.md` gains each endpoint and the filter rules; `/developers` updates itself from
the OpenAPI document. The `x-mcp` extension is **not** added here; the MCP spec adds it.

## Left to the builder

- Names: the author-books query object, the `FilterParams` error classes, how `SimilarBooks` reports
  failure (within the constraint above).
- Whether `GET /api/v1/categories/{slug}` (the single category) also gains the RC form. Not required;
  its `book_count` is on the primary today.
- Exact `per_page` default for search (the API default is 50; anything ≤ 100 is fine).
- Increment boundaries may move if a PR gets too big, as long as increment 1 (search + filters) ships
  first: the MCP server's first increment depends on it.
