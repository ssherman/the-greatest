# Books Filter Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the books front-page filter panel as six per-type rows with a pinned "Show N books" footer, a bigger trigger, single-year shortcuts, an advanced-search link with a signed-out intro page, and a selection model in which a ticked checkbox never moves.

**Architecture:** Selection state moves out of the visible checkboxes into a server-rendered **store** of hidden inputs inside the form, outside every lazy frame. Visible checkboxes carry no `name`. They are views of the store: ticking one adds or removes a store entry, and `sync()` re-derives every checkbox, chip, summary and cap from the store. Nothing is ever hoisted, re-parented or focused, and that is the jump fix. Per-type facet and search queries feed lazily loaded pages, and a JSON count endpoint drives the footer button.

**Tech Stack:** Rails 8, ViewComponent, Stimulus, Turbo Frames, daisyUI 5 / Tailwind 4, Minitest + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-22-books-filter-panel-redesign-design.md`. Read it before starting any task.

## Global Constraints

- All Rails/yarn commands run from `web-app/`. Lint is `bundle exec standardrb`, never `bin/rubocop`. Never run brakeman.
- No change to the URL grammar, `Books::FilterPath`, `Books::FilterTitle`, robots, or `Books::FilterParams` caps (`MAX_CATEGORIES = 6` across all four category types combined, `MAX_COUNTRIES = 10`).
- The first-page rows, in this order, are `Genre`, `Published`, `Audience`, `Origin`, `Subject`, `Setting`. Origin is hidden on collection pages, as today.
- Labels: "Origin", not "Country"; "Setting", not "Location". In code, the setting type is the enum value `location`.
- Trigger label: `Filter books` with no filters; `Filters` plus a count badge when any are applied.
- Footer: `Clear` plus a submit button reading `Show N books` (`Show 1 book` when N is 1), with N formatted with thousands separators.
- Eras, in order: `Since 2000` (2000–), `1950–1999`, `1900–1949`, `1800s` (1800–1899), `Before 1800` (–1799). Then "Best of a single year": the five years before `Date.current.year`, newest first. Then the From/To boxes with the hint `Same year in both boxes = just that year. Minus sign for BC.`
- Popular list size on Subject and Setting pages is **25**. Search returns at most **10** rows.
- **A visible checkbox is never moved, re-parented or `focus()`ed programmatically after the user ticks it.**
- Every count is over `Books::RankedBooksQuery`'s set, never `item_count` or `book_count`.
- Applied filters must be in the initial server response, outside any lazy turbo-frame.
- daisyUI 5: none of the removed v4 classes (`form-control`, `label-text`, `input-bordered`, …). Selected and unselected states must differ by more than colour (fill vs outline, `aria-pressed`, check marks). The owner is red-green colour blind.
- Do not change `CategorySearchQuery`'s behaviour; admin, saved searches and global canon share it.
- Tests assert behaviour, not copy or CSS. Minitest 6: use `assert_nil`, never `assert_equal nil`.
- Before every E2E run, confirm port 3000 belongs to this worktree (AGENTS.md snippet). If it is another checkout's, stop and tell the user. Run `yarn build:all` after any JS or CSS change and before E2E.

## Review Focus

1. **Applied filters that match zero books.** The applied genre or country must still be listed, checked, on its page so it can be unticked. → Task 1 test `applied categories are listed even with zero matching books`.
2. **Show without opening any page on a filtered URL.** The current filters must be kept. → Task 5 structural test `store holds applied filters outside every turbo-frame` + Task 6 E2E `Show without opening a page keeps the filters`.
3. **A ticked search result whose row disappears on the next search.** It is still submitted and still shown as a chip. → Task 6 E2E `a ticked search result survives the next search as a chip`.
4. **The category cap spans types.** With 6 categories across genre and subject, an unticked box on any page is disabled, including search results that arrive later. → Task 6 E2E `the category cap spans pages and later search results`.
5. **Closing after changes, and Back after Show.** Escape after ticks or Clear restores the applied state, and a page restored from Turbo's cache does not carry staged changes. → Task 6 E2E `closing restores the applied selection, even after Clear` and the `turbo:before-cache` step.

---

### Task 1: Per-type facet query

**Files:**
- Modify: `app/lib/books/filter_facets_query.rb`
- Test: `test/lib/books/filter_facets_query_test.rb`

**Interfaces:**
- Produces:
  - `Books::FilterFacetsQuery.categories(type:, ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil, limit: nil) -> Array<{record: Books::Category, count: Integer}>`
    - `type` is one of `"genre"`, `"audience"`, `"subject"`, `"location"`, otherwise `ArgumentError`.
  - `Books::FilterFacetsQuery.countries(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil) -> Array<{record: Books::Country, count: Integer}>`.
  - Constant `Books::FilterFacetsQuery::TYPES = %w[genre audience subject location]`.
- Removed: `.call`, `.genres`, `Result`, `DEFAULT_LIMIT`. The only app caller is `FiltersController`, which Task 4 rewrites. Delete the tests that cover the removed methods.

Behaviour:
- **Categories facet.** Keeps the applied category filter (AND), scopes to `category_type: type`, and orders by count desc, then id asc. `limit: nil` means all rows.
- **Countries facet.** Drops the country filter (OR alternatives), as today, and returns all rows.
- **Applied selections are no longer excluded.** Any applied record of the requested type, or any applied country, that is missing from the counted rows is appended with `count: 0`.

- [ ] **Step 1: Write the failing tests** (reuse the file's setup: three ranked books in `@rc`)

```ruby
test "categories facet returns only the requested type" do
  slugs = Books::FilterFacetsQuery.categories(type: "subject", ranking_configuration: @rc).map { |r| r[:record].slug }
  assert_includes slugs, "politics"
  assert_not_includes slugs, "novels"
end

test "categories facet keeps applied categories in the list with their counts" do
  novels = categories(:books_novels_genre)
  rows = Books::FilterFacetsQuery.categories(type: "genre", ranking_configuration: @rc, categories: [novels])
  assert_equal 3, rows.find { |r| r[:record] == novels }[:count]
end

test "applied categories are listed even with zero matching books" do
  americana = categories(:books_americana_genre) # no ranked books carry it
  rows = Books::FilterFacetsQuery.categories(type: "genre", ranking_configuration: @rc, categories: [americana])
  assert_equal [americana, 0], [rows.last[:record], rows.last[:count]]
end

test "categories facet limit caps the rows" do
  assert_equal 1, Books::FilterFacetsQuery.categories(type: "genre", ranking_configuration: @rc, limit: 1).size
end

test "an unknown type raises" do
  assert_raises(ArgumentError) { Books::FilterFacetsQuery.categories(type: "theme", ranking_configuration: @rc) }
end

test "countries facet keeps an applied country in the list" do
  # use an existing books_countries fixture applied to a ranked book; assert it is present with count > 0
end

test "audience facet lists audiences" do
  audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
  CategoryItem.create!(category: audience, item: books_books(:crime_and_punishment))
  rows = Books::FilterFacetsQuery.categories(type: "audience", ranking_configuration: @rc)
  assert_equal [[audience, 1]], rows.map { |r| [r[:record], r[:count]] }
end
```

For the countries test, read `test/fixtures/books/book_countries.yml` (or wherever `Books::BookCountry` fixtures live) and pick a country linked to a book ranked in setup. Also keep or adapt the existing collection, year-bound and `rows_for`-nil-record tests so they call the new methods.

- [ ] **Step 2: Run them and confirm they fail**
  Run: `bin/rails test test/lib/books/filter_facets_query_test.rb`. Expected: FAIL, with `NoMethodError` for `categories` and the countries assertion failing.

- [ ] **Step 3: Implement `categories` and `countries`, and delete `call`, `genres`, `Result` and `DEFAULT_LIMIT`**
  Rewrite the class comment to describe the new shape: one type per call, applied rows included, AND vs OR asymmetry.

- [ ] **Step 4: Run the tests and confirm they pass**
  Run: `bin/rails test test/lib/books/filter_facets_query_test.rb`. Expected: PASS. (`FiltersController` still references `.genres` until Task 4. Do not run its tests here.)

- [ ] **Step 5: Commit**
  `git commit -m "FilterFacetsQuery: one category type per call, applied rows always listed"`

---

### Task 2: Filtered, per-type category search

**Files:**
- Create: `app/lib/books/filter_category_search_query.rb`
- Modify: `app/lib/books/browse_query.rb` (make `name_match_quality_sql` public, and say in its comment that the filter search shares it)
- Test: `test/lib/books/filter_category_search_query_test.rb`

**Interfaces:**
- Produces: `Books::FilterCategorySearchQuery.call(query:, type:, ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil, limit: 10) -> Array<Books::Category>`
  - `type` must be in `FilterFacetsQuery::TYPES`, otherwise `ArgumentError`.
  - A blank query, or one over 100 characters after `strip.first(100)`, returns `[]`.
- Consumes: `Books::BrowseQuery.name_match_quality_sql(query, escaped)`, `CategorySearchQuery::NAME_OR_ALIAS_SQL`, `Books::RankedBooksQuery.call(...)`.

Behaviour:
- **Candidates:** active categories of `type` whose name or alias matches.
- **Kept:** only candidates with at least one book in `RankedBooksQuery`'s filtered set, built from the given filters with `.except(:includes).reorder(nil).reselect(:item_id)`.
- **Order:** match quality, then that filtered count desc, then name.
- **Speed:** the name match runs inside the counting subquery, as in `BrowseQuery.search`.

- [ ] **Step 1: Write the failing tests**

```ruby
setup do
  @rc = ranking_configurations(:books_global)
  RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
  RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
  @alias_hit = Books::Category.create!(name: "Statecraft", category_type: :subject, alternative_names: ["Politics Junk"])
  CategoryItem.create!(category: @alias_hit, item: books_books(:war_and_peace))
  CategoryItem.create!(category: @alias_hit, item: books_books(:crime_and_punishment))
end

def search(q, **opts) = Books::FilterCategorySearchQuery.call(query: q, type: "subject", ranking_configuration: @rc, **opts)

test "a name match outranks a more common alias-only match" do
  # politics (fixture) has 1 ranked book; Statecraft has 2 but matches only by alias
  assert_equal [categories(:books_politics_subject), @alias_hit], search("politics")
end

test "results are limited to the requested type" do
  assert_empty search("novels")
end

test "results are limited to categories with books under the applied filters" do
  # politics is only on crime_and_punishment; classics is only on war_and_peace/clash
  assert_equal [@alias_hit], search("politic", categories: [categories(:books_classics_genre)])
end

test "a blank query returns nothing" do
  assert_empty search("  ")
end
```

Note: check `category_items.yml` before relying on the comments above. They must hold for the assertions to mean anything. The alias fixture is what keeps the ordering test from passing vacuously.

- [ ] **Step 2: Run them and confirm they fail**
  Run: `bin/rails test test/lib/books/filter_category_search_query_test.rb`. Expected: FAIL with `NameError`.

- [ ] **Step 3: Implement the query** in `app/lib/books/filter_category_search_query.rb` and make `BrowseQuery.name_match_quality_sql` public.

- [ ] **Step 4: Run the tests and confirm they pass,** together with `test/lib/books/browse_query_test.rb`.

- [ ] **Step 5: Measure on the dev database (read-only)**
  Run: `bin/rails runner 'rc = Books::RankingConfiguration.default_primary; f = Books::Category.find_by(slug: "fantasy"); ActiveRecord::Base.uncached { 3.times { t = Process.clock_gettime(Process::CLOCK_MONOTONIC); Books::FilterCategorySearchQuery.call(query: "war", type: "subject", ranking_configuration: rc, categories: [f].compact); puts ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round } }'`
  - Pass: the best of three runs is under ~300 ms.
  - Otherwise: drop the filtered gate. Count over the whole ranking, as `BrowseQuery.search` does, delete the "limited to categories with books under the applied filters" test, and record the measured numbers in the commit message so the PR can say so (spec).

- [ ] **Step 6: Commit**
  `git commit -m "FilterCategorySearchQuery: per-type search scoped to the applied filters"`

---

### Task 3: Count endpoint

**Files:**
- Modify: `config/routes.rb` (next to `get "filters/countries"`, ~l.1004)
- Modify: `app/controllers/books/filters_controller.rb`
- Test: `test/controllers/books/filters_controller_test.rb`

**Interfaces:**
- Produces: `GET /filters/count` → `books_filters_count_path`.
  - Takes the same params as `/filters` (`category_slugs[]`, `country_slugs[]`, `year_start`, `year_end`, `ranking_configuration_id`, `collection`).
  - Renders `{"count": Integer}` as JSON, uncached (the controller already has `prevent_caching`).
  - Unknown slugs, over-cap selections or bad years → 404 via `FilterParams`, as `show` does.
- Consumes: `Books::RankedBooksQuery.call(...).except(:includes).reorder(nil).count`. Missing rc → `Books::RankingConfiguration.default_primary`.

- [ ] **Step 1: Write the failing tests**

```ruby
test "count returns the number of ranked books for a selection" do
  RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
  RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)

  get "/filters/count", params: {category_slugs: ["classics"]}, as: :json

  assert_response :success
  assert_equal({"count" => 1}, response.parsed_body)
end

test "count is a 404 for an unknown slug" do
  get "/filters/count", params: {category_slugs: ["no-such-genre"]}
  assert_response :not_found
end

test "count respects a collection" do
  # mirror an existing collection test in this file; assert the count differs from the unscoped count
end
```

`@rc` must be the primary configuration that `default_primary` returns. Check which fixture that is before writing the counts.

- [ ] **Step 2: Run them and confirm they fail** (`bin/rails test test/controllers/books/filters_controller_test.rb -n /count/`). Expected: a routing error.
- [ ] **Step 3: Add the route and `count` action**
- [ ] **Step 4: Run them and confirm they pass**
- [ ] **Step 5: Commit** `git commit -m "Books filters: JSON count endpoint for the Show button"`

---

### Task 4: Typed pages: controller, pane, rows, results

**Files:**
- Modify: `app/controllers/books/filters_controller.rb` (`categories`, `render_pane*`, `pane_path`)
- Modify: `app/components/books/filter_pane_component.rb` + `.html.erb`
- Modify: `app/components/books/filter_option_rows_component.rb` + `.html.erb`
- Modify: `app/views/books/filters/_results.html.erb`
- Test: `test/controllers/books/filters_controller_test.rb`, `test/components/books/filter_pane_component_test.rb`, `test/components/books/filter_option_rows_component_test.rb`

**Interfaces:**
- Consumes: Task 1 `FilterFacetsQuery.categories/countries`, Task 2 `FilterCategorySearchQuery.call`.
- Produces:
  - **Category pages:** `GET /filters/categories?type=<genre|audience|subject|location>&<applied filter params>`.
    - Missing `type` → `genre`. Pages served from a 6-hour edge-cached front page during deploy still call it without a type.
    - Any other `type` → 404.
    - With `q` (only meaningful for subject and location), it renders the results partial from `FilterCategorySearchQuery`.
    - Without `q`, it renders `FilterPaneComponent`:
      - genre, audience: `FilterFacetsQuery.categories(type:)` with `limit: nil`;
      - subject, location: `limit: 25`.
  - **Countries page:** `GET /filters/countries?<applied filter params>` renders the full countries facet. Its `q` branch is deleted, because Origin filters client-side.
  - **Pane component:** `Books::FilterPaneComponent.new(type:, rows:, results_src: nil)`.
    - `type` is a category type or `"country"`.
    - The turbo-frame id is `books_filter_pane_<type>`.
    - When `results_src` is present (subject and location), it renders an empty `turbo-frame#books_filter_results_<type>` with `data-results-src` *above* the popular list, under a "Popular <plural>" heading. When it is absent, there is no results frame.
    - `results_src` is the pane URL including the type and applied-filter params, without `q`.
    - The browse link stays, now pointing at the type's own browse page:
      - genre → `books_categories_path`
      - subject → `/categories/subjects`
      - location → `/categories/settings`
      - audience → `/categories/audiences`
      - country → `books_countries_path`

      Use the route helpers. It keeps `target: "_top"`.
    - When `rows` is empty, it shows an empty-state line.
  - **Option rows:** `Books::FilterOptionRowsComponent.new(axis:, type:, rows:, show_counts: true)`. Each row is a `<label data-filter-row data-name="<lowercased name>">` wrapping:
    - `<input type="checkbox" class="checkbox checkbox-sm" data-filter-option data-axis="<category|country>" data-type="<type>" data-slug="<slug>" data-name="<display name>" data-action="change->books--filter#toggle">` with **no `name` attribute**;
    - the name;
    - the count, when shown.

    Delete the `checked:` option and the type badge. Each page is a single type.
  - `_results.html.erb` renders rows with `show_counts: false` inside `turbo-frame#books_filter_results_<type>`.

- [ ] **Step 1: Write the failing tests**
  - **Controller:**
    - `categories with type=subject renders only subject rows` (assert `input[data-type='subject']` present, `input[data-type='genre']` absent);
    - `categories without a type renders genres`;
    - `categories with an unknown type is a 404`;
    - `a subject search returns name matches scoped to subjects` (`q: "politics", type: "subject"` → `input[data-slug='politics']`);
    - `countries renders every country with ranked books` (no 24-row cap).
  - **Option rows:**
    - `checkboxes carry no name so they are never submitted` (`assert_no_selector "input[name]"`);
    - `checkboxes carry axis, type, slug and display name`.
  - **Pane:**
    - `subject pane renders a results frame carrying its source`;
    - `genre pane renders no results frame`;
    - `an empty pane says so` (assert an element with `data-testid="filter-pane-empty"`).
  - Replace the old pane and row tests that assert the removed behaviour (badges, `checked:`, `axis:` frame ids).
- [ ] **Step 2: Run them and confirm they fail**
  Run: `bin/rails test test/controllers/books/filters_controller_test.rb test/components/books/filter_pane_component_test.rb test/components/books/filter_option_rows_component_test.rb`
- [ ] **Step 3: Implement** the controller branches and the component changes.
- [ ] **Step 4: Run the same tests and confirm they pass.** Then run `bin/rails test test/components/books test/controllers/books`. The modal component test is expected to fail until Task 5; nothing else should.
- [ ] **Step 5: Commit** `git commit -m "Books filters: one lazily loaded page per filter type"`

---

### Task 5: Panel markup (FilterModalComponent)

**Files:**
- Modify: `app/components/books/filter_modal_component.rb` + `.html.erb`
- Modify: `app/views/books/ranked_items/index.html.erb` (pass `total_count: @pagy.count`)
- Test: `test/components/books/filter_modal_component_test.rb` (rewrite)

**Interfaces:**
- Consumes: Task 3 `books_filters_count_path`; Task 4 pane URLs and frame ids.
- Produces, as the DOM contract for Task 6:
  - **Constructor:** `FilterModalComponent.new(categories:, countries:, year_start:, year_end:, ranking_configuration:, collection:, total_count:)`.
  - **Constants:**
    - `ROWS`: an ordered list of `{key:, label:, plural:}` for `genre/Genre`, `year/Published`, `audience/Audience`, `country/Origin`, `subject/Subject`, `location/Setting`. Keep Origin's existing hint.
    - `ERAS` (the Global Constraints values, as `{label:, start:, end:}`).
    - `RECENT_YEAR_COUNT = 5`.
  - **Root element:** `div.modal-box[data-controller="books--filter"]` with these values:
    - `max-categories`, `max-countries` (from `FilterParams`);
    - `count-url` (`books_filters_count_path`);
    - `initial-count` (`total_count`).
  - **Store:** inside the `<form>`, `<div hidden data-books--filter-target="store">` holds one entry per applied filter:
    - categories: `<input type="hidden" name="category_slugs[]" value=slug data-store-entry data-axis="category" data-type=category.category_type data-name=name>`;
    - countries: the same shape with `name="country_slugs[]" data-axis="country" data-type="country"`.

    It is never inside a turbo-frame. The existing `ranking_configuration_id` and `collection` hidden fields stay.
  - **Levels:** `[data-books--filter-target="level"][data-level=<key>]`, with `root` plus one per row key. Every level except root is `hidden`.
  - **Root level:** one `button[data-action="books--filter#open"][data-level-target=<key>]` per row, each containing `[data-books--filter-target="summary"][data-type=<key>]`. The server renders the summary text: names joined with ", ", or "Any"; for the year, the existing `year_summary`. Below the rows, `link_to "Advanced search", helpers.new_saved_search_path`.
  - **Each type level:**
    - a Back button (`books--filter#back`);
    - for genre, country, subject and location, an `input[type=search][data-books--filter-target="query"][data-type=<key>]` with:
      - `data-mode="filter"` for genre and country, `data-mode="search"` for subject and location;
      - `data-action="input->books--filter#query keydown->books--filter#suppressEnter"`;
      - no `name`;
    - for subject and location, a chips container `[data-books--filter-target="chips"][data-type=<key>]` between the search box and the list;
    - the lazy `turbo-frame#books_filter_pane_<key>` with `data-books--filter-target="pane" data-type=<key> data-pane-src=<pane url>` and `data-action="turbo:frame-load->books--filter#frameLoaded"`, holding a spinner.
  - **Year level:**
    - an "Eras" group, then a "Best of a single year" group. Each is a `button[type=button][data-books--filter-target="yearPreset"][data-start][data-end][aria-pressed]` with `data-action="books--filter#pickYears"`.
    - Then the two number fields `year_start` and `year_end`, `data-books--filter-target="year"`, `data-action="input->books--filter#yearsChanged"`, and the hint.
  - **Layout:** content scrolls in its own region, `[data-books--filter-target="scroll"]` (`flex-1 min-h-0 overflow-y-auto`), and the footer sits after it, outside it. The modal box is `p-0 flex flex-col` with a max height that fits a phone (e.g. `max-h-[85dvh]`). The form is `flex flex-col min-h-0 flex-1`.
  - **Footer:**
    - `[data-books--filter-target="capNotice"]` (hidden, `role=status`);
    - `button[type=button][data-action="books--filter#clear"]` "Clear";
    - `button[type=submit][data-books--filter-target="submit"]` with the server-rendered text from `show_label(total_count)` ("Show 15,875 books" / "Show 1 book").

    The Cancel button and the Clear link are gone.

- [ ] **Step 1: Write the failing tests**
  - `store holds applied filters outside every turbo-frame` (`assert_selector "[data-books--filter-target='store'] input[name='category_slugs[]'][value='novels']"`, and `assert_no_selector "turbo-frame [data-store-entry]"`);
  - `store entries carry the category type`;
  - `the first page lists six rows in order` (map `data-level-target` → `%w[genre year audience country subject location]`);
  - `a collection hides the Origin row`;
  - `summaries show applied names per type` (novels → genre summary "Novels", politics → subject summary "Politics", genre summary excludes it);
  - `recent year buttons are the five years before this year` (with `travel_to Date.new(2026, 10, 22)`, the `data-start` values are `%w[2025 2024 2023 2022 2021]`, each with an equal `data-end`);
  - `eras carry their bounds` (`Before 1800` → `data-start=""`, `data-end="1799"`);
  - `the submit button shows the total`;
  - `the advanced search link points at the new saved search page`;
  - `subject and setting pages have chips containers; genre does not`.
- [ ] **Step 2: Run them and confirm they fail** (`bin/rails test test/components/books/filter_modal_component_test.rb`).
- [ ] **Step 3: Implement** the component and pass `total_count` from the index view. Use `ApplicationController.helpers.number_with_delimiter` or `helpers.number_with_delimiter` for the label.
- [ ] **Step 4: Run** `bin/rails test test/components/books test/controllers/books`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Books filter panel: six rows, store of applied filters, pinned footer"`

---

### Task 6: Stimulus controller and the filters E2E suite

**Files:**
- Modify (rewrite): `app/javascript/controllers/books/filter_controller.js`
- Modify (rewrite): `e2e/tests/books/filters.spec.ts`
- Modify: `e2e/tests/books/collections.spec.ts` (button name, `[data-level-target='genre']`, the pane frame id `books_filter_pane_genre`, `Show` instead of `Apply`)

**Interfaces:**
- Consumes: the Task 5 DOM contract, the Task 4 option-row attributes, and the Task 3 count URL.
- Produces: the public actions `open`, `back`, `toggle`, `removeChip`, `query`, `suppressEnter`, `pickYears`, `yearsChanged`, `clear` and `frameLoaded`, plus `discard` on the dialog's `close` event and on `turbo:before-cache`.

Behaviour (the implementer writes the bodies):
- **`connect`**
  - Snapshot `storeTarget.innerHTML` and the two year values.
  - Listen for the dialog's `close` event and for `document`'s `turbo:before-cache`; both call `discard`. Remove both listeners in `disconnect`.
  - Call `sync()`.
- **`open(key)`**
  - Show the level.
  - On first open, set the pane frame's `src` from `data-pane-src`.
  - Focus the level's search box or Back button. This is focus on *entering* a page, which is allowed.
- **`toggle`**
  - Add or remove the store entry for `(axis, slug)`. A new entry takes `type` and `name` from the checkbox's data.
  - Then call `sync()`. Never move or focus any element.
- **`sync()`** derives everything from the store:
  - every `input[data-filter-option]`'s `checked`;
  - `disabled` when unchecked and its axis is at cap (categories counted across all types, max `maxCategories`; countries `maxCountries`);
  - the cap notice text (`You can select up to N. Untick one to add another.`);
  - the chips for subject and location: each is a `badge` with a `button[type=button]` (`aria-label="Remove <name>"`, `data-action="books--filter#removeChip"`);
  - the root summaries per type, plus the year summary (keep `yearLabel`);
  - the year presets' `aria-pressed`, true only when both boxes equal the preset exactly, with blank matching an empty bound;
  - then `scheduleCount()`.
- **`query`**
  - `data-mode="filter"`: hide each `[data-filter-row]` in that pane whose `data-name` does not include the lowercased query (the `hidden` attribute). Show the pane's "no matches" line when none remain.
  - `data-mode="search"`: debounce 250 ms, then set the results frame's `src` to `results-src + "&q=" + encodeURIComponent(q)`, or clear it when the query is blank. Queue the query if the frame has not loaded yet, and flush it from `frameLoaded`, as today.
- **`frameLoaded`:** `sync()` plus the pending-search flush.
- **`pickYears`:** set the boxes from `data-start`/`data-end`, then `sync()`. **`yearsChanged`:** `sync()`.
- **`clear`:** empty the store, blank both years, then `sync()`.
- **`discard`**
  - Restore the store and year snapshot.
  - Blank the query inputs, unhide the filtered rows, and empty the results frames.
  - Cancel the debounce timers and pending searches.
  - Restore the submit text to `initialCount`, `sync()`, and show `root`.
- **`scheduleCount`**
  - Debounce 300 ms, then `fetch(countUrl + "?" + new URLSearchParams(new FormData(form)))` with an `AbortController` that aborts the previous request.
  - On `ok`, set the submit text to `Show N books` / `Show 1 book`, using `toLocaleString("en-US")`.
  - On error or abort, leave the text as it is.
  - Skip the fetch when the form is unchanged since the last count, or since connect.
- **`suppressEnter`:** keep as is.

- [ ] **Step 1: Write the E2E suite first.** Replace `e2e/tests/books/filters.spec.ts`. Use the dev database's real data, as the current suite does, and an `openPanel` helper that clicks the button named `/Filter/`. Tests:
  - `the trigger reads "Filter books" unfiltered and shows a count when filtered` (`/` vs `/the-greatest/novels/books/written-by/french/authors` → badge `2`).
  - `the first page lists Genre, Published, Audience, Origin, Subject, Setting`.
  - `no page is fetched until it is opened` (adapt the existing request-listener test to `/filters/categories?type=genre`).
  - `Show without opening a page keeps the filters` (the existing structural test, retargeted at the button named `/^Show/`, waiting on `networkidle`).
  - `ticking a genre does not move it or scroll the list`: open Genre and scroll the `[data-books--filter-target="scroll"]` region to a row about 20 rows down. Record the region's `scrollTop` and the row's `boundingBox().y`, tick the row, wait one animation frame, and assert both are unchanged.
  - `ticking a subject search result does not move it or scroll the list`: open Subject, search a term with several results, tick the last result, and assert the same invariants. Also assert that a chip with that name appeared.
  - `a ticked search result survives the next search as a chip`: tick a result, search something else, and assert the chip is still there. Then press Show and assert the URL contains the slug.
  - `typing on the Genre page narrows the list without a request` (no `/filters/categories` request after typing).
  - `the category cap spans pages and later search results`: tick 5 genres and 1 subject, open Subject, run a new search, and assert every unticked result checkbox is disabled.
  - `the Show button count changes after a tick` (read the text before and after; it changes and matches `/^Show [\d,]+ books?$/`).
  - `an era fills the year boxes and a single year goes to /of/<year>` (click `Since 2000` → boxes `2000`/empty; click the first single-year button → Show → URL ends `/of/<that year>`).
  - `closing restores the applied selection, even after Clear`: on a filtered URL, open the panel, press Clear, press Escape, reopen, and assert the summaries show the applied names. Press Show and assert the URL is unchanged.
  - `pressing Enter in a search box does not submit`.
  - `chips on the page remove one filter at a time` (keep the existing test).
  - `the advanced search link opens the intro page when signed out` (lands on `/searches/new` with a `Login` button; Task 8 makes this pass, so leave it failing until then, or add it in Task 8).
  - `on a phone the footer buttons are visible on every page`: viewport 390×844; for each row, open it and assert `Clear` and the `/^Show/` button are `toBeInViewport()`.
- [ ] **Step 2: Build, check the port, and run the suite to see it fail.** Run `yarn build:all`, then the port-3000 ownership check from AGENTS.md, then `bin/rails server` in the background, then `yarn test:e2e --project=books e2e/tests/books/filters.spec.ts`. Expected: most tests fail, because the old JS doesn't match the new markup.
- [ ] **Step 3: Rewrite the Stimulus controller** to the behaviour above. Keep the file's habit of explaining *why* in comments; delete the comments about hoisting and twins.
- [ ] **Step 4: Update `collections.spec.ts`** to the new names and selectors.
- [ ] **Step 5: Rebuild and run** `yarn build:all && yarn test:e2e --project=books e2e/tests/books/filters.spec.ts e2e/tests/books/collections.spec.ts`. Expected: everything passes except the advanced-search test, if it was written now.
- [ ] **Step 6: Commit** `git commit -m "Books filter panel: store-driven Stimulus controller; ticking never moves a row"`

---

### Task 7: Bigger trigger button

**Files:**
- Modify: `app/components/books/filter_bar_component.rb` + `.html.erb`
- Test: `test/components/books/filter_bar_component_test.rb`

**Interfaces:**
- Produces: `FilterBarComponent#active_count -> Integer` (private is fine; test through the render).
  - It is `categories.size + countries.size + (year_start.present? || year_end.present? ? 1 : 0)`.
  - The button is a normal-size `btn btn-primary` with an inline SVG filter icon (`aria-hidden`).
  - It reads `Filter books` when `active_count` is 0. Otherwise it reads `Filters` plus `<span class="badge badge-sm" data-testid="filter-count">N</span>`.
  - The chips are unchanged. On phones they wrap below the button; on desktop they sit beside it.

- [ ] **Step 1: Write the failing tests**
  - `unfiltered, the button reads Filter books and shows no count` (`assert_button "Filter books"`, `assert_no_selector "[data-testid='filter-count']"`);
  - `filtered, the count includes categories, countries and one for any year range` (novels + french + 1900–2000 → `3`).
- [ ] **Step 2: Run them and confirm they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `bin/rails test test/components/books/filter_bar_component_test.rb`, then `yarn build:all` and the E2E trigger test from Task 6. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Books filter trigger: full-size button with an active-filter count"`

---

### Task 8: Advanced search intro page for signed-out visitors

**Files:**
- Modify: `app/controllers/saved_searches_controller.rb` (the before_actions at ~l.33-36)
- Create: `app/views/saved_searches/intro.html.erb`
- Test: `test/controllers/saved_searches_controller_test.rb`
- E2E: the advanced-search test in `e2e/tests/books/filters.spec.ts` (from Task 6)

**Interfaces:**
- **Signed-out `index` and `new`** (including `/searches/page/:page`, which routes to `index`) render `saved_searches/intro` with status 200 in the domain layout. They run after `require_domain_support!`, so a host without saved searches still 404s.
- **Every other action** keeps `require_signed_in!`.
- **Login:** the intro's Login button is `button.btn.btn-primary` with `onclick="login_modal.showModal()"`. The books layout's `Authentication::WidgetComponent` already has `reload_after_auth: true`, so a successful sign-in reloads the page into the form. No JS work is needed.
- **Copy:** an H1 "Advanced Search", a short paragraph, then a list built from what `app/views/saved_searches/books/_criteria_fields.html.erb` offers:
  - fiction or nonfiction;
  - book length;
  - publication years;
  - ranked only / top N;
  - genres, subjects and settings to include or exclude, matched with AND or OR;
  - languages to include or exclude;
  - countries of origin to include or exclude;
  - hide books you've read.

  Then "Save a search to come back to it later", and a sentence saying it needs a free account. Run the copy through the `avoid-ai-writing` skill before committing.
- **Page title:** `content_for :page_title, "Advanced Search | #{domain_name}"`.

- [ ] **Step 1: Write the failing tests**
  - `signed out, new renders the intro page` (`get "/searches/new"` on the books host → `assert_response :success` and `assert_select "button[onclick*='login_modal']"`);
  - `signed out, index renders the intro page`;
  - `signed out, create still redirects` (`post "/searches"` → `assert_response :redirect`);
  - `signed in, new renders the form` (`sign_in_as(user, stub_auth: true)` → `assert_select "form#saved-search-form"`).

  Delete or adapt any existing test that asserts signed-out `new` or `index` redirects.
- [ ] **Step 2: Run them and confirm they fail** (`bin/rails test test/controllers/saved_searches_controller_test.rb`).
- [ ] **Step 3: Implement** the `before_action :render_intro_unless_signed_in, only: [:index, :new]` (declared after `require_domain_support!`), narrow `require_signed_in!` to `[:create, :edit, :update, :destroy]`, and write the view.
- [ ] **Step 4: Run** the controller tests, then the E2E advanced-search test (`yarn build:all` first if anything changed). Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Saved searches: intro page with sign-in for signed-out visitors"`

---

### Task 9: Full verification

**Files:** none new. Fix whatever this turns up, in the task that owns the code.

- [ ] **Step 1:** `bin/rails test`. Expected: green, with no new warning lines (AGENTS.md).
- [ ] **Step 2:** `bundle exec standardrb`. Expected: no offences.
- [ ] **Step 3:** `bin/rails test test/lint/daisyui_v4_classes_test.rb`. Expected: PASS.
- [ ] **Step 4:** Check the port, then `yarn build:all && yarn test:e2e --project=books`. Expected: green, apart from failures that also fail on `main` (check `main` before blaming the branch).
- [ ] **Step 5:** Look at it by hand on a phone-sized viewport and on desktop: all six pages, the year page, the Show count, Clear, Escape, and Back after Show. Note anything off in the PR description.
- [ ] **Step 6: Commit** any fixes. Do not push or open a PR without asking the owner.
