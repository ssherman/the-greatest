# Public API — ranking configurations, lists, list items, author books

**Date:** 2026-09-20
**Status:** Approved
**Builds on:** `docs/superpowers/specs/2026-09-12-public-api-framework-design.md` (the framework
this rides on; nothing in it changes), `docs/features/public-api.md`

## Summary

The second increment of the books API: four resource families on the framework the first
increment shipped, read-only, behind `books:read`.

```
GET /api/v1/ranking_configurations              global book rankings; primary first
GET /api/v1/ranking_configurations/{id}
GET /api/v1/ranking_configurations/{id}/books   the ranking on that configuration
GET /api/v1/ranking_configurations/{id}/lists   the lists behind it, weight DESC
GET /api/v1/lists                               = the primary configuration's lists
GET /api/v1/lists/{id}                          any active list
GET /api/v1/lists/{id}/items                    its books, position ASC NULLS LAST
GET /api/v1/books/{slug}/lists                  the lists a book is on, with its position
GET /api/v1/authors/{slug}/books                the bibliography, ranked first (D13 of the framework spec)
```

Ranking configurations come first, and lists hang off them, because both numbers a client
wants — a book's `rank` and a list's `weight` — are properties of a (thing, configuration)
pair, not of the thing. `/api/v1/books` stays as it is: the primary configuration's ranking,
now with a sibling that names the configuration.

## Context

### What exists

| Piece | Where | Reused as |
|---|---|---|
| `render_ranked_page(relation, path:)` | `Api::V1::BaseController` | every collection here — it takes any relation and a row block |
| `Api::Page`, `Api::Host`, `Api::Problem` | `app/lib/api/` | pagination, absolute URLs, errors; no new codes |
| `BookResource` with `params[:rank]` | `app/lib/api/v1/books/` | the embedded book in list items and the author-books rows |
| `::Books::RankedBooksQuery.call(ranking_configuration:)` | `app/lib/books/` | `/ranking_configurations/{id}/books`, unchanged |
| `::Books::ListsQuery.call(ranking_configuration:)` | `app/lib/books/lists_query.rb` | both lists indexes; yields `RankedList` rows with `list` preloaded |
| The site's `(/rc/:ranking_configuration_id)` optional scope | `config/routes.rb`, `ApplicationController#load_ranking_configuration` | the pattern for optionally-nested indexes (D2) |
| `Books::AuthorsController#all_books_relation` | `app/controllers/books/authors_controller.rb` | extracted to `Books::AuthorBooksQuery` (D9) |
| The `/developers` page rendered from the OpenAPI document | `app/views/developers/show.html.erb` | documents the new endpoints with no view change |
| `contract_coverage_test.rb` | `test/integration/api/v1/` | the gate: a documented response without a test, or the reverse, fails |

### What the data looks like (development database, 2026-09-20)

Measured with `bin/rails runner`; regenerate before acting on the numbers.

- **Lists have no slug.** The site addresses them as `/lists/:id`. This is the first resource
  the API looks up by id (D4). The framework's slug-only rule (its D12) was about numeric
  slugs colliding with ids, which cannot arise here.
- **758 `Books::List` rows are `active`; 621 are on the primary configuration** ("May 2026",
  id 8) and carry a weight of 1–200 there. Of the other 137, 133 are on the year-specific
  global configurations ("The Best Books of 2024" etc., ids 5–7) and weighted *there*; 4 are
  on no configuration. Active does not imply "on the primary", and a list's weight is only
  meaningful next to a configuration (D1).
- **Position is usually null.** 38,184 of 56,500 items on active books lists have no
  `position`; 497 lists are entirely unordered. The site orders
  `position ASC NULLS LAST, id ASC`. `position: null` is a first-class state (D6).
- **Every item on an active books list resolves to a book today** (`listable_id` null: 0),
  but the model allows null and importers can write mismatched `listable_type`. The items
  query filters both so `total_count` is honest (D6).
- **Ranking configurations on the books host:** four global `Books::RankingConfiguration`
  rows (5, 6, 7, primary 8), one global `Books::Authors::RankingConfiguration` (9), two
  user-owned (10 shared, 11 private). `year` is null on all four book rows — the name carries
  it. Only the primary has `published_at`. `/rc/{id}` renders the ranked page for any global
  configuration, the primary included (no redirect), so it is the `url` for all of them.
- **`list_items.metadata`** holds the importer's raw `title`/`authors` and, on 250 items,
  `score`/`voter_count`. Not exposed (D7).

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Ranking configurations are a resource**, and `/api/v1/books` and `/api/v1/lists` are shortcuts to the primary one. `rank` and `weight` on a collection row mean "on the configuration you read it through"; show uses the primary and is `null` off it. | Both numbers belong to the pair. Without the resource, `/api/v1/lists` has to pretend the primary configuration is the only one, and the 133 lists weighted on the year rankings have no honest address. `rank` already works this way. |
| D2 | **One index action, optionally nested.** `BooksController#index` serves `/api/v1/books` and `/api/v1/ranking_configurations/{id}/books`; `ListsController#index` likewise. `Api::V1::Books::BaseController` resolves the configuration from the path or falls back to the primary. | The site's `(/rc/:id)` optional scope is the same idea and the team already reads it. Dedicated `RankingConfigurationBooksController` etc. would be copies with a different lookup. |
| D3 | **Only `global`, unarchived, `Books::RankingConfiguration` rows are addressable**; index and show share the scope. A user's configuration (shared or not), an archived one, or the authors configuration is a 404. `kind` is in the payload from day one, always `"books"` on this host. | Private configurations must never leak through a member token. `kind` makes adding `"authors"` rows and `/{id}/authors` later purely additive, and music needs it on day one (albums vs songs). |
| D4 | **Lists and configurations are looked up by integer id** with a `/\d+/` route constraint. Unknown id → 404 `not_found` problem; non-numeric → routing 404. | Lists have no slug. Without the constraint `find("12abc")` casts to 12 and answers for the wrong row. A routing 404 for a malformed address is the class the framework already chose for `.xml`. |
| D5 | **`GET /api/v1/lists/{id}` answers for any active list**, weight from the primary or `null`. `GET /api/v1/lists` is the primary's lists only. | Mirrors the site: `/lists` shows the ranked ones, `/lists/:id` renders any active list. |
| D6 | **List items are `{position, book}`**, `position` nullable, ordered `position ASC NULLS LAST, id ASC`, restricted to rows whose listable is a `Books::Book` that exists. | The site's order. Filtering in the relation keeps `total_count`, `per_page` and the rows consistent; skipping in the serializer would not. |
| D7 | **`GET /api/v1/books/{slug}/lists` returns every active list the book is on**, weight from the primary or `null`, ordered `weight DESC NULLS LAST, lists.id`. Rows are `{position, list}`. | A book on "100 Notable Books of 2024" would otherwise be unable to see that list from its side while `/lists/{id}` serves it. Null-weight rows are self-describing. |
| D8 | **`GET /api/v1/authors/{slug}/books` is the full bibliography**, author role only, ordered `rank ASC NULLS LAST, first_published_year ASC NULLS LAST, title`; compact `Book` rows with `rank` on the primary. | The site's "all books" page. Ranked-only would hide most of a prolific author's work; rank-first keeps the useful rows on page one. |
| D9 | **Extract `Books::AuthorBooksQuery`** from `Books::AuthorsController#all_books_relation` and have the site call it. | Copying the relation into the API leaves two definitions of "an author's bibliography" to drift. The extraction changes no SQL. |
| D10 | **Left out of the contract on purpose:** the configuration's algorithm parameters (`exponent`, `bonus_pool_percentage`, `min_list_weight`, `list_limit`, the dates-penalty settings); the list's editorial flags (`high_quality_source`, `category_specific`, `location_specific`, `creator_specific`, `voter_count_*`, `estimated_quality`) and `calculated_weight_details`; `list_items.metadata` and `verified`. | The contract is additive-only, so adding is free and removing is not. These are inputs to the weight and internals whose shape still moves, not facts about the resource. |
| D11 | **No new problem codes, no new scopes, no new parameters beyond `page`/`per_page`.** No sort, no search. | Search and filters have their own spec slot in the framework document. |

## Design

### 1. Routes

Inside the books `namespace :v1, module: "api/v1/books"` block, after the two existing
`resources` lines. Nested paths are explicit `get` lines so that every `/\d+/` constraint
names the param actually in that path — a `constraints:` on the parent `resources` binds
`:id`, not the `:list_id` a nested route carries:

```ruby
get "books/:slug/lists", to: "book_lists#index"
get "authors/:slug/books", to: "author_books#index"
resources :lists, only: [:index, :show], constraints: {id: /\d+/}
get "lists/:list_id/items", to: "list_items#index", constraints: {list_id: /\d+/}
resources :ranking_configurations, only: [:index, :show], constraints: {id: /\d+/}
get "ranking_configurations/:ranking_configuration_id/books", to: "books#index",
  constraints: {ranking_configuration_id: /\d+/}
get "ranking_configurations/:ranking_configuration_id/lists", to: "lists#index",
  constraints: {ranking_configuration_id: /\d+/}
```

The `defaults: {format: :json}, constraints: {format: :json}` on the enclosing `namespace :api`
still applies, so `.xml` on any of these is a routing 404 as before.

### 2. Controllers

All under `Api::V1::Books::BaseController` (`books:read`). Two additions to that base:

```ruby
# The configuration an index reads: the one named in the path when nested under
# /ranking_configurations/{id}, else the site's primary (nil when there is none yet).
# Only global, unarchived book configurations are addressable -- a member's own,
# an archived one, or the authors configuration is a 404 (spec D3).
def ranking_configuration
  if params[:ranking_configuration_id]
    ::Books::RankingConfiguration.global.active.find(params[:ranking_configuration_id])
  else
    ::Books::RankingConfiguration.default_primary
  end
end

# The base path for `links`: the nested form when the request came in nested.
def collection_path(suffix)
  if params[:ranking_configuration_id]
    "/api/v1/ranking_configurations/#{params[:ranking_configuration_id]}/#{suffix}"
  else
    "/api/v1/#{suffix}"
  end
end
```

Every nested action loads its parent before `Api::Page` parses the page params, so a
missing parent is a 404 even when `page=0` — the answer is about the address, not the
query. Then it builds the relation:

| Controller | Action | Parent | Relation | Row |
|---|---|---|---|---|
| `RankingConfigurationsController` | `index` | — | `::Books::RankingConfiguration.global.active.order(primary: :desc, created_at: :desc, id: :desc)` | `RankingConfigurationResource` with `item_count`/`list_count` params |
| | `show` | — | `.global.active.find(params[:id])` | same — one shape, no trait |
| `BooksController` | `index` | `ranking_configuration` (helper) | `::Books::RankedBooksQuery.call(ranking_configuration:)` (nil → empty page, as today) | unchanged |
| `ListsController` | `index` | `ranking_configuration` (helper) | `::Books::ListsQuery.call(ranking_configuration:)` (nil → empty page) | `ListResource.new(ranked_list.list, params: {weight: ranked_list.weight, item_count:})` |
| | `show` | — | `::Books::List.active.find(params[:id])` | `ListResource` `:full`; weight from `primary.ranked_lists.find_by(list:)&.weight`, nil when there is no primary |
| `ListItemsController` | `index` | `::Books::List.active.find(params[:list_id])` | `list.list_items.by_listable_type("Books::Book").with_listable.includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}]).order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC"))` | `{position:, book: BookResource.new(item.listable, params: {rank:}).to_h}` |
| `BookListsController` | `index` | `::Books::Book.find_by!(slug:)` | `::ListItem.where(listable: book).joins(:list).where(lists: {type: "Books::List", status: ::List.statuses[:active]})`, `.includes(:list)`, and when a primary exists a `LEFT OUTER JOIN ranked_lists ON ranked_lists.list_id = lists.id AND ranked_lists.ranking_configuration_id = <primary>` with `.select("list_items.*, ranked_lists.weight AS weight")`, ordered `ranked_lists.weight DESC NULLS LAST, lists.id ASC`; with no primary, no join, `NULL::integer AS weight`, ordered `lists.id ASC` | `{position:, list: ListResource.new(item.list, params: {weight: item.weight, item_count:}).to_h}` |
| `AuthorBooksController` | `index` | `::Books::Author.find_by!(slug:)` | `::Books::AuthorBooksQuery.call(author:, ranking_configuration: primary)` | `BookResource.new(book, params: {rank: book.ranked_position}).to_h` |

Counts and ranks are batched per page, never per row:

- `item_count` for a page of lists: `::ListItem.where(list_id: ids).by_listable_type("Books::Book").with_listable.group(:list_id).count`
  — the same predicate as `/lists/{id}/items`, so `item_count` always equals that endpoint's
  `total_count`. (`PublicListsController#index` counts every row; the API counts what it serves.)
- `item_count`/`list_count` for configurations: `::RankedItem.where(ranking_configuration_id: ids).where.not(rank: nil).group(:ranking_configuration_id).count`
  and the same over `::RankedList`.
- `rank` for the books embedded in list items: `::RankedItem.where(ranking_configuration: primary, item_type: "Books::Book", item_id: ids).pluck(:item_id, :rank).to_h`,
  passed as `params[:rank]` — `BookResource` falls back to `primary_ranked_item` per row only
  when the param is absent, and here it is never absent.

`render_ranked_page` counts the relation and skips the offset query past the last page; the
batched lookups run on the page's ids, so an empty page issues no lookups.

**Root-anchoring.** Every constant inside `Api::V1::Books` is written `::Books::List`,
`::List`, `::ListItem`, `::RankedItem`, `::RankedList`. `ListsController` is the sharp case:
a bare `List` resolves (there is no `Api::V1::Books::List`) but a bare `Books::List` raises
`NameError`. The controller tests exercise every reference.

### 3. `Books::AuthorBooksQuery` (D9)

`app/lib/books/author_books_query.rb`, next to `RankedBooksQuery`:

```ruby
Books::AuthorBooksQuery.call(author:, ranking_configuration:)  # -> Books::Book relation
```

Body: the current `all_books_relation` verbatim — `author.books` restricted to
`books_book_authors.role = author`, `preload({book_authors: :author}, {primary_image: {file_attachment: :blob}})`,
and either the `NULL::integer AS ranked_position` branch (nil configuration) or the
LEFT OUTER JOIN on `ranked_items` with `ranked_items.rank AS ranked_position` and the
three-key order. `Books::AuthorsController#all_books` calls it; its private
`all_books_relation` goes away. `ranked_books` (the show page's ranked-only list) stays where
it is — it is a different query and not this spec's concern.

### 4. Payloads

Key order is the OpenAPI order. `url` is the site page, `api_url` this resource, absolute,
built from `Api::Host.base_url` — the framework's rule.

**`RankingConfiguration`** — `Api::V1::Books::RankingConfigurationResource`, one shape:

```
id, name, kind, primary, year, description, published_at, last_refreshed_at,
item_count, list_count, url, api_url, books_api_url, lists_api_url
```

`kind` is `"books"`. `year` is nullable. `url` is `https://<host>/rc/{id}`.

**`List`** — `Api::V1::Books::ListResource`, compact by default, `:full` for show:

```
compact: id, name, source, year_published, yearly_award, number_of_voters,
         item_count, weight, activated_at, url, api_url, items_api_url
full:    + description, source_url
```

`source_url` is the `lists.url` column (the original list on the web); `url` is
`https://<host>/lists/{id}`. `weight` nullable (D1, D5). `year_published`, `number_of_voters`,
`source`, `activated_at` nullable — present on every active list today, but the columns allow null.

**List item row** (`/lists/{id}/items`): `{"position": 12, "book": {…compact Book…}}`,
`position` nullable.

**Book listing row** (`/books/{slug}/lists`): `{"position": 12, "list": {…compact List…}}`,
`position` nullable.

**Author books rows**: compact `Book`, `rank` nullable.

Collections use the framework envelope (`data`, `meta`, `links`) unchanged.

### 5. Contract

`config/api/v1/openapi.yaml` gains nine path items, all `x-domain: books`, and these
components: schemas `RankingConfiguration`, `RankingConfigurationCollection`,
`RankingConfigurationItem`, `List`, `ListFull`, `ListCollection`, `ListItem`, `ListItemRow`,
`ListItemCollection`, `BookListingRow`, `BookListingCollection`; parameter `id` (path,
integer, minimum 1) beside `slug`, plus `ranking_configuration_id` and `list_id` for the
nested paths. Every operation carries the six rate-limit response headers and 400/401/403/429;
the ones with a parent or an id (`/ranking_configurations/{id}`, its two sub-collections,
`/lists/{id}`, `/lists/{id}/items`, `/books/{slug}/lists`, `/authors/{slug}/books`) add 404.
Index operations without a parent (`/ranking_configurations`, `/lists`) do not document 404.

`/developers` renders its endpoint reference from this document, so the new operations
appear there with no view work. The `summary` lines are written to read well in that table;
the copy pass covers them.

### 6. Errors

No new codes. Unknown numeric id → 404 `not_found` (`ActiveRecord::RecordNotFound`, already
rescued). Non-numeric id → routing 404 (constraint, D4). Bad `page`/`per_page` → 400
`invalid_parameter`, after the parent lookup. Unauthenticated, wrong scope, rate-limited —
the framework's, untouched.

## Testing

Minitest + fixtures + Mocha, mirroring `app/`. No books list fixture is `active` today and
none is on `books_global` as active, so the lists tests set status and create `RankedList`
rows in `setup` rather than reshaping fixtures other suites depend on.

- **`RankingConfigurationsController`**: index order (primary first), scope (a user-owned
  configuration — shared or not — an archived one, and the authors configuration are absent
  from the index and 404 on show), counts, `kind`, `url` shape, pagination edges,
  `assert_queries_count`, `assert_api_conform`.
- **`BooksController` nested**: the same rows as `/api/v1/books` when `{id}` is the primary;
  different rows on another configuration; `links` carry the nested path; 404 on a private
  configuration even with `page=0`.
- **`ListsController`**: index = the configuration's active lists, weight DESC, id tiebreak,
  excluding active lists not on it and inactive lists on it; nested on a year configuration
  returns that configuration's weights; show answers for an active list off the primary with
  `weight: null`, 404 for an unapproved list, `item_count` equals the items endpoint's `total_count`.
- **`ListItemsController`**: `NULLS LAST` on position with id tiebreak; a null-listable row
  and a wrong-type row are neither counted nor returned; `rank` is the primary's and is null
  for an unranked book; one query batch for ranks (`assert_queries_count`).
- **`BookListsController`**: includes an active list off the primary with `weight: null`,
  ordered after the weighted ones; excludes an unapproved list; `position` carried; 404 on
  an unknown slug; the no-primary branch answers with every weight null.
- **`AuthorBooksController`**: ranked before unranked, year then title within unranked;
  editor-role books excluded; empty page when the author has no books; the nil-configuration
  branch (unset `primary` on the fixture) still orders by year.
- **`Books::AuthorBooksQuery`**: unit tests for both branches and the role filter;
  `test/controllers/books/authors_controller_test.rb` passes untouched.
- **`contract_coverage_test.rb`**: one `EXERCISES` entry per documented response.
- **E2E**: one `page.request.get` per new family in
  `e2e/tests/books/member/developers-tokens.spec.ts` — `/ranking_configurations`, `/lists`,
  and `/authors/{slug}/books` with the slug taken from `authors[0].slug` of the first
  `/api/v1/books` row — asserting 200. Proof the routes exist on the real host, nothing
  about the payload.
- `CI=1 bin/rails zeitwerk:check`, `bundle exec standardrb`, no new warning lines.

## Increments

One PR each, green on `bin/rails test` and `standardrb` before the next starts.

1. **Ranking configurations.** `RankingConfigurationResource`, `RankingConfigurationsController`,
   the two `BaseController` helpers, the nested `books#index` route, contract entries,
   coverage entries, tests, the E2E call.
2. **Lists.** `ListResource`, `ListsController`, `ListItemsController`, `BookListsController`,
   the nested `lists#index` route, contract, coverage, tests, the E2E call.
3. **Author books.** `Books::AuthorBooksQuery` extraction with the site controller switched
   over, `AuthorBooksController`, contract, coverage, tests, the E2E call. Update
   `docs/features/public-api.md` (the "Not yet" line and the D13 pointer) and the framework
   spec's D13 row to point here.

## Out of scope

- A member reading their own or a shared user configuration through the API.
- `kind: "authors"` configurations and `/ranking_configurations/{id}/authors`.
- Algorithm parameters on the configuration payload.
- `sort` on lists (the site has `weight`/`newest`), search, filters — the framework spec's
  search/filter slot.
- The weight breakdown (`calculated_weight_details`).
- Music and games resources.
