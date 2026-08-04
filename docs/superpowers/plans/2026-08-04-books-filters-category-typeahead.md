# Books Filters — Category Typeahead Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the filter modal's search reach every category — subjects and locations as well as genres — and let you select them.

**Architecture:** A new `GET /filters/categories` endpoint runs legacy's exact search (`search_by_name`, ordered by `book_count` desc, limit 10, all active types) and returns an HTML fragment of checkbox rows. The Stimulus controller that already filters rendered options gains a debounced fetch that **appends** that fragment rather than reloading the Turbo Frame — so staged checkboxes survive. Selected subjects and locations become visible checked rows instead of hidden inputs, so they can be unchecked.

**Tech Stack:** Rails 8.1, ViewComponent, Stimulus, DaisyUI 5, Minitest, Playwright. Design spec: `docs/superpowers/specs/2026-08-03-books-filters-design.md`. Increments 1–4 are **merged to main at `01d52540`**.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Work in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-filters-typeahead` on branch **`worktree-books-filters-typeahead`** (never `main`). Baseline: **5569 runs, 0 failures**.
- The worktree shares the test database `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
- Namespace media code (`Books::`); tests mirror the namespace.
- **No code comments** unless a landmine genuinely needs recording.
- **Controller tests assert behavior** — status codes, params, no errors. Component tests may assert structural contracts (input `name`/`value`/`checked`, counts, `data-*` hooks) but never class names, layout, or copy.
- **Every new user-facing flow needs a Playwright E2E test** in `web-app/e2e/tests/`. `data-testid` is kebab-case.
- **THE DEVELOPMENT DATABASE IS NOT DISPOSABLE.** A `PreToolUse` hook hard-blocks destructive commands. Never run `db:drop`/`db:reset`/`db:schema:load` or `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES). **This plan needs no migration and no schema change.**
- E2E: `bin/dev` self-terminates in a non-TTY shell — use `yarn build:all` then background `bin/rails server`, and verify port 3000 is *this* worktree's server. Caddy proxies `dev-new.thegreatestbooks.org` → `localhost:3000`; the books routes are hostname-constrained, so `localhost:3000` directly will **not** match them.
- Lint with `bundle exec standardrb`, NOT `bin/rubocop`. Never run brakeman.
- **Gate before "done":** `bundle exec standardrb` clean and `bin/rails test` passing. Compare the **runs count** against the 5569 baseline.
- Every git commit message ends with: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

### Interfaces from increments 1–4 (merged, do not recreate)

- `Books::FiltersController` exists with `#show` (validates, 303s to the canonical path) and `#options` (renders the facet frame). Private `resolved_filters` maps `category_slugs[]` / `country_slugs[]` / `year_start` / `year_end` through `Books::FilterParams`. `before_action :prevent_caching` and `before_action :find_ranking_configuration` are already declared.
- Routes `books_filters_path` (`GET /filters`) and `books_filters_options_path` (`GET /filters/options`) exist and are named.
- `Books::FilterFacetsComponent` renders the GET form. Its private methods include `selected_genres`, `preserved_categories` (currently hidden inputs — **Task 2 replaces this**), `genre_options`, `country_options`, and `clear_path`. Options are `{record:, count:, checked:}` hashes.
- `Books::FilterFacetsQuery` `DEFAULT_LIMIT` is **500**, so all 166 genres and 179 countries with ranked books already render; the search box filters them client-side.
- `books--filter-search` Stimulus controller: targets `query` and `option`; `filter()` toggles `hidden` on each option by substring against `data-filter-label`.
- `Books::FilterParams` accepts any active category slug of any type and raises `RecordNotFound` otherwise. `Books::FilterTitle` renders genres inline, subjects as **"on X"**, locations as **"Set in X"**.
- `Category.search_by_name(name)` → `where("name ILIKE ?", "%" + sanitize_sql_like(name) + "%")`. `Books::Category` inherits it and STI-scopes it.

### Data shape (current dev database)

```
genres      196 total / 166 with ranked books   ← all rendered today
countries   253 total / 179 with ranked books   ← all rendered today
subjects    36,852                              ← typeahead only
locations   15,706                              ← typeahead only
```

---

## The trap this plan has to avoid

Increment 4 renders a selected **non-genre** category (a `location` or `subject` arriving from a book-page link) as a **hidden input**, so it survives an Apply round-trip. That was correct when the modal had no way to display it.

The moment subjects and locations become *selectable*, that same mechanism becomes a trap: you pick "Politics", apply, reopen the modal — and it is invisible, so you cannot uncheck it. The only way out would be the chip row.

**Task 2 therefore replaces the hidden inputs with visible checked rows in their own sections.** Do not skip it or reorder it after Task 3; the typeahead is not safe to ship without it.

---

## File Structure

- `config/routes.rb` — **modify.** One named route: `books_filters_categories`.
- `app/controllers/books/filters_controller.rb` — **modify.** Add `#categories`.
- `app/lib/books/category_search_query.rb` — **new.** Legacy's search, isolated and testable. One responsibility: query string → matching categories.
- `app/components/books/filter_category_options_component.rb` + `.html.erb` — **new.** Renders checkbox rows grouped by category type. Used by both the typeahead response and (for the selected-subject/location sections) the facets form.
- `app/components/books/filter_facets_component.rb` + `.html.erb` — **modify.** Visible sections for selected subjects/locations; a results container for typeahead output.
- `app/javascript/controllers/books/filter_search_controller.js` — **modify.** Add the debounced fetch and injection.
- `e2e/tests/books/filters.spec.ts` — **modify.** Typeahead specs.
- Tests mirroring each Ruby file under `test/`.

**Task order:** Task 1 (`CategorySearchQuery`) → Task 2 (visible selected subject/location rows) → Task 3 (endpoint + options component) → Task 4 (Stimulus fetch) → Task 5 (E2E).

---

### Task 1: `Books::CategorySearchQuery`

**Files:**
- Create: `app/lib/books/category_search_query.rb`
- Test: `test/lib/books/category_search_query_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::CategorySearchQuery.call(query, limit: 10)` → an Array of `Books::Category`, all active, name-matching, ordered by `item_count` descending then name. Returns `[]` for a blank query. Later tasks call this from the controller.

Legacy's `CategoriesController#search` is the reference: `Category.active.search_by_name(query).order(book_count: :desc)`, optionally type-filtered, `.sorted_by_name.limit(10)`. The new app's equivalent count column is `item_count`, not `book_count`. Legacy's trailing `.sorted_by_name` re-sorts the *whole* relation before limiting, which discards the popularity ordering — that is a legacy bug, not a behaviour to port. Order by `item_count desc, name asc`, take the limit, and leave it in that order so the most-used categories surface first.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/category_search_query_test.rb`:

```ruby
require "test_helper"

module Books
  class CategorySearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::CategorySearchQuery.call("")
      assert_empty Books::CategorySearchQuery.call(nil)
      assert_empty Books::CategorySearchQuery.call("   ")
    end

    test "matches on a name substring, case-insensitively" do
      results = Books::CategorySearchQuery.call("fict")

      assert_includes results, categories(:books_fiction_genre)
    end

    test "matches regardless of case" do
      assert_includes Books::CategorySearchQuery.call("FICT"), categories(:books_fiction_genre)
    end

    test "returns categories of every type, not just genres" do
      types = Books::CategorySearchQuery.call("o", limit: 100).map { |c| c.category_type.to_s }.uniq

      assert_includes types, "genre"
      assert_includes types, "subject"
      assert_includes types, "location"
    end

    test "excludes soft-deleted categories" do
      assert_not_includes Books::CategorySearchQuery.call("retired"), categories(:books_deleted_genre)
    end

    test "excludes other domains' categories" do
      results = Books::CategorySearchQuery.call("rock", limit: 100)

      assert_empty results.select { |c| c.type != "Books::Category" }
    end

    test "orders by item_count descending" do
      counts = Books::CategorySearchQuery.call("o", limit: 100).map(&:item_count)

      assert_equal counts.sort.reverse, counts
    end

    test "respects the limit" do
      assert_operator Books::CategorySearchQuery.call("o", limit: 2).size, :<=, 2
    end

    test "escapes SQL LIKE wildcards so they match literally" do
      assert_empty Books::CategorySearchQuery.call("%")
    end
  end
end
```

The "every type" test relies on the books fixtures added in increment 2: `books_fiction_genre` (Fiction), `books_novels_genre` (Novels), `books_classics_genre` (Classics), `books_politics_subject` (Politics), `books_france_location` (France), `books_deleted_genre` (Retired Genre, `deleted: true`). All six contain the letter "o" except Classics — Fiction, Novels, Politics, and France cover genre, subject, and location.

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/books/category_search_query_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::CategorySearchQuery`.

- [ ] **Step 3: Write the implementation**

Create `app/lib/books/category_search_query.rb`:

```ruby
module Books
  class CategorySearchQuery
    DEFAULT_LIMIT = 10

    def self.call(query, limit: DEFAULT_LIMIT)
      term = query.to_s.strip
      return [] if term.empty?

      Books::Category
        .active
        .search_by_name(term)
        .order(item_count: :desc, name: :asc)
        .limit(limit)
        .to_a
    end
  end
end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/lib/books/category_search_query_test.rb`
Expected: PASS, 9 runs, 0 failures.

- [ ] **Step 5: Sanity-check against real data**

```bash
bin/rails runner 'Books::CategorySearchQuery.call("polit").each { |c| puts "#{c.name.ljust(28)} #{c.category_type.ljust(9)} #{c.item_count}" }'
```
Expected: a mix of types, most-used first. Report what you see — if it returns only one type, the `active` scope or the STI scoping is wrong.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/books/category_search_query.rb test/lib/books/category_search_query_test.rb
bundle exec standardrb
bin/rails test
git add app/lib/books/category_search_query.rb test/lib/books/category_search_query_test.rb
git commit -m "Add Books::CategorySearchQuery

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Show selected subjects and locations as removable rows

**Files:**
- Modify: `app/components/books/filter_facets_component.rb`
- Modify: `app/components/books/filter_facets_component.html.erb`
- Test: `test/components/books/filter_facets_component_test.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: selected `subject` and `location` categories render as **visible checked checkboxes** named `category_slugs[]`, in their own sections, instead of hidden inputs. Task 4's typeahead relies on those sections existing as injection points.

**Read "The trap this plan has to avoid" above before starting.** This task exists so a selected subject can be unchecked once Task 4 makes subjects selectable.

- [ ] **Step 1: Write the failing tests**

In `test/components/books/filter_facets_component_test.rb`, **replace** the existing test named `"preserves a selected non-genre category as a hidden field"` with:

```ruby
    test "a selected location renders as a visible checked checkbox so it can be unchecked" do
      render_component(categories: [categories(:books_france_location)])

      assert_selector "input[type=checkbox][name='category_slugs[]'][value=france][checked]"
      assert_no_selector "input[type=hidden][name='category_slugs[]'][value=france]", visible: :all
    end

    test "a selected subject renders as a visible checked checkbox" do
      render_component(categories: [categories(:books_politics_subject)])

      assert_selector "input[type=checkbox][name='category_slugs[]'][value=politics][checked]"
    end

    test "the subject and location sections are absent when none are selected" do
      render_component

      assert_no_selector "[data-testid=selected-subjects]"
      assert_no_selector "[data-testid=selected-locations]"
    end

    test "a selected location does not leak into the genre list" do
      render_component(categories: [categories(:books_france_location)])

      assert_selector "[data-testid=selected-locations] input[value=france]"
      assert_no_selector "[data-testid=genre-options] input[value=france]"
    end

    test "renders a container for typeahead results" do
      render_component

      assert_selector "[data-books--filter-search-target='results']"
    end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/components/books/filter_facets_component_test.rb`
Expected: FAIL — the location still renders hidden, and neither the testid containers nor the `results` target exist.

- [ ] **Step 3: Replace `preserved_categories` with typed selections**

In `app/components/books/filter_facets_component.rb`, remove the `preserved_categories` method **and the comment above it**, and add:

```ruby
    def selected_subjects
      categories.select { |category| category.category_type.to_s == "subject" }
    end

    def selected_locations
      categories.select { |category| category.category_type.to_s == "location" }
    end
```

- [ ] **Step 4: Update the template**

In `app/components/books/filter_facets_component.html.erb`:

Delete the `preserved_categories` hidden-input loop entirely.

Add `data-testid="genre-options"` to the existing genre list container `<div>`, so the "does not leak" test can target it.

Then, after the Countries section and before the year section, add:

```erb
    <% if selected_subjects.any? %>
      <section data-testid="selected-subjects">
        <h4 class="font-semibold text-sm uppercase tracking-wide text-base-content/70 mb-2">Subjects</h4>
        <div class="flex flex-col gap-1">
          <% selected_subjects.each do |category| %>
            <label class="label cursor-pointer justify-start gap-2"
                   data-books--filter-search-target="option"
                   data-filter-label="<%= category.name.downcase %>">
              <%= check_box_tag "category_slugs[]", category.slug, true, id: nil, class: "checkbox checkbox-sm" %>
              <span class="label-text"><%= category.name %></span>
            </label>
          <% end %>
        </div>
      </section>
    <% end %>

    <% if selected_locations.any? %>
      <section data-testid="selected-locations">
        <h4 class="font-semibold text-sm uppercase tracking-wide text-base-content/70 mb-2">Locations</h4>
        <div class="flex flex-col gap-1">
          <% selected_locations.each do |category| %>
            <label class="label cursor-pointer justify-start gap-2"
                   data-books--filter-search-target="option"
                   data-filter-label="<%= category.name.downcase %>">
              <%= check_box_tag "category_slugs[]", category.slug, true, id: nil, class: "checkbox checkbox-sm" %>
              <span class="label-text"><%= category.name %></span>
            </label>
          <% end %>
        </div>
      </section>
    <% end %>

    <section data-books--filter-search-target="results" class="hidden"></section>
```

The results section is where Task 4 injects typeahead output. It ships empty and hidden.

- [ ] **Step 5: Run to verify they pass**

Run: `bin/rails test test/components/books/filter_facets_component_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Verify the round-trip still works end to end**

Run: `bin/rails test test/controllers/books/`
Expected: PASS. A location selected in the URL must still survive an Apply — it is now a checked checkbox rather than a hidden field, which submits identically.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/books test/components/books
bundle exec standardrb
bin/rails test
git add app/components/books test/components/books
git commit -m "Show selected subjects and locations as removable rows

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The typeahead endpoint

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/books/filters_controller.rb`
- Create: `app/components/books/filter_category_options_component.rb` + `.html.erb`
- Create: `app/views/books/filters/categories.html.erb`
- Test: `test/components/books/filter_category_options_component_test.rb`
- Test: extend `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Consumes: `Books::CategorySearchQuery` from Task 1.
- Produces: `books_filters_categories_path` → `GET /filters/categories?q=…`, returning an HTML fragment of checkbox rows grouped by category type. Task 4 fetches this and injects the response into the `results` target.

- [ ] **Step 1: Add the route**

In `config/routes.rb`, immediately after the existing `books_filters_options` route:

```ruby
    get "filters/categories", to: "books/filters#categories", as: :books_filters_categories
```

Run `bin/rails routes | grep "books/filters#"` and confirm three rows now.

- [ ] **Step 2: Write the failing component test**

Create `test/components/books/filter_category_options_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterCategoryOptionsComponentTest < ViewComponent::TestCase
    def render_options(categories, selected: [])
      render_inline(Books::FilterCategoryOptionsComponent.new(categories: categories, selected_slugs: selected))
    end

    test "renders a checkbox per category" do
      render_options([categories(:books_politics_subject)])

      assert_selector "input[type=checkbox][name='category_slugs[]'][value=politics]"
    end

    test "groups by category type with a heading per group" do
      render_options([categories(:books_politics_subject), categories(:books_france_location)])

      assert_selector "[data-testid=typeahead-group='subject']"
      assert_selector "[data-testid=typeahead-group='location']"
    end

    test "marks an already-selected category as checked" do
      render_options([categories(:books_politics_subject)], selected: ["politics"])

      assert_selector "input[value=politics][checked]"
    end

    test "leaves an unselected category unchecked" do
      render_options([categories(:books_politics_subject)])

      assert_no_selector "input[value=politics][checked]"
    end

    test "renders nothing for an empty result set" do
      render_options([])

      assert_no_selector "input[name='category_slugs[]']"
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/components/books/filter_category_options_component_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::FilterCategoryOptionsComponent`.

- [ ] **Step 4: Write the component**

Create `app/components/books/filter_category_options_component.rb`:

```ruby
module Books
  class FilterCategoryOptionsComponent < ViewComponent::Base
    GROUP_LABELS = {"genre" => "Genres", "subject" => "Subjects", "location" => "Locations"}.freeze

    def initialize(categories:, selected_slugs: [])
      @categories = categories || []
      @selected_slugs = Array(selected_slugs)
    end

    private

    attr_reader :categories, :selected_slugs

    def groups
      categories
        .group_by { |category| category.category_type.to_s }
        .sort_by { |type, _| GROUP_LABELS.keys.index(type) || GROUP_LABELS.size }
    end

    def label_for(type)
      GROUP_LABELS.fetch(type, type.titleize)
    end

    def checked?(category)
      selected_slugs.include?(category.slug)
    end
  end
end
```

Create `app/components/books/filter_category_options_component.html.erb`:

```erb
<% groups.each do |type, rows| %>
  <div data-testid="typeahead-group=<%= type %>" class="mt-2">
    <h4 class="font-semibold text-sm uppercase tracking-wide text-base-content/70 mb-2"><%= label_for(type) %></h4>
    <div class="flex flex-col gap-1">
      <% rows.each do |category| %>
        <label class="label cursor-pointer justify-start gap-2">
          <%= check_box_tag "category_slugs[]", category.slug, checked?(category), id: nil, class: "checkbox checkbox-sm" %>
          <span class="label-text"><%= category.name %></span>
          <span class="label-text text-base-content/60">(<%= number_with_delimiter(category.item_count) %>)</span>
        </label>
      <% end %>
    </div>
  </div>
<% end %>
```

These rows carry **no** `data-books--filter-search-target="option"`. Injected results must not be hidden by the client-side substring filter — they are already the search result.

- [ ] **Step 5: Run the component test**

Run: `bin/rails test test/components/books/filter_category_options_component_test.rb`
Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 6: Add the controller action and view**

In `app/controllers/books/filters_controller.rb`, add above `private`:

```ruby
  def categories
    @categories = Books::CategorySearchQuery.call(params[:q])
    @selected_slugs = Array(params[:category_slugs])

    render layout: false
  end
```

Create `app/views/books/filters/categories.html.erb`:

```erb
<%= render Books::FilterCategoryOptionsComponent.new(categories: @categories, selected_slugs: @selected_slugs) %>
```

`layout: false` matters: the controller declares `layout "books/application"`, which would otherwise wrap this fragment in the whole page chrome.

- [ ] **Step 7: Add controller tests**

Append inside `module Books; class FiltersControllerTest`:

```ruby
    test "categories returns matching options across types" do
      get "/filters/categories", params: {q: "o"}

      assert_response :success
      assert_select "input[name='category_slugs[]']"
    end

    test "categories renders no page chrome" do
      get "/filters/categories", params: {q: "fict"}

      assert_response :success
      assert_select "nav", false
      assert_select "html", false
    end

    test "categories returns an empty body for a blank query" do
      get "/filters/categories", params: {q: ""}

      assert_response :success
      assert_select "input[name='category_slugs[]']", false
    end

    test "categories marks already-selected slugs as checked" do
      get "/filters/categories", params: {q: "fict", category_slugs: ["fiction"]}

      assert_response :success
      assert_select "input[value=fiction][checked]"
    end

    test "categories is not cacheable" do
      get "/filters/categories", params: {q: "fict"}

      assert_match "no-store", response.headers["Cache-Control"].to_s
    end
```

- [ ] **Step 8: Run the controller tests and commit**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: PASS, 0 failures.

```bash
bundle exec standardrb --fix app/controllers/books app/components/books test/components/books test/controllers/books config/routes.rb
bundle exec standardrb
bin/rails test
git add config/routes.rb app/controllers/books app/components/books app/views/books/filters test/components/books test/controllers/books
git commit -m "Add the books category typeahead endpoint

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Wire the typeahead into the Stimulus controller

**Files:**
- Modify: `app/javascript/controllers/books/filter_search_controller.js`
- Modify: `app/components/books/filter_facets_component.html.erb` (one attribute)

**Interfaces:**
- Consumes: `books_filters_categories_path` from Task 3; the `results` target from Task 2.
- Produces: typing in the search box both filters rendered options (unchanged) and appends matching subjects/locations/genres fetched from the endpoint.

- [ ] **Step 1: Pass the endpoint URL to the controller**

In `app/components/books/filter_facets_component.html.erb`, add a value attribute to the search input's container. The controller element is the `modal-box` in `filter_modal_component.html.erb`, so the value must go there instead — in `app/components/books/filter_modal_component.html.erb`, change the `modal-box` div to:

```erb
  <div class="modal-box max-w-xl"
       data-controller="books--filter-search"
       data-books--filter-search-url-value="<%= helpers.books_filters_categories_path %>">
```

- [ ] **Step 2: Extend the controller**

Replace `app/javascript/controllers/books/filter_search_controller.js` with:

```javascript
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--filter-search"
export default class extends Controller {
  static targets = ["query", "option", "results"]
  static values = { url: String, minLength: { type: Number, default: 2 }, debounce: { type: Number, default: 250 } }

  connect() {
    this.timer = null
    this.controllerAbort = null
  }

  disconnect() {
    clearTimeout(this.timer)
    this.controllerAbort?.abort()
  }

  filter() {
    const query = this.queryTarget.value.trim().toLowerCase()

    this.optionTargets.forEach((option) => {
      const label = option.dataset.filterLabel || ""
      option.classList.toggle("hidden", query !== "" && !label.includes(query))
    })

    this.scheduleSearch(query)
  }

  scheduleSearch(query) {
    if (!this.hasResultsTarget || !this.hasUrlValue) return

    clearTimeout(this.timer)

    if (query.length < this.minLengthValue) {
      this.clearResults()
      return
    }

    this.timer = setTimeout(() => this.search(query), this.debounceValue)
  }

  async search(query) {
    this.controllerAbort?.abort()
    this.controllerAbort = new AbortController()

    const params = new URLSearchParams()
    params.set("q", query)
    this.checkedSlugs().forEach((slug) => params.append("category_slugs[]", slug))

    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { Accept: "text/html" },
        signal: this.controllerAbort.signal
      })
      if (!response.ok) return

      const html = await response.text()
      this.renderResults(html)
    } catch (error) {
      if (error.name !== "AbortError") this.clearResults()
    }
  }

  renderResults(html) {
    this.resultsTarget.innerHTML = html
    this.dedupe()
    const empty = this.resultsTarget.querySelectorAll("input[name='category_slugs[]']").length === 0
    this.resultsTarget.classList.toggle("hidden", empty)
  }

  clearResults() {
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.classList.add("hidden")
  }

  // A genre matching the query is already rendered in the always-visible list,
  // so drop the endpoint's copy rather than showing the same checkbox twice.
  dedupe() {
    const rendered = new Set(this.existingSlugs())

    this.resultsTarget.querySelectorAll("input[name='category_slugs[]']").forEach((input) => {
      if (rendered.has(input.value)) input.closest("label")?.remove()
    })

    this.resultsTarget.querySelectorAll("[data-testid^='typeahead-group']").forEach((group) => {
      if (group.querySelectorAll("input[name='category_slugs[]']").length === 0) group.remove()
    })
  }

  existingSlugs() {
    return Array.from(
      this.element.querySelectorAll("input[name='category_slugs[]']")
    )
      .filter((input) => !this.resultsTarget.contains(input))
      .map((input) => input.value)
  }

  checkedSlugs() {
    return Array.from(
      this.element.querySelectorAll("input[name='category_slugs[]']:checked")
    ).map((input) => input.value)
  }
}
```

`checkedSlugs()` is why staged selections survive: the fetch carries them, the endpoint renders them checked, and nothing outside the `results` container is ever replaced.

- [ ] **Step 3: Build and confirm it compiles**

```bash
yarn build:all
```
Expected: completes with no errors.

- [ ] **Step 4: Run the suite and commit**

```bash
bin/rails test
bundle exec standardrb
git add app/javascript/controllers/books/filter_search_controller.js app/components/books/filter_modal_component.html.erb
git commit -m "Fetch and inject category typeahead results

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

The Ruby suite should be unchanged from Task 3's count — this task adds no Ruby tests. Task 5 exercises it in a browser.

---

### Task 5: Playwright E2E

**Files:**
- Modify: `e2e/tests/books/filters.spec.ts`

**Before you start:** `yarn build:all`, then background `bin/rails server`, and verify port 3000 is *this* worktree's server (check `/proc/<pid>/cwd`). Reach it at `https://dev-new.thegreatestbooks.org` — the books routes are hostname-constrained and `localhost:3000` will not match them. Specs must be strictly read-only against the development database.

- [ ] **Step 1: Add the specs**

Append inside the `Books filters` describe block in `e2e/tests/books/filters.spec.ts`:

```typescript
  test('typing surfaces subjects and locations beyond the rendered genres', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    await page.getByPlaceholder('Filter genres and countries').fill('polit');

    await expect(page.locator("[data-testid^='typeahead-group']").first()).toBeVisible();
    await expect(page.locator("[data-testid=\"typeahead-group=subject\"]")).toBeVisible();
  });

  test('a subject selected from the typeahead applies and titles correctly', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();

    await page.getByPlaceholder('Filter genres and countries').fill('polit');
    const subject = page.locator("[data-testid=\"typeahead-group=subject\"] input[name='category_slugs[]']").first();
    await subject.waitFor();
    const slug = await subject.getAttribute('value');
    await subject.check();

    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL(`/the-greatest/${slug}/books`);
    await expect(page.getByRole('heading', { level: 1 })).toContainText(/ on /);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('a selected subject is visible and removable when the modal reopens', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.locator('input[name="category_slugs[]"]').first().waitFor();
    await page.getByPlaceholder('Filter genres and countries').fill('polit');
    const subject = page.locator("[data-testid=\"typeahead-group=subject\"] input[name='category_slugs[]']").first();
    await subject.waitFor();
    const slug = await subject.getAttribute('value');
    await subject.check();
    await page.getByRole('button', { name: 'Apply' }).click();
    await expect(page).toHaveURL(`/the-greatest/${slug}/books`);

    await page.getByRole('button', { name: 'Filters' }).click();
    const reopened = page.locator(`[data-testid=selected-subjects] input[value="${slug}"]`);
    await reopened.waitFor();
    await expect(reopened).toBeChecked();

    await reopened.uncheck();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/');
  });

  test('staged genre selections survive a typeahead fetch', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();

    const genre = page.locator("[data-testid=genre-options] input[name='category_slugs[]']").first();
    await genre.waitFor();
    await genre.check();

    await page.getByPlaceholder('Filter genres and countries').fill('polit');
    await expect(page.locator("[data-testid^='typeahead-group']").first()).toBeVisible();

    await expect(genre).toBeChecked();
  });
```

That last spec is the one that matters most — it pins the reason this design fetches-and-appends instead of reloading the frame.

- [ ] **Step 2: Run the suite**

Run: `yarn test:e2e e2e/tests/books/filters.spec.ts`
Expected: all specs pass (9 existing + 4 new).

If the typeahead group for `subject` never appears, check `Books::CategorySearchQuery.call("polit")` in `bin/rails console` and report what types come back rather than weakening the assertion.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/books/filters.spec.ts
git commit -m "Add Playwright coverage for the category typeahead

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## What this plan does NOT do

- **Country typeahead.** All 179 countries with ranked books already render, so there is nothing to search for.
- **The admin inline `BookCountries` editor** — still its own increment.
- The legacy `/women`, `/western`, `/asia`, `/africa`, `/latin-america`, `/non-western`, `/condensed`, `/v/grid`, `/v/table` routes and CSV export. Still 404; each must be routed before books cutover or its indexed URLs break.

## Landmines

- **`layout: false` on `#categories`.** The controller declares `layout "books/application"`; without the override the fragment arrives wrapped in the entire page.
- **Injected rows must not carry `data-books--filter-search-target="option"`**, or the client-side substring filter will hide the very results the search just fetched.
- **Never replace anything outside the `results` container.** Staged checkboxes live in the genre and country lists; overwriting them is the bug this whole design exists to avoid.
- **Selected subjects/locations must be visible checkboxes, not hidden inputs** (Task 2) — otherwise a filter the user can now select becomes one they cannot remove.
