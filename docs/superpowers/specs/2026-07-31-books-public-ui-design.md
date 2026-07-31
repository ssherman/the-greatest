# Books Public UI — Design

**Status:** Design approved by owner 2026-07-31. Spec pending owner review.
**Goal:** Ship the public books site — ranked grid, book detail pages, curated lists, and user lists —
on `new.thegreatestbooks.org`, modelled on the games public UI.
**Why now:** The [descriptions subsystem](2026-07-27-descriptions-subsystem-design.md) was the blocker.
Increments (a)–(d) merged and the production backfill ran, so `Books::Book#primary_description`
resolves for 98.9% of ranked books. This is the next substantial piece of work.

Supersedes the settled decisions in `2026-07-27-books-public-ui-carryover.md`, which is now folded in
here. Where this document and the carryover disagree, this document wins — two carryover figures were
stale and are corrected below.

## Scope

**In:** ranked grid at `/` with path-based pagination (`/page/2`), `/book/:slug` detail pages, legacy
`/books/:id` and `/items/:id` 301s, robots/indexability plumbing, `/lists` + `/lists/:id`, full
user-list wiring, a books `paging.css`, a shared `Pagy::PathBasedPaging` extension, and Playwright
coverage for each increment.

**Out (deferred, each its own increment):** year filters and the legacy
`/the-greatest-books/{of,since,to,from}/:year` family; category pages and the
`/the-greatest/:category_id/books` family; author pages; search; the rankings methodology page;
table view; public user-list viewing (02d); sitemap.

## Increments

| # | Contents |
|---|---|
| 1 | Routes, robots plumbing, `Books::RankedBooksQuery`, ranked grid, `/book/:slug`, legacy 301s, books `paging.css`, layout fixes |
| 2 | `/lists`, `/lists/:id`, and converting the book page's list names into links |
| 3 | User-list wiring — `DOMAIN_SUBCLASSES`, modal JS, layout plumbing, My Lists |

Playwright specs are written inside each increment, not deferred to a trailing one.

## Current state (verified 2026-07-31 against dev)

- `Books::RankingConfiguration.default_primary` is **RC #8 "May 2026"**, 24,242 ranked items, all
  `Books::Book`. 624 `ranked_lists`.
- 126,254 books · 24,362 on ≥1 curated list · 37,111 with a primary image · 1,044 `Books::List`.
- 23,972 of 24,242 ranked books have a `summary`/`en` description.
- Books has **only** `Books::DefaultController` and a placeholder view. No public controllers, no
  components, no `paging.css`, no robots mechanism, no sitemap infrastructure anywhere in the app.
- `public/robots.txt` is the stock Rails file with no rules.

### Legacy URL facts

- **`/books/:id` is the legacy canonical book URL** — `resources :books, only: [:show, :create]`
  inside `scope "(/rc/:ranking_configuration_id)"` (legacy `config/routes.rb:253-254`). Every legacy
  view links via `book_path`. `/items/:id` (line 205) is the *older* alias.
- Legacy serves **every** book id with no gating and no `noindex`, so ~156k legacy book pages are
  indexable today.
- Legacy's canonical ranked view is the **list** view with per-book descriptions; `/v/grid` and
  `/v/table` are `noindex, follow`. Promoting the grid to canonical is a deliberate SEO change.

### The numeric-slug collision

**137** `Books::Book` rows have a purely numeric slug and **124** collide with a real book id.
(The carryover said 136; re-measured 2026-07-31.) Worked example:

- slug `"1"` belongs to book **id 22550**, 北斗の拳（1）
- book **id 1** is *The Adventures of Augie March*, slug `the-adventures-of-augie-march`

So `/book/1` and `/books/1` must resolve to **different books**. This is why the singular/plural URL
split is load-bearing — one segment cannot serve both.

friendly_id 5.7.0 `FinderMethods#find` tries the **slug first**, then falls back to the primary key
(`first_by_friendly_id(id)` … `return super if potential_primary_key?(id)`). `Books::Book` declares
`friendly_id :slug_candidates, use: [:slugged, :finders]`, so a bare `Books::Book.find(params[:id])`
is slug-first too. **Anywhere in this feature that passes a param to `.find` is a bug.**

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Every book gets a `/book/:slug` page; unranked books are `noindex, follow` | Keeps ~156k legacy `/books/:id` URLs 301-ing to a real page instead of 404-ing, without adding ~100k thin pages to the index. |
| D2 | Site-wide `noindex` until cutover, gated by `ENV["BOOKS_PUBLIC_INDEXING"]` (default off) | `new.thegreatestbooks.org` serves the same content as the live legacy apex; anything indexable there competes with the site it replaces. The per-book logic still ships and is unit-tested, so it is correct the day the flag flips. |
| D3 | No sitemap in this work | No sitemap infrastructure exists, and a host that should not be crawled does not need one. Revisit at cutover. |
| D4 | Any URL carrying `/rc/:ranking_configuration_id` is `noindex, follow` | The canonical URL never carries `/rc/`. An alternate RC is the same 24,242 books reordered — near-duplicate content. Applies even when the id *is* the default primary. |
| D5 | The ranked index is the **root path** `/`, paginated as `/page/2`…`/page/243`. `/the-greatest-books` 301s to `/` | Matches legacy exactly (`root to: "default#index"`, `get "/page/:page"`, `get "/the-greatest-books", to: redirect("/")`). The index is emphatically **not** at `/books` — that is a permanent 301 namespace holding ~156k indexed legacy URLs, and a future `/books/1952` would be ambiguous between "book id 1952" and "books from 1952". The deferred year/category increments keep their legacy paths (`/the-greatest-books/since/:year`), which stand alone and need no index there. |
| D5a | Pagination is path-based, via a shared opt-in `Pagy::PathBasedPaging` extension | Owner requirement, and it preserves legacy's indexed `/page/N` URLs. `?page=N` keeps working as an input, so no 301s are needed. See "Path-based pagination" below. |
| D6 | Book lookups are explicit: `find_by!(slug:)` for `/book/:slug`, `find_by!(id:)` for legacy redirects | friendly_id's slug-first `find` returns the wrong record for the 124 colliding slugs. |
| D7 | Grid query is plain SQL behind a `Books::RankedBooksQuery` seam | See "Query engine" below. |
| D8 | The grid query does **not** join `books_books` | The join exists in games only to support year filtering. Dropping it lets Postgres use `index_ranked_items_on_config_and_rank`: **33.0 ms → 5.3 ms** at the deepest offset. |
| D9 | Description source byline only when the license requires it (`cc_by_sa_4`, `cc0`) | CC BY-SA 4.0 attribution is a license condition. The 23,916 `ai_generated`/`goodreads` books render exactly as legacy does. |
| D10 | Grid ladder is `grid-cols-2 sm:3 md:4 lg:5 xl:6`, not the games `1/2/3/4` | Book covers are 326×500; games' are 810×1080. Games looks crisp because it renders an 810px source into a ~294px card (2.75× oversample). Books in that same card is 1.1× — visibly soft, and book covers are mostly typography, the worst case for undersampling. The denser ladder pins cards to 163–231px, keeping 1.4–2.0× oversample. |
| D11 | Serve the **original** cover blob; no new variant | 326×500 is already correctly sized for a 163–231px card. The existing variants are the wrong shape — `:large` is `resize_to_limit: [250, 250]`, which for a 2:3 cover yields 166×250, *below* display size. |
| D12 | Grid only in this spec; table view is a later increment | The card reserves a slot for the planned 1-sentence AI descriptions, which is what will let the grid carry the information legacy's list view carried. List view is being retired. |
| D13 | Book page's "Appears on these lists" ships in increment 1 as plain text, becomes links in increment 2 | It is a signature feature of the legacy book page and is real content unlinked. The conversion is one line. |

### Query engine (D7)

Researched the legacy implementation before deciding. `BookListQuery` → `Search::Books.advanced_search`
uses OpenSearch as a **filter engine only**: it runs with `disable_paging: true`, pulls *every*
matching id (scroll API past 10k hits), then `Book.where(id: book_ids)`, then **sorts in Postgres**
via `sorted_by_rank` — which joins `ranked_books` and orders by score — then paginates. OpenSearch
never eliminates the rank join.

Three reasons not to adopt it now:

1. For the unfiltered grid it is strictly worse — 24,242 ids round-tripped out of OpenSearch and back
   into a Postgres `IN` clause to reach the same rank join.
2. The new app's `Search::Books::BookIndex` maps exactly seven fields — `title`, `subtitle`,
   `alternate_titles`, `author_names`, `author_ids`, `category_ids`, `book_kind`. No year, no country,
   no language, no score. Every filter legacy leans on OpenSearch for is unindexed. Adopting the
   pattern means an expanded mapping plus a reindex of 126,254 books.
3. v1 has no filters at all.

So: plain SQL, but extracted into `Books::RankedBooksQuery` rather than inlined in the controller as
games does. Controller and views only ever see a paginatable `RankedItem` relation, so the later
filter increment can swap in OpenSearch — or a materialized view — inside that one object.

Materialized views are the right future tool for legacy's `categories_with_shared_books_count` /
`countries_with_shared_books_count` facet aggregates, which is where SQL genuinely gets painful. Not
for the ranked grid.

## Increment 1

### Routes

Inside the existing books `DomainConstraint` block, after `namespace :admin`:

```ruby
# Legacy 301s. Numeric-constrained so they never shadow /book/:slug.
# The rc scope covers /books/:id and /rc/52/books/:id in one route; legacy RC ids
# are meaningless here, so the redirect drops them.
scope "(/rc/:ranking_configuration_id)" do
  get "books/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}
end
get "items/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}

scope "(/rc/:ranking_configuration_id)" do
  get "book/:slug", to: "books/books#show", as: :book
end

# Ranked index. Root is canonical; pagination is path-based (D5a).
# Order matters: /page/1 must be declared before the generic /page/:page.
root to: "books/ranked_items#index", as: :books_root
get "page/1", to: redirect("/", status: 301)                # collapse the duplicate
get "page/:page", to: "books/ranked_items#index", as: :books_page, constraints: {page: /\d+/}
get "the-greatest-books", to: redirect("/", status: 301)    # legacy, matches its own redirect
get "rc/:ranking_configuration_id", to: "books/ranked_items#index", as: :books_rc
get "rc/:ranking_configuration_id/page/:page", to: "books/ranked_items#index", as: :books_rc_page,
  constraints: {page: /\d+/}
```

Resulting URL map:

| URL | Serves | Indexable |
|---|---|---|
| `/` | ranked grid, page 1 | yes (at cutover) |
| `/page/2` … `/page/243` | ranked grid, page N | yes (at cutover) |
| `/page/1` | → 301 `/` | — |
| `/the-greatest-books` | → 301 `/` | — |
| `/rc/:id`, `/rc/:id/page/:page` | alternate RC | never (D4) |
| `/book/:slug` | detail | when ranked (D1) |
| `/books/:id`, `/rc/:x/books/:id`, `/items/:id` | → 301 `/book/:slug` | — |
| `/lists`, `/lists/:id` | increment 2 | yes (at cutover) |

The `lists` routes are **not** added here — they land in increment 2 alongside their controller.
Increment 1's layout nav therefore cannot link to Lists yet; that entry is wired in increment 2.

`Books::LegacyBooksController#show` — `Books::Book.find_by!(id: params[:id])`, then
`redirect_to book_path(book.slug), status: :moved_permanently`.

### Indexability

`Books::PublicIndexing.enabled?` (new, `app/lib/books/public_indexing.rb`) reads
`ENV["BOOKS_PUBLIC_INDEXING"]`, default **false**. The layout always emits a robots meta, via a helper
added to the existing `Books::DefaultHelper`:

```ruby
def books_robots_content
  return "noindex, follow" unless Books::PublicIndexing.enabled?
  return "noindex, follow" if params[:ranking_configuration_id].present?
  @indexable ? "index, follow" : "noindex, follow"
end
```

Controllers set `@indexable`: grid and lists `true`, book show `@ranked_item.present?`. `follow`
throughout, so rc-scoped pages still pass link equity to canonical book pages.

### Path-based pagination

pagy 43.5.6 does not support `/page/N` out of the box, and **two independent defects** must be fixed —
which is why previous attempts stalled. Both were verified experimentally against the installed gem.

**Defect 1 — reading.** `Pagy::Request#get_params` is `request.GET.merge(request.POST).to_h`. Rails
route params are never included, so a `/page/12` route resolves to page **1** no matter what URL
generation does. Measured:

```
query string only (pagy's default view of params) -> resolve_page = 1
route param included                              -> resolve_page = 12
```

**Defect 2 — writing.** `a_lambda` composes a *single* templated URL containing the sentinel
`Pagy::PAGE_TOKEN` (the two-character string `"P "`), then `split`s it and interpolates each page
number. A page-1 special case — `/` rather than `/page/1` — cannot be expressed in one template, and
naive overrides destroy the token (`PAGE_TOKEN.to_i == 0`), emitting malformed HTML like
`<a href="/"11 rel="prev">`.

Both `compose_url` and `get_params` are marked "Overriding support" in the gem. The extension lives in
`config/initializers/pagy.rb` as **shared, opt-in** infrastructure — not books-namespaced — activated
only when a `:page_path` option is present, so every other domain is provably unaffected:

```ruby
module Pagy::PathBasedPaging
  def compose_url(absolute, path, params, fragment)
    builder = @options[:page_path]
    return super unless builder

    page  = params.delete(@options[:page_key] || :page)
    query = Pagy::Linkable::QueryUtils.build_nested_query(params).sub(/\A(?=.)/, '?')
    "#{@request.base_url if absolute}#{builder.call(page)}#{query}#{fragment}"
  end

  # pagy templates one URL with PAGE_TOKEN and string-splits it per page, which makes
  # the page-1 special case inexpressible. Build each href for real instead; the
  # templating is only a speed optimisation, irrelevant for a 7-anchor nav.
  def a_lambda(anchor_string: @options[:anchor_string], **opts)
    return super unless @options[:page_path]

    lambda do |page, text = page_label(page), classes: nil, aria_label: nil|
      rel = case page
            when @previous then %( rel="prev")
            when @next     then %( rel="next")
            end
      %(<a href="#{compose_page_url(page, **opts)}"#{
        %( #{anchor_string}) if anchor_string}#{
        %( class="#{classes}") if classes}#{rel}#{
        %( aria-label="#{aria_label}") if aria_label}>#{text}</a>)
    end
  end
end
Pagy::Offset.prepend(Pagy::PathBasedPaging)
```

Defect 1 is fixed by passing route params through in the controller. `request.params` includes both
route and query params; `controller`/`action` must be stripped so they never leak into a query string:

```ruby
def pagy_path_request
  {base_url: request.base_url, path: request.path,
   params: request.params.except("controller", "action").to_h}
end
```

The books controllers then pass a builder using real route helpers — no string surgery:

```ruby
pagy(query, limit: 100, request: pagy_path_request,
     page_path: ->(n) { n.to_i <= 1 ? books_root_path : books_page_path(n.to_i) })
```

**`?page=N` keeps working as an input**, so no redirects are needed for existing links. Verified:

| Request | Resolved page | Generated "next" link |
|---|---|---|
| `/` | 1 | `/page/2` |
| `/?page=7` | 7 | `/page/8` |
| `/page/7` | 7 | `/page/8` |

Generated links are always path-based. Route params win over query params in Rails, so `/page/7?page=9`
is deterministic (page 7).

**Admin keeps `?page=`.** All 19 admin controllers are auth-gated and `noindex`; path-based pagination
there is churn with no benefit.

### Ranked grid

`Books::RankedItemsController < RankedItemsController` — `Pagy::Method` + `Cacheable`,
`layout "books/application"`, `before_action :find_ranking_configuration`,
`:validate_ranking_configuration_type`, `:cache_for_index_page`. `ranking_configuration_class` returns
`Books::RankingConfiguration`. **No `parse_year_filter`** — `Filters::YearFilter` only parses
`/^\d{4}$/` and ranked books span -2400..2064 (165 negative, 530 null).

```ruby
# Books::RankedBooksQuery.call(ranking_configuration:)
RankedItem
  .where(ranking_configuration_id: rc.id, item_type: "Books::Book")
  .includes(item: [{book_authors: :author}, :primary_image])
  .order(:rank)
```

100 per page, matching games and legacy's `@limit = 100`.

`Books::CardComponent` — cover, rank badge, title, `by <authors>`, year. `book_authors` is already
`-> { order(:position) }`. No category badges (no category pages to link to). No user-list widget
until increment 3, but the card ships `data-listable-type` / `data-listable-id` from the start so
increment 3 is purely additive. Takes an `index:` for the eager/lazy image split.

`Books::DefaultController`, its view and test are deleted; `e2e/tests/books/homepage.spec.ts` is
rewritten against the grid. The layout nav's three dead links (all currently pointing at `/`) become
Books → `books_root_path` in this increment and Lists → `books_lists_path` in increment 2;
**Authors is removed** — no author pages in v1, and a nav link to nowhere is worse than no link.

### Book detail page

`Books::BooksController#show`, mirroring `Games::GamesController` — `Cacheable`,
`load_ranking_configuration`, `cache_for_show_page`:

```ruby
@book = Books::Book
  .includes(:categories, :descriptions, {book_authors: :author})
  .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
  .find_by!(slug: params[:slug])

@ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @book)
@indexable   = @ranked_item.present?
@categories_by_type = @book.categories.active.group_by(&:category_type)
```

`:descriptions` **must** be preloaded — `primary_description` runs `Descriptions::Resolver` over the
association in Ruby.

Sections: cover · title (+ `subtitle`, present on 43% of ranked books) · `by <authors>` · rank
sentence when ranked · description + license byline · categories grouped by `category_type` · appears
on these lists.

The lists section mirrors legacy's intersection of the book's lists with the RC's lists:

```ruby
@list_items = @book.list_items
  .joins(:list)
  .where(list_id: @ranking_configuration.ranked_lists.select(:list_id))
  .where(lists: {status: :active})
  .includes(:list)
  .order(Arel.sql("list_items.position ASC NULLS LAST"), "lists.name")
```

### Description sources and attribution

`Descriptions::SourcePriority::ORDER` is `manual, ai_generated, goodreads, wikipedia, openlibrary,
publisher, musicbrainz, igdb, other`. Resolved across all 24,242 ranked books, the description that
actually renders is:

| Source | Books | License |
|---|---:|---|
| `ai_generated` | 21,938 | — |
| `goodreads` | 1,978 | `proprietary` |
| `wikipedia` | 26 | `cc_by_sa_4` |
| `openlibrary` | 18 | `cc0` |
| `other` | 12 | — |

The byline renders only for `license_cc_by_sa_4?` or `license_cc0?` (the enum is `prefix: true`),
linking `source_url` with `rel="noopener"` when present. Goodreads-sourced descriptions already serve
unattributed on the live legacy site via `description_to_display`; that is unchanged.

## Increment 2 — lists

`Books::ListsController` transcribes `Games::ListsController`: `Pagy::Method` + `Cacheable`,
`load_ranking_configuration`, caching on both actions.

- `index` — the RC's `ranked_lists` joined to `lists` where `type = "Books::List"`,
  `includes(list: :list_items)`, `order(weight: :desc)`, `limit(50)`. Cards show weight, item count,
  name, `source`, truncated `description`. `Books::List` still has a plain `description` column — the
  descriptions subsystem did not absorb `List`.
- `show` — `Books::List.find(params[:id])` (numeric; legacy ids preserved, no friendly_id), with
  `list_items.includes(listable: [{book_authors: :author}, :primary_image])` ordered by
  `position ASC NULLS LAST`, paginated at 100.
- Converts the book page's list names into links (D13) and wires the layout's Lists nav entry.

If list-detail pagination uses a Turbo Frame, it **must** carry `data: {turbo_action: "advance"}` —
the games equivalent does not, which breaks the back button, deep links, and crawler discovery of
pages 2+.

## Increment 3 — user lists

| Change | Location |
|---|---|
| `DOMAIN_SUBCLASSES["books"] = %w[Books::UserList]` | `app/models/user_list.rb:41` |
| `DEFAULT_SUBCLASSES += Books::UserList` | `app/models/user_list.rb:28` |
| `Books::Book ↔ Books::UserList` in `_matchesListable` **and** `_listClassFor` | `user_list_modal_controller.js:229` |
| `when :books then "books/application"` | `MyListsController#resolve_layout` |
| `data-controller="user-list-state"`, `Toast::RegionComponent`, `UserLists::ModalComponent`, `_user_list_icon_template`, My Lists nav link | `layouts/books/application.html.erb` |
| `GET /user_lists` → 301 `/my/lists` | routes |

Adding the `DOMAIN_SUBCLASSES` key is what makes `UserListStateController` and
`UserListsController::ALLOWED_TYPES` work — without it the modal opens and the create 422s.
`DEFAULT_SUBCLASSES` uses `find_or_create_by!` on `(user, list_type)`, so the 69,459 migrated users do
not get duplicates.

Stale comments at `user_list.rb:38` and `my_lists_controller.rb:71` are updated. `csv_row`'s `else`
branch already works — `Books::Book#release_year` exists, aliasing `first_published_year`, so
dummy-UI spec decision D3 is confirmed stale.

Public user-list **viewing** stays deferred to 02d. Only 115 of 282,922 `Books::UserList` rows are
public (95 with items); those 404 for non-owners until then.

## UI standards (normative)

Verified against the compiled `app/assets/builds/*.css`, pagy 43.5.6 source, and the real image corpus.

### Bugs in the games implementation — do not inherit

| # | Problem | Books must |
|---|---|---|
| B1 | **No `loading="lazy"` on any `<img>` in the app.** `grep -rn "loading:" app/views app/components` returns only `turbo_frame_tag` hits. | Lazy-load every cover below the first row. |
| B2 | **`prose` is a no-op.** `@tailwindcss/typography` appears **0 times** in `package.json` and `yarn.lock`; the only `.prose` rule in the build is a DaisyUI custom property nothing consumes. `max-w-none` cancels a max-width that was never set. | Never use `prose`. Style the description explicitly. |
| B3 | **Books has no `paging.css`** and no `@import` for one. | Add both. |
| B4 | **All existing `paging.css` files target pagy-9 selectors pagy 43 no longer emits.** `series_nav` renders the current page as `<a role="link" aria-disabled="true" aria-current="page">` — no `class="current"` — and gaps as `<a role="separator" aria-disabled="true">` — no `class="gap"`. Because the current page has no `href`, `a:not([href]) { btn-disabled }` catches it: **the current page renders greyed-out, the opposite of highlighted.** | Use the corrected selectors below. |
| B5 | **`badge-ghost hover:badge-primary` is a dead hover in DaisyUI 5** — `hover:badge-primary` only sets `--badge-color`, while `.badge-ghost` sets `background-color` directly and wins. | Books' category badges are static; plain `badge badge-ghost`. |
| B6 | **`<html>` has no `lang`.** All four public layouts lack it. WCAG 3.1.1 Level A failure. | `<html lang="en" data-theme="cmyk">`. |
| B7 | **Double container.** The layout wraps `yield` in `<main class="container mx-auto px-4 py-8">` and every games view opens another. Horizontal padding doubles to 64px — 32px of lost width on a 375px phone. | Books views start at `<div class="space-y-8">`, no second container. |
| B8 | **Turbo-framed pagination does not advance the URL** (`games/lists/show.html.erb:88`). | Add `data: {turbo_action: "advance"}` or use full-page nav. |
| B9 | **Two links per card to the same URL** — the figure link's accessible name is the `alt`, so AT announces each card twice and there are 200 tab stops per page. | One link per card, stretched-link pattern. |

`shadow-xl`, `shadow-2xl`, `shadow-md`, `rounded-xl`, `rounded-box`, `badge-lg`, `line-clamp-2`,
`aspect-[3/4]`, `transition-shadow` all compile correctly under Tailwind 4.3.1 / DaisyUI 5.6.3. The
`shadow-sm`→`shadow-xs` v3→v4 rename touches nothing these views use. **No migration sweep needed.**

### Grid and images

```
grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6
```

| Viewport | Cols | Card | Cover @2:3 |
|---|---|---|---|
| 375 | 2 | 163px | 245px |
| 768 | 4 | 166px | 249px |
| 1280 | 6 | 188px | 282px |
| 1536 | 6 | 231px | 347px |

Card width stays in a 163–231px band at every breakpoint, so one source size serves all of them.
`@container` queries are overkill — the card renders in exactly one context whose width is a pure
function of the viewport. Revisit only if the card is reused inside a narrow rail.

Use `card card-sm` rather than `card` + `card-body p-4` — `card-sm` sets padding, font size, and title
size coherently. Cover goes flush in a `<figure>` with no padding; DaisyUI 5's `.card figure:first-child`
already clips corners.

```erb
<figure class="bg-base-200">
  <%= image_tag rails_public_blob_url(book.primary_image.file),
      alt: "",
      loading: index < 6 ? "eager" : "lazy",
      decoding: "async",
      fetchpriority: index < 6 ? "high" : "auto",
      class: "w-full aspect-[2/3] object-cover" %>
</figure>
```

`w-full aspect-[2/3]` solves CLS without width/height attributes. The first 6 cards are eager +
high priority for LCP — Chrome does not prioritise lazy images, so lazy-loading the first row
measurably regresses LCP. Placeholder for the ~16% without a cover uses the same box and
`aria-hidden="true"` (games renders a literal "No Image" string, which AT reads on every coverless card).

On the detail page, use the **real blob dimensions** from `file.blob.metadata` with `w-full h-auto`
rather than an aspect box — the corpus contains 16:9 outliers that `aspect-[2/3] object-cover` would
mangle at detail size. Fall back to `aspect-[2/3] object-contain` when metadata is nil. Constrain the
mobile cover with `max-w-[180px] sm:max-w-[240px] lg:max-w-none`, or a 2:3 cover eats 70% of a 667px
viewport before the title appears.

**Do not add `self-start` to the detail page's sticky sidebar** — `sticky top-8` works *because* the
grid item stretches to full row height; `self-start` silently kills it. Sticky also dies if any
ancestor gains `overflow-hidden`.

### Pagination

pagy's default `SERIES_SLOTS = 7` yields 9 anchors ≈ 428px against 343px available at 375px — it
wraps to two ragged rows rather than overflowing. Use `slots: 5` (7 anchors ≈ 332px, one row) plus a
plain-text "Page N of 243" line. Do not wrap pagy's output in a second `<nav>` — it already emits one
with `aria-label="Pages"`.

New `app/assets/stylesheets/books/paging.css`, plus `@import "./paging.css";` in
`books/application.css`:

```css
.pagy {
  @apply flex flex-wrap justify-center items-center gap-1 font-semibold text-sm;

  a { @apply btn btn-sm btn-ghost; }

  /* Disabled prev/next and the "…" separator — but NOT the current page. */
  a:not([href]):not([aria-current]) { @apply btn-disabled; }

  /* pagy 43 marks the current page with aria-current, not class="current". */
  a[aria-current="page"] { @apply btn-primary pointer-events-none; }
}
```

A jump-to-page input is explicitly out of scope — pagy's JS is not bundled
(`Pagy.sync_javascript` is commented out in `config/initializers/pagy.rb`).

### Theme, typography, accessibility

**No `dark:` variants.** The layout pins `data-theme="cmyk"` and the books CSS registers exactly one
theme. `dark:` keys off the OS `prefers-color-scheme`, which is independent of `data-theme`, so a
`dark:` class would fire on a page still rendering the light cmyk palette. Semantic DaisyUI tokens
only — `bg-base-100`, `text-base-content`, `badge-primary` — never raw palette colors.
`text-base-content/50` on `bg-base-200` measures **~3.3:1** and fails AA; **`/70` is the floor for
body text, `/80` preferred.**

Move the font rules into `@layer base`. They are currently unlayered, and unlayered CSS beats any
layered rule — so the bare `h1…h6` selector makes `font-sans` on a heading a no-op. Trim the Google
Fonts request to `Lora:ital,wght@0,400;0,600;1,400` + `Playfair+Display:wght@700`; `card-title` is
`font-weight: 600` in DaisyUI 5, so Lora 600 must stay. Add `text-balance` to the detail `<h1>`.

- Cover alt: `""` on grid cards (the adjacent title link carries the name), `"Cover of #{title}"` on
  detail, `aria-hidden="true"` on placeholders.
- Headings: grid `<h1>` page title, card titles are real `<h2>` elements — `card-title` carries no
  semantics. Detail `<h1>` book title; the subtitle is a `<p>`, not an `<h2>`; section headings `<h2>`;
  category-type labels `<h3>`.
- Rank badge needs `<span class="sr-only">Rank </span>#42` — colour and position alone don't convey it.
- Stretched link with `has-[a:focus-visible]:outline-2` on the card, so the ring shows for keyboard
  but not mouse. **Increment 3 landmine:** `after:inset-0` covers the whole card including the
  `UserLists::CardWidgetComponent` button — `relative z-10` on the `card-actions` wrapper is
  load-bearing, or the add-to-list button is unclickable.
- Add a skip link to the layout.

## Tests

Controller tests assert behavior only — status codes, assigns, redirect targets — never markup, per
`docs/testing.md`.

- **The collision guard:** `/books/1` and `/book/1` resolve to different books, and the 301 target is
  the id-book's slug. This is the regression test for D6.
- **Pagination URLs:** `/page/2` resolves to page 2 (guards defect 1); the nav on page 2 links to `/`
  and not `/page/1` (guards defect 2); `/?page=7` still resolves to page 7; `/page/1` and
  `/the-greatest-books` 301 to `/`. Plus a `Pagy::PathBasedPaging` unit test asserting that a pagy
  call **without** `:page_path` still emits `?page=N`, so the other domains cannot regress.
- `books_robots_content` across all four combinations of `PublicIndexing.enabled?` × `@indexable`,
  plus the `/rc/:id` override.
- `assert_queries_count` on the grid, pinning the `book_authors` / `primary_image` preloads.
- `Books::RankedBooksQuery` unit test; `Books::CardComponent` component test.
- Routing test: books host matches; `/`, `/page/:page`, `/rc/:id` and `/rc/:id/page/:page` resolve to
  `books/ranked_items#index`; numeric constraints hold. Note `get "the-greatest-books"` is an exact
  single-segment match, so it does not shadow the deferred `/the-greatest-books/since/:year` family.
- Playwright per increment: grid + detail (1), lists (2), add-to-list flow (3).

## Verification gate

Every increment, before it is called done:

- `bin/rails test` from `web-app/`
- `bundle exec standardrb`
- `yarn build:all` — must emit `app/assets/builds/books.css`
- `npx playwright test --config=e2e/playwright.config.ts --project=books` green

## Risks

| Risk | Mitigation |
|---|---|
| A `.find(params[:id])` slips into a controller and silently serves the wrong book for 124 slugs | D6 makes both lookups explicit; the collision test is the guard. |
| `BOOKS_PUBLIC_INDEXING` flipped on before cutover → duplicate content against the live legacy apex | Defaults to false and is set nowhere; flipping it is a deliberate deploy-time act at cutover. |
| Grid feels sparse versus games' larger cards | Deliberate (D10) and driven by source resolution, not taste. If it reads too dense in review, the ladder is one class string to change. |
| The 8.9 MB cover PNG dominates page 1 | Tracked as data cleanup below; not a code change. |

## Follow-ups (tracked, not in scope)

1. **Fix pagination in the other three domains** — owner wants this, sequenced as its own PR because
   it touches three live sites. Two parts:
   - *CSS.* All are broken, differently: music targets dead `.current`/`.gap` selectors *and* uses raw
     `bg-gray-*`/`text-gray-*` that ignore the DaisyUI theme; games targets the dead selectors; movies
     has **no `paging.css` at all**. The books file above is the correct template for all three.
   - *Path-based URLs.* The `Pagy::PathBasedPaging` extension is already shared, so adoption is
     per-surface: **12 public `pagy(` call sites** (`music/{albums,songs,artists}/{ranked_items,lists,
     categories}`, `games/{ranked_items,lists,categories}`, `my_lists`), each needing a `/page/:page`
     route variant plus a `page_path:` lambda. `?page=N` continues to work, so no 301s are required.
     Admin's 19 call sites stay on `?page=`.
2. **Resize one cover.** `The_Sound_and_the_Fury_281929_1st_ed_dust_jacket29.png` is 1613×2370 / 8.9 MB
   and is more than half of grid page 1 by itself. Median cover is 28.5 KB; page 2 totals 2.63 MB.
3. **1-sentence AI descriptions**, which unlock both the grid card description slot and table view.
4. **Cutover checklist** — flip `BOOKS_PUBLIC_INDEXING`, build a sitemap, decide apex DNS.
