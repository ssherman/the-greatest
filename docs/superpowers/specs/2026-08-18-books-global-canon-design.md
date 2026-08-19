# Books global canon

Ports the legacy site's `/global-canon` page — an algorithmically balanced canon drawn from the
ranked books — to the new app, keeping its visitor-facing customisation and adding two changes:
the non-fiction share can now reach 0% or 100%, and visitors can exclude genres.

## Why

The Global Canon is the legacy site's answer to a real complaint about aggregate rankings: the
top of the list is dominated by a handful of countries and a handful of authors with several books
each. The canon walks the same ranking but admits at most one book per author and at most N books
per country, so what comes out reads like a canon rather than a leaderboard.

It is linked from the first slot of the legacy Lists menu and is one of the few legacy pages with
no equivalent in the new app.

### What the legacy implementation actually does

`GlobalCanonGenerator.generate_global_canon` (`admin/app/lib/global_canon_generator.rb`) is one
class method. Given `total_books`, `nonfiction_percentage`, `max_books_per_country` and
`exclude_categories` it:

1. Splits the total into a fiction quota and a non-fiction quota.
2. Walks the ranked books in rank order **twice** — fiction first, then non-fiction — taking a book
   only when its country is under the cap and its author has not been used.
3. Shares the country counter across both passes, so fiction consumes country slots before
   non-fiction runs.
4. Excludes the children's-books category and four books by id.
5. Re-queries the union in rank order.

Customisation is three menus in the page plus a Stimulus controller that rewrites
`window.location` into a nested path, page-cached per URL.

### The migration already did the hard part

| Piece | Status in the new app |
| --- | --- |
| Ranked books | `RankedItem` — 24,242 ranked under books RC 8 |
| Fiction / Non-fiction | `Books::Category` 2683 / 3348, `category_type: genre` |
| Country of origin | `Books::BookCountry` — 126,007 rows over 253 countries |
| Authors | `Books::BookAuthor` |
| The four blacklisted ids | **ids were preserved by the migration** — they resolve 1:1 |
| Multi-slug path grammar | `Books::FilterPath` already encodes `fantasy,poetry` sorted |
| Category picker | `CategorySearchQuery` + `saved_search_picker_controller.js` |
| Form → canonical path | `Books::FiltersController#show` 303s to `Books::FilterPath.call` |

The blacklist resolves as:

| id | title | why |
| --- | --- | --- |
| 2526 | The Protocols of the Elders of Zion | antisemitic forgery |
| 1974 | Mein Kampf | — |
| 15365 | Revolt Against The Modern World | fascist esotericism |
| 705 | The Elements of Style | not hateful — a style manual, excluded as not literature |

### Measurements that shaped the design

Run against the development database (books RC 8, 24,242 ranked books):

- Building the candidate table costs **~0.4s**; the selection scan itself costs **~2ms**.
- Most configurations scan nearly the whole ranked set — at 250 books / 50% non-fiction the
  non-fiction pass reaches position 21,374 of 24,242. **Early-exit batching buys nothing.**
- **The canon frequently cannot be filled.** 250 books / all fiction / max 1 per country yields
  **156**; 250 / all non-fiction / max 3 yields 246. Legacy shows the short list with no
  explanation.
- 566 of the ranked books carry neither the Fiction nor the Non-fiction category, and 100 carry
  both. Books in neither are invisible to the canon at any setting. This matches legacy and is
  deliberate.

## Scope

**In:**

- `/global-canon` and its customised path forms, ported grammar-verbatim.
- Non-fiction share extended from 0–50% to **0–100%**, so a canon can be all fiction or all
  non-fiction.
- Visitor-selectable **genre exclusions**, path-based so every variant is edge-cacheable.
- The four-book blacklist.
- A note when the settings cannot deliver the requested count.
- Nav entry in the books Lists menu.

**Out:**

- The default children's-books exclusion. Dropped — genres are now excludable by hand, and
  `/global-canon` is cleaner unfiltered. This changes the default page's output versus production.
- Excluding subjects or settings. The picker is genres only.
- Admin surface. There is nothing to administer; the canon is derived.
- Pagination. 250 is the ceiling.
- Any other media domain.

## Design

Four objects in `app/lib/books/`, next to the query objects they mirror.

### 1. `Books::GlobalCanonParams`

Raw params → a validated settings value object, mirroring `Books::FilterParams`.

```ruby
# app/lib/books/global_canon_params.rb
TOTALS = [50, 100, 150, 200, 250].freeze
DEFAULTS = {total_books: 150, nonfiction_percentage: 20, max_books_per_country: 3}.freeze
MAX_EXCLUDED_GENRES = 6   # matches FilterParams::MAX_CATEGORIES

Settings = Struct.new(:total_books, :nonfiction_percentage, :max_books_per_country,
  :excluded_genres, keyword_init: true)
```

Rules:

- Absent segments take the defaults.
- A value outside its allowed set raises `ActiveRecord::RecordNotFound`. The route constraints
  already reject these; this is the defensive half, in the spirit of `find_collection`'s comment
  about a future-loosened constraint.
- Genre slugs use `FilterParams#resolve` semantics exactly: split on comma, unique, more than
  `MAX_EXCLUDED_GENRES` → 404, any slug that does not resolve → 404, result sorted by slug.
- The genre scope is `Books::Category.active.where(category_type: :genre)`. A subject or setting
  slug therefore 404s rather than silently filtering.
- `#default?` — true when the settings equal `DEFAULTS` with no exclusions. Drives canonicalisation.

### 2. `Books::GlobalCanonQuery`

The algorithm. Returns a result struct; callers never learn how selection works.

```ruby
# app/lib/books/global_canon_query.rb
BLOCKED_BOOK_IDS = [2526, 1974, 15365, 705].freeze

Result = Struct.new(:ranked_items, :requested, :delivered,
  :blocked_by_country, :blocked_by_author, keyword_init: true)

def self.call(ranking_configuration:, settings:)
```

**Candidate table.** One query builds an ordered array of
`[item_id, country_id, author_id, fiction?, nonfiction?]` for the whole ranked set. Not
`.includes(:countries, :authors)` over a relation — that materialises 24k AR objects with two
associations each to answer a question about integers. Country and author are the *first* of each
per book, matching legacy's `book.countries.first` / `book.authors.first`; the ordering used to
pick "first" is pinned in a test, because a change there silently reshuffles the whole canon.

**Selection.**

```
nonfiction_quota = (total_books * nonfiction_percentage / 100.0).round
fiction_quota    = total_books - nonfiction_quota

country_used = Hash.new(0)   # shared across BOTH passes -- load-bearing
author_used  = Hash.new(0)

pass(fiction_ids,    fiction_quota)
pass(nonfiction_ids, nonfiction_quota)
```

The shared counter and the fiction-first order are the two pieces of legacy behaviour most likely
to be "cleaned up" by accident. Fiction runs first and consumes country slots, which is why the
non-fiction tail is more geographically constrained than the fiction head. A test makes flipping
the order produce a different result.

Skipped in every pass: `BLOCKED_BOOK_IDS`, and any book carrying an excluded genre
(`CategoryItem.where(category_id: excluded, item_type: "Books::Book")`).

Each skip increments `blocked_by_country` or `blocked_by_author`, which is what lets the view name
the binding constraint instead of guessing.

**Return.** The selected ids re-queried as `RankedItem`s ordered by rank, with the same
`includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])` preload
`RankedBooksQuery` uses, so the grid does not N+1.

### 3. `Books::GlobalCanonPath`

Settings → canonical path. The only place URL shape lives, mirroring `Books::FilterPath`.

```
/global-canon                                                    # settings == defaults
/global-canon/total_books/250/nonfiction/40/max_per_country/2
/global-canon/total_books/250/nonfiction/40/max_per_country/2/excluding/childrens-books,poetry
```

Genre slugs are comma-joined and **sorted**, so `poetry,fantasy` and `fantasy,poetry` cannot both
exist. When the settings equal the defaults the bare path is returned; the controller uses this to
301 away from spelled-out defaults.

The `excluding` segment only ever appends to the **full** form. Partial forms plus exclusions would
multiply the shapes for no gain — the form always emits all three settings.

### 4. `Books::GlobalCanonController`

```ruby
# app/controllers/books/global_canon_controller.rb
before_action :redirect_to_canonical_form, only: [:show]   # above the cache filter: a 301
before_action :cache_for_index_page, only: [:show]         # must not carry 6h cache headers
before_action :prevent_caching, only: [:settings, :genres]
```

| Action | Purpose |
| --- | --- |
| `show` | The page. |
| `settings` | Form target. Resolves params, 303s to `GlobalCanonPath.call`. Mirrors `Books::FiltersController#show`. |
| `genres` | JSON for the picker: `CategorySearchQuery.call(params[:q], scope: Books::Category, types: [:genre])` rendered as `{value: slug, text: name}`. |

`{value: slug}` is a deliberate divergence from the saved-search picker's `{value: id}` — this URL
grammar is slug-based, and translating ids to slugs in JS would put URL knowledge in two places.

**`show` reads path segments; `settings` reads the query string.** Both arrive in `params`, so one
`GlobalCanonParams` serves both and no `request.path_parameters` / `request.query_parameters`
asymmetry is needed here — unlike `find_collection`, which must use `path_parameters` because its
action also serves routes with no `:collection` segment. Every route reaching `show` supplies the
segments positionally, and no route reaching `show` also accepts them as a query string, so a
crawler cannot mint `/global-canon?total_books=250`: `redirect_to_canonical_form` sends any request
carrying those keys in `request.query_parameters` to the canonical path with a 301, the same guard
`Books::BrowseController` uses.

### Routes

Declared in the books domain block. `settings` and `genres` come first, per the ordering convention
this file already documents.

```ruby
canon_total   = /(?:50|100|150|200|250)/
canon_pct     = /(?:100|[1-9]?\d)/
canon_country = /(?:10|[1-9])/
canon_genres  = /[a-z0-9\-]+(?:,[a-z0-9\-]+){0,5}/
```

The constraints are load-bearing for the same reason `collection_re` is: an unconstrained segment
mints an unbounded space of soft-duplicates of a page that ranks. The genre regex caps the list at
six before `GlobalCanonParams` ever sees it.

The route accepts **any** integer 0–100 for the non-fiction share even though the menu offers only
multiples of five, so a hand-typed or bookmarked value still resolves.

### Caching and indexing

- `show` → `cache_for_index_page` (6h public, 1h stale-while-revalidate). Every distinct settings
  URL is its own edge-cache entry — the entire reason the settings live in the path.
- `settings` and `genres` → `prevent_caching`.
- `/global-canon` → `index, follow`, canonical `/global-canon`.
- Every customised variant → `noindex, follow` and **no canonical tag at all**.

That last point follows the rule `Books::RankedItemsController` states for `/rc/` URLs: a canonical
pointing away from a noindexed page risks propagating the noindex to the target.
`Books::BrowseController` does pair them for sort variants, but those are the same result set
reordered; these are genuinely different result sets, so the stricter rule applies.

### The page

Header keeps the legacy copy, minus the children's-books sentence, and keeps the live
`List.active.count` figure.

Settings form — a GET form to `/global-canon/settings`:

| Control | Values |
| --- | --- |
| Total books | 50 / 100 / 150 / 200 / 250 |
| Non-fiction | 0%, 5%, 10% … 100% |
| Max per country | 1–10 |
| Genres to exclude | search-and-add picker |

Legacy offered every integer 0–50 for the non-fiction share; as a 101-entry menu over the new range
that is unusable, so the menu is coarsened while the route stays permissive.

The picker reuses `saved_search_picker_controller.js` (already registered in
`app/javascript/controllers/index.js`, so it ships in the books bundle) pointed at
`/global-canon/genres`. Without JavaScript the three menus still submit; the picker is the
enhancement. No `<select multiple>` fallback — daisyUI 5 renders it as an unreadable single row
(CLAUDE.md).

The grid renders `Books::CardComponent` inside `Books::CardComponent::GRID_CONTAINER_CLASS`,
numbered **1..N by canon position** rather than by global rank. Legacy leads with an `<ol>` for the
same reason: global ranks (#1, #3, #9, #14 …) make the diversity filter's gaps look like bugs.

Short-list note, above the grid, only when `delivered < requested`, naming whichever cap blocked
more candidates:

> Showing **156** of the 250 requested. The limit of 1 book per country is the binding constraint —
> raise it to get more.

Nav: "The Global Canon" becomes the first curated entry in `app/views/books/shared/_nav_links.html.erb`,
above "The Greatest Books of the 21st Century", matching legacy order. It is shorter than the
longest label, so the submenu sizing from `10d0b7a3` is unaffected.

## Testing

`ranked_items.yml` has no books entries, and the existing books controller tests build ranked data
inline in `setup` (`RankedItem.create!(item: books_books(:war_and_peace), rank: 1, …)`). The canon
tests do the same. Building the ranked set explicitly also avoids the fixture-id-order trap that has
produced vacuously-passing sort tests in this repo.

### `Books::GlobalCanonQuery` — `test/lib/books/global_canon_query_test.rb`

- The country cap holds at its boundary: exactly N from one country, never N+1.
- No two selected books share an author.
- **Fiction consumes country slots before non-fiction runs.** Constructed so that flipping the pass
  order changes the output — otherwise the test passes against either implementation.
- Blocked ids never appear, even when they would otherwise rank.
- An excluded genre removes its books; a book carrying two genres, one excluded, is still removed.
- 0% yields zero non-fiction; 100% yields zero fiction.
- A book in neither category never appears, at either extreme.
- Under-delivery reports the correct `delivered` and names the cap that blocked more candidates.
- Results are ordered by rank.
- Which country and which author count as "first" is pinned.

### `Books::GlobalCanonParams` — `test/lib/books/global_canon_params_test.rb`

Defaults when segments are absent; 404 on an out-of-set total, a >100 percentage, an unknown genre
slug, a subject or setting slug, and seven genres; slugs sorted; `#default?` true only for the
exact default triple with no exclusions.

### `Books::GlobalCanonPath` — `test/lib/books/global_canon_path_test.rb`

Bare path for defaults; full path otherwise; genre slugs sorted and comma-joined; `excluding` only
ever on the full form.

### `Books::GlobalCanonController` — `test/controllers/books/global_canon_controller_test.rb`

200 and `index, follow` with a canonical on `/global-canon`; 200, `noindex, follow` and **no**
canonical on a customised path; 301 from spelled-out defaults; 404s for bad segments; `settings`
303s to the computed path; cache headers present on `show` and absent on `settings`/`genres`;
`assert_no_frame_trapped_links`; and an `assert_queries_count` pin on `show`, since the grid renders
authors and cover images per card.

### Verifying the tests actually test something

Every assertion above is confirmed by **deleting the line of production code it covers and watching
the test go red** before it counts as written. No `assert_empty` as a primary assertion and no bare
`assert_response :success` standing alone — both have passed against deleted code in this repo.

### Gate

`bin/rails test`, `bundle exec standardrb`, and the Playwright specs below.

## Increments

Each increment ships its own E2E spec rather than deferring them, which is how
`books-saved-searches` ended up with its E2E increment still outstanding.

### 1. Core canon

`GlobalCanonParams`, `GlobalCanonQuery`, `GlobalCanonPath`, the controller with `show` and
`settings`, routes, view, nav entry, the three menus including the 0–100 non-fiction range, the
blacklist, the short-list note.

E2E `e2e/tests/books/global-canon.spec.ts`: reach the page from the Lists menu, see the expected
number of cards, change a menu, confirm the URL becomes the path form and the results change.

### 2. Genre exclusion

The `excluding` segment in params and path, `#genres`, the picker wiring, route constraint.

E2E: add an exclusion through the picker, confirm the URL gains the segment and books of that genre
are gone. Update `e2e/tests/books/lists.spec.ts` for the new nav entry.

## Rollout

No migration, no data backfill, no job. The page is derived entirely from data that already exists,
so deploying is the whole rollout.

Two things change for existing visitors:

1. `/global-canon` no longer excludes children's books, so the default list differs from what
   production shows today.
2. The non-fiction menu now reaches 100%.

Legacy `/global-canon` URLs need no redirect — the grammar is ported verbatim.
