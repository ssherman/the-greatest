# Books Filters — Modal UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the books filter URLs a UI — one modal that stages genre, country, and date selections, plus a chip row that shows and removes active filters.

**Architecture:** The modal is a plain GET form posting to `Books::FiltersController#show`, which validates the selection and 303-redirects to the canonical path built by `Books::FilterPath`. That keeps the URL grammar in exactly one place (Ruby) with no JS reimplementation, and makes staging work with checkboxes alone. Facet content lazy-loads into a Turbo Frame when the dialog opens, so its ~300–500ms cost never touches page render.

**Tech Stack:** Rails 8.1, ViewComponent, Turbo Frames, one Stimulus controller, DaisyUI 5 + Tailwind 4, Minitest, Playwright. Design spec: `docs/superpowers/specs/2026-08-03-books-filters-design.md` §7. Increments 1–3 are **merged to main at `e3efe956`**.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Work in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-filters-modal` on branch **`worktree-books-filters-modal`** (never `main`). Baseline: **5525 runs, 0 failures**.
- The worktree shares the test database `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
- Namespace media code (`Books::`); tests mirror the namespace.
- **No code comments** unless a landmine genuinely needs recording.
- **Controller tests assert behavior** — status codes, redirect targets, params, no errors — **never HTML/CSS/copy.** Component tests may assert structural contracts (a form's `action`/`method`, an input's `name`, a link's `href`) because those are the interface, but never class names, layout, or copy.
- **Every new user-facing flow needs a Playwright E2E test** in `web-app/e2e/tests/`. Add `data-testid` (kebab-case) only where role/text/label cannot target an element.
- **THE DEVELOPMENT DATABASE IS NOT DISPOSABLE.** A `PreToolUse` hook hard-blocks destructive commands. Never run `db:drop`/`db:reset`/`db:schema:load` or `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES). **This plan needs no migration and no schema change.**
- Lint with `bundle exec standardrb`, NOT `bin/rubocop`. Never run brakeman.
- **Gate before "done":** `bundle exec standardrb` clean and `bin/rails test` passing. Compare the **runs count** against the 5525 baseline, not just failures.
- Every git commit message ends with: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

### Verified environment facts you can rely on

- The books layout loads the **`application`** JS bundle (`app/views/layouts/books/application.html.erb:19`), which imports `@hotwired/turbo-rails` and `./controllers`. **Turbo Frames and Stimulus both work on books pages.** (`app/javascript/books.js` exists but the layout does not use it — a pre-existing oddity, not this plan's business.)
- `app/javascript/controllers/index.js` is auto-generated. After adding a controller, run `bin/rails stimulus:manifest:update`.
- Established modal pattern (`app/components/music/filter_tabs_component.html.erb`): native `<dialog id="x" class="modal">` opened with `onclick="x.showModal()"`, a `<div class="modal-box">`, and `<form method="dialog"><button class="btn">Cancel</button></form>` to close. **No JS is needed to open or close a dialog.**
- DaisyUI-5 form pattern in this codebase: `<div class="form-control">` + `<label class="label">` + `input input-bordered w-full`.
- `Books::CardComponent::GRID_CONTAINER_CLASS` holds the grid classes; the index view already uses it.

### Interfaces from increments 1–3 (merged, do not recreate)

- `Books::FilterParams.call(params)` → `Result` with `categories`, `countries`, `year_start`, `year_end`. Reads `params[:category_id]` / `params[:country_id]` as **comma-joined slug strings**, and `params[:year]` / `:published_start` / `:published_end`. **Raises `ActiveRecord::RecordNotFound`** on an unknown or soft-deleted category slug, an unknown country slug, or a year that is non-numeric or outside `-4000..(current year + 5)`. Returns years normalized (`"0001900"` → `"1900"`).
- `Books::FilterPath.call(categories:, countries:, year_start:, year_end:, page: nil, ranking_configuration: nil)` → String path, slugs sorted. A **non-primary** `ranking_configuration` prefixes `/rc/:id`; a primary one or `nil` adds no prefix.
- `Books::FilterTitle.call(categories:, countries:, year_start:, year_end:)` → String.
- `Books::FilterFacetsQuery.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: 36)` → `Result` with `genres` and `countries`, each an array of `{record:, count:}` ordered by count desc. **Already-selected values are excluded from their own axis's list**, and `unknown` never appears in countries.
- `Books::RankedItemsController#index` already sets `@categories`, `@countries`, `@filtered`, `@page_title`, and `@canonical_path`. It does **not** yet expose the year bounds as instance variables — Task 3 adds that.
- `/rc/` URLs emit **no** canonical tag (spec D4). Filter *links* still carry `/rc/` for navigation; only the canonical drops out.

---

## Scope: increment 4 only

This plan covers **increment 4** (the modal UI). Increment 5 (the admin inline `BookCountries` editor) is deliberately **not** here: it is a different layer with different constraints — admin authorization, the admin layout, an admin E2E suite — and it follows the established increment-4c inline-association pattern rather than anything in this plan. It is a short plan of its own and blocks nothing here.

## Two deliberate deviations from spec §7

1. **Genre search is instant-filter only.** §7 describes a Stimulus controller doing double duty — substring-filtering the visible 36 *and* carrying staged selections into a frame reload for "search all genres." **Task 4 ships only the first half.** The deep search is the complex half (it must round-trip staged checkbox state through a frame request to avoid losing it), and the facet query already surfaces the 36 most relevant genres *for the current filter state*, which covers the common case. Ship without it and see whether it is missed. If you want it, it is an additive follow-up, not a rework.

2. **Non-genre selected categories are preserved as hidden inputs.** The modal offers **genres only** (matching legacy, whose facet method is `category_type: :genre` with `.not_location`). But a URL can legitimately carry a `location` or `subject` category — book detail pages link into those. Without care, opening the modal on `/the-greatest/france/books` and pressing Apply would silently **drop** the `france` filter. Task 2 renders those as hidden fields so they survive a round-trip.

---

## File Structure

- `config/routes.rb` — **modify.** Two named routes: `books_filters` and `books_filters_options`.
- `app/controllers/books/filters_controller.rb` — **new.** Two actions: `show` (validate → 303 to canonical path) and `options` (render the facet form into a frame). One responsibility: translating a modal submission into a canonical URL.
- `app/components/books/filter_facets_component.rb` + `.html.erb` — **new.** The GET form: genre checkboxes, country checkboxes, year inputs, hidden preservation fields.
- `app/components/books/filter_modal_component.rb` + `.html.erb` — **new.** The `<dialog>` shell and the lazy Turbo Frame. Knows nothing about facets.
- `app/components/books/filter_bar_component.rb` + `.html.erb` — **new.** The Filters button and the active-filter chip row.
- `app/views/books/filters/options.html.erb` — **new.** Frame wrapper around the facets component.
- `app/controllers/books/ranked_items_controller.rb` — **modify.** Expose `@year_start` / `@year_end`.
- `app/views/books/ranked_items/index.html.erb` — **modify.** Render the bar and the modal.
- `app/javascript/controllers/books/filter_search_controller.js` — **new.** Substring filter over rendered genre options.
- `app/javascript/controllers/index.js` — **regenerated** by `bin/rails stimulus:manifest:update`.
- `e2e/tests/books/filters.spec.ts` — **new.**
- Tests mirroring each Ruby file under `test/`.

**Task order:** Task 1 (routes + `#show`) → Task 2 (`#options` + facets component) → Task 3 (bar + modal + view wiring) → Task 4 (Stimulus) → Task 5 (E2E).

---

### Task 1: Routes and `Books::FiltersController#show`

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/books/filters_controller.rb`
- Test: `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Consumes: `Books::FilterParams`, `Books::FilterPath`.
- Produces: named routes `books_filters_path` (`/filters`) and `books_filters_options_path` (`/filters/options`). `#show` accepts `category_slugs[]`, `country_slugs[]`, `year_start`, `year_end`, `ranking_configuration_id` and 303-redirects to the canonical path. Later tasks post the modal form here.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the books `DomainConstraint` block, immediately **before** the filter-route loop's comment block:

```ruby
    # The modal posts here; #show 303s to the canonical filter path so the URL
    # grammar lives only in Books::FilterPath. Neither is ever linked publicly.
    get "filters", to: "books/filters#show", as: :books_filters
    get "filters/options", to: "books/filters#options", as: :books_filters_options
```

- [ ] **Step 2: Verify the routes registered and shadow nothing**

```bash
bin/rails routes | grep -E "books/filters#"
```
Expected: exactly two rows, `books_filters GET /filters` and `books_filters_options GET /filters/options`. Nothing else in the books block starts with `filters`, so no shadowing is possible — confirm from the output rather than assuming.

- [ ] **Step 3: Write the failing test**

Create `test/controllers/books/filters_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class FiltersControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @rc = ranking_configurations(:books_global)
    end

    test "redirects to the canonical path for a genre selection" do
      get "/filters", params: {category_slugs: ["novels"]}

      assert_response :see_other
      assert_redirected_to "/the-greatest/novels/books"
    end

    test "sorts slugs so the redirect target is canonical" do
      get "/filters", params: {category_slugs: ["novels", "fiction"]}

      assert_redirected_to "/the-greatest/fiction,novels/books"
    end

    test "combines genre, country and years" do
      get "/filters", params: {
        category_slugs: ["novels"],
        country_slugs: ["french"],
        year_start: "1900",
        year_end: "2000"
      }

      assert_redirected_to "/the-greatest/novels/books/written-by/french/authors/from/1900/to/2000"
    end

    test "an empty selection redirects to the root" do
      get "/filters"

      assert_redirected_to "/"
    end

    test "normalizes a zero-padded year" do
      get "/filters", params: {year_start: "0001900"}

      assert_redirected_to "/the-greatest-books/since/1900"
    end

    test "keeps a non-primary ranking configuration in the redirect" do
      alternate = ranking_configurations(:books_inherited)

      get "/filters", params: {category_slugs: ["novels"], ranking_configuration_id: alternate.id}

      assert_redirected_to "/rc/#{alternate.id}/the-greatest/novels/books"
    end

    test "adds no rc prefix for the primary ranking configuration" do
      get "/filters", params: {category_slugs: ["novels"], ranking_configuration_id: @rc.id}

      assert_redirected_to "/the-greatest/novels/books"
    end

    test "an unknown category slug is a 404" do
      get "/filters", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end

    test "an unknown country slug is a 404" do
      get "/filters", params: {country_slugs: ["atlantean"]}

      assert_response :not_found
    end

    test "a malformed year is a 404" do
      get "/filters", params: {year_start: "not-a-year"}

      assert_response :not_found
    end

    test "an unknown ranking configuration is a 404" do
      get "/filters", params: {ranking_configuration_id: 999_999}

      assert_response :not_found
    end

    test "the redirect is not cacheable" do
      get "/filters", params: {category_slugs: ["novels"]}

      assert_match "no-store", response.headers["Cache-Control"].to_s
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: FAIL — the controller does not exist, so requests raise a routing/constant error.

- [ ] **Step 5: Write the controller**

Create `app/controllers/books/filters_controller.rb`:

```ruby
class Books::FiltersController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :prevent_caching
  before_action :find_ranking_configuration

  def show
    filters = resolved_filters

    redirect_to Books::FilterPath.call(
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end,
      ranking_configuration: @ranking_configuration
    ), status: :see_other
  end

  private

  def resolved_filters
    Books::FilterParams.call(
      ActionController::Parameters.new(
        category_id: Array(params[:category_slugs]).join(","),
        country_id: Array(params[:country_slugs]).join(","),
        published_start: params[:year_start],
        published_end: params[:year_end]
      )
    )
  end

  def find_ranking_configuration
    return if params[:ranking_configuration_id].blank?

    @ranking_configuration = Books::RankingConfiguration.find(params[:ranking_configuration_id])
  end
end
```

`@ranking_configuration` stays `nil` when the param is absent, which is exactly what `Books::FilterPath` wants for "no `/rc/` prefix."

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: PASS, 12 runs, 0 failures.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books/filters_controller.rb test/controllers/books/filters_controller_test.rb config/routes.rb
bundle exec standardrb
bin/rails test
git add config/routes.rb app/controllers/books/filters_controller.rb test/controllers/books/filters_controller_test.rb
git commit -m "Add Books::FiltersController redirect endpoint

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `#options` and `Books::FilterFacetsComponent`

**Files:**
- Modify: `app/controllers/books/filters_controller.rb`
- Create: `app/components/books/filter_facets_component.rb`
- Create: `app/components/books/filter_facets_component.html.erb`
- Create: `app/views/books/filters/options.html.erb`
- Test: `test/components/books/filter_facets_component_test.rb`
- Test: extend `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Consumes: `Books::FilterFacetsQuery`, `Books::FilterParams`, and the `books_filters_path` route from Task 1.
- Produces: `GET /filters/options` rendering a Turbo Frame with id **`books_filter_options`** containing a GET form to `/filters` with `data-turbo-frame="_top"`. Task 3's modal points its frame `src` at this action. Field names: `category_slugs[]`, `country_slugs[]`, `year_start`, `year_end`, `ranking_configuration_id`.

**Read the "Two deliberate deviations" section above before implementing** — deviation 2 (hidden preservation of non-genre categories) is implemented here and looks like dead code if you skim it.

- [ ] **Step 1: Write the failing component test**

Create `test/components/books/filter_facets_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterFacetsComponentTest < ViewComponent::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)
    end

    def facets_for(categories: [], countries: [], year_start: nil, year_end: nil)
      Books::FilterFacetsQuery.call(
        ranking_configuration: @rc,
        categories: categories,
        countries: countries,
        year_start: year_start,
        year_end: year_end
      )
    end

    def render_component(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      render_inline(
        Books::FilterFacetsComponent.new(
          facets: facets_for(categories: categories, countries: countries, year_start: year_start, year_end: year_end),
          categories: categories,
          countries: countries,
          year_start: year_start,
          year_end: year_end,
          ranking_configuration: ranking_configuration
        )
      )
    end

    test "posts to the filters endpoint and escapes the frame" do
      render_component

      assert_selector "form[action='/filters'][method='get'][data-turbo-frame='_top']"
    end

    test "renders a checkbox per faceted genre" do
      render_component

      assert_selector "input[type=checkbox][name='category_slugs[]'][value=novels]"
    end

    test "renders a checkbox per faceted country" do
      render_component

      assert_selector "input[type=checkbox][name='country_slugs[]'][value=french]"
    end

    test "a selected genre renders checked so it can be unchecked" do
      render_component(categories: [categories(:books_novels_genre)])

      assert_selector "input[name='category_slugs[]'][value=novels][checked]"
    end

    test "a selected country renders checked so it can be unchecked" do
      render_component(countries: [books_countries(:french)])

      assert_selector "input[name='country_slugs[]'][value=french][checked]"
    end

    test "preserves a selected non-genre category as a hidden field" do
      render_component(categories: [categories(:books_france_location)])

      assert_selector "input[type=hidden][name='category_slugs[]'][value=france]", visible: :all
      assert_no_selector "input[type=checkbox][name='category_slugs[]'][value=france]"
    end

    test "renders the current year bounds" do
      render_component(year_start: "1900", year_end: "2000")

      assert_selector "input[name=year_start][value='1900']"
      assert_selector "input[name=year_end][value='2000']"
    end

    test "carries a non-primary ranking configuration as a hidden field" do
      alternate = ranking_configurations(:books_inherited)

      render_component(ranking_configuration: alternate)

      assert_selector "input[type=hidden][name=ranking_configuration_id][value='#{alternate.id}']", visible: :all
    end

    test "omits the ranking configuration field when there is none" do
      render_component

      assert_no_selector "input[name=ranking_configuration_id]", visible: :all
    end

    test "the clear control points at the unfiltered root" do
      render_component(categories: [categories(:books_novels_genre)])

      assert_selector "a[href='/']"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/books/filter_facets_component_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::FilterFacetsComponent`.

- [ ] **Step 3: Write the component class**

Create `app/components/books/filter_facets_component.rb`:

```ruby
module Books
  class FilterFacetsComponent < ViewComponent::Base
    def initialize(facets:, categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      @facets = facets
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
    end

    private

    attr_reader :facets, :categories, :countries, :year_start, :year_end, :ranking_configuration

    def selected_genres
      categories.select { |category| category.category_type.to_s == "genre" }
    end

    # A location/subject category can arrive from a book page's link. The modal
    # offers genres only, so those must ride along hidden or Apply would drop them.
    def preserved_categories
      categories - selected_genres
    end

    def genre_options
      selected_genres.map { |category| {record: category, count: nil, checked: true} } +
        facets.genres.map { |row| {record: row[:record], count: row[:count], checked: false} }
    end

    def country_options
      countries.map { |country| {record: country, count: nil, checked: true} } +
        facets.countries.map { |row| {record: row[:record], count: row[:count], checked: false} }
    end

    def clear_path
      Books::FilterPath.call(ranking_configuration: ranking_configuration)
    end
  end
end
```

- [ ] **Step 4: Write the component template**

Create `app/components/books/filter_facets_component.html.erb`:

```erb
<%= form_with url: books_filters_path, method: :get, data: {turbo_frame: "_top"} do %>
  <% if ranking_configuration %>
    <%= hidden_field_tag :ranking_configuration_id, ranking_configuration.id %>
  <% end %>
  <% preserved_categories.each do |category| %>
    <%= hidden_field_tag "category_slugs[]", category.slug, id: nil %>
  <% end %>

  <div class="space-y-6">
    <section>
      <h4 class="font-semibold text-sm uppercase tracking-wide text-base-content/70 mb-2">Genres</h4>
      <div class="form-control">
        <input type="search"
               placeholder="Filter genres"
               class="input input-bordered w-full"
               data-books--filter-search-target="query"
               data-action="input->books--filter-search#filter">
      </div>
      <div class="flex flex-col gap-1 max-h-56 overflow-y-auto pr-1 mt-2">
        <% genre_options.each do |option| %>
          <label class="label cursor-pointer justify-start gap-2"
                 data-books--filter-search-target="option"
                 data-filter-label="<%= option[:record].name.downcase %>">
            <%= check_box_tag "category_slugs[]", option[:record].slug, option[:checked], id: nil, class: "checkbox checkbox-sm" %>
            <span class="label-text"><%= option[:record].name %></span>
            <% if option[:count] %>
              <span class="label-text text-base-content/60">(<%= number_with_delimiter(option[:count]) %>)</span>
            <% end %>
          </label>
        <% end %>
      </div>
    </section>

    <section>
      <h4 class="font-semibold text-sm uppercase tracking-wide text-base-content/70 mb-2">Countries</h4>
      <div class="flex flex-col gap-1 max-h-56 overflow-y-auto pr-1">
        <% country_options.each do |option| %>
          <label class="label cursor-pointer justify-start gap-2">
            <%= check_box_tag "country_slugs[]", option[:record].slug, option[:checked], id: nil, class: "checkbox checkbox-sm" %>
            <span class="label-text"><%= option[:record].name %></span>
            <% if option[:count] %>
              <span class="label-text text-base-content/60">(<%= number_with_delimiter(option[:count]) %>)</span>
            <% end %>
          </label>
        <% end %>
      </div>
    </section>

    <section class="grid grid-cols-2 gap-4">
      <div class="form-control">
        <label class="label" for="year_start"><span class="label-text">From year</span></label>
        <%= number_field_tag :year_start, year_start, class: "input input-bordered w-full", placeholder: "Any" %>
      </div>
      <div class="form-control">
        <label class="label" for="year_end"><span class="label-text">To year</span></label>
        <%= number_field_tag :year_end, year_end, class: "input input-bordered w-full", placeholder: "Any" %>
      </div>
    </section>
  </div>

  <div class="modal-action">
    <%= link_to "Clear", clear_path, class: "btn btn-ghost", data: {turbo_frame: "_top"} %>
    <form method="dialog"><button class="btn">Cancel</button></form>
    <%= submit_tag "Apply", class: "btn btn-primary", data: {disable_with: false} %>
  </div>
<% end %>
```

`id: nil` on the repeated inputs suppresses Rails' duplicate `id` attributes, which would otherwise repeat across every checkbox.

- [ ] **Step 5: Run the component test to verify it passes**

Run: `bin/rails test test/components/books/filter_facets_component_test.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 6: Add the `#options` action and its view**

In `app/controllers/books/filters_controller.rb`, add above `private`:

```ruby
  def options
    filters = resolved_filters

    @categories = filters.categories
    @countries = filters.countries
    @year_start = filters.year_start
    @year_end = filters.year_end
    @facets = Books::FilterFacetsQuery.call(
      ranking_configuration: @ranking_configuration || Books::RankingConfiguration.default_primary,
      categories: @categories,
      countries: @countries,
      year_start: @year_start,
      year_end: @year_end
    )
  end
```

Create `app/views/books/filters/options.html.erb`:

```erb
<%= turbo_frame_tag "books_filter_options" do %>
  <%= render Books::FilterFacetsComponent.new(
        facets: @facets,
        categories: @categories,
        countries: @countries,
        year_start: @year_start,
        year_end: @year_end,
        ranking_configuration: @ranking_configuration
      ) %>
<% end %>
```

- [ ] **Step 7: Add `#options` tests**

Append inside `module Books; class FiltersControllerTest`, before the final `end`s:

```ruby
    test "options renders the facet frame" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/options"

      assert_response :success
      assert_select "turbo-frame#books_filter_options"
      assert_select "form[action='/filters']"
    end

    test "options reflects the current selection as checked" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/options", params: {category_slugs: ["novels"]}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=novels][checked]"
    end

    test "options 404s on an unknown slug" do
      get "/filters/options", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end
```

- [ ] **Step 8: Run the controller tests**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: PASS, 15 runs, 0 failures.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books/filters_controller.rb app/components/books test/components/books test/controllers/books/filters_controller_test.rb
bundle exec standardrb
bin/rails test
git add app/controllers/books/filters_controller.rb app/components/books app/views/books/filters test/components/books test/controllers/books/filters_controller_test.rb
git commit -m "Add the books filter facets form

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Filter bar, modal shell, and view wiring

**Files:**
- Create: `app/components/books/filter_bar_component.rb` + `.html.erb`
- Create: `app/components/books/filter_modal_component.rb` + `.html.erb`
- Modify: `app/controllers/books/ranked_items_controller.rb`
- Modify: `app/views/books/ranked_items/index.html.erb`
- Test: `test/components/books/filter_bar_component_test.rb`
- Test: extend `test/controllers/books/ranked_items_controller_test.rb`

**Interfaces:**
- Consumes: `books_filters_options_path` from Task 1, `Books::FilterPath`.
- Produces: the modal `<dialog id="books_filter_modal">`, opened by the bar's button via `books_filter_modal.showModal()`. Task 5's E2E drives exactly these.

- [ ] **Step 1: Write the failing bar test**

Create `test/components/books/filter_bar_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterBarComponentTest < ViewComponent::TestCase
    def render_bar(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      render_inline(
        Books::FilterBarComponent.new(
          categories: categories,
          countries: countries,
          year_start: year_start,
          year_end: year_end,
          ranking_configuration: ranking_configuration
        )
      )
    end

    test "renders a button that opens the modal" do
      render_bar

      assert_selector "button[onclick='books_filter_modal.showModal()']"
    end

    test "renders no chips when nothing is filtered" do
      render_bar

      assert_no_selector "[data-testid=filter-chip]"
    end

    test "a genre chip links to the path without that genre" do
      render_bar(categories: [categories(:books_novels_genre)])

      assert_selector "[data-testid=filter-chip]", count: 1
      assert_selector "a[href='/']"
    end

    test "removing one genre keeps the others" do
      render_bar(categories: [categories(:books_novels_genre), categories(:books_classics_genre)])

      assert_selector "[data-testid=filter-chip]", count: 2
      assert_selector "a[href='/the-greatest/classics/books']"
      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "a country chip links to the path without that country" do
      render_bar(categories: [categories(:books_novels_genre)], countries: [books_countries(:french)])

      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "the date range is a single chip that clears both bounds" do
      render_bar(categories: [categories(:books_novels_genre)], year_start: "1900", year_end: "2000")

      assert_selector "[data-testid=filter-chip]", count: 2
      assert_selector "a[href='/the-greatest/novels/books']"
    end

    test "chips keep a non-primary ranking configuration" do
      alternate = ranking_configurations(:books_inherited)

      render_bar(categories: [categories(:books_novels_genre)], countries: [books_countries(:french)], ranking_configuration: alternate)

      assert_selector "a[href='/rc/#{alternate.id}/the-greatest/novels/books']"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/components/books/filter_bar_component_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::FilterBarComponent`.

- [ ] **Step 3: Write the bar component**

Create `app/components/books/filter_bar_component.rb`:

```ruby
module Books
  class FilterBarComponent < ViewComponent::Base
    MODAL_ID = "books_filter_modal"

    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
    end

    private

    attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration

    def modal_id
      MODAL_ID
    end

    def chips
      category_chips + country_chips + date_chips
    end

    def category_chips
      categories.map do |category|
        {label: category.name, path: path_without(categories: categories - [category])}
      end
    end

    def country_chips
      countries.map do |country|
        {label: country.name, path: path_without(countries: countries - [country])}
      end
    end

    def date_chips
      return [] if year_start.blank? && year_end.blank?

      [{label: date_label, path: path_without(year_start: nil, year_end: nil)}]
    end

    def date_label
      return year_start if year_start.present? && year_start == year_end
      return "#{year_start}–#{year_end}" if year_start.present? && year_end.present?
      return "Since #{year_start}" if year_start.present?

      "To #{year_end}"
    end

    def path_without(categories: self.categories, countries: self.countries, year_start: self.year_start, year_end: self.year_end)
      Books::FilterPath.call(
        categories: categories,
        countries: countries,
        year_start: year_start,
        year_end: year_end,
        ranking_configuration: ranking_configuration
      )
    end
  end
end
```

- [ ] **Step 4: Write the bar template**

Create `app/components/books/filter_bar_component.html.erb`:

```erb
<div class="flex flex-wrap items-center gap-2">
  <button type="button" class="btn btn-primary btn-sm" onclick="<%= modal_id %>.showModal()">
    Filters
  </button>

  <% chips.each do |chip| %>
    <span class="badge badge-lg gap-1" data-testid="filter-chip">
      <%= chip[:label] %>
      <%= link_to chip[:path], class: "font-bold", aria: {label: "Remove #{chip[:label]} filter"} do %>
        &times;
      <% end %>
    </span>
  <% end %>
</div>
```

- [ ] **Step 5: Run the bar test to verify it passes**

Run: `bin/rails test test/components/books/filter_bar_component_test.rb`
Expected: PASS, 7 runs, 0 failures.

- [ ] **Step 6: Write the modal component**

Create `app/components/books/filter_modal_component.rb`:

```ruby
module Books
  class FilterModalComponent < ViewComponent::Base
    def initialize(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      @categories = categories || []
      @countries = countries || []
      @year_start = year_start
      @year_end = year_end
      @ranking_configuration = ranking_configuration
    end

    private

    attr_reader :categories, :countries, :year_start, :year_end, :ranking_configuration

    def modal_id
      Books::FilterBarComponent::MODAL_ID
    end

    def options_path
      helpers.books_filters_options_path(
        category_slugs: categories.map(&:slug),
        country_slugs: countries.map(&:slug),
        year_start: year_start,
        year_end: year_end,
        ranking_configuration_id: ranking_configuration&.id
      )
    end
  end
end
```

Create `app/components/books/filter_modal_component.html.erb`:

```erb
<dialog id="<%= modal_id %>" class="modal">
  <div class="modal-box max-w-xl" data-controller="books--filter-search">
    <h3 class="font-bold text-lg mb-4">Filters</h3>

    <%= turbo_frame_tag "books_filter_options", src: options_path, loading: :lazy do %>
      <div class="flex justify-center py-8">
        <span class="loading loading-spinner loading-md"></span>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button aria-label="Close">close</button>
  </form>
</dialog>
```

`loading: :lazy` means the frame fetches when it becomes visible. A closed `<dialog>` is not visible, so the facet query does not run until the modal is opened — which is the entire point of putting it in a frame.

- [ ] **Step 7: Expose the year bounds on the index controller**

In `app/controllers/books/ranked_items_controller.rb`, change the `index` action so the year bounds become instance variables the components can read. Assign them right after `@countries`, then replace **every** remaining `filters.year_start` / `filters.year_end` reference in that action with `@year_start` / `@year_end` — they appear in the `@filtered` predicate and in the `FilterTitle`, `FilterPath`, and `RankedBooksQuery` calls:

```ruby
    @categories = filters.categories
    @countries = filters.countries
    @year_start = filters.year_start
    @year_end = filters.year_end
    @filtered = @categories.any? || @countries.any? || @year_start.present? || @year_end.present?
```

Then use `@year_start` / `@year_end` in the `FilterTitle`, `FilterPath`, and `RankedBooksQuery` calls in that same action.

- [ ] **Step 8: Render the bar and modal in the index view**

In `app/views/books/ranked_items/index.html.erb`, immediately after the `<h1>` line, add:

```erb
  <%= render Books::FilterBarComponent.new(
        categories: @categories,
        countries: @countries,
        year_start: @year_start,
        year_end: @year_end,
        ranking_configuration: @ranking_configuration
      ) %>
```

and at the very end of the file, after the closing `</div>`:

```erb
<%= render Books::FilterModalComponent.new(
      categories: @categories,
      countries: @countries,
      year_start: @year_start,
      year_end: @year_end,
      ranking_configuration: @ranking_configuration
    ) %>
```

- [ ] **Step 9: Add index integration tests**

Append inside `module Books; class RankedItemsControllerTest`:

```ruby
    test "the index renders the filter bar and modal" do
      get "/"

      assert_response :success
      assert_select "button[onclick='books_filter_modal.showModal()']"
      assert_select "dialog#books_filter_modal"
    end

    test "a filtered index renders a chip per active filter" do
      get "/the-greatest/novels/books"

      assert_response :success
      assert_select "[data-testid=filter-chip]", 1
    end

    test "the modal frame is lazy and carries the current filter state" do
      get "/the-greatest/novels/books"

      assert_select "turbo-frame#books_filter_options[loading=lazy]" do |frame|
        assert_match "category_slugs", frame.first["src"]
        assert_match "novels", frame.first["src"]
      end
    end
```

- [ ] **Step 10: Run the tests**

Run: `bin/rails test test/controllers/books/ranked_items_controller_test.rb test/components/books/`
Expected: PASS, 0 failures. The pre-existing `ranked_items_controller_test.rb` tests must all still pass — if the query-count pin (`assert_queries_count`) now fails, the bar or modal added a query; report the new number rather than just bumping the pin.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb --fix app/components/books app/controllers/books app/views/books test/components/books test/controllers/books
bundle exec standardrb
bin/rails test
git add app/components/books app/controllers/books/ranked_items_controller.rb app/views/books/ranked_items/index.html.erb test/components/books test/controllers/books
git commit -m "Render the books filter bar and modal

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Genre search Stimulus controller

**Files:**
- Create: `app/javascript/controllers/books/filter_search_controller.js`
- Modify: `app/javascript/controllers/index.js` (regenerated)

**Interfaces:**
- Consumes: the `data-controller="books--filter-search"` element and the `query` / `option` targets already emitted by Tasks 2 and 3.
- Produces: registered controller identifier **`books--filter-search`**.

This is the **only** JavaScript in this feature. Opening and closing the dialog, staging selections, and submitting are all native browser behavior.

- [ ] **Step 1: Write the controller**

Create `app/javascript/controllers/books/filter_search_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--filter-search"
export default class extends Controller {
  static targets = ["query", "option"]

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()

    this.optionTargets.forEach((option) => {
      const label = option.dataset.filterLabel || ""
      option.classList.toggle("hidden", query !== "" && !label.includes(query))
    })
  }
}
```

- [ ] **Step 2: Regenerate the Stimulus manifest**

Run: `bin/rails stimulus:manifest:update`
Then confirm the registration landed:

```bash
grep -n "books--filter-search" app/javascript/controllers/index.js
```
Expected: one `application.register("books--filter-search", ...)` line. If the generator produced a different identifier, **use whatever it produced** and update the `data-controller` attribute in `filter_modal_component.html.erb` and the two `data-books--filter-search-target` attributes in `filter_facets_component.html.erb` to match — report the mismatch.

- [ ] **Step 3: Build the JS bundle and confirm it compiles**

Run: `yarn build`
Expected: completes with no errors. This is the check that the new file parses and is reachable from the `application` entrypoint that the books layout loads.

- [ ] **Step 4: Run the suite and commit**

```bash
bin/rails test
bundle exec standardrb
git add app/javascript/controllers/books/filter_search_controller.js app/javascript/controllers/index.js
git commit -m "Add the books genre filter search controller

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

There is no Ruby test for this file; Task 5's E2E is what exercises it in a browser.

---

### Task 5: Playwright E2E

**Files:**
- Create: `e2e/tests/books/filters.spec.ts`

**Interfaces:**
- Consumes: everything above. Drives the real browser against a running dev server.

**Before you start:** E2E needs a local server. Per project notes, `bin/dev` self-terminates in a non-TTY agent shell — use `yarn build:all` then `bin/rails server` instead, and **check what is actually listening on port 3000** before trusting a run. E2E also needs `e2e/.env`.

- [ ] **Step 1: Write the spec**

Create `e2e/tests/books/filters.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books filters', () => {
  test('the filter modal opens and lists genres', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('button', { name: 'Filters' }).click();

    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Filters' })).toBeVisible();
    await expect(page.locator('input[name="category_slugs[]"]').first()).toBeVisible();
  });

  test('applying a genre navigates to its canonical filter URL', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();

    await page.locator('input[name="category_slugs[]"]').first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(/\/the-greatest\/[^/]+\/books$/);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Novels/i);
  });

  test('a chip removes its filter and returns to the root', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await page.getByTestId('filter-chip').getByRole('link').click();

    await expect(page).toHaveURL(/\/$/);
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('genre search filters the visible options', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    const before = await page.locator('label[data-filter-label]:visible').count();
    await page.getByPlaceholder('Filter genres').fill('zzzzz-no-such-genre');
    const after = await page.locator('label[data-filter-label]:visible').count();

    expect(after).toBeLessThan(before);
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });
});
```

- [ ] **Step 2: Build assets and start a server**

```bash
yarn build:all
bin/rails server
```
Leave it running (background it), and verify port 3000 is actually serving this app before continuing.

- [ ] **Step 3: Run the spec**

Run: `yarn test:e2e e2e/tests/books/filters.spec.ts`
Expected: 6 passed.

If the "genre search" test finds no visible options to filter, the dev database's primary ranking configuration may have no ranked books with genres — check `Books::FilterFacetsQuery.call(ranking_configuration: Books::RankingConfiguration.default_primary).genres.size` in `bin/rails console` and report what you find rather than weakening the assertion.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/filters.spec.ts
git commit -m "Add Playwright coverage for the books filter modal

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## What this plan does NOT do

- **Deep genre search** across all ~14k genres — see deviation 1. The modal filters the top-36 facet list only.
- **Increment 5**, the admin inline `BookCountries` editor. Separate plan.
- The legacy `/women`, `/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`, `/condensed`, `/v/grid`, `/v/table` routes and CSV export. Still 404; each must be routed before books cutover or its indexed URLs break.
- Any sitemap work. Books is `noindex` site-wide until `BOOKS_PUBLIC_INDEXING=true`.
