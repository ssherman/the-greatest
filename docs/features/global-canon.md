# Global Canon

## Overview

`/global-canon` is an algorithmically balanced canon of books, drawn from the books ranked list
but reshuffled so no single country or author can dominate it. The plain ranked list (`/`) is
what the world's "greatest books" lists actually voted for, and that vote skews hard toward a
handful of countries and toward authors who wrote several books that all rank well. The canon
walks the same ranking but admits **at most N books per country** and **exactly one book per
author**, so the result reads like a canon — a representative, curated set — rather than a
leaderboard.

It is a **port** of the legacy site's `/global-canon` (`GlobalCanonGenerator` in
`admin/app/lib/global_canon_generator.rb`), keeping its visitor-facing customisation (total book
count, non-fiction share, max books per country) and its URL grammar verbatim, while extending the
non-fiction share from 0–50% to the full 0–100% and adding visitor-selectable genre exclusions,
which legacy did not have. The default children's-books exclusion legacy applied is **dropped** —
genres are now excludable by hand, so `/global-canon` today can show a different set of books than
production does, on purpose.

Only books has a Global Canon. There is no admin surface — the canon is entirely derived from
existing ranking, category, country and author data, so there is nothing to store or administer.
There is no pagination; 250 is the largest selectable total and also the page's ceiling.

## Architecture

Three requests, three different jobs. `show` renders the page from path segments; `settings` is
the form's GET target and only ever redirects; `genres` is a JSON search endpoint for the
exclusion picker.

```
GET /global-canon(/total_books/:t/nonfiction/:p/max_per_country/:c(/excluding/:genres))
  |
  v
redirect_to_canonical_form   # 301 if computed path != request.path, or a recognised query key is present
  |
  v
Books::GlobalCanonParams.call(params)      -> Settings (total_books, nonfiction_percentage,
  |                                            max_books_per_country, excluded_genres)
  v
Books::GlobalCanonQuery.call(ranking_configuration:, settings:)
  |  fiction pass, then non-fiction pass, shared country/author counters
  v
Result(ranked_items, requested, delivered, blocked_by_country, blocked_by_author)
  |
  v
show.html.erb -> Books::CardComponent grid, numbered by canon position
```

```
GET /global-canon/settings?total_books=250&nonfiction_percentage=40&...
  |
  v
Books::GlobalCanonParams.call(params) -> Settings
  |
  v
Books::GlobalCanonPath.call(settings) -> canonical path string
  |
  v
303 See Other -> that path                 # so the URL grammar lives only in GlobalCanonPath
```

```
GET /global-canon/genres?q=poet
  |
  v
CategorySearchQuery.call(q, scope: Books::Category, types: [:genre])
  |
  v
render json: [{value: slug, text: name}, ...]
```

`show` and `settings` share one params object (`Books::GlobalCanonParams`) even though `show`
reads path segments and `settings` reads a query string — both land in Rails' `params`, so unlike
`Books::BrowseController#find_collection` (which must read `request.path_parameters` because one
of its actions also serves a route with no `:collection` segment at all), no such asymmetry is
needed here: every route reaching `show` supplies all its segments positionally.

## The four objects

| Object | Owns |
| --- | --- |
| `Books::GlobalCanonParams` | Raw params -> a validated `Settings` struct, or `ActiveRecord::RecordNotFound`. The defensive half of validation — the route constraints (below) already reject most bad input; this is what stands between a future-loosened constraint and a page that silently serves the wrong canon under a URL that promised a specific one. |
| `Books::GlobalCanonQuery` | The selection algorithm. Takes a ranking configuration and a `Settings`, returns a `Result` (`ranked_items`, `requested`, `delivered`, `blocked_by_country`, `blocked_by_author`). Callers never see how selection works. |
| `Books::GlobalCanonPath` | `Settings` -> the one canonical path string for those settings. The *only* place the URL shape lives — both the controller's redirect logic and the settings-form target go through it. |
| `Books::GlobalCanonController` | Wires the above together: `show` (the page), `settings` (form target, always redirects), `genres` (JSON picker source). Owns caching/indexing decisions and the canonical-form 301. |

### `Books::GlobalCanonParams`

`app/lib/books/global_canon_params.rb`. Mirrors `Books::FilterParams`'s validation shape (raw
value -> parsed value -> raise if it doesn't satisfy a predicate, never a silent fallback to a
default for a *present-but-invalid* value):

- `total_books` must be one of `TOTALS = [50, 100, 150, 200, 250]`.
- `nonfiction_percentage` must be `0..100`.
- `max_books_per_country` must be `1..10`.
- `excluded_genres` accepts either shape the two entry points produce — a comma-joined string (the
  path segment) or an array (the picker's `excluded_genres[]` hidden inputs) — splits, strips,
  uniques, 404s past `MAX_EXCLUDED_GENRES = 6`, resolves each slug against
  `Books::Category.active.where(category_type: :genre)`, and 404s on any slug that doesn't
  resolve to a genre in that scope (so a subject or setting slug 404s too — see "Genre exclusions"
  below). Resolved genres are sorted by slug.
- Absent segments take the defaults (`total_books: 150, nonfiction_percentage: 20,
  max_books_per_country: 3`, no exclusions).
- `Settings#default?` is true only for that exact triple with zero exclusions; it drives
  canonicalisation and indexability everywhere downstream.

### `Books::GlobalCanonQuery`

`app/lib/books/global_canon_query.rb`. See "The selection algorithm" below.

### `Books::GlobalCanonPath`

`app/lib/books/global_canon_path.rb`. `Settings` -> canonical path string:

```
/global-canon                                                          # settings.default?
/global-canon/total_books/250/nonfiction/40/max_per_country/2
/global-canon/total_books/250/nonfiction/40/max_per_country/2/excluding/childrens-books,poetry
```

Excluded-genre slugs are comma-joined and sorted, so `poetry,fantasy` and `fantasy,poetry` can
never both exist as separate URLs and separate cache entries. `excluding` only ever appends to the
full three-segment form — a partial form (e.g. just `total_books`) plus exclusions is never
produced, since the settings form always submits all three base settings together.

### `Books::GlobalCanonController`

`app/controllers/books/global_canon_controller.rb`. `before_action` order is deliberate:
`redirect_to_canonical_form` runs before `cache_for_index_page`, because a 301 must not be
decorated with 6-hour public edge-cache headers; `find_ranking_configuration` runs after both, so
a request that's about to redirect anyway doesn't pay for an uncached
`Books::RankingConfiguration.default_primary` lookup, and so that lookup coming back `nil` can
never turn a clean redirect into an unrelated 404.

`find_ranking_configuration` is also scoped `only: [:show]` — it's the only action that reads
`@ranking_configuration`. `#settings` never touches it, and `#genres` is the exclusion picker's
search-as-you-type source: it fires on every keystroke, so running an uncached `default_primary`
lookup there was a wasted query per keystroke, and a `nil` RC would 404 the JSON endpoint for a
reason unrelated to the search itself. With the lookup scoped away, `prevent_caching` is the only
filter left on `#genres`, so its `no-store` header can never be skipped by an earlier 404.

## The selection algorithm

`Books::GlobalCanonQuery` ports `GlobalCanonGenerator.generate_global_canon` from the legacy site.
Given a ranking configuration and a `Settings`, it:

1. Splits `total_books` into a fiction quota and a non-fiction quota:
   `nonfiction_quota = (total_books * nonfiction_percentage / 100.0).round`,
   `fiction_quota = total_books - nonfiction_quota`.
2. Builds `ranked_scope` — the ranking configuration's `RankedItem`s for `item_type: "Books::Book"`,
   ranked (`rank` not null), with the four blocked ids and any excluded-genre books already
   filtered out at the SQL level (a `where.not(item_id: ...)` subquery on `CategoryItem`, not a
   per-item Ruby check).
3. Runs the **fiction pass first**, then the **non-fiction pass**, each walking its candidates
   (books tagged with the `fiction`/`nonfiction` genre, in rank order) and taking a book only if
   its country is under `max_books_per_country` and its author hasn't been used yet.
4. Re-queries the selected ids as `RankedItem`s ordered by `rank`, with the same
   `includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])` preload
   `RankedBooksQuery` uses, so the grid doesn't N+1 on authors or cover images.

### Two behaviours that are load-bearing and must not be "tidied"

**The fiction pass runs before the non-fiction pass.** **The country and author counters
(`@country_used`, `@author_used`) are shared across both passes**, not reset between them. Together
these mean fiction spends country (and author) slots *first*, and the non-fiction pass inherits
whatever's left. This is why the non-fiction tail of a canon is consistently more geographically
constrained than the fiction head — it's not a bug, it's the direct consequence of pass order plus
shared counters. `Books::GlobalCanonQueryTest#"fiction consumes country slots before the
non-fiction pass runs"` is built so that flipping the pass order changes which book gets selected —
a test that would pass unchanged against a reordered implementation would be worthless here, so
this one is deliberately constructed to fail against either order except the shipped one.

Both of these are exactly the two details the design spec calls out as "most likely to be cleaned
up by accident," and the implementation and its test suite preserve both.

### Country attribution, and the `nil` bucket

Each book's country and author are taken as the *first* row for that book (`order(:id)` for
country, `order(:position, :id)` for author) — this reproduces legacy's `book.countries.first` /
`book.authors.first`, which had no explicit order of its own. Which row wins is not cosmetic: it
decides which country/author bucket a multi-country or multi-author book spends, so both orderings
are pinned by tests (`"spends the lowest-id country when a book has two"`,
`"spends the lowest-position author, not the first-created one"`).

A book with **no** country at all falls into a single `nil` bucket in `@country_used`, and that
bucket is capped by `max_books_per_country` exactly like a real country — legacy does the same
(`book.countries.first&.id`), and it's preserved deliberately rather than treated as "no
constraint." A canon with a low country cap and many country-less ranked books will therefore
under-fill even though plenty of eligible books exist, because they're all competing for the same
`nil` slot.

When a book fails both checks — its country is at cap *and* its author is already used — it's
charged to `blocked_by_author` only, never both. `select_pass` computes `country_at_cap` and
`author_taken` up front, then checks `author_taken` first: **`blocked_by_country` means "this book
would be admitted if the country cap were raised."** A book whose author is already used would
still be rejected even with a higher cap, so it can never be the reason `blocked_by_country`
mentions to a visitor — it's charged to `blocked_by_author` instead, regardless of its country.
Only a book whose author is still free, and which is rejected purely because its country is full,
increments `blocked_by_country`. This is why `show.html.erb`'s short-list note can use a plain
`blocked_by_country.positive?` check (see "The short-list note's branch order matters" below) to
decide whether to tell a visitor to raise the country cap — under this attribution, *any* positive
count is a real, actionable one. This attribution is new information the legacy implementation
never produced (it skipped on a single combined `country || author` check).

This is a deliberate reversal of the order the algorithm originally shipped with — country checked
first, author second — which charged a book failing both checks to `blocked_by_country`. That
attribution was actionably *wrong*: it could tell a visitor raising the country cap would get them
more books when it would not have admitted the very book being counted (its author would still
reject it). `Books::GlobalCanonQueryTest#"attributes a book blocked by both country and author to
author only"` pins the corrected attribution and explains why.

### The four blocked books

`BLOCKED_BOOK_IDS = [2526, 1974, 15365, 705]`, excluded from every canon regardless of settings.
The legacy migration preserved book ids, so these resolve 1:1 in this app:

| id | title | why |
| --- | --- | --- |
| 2526 | The Protocols of the Elders of Zion | antisemitic forgery |
| 1974 | Mein Kampf | — |
| 15365 | Revolt Against The Modern World | fascist esotericism |
| 705 | The Elements of Style | not hateful — a style manual, excluded as not literature |

### Under-delivery is expected, not a bug

The canon frequently cannot be filled to the requested `total_books` — a low `max_books_per_country`
against a small or geographically concentrated candidate pool, or a request skewed heavily toward
whichever of fiction/non-fiction has fewer eligible books, routinely comes up short. The design
spec measured this on the development database (24,242 ranked books at the time): 250 books / all
fiction / max 1 per country delivered 156; 250 / all non-fiction / max 3 delivered 246. `Result`
reports `requested` and `delivered` separately so the view can say so plainly rather than silently
returning a short grid.

### Divergence from the design spec's sketch

The spec sketches the candidate table as a single query producing one ordered array of
`[item_id, country_id, author_id, fiction?, nonfiction?]` tuples. The shipped implementation
instead runs `candidates_in(:fiction)` / `candidates_in(:nonfiction)` as two separate rank-ordered
`pluck(:item_id)` queries (each a `ranked_scope` filtered to one genre), with country and author
resolved through two more memoised lookup hashes (`country_by_book`, `author_by_book`) built from
their own queries. The externally observable behaviour matches the spec exactly — same ordering,
same shared counters, same attribution — but the shape is several targeted queries rather than one
unified one. Nothing in the design depends on it being a single query, so this is a shipped
implementation detail, not a behavioural gap.

## The URL grammar

| URL | Behaviour |
| --- | --- |
| `GET /global-canon` | The defaults: 150 books, 20% non-fiction, max 3 per country, no exclusions. Indexable. |
| `GET /global-canon/total_books/:t` | Partial form. 301s to the full three-segment form with the other two settings spelled out at their defaults. |
| `GET /global-canon/total_books/:t/nonfiction/:p` | Partial form. Same 301 behaviour. |
| `GET /global-canon/total_books/:t/nonfiction/:p/max_per_country/:c` | The full form. Canonical unless it equals the defaults (in which case it 301s to the bare path) or its genre list isn't sorted. |
| `GET /global-canon/total_books/:t/nonfiction/:p/max_per_country/:c/excluding/:genres` | The full form plus exclusions. `:genres` is a comma-joined, sorted list of up to 6 genre slugs. |
| `GET /global-canon?total_books=250...` | A recognised query key (`QUERY_FORM_KEYS`) reaching `show` at all — including one that resolves to the *default* settings, e.g. `?total_books=150`. 301s into the equivalent path form — the same guard `Books::BrowseController` uses, so a crawler can never mint `/global-canon?total_books=250` (or `?total_books=150`) as a distinct, cacheable URL. An *unrecognised* key, e.g. `?utm_source=newsletter`, is left alone and still 200s — the whole point being that campaign-tracking query strings must not be redirected away. |
| `GET /global-canon/settings?...` | The form's GET target. Resolves params through `GlobalCanonParams`, 303s to `GlobalCanonPath.call(settings)`. Never cached (`prevent_caching`). 404s on an invalid value, same as `show` — this is the only guard standing between a hand-edited query string here and a 500, since this route carries no regex constraint of its own. |
| `GET /global-canon/genres?q=...` | JSON search source for the exclusion picker. Never cached. |

Route segment constraints (`canon_total`, `canon_pct`, `canon_country`, `canon_genres` in
`config/routes.rb`, in the books domain block) reject most bad input before it reaches the app at
all — `GlobalCanonParams` is the defensive second layer for whatever the constraints don't catch
(the `settings` action, and any future loosening of a constraint).

### Why settings live in the path, not a query string

Every distinct combination of settings is its own URL, and every one of those URLs is its own
Cloudflare edge-cache entry (`show` sets 6-hour public cache headers via `cache_for_index_page`).
A query string would either bypass that cache entirely or require normalising query-parameter
order and presence into a cache key by hand; putting settings in the path means the cache key *is*
the URL, for free.

### Canonicalisation

`redirect_to_canonical_form` computes `Books::GlobalCanonPath.call(GlobalCanonParams.call(params))`
and 301s whenever that differs from `request.path`, **or** the request carries a recognised query
key. Two rules, because one alone doesn't cover every non-canonical shape:

Comparing the *computed* path against `request.path` (which excludes the query string entirely)
catches a partial form, a spelled-out set of defaults, and a query string that resolves to
**non-default** settings — all of these compute a canonical path that differs from the request
path. It does **not** catch a query string that resolves to the **default** settings (e.g.
`?total_books=150`, 150 being the default): the computed canonical is the bare path, which is
already `request.path`, so the comparison alone sees no difference and would serve a
publicly-cacheable 200 — Cloudflare mints a fresh cache entry per distinct query string regardless
of what it resolves to.

`QUERY_FORM_KEYS = %w[total_books nonfiction_percentage max_books_per_country excluded_genres]`
closes that gap, mirroring `Books::BrowseController::QUERY_FORM_KEYS`: any of *these* keys present
in `request.query_parameters` forces the redirect regardless of what it resolves to. Only
recognised keys count — `?utm_source=`, `?fbclid=` and friends must keep returning 200, since
redirecting those away destroys campaign attribution, so this checks for specific keys, never bare
query-string presence.

`request.query_parameters`, not `params`, for that check — same reasoning as
`Books::BrowseController`: on a routed path like `/global-canon/total_books/250/...` the same
values arrive as *path* parameters (in `params`), and triggering off `params` would make every such
request redirect to itself forever. `request.query_parameters` only ever holds the literal `?...`
query string, so a routed path with no query string never trips this check.

Comparing against the *computed* path rather than testing for specific segment combinations still
means a new non-canonical *path* shape added later is covered automatically; only the query-string
half of canonicalisation needs an explicit key list, because "does this query resolve to something
different from what's already showing" isn't decidable from `request.path` alone once the answer
can be "no, and that's exactly the bug."

Termination: `/global-canon?total_books=150` has `"total_books"` in `query_parameters`, so it
redirects to the computed canonical (`/global-canon`, since 150 is the default). That target
carries no query string, so on the next request `query_parameters.slice(*QUERY_FORM_KEYS)` is empty
and `canonical == request.path` — no redirect, a plain 200.
`global_canon_controller_test.rb`'s `"the redirect target for a default-resolving query is
terminal"` pins this.

### Indexability

- The bare `/global-canon` renders `<meta name="robots" content="index, follow">` and a
  `<link rel="canonical" href="https://.../global-canon">`.
- **Every** customised variant — a spelled-out-but-not-default full form, or any form carrying
  `excluding` — renders `noindex, follow` and **no canonical tag at all** (`@canonical_path` is
  only set `if @indexable`, and `@indexable = @settings.default?`).

A canonical tag pointing from a noindexed page back at `/global-canon` might look like the "right"
thing to do — point search engines at the one worth indexing — but a canonical on a noindexed page
risks the noindex propagating *to* the canonical's target instead, per the same rule
`Books::RankedItemsController` already states for its own `/rc/` URLs. `Books::BrowseController`
does pair a canonical with different sort-order variants of a page, but those variants are the
*same result set*, just reordered; a customised canon is a *genuinely different result set*
(different books, in a different order), so the stricter rule — no canonical at all — applies here
instead.

## Genre exclusions

The settings form's third control is a search-and-add picker (reusing
`saved_search_picker_controller.js`, already registered for the books bundle) pointed at
`GET /global-canon/genres?q=...`. It's progressive enhancement: without JavaScript the three
`<select>` menus still submit a normal GET to `/global-canon/settings`; chosen genres are also
carried as plain `excluded_genres[]` hidden inputs so the picker's selections submit the same way.

`GlobalCanonController#genres` calls
`CategorySearchQuery.call(params[:q], scope: ::Books::Category, types: [:genre])` and renders
`{value: category.slug, text: category.name}` per match — **slugs, not ids**. This is a deliberate
divergence from the saved-search picker's own endpoint, which returns `{value: id}`: the canon's
URL grammar is slug-based (`/excluding/childrens-books,poetry`), so if the picker instead worked in
ids, translating id -> slug would have to happen in JavaScript, putting the URL's vocabulary in two
places instead of one.

`types: [:genre]` is also deliberate and narrower than the books filter modal's own category
picker, which searches genres, subjects, *and* settings (locations) together. Excluding "set in
Paris" from a global canon isn't a thing this page offers, and `GlobalCanonParams` 404s a subject
or location slug it's handed — the endpoint and the validator have to agree on what's excludable,
or the picker could hand a visitor a chip that 404s the moment they click "Update list."

## Gotchas

- **The `/excluding/` segment must key off `excluded_genres`, never off `default?`.**
  `GlobalCanonPath#call` appends `excluding/...` whenever `settings.excluded_genres` is non-empty —
  it does *not* check whether the other three settings are non-default. If it were changed to key
  off `default?` instead, a canon customised *only* by excluding a genre (total/percentage/cap all
  still at their defaults) would compute back to the bare `/global-canon` path. Since the
  controller 301s whenever `computed_path != request.path`, and the bare path re-parses right back
  to that same customised-by-a-genre `Settings` (because `GlobalCanonParams` has no idea a genre
  was excluded once it's off the URL), the redirect would point at itself — an infinite 301 loop
  on any genre-only exclusion. `global_canon_path_test.rb`'s
  `"defaults customised only by an excluded genre round-trips and never collapses to the bare
  path"` test exists precisely to guard this.

- **The country-cap boundary is under-covered by the params unit test on purpose — the round-trip
  test picks up the slack.** `global_canon_params_test.rb`'s `"404s on a country cap outside
  1..10"` only asserts that `0` and `11` fail; nothing in that file asserts `10` itself succeeds.
  That coverage lives in `global_canon_path_test.rb`'s
  `"round-trip stability: path -> reparse -> path yields same path"` test, which iterates every
  total × every sampled percentage × `(1..10)` — country cap `10` included — through
  `GlobalCanonParams.call` as part of its combinatorial round-trip. It is the only test anywhere
  that exercises `max_books_per_country = 10` as a *valid*, successfully-parsed value rather than
  as a rejected boundary.

- **`Books::List.active`, not `List.active`.** The header copy in `show.html.erb` counts
  `Books::List.active.count`. `List` (root namespace) is the shared model spanning all four sites
  this app serves — books, music, movies, games — so `List.active.count` would silently report a
  much larger, wrong number the moment someone "simplifies" the namespace away. `Books::List < ::List`
  is what scopes it to books.

- **The short-list note's branch order matters — the both-zero branch must come first.**
  `show.html.erb` renders the note only when `@result.delivered < @result.requested`, then checks,
  in this order: (1) `blocked_by_country.zero? && blocked_by_author.zero?` → "there aren't enough
  ranked books to fill a canon this size"; (2) `blocked_by_country.positive?` → names the country
  cap; (3) else → names the one-book-per-author cap. If the both-zero branch were moved after the
  country check, a short list caused purely by too small a candidate pool (`blocked_by_country: 0,
  blocked_by_author: 0` — nothing actually hit either cap) would evaluate `blocked_by_country.
  positive?` as `0.positive?` — false — and fall through to the *else* branch, wrongly blaming the
  one-book-per-author rule instead. (Under the old `blocked_by_country >= blocked_by_author`
  comparison this same reordering produced a different wrong answer — `0 >= 0` is true, so it
  wrongly blamed the country cap instead. Which cap gets blamed changed with the attribution fix;
  that the both-zero branch has to run first did not.) `global_canon_controller_test.rb`'s
  `"the short-list note explains an undersized pool without naming either cap"` pins this branch
  specifically.

  The middle branch is a plain `blocked_by_country.positive?`, not the `blocked_by_country >=
  blocked_by_author` comparison it shipped with initially. Under the corrected attribution above
  (`blocked_by_country` only ever counts a book that *would* be admitted by a higher cap), a
  magnitude comparison against `blocked_by_author` is neither necessary nor correct: a book can
  easily be blocked-by-author more often while a smaller-but-positive `blocked_by_country` count
  still names a real, actionable lever — raising the cap would deliver those books regardless of
  how many other books are stuck on the author rule. `.positive?` is simpler *and* provably
  correct under the new semantics, which `>=` was not: `global_canon_controller_test.rb`'s
  `"the short-list note offers the country lever even when author-blocked books outnumber it"`
  pins a scenario (`blocked_by_country: 1`, `blocked_by_author: 2`) where the old `>=` comparison
  would have wrongly suppressed the country message.

## Related documentation

- `docs/superpowers/specs/2026-08-18-books-global-canon-design.md` — the full design spec,
  including the legacy `GlobalCanonGenerator` walkthrough, the development-database measurements
  that shaped the design, and the increment breakdown.
- `docs/features/saved_searches.md` — the saved-search picker
  (`saved_search_picker_controller.js`) this feature's genre-exclusion UI reuses, and the
  `{value: id}` shape the canon's own `/global-canon/genres` endpoint deliberately diverges from.
- `docs/features/search.md` — `CategorySearchQuery` and `Books::FiltersController`, whose
  Category-axis definition (genres, subjects, and settings together) the canon's `genres` endpoint
  deliberately narrows.
