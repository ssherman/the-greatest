# Path-Based Pagination for Games, Music, and My Lists — Design

**Status:** Design approved by owner 2026-08-01. Spec pending owner review.
**Goal:** Move every paginated public page onto `/page/N` paths instead of `?page=N`, behind one
shared abstraction, so pages are cleanly cacheable at the Cloudflare edge.
**Why now:** Books shipped path-based pagination in its increment-1 work and it is proven in
production. Games and music still emit `?page=N`, and their `paging.css` files are visibly broken.

## Motivation

**Cloudflare caching, not SEO.** The owner does not care about SEO or redirects for this change.
Path-based URLs are unambiguous cache keys: `expires_in 6.hours, public: true` (from `Cacheable`)
already makes these pages edge-cacheable, and a distinct path per page means each is its own cache
entry with no dependence on query-string cache-key configuration.

**`?page=N` must keep working.** Both forms land in `params[:page]` (route params win in Rails), so
existing links keep resolving. No redirects are added.

## Scope

**In:** a `Pagination::PathBuilder` object, a `PathBasedPagination` controller concern, `/page/:page`
routes for every paginated games/music/My Lists action, migrating books onto the shared concern,
`turbo_action: "advance"` on the four frame-paginated views, and rewritten `paging.css` for games and
music.

**Out:** the books filter URL grammar (its own spec — see below); auto-scroll/infinite pagination
(owner explicitly deferred); any redirect routes.

### Why the filter grammar is a separate spec

The legacy books site generates filtered URLs with `BooksHelper#filtered_books_path` — a ~60-line
conditional producing this grammar:

```
[/rc/:id]  /the-greatest-books                     (no category)
           | /the-greatest/:cat,slugs/books        (categories, comma-joined)
           [/written-by/:country,slugs/authors]
           [/of/:y | /since/:y | /to/:y | /from/:a/to/:b]
           [/page/:n]
```

Reproducing it needs both generation *and* parsing back into filter state, which is a project in its
own right. Notably, **the legacy helper accepts `page:` but never uses it** — `page` only
participates in its "are any filters set?" guard, and pagination is handled entirely separately by
explicit `/page/:page` routes plus Kaminari's `next_page_path`. Legacy already treats filters and
paging as separate concerns, which is the same split this design takes.

`PathBuilder` takes `base_path` as a constructor argument precisely so that work plugs in later: a
future `Books::FilterPath` computes `base_path` from filter state and hands it to the identical
builder. `PathBuilder` never learns about filters.

## Architecture

### `app/lib/pagination/path_builder.rb`

Sole responsibility: turn a page number into a path.

```ruby
module Pagination
  class PathBuilder
    PAGE_SEGMENT = %r{/page/\d+\z}

    def self.from_request(request)
      new(base_path: request.path.sub(PAGE_SEGMENT, ""))
    end

    def initialize(base_path:)
      @base_path = base_path.chomp("/").presence || "/"
    end

    attr_reader :base_path

    # pagy invokes this through its :page_path option
    def call(page)
      page = page.to_i
      return base_path if page <= 1
      (base_path == "/") ? "/page/#{page}" : "#{base_path}/page/#{page}"
    end
  end
end
```

`from_request` strips a trailing `/page/N` so paging from page 2 to 3 replaces rather than appends.
Page 1 returns the bare path, so navs never emit `/page/1`.

### `app/controllers/concerns/path_based_pagination.rb`

```ruby
module PathBasedPagination
  extend ActiveSupport::Concern

  private

  def pagy_path_options
    {request: pagy_path_request, page_path: Pagination::PathBuilder.from_request(request)}
  end

  # pagy appends whatever params it is handed as a query string after removing the
  # page key. request.params includes PATH parameters, so passing it whole emits
  # /albums/since/1990/page/2?year=1990 -- duplicating the filter into a query
  # string and fragmenting the edge cache. Pass only real query params, plus the
  # page (which pagy needs in order to resolve the current page from the route).
  def pagy_path_request
    {
      base_url: request.base_url,
      path: request.path,
      params: request.query_parameters.merge(
        request.path_parameters.slice(:page).stringify_keys
      )
    }
  end
end
```

Call sites become:

```ruby
@pagy, @albums = pagy(scope, limit: 100, **pagy_path_options)
```

**This fixes a latent bug in books.** Books' shipped `pagy_path_request` strips `controller`,
`action`, and `ranking_configuration_id` *by name*; it is correct only because its paginated routes
carry no other path parameters. The generic version is correct for any route.

### Why pagy needs this at all

`Pagy::Request#get_params` is `request.GET.merge(request.POST)`, so Rails route parameters never
reach pagy and a `/page/12` route would otherwise resolve to page 1. The `Pagy::PathBasedPaging`
initializer (shipped with books) supplies the `:page_path` option and overrides `a_lambda`; this
design adds no changes to it.

## Routes

Every paginated action gains a `/page/:page` sibling with `constraints: {page: /\d+/}` — **24 new
route lines** in total (7 games + 15 music + 2 My Lists).

**Games (7):** root `/page/:page` · `/video-games/page/:page` ·
`/video-games/{since,through}/:year/page/:page` · `/video-games/:year/page/:page` ·
`/lists/:id/page/:page` · `/categories/:id/page/:page`

**Music (15):** `/albums/page/:page` and its three year variants · the same four for `/songs` ·
`/artists/page/:page` · `/albums/lists/page/:page` · `/albums/lists/:id/page/:page` ·
`/songs/lists/page/:page` · `/songs/lists/:id/page/:page` · `/albums/categories/:id/page/:page` ·
`/artists/categories/:id/page/:page`

**My Lists (2):** only `show` paginates — `index` does not — but it is reachable at two paths, so
both `my/lists/:id/page/:page` and the legacy alias `user_lists/:id/page/:page` are needed.

No ordering hazard: year routes are constrained to `\d{4}(s|-\d{4})?`, which `page` cannot match, so
`/albums/page/2` cannot be captured by `/albums/:year`.

## Controllers converted

| Domain | Action |
|---|---|
| Games | `ranked_items#index`, `lists#show`, `categories#show` |
| Music | `albums/ranked_items#index`, `songs/ranked_items#index`, `artists/ranked_items#index`, `albums/lists#index`, `albums/lists#show`, `songs/lists#index`, `songs/lists#show`, `albums/categories#show`, `artists/categories#show` |
| Shared | `my_lists#show` (`index` does not paginate) |
| Books | `ranked_items#index` — migrated onto the concern, deleting its bespoke `pagy_path_request` and `ranked_books_page_path` |

My Lists is auth-gated and never edge-cached; it is included for a single app-wide mechanism and
because the deferred auto-scroll work will want stable per-page URLs everywhere.

## Turbo Frames

`games/lists/show`, `music/albums/lists/show`, `music/songs/lists/show`, and `my_lists/show` paginate
inside `turbo_frame_tag "list_items"` with no `turbo_action`. The frame swaps content and the URL
never changes — so on those pages path-based URLs would be inert and nothing would ever be requested
at a cacheable per-page URL.

All four get `data: { turbo_action: "advance" }`. Turbo then requests the real page URL, the server
returns a full response (cacheable), and Turbo extracts the matching frame — preserving the partial
update while producing one cache entry per page.

## Pagination styles

`app/assets/stylesheets/{games,music}/paging.css` are rewritten from the books template:

```css
.pagy {
  @apply flex flex-wrap justify-center items-center gap-1 font-semibold text-sm;

  a { @apply btn btn-sm btn-ghost; }

  /* Disabled prev/next and the "…" separator, but NOT the current page. */
  a:not([href]):not([aria-current]) { @apply btn-disabled; }

  /* pagy 43 marks the current page with aria-current, not class="current". */
  a[aria-current="page"] { @apply btn-primary pointer-events-none; }
}
```

Both files currently target pagy-9's `.current` and `.gap`, which pagy 43.5.6 does not emit — it
renders the current page as `<a role="link" aria-disabled="true" aria-current="page">` and gaps as
`<a role="separator" aria-disabled="true">`. Because the current page has no `href`, the existing
`a:not([href])` rule catches it and styles it `btn-disabled`, so **the current page renders
greyed-out — the opposite of highlighted.** That is the visible breakage.

Music additionally moves off raw `bg-gray-*` / `text-gray-*`, which ignore the DaisyUI theme. Both
files' `label`/`input` blocks are dropped: they style `input_nav_js`, and pagy's JavaScript is not
bundled (`Pagy.sync_javascript` is commented out in `config/initializers/pagy.rb`).

## Tests

- **`Pagination::PathBuilder` unit test:** root path, nested path, replacing an existing `/page/N`,
  page 1 returning the bare path, trailing-slash handling.
- **Per domain, a controller test** that `/page/2` resolves to page 2 and the rendered nav emits
  path-based hrefs.
- **The path-parameter leak guard:** on `/albums/since/1990`, assert no generated pagination link
  contains `year=`. This is the specific defect `pagy_path_request` exists to prevent, and nothing
  else would catch it.
- **`?page=2` still resolves** — the owner's explicit requirement.
- **Books' existing pagination tests stay green** through the migration; they are the regression net
  proving the shared concern matches the behavior already running in production.

## Verification gate

- `bin/rails test`
- `bundle exec standardrb`
- `yarn build:all` — emits the books, games, and music CSS bundles
- `npx playwright test --project=books` (plus games/music projects if present)

## Risks

| Risk | Mitigation |
|---|---|
| A path parameter leaks into generated query strings, fragmenting the cache | `pagy_path_request` passes only `query_parameters` + page; guarded by the year-filter test |
| Migrating books regresses production pagination | Books' existing tests are unchanged and must stay green; they cover `/page/2`, `?page=2`, and the `/page/1` redirect |
| A new `/page/:page` route shadows an existing one | All constrained to `/\d+/`; year routes require `\d{4}(s|-\d{4})?`, which cannot match `page` |
| Turbo frame pages still don't advance the URL | `turbo_action: "advance"` on all four; covered by the per-domain nav assertions |

## Follow-ups (not in scope)

1. **Books filter URL grammar** — generation and parsing for the legacy
   `/the-greatest/:cats/books/written-by/:countries/authors/from/:a/to/:b` family, plugging a
   `Books::FilterPath` into `Pagination::PathBuilder`.
2. **Auto-scroll pagination** — owner explicitly deferred; will build on the stable per-page URLs
   this design establishes.
