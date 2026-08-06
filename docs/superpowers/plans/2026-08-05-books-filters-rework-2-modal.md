# Books Filters Rework — Increment 2: The Drill-Down Modal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat 345-row filter modal with a two-level drill-down — three axis rows at level 1, one axis per pane, each pane with its own server-backed search.

**Architecture:** One `<dialog>` containing one GET form. Level 1 and the three panes are all in the DOM at once and toggled by CSS, so staged checkboxes survive navigation. Each pane's body is a `<turbo-frame>` whose `src` Stimulus assigns on first visit only. Search replaces a *nested* results frame; checking a search result hoists that row out of the ephemeral frame into a persistent container. Apply is still a plain form submit to `/filters`, so `Books::FilterPath` remains the only place the URL grammar exists.

**Tech Stack:** Rails 8.1, ViewComponent, Turbo Frames, Stimulus, DaisyUI 5 / Tailwind 4, Minitest, Playwright. Design spec: `docs/superpowers/specs/2026-08-05-books-filters-rework-design.md` §4, §5, §6, §8. Increment 1 is merged on this branch.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Work in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-filters-typeahead` on branch **`worktree-books-filters-typeahead`**. Never `main`. Do not `cd` to the original repo root.
- Baseline entering this increment: **5599 runs, 0 failures**.
- The worktree shares the test database `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
- Namespace media code under `Books::`; tests mirror the namespace.
- **Use Rails generators** for new components: `bin/rails generate component Books::Foo`. Never hand-create.
- **No code comments** unless recording a genuine landmine.
- **Component tests may assert structural contracts** — input `name`/`value`/`checked`, row counts, `data-*` hooks, turbo-frame ids. They must **never** assert class names, layout, or copy. Controller tests assert behavior only.
- **THE DEVELOPMENT DATABASE IS NOT DISPOSABLE.** Never run `db:drop`/`db:reset`/`db:schema:load`, and never `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES). **This increment needs no migration and no schema change.**
- Lint with `bundle exec standardrb`, **not** `bin/rubocop`. Never run brakeman.
- After adding or deleting a Stimulus controller, run `bin/rails stimulus:manifest:update` — `app/javascript/controllers/index.js` is generated, never hand-edited.
- **Gate before "done":** `bundle exec standardrb` clean and `bin/rails test` passing, compared by **runs count**.
- Every git commit message ends with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## Interfaces from increment 1 (merged — do not recreate)

```ruby
Books::FilterFacetsQuery.genres(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, limit: DEFAULT_LIMIT)
Books::FilterFacetsQuery.countries(...)          # => [{record:, count:}]
Books::FilterFacetsQuery::DEFAULT_LIMIT          # => 24
Books::CategorySearchQuery.call(query, limit: 10) # => [Books::Category], all 3 types, item_count desc
Books::CountrySearchQuery.call(query, limit: 10)  # => [Books::Country], unknown excluded
Books::FilterParams::MAX_CATEGORIES               # => 6
Books::FilterParams::MAX_COUNTRIES                # => 10
Books::FilterPath.call(categories:, countries:, year_start:, year_end:, ranking_configuration:)
Books::FilterBarComponent::MODAL_ID               # => "books_filter_modal"
```

`Books::Category#category_type` is an enum: `genre` / `location` / `subject` (plus unused music/games values).

---

## THE DOM CONTRACT

Every task below builds part of one HTML structure driven by one Stimulus controller. **This section is the contract between them.** A component that emits a different attribute name than the controller reads produces a modal that silently does nothing — no error, no failing unit test. Copy these names exactly.

```html
<dialog id="books_filter_modal" class="modal modal-bottom sm:modal-middle">
  <div class="modal-box"
       data-controller="books--filter"
       data-books--filter-max-categories-value="6"
       data-books--filter-max-countries-value="10">

    <form method="get" action="/filters" data-turbo-frame="_top">
      <!-- optional: <input type="hidden" name="ranking_configuration_id"> -->

      <!-- ===== LEVEL 1 ===== -->
      <div data-books--filter-target="level" data-level="root">
        <button type="button" data-action="books--filter#open" data-level-target="category">
          Category
          <span data-books--filter-target="summary" data-axis="category">Novels, Politics</span>
        </button>
        <!-- same for data-level-target="country" (label "Origin")
             and data-level-target="year" (label "Published") -->
      </div>

      <!-- ===== PANE: category ===== -->
      <div data-books--filter-target="level" data-level="category" class="hidden">
        <button type="button" data-action="books--filter#back">‹ Category</button>

        <input type="search"
               data-books--filter-target="query"
               data-axis="category"
               data-action="input->books--filter#search">

        <turbo-frame id="books_filter_pane_category"
                     data-books--filter-target="pane"
                     data-axis="category"
                     data-pane-src="/filters/categories?...">
          <!-- filled on first open by Task 3's action, rendering Task 2's component: -->
          <turbo-frame id="books_filter_results_category"
                       data-books--filter-target="results"
                       data-axis="category"
                       data-results-src="/filters/categories?..."></turbo-frame>
          <div data-books--filter-target="selected" data-axis="category">
            <!-- currently-applied rows, checked; hoist destination -->
          </div>
          <div data-books--filter-target="browse" data-axis="category">
            <!-- facet rows, unchecked -->
          </div>
          <p data-books--filter-target="capNotice" data-axis="category" class="hidden"></p>
        </turbo-frame>
      </div>

      <!-- ===== PANE: country ===== identical, data-axis="country",
           frames books_filter_pane_country / books_filter_results_country -->

      <!-- ===== PANE: year ===== plain inputs, no frame, no fetch -->
      <div data-books--filter-target="level" data-level="year" class="hidden">
        <button type="button" data-action="books--filter#back">‹ Published</button>
        <input type="number" name="year_start" data-books--filter-target="year" data-axis="year">
        <input type="number" name="year_end"   data-books--filter-target="year" data-axis="year">
      </div>

      <div class="modal-action">
        <a href="<clear path>" data-turbo-frame="_top">Clear</a>
        <button type="button" data-action="books--filter#cancel">Cancel</button>
        <input type="submit" value="Apply">
      </div>
    </form>
  </div>
  <form method="dialog" class="modal-backdrop"><button aria-label="Close">close</button></form>
</dialog>
```

**Checkbox rows** — one shape everywhere (browse list, selected list, search results):

```html
<label class="label cursor-pointer justify-start gap-2" data-option-value="novels">
  <input type="checkbox" name="category_slugs[]" value="novels" class="checkbox checkbox-sm"
         data-action="change->books--filter#toggle" data-axis="category">
  <span class="label-text">Novels</span>
  <span class="badge badge-ghost badge-sm">Subject</span>   <!-- non-genre categories only -->
  <span class="label-text text-base-content/60">(12,043)</span>  <!-- browse rows only -->
</label>
```

Rules that fall out of this and are asserted by tests:

1. Checkbox `name` stays `category_slugs[]` / `country_slugs[]` so `FilterParams` and `FilterPath` are untouched.
2. `data-option-value` mirrors the input's `value` and is how the controller finds duplicates across containers.
3. **Search-result rows carry no count** (spec §6): facet counts are ranking-configuration-scoped, `item_count` is global, and they diverge badly — Fiction reads 15,875 as a facet and 65,073 as `item_count`.
4. The type badge appears only when `category_type != "genre"`, labelled **`Setting`** for `location` and **`Subject`** for `subject`.

## File Structure

| File | Responsibility |
|---|---|
| `app/components/books/filter_option_rows_component.rb` + `.html.erb` *(new)* | renders a list of checkbox rows; the single definition of a row |
| `app/components/books/filter_pane_component.rb` + `.html.erb` *(new)* | one axis pane: results frame + selected + browse + cap notice |
| `app/components/books/filter_modal_component.rb` + `.html.erb` *(rewrite)* | dialog shell, the form, level 1, three panes, actions |
| `app/javascript/controllers/books/filter_controller.js` *(new)* | pane nav, first-visit src, debounced search, hoist, summary, caps |
| `app/controllers/books/filters_controller.rb` *(modify)* | `#categories` / `#countries`; `#options` deleted in Task 6 |
| `config/routes.rb` *(modify)* | two named routes added; `filters/options` deleted in Task 6 |
| `app/views/books/ranked_items/index.html.erb` *(modify)* | unchanged call sites; verified in Task 5 |
| **Deleted in Task 6** | `filter_facets_component.{rb,html.erb}`, `views/books/filters/options.html.erb`, `controllers/books/filter_search_controller.js`, `test/components/books/filter_facets_component_test.rb` |
| `e2e/tests/books/filters.spec.ts` *(rewrite, Task 7)* | |

**Task order:** 1 rows → 2 pane → 3 routes+actions → 4 Stimulus → 5 modal rewrite + switchover → 6 delete dead code → 7 E2E + gate.

Tasks 1–4 are purely additive; the live modal keeps working. Task 5 is the switchover. Task 6 removes what Task 5 orphaned. Every task ends green.

---

### Task 1: `Books::FilterOptionRowsComponent`

**Files:**
- Create: `app/components/books/filter_option_rows_component.rb` + `.html.erb` (via generator)
- Test: `test/components/books/filter_option_rows_component_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```ruby
  Books::FilterOptionRowsComponent.new(
    axis: :category | :country,   # drives the input name and data-axis
    rows: [...],                  # Array of {record:, count:} OR bare records
    checked: false,               # render every row checked
    show_counts: true             # false for search results (spec §6)
  )
  ```
  Tasks 2 and 3 both render this.

The badge rule: for `axis: :category`, a record whose `category_type` is not `"genre"` gets a badge — `location` → `Setting`, `subject` → `Subject`. Genres and all countries get no badge.

- [ ] **Step 1: Generate the component**

Run: `bin/rails generate component Books::FilterOptionRows`
This creates the `.rb`, the `.html.erb`, and the test file.

- [ ] **Step 2: Write the failing test**

Replace `test/components/books/filter_option_rows_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterOptionRowsComponentTest < ViewComponent::TestCase
    def render_rows(**options)
      render_inline(Books::FilterOptionRowsComponent.new(**options))
    end

    test "renders one checkbox per row with the category input name" do
      render_rows(axis: :category, rows: [
        {record: categories(:books_novels_genre), count: 12},
        {record: categories(:books_fiction_genre), count: 9}
      ])

      assert_selector "input[name='category_slugs[]']", count: 2
      assert_selector "input[value='novels']"
      assert_selector "input[value='fiction']"
    end

    test "uses the country input name for the country axis" do
      render_rows(axis: :country, rows: [{record: books_countries(:french), count: 2}])

      assert_selector "input[name='country_slugs[]'][value='french']"
    end

    test "accepts bare records as well as count hashes" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])

      assert_selector "input[value='novels']"
    end

    test "rows are unchecked by default and checked on request" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])
      assert_no_selector "input[checked]"

      render_rows(axis: :category, rows: [categories(:books_novels_genre)], checked: true)
      assert_selector "input[checked]"
    end

    test "carries the data hooks the Stimulus controller reads" do
      render_rows(axis: :category, rows: [categories(:books_novels_genre)])

      assert_selector "label[data-option-value='novels']"
      assert_selector "input[data-axis='category'][data-action='change->books--filter#toggle']"
    end

    test "shows counts by default and omits them on request" do
      render_rows(axis: :category, rows: [{record: categories(:books_novels_genre), count: 1234}])
      assert_text "1,234"

      render_rows(axis: :category, rows: [{record: categories(:books_novels_genre), count: 1234}], show_counts: false)
      assert_no_text "1,234"
    end

    test "badges a subject and a location but never a genre" do
      render_rows(axis: :category, rows: [
        categories(:books_politics_subject),
        categories(:books_france_location),
        categories(:books_novels_genre)
      ])

      assert_selector "label[data-option-value='politics']", text: "Subject"
      assert_selector "label[data-option-value='france']", text: "Setting"
      assert_no_selector "label[data-option-value='novels'] .badge"
    end

    test "never badges a country" do
      render_rows(axis: :country, rows: [books_countries(:french)])

      assert_no_selector ".badge"
    end

    test "renders nothing for an empty row set" do
      render_rows(axis: :category, rows: [])

      assert_no_selector "input"
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/components/books/filter_option_rows_component_test.rb`
Expected: FAIL — the generated component renders a placeholder, so the selectors find nothing.

- [ ] **Step 4: Write the implementation**

`app/components/books/filter_option_rows_component.rb`:

```ruby
module Books
  class FilterOptionRowsComponent < ViewComponent::Base
    BADGES = {"location" => "Setting", "subject" => "Subject"}.freeze

    def initialize(axis:, rows:, checked: false, show_counts: true)
      @axis = axis.to_s
      @rows = Array(rows)
      @checked = checked
      @show_counts = show_counts
    end

    private

    attr_reader :axis, :rows, :checked, :show_counts

    def input_name
      "#{axis}_slugs[]"
    end

    def normalized_rows
      rows.map do |row|
        row.is_a?(Hash) ? row : {record: row, count: nil}
      end
    end

    def badge_for(record)
      return nil unless axis == "category"

      BADGES[record.category_type.to_s]
    end

    def count_for(row)
      return nil unless show_counts

      row[:count]
    end
  end
end
```

`app/components/books/filter_option_rows_component.html.erb`:

```erb
<% normalized_rows.each do |row| %>
  <% record = row[:record] %>
  <label class="label cursor-pointer justify-start gap-2" data-option-value="<%= record.slug %>">
    <%= check_box_tag input_name, record.slug, checked, id: nil, class: "checkbox checkbox-sm",
          data: {axis: axis, action: "change->books--filter#toggle"} %>
    <span class="label-text"><%= record.name %></span>
    <% if (badge = badge_for(record)) %>
      <span class="badge badge-ghost badge-sm"><%= badge %></span>
    <% end %>
    <% if (count = count_for(row)) %>
      <span class="label-text text-base-content/60">(<%= number_with_delimiter(count) %>)</span>
    <% end %>
  </label>
<% end %>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/components/books/filter_option_rows_component_test.rb`
Expected: `9 runs, 0 failures`

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/components/books/filter_option_rows_component.rb test/components/books/filter_option_rows_component_test.rb
git add app/components/books/filter_option_rows_component.rb app/components/books/filter_option_rows_component.html.erb test/components/books/filter_option_rows_component_test.rb
git commit -m "$(cat <<'EOF'
Add Books::FilterOptionRowsComponent

One definition of a filter checkbox row, shared by the pane's browse list,
its selected list, and its search results — so the Stimulus controller has
exactly one shape to move between containers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Books::FilterPaneComponent`

**Files:**
- Create: `app/components/books/filter_pane_component.rb` + `.html.erb` (via generator)
- Test: `test/components/books/filter_pane_component_test.rb`

**Interfaces:**
- Consumes: `Books::FilterOptionRowsComponent` (Task 1).
- Produces:
  ```ruby
  Books::FilterPaneComponent.new(
    axis: :category | :country,
    facet_rows: [{record:, count:}],  # from FilterFacetsQuery.genres/.countries
    selected: [records],              # currently-applied records on this axis
    results_src: "/filters/categories?..."   # base URL; JS appends &q=
  )
  ```
  Task 3's controller action renders this. Task 5's modal does **not** — the modal emits only the empty outer frame.

Renders, in this order inside `<turbo-frame id="books_filter_pane_<axis>">`:
1. an empty nested `<turbo-frame id="books_filter_results_<axis>">` carrying `data-results-src`
2. a `selected` container holding `selected` rendered **checked**
3. a `browse` container holding `facet_rows` rendered **unchecked, with counts**
4. an empty, hidden `capNotice` paragraph

- [ ] **Step 1: Generate the component**

Run: `bin/rails generate view_component:component Books::FilterPane`

Not `generate component` — view_component 4.12 registers the generator under the
`view_component:` namespace, and the bare form does not exist. Several older docs in this
repo (including `docs/dev-core-values.md`) still say `generate component`; they are stale.

- [ ] **Step 2: Write the failing test**

Replace `test/components/books/filter_pane_component_test.rb`:

```ruby
require "test_helper"

module Books
  class FilterPaneComponentTest < ViewComponent::TestCase
    def render_pane(**options)
      defaults = {axis: :category, facet_rows: [], selected: [], results_src: "/filters/categories"}
      render_inline(Books::FilterPaneComponent.new(**defaults.merge(options)))
    end

    test "wraps itself in the pane frame for its axis" do
      render_pane(axis: :category)
      assert_selector "turbo-frame#books_filter_pane_category"

      render_pane(axis: :country, results_src: "/filters/countries")
      assert_selector "turbo-frame#books_filter_pane_country"
    end

    test "emits an empty results frame carrying its source" do
      render_pane(axis: :category, results_src: "/filters/categories?year_start=1900")

      assert_selector "turbo-frame#books_filter_results_category[data-results-src='/filters/categories?year_start=1900']"
      assert_no_selector "turbo-frame#books_filter_results_category input"
    end

    test "renders selected records checked in the selected container" do
      render_pane(selected: [categories(:books_novels_genre)])

      assert_selector "[data-books--filter-target='selected'] input[value='novels'][checked]"
    end

    test "renders facet rows unchecked with counts in the browse container" do
      render_pane(facet_rows: [{record: categories(:books_fiction_genre), count: 4321}])

      assert_selector "[data-books--filter-target='browse'] input[value='fiction']"
      assert_no_selector "[data-books--filter-target='browse'] input[checked]"
      assert_text "4,321"
    end

    test "carries the axis on every container the controller queries" do
      render_pane(axis: :category)

      assert_selector "[data-books--filter-target='results'][data-axis='category']"
      assert_selector "[data-books--filter-target='selected'][data-axis='category']"
      assert_selector "[data-books--filter-target='browse'][data-axis='category']"
      assert_selector "[data-books--filter-target='capNotice'][data-axis='category']"
    end

    test "the cap notice starts hidden and empty" do
      render_pane

      assert_selector "[data-books--filter-target='capNotice'].hidden"
      assert_selector "[data-books--filter-target='capNotice']", text: ""
    end

    test "uses the country input name on the country axis" do
      render_pane(axis: :country, selected: [books_countries(:french)], results_src: "/filters/countries")

      assert_selector "input[name='country_slugs[]'][value='french'][checked]"
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/components/books/filter_pane_component_test.rb`
Expected: FAIL — placeholder markup, no frames found.

- [ ] **Step 4: Write the implementation**

`app/components/books/filter_pane_component.rb`:

```ruby
module Books
  class FilterPaneComponent < ViewComponent::Base
    def initialize(axis:, facet_rows: [], selected: [], results_src: nil)
      @axis = axis.to_s
      @facet_rows = Array(facet_rows)
      @selected = Array(selected)
      @results_src = results_src
    end

    private

    attr_reader :axis, :facet_rows, :selected, :results_src

    def pane_frame_id
      "books_filter_pane_#{axis}"
    end

    def results_frame_id
      "books_filter_results_#{axis}"
    end
  end
end
```

`app/components/books/filter_pane_component.html.erb`:

```erb
<%= helpers.turbo_frame_tag pane_frame_id, data: {"books--filter-target": "pane", axis: axis} do %>
  <%= helpers.turbo_frame_tag results_frame_id,
        data: {"books--filter-target": "results", axis: axis, results_src: results_src} %>

  <div class="flex flex-col gap-1" data-books--filter-target="selected" data-axis="<%= axis %>">
    <%= render Books::FilterOptionRowsComponent.new(axis: axis, rows: selected, checked: true, show_counts: false) %>
  </div>

  <div class="flex flex-col gap-1" data-books--filter-target="browse" data-axis="<%= axis %>">
    <%= render Books::FilterOptionRowsComponent.new(axis: axis, rows: facet_rows) %>
  </div>

  <p class="text-sm text-warning hidden" data-books--filter-target="capNotice" data-axis="<%= axis %>"></p>
<% end %>
```

**Landmine:** the outer `turbo_frame_tag` here has the SAME id as the empty frame Task 5's modal emits. That is required — Turbo replaces a frame by matching id, so the modal's placeholder and this response must agree exactly, or the first pane open silently does nothing.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/components/books/filter_pane_component_test.rb`
Expected: `7 runs, 0 failures`

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/components/books/filter_pane_component.rb test/components/books/filter_pane_component_test.rb
git add app/components/books/filter_pane_component.rb app/components/books/filter_pane_component.html.erb test/components/books/filter_pane_component_test.rb
git commit -m "$(cat <<'EOF'
Add Books::FilterPaneComponent

One axis pane: an ephemeral results frame, a persistent selected list that
search hits get hoisted into, the browsed facet rows, and a cap notice.
Both axes share it; the row component handles the type badges.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Pane endpoints

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/books/filters_controller.rb`
- Test: `test/controllers/books/filters_controller_test.rb` (add; keep every existing test passing)

**Interfaces:**
- Consumes: `Books::FilterPaneComponent`, `Books::FilterOptionRowsComponent`, `Books::FilterFacetsQuery.genres/.countries`, `Books::CategorySearchQuery`, `Books::CountrySearchQuery`.
- Produces: `books_filters_categories_path` and `books_filters_countries_path`. Task 5's modal builds pane `src` values from them.

Two response shapes per action:
- **no `q`** → the full pane (`Books::FilterPaneComponent`), wrapped in the pane frame.
- **`q` present** → only the results frame, containing `Books::FilterOptionRowsComponent` with `show_counts: false`.

`#options` and its route are **not** touched in this task — they die in Task 6.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, directly below the existing `filters/options` line inside the books `DomainConstraint` block:

```ruby
    get "filters/categories", to: "books/filters#categories", as: :books_filters_categories
    get "filters/countries", to: "books/filters#countries", as: :books_filters_countries
```

- [ ] **Step 2: Write the failing tests**

Append inside `module Books ... class FiltersControllerTest`, before the final `end end`:

```ruby
    test "the category pane renders its frame with facet rows" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/categories"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_category"
      assert_select "turbo-frame#books_filter_results_category"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "the country pane renders its own frame" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/countries"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_country"
      assert_select "turbo-frame#books_filter_results_country"
    end

    test "the pane reflects the current selection as checked" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/categories", params: {category_slugs: ["novels"]}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=novels][checked]"
    end

    test "searching returns only the results frame" do
      get "/filters/categories", params: {q: "fict"}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_category"
      assert_select "turbo-frame#books_filter_pane_category", false
      assert_select "input[name='category_slugs[]'][value=fiction]"
    end

    test "search reaches subjects and locations, not only genres" do
      get "/filters/categories", params: {q: "politics"}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=politics]"
    end

    test "country search returns the country results frame" do
      get "/filters/countries", params: {q: "fren"}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_country"
      assert_select "input[name='country_slugs[]'][value=french]"
    end

    test "a blank search returns an empty results frame" do
      get "/filters/categories", params: {q: ""}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_category"
      assert_select "input[name='category_slugs[]']", false
    end

    test "the pane 404s on an unknown slug" do
      get "/filters/categories", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: FAIL — `AbstractController::ActionNotFound` / routing errors for `#categories`.

- [ ] **Step 4: Write the implementation**

In `app/controllers/books/filters_controller.rb`, add two public actions after `#options`:

```ruby
  def categories
    render_pane(:category)
  end

  def countries
    render_pane(:country)
  end
```

And these private methods:

```ruby
  def render_pane(axis)
    filters = resolved_filters
    rc = @ranking_configuration || Books::RankingConfiguration.default_primary
    raise ActiveRecord::RecordNotFound if rc.nil?

    if params[:q].present?
      render_pane_results(axis)
    else
      render_pane_body(axis, filters, rc)
    end
  end

  def render_pane_results(axis)
    rows = (axis == :category) ? Books::CategorySearchQuery.call(params[:q]) : Books::CountrySearchQuery.call(params[:q])

    render partial: "books/filters/results",
      locals: {axis: axis, rows: rows, results_src: pane_path(axis)},
      layout: false
  end

  def render_pane_body(axis, filters, rc)
    facet_rows = if axis == :category
      Books::FilterFacetsQuery.genres(**facet_args(filters, rc))
    else
      Books::FilterFacetsQuery.countries(**facet_args(filters, rc))
    end
    selected = (axis == :category) ? filters.categories : filters.countries

    render Books::FilterPaneComponent.new(
      axis: axis,
      facet_rows: facet_rows,
      selected: selected,
      results_src: pane_path(axis)
    ), layout: false
  end

  def facet_args(filters, rc)
    {
      ranking_configuration: rc,
      categories: filters.categories,
      countries: filters.countries,
      year_start: filters.year_start,
      year_end: filters.year_end
    }
  end

  def pane_path(axis)
    (axis == :category) ? books_filters_categories_path : books_filters_countries_path
  end
```

The results-only response needs a partial. Create `app/views/books/filters/_results.html.erb`:

```erb
<%= turbo_frame_tag "books_filter_results_#{axis}",
      data: {"books--filter-target": "results", axis: axis, results_src: results_src} do %>
  <%= render Books::FilterOptionRowsComponent.new(axis: axis, rows: rows, show_counts: false) %>
<% end %>
```

The frame id and the `data-*` attributes here must match what `Books::FilterPaneComponent` emits for the same axis — Turbo matches frames by id, and the controller finds them by target and axis.

**Why `layout: false`:** the controller declares `layout "books/application"`. Turbo would still find the frame inside a full document, but rendering the whole books layout for every keystroke is waste. `before_action :prevent_caching` already applies to these actions, so no cache headers need adding.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/books/filters_controller_test.rb`
Expected: all pass — the 8 new tests plus every pre-existing one, **including `options returns the full genre facet, not the increment-2 pane size`**, which must still pass because this task does not touch `#options`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/controllers/books/filters_controller.rb config/routes.rb test/controllers/books/filters_controller_test.rb
git add config/routes.rb app/controllers/books/filters_controller.rb app/views/books/filters/_results.html.erb test/controllers/books/filters_controller_test.rb
git commit -m "$(cat <<'EOF'
Add per-axis filter pane endpoints

/filters/categories and /filters/countries each render one pane, or -- with
?q= -- only the nested results frame, so a search replaces the results
without disturbing staged checkboxes elsewhere in the pane.

Search rows carry no count: facet counts are RC-scoped while item_count is
global, and showing both in one pane would give a row two numbers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The `books--filter` Stimulus controller

**Files:**
- Create: `app/javascript/controllers/books/filter_controller.js`
- Modify: `app/javascript/controllers/index.js` (via `bin/rails stimulus:manifest:update`, never by hand)

**Interfaces:**
- Consumes: the DOM contract above.
- Produces: `data-controller="books--filter"` with targets `level`, `summary`, `pane`, `results`, `selected`, `browse`, `capNotice`, `query`, `year`, and values `maxCategories`, `maxCountries`. Task 5's modal wires to exactly these.

There is no JS unit-test harness in this project — behavior is proven by the Playwright specs in Task 7. Keep the controller small and obvious.

- [ ] **Step 1: Write the controller**

Create `app/javascript/controllers/books/filter_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 250

// Connects to data-controller="books--filter"
export default class extends Controller {
  static targets = ["level", "summary", "pane", "results", "selected", "browse", "capNotice", "query", "year"]
  static values = { maxCategories: Number, maxCountries: Number }

  connect() {
    this.timers = {}
    this.show("root")
    this.refresh()
  }

  open(event) {
    this.show(event.currentTarget.dataset.levelTarget)
  }

  back() {
    this.show("root")
  }

  cancel() {
    this.element.closest("dialog")?.close()
  }

  show(level) {
    this.levelTargets.forEach((el) => el.classList.toggle("hidden", el.dataset.level !== level))
    if (level === "root") return

    const pane = this.paneTargets.find((el) => el.dataset.axis === level)
    if (pane && !pane.src && pane.dataset.paneSrc) pane.src = pane.dataset.paneSrc
  }

  search(event) {
    const axis = event.currentTarget.dataset.axis
    const query = event.currentTarget.value.trim()

    clearTimeout(this.timers[axis])
    this.timers[axis] = setTimeout(() => this.runSearch(axis, query), DEBOUNCE_MS)
  }

  runSearch(axis, query) {
    const frame = this.resultsTargets.find((el) => el.dataset.axis === axis)
    if (!frame) return

    const base = frame.dataset.resultsSrc
    const separator = base.includes("?") ? "&" : "?"
    frame.src = `${base}${separator}q=${encodeURIComponent(query)}`
  }

  // A search hit and a browsed row can name the same value. Checking the search
  // hit adopts the existing row when there is one, and otherwise moves the label
  // out of the results frame -- which the next search would otherwise discard.
  toggle(event) {
    const input = event.target
    const label = input.closest("label")
    const results = label?.closest("[data-books--filter-target='results']")

    if (results && input.checked) {
      const twin = this.findTwin(input, results)
      if (twin) {
        twin.checked = true
        label.remove()
      } else {
        this.selectedFor(input.dataset.axis)?.appendChild(label)
      }
    }

    this.refresh()
  }

  findTwin(input, results) {
    const matches = this.element.querySelectorAll(
      `input[name="${input.name}"][value="${CSS.escape(input.value)}"]`
    )
    return Array.from(matches).find((el) => el !== input && !results.contains(el))
  }

  selectedFor(axis) {
    return this.selectedTargets.find((el) => el.dataset.axis === axis)
  }

  refresh() {
    this.applyAxis("category", this.maxCategoriesValue)
    this.applyAxis("country", this.maxCountriesValue)
    this.refreshYearSummary()
  }

  applyAxis(axis, max) {
    const inputs = Array.from(this.element.querySelectorAll(`input[data-axis="${axis}"]`))
    // An unopened pane has no inputs yet. Bailing keeps the server-rendered
    // summary, which is correct; recomputing from zero inputs would blank it.
    if (inputs.length === 0) return

    const checked = inputs.filter((el) => el.checked)
    const atCap = max > 0 && checked.length >= max

    inputs.forEach((el) => { el.disabled = !el.checked && atCap })

    const notice = this.capNoticeTargets.find((el) => el.dataset.axis === axis)
    if (notice) {
      notice.textContent = atCap ? `You can select up to ${max}. Uncheck one to add another.` : ""
      notice.classList.toggle("hidden", !atCap)
    }

    const summary = this.summaryTargets.find((el) => el.dataset.axis === axis)
    if (summary) {
      const names = checked.map((el) => el.closest("label")?.querySelector(".label-text")?.textContent.trim())
      summary.textContent = names.filter(Boolean).join(", ") || "Any"
    }
  }

  refreshYearSummary() {
    const summary = this.summaryTargets.find((el) => el.dataset.axis === "year")
    if (!summary) return

    const [start, end] = this.yearTargets.map((el) => el.value.trim())
    summary.textContent = this.yearLabel(start, end)
  }

  yearLabel(start, end) {
    if (start && end) return start === end ? start : `${start}–${end}`
    if (start) return `Since ${start}`
    if (end) return `To ${end}`
    return "Any"
  }
}
```

**Two landmines encoded above, do not simplify them away:**
- `pane.src` is assigned only when falsy, so a pane loads **once**. Re-assigning on every open would refetch and wipe staged checkboxes in that pane.
- `toggle` checks `input.checked` before hoisting. Without that guard, *un*checking a hoisted row would move it again.

Also note `disabled` inputs do not submit — that is fine, because only *unchecked* inputs are ever disabled.

- [ ] **Step 2: Regenerate the Stimulus manifest**

Run: `bin/rails stimulus:manifest:update`
Expected: `app/javascript/controllers/index.js` gains

```javascript
import Books__FilterController from "./books/filter_controller"
application.register("books--filter", Books__FilterController)
```

`books--filter-search` must still be registered — it is deleted in Task 6, not here.

- [ ] **Step 3: Confirm the bundle builds**

Run: `yarn build:all`
Expected: completes with no error. A syntax error in the controller fails here.

- [ ] **Step 4: Confirm the suite is unaffected**

Run: `bin/rails test`
Expected: unchanged from Task 3 — this task adds no Ruby.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/books/filter_controller.js app/javascript/controllers/index.js
git commit -m "$(cat <<'EOF'
Add the books--filter Stimulus controller

Pane navigation by CSS, first-visit-only frame src, debounced per-axis
search, hoisting a checked search hit out of the ephemeral results frame,
level-1 summaries, and cap enforcement.

Panes load once on purpose: reassigning src on every open would refetch the
frame and wipe staged checkboxes inside it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Rewrite `Books::FilterModalComponent` — the switchover

**Files:**
- Modify: `app/components/books/filter_modal_component.rb`
- Modify: `app/components/books/filter_modal_component.html.erb`
- Test: `test/components/books/filter_modal_component_test.rb` (rewrite)

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: the modal the index view already renders. Its constructor keyword arguments are **unchanged** (`categories:`, `countries:`, `year_start:`, `year_end:`, `ranking_configuration:`), so `app/views/books/ranked_items/index.html.erb` needs no edit.

After this task the live modal is the drill-down. `#options` still exists but nothing calls it.

- [ ] **Step 1: Write the failing test**

Replace `test/components/books/filter_modal_component_test.rb` entirely:

```ruby
require "test_helper"

module Books
  class FilterModalComponentTest < ViewComponent::TestCase
    def render_modal(**options)
      render_inline(Books::FilterModalComponent.new(**options))
    end

    test "renders the dialog the filter bar opens" do
      render_modal

      assert_selector "dialog##{Books::FilterBarComponent::MODAL_ID}"
    end

    test "is a bottom sheet on small screens" do
      render_modal

      assert_selector "dialog.modal-bottom"
    end

    test "wires the Stimulus controller with both caps" do
      render_modal

      assert_selector "[data-controller='books--filter']"
      assert_selector "[data-books--filter-max-categories-value='#{Books::FilterParams::MAX_CATEGORIES}']"
      assert_selector "[data-books--filter-max-countries-value='#{Books::FilterParams::MAX_COUNTRIES}']"
    end

    test "the form targets the redirect endpoint and escapes the frame" do
      render_modal

      assert_selector "form[action='/filters'][method='get'][data-turbo-frame='_top']"
    end

    test "renders exactly four levels: root and three axes" do
      render_modal

      assert_selector "[data-books--filter-target='level']", count: 4
      assert_selector "[data-level='root']"
      assert_selector "[data-level='category']"
      assert_selector "[data-level='country']"
      assert_selector "[data-level='year']"
    end

    test "each axis row opens its own level" do
      render_modal

      assert_selector "[data-action='books--filter#open'][data-level-target='category']"
      assert_selector "[data-action='books--filter#open'][data-level-target='country']"
      assert_selector "[data-action='books--filter#open'][data-level-target='year']"
    end

    test "emits empty pane frames carrying their deferred source" do
      render_modal

      assert_selector "turbo-frame#books_filter_pane_category[data-pane-src]"
      assert_selector "turbo-frame#books_filter_pane_country[data-pane-src]"
      assert_no_selector "turbo-frame#books_filter_pane_category input"
    end

    test "panes are not lazy turbo-frames" do
      render_modal

      assert_no_selector "turbo-frame#books_filter_pane_category[loading='lazy']"
      assert_no_selector "turbo-frame#books_filter_pane_category[src]"
    end

    test "the pane source carries the current filters" do
      render_modal(categories: [categories(:books_novels_genre)], year_start: "1900")

      src = page.find("turbo-frame#books_filter_pane_category")["data-pane-src"]
      assert_includes src, "novels"
      assert_includes src, "1900"
    end

    test "renders the year inputs with the applied values" do
      render_modal(year_start: "1900", year_end: "2000")

      assert_selector "input[name='year_start'][value='1900']"
      assert_selector "input[name='year_end'][value='2000']"
    end

    test "a non-primary ranking configuration rides along as a hidden field" do
      alternate = ranking_configurations(:books_inherited)

      render_modal(ranking_configuration: alternate)

      assert_selector "input[type='hidden'][name='ranking_configuration_id'][value='#{alternate.id}']", visible: :all
    end

    test "the primary ranking configuration needs no hidden field" do
      render_modal(ranking_configuration: ranking_configurations(:books_global))

      assert_no_selector "input[name='ranking_configuration_id']", visible: :all
    end

    test "clear links to the unfiltered path" do
      render_modal(categories: [categories(:books_novels_genre)])

      assert_selector "a[href='/']"
    end

    test "summaries start with the applied selection" do
      render_modal(categories: [categories(:books_novels_genre)])

      assert_selector "[data-books--filter-target='summary'][data-axis='category']", text: "Novels"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/components/books/filter_modal_component_test.rb`
Expected: FAIL — the current modal has none of these hooks.

- [ ] **Step 3: Write the implementation**

`app/components/books/filter_modal_component.rb`:

```ruby
module Books
  class FilterModalComponent < ViewComponent::Base
    AXES = [
      {axis: "category", label: "Category", hint: "Genre, subject, or setting"},
      {axis: "country", label: "Origin", hint: "The book's national tradition, not the author's birthplace"},
      {axis: "year", label: "Published", hint: nil}
    ].freeze

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

    def max_categories
      Books::FilterParams::MAX_CATEGORIES
    end

    def max_countries
      Books::FilterParams::MAX_COUNTRIES
    end

    def rc_param
      ranking_configuration&.primary? ? nil : ranking_configuration&.id
    end

    def pane_src(axis)
      path = (axis == "category") ? helpers.books_filters_categories_path : helpers.books_filters_countries_path

      "#{path}?#{filter_query}"
    end

    def filter_query
      {
        category_slugs: categories.map(&:slug),
        country_slugs: countries.map(&:slug),
        year_start: year_start,
        year_end: year_end,
        ranking_configuration_id: rc_param
      }.compact_blank.to_query
    end

    def summary_for(axis)
      case axis
      when "category" then names_or_any(categories)
      when "country" then names_or_any(countries)
      else year_summary
      end
    end

    def names_or_any(records)
      records.any? ? records.map(&:name).join(", ") : "Any"
    end

    def year_summary
      return "#{year_start}–#{year_end}" if year_start.present? && year_end.present? && year_start != year_end
      return year_start if year_start.present? && year_start == year_end
      return "Since #{year_start}" if year_start.present?
      return "To #{year_end}" if year_end.present?

      "Any"
    end

    def clear_path
      Books::FilterPath.call(ranking_configuration: ranking_configuration)
    end
  end
end
```

`app/components/books/filter_modal_component.html.erb`:

```erb
<dialog id="<%= modal_id %>" class="modal modal-bottom sm:modal-middle">
  <div class="modal-box max-w-xl"
       data-controller="books--filter"
       data-books--filter-max-categories-value="<%= max_categories %>"
       data-books--filter-max-countries-value="<%= max_countries %>">

    <%= form_with url: helpers.books_filters_path, method: :get, data: {turbo_frame: "_top"} do %>
      <% if rc_param %>
        <%= hidden_field_tag :ranking_configuration_id, rc_param %>
      <% end %>

      <div data-books--filter-target="level" data-level="root">
        <h3 class="font-bold text-lg mb-4">Filters</h3>
        <ul class="menu w-full p-0">
          <% AXES.each do |row| %>
            <li>
              <button type="button" class="flex justify-between items-center w-full"
                      data-action="books--filter#open" data-level-target="<%= row[:axis] %>">
                <span class="flex flex-col items-start">
                  <span class="font-semibold"><%= row[:label] %></span>
                  <% if row[:hint] %>
                    <span class="text-xs text-base-content/60"><%= row[:hint] %></span>
                  <% end %>
                </span>
                <span class="flex items-center gap-2">
                  <span class="text-sm text-base-content/70 truncate max-w-[10rem]"
                        data-books--filter-target="summary" data-axis="<%= row[:axis] %>"><%= summary_for(row[:axis]) %></span>
                  <span aria-hidden="true">&rsaquo;</span>
                </span>
              </button>
            </li>
          <% end %>
        </ul>
      </div>

      <% ["category", "country"].each do |axis| %>
        <div class="hidden" data-books--filter-target="level" data-level="<%= axis %>">
          <button type="button" class="btn btn-ghost btn-sm mb-3" data-action="books--filter#back">
            &lsaquo; <%= AXES.find { |row| row[:axis] == axis }[:label] %>
          </button>

          <div class="form-control mb-3">
            <input type="search" class="input input-bordered w-full"
                   placeholder="<%= (axis == "category") ? "Search genres, subjects, settings" : "Search origins" %>"
                   data-books--filter-target="query" data-axis="<%= axis %>"
                   data-action="input->books--filter#search">
          </div>

          <div class="max-h-72 overflow-y-auto pr-1">
            <%= helpers.turbo_frame_tag "books_filter_pane_#{axis}",
                  data: {"books--filter-target": "pane", axis: axis, pane_src: pane_src(axis)} do %>
              <div class="flex justify-center py-8">
                <span class="loading loading-spinner loading-md"></span>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <div class="hidden" data-books--filter-target="level" data-level="year">
        <button type="button" class="btn btn-ghost btn-sm mb-3" data-action="books--filter#back">
          &lsaquo; Published
        </button>
        <div class="grid grid-cols-2 gap-4">
          <div class="form-control">
            <label class="label" for="year_start"><span class="label-text">From year</span></label>
            <%= number_field_tag :year_start, year_start, class: "input input-bordered w-full", placeholder: "Any",
                  data: {"books--filter-target": "year", axis: "year", action: "input->books--filter#refresh"} %>
          </div>
          <div class="form-control">
            <label class="label" for="year_end"><span class="label-text">To year</span></label>
            <%= number_field_tag :year_end, year_end, class: "input input-bordered w-full", placeholder: "Any",
                  data: {"books--filter-target": "year", axis: "year", action: "input->books--filter#refresh"} %>
          </div>
        </div>
      </div>

      <div class="modal-action">
        <%= link_to "Clear", clear_path, class: "btn btn-ghost", data: {turbo_frame: "_top"} %>
        <button type="button" class="btn" data-action="books--filter#cancel">Cancel</button>
        <%= submit_tag "Apply", class: "btn btn-primary", data: {disable_with: false} %>
      </div>
    <% end %>
  </div>
  <form method="dialog" class="modal-backdrop">
    <button aria-label="Close">close</button>
  </form>
</dialog>
```

**Landmines:**
- The pane frames carry `data-pane-src`, **never `src` and never `loading: :lazy`**. A lazy frame's IntersectionObserver does not fire inside a closed `<dialog>` or a `display:none` pane, so the pane would stay empty until something else forced it.
- The old modal reset the form via an `onclose` attribute so staged input did not survive a cancel. That is **deliberately gone**: closing now keeps staged state, and Cancel simply closes. Reopening shows what you staged. If a reset is wanted later it must not clobber hoisted rows.

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/components/books/filter_modal_component_test.rb`
Expected: `14 runs, 0 failures`

- [ ] **Step 5: Confirm the index view still renders**

Run: `bin/rails test test/controllers/books/ test/components/books/`
Expected: all pass. The constructor signature did not change, so `app/views/books/ranked_items/index.html.erb` needs no edit — confirm by reading it that both `FilterBarComponent` and `FilterModalComponent` are still passed the same keywords.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/components/books/filter_modal_component.rb test/components/books/filter_modal_component_test.rb
yarn build:all
git add app/components/books/filter_modal_component.rb app/components/books/filter_modal_component.html.erb test/components/books/filter_modal_component_test.rb
git commit -m "$(cat <<'EOF'
Rewrite the filter modal as a two-level drill-down

Level 1 is three rows -- Category, Origin, Published -- and runs no query.
Each axis pane is a turbo-frame whose src is assigned on first open, so
panes are CSS-toggled and staged checkboxes survive navigation.

Pane frames carry data-pane-src rather than src or loading:lazy: a lazy
frame's IntersectionObserver never fires inside a closed dialog.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Delete the superseded modal

**Files:**
- Delete: `app/components/books/filter_facets_component.rb` + `.html.erb`
- Delete: `test/components/books/filter_facets_component_test.rb`
- Delete: `app/views/books/filters/options.html.erb`
- Delete: `app/javascript/controllers/books/filter_search_controller.js`
- Modify: `app/controllers/books/filters_controller.rb` — remove `#options`
- Modify: `config/routes.rb` — remove the `filters/options` route
- Modify: `test/controllers/books/filters_controller_test.rb` — remove the four `options` tests
- Modify: `app/javascript/controllers/index.js` (via `bin/rails stimulus:manifest:update`)

**Interfaces:**
- Consumes: nothing. Task 5 made all of this unreachable.
- Produces: `/filters/options` now 404s.

The four tests to remove from `filters_controller_test.rb` are exactly: `"options renders the facet frame"`, `"options reflects the current selection as checked"`, `"options 404s on an unknown slug"`, and `"options returns the full genre facet, not the increment-2 pane size"`. The last one was added in increment 1 specifically to guard the `limit: 500` pin, which dies with the action it guarded.

- [ ] **Step 1: Delete the files**

```bash
git rm app/components/books/filter_facets_component.rb \
       app/components/books/filter_facets_component.html.erb \
       test/components/books/filter_facets_component_test.rb \
       app/views/books/filters/options.html.erb \
       app/javascript/controllers/books/filter_search_controller.js
```

- [ ] **Step 2: Remove the action and its route**

In `app/controllers/books/filters_controller.rb`, delete the entire `def options ... end` method. **Leave `#show`, `#categories`, `#countries`, and every private method intact** — `resolved_filters` and `find_ranking_configuration` are still used.

In `config/routes.rb`, delete the line:

```ruby
    get "filters/options", to: "books/filters#options", as: :books_filters_options
```

and update the comment above the remaining filter routes so it no longer describes a facets frame.

- [ ] **Step 3: Remove the four obsolete controller tests**

Delete those four `test "options ..."` blocks from `test/controllers/books/filters_controller_test.rb`. Leave every other test.

- [ ] **Step 4: Add a test proving the route is gone**

Append inside the test class:

```ruby
    test "the superseded options endpoint is gone" do
      assert_raises ActionController::RoutingError do
        get "/filters/options"
      end
    end
```

If the app renders 404 rather than raising in the test environment, assert `assert_response :not_found` instead — run it and use whichever matches.

- [ ] **Step 5: Regenerate the manifest and rebuild**

```bash
bin/rails stimulus:manifest:update
yarn build:all
```

Expected: `books--filter-search` is gone from `index.js`; `books--filter` remains.

- [ ] **Step 6: Run the suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. The runs count **drops** here — the deleted facets component test and the four options tests go away. Record the new number; Task 7 compares against it.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "$(cat <<'EOF'
Delete the superseded flat filter modal

Removes FilterFacetsComponent, the /filters/options endpoint and view, and
the books--filter-search controller, all orphaned by the drill-down rewrite.

Takes the limit: 500 pin with it -- that existed only to keep the flat
modal rendering its full option set until this point.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Suppress Enter in the search box, then E2E and the gate

**Files:**
- Modify: `app/javascript/controllers/books/filter_controller.js`
- Modify: `app/components/books/filter_modal_component.html.erb`
- Rewrite: `e2e/tests/books/filters.spec.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: proof the drill-down works in a browser — in particular the hoist, which no Ruby test can reach.

#### The Enter bug

The pane search inputs sit inside the `<form>` that submits to `/filters`. A single text input in a form means **Enter submits it** — so typing a search and pressing Enter applies whatever is currently staged and navigates away, mid-search.

This is not an edge case on the device this rework exists for: a mobile virtual keyboard's **Search / Go key is Enter**, so it is the *expected* way to finish typing a query on a phone.

- [ ] **Step 1: Add the suppression**

In `app/javascript/controllers/books/filter_controller.js`, add one action method (place it directly after `search`):

```javascript
  // The search inputs live inside the form that submits to /filters, so Enter
  // would apply the staged filters mid-search. On a phone the keyboard's
  // Search key IS Enter, so this is the common path, not an edge case.
  suppressEnter(event) {
    if (event.key === "Enter") event.preventDefault()
  }
```

In `app/components/books/filter_modal_component.html.erb`, extend the search input's `data-action` to bind it — the value becomes two space-separated action descriptors:

```erb
                   data-action="input->books--filter#search keydown->books--filter#suppressEnter">
```

- [ ] **Step 2: Verify the build**

Run: `yarn build:all`
Expected: succeeds.

- [ ] **Step 3: Rewrite the spec**

Replace `e2e/tests/books/filters.spec.ts` entirely:

```ts
import { test, expect } from '@playwright/test';

const openModal = async (page) => {
  await page.getByRole('button', { name: 'Filters' }).click();
  await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
};

test.describe('Books filters', () => {
  test('no pane is fetched until its axis is opened', async ({ page }) => {
    const paneRequests: string[] = [];
    page.on('request', (r) => {
      if (r.url().includes('/filters/categories')) paneRequests.push(r.url());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');
    await openModal(page);

    expect(paneRequests).toHaveLength(0);

    await page.getByRole('button', { name: /Category/ }).click();
    await expect.poll(() => paneRequests.length).toBe(1);
  });

  test('level 1 shows three axes and drills into one', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await expect(page.locator("[data-level='root']")).toBeVisible();
    await page.getByRole('button', { name: /Category/ }).click();

    await expect(page.locator("[data-level='root']")).toBeHidden();
    await expect(page.locator("[data-level='category']")).toBeVisible();
    await expect(page.locator("input[name='category_slugs[]']").first()).toBeVisible();
  });

  test('staging survives navigating between panes', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    const genre = page.locator("input[name='category_slugs[]']").first();
    await genre.waitFor();
    await genre.check();

    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Origin/ }).click();
    await page.locator("input[name='country_slugs[]']").first().waitFor();
    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Category/ }).click();

    await expect(genre).toBeChecked();
  });

  test('applying across two axes navigates to the canonical URL', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.locator("input[name='category_slugs[]'][value='novels']").check();
    await page.getByRole('button', { name: /^‹/ }).click();
    await page.getByRole('button', { name: /Origin/ }).click();
    await page.locator("input[name='country_slugs[]'][value='french']").check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/the-greatest/novels/books/written-by/french/authors');
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });

  test('search is scoped to its own axis', async ({ page }) => {
    await page.goto('/');
    await openModal(page);

    await page.getByRole('button', { name: /Category/ }).click();
    await page.getByPlaceholder('Search genres, subjects, settings').fill('fren');

    await expect(page.locator("turbo-frame#books_filter_results_category input")).toHaveCount(0);
  });

  test('a checked search result survives the next search', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('politic');
    const hit = page.locator("turbo-frame#books_filter_results_category input").first();
    await hit.waitFor();
    const slug = await hit.getAttribute('value');
    await hit.check();

    await search.fill('zzzzz-no-such-category');
    await expect(page.locator("turbo-frame#books_filter_results_category input")).toHaveCount(0);

    await expect(page.locator(`input[name='category_slugs[]'][value='${slug}']`)).toBeChecked();
  });

  test('a staged subject can be unchecked after applying', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('politic');
    const hit = page.locator("turbo-frame#books_filter_results_category input").first();
    await hit.waitFor();
    const slug = await hit.getAttribute('value');
    await hit.check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('filter-chip')).toHaveCount(1);

    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();
    const staged = page.locator(`input[name='category_slugs[]'][value='${slug}']`);
    await staged.waitFor();
    await expect(staged).toBeChecked();
    await staged.uncheck();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page).toHaveURL('/');
  });

  test('pressing Enter in the search box does not apply the filters', async ({ page }) => {
    await page.goto('/');
    await openModal(page);
    await page.getByRole('button', { name: /Category/ }).click();

    const search = page.getByPlaceholder('Search genres, subjects, settings');
    await search.fill('novel');
    await search.press('Enter');

    await page.waitForTimeout(500);
    await expect(page).toHaveURL('/');
    await expect(page.locator('dialog#books_filter_modal')).toBeVisible();
  });

  test('chips remove one filter at a time down to the root', async ({ page }) => {
    await page.goto('/the-greatest/novels/books/written-by/french/authors');

    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
    await page.getByTestId('filter-chip').filter({ hasText: 'French' }).getByRole('link').click();

    await expect(page).toHaveURL('/the-greatest/novels/books');
    await page.getByTestId('filter-chip').filter({ hasText: 'Novels' }).getByRole('link').click();

    await expect(page).toHaveURL('/');
    await expect(page.getByTestId('filter-chip')).toHaveCount(0);
  });

  test('the heading reflects the active filter', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');

    await expect(page.getByRole('heading', { level: 1 })).toContainText(/Novels/i);
  });

  test('an unknown genre slug is a 404', async ({ page }) => {
    const response = await page.goto('/the-greatest/no-such-genre/books');

    expect(response?.status()).toBe(404);
  });
});
```

The sixth test is the hoist regression and is the single most important spec in this file — it is the only place the hoisting mechanism is exercised end to end.

- [ ] **Step 2: Build and start a server**

`bin/dev` self-terminates in a non-TTY shell — the Tailwind watcher exits and takes foreman with it. Use:

```bash
yarn build:all
bin/rails server &
```

Before trusting any result, confirm port 3000 is **this worktree's** server. Caddy proxies `dev-new.thegreatestbooks.org` → `localhost:3000`; the books routes are hostname-constrained, so hitting `localhost:3000` directly will not match them.

- [ ] **Step 3: Run the spec**

Run: `yarn test:e2e e2e/tests/books/filters.spec.ts`
Expected: all 11 pass.

If a genre named `novels` or a country named `french` is missing from the dev database, the "applying across two axes" test fails on a missing checkbox — check the data before assuming a code defect. If every admin spec times out on the public homepage, the e2e user lost its role in a reseed: `bin/rails e2e:admin`.

- [ ] **Step 4: Full gate**

```bash
bin/rails test
bundle exec standardrb
```

Expected: 0 failures, 0 errors; runs count matching Task 6's recorded number plus the component tests added in Tasks 1, 2, 5. `standardrb` clean.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/filters.spec.ts
git commit -m "$(cat <<'EOF'
Rewrite the books filter E2E suite for the drill-down modal

Covers deferred pane loading, staging surviving pane navigation, applying
across two axes, per-axis search scoping, and -- the one no Ruby test can
reach -- a checked search result surviving the next search and remaining
uncheckable after an Apply round trip.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done when

- [ ] `bin/rails test` → 0 failures, 0 errors
- [ ] `bundle exec standardrb` → no offenses
- [ ] `yarn test:e2e e2e/tests/books/filters.spec.ts` → 11/11
- [ ] `/filters/options` no longer routes; `FilterFacetsComponent` and `books--filter-search` no longer exist
- [ ] The modal opens to three rows, drills into an axis, searches that axis only, and a checked search hit survives the next search
- [ ] `app/lib/books/` is untouched by this increment — increment 1 owns the query layer

## Landmines

- **`data-pane-src`, never `src` or `loading: :lazy`.** A lazy frame's IntersectionObserver does not fire inside a closed `<dialog>` or a `display:none` pane, so the pane would never load.
- **Assign `pane.src` only when it is falsy.** Reassigning on every open refetches the frame and wipes every staged checkbox inside it.
- **Guard the hoist on `input.checked`.** Without it, *un*checking a hoisted row moves it a second time.
- **`data-turbo-frame="_top"` on the form.** Without it the Apply submit is captured by the enclosing pane frame instead of navigating the page.
- **The modal's placeholder frame id and the pane response's frame id must match exactly** (`books_filter_pane_<axis>`). A mismatch makes the first open silently do nothing — no console error, no failing unit test.
- **Search rows carry no count.** Facet counts are ranking-configuration-scoped; `item_count`/`book_count` are global and diverge by 4× or more.
- **`app/javascript/controllers/index.js` is generated.** Always `bin/rails stimulus:manifest:update`, never a hand edit.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** The books data exists only in development and takes hours to rebuild.
- The worktree shares `the_greatest_test` with the main checkout — do not run tests concurrently with another worktree.
