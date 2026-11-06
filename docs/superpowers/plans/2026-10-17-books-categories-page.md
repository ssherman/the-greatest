# Books `/categories` Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the books category index from `/genres` to `/categories`, with page tabs, a labelled sort
dropdown, live search across all three types, and each child category's parent chain.

**Architecture:** This extends the existing `Books::BrowseController` / `Books::BrowseQuery` /
`Books::BrowsePath` stack; there is no new controller. Every `/genres` index URL becomes one route-level
301. Search is an uncached `GET /categories/search?q=`, which works without JavaScript. With JavaScript,
a small Stimulus controller submits it into a Turbo Frame as the reader types. The parent chains are
built by one recursive-CTE query object per page.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, Turbo Frames, Stimulus (Rollup
IIFE bundle `books_web.js`), daisyUI 5.7 / Tailwind 4, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-17-books-categories-page-design.md`. Read it first; this plan
argues from it.

## Global Constraints

- Run Rails and yarn commands from `web-app/`, and prefix every Ruby command with `mise exec --` (a
  worktree's PATH can carry the wrong Ruby).
- **Before the first test run in this worktree**, run `yarn build:all` and
  `mise exec -- bin/rails db:test:prepare`. Without the builds, every layout render fails with
  "asset not found".
- Lint is `mise exec -- bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.
- Counts are ranked books from `Books::RankingConfiguration.default_primary`, and search must use
  the same join and the same per-type minimum (`config.x.books.browse_min_category_books`, 5).
  Genres are exempt from the minimum.
- Type, sort and page are **path segments**. Only the uncached search endpoint takes a query string.
- New URL words: `/categories` (genre), `/categories/settings` (location), `/categories/subjects`
  (subject), `/sorted-by/name`, `/page/N`. The default sort (`book_count`) and page 1 never appear in
  a URL.
- Tab labels are `Genres` · `Settings` · `Subjects`. Sort labels are `Most books` · `A–Z`. The search
  placeholder is `Search categories…`.
- The chain separator is ` › ` (U+203A with a space either side), root first, excluding the category
  itself.
- The active tab and the active sort must be distinguishable without color: underline or weight,
  plus `aria-current`.
- daisyUI 5 only. Check every class against `docs/external-libraries/daisyui-llms.txt`.
  `test/lint/daisyui_v4_classes_test.rb` must stay green.
- Stimulus markup is a literal `data-controller="..."` attribute in a component `.html.erb`, and the
  controller is registered in `app/javascript/manifests/books_web.js`.
  `test/lint/stimulus_manifest_test.rb` must stay green.
- Capybara `text:` / `assert_text` match substrings. Pin exact copy with `exact_text:` on a scoped
  element.

## Review Focus

1. **LIKE metacharacters in a search** (`%`, `_`, `\`) must match literally, never as wildcards.
   Pinned in Task 1.
2. **A category found only through `alternative_names`** ("Gallia" → France) must appear in
   search. Pinned in Task 1.
3. **A `/genres` URL mixing path and query forms, or carrying junk** (`/genres?filter=theme`,
   `/genres/filtered-by/location?page=1`) must land on one valid `/categories` URL in one hop.
   Pinned in Task 3.
4. **An oversized or empty `q`** (500 characters, whitespace only, missing) must return 200 with no
   cards and no error. Pinned in Task 6.
5. **A card link inside the results frame must leave the frame.** Otherwise Turbo writes
   "Content missing", on both the grid and the search page. Pinned in Task 6.

---

### Task 1: Ranked category search query

**Files:**
- Modify: `web-app/app/lib/books/browse_query.rb`
- Modify: `web-app/app/lib/category_search_query.rb` (expose the name/alias SQL)
- Test: `web-app/test/lib/books/browse_query_test.rb`

**Interfaces:**
- Produces:
  - `Books::BrowseQuery.search(ranking_configuration:, query:, type: nil, limit: SEARCH_LIMIT)` →
    `ActiveRecord::Relation` of `Books::Category`, each row carrying `ranked_count`.
  - Constants `SEARCH_LIMIT = 60`, `SEARCH_MIN_LENGTH = 2`, `SEARCH_MAX_LENGTH = 100`.
  - `CategorySearchQuery::NAME_OR_ALIAS_SQL`, the existing `name_or_alias_sql` string promoted to a
    public constant. `CategorySearchQuery` uses it too.

- [ ] **Step 1: Write the failing tests** (append to `BrowseQueryTest`; reuse its `with_browse_minimum`
  helper and the setup's three ranked books)

```ruby
def search_for(query, **options)
  Books::BrowseQuery.search(ranking_configuration: @rc, query: query, **options)
end

def tag(category, book = books_books(:war_and_peace))
  CategoryItem.create!(category: category, item: book)
end

test "search matches all three types" do
  tag(categories(:books_americana_genre))
  tag(categories(:books_american_location))
  tag(categories(:books_american_history_subject))
  types = with_browse_minimum(1) { search_for("americ").map { |c| c.category_type.to_s }.sort }
  assert_equal %w[genre location subject], types
end

test "search puts the current type first" do
  # same three tags as above
  first = with_browse_minimum(1) { search_for("americ", type: "subject").first }
  assert_equal categories(:books_american_history_subject), first
end

test "search applies the ranked minimum to subjects and settings but not genres" do
  # same three tags, default minimum (5), one ranked book each
  assert_equal [categories(:books_americana_genre)], search_for("americ").to_a
end

test "search ignores a category none of whose books are ranked" do
  # tag books_americana_genre ONLY with a books fixture that has no RankedItem in @rc
  assert_empty search_for("americana").to_a
end

test "search matches alternative_names" do
  france = categories(:books_france_location)
  france.update!(alternative_names: ["Gallia"])
  tag(france)
  assert_equal [france], with_browse_minimum(1) { search_for("gall").to_a }
end

test "search treats LIKE metacharacters literally" do
  tag(categories(:books_american_history_subject))
  with_browse_minimum(1) do
    assert_empty search_for("%%").to_a
    assert_empty search_for("a_e").to_a     # as a wildcard, "a_e" matches "AMErican History"
    assert_empty search_for("a\\").to_a     # two characters, so it reaches the LIKE
  end
end

test "a query shorter than two characters after stripping returns nothing" do
  tag(categories(:books_americana_genre))
  assert_empty search_for("a").to_a
  assert_empty search_for("   ").to_a
  assert_empty search_for(nil).to_a
end

test "search caps results at the limit" do
  # the three tags from the first test
  assert_equal 1, with_browse_minimum(1) { search_for("americ", limit: 1).to_a.size }
end

test "search reports the same ranked_count as the grid" do
  politics = categories(:books_politics_subject)
  grid = with_browse_minimum(1) { categories_for(type: "subject").find { |c| c.id == politics.id } }
  hit = with_browse_minimum(1) { search_for("politic").find { |c| c.id == politics.id } }
  assert_equal grid.ranked_count, hit.ranked_count
end
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- bin/rails test test/lib/books/browse_query_test.rb`
Expected: the new tests ERROR with `NoMethodError: undefined method 'search'`. The existing tests still pass.

- [ ] **Step 3: Implement**
  - Extract a private `ranked_scope(ranking_configuration)` from `categories`. It covers the
    `active` + joined-count subquery + `select` + the genre-exempt minimum. Use it in both
    `categories` (adds `where(category_type:)` and the existing order) and `search`.
  - In `search`:
    - strip the query, then truncate it to `SEARCH_MAX_LENGTH`;
    - return `Books::Category.none` when it is shorter than `SEARCH_MIN_LENGTH`;
    - otherwise apply `CategorySearchQuery::NAME_OR_ALIAS_SQL` with
      `pattern: "%#{Books::Category.sanitize_sql_like(q)}%"`;
    - order by `(categories.category_type = <enum value of normalized_type(type)>) DESC`, then
      `ranked_counts.ranked_count DESC`, then `categories.name`;
    - apply `limit`.
  - Keep `ranked_book_ids_sql` as it is.

- [ ] **Step 4: Run them and confirm they pass**

Run: `mise exec -- bin/rails test test/lib/books/browse_query_test.rb test/lib/category_search_query_test.rb`
Expected: all PASS. (If `category_search_query_test.rb` lives elsewhere, find it with
`find test -name 'category_search_query_test.rb'`.)

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/books/browse_query.rb web-app/app/lib/category_search_query.rb web-app/test/lib/books/browse_query_test.rb
git commit -m "Browse: ranked category search across all three types"
```

---

### Task 2: Parent chains in one query

**Files:**
- Create: `web-app/app/lib/books/category_chains.rb`
- Test: `web-app/test/lib/books/category_chains_test.rb`

**Interfaces:**
- Produces: `Books::CategoryChains.call(categories)`. It takes an enumerable of `Books::Category`
  and returns a `Hash{Integer => Array<String>}` mapping category id to ancestor names, root first.
  Only categories with a non-empty chain get a key. Callers use `chains.fetch(id, [])`.

- [ ] **Step 1: Write the failing tests.** Build a tree in setup: `europe` (new location, no
  parent); `categories(:books_france_location)` with `parent: europe`; `idf` ("Île-de-France",
  parent France); `paris` (parent idf). Add `speculative` (a genre with `parent:
  categories(:books_fiction_genre)`) and `space_opera` (parent speculative).

```ruby
test "returns each category's ancestors root first" do
  chains = Books::CategoryChains.call([@paris, @france, @europe])
  assert_equal ["Europe", "France", "Île-de-France"], chains[@paris.id]
  assert_equal ["Europe"], chains[@france.id]
  assert_not chains.key?(@europe.id)
end

test "works for genres" do
  assert_equal ["Fiction", "Speculative Fiction"], Books::CategoryChains.call([@space_opera])[@space_opera.id]
end

test "stops at a soft-deleted ancestor" do
  @france.update_columns(deleted: true)
  assert_equal ["Île-de-France"], Books::CategoryChains.call([@paris])[@paris.id]
end

test "one query however many categories, none when nothing has a parent" do
  assert_queries_count(1) { Books::CategoryChains.call([@paris, @idf, @space_opera]) }
  assert_queries_count(0) { Books::CategoryChains.call([@europe]) }
end

test "a parent cycle written around the validation terminates" do
  @europe.update_columns(parent_id: @paris.id)
  chain = Books::CategoryChains.call([@paris])[@paris.id]
  assert_operator chain.size, :<=, Books::Category::MAX_DEPTH
end
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- bin/rails test test/lib/books/category_chains_test.rb`
Expected: ERROR `NameError: uninitialized constant Books::CategoryChains`

- [ ] **Step 3: Implement `Books::CategoryChains`** (a PORO with `self.call`, like `Books::BrowsePath`)
  - Collect the `parent_id`s, compacted. If there are none, return `{}` without querying.
  - Otherwise run one recursive CTE that walks upward from those ids, through non-deleted rows only,
    with depth ≤ `Books::Category::MAX_DEPTH`. Select `id, name, parent_id` (`DISTINCT`).
  - Build `nodes = {id => [name, parent_id]}`. For each category, walk from its `parent_id` through
    `nodes` to collect names. Stop on a missing node, after `MAX_DEPTH` steps, or on a revisited id.
    Reverse to root-first.
  - Add a header comment explaining why this exists: one query for a whole page, never
    `Category#ancestors` per card.

- [ ] **Step 4: Run them and confirm they pass**

Run: `mise exec -- bin/rails test test/lib/books/category_chains_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/books/category_chains.rb web-app/test/lib/books/category_chains_test.rb
git commit -m "Books::CategoryChains: every card's parent chain in one query"
```

---

### Task 3: Move the page to `/categories`, with one-hop redirects from `/genres`

**Files:**
- Modify: `web-app/app/lib/books/browse_path.rb`
- Modify: `web-app/config/routes.rb` (the browse block, roughly lines 1041–1074)
- Modify: `web-app/app/controllers/books/browse_controller.rb`
- Rename: `web-app/app/views/books/browse/genres.html.erb` → `categories.html.erb`
- Modify: `web-app/app/views/books/shared/_nav_links.html.erb` (add a "Categories" link after
  Authors), `web-app/app/components/footer_component.rb` ("Genres" → "Categories"),
  `web-app/app/components/books/filter_pane_component.rb` (path → `books_categories_path`, label →
  "Browse all categories")
- Test: `test/lib/books/browse_path_test.rb`, `test/routing/books_browse_routing_test.rb`,
  `test/controllers/books/browse_controller_test.rb`, `test/components/books/browse_toolbar_component_test.rb`,
  `test/components/books/filter_pane_component_test.rb`, `test/components/footer_component_test.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Books::BrowsePath.call(axis: :categories | :countries, type:, sort:, page:)`. Axis `:genres` is
    gone.
  - `Books::BrowsePath::TYPE_SEGMENTS = {"location" => "settings", "subject" => "subjects"}`.
  - `Books::BrowsePath.from_legacy_genres(path_params:, query_params:)` → String. Path params win
    over query params for `filter`/`sort`/`page`.
  - Route helper `books_categories_path` (→ `/categories`). `books_genres_path` and
    `books_genres_page_path` are removed.
  - Controller action `BrowseController#categories` (was `#genres`).

- [ ] **Step 1: Write the failing tests**
  - `browse_path_test.rb`: change every `axis: :genres` expectation to the new grammar:
    - `/categories`
    - `/categories/settings`
    - `/categories/subjects`
    - `/categories/sorted-by/name`
    - `/categories/subjects/sorted-by/name`
    - `/categories/page/3`
    - `/categories/settings/sorted-by/name/page/2`
    - page 1 / 0 / nil / "" / `["1"]` → `/categories`
    - junk type or `theme` → `/categories`
  - Add `from_legacy_genres` cases:

```ruby
{
  [{}, {}] => "/categories",
  [{filter: "location"}, {}] => "/categories/settings",
  [{filter: "subject", sort: "name", page: "2"}, {}] => "/categories/subjects/sorted-by/name/page/2",
  [{}, {"filter" => "location", "sort" => "name"}] => "/categories/settings/sorted-by/name",
  [{filter: "subject"}, {"filter" => "location"}] => "/categories/subjects",   # path wins
  [{}, {"filter" => "theme"}] => "/categories",
  [{filter: "location", page: "1"}, {}] => "/categories/settings"
}.each do |(path_params, query_params), expected|
  assert_equal expected, Books::BrowsePath.from_legacy_genres(path_params: path_params, query_params: query_params)
end
```

  - `books_browse_routing_test.rb`:
    - Every new shape routes to `books/browse#categories`, with `filter` set by the route default
      for `settings`/`subjects` and the `sort`/`page` params carried.
    - `/categories/sorted-by/nonsense`, `/categories/theme` and `/categories/settings/page/x` do
      not route.
    - `books_categories_path == "/categories"`.
    - `/genres/:id` still routes to `books/legacy_categories#show`.
  - `browse_controller_test.rb`:
    - Swap `/genres` for `/categories` in the existing tests. The cacheable, indexable, noindex and
      canonical assertions keep their meaning, with canonicals at the new paths.
    - Replace the query-form tests with these redirect cases:

```ruby
{
  "/genres" => "/categories",
  "/genres/page/2" => "/categories/page/2",
  "/genres/sorted-by/name" => "/categories/sorted-by/name",
  "/genres/filtered-by/genre" => "/categories",
  "/genres/filtered-by/location" => "/categories/settings",
  "/genres/filtered-by/subject/sorted-by/name/page/3" => "/categories/subjects/sorted-by/name/page/3",
  "/genres/filtered-by/location/page/1" => "/categories/settings",
  "/genres?filter=location&sort=name" => "/categories/settings/sorted-by/name",
  "/genres?filter=theme" => "/categories",
  "/categories?filter=subject" => "/categories/subjects",
  "/categories/page/1" => "/categories",
  "/categories/sorted-by/book_count" => "/categories",
  "/categories/settings/sorted-by/name/page/1" => "/categories/settings/sorted-by/name"
}.each do |from, to|
  test "#{from} redirects permanently to #{to} in one hop" do
    get from
    assert_response :moved_permanently
    assert_equal "http://#{host}#{to}", response.location
    # The target must not redirect again. Paged targets past the fixtures' last
    # page 404 by design (pagy_path), so only an unpaged target is followed.
    unless to.include?("/page/")
      get to
      assert_response :success
    end
  end
end

test "a redirect carries no edge-cache headers" do
  get "/categories/page/1"
  assert_no_match "public", response.headers["Cache-Control"].to_s
end
```

  - Component tests: the footer expects `a[href='/categories']` with text "Categories". The filter
    pane expects `a[href='/categories']`. In the toolbar test, change only the paths for now (the
    markup is redone in Task 5).

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- bin/rails test test/lib/books/browse_path_test.rb test/routing/books_browse_routing_test.rb test/controllers/books/browse_controller_test.rb test/components`
Expected: failures on every new path, and `NoMethodError` for `from_legacy_genres`.

- [ ] **Step 3: Implement**
  - **`BrowsePath`:**
    - `BASES = {categories: "/categories", countries: "/countries"}`;
    - `filter_segment` returns `"/#{TYPE_SEGMENTS.fetch(@type)}"` for a non-genre type;
    - `from_legacy_genres` merges `query_params.slice("filter", "sort", "page")` under the
      stringified path params and calls `call(axis: :categories, ...)`.
    - Update the class comment: this is no longer the legacy grammar.
  - **Routes:**
    - Replace the eight `/genres` routes with one redirect route:

      ```ruby
      get "genres(/filtered-by/:filter)(/sorted-by/:sort)(/page/:page)",
        constraints: {filter: browse_filter, sort: browse_sort, page: /\d+/},
        to: redirect { |path_params, req| Books::BrowsePath.from_legacy_genres(path_params: path_params, query_params: req.query_parameters) }
      ```

    - Keep `get "genres/:id"` **after** it.
    - Add, in this order:
      - `get "categories", to: "books/browse#categories", as: :books_categories`;
      - `categories(/sorted-by/:sort)(/page/:page)`;
      - `categories/settings(/sorted-by/:sort)(/page/:page)` with `defaults: {filter: "location"}`;
      - `categories/subjects(/sorted-by/:sort)(/page/:page)` with `defaults: {filter: "subject"}`;
      - all with the `browse_sort` / `\d+` constraints.
    - Rewrite the block comment: say why `/genres` now redirects (spec §5), and keep the
      "constraints are load-bearing" paragraph.
  - **`BrowseController`:**
    - Rename `genres` → `categories`. `@canonical_path` uses `axis: :categories`.
    - Generalize `redirect_to_canonical_form`: build `target = BrowsePath.call(axis:
      action_name.to_sym, type: params[:filter], sort: params[:sort], page: params[:page])`, and
      redirect 301 when any of `QUERY_FORM_KEYS` is in `request.query_parameters` **or** `target !=
      request.path`.
    - Keep its long comment, updated. Keep it above `cache_for_index_page`.
  - **View:** rename it and build each card's path with `Books::FilterPath.call(categories:
    [record])`.
  - **Links:** nav, footer and filter pane as listed under Files.

- [ ] **Step 4: Run them and confirm they pass**

Run: same command as Step 2, plus `test/controllers/books/legacy_categories_controller_test.rb`
Expected: all PASS. The legacy-categories test passes untouched.

- [ ] **Step 5: Lint and commit**

```bash
mise exec -- bundle exec standardrb app/lib/books config/routes.rb app/controllers/books app/components test
git add -A web-app/app web-app/config/routes.rb web-app/test
git commit -m "Move the books category index to /categories; /genres 301s there in one hop"
```

---

### Task 4: Cards show the parent chain; 2 columns on a phone

**Files:**
- Modify: `web-app/app/components/books/browse_card_component.rb`, `.html.erb`
- Modify: `web-app/app/controllers/books/browse_controller.rb` (`categories` sets `@chains`)
- Modify: `web-app/app/views/books/browse/categories.html.erb`
- Test: `test/components/books/browse_card_component_test.rb`, `test/controllers/books/browse_controller_test.rb`

**Interfaces:**
- Consumes: `Books::CategoryChains.call` (Task 2).
- Produces: `Books::BrowseCardComponent.new(record:, count:, path:, chain: [], label: nil)`. `label`
  is a short type name shown on search results (Task 6). The chain line carries
  `data-testid="browse-card-chain"`, because absence can't be targeted by role or text.

- [ ] **Step 1: Write the failing tests**

```ruby
# component
test "renders the chain root first with › separators" do
  render_inline(Books::BrowseCardComponent.new(record: categories(:books_france_location), count: 3,
    path: "/x", chain: ["Europe", "France", "Île-de-France"]))
  assert_selector "[data-testid=browse-card-chain]", exact_text: "Europe › France › Île-de-France"
end

test "no chain line when the chain is empty" do
  render_inline(Books::BrowseCardComponent.new(record: categories(:books_fiction_genre), count: 3, path: "/x"))
  assert_no_selector "[data-testid=browse-card-chain]"
end

test "shows the label when given" do
  render_inline(Books::BrowseCardComponent.new(record: categories(:books_politics_subject), count: 3,
    path: "/x", label: "Subject"))
  assert_text(/\bSubject\b/)
end

# controller (minimum already lowered to 1 in setup)
test "categories renders a child setting's chain" do
  europe = Books::Category.create!(name: "Europe", category_type: :location)
  categories(:books_france_location).update!(parent: europe)
  CategoryItem.create!(category: categories(:books_france_location), item: @book)
  get "/categories/settings"
  assert_select "[data-testid=browse-card-chain]", text: "Europe"
end

test "the chain costs the same queries for one child as for three" do
  # build: europe > france > paris and europe > germany > berlin, all tagged on @book (ranked)
  get "/categories/settings"   # warm-up: a per-process memo must not skew the baseline
  one = count_queries_for { get "/categories/settings" }   # with only France tagged
  # ...tag paris and berlin too...
  three = count_queries_for { get "/categories/settings" }
  assert_equal one, three
end
```

`count_queries_for` is a local helper that counts `sql.active_record` notifications for the block.
Use `ActiveSupport::Notifications.subscribed`, and ignore `SCHEMA` and `TRANSACTION` names. **Prove
the guard can fail:** temporarily render `record.ancestors.map(&:name)` in the view, watch the
test go red, then revert.

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- bin/rails test test/components/books/browse_card_component_test.rb test/controllers/books/browse_controller_test.rb`
Expected: `ArgumentError: unknown keyword: :chain`, and no chain in the controller HTML.

- [ ] **Step 3: Implement**
  - **Component:** the chain is a `<p>` (small, `text-base-content/60`) between the name and the
    count. The label is a small `badge badge-ghost badge-sm` before the name. Name and chain get
    `[overflow-wrap:anywhere]` so a card never widens.
  - **Controller:** `@chains = Books::CategoryChains.call(@records)` after pagination.
  - **View:** pass `chain: @chains.fetch(record.id, [])`, and set the grid to `grid grid-cols-2
    lg:grid-cols-3 gap-3 sm:gap-4`. The countries view keeps its grid.

- [ ] **Step 4: Run them and confirm they pass** (same command)

- [ ] **Step 5: Commit**

```bash
git add web-app/app/components/books/browse_card_component* web-app/app/controllers/books/browse_controller.rb web-app/app/views/books/browse/categories.html.erb web-app/test
git commit -m "Browse cards show the parent chain; two columns on a phone"
```

---

### Task 5: Toolbar: page tabs for the type, a labelled sort dropdown

**Files:**
- Modify: `web-app/app/components/books/browse_toolbar_component.rb`, `.html.erb`
- Modify: `web-app/app/views/books/browse/categories.html.erb`, `countries.html.erb` (drop the
  `flex justify-center` wrapper; the component lays itself out)
- Test: `test/components/books/browse_toolbar_component_test.rb`

**Interfaces:**
- Produces: `Books::BrowseToolbarComponent.new(axis:, sort:, type: nil, show_types: false)`, with the
  same signature. `SORT_LABELS = {"book_count" => "Most books", "name" => "A–Z"}`. Task 6 adds the
  search slot.

- [ ] **Step 1: Rewrite the component tests**

```ruby
test "tabs are links in a labelled nav, the active one marked" do
  render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "subject", sort: "name", show_types: true))
  assert_selector "nav[aria-label='Category type'] a.tab", count: 3
  assert_selector "a.tab.tab-active[aria-current=page][href='/categories/subjects/sorted-by/name']", exact_text: "Subjects"
  assert_selector "a.tab[href='/categories/settings/sorted-by/name']", exact_text: "Settings"
end

test "the sort dropdown names the current sort and links to both" do
  render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "location", sort: "book_count", show_types: true))
  assert_selector "details.dropdown summary", exact_text: "Sort: Most books"
  assert_selector "details.dropdown a[href='/categories/settings'][aria-current=page]", exact_text: "Most books"
  assert_selector "details.dropdown a[href='/categories/settings/sorted-by/name']", exact_text: "A–Z"
end

test "no link carries a query string" # keep the existing test, on axis :categories

test "countries gets the dropdown and no tabs" do
  render_inline(Books::BrowseToolbarComponent.new(axis: :countries, sort: "name"))
  assert_no_selector "nav[aria-label='Category type']"
  assert_selector "details.dropdown summary", exact_text: "Sort: A–Z"
  assert_selector "details.dropdown a[href='/countries']"
end
```

(If `summary` has an icon or a caret with text, wrap the label in a `<span>` and scope
`exact_text` to it, rather than reflowing the test.)

- [ ] **Step 2: Run it and confirm it fails**

Run: `mise exec -- bin/rails test test/components/books/browse_toolbar_component_test.rb`

- [ ] **Step 3: Implement**
  - **Tabs:** `<nav aria-label="Category type">` wrapping `<div class="tabs tabs-border
    justify-center">`, containing `link_to` with class `tab` (plus `tab-active` and
    `aria-current="page"` when active). Use no `role="tablist"`: these are page links, not ARIA
    tabs with panels.
  - **Toolbar row** below it: `flex flex-wrap items-center justify-end gap-3` (Task 6 puts the
    search on the left).
  - **Dropdown:** `<details class="dropdown dropdown-end">`. The `<summary class="btn btn-sm">`
    reads "Sort: <label>". `<ul class="dropdown-content menu bg-base-100 rounded-box z-10 w-40 p-2
    shadow-sm">` holds one `link_to` per sort, with `aria-current="page"` and `font-semibold` on
    the active one.
  - Check each class against the pinned daisyUI reference.

- [ ] **Step 4: Run the toolbar, browse controller and lint tests**

Run: `mise exec -- bin/rails test test/components/books test/controllers/books/browse_controller_test.rb test/lint`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add web-app/app/components/books/browse_toolbar_component* web-app/app/views/books/browse web-app/test/components/books/browse_toolbar_component_test.rb
git commit -m "Browse toolbar: page tabs for the type, a labelled sort dropdown"
```

---

### Task 6: Search endpoint, form and results frame (works without JavaScript)

**Files:**
- Modify: `web-app/config/routes.rb` (add `categories/search` directly after the bare `categories` route)
- Modify: `web-app/app/controllers/books/browse_controller.rb` (`search` action)
- Create: `web-app/app/views/books/browse/search.html.erb`
- Modify: `web-app/app/views/books/browse/categories.html.erb` (wrap the results in the frame)
- Modify: `web-app/app/components/books/browse_toolbar_component.rb`, `.html.erb` (search form)
- Modify: `web-app/app/models/books/category.rb` (`type_label`), `web-app/app/components/books/filter_option_rows_component.rb` (use it)
- Test: `test/controllers/books/browse_controller_test.rb`, `test/components/books/browse_toolbar_component_test.rb`, `test/models/books/category_test.rb`

**Interfaces:**
- Consumes:
  - `Books::BrowseQuery.search` (Task 1);
  - `Books::CategoryChains.call` (Task 2);
  - `BrowseCardComponent`'s `chain:` and `label:` (Task 4).
- Produces:
  - Route `books_categories_search_path` → `/categories/search`, with `GET q=`, `filter=`.
  - Frame id `categories_results`, constant `Books::BrowseToolbarComponent::RESULTS_FRAME`.
  - Toolbar keyword args `search: false, query: nil`. When `search` is true, it renders the form.
  - `Books::Category#type_label` → `"Setting"` for location; every other type gets its titleized
    name. This moves `FilterOptionRowsComponent::BADGE_LABELS` onto the model, so both components
    agree.

- [ ] **Step 1: Write the failing tests**

```ruby
# controller
test "search finds a category, uncached and noindex" do
  get "/categories/search", params: {q: "polit"}
  assert_response :success
  assert_select "turbo-frame#categories_results[target=_top] a[href='/the-greatest/politics/books']"
  assert_match "no-store", response.headers["Cache-Control"].to_s
  assert_select "meta[name=robots][content^=noindex]"
end

test "search labels each result with its type" do
  get "/categories/search", params: {q: "polit"}
  assert_select "#categories_results .badge", text: "Subject"
end

test "a missing, blank or oversized q renders without cards" do
  ["", "   ", nil, "x" * 500].each do |q|
    get "/categories/search", params: {q: q}.compact
    assert_response :success
    assert_select "#categories_results a[href^='/the-greatest/']", count: 0
  end
end

test "the browse grid sits in the same _top frame" do
  get "/categories"
  assert_select "turbo-frame#categories_results[target=_top]"
end

test "no frame-trapped links on the grid" do
  assert_no_frame_trapped_links "/categories"
end

test "no frame-trapped links on search results" do
  assert_no_frame_trapped_links "/categories/search?q=polit"
end

# toolbar component
test "search form targets the results frame and keeps the current type" do
  render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "location", sort: "name",
    show_types: true, search: true, query: "par"))
  assert_selector "form[action='/categories/search'][method=get][data-turbo-frame=categories_results]"
  assert_selector "input[type=search][name=q][value=par][placeholder='Search categories…']"
  assert_selector "input[type=hidden][name=filter][value=location]", visible: :all
  assert_selector "label", text: "Search categories", visible: :all   # accessible name
end

# model
test "type_label" do
  assert_equal "Setting", categories(:books_france_location).type_label
  assert_equal "Subject", categories(:books_politics_subject).type_label
  assert_equal "Genre", categories(:books_fiction_genre).type_label
end
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `mise exec -- bin/rails test test/controllers/books/browse_controller_test.rb test/components/books test/models/books/category_test.rb`

- [ ] **Step 3: Implement**
  - **Controller:**
    - `before_action :redirect_to_canonical_form, :cache_for_index_page, except: :search`, and
      `before_action :prevent_caching, only: :search`. `find_ranking_configuration` stays for all
      actions.
    - `search` sets `@type = normalized_type(params[:filter])`, `@query = params[:q].to_s`,
      `@records = BrowseQuery.search(...).to_a`, `@chains`, `@indexable = false`, and `@page_title
      = "Search categories"`.
  - **Search view:** same layout as the categories view, with the toolbar (`search: true, query:
    @query`).
    - Inside `turbo_frame_tag "categories_results", target: "_top"`, put a status line with
      `aria-live="polite"`. It reads either:
      - "N categories match “query”";
      - "No categories match “query”."; or
      - when the stripped query is shorter than 2 characters, "Type at least 2 characters to
        search."
    - Below the status, the same card grid, with `label: record.type_label`.
  - **Categories view:** wrap the grid, the pagination and the empty state in `turbo_frame_tag
    "categories_results", target: "_top"`. Pass `search: true` to the toolbar.
  - **Toolbar form:**
    - `form_with url: helpers.books_categories_search_path, method: :get, data: {turbo_frame:
      RESULTS_FRAME}`, placed left in the row and full width below `sm`;
    - a daisyUI 5 `label.input` wrapping a magnifier icon and `<input type="search" name="q">`,
      plus an `sr-only` text "Search categories";
    - a hidden `filter` field holding the current type;
    - no visible submit button (Enter submits).
    - `form_with` emits no `utf8` or `authenticity_token` on GET. Confirm the URL is just
      `?q=&filter=`.
  - **`type_label`:** add it on the model, and have `FilterOptionRowsComponent` use it. Move that
    component's comment about "Setting" onto the model method.

- [ ] **Step 4: Run them and confirm they pass**

Run: `mise exec -- bin/rails test test/controllers/books test/components/books test/models/books`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add -A web-app/app web-app/config/routes.rb web-app/test
git commit -m "Category search: uncached /categories/search into a _top results frame"
```

---

### Task 7: Live search as you type (Stimulus)

**Files:**
- Create: `web-app/app/javascript/controllers/books/category_search_controller.js`
- Modify: `web-app/app/javascript/manifests/books_web.js` (register `books--category-search`)
- Modify: `web-app/app/components/books/browse_toolbar_component.html.erb`, `.rb` (wire the form)
- Test: `test/components/books/browse_toolbar_component_test.rb` (wiring), `test/lint` (manifest)

**Interfaces:**
- Consumes: frame id `categories_results` and the search form (Task 6).
- Produces:
  - Stimulus identifier `books--category-search` on the `<form>`, with values `frame` (String,
    the frame id) and `browseUrl` (String: the current browse path, `BrowsePath.call(axis:
    :categories, type:, sort:)`), and action `input->books--category-search#search` on the input.
  - Toolbar keyword `browse_path:` (String): the grid to restore when the box is cleared.
    - The categories view passes `request.path`. It is already canonical, because non-canonical
      forms 301 first, so it keeps the reader's sort and page.
    - The search view passes `Books::BrowsePath.call(axis: :categories, type: @type)`.

- [ ] **Step 1: Write the failing component test**

```ruby
test "the search form is wired to the live-search controller" do
  render_inline(Books::BrowseToolbarComponent.new(axis: :categories, type: "subject", sort: "book_count",
    show_types: true, search: true, browse_path: "/categories/subjects"))
  assert_selector "form[data-controller='books--category-search'][data-books--category-search-frame-value=categories_results][data-books--category-search-browse-url-value='/categories/subjects']"
  assert_selector "input[name=q][data-action~='input->books--category-search#search']"
end
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `mise exec -- bin/rails test test/components/books/browse_toolbar_component_test.rb`

- [ ] **Step 3: Implement the controller and register it**
  - `search()`: clear the pending timer, then set a 250 ms timer.
  - When the timer fires, read the trimmed value:
    - 2 or more characters → `this.element.requestSubmit()`, and set `this.searched = true`;
    - empty and `this.searched` → set the frame's `src` to `browseUrlValue` and reset `searched`;
    - 1 character → do nothing.
  - `disconnect()` clears the timer.
  - Match the existing `books/filter_controller.js` style: comments explain *why*.
  - Put `data-controller` in the template as a **literal attribute**.

- [ ] **Step 4: Build and run the lints**

Run: `yarn build:all && mise exec -- bin/rails test test/components/books test/lint`
Expected: PASS, and `stimulus_manifest_test` is green.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/javascript web-app/app/components/books web-app/app/views/books/browse web-app/test
git commit -m "Category search updates the results as you type"
```

---

### Task 8: Playwright coverage, docs, full verification

**Files:**
- Modify: `web-app/e2e/tests/books/browse.spec.ts`
- Modify: `docs/features/books-categories.md` (add a "Category index page" section: URLs, the
  redirects, search, chains, the ranked-count invariant)

- [ ] **Step 1: Rewrite `browse.spec.ts`.** Keep the country-card test, the "Origins" half of the
  footer test, and the filter-pane test (now `/Browse all categories/` → `/categories`). Replace
  the rest with:
  - **a genre card navigates** to its filter page (`/categories`; first `a[href^='/the-greatest/']`
    → one filter chip);
  - **the Subjects tab** goes to `/categories/subjects` and lists different cards;
  - **the sort dropdown**: open "Sort: Most books", click "A–Z", and expect the URL
    `/categories/sorted-by/name`;
  - **search as you type**: on `/categories`, fill `Search categories` with `fiction`, and expect a
    card linking `/the-greatest/fiction/books`. Clear the box and expect the original first card back;
  - **search finds another tab's category**: on `/categories`, type `europe`, and expect a card
    whose badge reads "Setting";
  - **old URLs redirect**: `/genres` → `/categories`, and `/genres/filtered-by/location` →
    `/categories/settings`;
  - **the top-nav "Categories" link** reaches `/categories`. On a phone the link sits in the drawer,
    so run this at the default desktop viewport.
  - **the footer "Categories" link** reaches `/categories`.

  The dev data is real, so assert on structure and on categories that certainly exist (Fiction,
  Europe), not on counts.

- [ ] **Step 2: Start this worktree's server, confirm it owns port 3000, then run the spec**

```bash
yarn build:all
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
# free → start it: setsid mise exec -- bin/rails server -p 3000 </dev/null &
# another checkout → STOP and tell Shane; do not kill it or use another port
yarn test:e2e --project=books books/browse.spec.ts
```

Expected: every test passes. If you started a server, stop it afterwards.

- [ ] **Step 3: Update `docs/features/books-categories.md`.**

- [ ] **Step 4: Full verification**

Run: `mise exec -- bin/rails test` and `mise exec -- bundle exec standardrb`
Expected: 0 failures, 0 errors, no new warning lines, and standardrb clean.

- [ ] **Step 5: Commit**

```bash
git add web-app/e2e/tests/books/browse.spec.ts docs/features/books-categories.md
git commit -m "Categories page: Playwright coverage and feature doc"
```
