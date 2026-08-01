# Path-Based Pagination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every paginated page in games, music, and My Lists onto `/page/N` paths instead of `?page=N`, behind one shared abstraction, and migrate books off its bespoke implementation onto the same abstraction.

**Architecture:** Two objects with distinct jobs. `Pagination::PathBuilder` turns a page number into a path and takes `base_path` as a constructor argument — that argument is the seam a future filter grammar plugs into. `PathBasedPagination` is a controller concern that wires the builder into pagy and, critically, feeds pagy only real query parameters so route parameters cannot leak into generated query strings.

**Tech Stack:** Rails 8, Minitest + fixtures, pagy 43.5.6, Turbo, Tailwind CSS 4, DaisyUI 5.

**Spec:** `docs/superpowers/specs/2026-08-01-path-based-pagination-design.md`. Read its Architecture section before starting.

## Global Constraints

- **Working directory is `web-app/`.** Every `bin/rails`, `yarn`, and `bundle` command runs from there. Docs live at the project root in `docs/`, NOT `web-app/docs/`.
- **Lint is `bundle exec standardrb`** (`--fix` autocorrects), NEVER `bin/rubocop`. Do not run or suggest brakeman.
- **Never run destructive DB commands.** `db:drop`, `db:reset`, `db:schema:load`, and `ActiveRecord::FixtureSet.create_fixtures` are blocked by a hook and would destroy development data that takes hours to rebuild. Ordinary `bin/rails test` is fine and is all any task needs.
- **Do not touch the movies domain.** It is unimplemented. No movies routes, no movies CSS, no movies mentions in reports.
- **`?page=N` must keep working** on every converted route. This is an explicit owner requirement.
- **No redirects.** `/page/1` is not special-cased for games, music, or My Lists — the builder simply never emits it. Books keeps the `/page/1` → `/` redirect it already ships; leave that route alone.
- **DaisyUI semantic tokens only** in CSS — `bg-base-100`, `text-base-content`, `btn-primary`. Never raw palette colors (`bg-gray-200`), never `dark:` variants.
- **No code comments** beyond those the plan's code blocks already contain.
- **Every domain's ranking-configuration fixture:** `games_global`, `music_albums_global`, `music_songs_global`, `music_artists_global`, `books_global`. All are `global: true, primary: true` and are what `default_primary` returns.
- **`pagy.page_url(n)` generates a URL for any page number regardless of how many pages exist.** Tests use it to assert generated paths without seeding data.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `app/lib/pagination/path_builder.rb` | Turns a page number into a path; knows nothing about filters or pagy |
| `app/controllers/concerns/path_based_pagination.rb` | Wires the builder into pagy and sanitises the params pagy sees |
| `test/lib/pagination/path_builder_test.rb` | Unit test for the builder |

**Modified:** `config/routes.rb` (24 new route lines), 13 controllers, `app/assets/stylesheets/{games,music}/paging.css`, and four views that paginate inside a Turbo Frame.

---

### Task 1: Pagination::PathBuilder

**Files:**
- Create: `app/lib/pagination/path_builder.rb`
- Test: `test/lib/pagination/path_builder_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Pagination::PathBuilder.new(base_path:)` and `Pagination::PathBuilder.from_request(request)`. Instances respond to `#call(page)` returning a String path, and `#base_path`. `#call` is what pagy invokes through its `:page_path` option.

**Background.** `app/lib/` is an autoload root in this app (it already holds `app/lib/search/...` as `Search::` and `app/lib/services/...` as `Services::`), so `app/lib/pagination/path_builder.rb` defines `Pagination::PathBuilder`. You will need to create the `app/lib/pagination/` directory.

- [ ] **Step 1: Write the failing test**

Create `test/lib/pagination/path_builder_test.rb`:

```ruby
require "test_helper"

module Pagination
  class PathBuilderTest < ActiveSupport::TestCase
    test "page one returns the base path unchanged" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums", builder.call(1)
    end

    test "page zero and negatives collapse to the base path" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums", builder.call(0)
      assert_equal "/albums", builder.call(-3)
    end

    test "appends the page segment for later pages" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums/page/2", builder.call(2)
      assert_equal "/albums/page/243", builder.call(243)
    end

    test "handles the root path without doubling the slash" do
      builder = Pagination::PathBuilder.new(base_path: "/")

      assert_equal "/", builder.call(1)
      assert_equal "/page/2", builder.call(2)
    end

    test "strips a trailing slash from the base path" do
      builder = Pagination::PathBuilder.new(base_path: "/albums/")

      assert_equal "/albums", builder.call(1)
      assert_equal "/albums/page/2", builder.call(2)
    end

    test "accepts a string page number" do
      builder = Pagination::PathBuilder.new(base_path: "/albums")

      assert_equal "/albums/page/5", builder.call("5")
    end

    test "from_request replaces an existing page segment rather than appending" do
      builder = Pagination::PathBuilder.from_request(fake_request("/albums/page/7"))

      assert_equal "/albums", builder.base_path
      assert_equal "/albums/page/8", builder.call(8)
    end

    test "from_request keeps nested filter and scope segments" do
      builder = Pagination::PathBuilder.from_request(fake_request("/rc/12/albums/since/1990"))

      assert_equal "/rc/12/albums/since/1990/page/2", builder.call(2)
    end

    test "from_request only strips a page segment at the end" do
      builder = Pagination::PathBuilder.from_request(fake_request("/lists/page/3/page/4"))

      assert_equal "/lists/page/3", builder.base_path
    end

    private

    def fake_request(path)
      Struct.new(:path).new(path)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/pagination/path_builder_test.rb`
Expected: FAIL with `NameError: uninitialized constant Pagination`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/pagination/path_builder.rb`:

```ruby
module Pagination
  # Turns a page number into a path. Takes base_path as a constructor argument so
  # a caller that computes it some other way -- e.g. from filter state -- can reuse
  # this unchanged.
  class PathBuilder
    PAGE_SEGMENT = %r{/page/\d+\z}

    def self.from_request(request)
      new(base_path: request.path.sub(PAGE_SEGMENT, ""))
    end

    def initialize(base_path:)
      @base_path = base_path.chomp("/").presence || "/"
    end

    attr_reader :base_path

    # pagy invokes this through its :page_path option.
    def call(page)
      page = page.to_i
      return base_path if page <= 1

      (base_path == "/") ? "/page/#{page}" : "#{base_path}/page/#{page}"
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/pagination/path_builder_test.rb`
Expected: PASS, 9 tests.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/pagination/path_builder.rb test/lib/pagination/path_builder_test.rb
git add app/lib/pagination test/lib/pagination
git commit -m "Add Pagination::PathBuilder"
```

---

### Task 2: PathBasedPagination concern, with books as first consumer

**Files:**
- Create: `app/controllers/concerns/path_based_pagination.rb`
- Modify: `app/controllers/books/ranked_items_controller.rb`
- Test: `test/controllers/books/ranked_items_controller_test.rb` (existing — must stay green)

**Interfaces:**
- Consumes: `Pagination::PathBuilder.from_request(request)` from Task 1.
- Produces: `PathBasedPagination`, a controller concern exposing the private method `pagy_path_options` returning a Hash suitable for splatting into a `pagy(...)` call: `pagy(scope, limit: 100, **pagy_path_options)`.

**Background — why the concern exists at all.** pagy's `Pagy::Request#get_params` is `request.GET.merge(request.POST)`, so Rails **route** parameters never reach pagy and a `/page/12` route would otherwise resolve to page 1. The `Pagy::PathBasedPaging` initializer already in the repo (`config/initializers/pagy_path_based_paging.rb`) handles URL *generation* when given a `:page_path` option; this concern supplies that option and fixes the reading side.

**Background — the bug this fixes.** pagy appends whatever params it is handed as a query string after removing the page key. `request.params` includes **path** parameters, so passing it whole would generate `/albums/since/1990/page/2?year=1990` — duplicating the filter into a query string and fragmenting the Cloudflare cache. Books' current implementation strips `controller`, `action`, and `ranking_configuration_id` *by name*, and is correct only because its paginated routes carry no other path parameters. The concern is correct for any route.

- [ ] **Step 1: Write the concern**

Create `app/controllers/concerns/path_based_pagination.rb`:

```ruby
module PathBasedPagination
  extend ActiveSupport::Concern

  private

  def pagy_path_options
    {request: pagy_path_request, page_path: Pagination::PathBuilder.from_request(request)}
  end

  # pagy appends whatever params it is given as a query string once the page key is
  # removed, and request.params includes route parameters -- so passing it whole
  # would echo filters such as :year back into the query string. Pass only real
  # query params, plus :page, which pagy needs in order to resolve the current page
  # when it arrives as a route segment.
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

- [ ] **Step 2: Migrate the books controller onto it**

In `app/controllers/books/ranked_items_controller.rb`:

1. Add `include PathBasedPagination` directly below `include Cacheable`.
2. Replace the `pagy(...)` call in `index` with:

```ruby
    @pagy, @ranked_books = pagy(
      Books::RankedBooksQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100,
      **pagy_path_options
    )
```

3. Delete the entire `pagy_path_request` method and the `ranked_books_page_path` method, including their comments. Keep the `raise ActiveRecord::RecordNotFound if @pagy.page > @pagy.last` line and its comment — that overflow guard is unrelated to this change.

The `private` keyword now has no methods under it in this controller; remove the bare `private` line as well.

- [ ] **Step 3: Run the books tests to verify no behavior changed**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb`
Expected: PASS, all tests. These already assert `/page/2` resolves, `?page=2` resolves, `/page/1` redirects, rc-scoped links are path-based, and that `ranking_configuration_id` does not leak into generated hrefs. They are the regression net proving the shared concern reproduces the behavior running in production.

If the rc-scoped leak test fails, the cause is that `ranking_configuration_id` is a *path* parameter and `query_parameters` correctly excludes it — investigate rather than reverting to name-stripping.

- [ ] **Step 4: Run the full suite**

Run: `bin/rails test`
Expected: PASS, no failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/concerns/path_based_pagination.rb app/controllers/books/ranked_items_controller.rb
git add app/controllers/concerns/path_based_pagination.rb app/controllers/books/ranked_items_controller.rb
git commit -m "Add PathBasedPagination concern and migrate books onto it"
```

---

### Task 3: Games

**Files:**
- Modify: `config/routes.rb`, `app/controllers/games/ranked_items_controller.rb:33`, `app/controllers/games/lists_controller.rb:36`, `app/controllers/games/categories_controller.rb:18`, `app/views/games/lists/show.html.erb:79`, `app/assets/stylesheets/games/paging.css`
- Test: `test/controllers/games/ranked_items_controller_test.rb`, `test/controllers/games/lists_controller_test.rb`, `test/controllers/games/categories_controller_test.rb`

**Interfaces:**
- Consumes: `PathBasedPagination#pagy_path_options` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the games `DomainConstraint` block. Add each `/page/:page` route **immediately after** its base route so related routes stay together:

```ruby
      get "lists/:id/page/:page", to: "games/lists#show", as: :games_list_page, constraints: {page: /\d+/}
      get "video-games/page/:page", to: "games/ranked_items#index", as: :video_games_page, constraints: {page: /\d+/}
      get "video-games/since/:year/page/:page", to: "games/ranked_items#index", as: :video_games_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "video-games/through/:year/page/:page", to: "games/ranked_items#index", as: :video_games_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "video-games/:year/page/:page", to: "games/ranked_items#index", as: :video_games_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "categories/:id/page/:page", to: "games/categories#show", as: :games_category_page, constraints: {page: /\d+/}
```

And directly after `root to: "games/ranked_items#index", as: :games_root`:

```ruby
    get "page/:page", to: "games/ranked_items#index", as: :games_root_page, constraints: {page: /\d+/}
```

The `defaults:` on the since/through variants must match their base routes — without them the year filter silently changes meaning on page 2.

- [ ] **Step 2: Convert the three controllers**

In each, add `include PathBasedPagination` below the existing `include Cacheable` line, and change the `pagy(` call:

- `app/controllers/games/ranked_items_controller.rb:33` → `@pagy, @games = pagy(games_query, limit: 100, **pagy_path_options)`
- `app/controllers/games/lists_controller.rb:36` → `@pagy, @pagy_list_items = pagy(list_items_query, limit: 100, **pagy_path_options)`
- `app/controllers/games/categories_controller.rb:18` → `@pagy, @games = pagy(games_query, limit: 100, **pagy_path_options)`

- [ ] **Step 3: Make the Turbo Frame advance the URL**

In `app/views/games/lists/show.html.erb:79`, change:

```erb
    <%= turbo_frame_tag "list_items" do %>
```

to:

```erb
    <%= turbo_frame_tag "list_items", data: {turbo_action: "advance"} do %>
```

Without this the frame swaps content and the URL never changes, so the path-based URLs are never actually visited and nothing is cached per page.

- [ ] **Step 4: Rewrite the pagination stylesheet**

Replace the entire contents of `app/assets/stylesheets/games/paging.css`:

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

The old file targets pagy-9's `.current` and `.gap`, which pagy 43.5.6 does not emit — it renders the current page as `<a role="link" aria-disabled="true" aria-current="page">`. Because that element has no `href`, the old `a:not([href])` rule caught it and styled it `btn-disabled`, rendering the current page greyed-out instead of highlighted. The dropped `label`/`input` block styled `input_nav_js`, whose JavaScript is not bundled.

- [ ] **Step 5: Write the tests**

Append to `test/controllers/games/ranked_items_controller_test.rb`, inside the class:

```ruby
    test "path-based pagination resolves the page" do
      get "/video-games/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      get "/video-games?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "generated page urls are path-based" do
      get "/video-games"

      assert_equal "/video-games/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "page one links to the bare path, never /page/1" do
      get "/video-games/page/2"

      assert_equal "/video-games", @controller.view_assigns["pagy"].page_url(1)
    end

    test "year filter segments do not leak into the query string" do
      get "/video-games/1990s"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/video-games/1990s/page/2", url
      refute_includes url, "year="
    end

    test "ranking configuration scope is preserved in generated page urls" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/rc/#{ranking_configurations(:games_global).id}/video-games/page/2", url
      refute_includes url, "ranking_configuration_id="
    end
```

Append to `test/controllers/games/lists_controller_test.rb`, inside the class — replace `<LIST_FIXTURE>` with a `Games::List` fixture already referenced elsewhere in that file:

```ruby
    test "list show pagination is path-based" do
      list = <LIST_FIXTURE>

      get "/lists/#{list.id}"

      assert_equal "/lists/#{list.id}/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "list show resolves a path-based page" do
      list = <LIST_FIXTURE>

      get "/lists/#{list.id}/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end
```

Append to `test/controllers/games/categories_controller_test.rb`, inside the class — replace `<CATEGORY_FIXTURE>` similarly:

```ruby
    test "category show pagination is path-based and does not leak the id" do
      category = <CATEGORY_FIXTURE>

      get "/categories/#{category.id}"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/categories/#{category.id}/page/2", url
      refute_includes url, "id="
    end
```

Read the existing `setup` block in each file first — they already set `host!` and load fixtures; match what is there rather than inventing new setup.

- [ ] **Step 6: Run the games tests**

Run: `bin/rails test test/controllers/games`
Expected: PASS. The leak assertions (`refute_includes url, "year="` and `"id="`) are the ones that fail without the concern's `query_parameters` handling — if they pass trivially, confirm the controller actually includes `PathBasedPagination`.

- [ ] **Step 7: Verify the CSS builds**

Run: `yarn build:css:games`
Then: `grep -c "aria-current" app/assets/builds/games.css`
Expected: build succeeds; grep returns at least `1`.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/games test/controllers/games
git add config/routes.rb app/controllers/games app/views/games/lists/show.html.erb app/assets/stylesheets/games/paging.css test/controllers/games
git commit -m "Convert games to path-based pagination and fix its pagy styles"
```

---

### Task 4: Music

**Files:**
- Modify: `config/routes.rb`, `app/controllers/music/albums/ranked_items_controller.rb:29`, `app/controllers/music/songs/ranked_items_controller.rb:29`, `app/controllers/music/artists/ranked_items_controller.rb:24`, `app/controllers/music/albums/lists_controller.rb:24` and `:40`, `app/controllers/music/songs/lists_controller.rb:24` and `:33`, `app/controllers/music/albums/categories_controller.rb:18`, `app/controllers/music/artists/categories_controller.rb:18`, `app/views/music/albums/lists/show.html.erb`, `app/views/music/songs/lists/show.html.erb`, `app/assets/stylesheets/music/paging.css`
- Test: files under `test/controllers/music/`

**Interfaces:**
- Consumes: `PathBasedPagination#pagy_path_options` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the music `DomainConstraint` block. `/artists` sits outside the `(/rc/:ranking_configuration_id)` scope — put its page route beside it, outside the scope too:

```ruby
    get "artists/page/:page", to: "music/artists/ranked_items#index", as: :artists_page, constraints: {page: /\d+/}
```

Inside the `scope "(/rc/:ranking_configuration_id)"` block, each immediately after its base route:

```ruby
      get "albums/page/:page", to: "music/albums/ranked_items#index", as: :albums_page, constraints: {page: /\d+/}
      get "albums/lists/page/:page", to: "music/albums/lists#index", as: :music_albums_lists_page, constraints: {page: /\d+/}
      get "albums/lists/:id/page/:page", to: "music/albums/lists#show", as: :music_album_list_page, constraints: {page: /\d+/}
      get "albums/categories/:id/page/:page", to: "music/albums/categories#show", as: :music_album_category_page, constraints: {page: /\d+/}
      get "albums/since/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "albums/through/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "albums/:year/page/:page", to: "music/albums/ranked_items#index", as: :albums_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "songs/page/:page", to: "music/songs/ranked_items#index", as: :songs_page, constraints: {page: /\d+/}
      get "songs/lists/page/:page", to: "music/songs/lists#index", as: :music_songs_lists_page, constraints: {page: /\d+/}
      get "songs/lists/:id/page/:page", to: "music/songs/lists#show", as: :music_song_list_page, constraints: {page: /\d+/}
      get "songs/since/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_since_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "since"}
      get "songs/through/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_through_year_page,
        constraints: {year: /\d{4}/, page: /\d+/}, defaults: {year_mode: "through"}
      get "songs/:year/page/:page", to: "music/songs/ranked_items#index", as: :songs_by_year_page,
        constraints: {year: /\d{4}(s|-\d{4})?/, page: /\d+/}
      get "artists/categories/:id/page/:page", to: "music/artists/categories#show", as: :music_artist_category_page, constraints: {page: /\d+/}
```

Before writing these, open the existing `albums/since/:year` and `songs/since/:year` routes and copy their `defaults:` and `constraints:` **verbatim** — if the base routes use different year constraints than shown above, match the base routes rather than this plan, or the filter changes meaning on page 2.

- [ ] **Step 2: Convert the nine call sites**

In each controller add `include PathBasedPagination` below the existing `include Cacheable` line, then append `, **pagy_path_options` inside the `pagy(` call:

| File | Line | New call |
|---|---|---|
| `music/albums/ranked_items_controller.rb` | 29 | `@pagy, @albums = pagy(albums_query, limit: 100, **pagy_path_options)` |
| `music/songs/ranked_items_controller.rb` | 29 | `@pagy, @songs = pagy(songs_query, limit: 100, **pagy_path_options)` |
| `music/artists/ranked_items_controller.rb` | 24 | `@pagy, @artists = pagy(artists_query, limit: 100, **pagy_path_options)` |
| `music/albums/lists_controller.rb` | 24 | `@pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25, **pagy_path_options)` |
| `music/albums/lists_controller.rb` | 40 | `@pagy, @pagy_list_items = pagy(list_items_query, limit: 100, **pagy_path_options)` |
| `music/songs/lists_controller.rb` | 24 | `@pagy, @ranked_lists = pagy(ranked_lists_query, limit: 25, **pagy_path_options)` |
| `music/songs/lists_controller.rb` | 33 | `@pagy, @pagy_list_items = pagy(list_items_query, limit: 100, **pagy_path_options)` |
| `music/albums/categories_controller.rb` | 18 | `@pagy, @albums = pagy(albums_query, limit: 100, **pagy_path_options)` |
| `music/artists/categories_controller.rb` | 18 | `@pagy, @artists = pagy(artists_query, limit: 100, **pagy_path_options)` |

Note the two `limit: 25` call sites — keep 25, do not normalise them to 100.

- [ ] **Step 3: Make the two Turbo Frames advance the URL**

In both `app/views/music/albums/lists/show.html.erb` and `app/views/music/songs/lists/show.html.erb`, change:

```erb
<%= turbo_frame_tag "list_items" do %>
```

to:

```erb
<%= turbo_frame_tag "list_items", data: {turbo_action: "advance"} do %>
```

- [ ] **Step 4: Rewrite the pagination stylesheet**

Replace the entire contents of `app/assets/stylesheets/music/paging.css`:

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

This replaces raw `bg-gray-200` / `text-gray-500` / `bg-gray-300` / `text-gray-300` / `bg-gray-100` / `bg-gray-400`, which ignore the DaisyUI theme entirely, as well as the dead pagy-9 `.current` and `.gap` selectors.

- [ ] **Step 5: Write the tests**

Add to `test/controllers/music/albums/ranked_items_controller_test.rb` (create the file only if it does not exist; otherwise append inside the existing class and match its `setup`):

```ruby
    test "path-based pagination resolves the page" do
      get "/albums/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      get "/albums?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "generated page urls are path-based" do
      get "/albums"

      assert_equal "/albums/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "the year filter does not leak into the query string" do
      get "/albums/since/1990"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/albums/since/1990/page/2", url
      refute_includes url, "year="
    end

    test "ranking configuration scope is preserved without leaking into the query string" do
      get "/rc/#{ranking_configurations(:music_albums_global).id}/albums"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_includes url, "/albums/page/2"
      refute_includes url, "ranking_configuration_id="
    end
```

Add the equivalent three tests for songs to `test/controllers/music/songs/ranked_items_controller_test.rb`, using `/songs`, `/songs/page/2`, `/songs?page=2`, and `/songs/since/1990`:

```ruby
    test "path-based pagination resolves the page" do
      get "/songs/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      get "/songs?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "the year filter does not leak into the query string" do
      get "/songs/since/1990"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/songs/since/1990/page/2", url
      refute_includes url, "year="
    end
```

And for artists, in `test/controllers/music/artists/ranked_items_controller_test.rb`:

```ruby
    test "path-based pagination resolves the page" do
      get "/artists/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "generated page urls are path-based" do
      get "/artists"

      assert_equal "/artists/page/2", @controller.view_assigns["pagy"].page_url(2)
    end
```

- [ ] **Step 6: Run the music tests**

Run: `bin/rails test test/controllers/music`
Expected: PASS.

- [ ] **Step 7: Verify the CSS builds**

Run: `yarn build:css:music`
Then: `grep -c "aria-current" app/assets/builds/music.css`
Expected: build succeeds; grep returns at least `1`.

Also confirm the raw greys are gone from the pagy rules:
Run: `grep -c "pagy" app/assets/builds/music.css`
Expected: at least `1`, and no `bg-gray` inside those rules.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/music test/controllers/music
git add config/routes.rb app/controllers/music app/views/music/albums/lists/show.html.erb app/views/music/songs/lists/show.html.erb app/assets/stylesheets/music/paging.css test/controllers/music
git commit -m "Convert music to path-based pagination and fix its pagy styles"
```

---

### Task 5: My Lists, and full verification

**Files:**
- Modify: `config/routes.rb`, `app/controllers/my_lists_controller.rb:57`, `app/views/my_lists/show.html.erb:62`
- Test: `test/controllers/my_lists_controller_test.rb`

**Interfaces:**
- Consumes: `PathBasedPagination#pagy_path_options` from Task 2.
- Produces: nothing.

**Background.** Only `my_lists#show` paginates; `index` does not. `show` is reachable at two paths — `my/lists/:id` and the legacy alias `user_lists/:id` — so both need a page route. My Lists is auth-gated and never edge-cached; it is converted so there is one pagination mechanism app-wide.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, immediately after each existing route:

```ruby
  get "my/lists/:id/page/:page", to: "my_lists#show", as: :my_list_page, constraints: {page: /\d+/}
  get "user_lists/:id/page/:page", to: "my_lists#show", as: :user_list_page, constraints: {page: /\d+/}
```

- [ ] **Step 2: Convert the controller**

In `app/controllers/my_lists_controller.rb`, add `include PathBasedPagination` alongside the other includes at the top of the class, then change line 57:

```ruby
      format.html { @pagy, @items = pagy(collection, limit: 100, **pagy_path_options) }
```

- [ ] **Step 3: Make the Turbo Frame advance the URL**

In `app/views/my_lists/show.html.erb:62`, change:

```erb
  <%= turbo_frame_tag "list_items" do %>
```

to:

```erb
  <%= turbo_frame_tag "list_items", data: {turbo_action: "advance"} do %>
```

- [ ] **Step 4: Write the tests**

Append inside the class in `test/controllers/my_lists_controller_test.rb`. Read its existing `setup` first — My Lists requires an authenticated user, and the file already establishes one via `sign_in_as(@user, stub_auth: true)`. Reuse whatever user and list it already sets up, substituting them for `<USER>` and `<LIST>`:

```ruby
    test "list pagination is path-based" do
      sign_in_as(<USER>, stub_auth: true)

      get "/my/lists/#{<LIST>.id}"

      assert_equal "/my/lists/#{<LIST>.id}/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "resolves a path-based page" do
      sign_in_as(<USER>, stub_auth: true)

      get "/my/lists/#{<LIST>.id}/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      sign_in_as(<USER>, stub_auth: true)

      get "/my/lists/#{<LIST>.id}?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end
```

- [ ] **Step 5: Run the My Lists tests**

Run: `bin/rails test test/controllers/my_lists_controller_test.rb`
Expected: PASS.

- [ ] **Step 6: Run the full verification gate**

Run each and report the output:

1. `bin/rails test` — the whole suite. Expected: 0 failures, 0 errors.
2. `bundle exec standardrb` — expected: no offenses.
3. `yarn build:all` — expected: succeeds, emitting `app/assets/builds/{books,games,music}.css`.
4. `npx playwright test --config=e2e/playwright.config.ts --project=books` — expected: pass. If Playwright reports a missing browser executable, report that as an environment issue rather than installing browsers or editing specs.

- [ ] **Step 7: Commit**

```bash
bundle exec standardrb --fix app/controllers/my_lists_controller.rb test/controllers/my_lists_controller_test.rb
git add config/routes.rb app/controllers/my_lists_controller.rb app/views/my_lists/show.html.erb test/controllers/my_lists_controller_test.rb
git commit -m "Convert My Lists to path-based pagination"
```

---

## Self-Review

**Spec coverage.** `Pagination::PathBuilder` (Task 1) · `PathBasedPagination` concern and the path-parameter fix (Task 2) · books migration (Task 2) · games routes/controllers/CSS/Turbo Frame (Task 3) · music routes/controllers/CSS/Turbo Frames (Task 4) · My Lists (Task 5) · `?page=N` still resolving, asserted in Tasks 3, 4 and 5 · the path-parameter leak guard, asserted in Tasks 3 and 4 · verification gate (Task 5 Step 6).

**Route count.** 7 games + 15 music + 2 My Lists = 24, matching the spec.

**Type consistency.** `Pagination::PathBuilder.new(base_path:)` and `.from_request(request)` are defined in Task 1 and used only through `pagy_path_options` in Task 2. `pagy_path_options` is defined in Task 2 and splatted identically in Tasks 3, 4 and 5. `pagy.page_url(n)` is used consistently in every test.

**Deliberate placeholders.** Tasks 3 and 5 contain `<LIST_FIXTURE>`, `<CATEGORY_FIXTURE>`, `<USER>` and `<LIST>`. These are not omissions: the existing test files already establish their own fixtures and auth, and inventing names risks referencing fixtures that do not exist. Each is accompanied by an instruction to read the file's existing `setup` and reuse what is there.

**Not covered, by design.** The books filter URL grammar and auto-scroll pagination are spec follow-ups. Books' `/page/1` → `/` redirect is left in place. No redirects are added anywhere else.
