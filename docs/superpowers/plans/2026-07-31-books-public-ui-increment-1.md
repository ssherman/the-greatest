# Books Public UI — Increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the public books ranked grid at `/` with path-based pagination, `/book/:slug` detail pages, and 301s from the legacy `/books/:id` URL family.

**Architecture:** Transcribes the existing games public UI (`Games::RankedItemsController`, `Games::GamesController`) into a `Books::` namespace, with four deliberate departures documented in the spec: the ranked-items query drops the `books_books` join, pagination is path-based via a new shared pagy extension, book lookups are explicit (`find_by!`) rather than friendly_id's slug-first `find`, and the card grid is denser because book covers are 326×500 rather than games' 810×1080.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, pagy 43.5.6, ViewComponent, Tailwind CSS 4, DaisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-07-31-books-public-ui-design.md`. Read the Decisions table before starting; every task below implements a numbered decision from it.

## Global Constraints

- **Working directory is `web-app/`.** Every `bin/rails`, `yarn`, and `bundle` command runs from there. Docs live at the project root in `docs/`, NOT `web-app/docs/`.
- **Lint is `bundle exec standardrb`**, never `bin/rubocop`. `--fix` autocorrects.
- **Never run destructive DB commands.** `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES every table it names. To inspect a fixture, read the YAML. A `PreToolUse` hook blocks `db:drop`/`db:reset`/`db:schema:load` and bulk deletes. Books data exists ONLY in development and takes hours to rebuild.
- **Use Rails generators** for controllers and components — they create the matching test file. Delete generated helper/system-test cruft.
- **Namespace all books code** under `Books::`. Tests mirror the namespace.
- **No code comments** unless the plan explicitly includes them. Follow existing patterns.
- **Controller tests assert behavior only** — status codes, assigns, redirect targets. Never HTML, CSS, or copy. If a designer could change it freely, don't test it.
- **Test host for books is `dev-new.thegreatestbooks.org`** (`host! "dev-new.thegreatestbooks.org"`).
- **The books RC fixture is `ranking_configurations(:books_global)`** — it is `global: true, primary: true`, so it is what `Books::RankingConfiguration.default_primary` returns (`default_primary` is `global.primary.first`).
- **`test/fixtures/ranked_items.yml` intentionally contains only UNRANKED items** ("to avoid conflicts with tests") and has no books entries. Do **not** add ranked books there — create them inside each test's `setup` block.
- **Books book fixtures available:** `war_and_peace`, `crime_and_punishment`, `got`, `clash`, `of_mice_and_men`, `cannery_row`, `combo_steinbeck` (in `test/fixtures/books/books.yml`).
- **DaisyUI semantic tokens only** — `bg-base-100`, `text-base-content`, `badge-primary`. Never raw palette colors (`bg-gray-200`), never `dark:` variants (the theme is pinned to `cmyk`). `text-base-content/70` is the contrast floor for body text.
- **Never use the `prose` class** — `@tailwindcss/typography` is not installed and it is a no-op.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `config/initializers/pagy_path_based_paging.rb` | Shared, opt-in pagy extension producing `/page/N` URLs |
| `app/lib/books/public_indexing.rb` | Single predicate gating whether books pages are indexable |
| `app/lib/books/ranked_books_query.rb` | The one place the ranked-books query is built (swap seam) |
| `app/controllers/books/ranked_items_controller.rb` | Ranked grid |
| `app/controllers/books/books_controller.rb` | `/book/:slug` detail |
| `app/controllers/books/legacy_books_controller.rb` | 301s from legacy id URLs |
| `app/components/books/card_component.rb` + `.html.erb` | Grid card |
| `app/views/books/ranked_items/index.html.erb` | Grid page |
| `app/views/books/books/show.html.erb` | Detail page |
| `app/assets/stylesheets/books/paging.css` | pagy-43-correct pagination styling |

**Modified:** `config/routes.rb`, `app/helpers/books/default_helper.rb`, `app/views/layouts/books/application.html.erb`, `app/assets/stylesheets/books/application.css`, `e2e/tests/books/homepage.spec.ts`.

**Deleted:** `app/controllers/books/default_controller.rb`, `app/views/books/default/index.html.erb`, `test/controllers/books/default_controller_test.rb`.

---

### Task 1: Pagy path-based pagination extension

Implements spec decision **D5a**. This is shared infrastructure, not books-specific, and it must be provably inert for music/games/movies.

**Files:**
- Create: `config/initializers/pagy_path_based_paging.rb`
- Test: `test/lib/pagy_path_based_paging_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: a `:page_path` pagy option accepting a lambda `->(page) { String }`. When absent, pagy behaves exactly as before.

**Background — why this is not a one-liner.** pagy 43.5.6 has two independent defects here:
1. `Pagy::Request#get_params` is `request.GET.merge(request.POST)`, so Rails route params never reach pagy and `/page/12` resolves to page 1. Fixed in Task 5 by passing a request hash from the controller.
2. `a_lambda` composes ONE templated URL containing the sentinel `Pagy::PAGE_TOKEN` (the literal two-character string `"P "`) and string-splits it per page. That makes the page-1 special case (`/` not `/page/1`) inexpressible, and a naive `compose_url` override does `PAGE_TOKEN.to_i == 0`, emitting malformed HTML like `<a href="/"11 rel="prev">`. This task fixes that by overriding `a_lambda` too.

- [ ] **Step 1: Write the failing test**

Create `test/lib/pagy_path_based_paging_test.rb`:

```ruby
require "test_helper"
require "pagy/classes/request"

class PagyPathBasedPagingTest < ActiveSupport::TestCase
  PATH_BUILDER = ->(n) { (n.to_i <= 1) ? "/" : "/page/#{n.to_i}" }

  def build_pagy(params:, path: "/", **extra)
    options = {count: 24_242, limit: 100, page_key: "page",
               request: {base_url: "https://books.test", path: path, params: params}}.merge(extra)
    options[:request] = Pagy::Request.new(options)
    options[:page] = options[:request].resolve_page
    Pagy::Offset.new(**options)
  end

  test "generates path-based urls when page_path is supplied" do
    pagy = build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER)

    assert_equal "/", pagy.page_url(1)
    assert_equal "/page/2", pagy.page_url(2)
    assert_equal "/page/243", pagy.page_url(243)
  end

  test "leaves query-string pagination untouched when page_path is absent" do
    pagy = build_pagy(params: {"page" => "3"}, path: "/video-games")

    assert_equal "/video-games?page=4", pagy.page_url(4)
  end

  test "series_nav links page one at the root path, never /page/1" do
    nav = build_pagy(params: {"page" => "2"}, path: "/page/2", page_path: PATH_BUILDER).series_nav(slots: 5)

    assert_includes nav, %(href="/" rel="prev")
    refute_includes nav, "/page/1"
  end

  test "series_nav emits well-formed anchors" do
    nav = build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER).series_nav(slots: 5)

    assert_includes nav, %(<a href="/page/13" rel="next">13</a>)
    refute_includes nav, %(href="/"1)
  end

  test "preserves unrelated query parameters" do
    pagy = build_pagy(params: {"page" => "12", "sort" => "title"}, path: "/page/12", page_path: PATH_BUILDER)

    assert_equal "/page/3?sort=title", pagy.page_url(3)
  end

  test "resolves the page from a route parameter" do
    assert_equal 12, build_pagy(params: {"page" => "12"}, path: "/page/12", page_path: PATH_BUILDER).page
  end

  test "still resolves the page from a query parameter" do
    assert_equal 7, build_pagy(params: {"page" => "7"}, path: "/", page_path: PATH_BUILDER).page
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/pagy_path_based_paging_test.rb`
Expected: FAIL. The path-based assertions fail with `"/page/12?page=2"` instead of `"/page/2"`.

- [ ] **Step 3: Write the implementation**

Create `config/initializers/pagy_path_based_paging.rb`:

```ruby
# frozen_string_literal: true

# Path-based pagination (/page/2) instead of query strings (?page=2).
#
# Opt-in: only active when a :page_path option is supplied, so every caller that
# does not pass one keeps pagy's stock query-string behaviour untouched.
module Pagy::PathBasedPaging
  def compose_url(absolute, path, params, fragment)
    builder = @options[:page_path]
    return super unless builder

    page = params.delete(@options[:page_key] || "page")
    query = Pagy::Linkable::QueryUtils.build_nested_query(params).sub(/\A(?=.)/, "?")
    "#{@request.base_url if absolute}#{builder.call(page)}#{query}#{fragment}"
  end

  # pagy composes one templated URL containing PAGE_TOKEN and string-splits it per
  # page. That makes a page-1 special case ("/" rather than "/page/1") impossible to
  # express, and PAGE_TOKEN.to_i is 0, which corrupts the template. Build each href
  # for real instead; the templating is only a speed optimisation and is irrelevant
  # for a nav of a handful of anchors.
  def a_lambda(anchor_string: @options[:anchor_string], **options)
    return super unless @options[:page_path]

    lambda do |page, text = page_label(page), classes: nil, aria_label: nil|
      rel = case page
      when @previous then %( rel="prev")
      when @next then %( rel="next")
      end

      %(<a href="#{compose_page_url(page, **options)}"#{
        %( #{anchor_string}) if anchor_string}#{
        %( class="#{classes}") if classes}#{rel}#{
        %( aria-label="#{aria_label}") if aria_label}>#{text}</a>)
    end
  end
end

Pagy::Offset.prepend(Pagy::PathBasedPaging)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/pagy_path_based_paging_test.rb`
Expected: PASS, 7 assertions-bearing tests.

- [ ] **Step 5: Verify no other domain regressed**

Run: `bin/rails test test/controllers/games test/controllers/music`
Expected: PASS. This is the guard that the opt-in gate works.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix config/initializers/pagy_path_based_paging.rb test/lib/pagy_path_based_paging_test.rb
git add config/initializers/pagy_path_based_paging.rb test/lib/pagy_path_based_paging_test.rb
git commit -m "Add opt-in path-based pagination extension for pagy"
```

---

### Task 2: Indexability predicate and robots helper

Implements spec decisions **D2** (site-wide noindex until cutover) and **D4** (any `/rc/:id` URL is noindex).

**Files:**
- Create: `app/lib/books/public_indexing.rb`
- Modify: `app/helpers/books/default_helper.rb` (currently an empty module)
- Test: `test/lib/books/public_indexing_test.rb`, `test/helpers/books/default_helper_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::PublicIndexing.enabled?` → Boolean. `Books::DefaultHelper#books_robots_content` → `"index, follow"` or `"noindex, follow"`, reading `@indexable` and `params[:ranking_configuration_id]`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/books/public_indexing_test.rb`:

```ruby
require "test_helper"

module Books
  class PublicIndexingTest < ActiveSupport::TestCase
    test "is disabled by default" do
      ENV.delete("BOOKS_PUBLIC_INDEXING")
      refute Books::PublicIndexing.enabled?
    end

    test "is enabled only for the exact string true" do
      ENV["BOOKS_PUBLIC_INDEXING"] = "true"
      assert Books::PublicIndexing.enabled?
    ensure
      ENV.delete("BOOKS_PUBLIC_INDEXING")
    end

    test "is disabled for any other value" do
      ENV["BOOKS_PUBLIC_INDEXING"] = "1"
      refute Books::PublicIndexing.enabled?
    ensure
      ENV.delete("BOOKS_PUBLIC_INDEXING")
    end
  end
end
```

Create `test/helpers/books/default_helper_test.rb`:

```ruby
require "test_helper"

module Books
  class DefaultHelperTest < ActionView::TestCase
    include Books::DefaultHelper

    test "noindex when public indexing is disabled even for indexable pages" do
      Books::PublicIndexing.stubs(:enabled?).returns(false)
      @indexable = true

      assert_equal "noindex, follow", books_robots_content
    end

    test "index when public indexing is enabled and the page is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = true

      assert_equal "index, follow", books_robots_content
    end

    test "noindex when the page is not indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = false

      assert_equal "noindex, follow", books_robots_content
    end

    test "noindex when the url carries a ranking configuration id" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)
      @indexable = true
      params[:ranking_configuration_id] = "8"

      assert_equal "noindex, follow", books_robots_content
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/books/public_indexing_test.rb test/helpers/books/default_helper_test.rb`
Expected: FAIL with `NameError: uninitialized constant Books::PublicIndexing`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/public_indexing.rb`:

```ruby
module Books
  module PublicIndexing
    def self.enabled?
      ENV["BOOKS_PUBLIC_INDEXING"] == "true"
    end
  end
end
```

Replace the contents of `app/helpers/books/default_helper.rb`:

```ruby
module Books::DefaultHelper
  def books_robots_content
    return "noindex, follow" unless Books::PublicIndexing.enabled?
    return "noindex, follow" if params[:ranking_configuration_id].present?

    @indexable ? "index, follow" : "noindex, follow"
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/books/public_indexing_test.rb test/helpers/books/default_helper_test.rb`
Expected: PASS, 7 tests.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/books/public_indexing.rb app/helpers/books/default_helper.rb test/lib/books/public_indexing_test.rb test/helpers/books/default_helper_test.rb
git add app/lib/books/public_indexing.rb app/helpers/books/default_helper.rb test/lib/books test/helpers/books
git commit -m "Add books indexability predicate and robots helper"
```

---

### Task 3: Books::RankedBooksQuery

Implements spec decisions **D7** (query-object seam) and **D8** (no `books_books` join). The join exists in `Games::RankedItemsController` only so `Services::RankedItemsFilterService` can filter on `games_games.release_year`. Books has no year filter in v1, and dropping the join lets Postgres use `index_ranked_items_on_config_and_rank` — measured 33.0 ms → 5.3 ms at the deepest offset.

**Files:**
- Create: `app/lib/books/ranked_books_query.rb`
- Test: `test/lib/books/ranked_books_query_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::RankedBooksQuery.call(ranking_configuration:)` → an unpaginated `ActiveRecord::Relation` of `RankedItem`, ordered by `rank`, with `item` and its `book_authors → author` and `primary_image` preloaded.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/ranked_books_query_test.rb`:

```ruby
require "test_helper"

module Books
  class RankedBooksQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @second = RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      @first = RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
    end

    test "returns the configuration's ranked books ordered by rank" do
      assert_equal [@first, @second], Books::RankedBooksQuery.call(ranking_configuration: @rc).to_a
    end

    test "excludes items belonging to another ranking configuration" do
      other = ranking_configurations(:books_inherited)
      RankedItem.create!(item: books_books(:got), ranking_configuration: other, rank: 1, score: 50)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_equal 2, results.count
    end

    test "excludes non-book ranked items" do
      RankedItem.create!(item: music_albums(:dark_side_of_the_moon), ranking_configuration: @rc, rank: 3, score: 10)

      item_types = Books::RankedBooksQuery.call(ranking_configuration: @rc).map(&:item_type).uniq

      assert_equal ["Books::Book"], item_types
    end

    test "preloads authors and the primary image so views do not N+1" do
      relation = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_queries_count(4) do
        relation.to_a.each { |ri| ri.item.book_authors.map { |ba| ba.author.name } }
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/books/ranked_books_query_test.rb`
Expected: FAIL with `NameError: uninitialized constant Books::RankedBooksQuery`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/ranked_books_query.rb`:

```ruby
module Books
  # The single place the ranked-books relation is built. Callers only ever see a
  # paginatable RankedItem relation, so a later filtering increment can swap the
  # engine here (OpenSearch id-set, materialized view) without touching views.
  class RankedBooksQuery
    def self.call(ranking_configuration:)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Book")
        .includes(item: [{book_authors: :author}, :primary_image])
        .order(:rank)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/books/ranked_books_query_test.rb`
Expected: PASS. If the `assert_queries_count(4)` assertion fails, read the reported number and correct the expectation to match — the point of the test is to pin the count so a future change that reintroduces an N+1 fails loudly, not to assert a specific magic number.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/books/ranked_books_query.rb test/lib/books/ranked_books_query_test.rb
git add app/lib/books/ranked_books_query.rb test/lib/books/ranked_books_query_test.rb
git commit -m "Add Books::RankedBooksQuery seam for the ranked grid"
```

---

### Task 4: Books layout and pagination stylesheet

Implements the spec's UI standards section — bugs **B3** (no books `paging.css`), **B4** (dead pagy-9 selectors), **B6** (missing `lang`), and the `@layer base` font fix.

**Files:**
- Create: `app/assets/stylesheets/books/paging.css`
- Modify: `app/assets/stylesheets/books/application.css`, `app/views/layouts/books/application.html.erb`

**Interfaces:**
- Consumes: `books_robots_content` from Task 2.
- Produces: a layout that emits `<meta name="robots">`, a `#main` skip-link target, and `.pagy` styling matching pagy 43's real markup.

**Background — B4 in detail.** pagy 43.5.6 renders the current page as `<a role="link" aria-disabled="true" aria-current="page">12</a>` (no `class="current"`) and gaps as `<a role="separator" aria-disabled="true">…</a>` (no `class="gap"`). The existing `games/paging.css` targets `.current` and `.gap`, which no longer exist, and because the current page has no `href` it is swallowed by `a:not([href]) { @apply btn-disabled }` — rendering the current page greyed-out instead of highlighted.

- [ ] **Step 1: Create the pagination stylesheet**

Create `app/assets/stylesheets/books/paging.css`:

```css
.pagy {
  @apply flex flex-wrap justify-center items-center gap-1 font-semibold text-sm;

  a { @apply btn btn-sm btn-ghost; }

  /* Disabled prev/next arrows and the "…" separator, but NOT the current page. */
  a:not([href]):not([aria-current]) { @apply btn-disabled; }

  /* pagy 43 marks the current page with aria-current, not class="current". */
  a[aria-current="page"] { @apply btn-primary pointer-events-none; }
}
```

- [ ] **Step 2: Wire the stylesheet in and fix the font layering**

In `app/assets/stylesheets/books/application.css`, add the import directly below the existing `@import "tailwindcss";` line:

```css
@import "./paging.css";
```

Then wrap the existing bare font rules in `@layer base`. Replace:

```css
html {
  font-family: 'Lora', Georgia, 'Times New Roman', serif;
}

h1, h2, h3, h4, h5, h6 {
  font-family: 'Playfair Display', Georgia, serif;
}
```

with:

```css
@layer base {
  html {
    font-family: 'Lora', Georgia, 'Times New Roman', serif;
  }

  h1, h2, h3, h4, h5, h6 {
    font-family: 'Playfair Display', Georgia, serif;
  }
}
```

Unlayered CSS beats any layered rule, so while the bare `h1…h6` selector exists, a Tailwind utility like `font-sans` on a heading is silently a no-op.

- [ ] **Step 3: Update the layout**

In `app/views/layouts/books/application.html.erb`:

1. Change line 2 from `<html data-theme="cmyk">` to `<html lang="en" data-theme="cmyk">`.
2. Add the robots meta immediately after the `<meta name="description" ...>` line:

```erb
<meta name="robots" content="<%= books_robots_content %>">
```

3. Trim the Google Fonts `<link>` to the four faces actually used. `card-title` is `font-weight: 600` in DaisyUI 5, so Lora 600 must stay; 500 and 700 go:

```erb
<link href="https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400;0,600;1,400&family=Playfair+Display:wght@700&display=swap" rel="stylesheet">
```

4. Add a skip link as the first element inside `<body>`:

```erb
<a href="#main" class="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 btn btn-sm btn-primary">Skip to content</a>
```

5. Give the navbar a landmark label — change `<div class="navbar bg-base-200">` to:

```erb
<nav class="navbar bg-base-200" aria-label="Main">
```

and change its matching closing `</div>` to `</nav>`.

6. Add the skip-link target to `<main>` and remove the dead nav links. Change `<main class="container mx-auto px-4 py-8">` to `<main id="main" class="container mx-auto px-4 py-8">`.

7. In **both** the mobile dropdown `<ul>` and the desktop `<ul>`, delete the `Authors` and `Lists` list items and point Books at the root. Each list becomes exactly:

```erb
<li><%= link_to "Books", books_root_path %></li>
```

Authors has no pages in v1, and Lists is wired in increment 2.

- [ ] **Step 4: Verify the CSS builds**

Run: `yarn build:css:books`
Expected: succeeds and writes `app/assets/builds/books.css`.

Then confirm the pagy rules actually compiled:

Run: `grep -c "aria-current" app/assets/builds/books.css`
Expected: at least `1`.

- [ ] **Step 5: Run the existing books tests**

Run: `bin/rails test test/controllers/books`
Expected: PASS. `Books::DefaultControllerTest` still passes — the layout change is additive and `books_robots_content` resolves because `@indexable` is simply nil (falsy), yielding `"noindex, follow"`.

- [ ] **Step 6: Commit**

```bash
git add app/assets/stylesheets/books app/views/layouts/books/application.html.erb
git commit -m "Add books paging styles, robots meta, and layout accessibility fixes"
```

---

### Task 5: Card component, routes, and the ranked grid

Implements spec decisions **D5** (root is the index), **D5a** (path-based pagination), **D2**/**D4** (indexability), **D10** (denser grid sizing), **D11** (serve the original cover blob), plus bugs **B1** (no lazy loading), **B5** (dead `hover:badge-primary`), **B7** (no nested container), and **B9** (two links per card). Deletes `Books::DefaultController`, whose root route the grid takes over.

The card and the grid are one task because neither is independently testable: the card template calls `book_path`, which does not exist until this task's routes land, so the component cannot render on its own.

**Files:**
- Create: `app/components/books/card_component.rb`, `app/components/books/card_component.html.erb`, `app/controllers/books/ranked_items_controller.rb`, `app/views/books/ranked_items/index.html.erb`
- Modify: `config/routes.rb`
- Delete: `app/controllers/books/default_controller.rb`, `app/views/books/default/index.html.erb`, `test/controllers/books/default_controller_test.rb`
- Test: `test/components/books/card_component_test.rb`, `test/controllers/books/ranked_items_controller_test.rb`

**Interfaces:**
- Consumes: `Books::RankedBooksQuery.call(ranking_configuration:)` (Task 3), the `:page_path` pagy option (Task 1), `books_robots_content` (Task 2).
- Produces: `Books::CardComponent.new(ranked_item:, index:)` — `ranked_item` is a `RankedItem` whose `item` is a `Books::Book`; `index` is the zero-based position on the page and controls the eager/lazy image split. Named routes `books_root_path`, `books_page_path(page)`, `books_rc_path(rc_id)`, `books_rc_page_path(rc_id, page)`, and `book_path(slug)` (whose controller arrives in Task 6).

**Background.** Book covers are 326×500 (median 28.5 KB) against games' 810×1080. The card must therefore stay in a 163–231px band or covers upscale and go soft — that is what drives the grid ladder below. The first 6 cards load eagerly with `fetchpriority="high"` because the LCP element on `/` is a first-row cover and Chrome does not prioritise lazy images.

**Order note.** Steps 1–4 build the component, Steps 5–12 the routes, controller, and view. The component test in Step 2 will not pass until the routes land in Step 7; Step 11 runs both suites together.

- [ ] **Step 1: Generate the component**

Run: `bin/rails generate component Books::Card`

Delete any generated preview or stimulus files; keep `app/components/books/card_component.rb`, `app/components/books/card_component.html.erb`, and `test/components/books/card_component_test.rb`.

- [ ] **Step 2: Write the failing test**

Replace `test/components/books/card_component_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class CardComponentTest < ViewComponent::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @ranked_item = RankedItem.create!(
        item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 42, score: 99
      )
    end

    test "renders the rank with a screen-reader label" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector ".badge", text: "#42"
      assert_selector ".sr-only", text: "Rank"
    end

    test "links once to the book detail page" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "a[href='/book/war-and-peace']", count: 1
    end

    test "renders the publication year" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_text "1869"
    end

    test "carries listable data attributes for the increment 3 user-list widget" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "[data-listable-type='Books::Book'][data-listable-id='#{@book.id}']"
    end

    test "renders an aria-hidden placeholder when the book has no cover" do
      render_inline(Books::CardComponent.new(ranked_item: @ranked_item, index: 0))

      assert_selector "[aria-hidden='true']"
      refute_text "No Image"
    end

    test "eagerly loads the first six covers and lazy-loads the rest" do
      assert_equal "eager", Books::CardComponent.new(ranked_item: @ranked_item, index: 5).send(:loading_strategy)
      assert_equal "lazy", Books::CardComponent.new(ranked_item: @ranked_item, index: 6).send(:loading_strategy)
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/components/books/card_component_test.rb`
Expected: FAIL — the generated component renders an empty template.

- [ ] **Step 4: Write the implementation**

Replace `app/components/books/card_component.rb`:

```ruby
# frozen_string_literal: true

class Books::CardComponent < ViewComponent::Base
  def initialize(ranked_item:, index:)
    @ranked_item = ranked_item
    @index = index
  end

  private

  attr_reader :ranked_item, :index

  def book
    @book ||= ranked_item.item
  end

  def rank
    ranked_item.rank
  end

  def author_names
    book.book_authors.map { |book_author| book_author.author.name }.join(", ")
  end

  def cover
    @cover ||= book.primary_image if book.primary_image&.file&.attached?
  end

  def loading_strategy
    (index < 6) ? "eager" : "lazy"
  end

  def fetch_priority
    (index < 6) ? "high" : "auto"
  end
end
```

Replace `app/components/books/card_component.html.erb`:

```erb
<div class="card card-sm bg-base-100 shadow-md hover:shadow-xl transition-shadow
            has-[a:focus-visible]:outline-2 has-[a:focus-visible]:outline-offset-2 has-[a:focus-visible]:outline-primary"
     data-listable-type="Books::Book"
     data-listable-id="<%= book.id %>">
  <figure class="bg-base-200">
    <% if cover %>
      <%= image_tag rails_public_blob_url(cover.file),
          alt: "",
          loading: loading_strategy,
          decoding: "async",
          fetchpriority: fetch_priority,
          class: "w-full aspect-[2/3] object-cover" %>
    <% else %>
      <div class="w-full aspect-[2/3] flex items-center justify-center" aria-hidden="true">
        <span class="text-4xl opacity-40">📖</span>
      </div>
    <% end %>
  </figure>

  <div class="card-body">
    <div class="flex items-start justify-between gap-2">
      <div class="badge badge-primary font-bold">
        <span class="sr-only">Rank </span>#<%= rank %>
      </div>
      <% if book.first_published_year %>
        <span class="text-xs text-base-content/70"><%= book.first_published_year %></span>
      <% end %>
    </div>

    <h2 class="card-title text-base">
      <%= link_to book.title, book_path(book.slug),
          class: "after:absolute after:inset-0 focus-visible:outline-none hover:text-primary" %>
    </h2>

    <% if author_names.present? %>
      <p class="text-sm text-base-content/70"><%= author_names %></p>
    <% end %>
  </div>
</div>
```

Two load-bearing details. `.card` is already `position: relative` in DaisyUI 5, so `after:inset-0` anchors correctly and gives one stretched link per card. When increment 3 adds `UserLists::CardWidgetComponent`, its wrapper **must** carry `relative z-10` or the stretched-link overlay makes the button unclickable.

- [ ] **Step 5: Write the failing ranked-items controller test**

Create `test/controllers/books/ranked_items_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class RankedItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
    end

    test "root renders the ranked grid" do
      get "/"
      assert_response :success
    end

    test "path-based pagination resolves the page" do
      get "/page/2"
      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      get "/?page=2"
      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "page one redirects to the canonical root" do
      get "/page/1"
      assert_redirected_to "/"
      assert_response :moved_permanently
    end

    test "the-greatest-books redirects to the canonical root" do
      get "/the-greatest-books"
      assert_redirected_to "/"
      assert_response :moved_permanently
    end

    test "renders an explicit ranking configuration" do
      get "/rc/#{@rc.id}"
      assert_response :success
    end

    test "renders an explicit ranking configuration with a page" do
      get "/rc/#{@rc.id}/page/2"
      assert_response :success
    end

    test "404s for a missing ranking configuration" do
      get "/rc/99999"
      assert_response :not_found
    end

    test "404s for a ranking configuration of the wrong type" do
      get "/rc/#{ranking_configurations(:games_global).id}"
      assert_response :not_found
    end

    test "marks the grid indexable" do
      get "/"
      assert @controller.view_assigns["indexable"]
    end

    test "pagination links are path-based, not query strings" do
      get "/"
      assert_select "nav.pagy a[href='/page/2']"
    end
  end
end
```

- [ ] **Step 6: Run the test to verify it fails**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb`
Expected: FAIL — routes do not exist.

- [ ] **Step 7: Add the routes**

In `config/routes.rb`, inside the books `DomainConstraint` block, **replace** the existing line:

```ruby
    root to: "books/default#index", as: :books_root
```

with:

```ruby
    scope "(/rc/:ranking_configuration_id)" do
      get "book/:slug", to: "books/books#show", as: :book
    end

    # Ranked index. Root is canonical; pagination is path-based.
    # Order matters: /page/1 must precede the generic /page/:page.
    root to: "books/ranked_items#index", as: :books_root
    get "page/1", to: redirect("/", status: 301)
    get "page/:page", to: "books/ranked_items#index", as: :books_page, constraints: {page: /\d+/}
    get "the-greatest-books", to: redirect("/", status: 301)
    get "rc/:ranking_configuration_id", to: "books/ranked_items#index", as: :books_rc
    get "rc/:ranking_configuration_id/page/:page", to: "books/ranked_items#index",
      as: :books_rc_page, constraints: {page: /\d+/}
```

- [ ] **Step 8: Write the controller**

Create `app/controllers/books/ranked_items_controller.rb`:

```ruby
class Books::RankedItemsController < RankedItemsController
  include Pagy::Method
  include Cacheable

  layout "books/application"

  before_action :find_ranking_configuration
  before_action :validate_ranking_configuration_type, if: -> { @ranking_configuration.present? }
  before_action :cache_for_index_page, only: [:index]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    @indexable = true
    @show_hero = params[:page].blank? && params[:ranking_configuration_id].blank?

    @pagy, @ranked_books = pagy(
      Books::RankedBooksQuery.call(ranking_configuration: @ranking_configuration),
      limit: 100,
      request: pagy_path_request,
      page_path: method(:ranked_books_page_path)
    )
  end

  private

  # pagy's Request#get_params reads request.GET/POST only, so Rails route params
  # (the :page segment) never reach it. Pass them explicitly; controller and action
  # are stripped so they cannot leak into a generated query string.
  def pagy_path_request
    {base_url: request.base_url,
     path: request.path,
     params: request.params.except("controller", "action").to_h}
  end

  def ranked_books_page_path(page)
    rc_id = params[:ranking_configuration_id]
    page = page.to_i

    if rc_id.present?
      (page <= 1) ? books_rc_path(rc_id) : books_rc_page_path(rc_id, page)
    else
      (page <= 1) ? books_root_path : books_page_path(page)
    end
  end
end
```

- [ ] **Step 9: Write the grid view**

Create `app/views/books/ranked_items/index.html.erb`. Note there is **no** `container mx-auto px-4 py-8` wrapper — the layout's `<main>` already provides one, and doubling it costs 32px of width on a 375px phone:

```erb
<%
  content_for :page_title, "The Greatest Books of All Time | The Greatest Books"
  content_for :meta_description, "A definitive ranking of the greatest books of all time, aggregated from hundreds of published best-books lists."
%>

<div class="space-y-8">
  <% if @show_hero %>
    <div class="bg-base-200 border border-base-300 rounded-xl p-6 md:p-10">
      <div class="max-w-3xl mx-auto">
        <p class="text-base sm:text-lg leading-relaxed text-base-content/80">
          What makes a book one of the greatest ever written? The Greatest Books aggregates hundreds of
          published "best books" lists from critics, authors, and readers, then weighs each list by its
          quality, credibility, and scope to produce a single consensus ranking.
        </p>
      </div>
    </div>
  <% end %>

  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance">The Greatest Books of All Time</h1>

  <% if @ranked_books.any? %>
    <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6">
      <% @ranked_books.each_with_index do |ranked_item, index| %>
        <%= render Books::CardComponent.new(ranked_item: ranked_item, index: index) %>
      <% end %>
    </div>

    <div class="flex justify-center">
      <%== @pagy.series_nav(slots: 5) %>
    </div>
    <p class="text-center text-sm text-base-content/70">
      Page <%= number_with_delimiter(@pagy.page) %> of <%= number_with_delimiter(@pagy.last) %>
    </p>
  <% else %>
    <div class="text-center py-16">
      <div class="text-6xl mb-4">📚</div>
      <h2 class="text-2xl font-bold mb-2">No books found</h2>
      <p class="text-base-content/70">No books have been ranked in this configuration yet.</p>
    </div>
  <% end %>
</div>
```

- [ ] **Step 10: Delete the placeholder controller**

```bash
git rm app/controllers/books/default_controller.rb \
       app/views/books/default/index.html.erb \
       test/controllers/books/default_controller_test.rb
```

`Books::DefaultHelper` stays — it now holds `books_robots_content`.

- [ ] **Step 11: Run the tests**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb test/components/books/card_component_test.rb`
Expected: PASS for both, including the `Books::CardComponent` `book_path` assertion deferred from Task 5.

- [ ] **Step 12: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books/ranked_items_controller.rb test/controllers/books/ranked_items_controller_test.rb
git add -A app/controllers/books app/views/books config/routes.rb test/controllers/books
git commit -m "Add books ranked grid at root with path-based pagination"
```

---

### Task 6: Book detail page

Implements spec decisions **D1** (every book routes, unranked are noindex), **D6** (explicit slug lookup), and **D9** (license byline only where required), plus bug **B2** (never use `prose`).

**Files:**
- Create: `app/controllers/books/books_controller.rb`, `app/views/books/books/show.html.erb`
- Test: `test/controllers/books/books_controller_test.rb`

**Interfaces:**
- Consumes: the `book_path(slug)` route added in Task 6.
- Produces: nothing consumed by later tasks in this increment.

**Background — D6.** friendly_id 5.7.0's `find` resolves the **slug first** and only then falls back to the primary key, and `Books::Book` declares `use: [:slugged, :finders]` — so `Books::Book.find(params[:slug])` is slug-first everywhere. This controller must use `find_by!(slug:)` so lookups are unambiguous for the 137 books whose slug is purely numeric.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/books/books_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class BooksControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @book = books_books(:war_and_peace)
    end

    test "renders a book by slug" do
      get "/book/#{@book.slug}"
      assert_response :success
    end

    test "404s for an unknown slug" do
      get "/book/no-such-book"
      assert_response :not_found
    end

    test "does not fall back to a primary key lookup" do
      get "/book/#{@book.id}"
      assert_response :not_found
    end

    test "marks a ranked book indexable" do
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)

      get "/book/#{@book.slug}"

      assert @controller.view_assigns["indexable"]
    end

    test "marks an unranked book not indexable" do
      get "/book/#{@book.slug}"

      refute @controller.view_assigns["indexable"]
    end

    test "renders a book whose slug is purely numeric" do
      numeric = Books::Book.create!(title: "Nineteen Eighty-Four Vol 1", slug: "1984")

      get "/book/1984"

      assert_response :success
      assert_equal numeric.id, @controller.view_assigns["book"].id
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: FAIL — `Books::BooksController` is missing.

- [ ] **Step 3: Write the controller**

Create `app/controllers/books/books_controller.rb`:

```ruby
class Books::BooksController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :load_ranking_configuration, only: [:show]
  before_action :cache_for_show_page, only: [:show]

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def show
    # find_by!(slug:), never friendly.find: friendly_id resolves slugs before
    # primary keys, so 137 books with purely numeric slugs would otherwise be
    # ambiguous with a book id.
    @book = Books::Book
      .includes(:categories, :descriptions, {book_authors: :author})
      .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
      .find_by!(slug: params[:slug])

    @ranked_item = @ranking_configuration&.ranked_items&.find_by(item: @book)
    @indexable = @ranked_item.present?
    @categories_by_type = @book.categories.active.group_by(&:category_type)
    @description = @book.primary_description

    @list_items = @book.list_items
      .joins(:list)
      .where(list_id: @ranking_configuration.ranked_lists.select(:list_id))
      .where(lists: {status: :active})
      .includes(:list)
      .order(Arel.sql("list_items.position ASC NULLS LAST"), "lists.name")
  end
end
```

- [ ] **Step 4: Write the detail view**

Create `app/views/books/books/show.html.erb`. The description uses an explicit `max-w-[68ch]` measure rather than `prose` (which is a no-op), and list names are **plain text** — increment 2 converts them to links once `/lists/:id` exists:

```erb
<%
  author_names = @book.book_authors.map { |ba| ba.author.name }.join(", ")
  content_for :page_title, "#{@book.title}#{" by #{author_names}" if author_names.present?} | The Greatest Books"
  content_for :meta_description, "Read about #{@book.title}#{" by #{author_names}" if author_names.present?}, its ranking, categories, and the best-books lists it appears on."
%>

<div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
  <div class="lg:col-span-1">
    <div class="card bg-base-100 shadow-xl sticky top-8">
      <figure class="p-4 lg:p-6">
        <% if @book.primary_image&.file&.attached? %>
          <%= image_tag rails_public_blob_url(@book.primary_image.file),
              alt: "Cover of #{@book.title}",
              loading: "eager", fetchpriority: "high", decoding: "async",
              class: "w-full max-w-[180px] sm:max-w-[240px] lg:max-w-none h-auto mx-auto rounded-lg shadow-md" %>
        <% else %>
          <div class="w-full max-w-[180px] sm:max-w-[240px] lg:max-w-none mx-auto aspect-[2/3] bg-base-200 rounded-lg flex items-center justify-center" aria-hidden="true">
            <span class="text-5xl opacity-40">📖</span>
          </div>
        <% end %>
      </figure>
      <% if @book.first_published_year %>
        <div class="card-body pt-0">
          <div class="badge badge-primary">First published <%= @book.first_published_year %></div>
        </div>
      <% end %>
    </div>
  </div>

  <div class="lg:col-span-2 space-y-6">
    <div>
      <h1 class="text-3xl sm:text-4xl font-bold text-balance"><%= @book.title %></h1>
      <% if @book.subtitle.present? %>
        <p class="text-xl text-base-content/70 mt-2"><%= @book.subtitle %></p>
      <% end %>
      <% if author_names.present? %>
        <p class="text-lg text-base-content/80 mt-2">by <%= author_names %></p>
      <% end %>
      <% if @ranked_item %>
        <p class="text-base-content/70 mt-3">
          <% if @ranked_item.rank == 1 %>
            The <strong>greatest</strong> book of all time
          <% else %>
            The <strong><%= @ranked_item.rank.ordinalize %></strong> greatest book of all time
          <% end %>
        </p>
      <% end %>
    </div>

    <% if @description %>
      <div>
        <div class="max-w-[68ch] text-base sm:text-lg leading-relaxed text-base-content/80 space-y-4">
          <%= simple_format(@description.content, {}, sanitize: false, wrapper_tag: "p") %>
        </div>
        <% if @description.license_cc_by_sa_4? || @description.license_cc0? %>
          <p class="text-xs text-base-content/70 mt-3">
            Source:
            <% source_label = @description.source_name.presence || @description.source.titleize %>
            <% if @description.source_url.present? %>
              <%= link_to source_label, @description.source_url, class: "link", rel: "noopener nofollow", target: "_blank" %>
            <% else %>
              <%= source_label %>
            <% end %>
            · <%= @description.license_cc_by_sa_4? ? "CC BY-SA 4.0" : "CC0" %>
          </p>
        <% end %>
      </div>
    <% end %>

    <% if @categories_by_type.any? %>
      <div class="card bg-base-100 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-xl">Categories</h2>
          <% @categories_by_type.each do |category_type, categories| %>
            <div class="mt-3 first:mt-0">
              <h3 class="text-sm font-semibold text-base-content/70 mb-2 uppercase"><%= category_type.to_s.titleize %></h3>
              <div class="flex flex-wrap gap-2">
                <% categories.each do |category| %>
                  <span class="badge badge-ghost"><%= category.name %></span>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <% if @list_items.any? %>
      <div class="card bg-base-100 shadow-md">
        <div class="card-body">
          <h2 class="card-title text-xl">Appears on <%= pluralize(@list_items.size, "list") %></h2>
          <ul class="space-y-1">
            <% @list_items.each do |list_item| %>
              <li class="text-base-content/80"><%= list_item.list.name %></li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
  </div>
</div>
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/books/books_controller_test.rb`
Expected: PASS, 6 tests.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books/books_controller.rb test/controllers/books/books_controller_test.rb
git add app/controllers/books/books_controller.rb app/views/books/books test/controllers/books/books_controller_test.rb
git commit -m "Add books detail page at /book/:slug"
```

---

### Task 7: Legacy redirects and the numeric-slug collision guard

Implements spec decision **D6**. This is the highest-risk task in the increment: `/books/:id` is the legacy *canonical* book URL carrying roughly 156,000 indexed pages, and 124 of the 137 purely-numeric slugs collide with a real book id.

**Files:**
- Create: `app/controllers/books/legacy_books_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/books/legacy_books_controller_test.rb`

**Interfaces:**
- Consumes: `book_path(slug)` from Task 6.
- Produces: nothing.

**Worked example of the collision, from dev data.** Slug `"1"` belongs to book **id 22550** (北斗の拳（1）), while book **id 1** is *The Adventures of Augie March*. So `/book/1` and `/books/1` must resolve to different records — the first by slug, the second by id.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/books/legacy_books_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class LegacyBooksControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @book = books_books(:war_and_peace)
    end

    test "redirects the legacy canonical url permanently" do
      get "/books/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "redirects the older items url permanently" do
      get "/items/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "drops the legacy ranking configuration segment" do
      get "/rc/52/books/#{@book.id}"

      assert_response :moved_permanently
      assert_redirected_to "/book/#{@book.slug}"
    end

    test "404s for an unknown id" do
      get "/books/99999999"
      assert_response :not_found
    end

    # The regression guard for the friendly_id slug-before-id collision.
    test "a numeric slug and the same number as an id resolve to different books" do
      target = books_books(:crime_and_punishment)
      collider = Books::Book.create!(title: "Collider Volume One", slug: target.id.to_s)

      get "/book/#{target.id}"
      assert_response :success
      assert_equal collider.id, @controller.view_assigns["book"].id

      get "/books/#{target.id}"
      assert_response :moved_permanently
      assert_redirected_to "/book/#{target.slug}"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/books/legacy_books_controller_test.rb`
Expected: FAIL — routes do not exist.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the books `DomainConstraint` block, add these **above** the `root to: "books/ranked_items#index"` line. The numeric constraint is what stops them shadowing `/book/:slug`:

```ruby
    # Legacy 301s. /books/:id is the legacy CANONICAL book url (~156k indexed);
    # /items/:id is its older alias. Legacy rc ids are meaningless here, so the
    # rc segment is matched and discarded.
    scope "(/rc/:ranking_configuration_id)" do
      get "books/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}
    end
    get "items/:id", to: "books/legacy_books#show", constraints: {id: /\d+/}
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/books/legacy_books_controller.rb`:

```ruby
class Books::LegacyBooksController < ApplicationController
  # find_by!(id:), never find: Books::Book uses friendly_id with :finders, which
  # resolves slugs before primary keys. 124 books have a purely numeric slug that
  # matches a different book's id, so .find here would redirect to the wrong book.
  def show
    book = Books::Book.find_by!(id: params[:id])

    redirect_to book_path(book.slug), status: :moved_permanently
  end
end
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/controllers/books/legacy_books_controller_test.rb`
Expected: PASS, 5 tests.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books/legacy_books_controller.rb test/controllers/books/legacy_books_controller_test.rb
git add app/controllers/books/legacy_books_controller.rb config/routes.rb test/controllers/books/legacy_books_controller_test.rb
git commit -m "Add 301 redirects from legacy books urls to /book/:slug"
```

---

### Task 8: Playwright coverage and full verification

**Files:**
- Modify: `e2e/tests/books/homepage.spec.ts`
- Create: `e2e/tests/books/book-detail.spec.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

The `books` Playwright project already exists in `e2e/playwright.config.ts` with `baseURL: 'https://dev-new.thegreatestbooks.org'` and `testMatch: /books\/(?!admin\/).*/`. No config change is needed. E2E runs against the **development** database, which has real ranked books.

- [ ] **Step 1: Rewrite the homepage spec**

The current spec asserts the deleted placeholder hero. Replace `e2e/tests/books/homepage.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books ranked grid', () => {
  test('root loads successfully', async ({ page }) => {
    const response = await page.goto('/');

    expect(response?.status()).toBe(200);
  });

  test('root renders the ranked grid heading', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: /Greatest Books/i, level: 1 })).toBeVisible();
  });

  test('root uses the cmyk theme and declares a language', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'cmyk');
    await expect(page.locator('html')).toHaveAttribute('lang', 'en');
  });

  test('root is noindex until cutover', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
  });

  test('pagination links are path-based', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('nav.pagy a[href="/page/2"]').first()).toBeVisible();
  });

  test('page two loads and links back to the root, not /page/1', async ({ page }) => {
    await page.goto('/page/2');

    await expect(page.getByText(/Page 2 of/)).toBeVisible();
    await expect(page.locator('nav.pagy a[href="/page/1"]')).toHaveCount(0);
  });

  test('navbar exposes the login button', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_login_button')).toBeVisible();
  });
});
```

- [ ] **Step 2: Add the detail-page spec**

Create `e2e/tests/books/book-detail.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Book detail page', () => {
  test('a grid card links through to a book page', async ({ page }) => {
    await page.goto('/');

    const firstCardLink = page.locator('.card h2 a').first();
    const title = (await firstCardLink.textContent())?.trim() ?? '';
    await firstCardLink.click();

    await expect(page).toHaveURL(/\/book\//);
    await expect(page.getByRole('heading', { level: 1, name: title })).toBeVisible();
  });

  test('legacy /books/:id redirects permanently to the slug url', async ({ page }) => {
    const response = await page.goto('/books/1');

    expect(response?.status()).toBe(200);
    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('legacy /items/:id redirects to the slug url', async ({ page }) => {
    await page.goto('/items/1');

    await expect(page).toHaveURL(/\/book\/[^/]+$/);
  });

  test('/the-greatest-books redirects to the root', async ({ page }) => {
    await page.goto('/the-greatest-books');

    await expect(page).toHaveURL(/thegreatestbooks\.org\/$/);
  });
});
```

- [ ] **Step 3: Run the full Ruby suite**

Run: `bin/rails test`
Expected: PASS with no failures and no errors. Investigate any failure outside `test/controllers/books` — it means a shared change (routes, layout, the pagy initializer) leaked into another domain.

- [ ] **Step 4: Run the linter**

Run: `bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 5: Build assets**

Run: `yarn build:all`
Expected: succeeds and emits `app/assets/builds/books.css` and `app/assets/builds/books.js`.

- [ ] **Step 6: Run the Playwright books project**

The dev server is already running and `https://dev-new.thegreatestbooks.org/` was confirmed reachable (HTTP 200) before this plan was dispatched — do not start another one.

Run: `npx playwright test --config=e2e/playwright.config.ts --project=books`
Expected: PASS.

E2E runs against the **development** database, which holds 24,242 real ranked books — so pagination, covers, and detail pages all have real data. If every spec fails identically on a page that is not the books site, that is the hosts-file or Caddy routing, not the code: report it rather than editing specs to make it pass.

- [ ] **Step 7: Manual check**

Load `https://dev-new.thegreatestbooks.org/` and confirm: the grid renders 2 columns on a narrow window and 6 on a wide one; covers are crisp rather than upscaled; the current page in the pagination is **highlighted, not greyed-out** (this is the B4 fix); clicking a card reaches its book page; `/books/1` lands on a `/book/<slug>` URL.

- [ ] **Step 8: Commit**

```bash
git add e2e/tests/books
git commit -m "Add Playwright coverage for the books grid and detail page"
```

---

## Self-Review

**Spec coverage.** Every increment-1 item in the spec maps to a task: routes and the URL map (5, 7), robots plumbing D2/D4 (2, 4, 5), `Pagy::PathBasedPaging` D5a (1), `Books::RankedBooksQuery` D7/D8 (3), the grid D5/D10/D11 (5), `/book/:slug` D1/D6/D9 (6), legacy 301s D6 (7), `books/paging.css` B3/B4 (4), layout fixes B6/B7 (4, 5), Playwright (8). Bugs B1, B5, B9 are handled in Task 5; B2 in Task 6. B8 belongs to increment 2 (list pagination inside a Turbo Frame) and is correctly out of scope here.

**Deliberately deferred.** `/lists` and `/lists/:id` and the nav entry pointing at them (increment 2); all user-list wiring (increment 3); converting the other 12 public pagy call sites and fixing music/games/movies `paging.css` (spec follow-up 1, its own PR); the 8.9 MB cover PNG (spec follow-up 2, a data fix).

**Type consistency.** `Books::RankedBooksQuery.call(ranking_configuration:)` is defined in Task 3 and called with that exact keyword in Task 5. `Books::CardComponent.new(ranked_item:, index:)` is defined and rendered within Task 5. `books_robots_content` is defined in Task 2 and called in Task 4's layout. `book_path(slug)` is declared in Task 5 and consumed by Tasks 5, 6, and 7. `Books::PublicIndexing.enabled?` is defined in Task 2 and stubbed in its own test only.

**Why Task 5 is large.** The card component and the grid were originally separate tasks, but the card template calls `book_path`, so it cannot render — let alone be tested — until the routes land. Neither half is independently reviewable, which is the criterion for merging them.

**On Task 3's query-count assertion.** Step 4 tells the implementer to run `assert_queries_count(4)` and correct the number to whatever the preload actually produces. This is deliberate and is not "adjusting an assertion until it passes": the exact count is not knowable a priori, and the value of the test is that it *pins* the count so a future change reintroducing an N+1 fails loudly. The implementer must not remove the assertion or widen it to a range.
