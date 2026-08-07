# Books legacy `/genres` routes — design

**Date:** 2026-08-07
**Status:** approved, not yet implemented
**Supersedes:** nothing. Extends `2026-08-05-books-filters-rework-design.md`, which shipped
`/genres` and `/countries` but left the rest of the legacy grammar 404ing.

## 1. Goal

Make every legacy `/genres` and `/countries` URL resolve on the new app, without a redirect
where a redirect is avoidable, before books cutover.

Today `/genres` and `/countries` return 200 and everything else in both families returns 404:

```
200  /genres
404  /genres/fiction
200  /genres/page/2
404  /genres/sorted-by/name
404  /genres/filtered-by/location
404  /genres/filtered-by/subject/sorted-by/name
404  /genres/search
404  /genres/page
```

`/genres` is hardcoded in the legacy navbar (`app/views/shared/_navbar.html.erb:36` and `:118`),
so it has carried sitewide internal links for roughly a decade on a site serving millions of
views a day. `/genres/filtered-by/...` and `/genres/sorted-by/...` are linked from that page.
This is live, indexed surface, and it breaks the moment the domain points at the new app.

## 2. What legacy actually is

`config/routes.rb:271` in `the-greatest-books/admin`:

```ruby
resources :categories, only: [:index, :show], path: "genres" do
  collection do
    get "sorted-by/:sort",                   action: :index, as: :sorted_by
    get "filtered-by/:filter",               action: :index, as: :filtered_by
    get "filtered-by/:filter/sorted-by/:sort", action: :index, as: :filtered_and_sorted_by
    get "search"
  end
end

resources :countries, only: [:index] do
  collection do
    get "sorted-by/:sort", action: :index, as: :sorted_by
    get "search"
  end
end
```

| Legacy path | Legacy behaviour |
|---|---|
| `/genres` | index; `sort` defaults `book_count`, `filter` defaults `genre` |
| `/genres/sorted-by/:sort` | index; `sort` ∈ `name`, `book_count` |
| `/genres/filtered-by/:filter` | index; `filter` ∈ `genre`, `location`, `subject` |
| `/genres/filtered-by/:filter/sorted-by/:sort` | index, both axes |
| `/genres/:id` | `BookListQuery.call(categories: [category])` — a ranked book list |
| `/genres/search` | JSON typeahead |
| `/countries` | index; `sort` ∈ `name` (default), `book_count` |
| `/countries/sorted-by/:sort` | index |
| `/countries/search` | JSON typeahead |

`/countries` has **no** show route.

Legacy resolves `/genres/:id` with `Category.active.friendly.find`, which accepts a slug or a
primary key. Every legacy category has a slug (0 null/blank of 73,913) and legacy's
`friendly_id_slugs` history table is **empty**, so there are no historical slugs to honour.

Legacy's own public HTML never links `/genres/:slug` — both the index page and
`link_to_books_by_category` link straight to `/the-greatest/#{slug}/books/`. Show-page exposure
is therefore backlinks and history only, whereas the `filtered-by` / `sorted-by` variants are
linked from a live page and have current crawl exposure.

## 3. Decisions

### D1 — Route the legacy paths verbatim rather than redirecting them

`Books::BrowseController` already reads `params[:filter]` and `params[:sort]`, and
`Books::BrowseQuery.normalized_type` / `.normalized_sort` already accept exactly the legacy
vocabulary (`genre|location|subject`, `book_count|name`). Route segments populate `params`
identically to query parameters, so the legacy paths can be mapped onto the existing actions
with **no controller changes**.

`Pagination::PathBuilder.from_request` derives the pagination base by stripping a trailing
`/page/N` from `request.path`, so `/genres/filtered-by/location/page/3` paginates correctly
with no changes either.

This is the same approach increment 4 of the original filters work took with the filter
grammar, and for the same reason: a routed URL keeps its link equity intact and costs no
redirect hop.

### D2 — Path segments, not query parameters

The `?filter=` / `?sort=` form shipped in PR #204 is replaced by the legacy path form as the
single canonical shape. Query strings are cacheable at Cloudflare — they are part of the
default cache key — so this is not a caching fix. It is chosen because the path form is what
legacy already publishes, which turns a redirect into a plain route, and because it keeps one
URL grammar across the whole books site rather than two.

### D3 — Keep `/genres`, do not rename to `/categories`

The container is technically all three category types, so `/categories` is the more accurate
noun and `/genres/filtered-by/subject` reads oddly. Rejected anyway:

- Legacy already made this call deliberately — the model is `Category`, the path is `genres`.
- `/genres` is in the legacy navbar sitewide. Renaming puts a 301 on the site's most-linked
  taxonomy hub for a distinction no user or crawler perceives.
- "book genres" is a real search term; "book categories" is not.
- What a search engine reads for the location and subject views is the `<title>` / `<h1>`,
  which already say "Book Settings" and "Book Subjects".

Splitting into sibling hubs (`/genres`, `/subjects`, and something for locations) was also
considered and rejected: it breaks the verbatim-grammar approach that makes this increment
cheap, there is no good URL word for settings, and these pages are a route to the real
destination (`/the-greatest/:slug/books`), not the destination.

### D4 — Segment constraints are load-bearing

`normalized_sort` and `normalized_type` silently fall back to the default for **any** input.
As a query parameter that is harmless behind a canonical tag. As a path segment it makes
`/genres/sorted-by/<anything>` an unbounded space of indexable URLs that each render a
soft-duplicate of `/genres`.

Every parameterised route is therefore constrained to its known vocabulary, so unknown values
404 instead of rendering:

```ruby
sort:   /(?:book_count|name)/
filter: /(?:genre|location|subject)/
page:   /\d+/
```

Rails anchors segment constraints itself and raises `ArgumentError` on a regexp containing
`\A`, `\z`, `^`, or `$`. The non-capturing group is there so the alternation cannot leak when
Rails concatenates the segment patterns.

### D5 — `/genres/:id` 301s to the filter page

Legacy's show action renders a ranked book list for one category. `/the-greatest/:slug/books`
renders exactly that. So this is a redirect to existing content, not a page to rebuild —
building a second one would be duplicate content competing with the filter page.

Verified: `/the-greatest/fiction/books`, `/the-greatest/fictional-location/books` and
`/the-greatest/identity/books` all return 200, so all three category types have a live
destination.

Scoped to `Books::Category.active`. Of 73,945 books categories, 21,191 are soft-deleted;
legacy 404s those, and only about 3% of a 1,000-row sample have a surviving category carrying
their name in `alternative_names`, so chasing merge targets is not worth the complexity.

### D6 — Numeric ids resolve through `LegacyIdMap`, and only after slug

Category ids were **not** preserved by the migration (`CategoryMigrator` is a fresh-id
migrator keyed on `LegacyIdMap` under model `"Books::Category"`), so a numeric legacy id
cannot be resolved by primary key.

Slug is tried first. This is required, not merely legacy-compatible: 206 books categories have
a purely numeric slug, and a slug must beat a coincidentally equal legacy id — the same trap
`Books::LegacyBooksController` documents for books.

### D7 — Category slugs were preserved, so slug lookup is 1:1

`CategoryMigrator#upsert_row` pins `def category.should_generate_new_friendly_id? = false`
specifically to stop FriendlyId regenerating the slug from the name on insert. Legacy slugs
therefore survive verbatim and `find_by(slug:)` is an exact port of legacy's lookup.

### D8 — `/genres/search` resolves the "Search" category

There is a real, active subject category named "Search" (slug `search`, 41 catalog books, 16
ranked). Legacy shadows it with the JSON typeahead endpoint purely as an accident of route
ordering — `collection` routes are declared before the `:id` member route. Nothing points a
JSON client at the new app, so letting it resolve as a category is better than replicating the
accident.

The same applies to `/genres/page`, which resolves the active location category named "Page"
(slug `page`, 2 catalog books, 0 ranked). `/genres/page/2` remains pagination because the
paginated route is declared first.

## 4. Routes

All added inside the existing books `DomainConstraint` block in `web-app/config/routes.rb`,
replacing the four current browse routes. Order matters — `genres/:id` must come last.

```
genres                                                    → books/browse#genres   (as: books_genres)
genres/page/:page                                         → books/browse#genres   (as: books_genres_page)
genres/sorted-by/:sort                                    → books/browse#genres
genres/sorted-by/:sort/page/:page                         → books/browse#genres
genres/filtered-by/:filter                                → books/browse#genres
genres/filtered-by/:filter/page/:page                     → books/browse#genres
genres/filtered-by/:filter/sorted-by/:sort                → books/browse#genres
genres/filtered-by/:filter/sorted-by/:sort/page/:page     → books/browse#genres
genres/:id                                                → books/legacy_categories#show

countries                                                 → books/browse#countries (as: books_countries)
countries/page/:page                                      → books/browse#countries (as: books_countries_page)
countries/sorted-by/:sort                                 → books/browse#countries
countries/sorted-by/:sort/page/:page                      → books/browse#countries
```

Only the four bare forms keep route names — they are used by the footer
(`layouts/books/application.html.erb:68-69`) and by `Books::FilterPaneComponent#browse_path`.
Every parameterised path is built by `Books::BrowsePath`, matching the `Books::FilterPath`
precedent where the 80 filter routes are unnamed.

No `/rc/:id/genres/...` variants: legacy has none, and the browse pages are scoped to the
default primary ranking configuration.

## 5. `Books::BrowsePath`

New PORO at `app/lib/books/browse_path.rb`, mirroring `Books::FilterPath`.

```ruby
Books::BrowsePath.call(axis: :genres, type: "location", sort: "name", page: 3)
# => "/genres/filtered-by/location/sorted-by/name/page/3"
```

- `axis` is `:genres` or `:countries`. `:countries` ignores `type`.
- `type` and `sort` normalize through `Books::BrowseQuery.normalized_type` / `.normalized_sort`,
  so an unknown value collapses to the default rather than appearing in a path.
- Defaults are omitted, so the default view has exactly one URL — the property
  `BrowseToolbarComponent#path_for` currently provides and must keep.
- `page` ≤ 1 emits no page segment.

It replaces the query-string construction in `Books::BrowseToolbarComponent#path_for` and both
`@canonical_path` assignments in `Books::BrowseController`. Pagination does not use it —
`Pagination::PathBuilder` already derives page links from `request.path`.

## 6. `Books::LegacyCategoriesController`

New controller at `app/controllers/books/legacy_categories_controller.rb`, alongside the
existing `legacy_books_controller.rb` and `legacy_authors_controller.rb` and following their
shape.

```ruby
class Books::LegacyCategoriesController < ApplicationController
  def show
    redirect_to Books::FilterPath.call(categories: [find_category!]),
      status: :moved_permanently
  end

  private

  def find_category!
    Books::Category.active.find_by(slug: params[:id]) || find_by_legacy_id!
  end

  def find_by_legacy_id!
    raise ActiveRecord::RecordNotFound unless /\A\d+\z/.match?(params[:id])

    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: params[:id])
    raise ActiveRecord::RecordNotFound if new_id.nil?

    Books::Category.active.find_by!(id: new_id)
  end
end
```

`find_by!(id:)`, never `.find`: `Category` uses FriendlyId with `:finders`, which resolves
slugs before primary keys. This is the trap `Books::LegacyBooksController` documents.

A missing category raises `ActiveRecord::RecordNotFound` and gets the app's standard 404.

## 7. Collapsing the query-string form

PR #204's `?filter=` / `?sort=` URLs were live on the preview host. A `before_action` on
`Books::BrowseController` 301s any request carrying a `filter`, `sort`, or `page` **query**
parameter to the equivalent `Books::BrowsePath`, normalizing unknown values to the default.

Only `request.query_parameters` is inspected, never `params` — on a routed path such as
`/genres/filtered-by/location` the values arrive as path parameters and must not trigger a
redirect loop.

This also permanently closes the door on a crawler minting `?filter=` variants of pages this
increment makes more crawlable.

## 8. Crawl and canonical policy

Unchanged in principle from the rework spec, restated in path terms:

- Canonical keeps `filter` and `page`, and **drops `sort`**. A sort variant is the same result
  set reordered — duplicate content by definition — so `/genres/sorted-by/name` canonicals to
  `/genres`. `Books::BrowseController` already does this; `BrowsePath` only changes the shape.
- All browse responses stay `@indexable = true`.
- The canonical set is bounded: 3 filter values plus `/countries`, times their page counts. No
  new `robots.txt` entries are needed, and D4's constraints are what keep the set bounded.
- `/genres/:id` 301s into `/the-greatest/:slug/books`, which is crawl class 1 (single facet,
  no comma) and already indexable under the existing policy. A category with no ranked books
  lands on the existing empty state, which `Books::RankedItemsController` already marks
  `noindex`.

## 9. Out of scope

- `/women`, `/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`, `/condensed`,
  `/global-canon`, `/that-start-with/:letter`. Still 404ing, still required before cutover.
  `/women` needs an author gender field the migration never brought over, so that family is
  its own spec.
- `/genres/search` and `/countries/search` as JSON endpoints. The books modal has its own
  per-axis search endpoints; the legacy JSON contract has no consumer here.
- Redirecting soft-deleted categories to a merge target (D5).
- The production run of the two country-data rake tasks, tracked separately.

## 10. Testing

**Routing** (`test/integration/books/`) — `assert_recognizes` ignores `host!`, so every
assertion passes a full `http://<books-host>/path` or the negative cases pass vacuously.

- Each of the 13 routes recognises to the right controller and action with the right params.
- `genres/page/2` recognises as pagination, not as `legacy_categories#show`.
- `genres/sorted-by/upvotes`, `genres/filtered-by/theme` and `countries/sorted-by/bogus` do
  not recognise (D4 constraints).

**`Books::BrowsePath`** (`test/lib/books/browse_path_test.rb`) — every axis/type/sort/page
combination, defaults omitted, unknown values normalized, `:countries` ignoring `type`.

**`Books::BrowseController`** — each legacy path returns 200 and sets the expected `@type` /
`@sort`; the canonical for a sorted path drops the sort; `?filter=location` 301s to
`/genres/filtered-by/location`; a routed path does **not** redirect.

**`Books::LegacyCategoriesController`** — 301 to `/the-greatest/fiction/books` for a slug;
301 for a `LegacyIdMap`-mapped numeric id; a numeric slug wins over an equal legacy id
(construct both); 404 for `retired-genre` (the existing `books_deleted_genre` fixture,
already commented "Soft-deleted, must never resolve"); 404 for an unmapped numeric id; 404 for
an unknown slug.

The numeric-id cases create their `LegacyIdMap` rows in the test rather than adding a
`legacy_id_maps.yml` fixture, which would load for the whole suite for two assertions.

**Component** — `Books::BrowseToolbarComponent` emits path URLs and marks the active link.

**E2E** (`e2e/tests/books/browse.spec.ts`, extending the existing 5 specs) — from `/genres`,
clicking "Settings" lands on `/genres/filtered-by/location` with no query string.

## 11. Landmines

- **Route order.** `genres/:id` last, and `genres/page/:page` before it, or `/genres/page/2`
  resolves as the category "Page" with a stray path segment.
- **`.find` vs `.find_by!(id:)`** on any FriendlyId `:finders` model (§6).
- **Slug before legacy id**, because 206 books categories have purely numeric slugs (D6).
- **Anchors in route constraints raise `ArgumentError`** (D4).
- **`assert_recognizes` ignores `host!`** — pass a full URL under a `DomainConstraint`.
- **`request.query_parameters`, not `params`,** in the §7 redirect guard, or routed paths
  redirect to themselves forever.
- **`Category#should_generate_new_friendly_id?` is `slug.blank? || name_changed?`,** so an
  explicit `slug:` passed to `Books::Category.create!` in a test is silently overwritten.
  Read the slug back, or use the fixtures.

## 12. Increments

One increment. The route table, `BrowsePath`, the legacy controller, the query-string collapse
and their tests are a single reviewable change — splitting them leaves the tree in a state
where the toolbar emits URLs the routes do not serve.
