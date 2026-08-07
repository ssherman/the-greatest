# Books legacy `/genres` routes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every legacy `/genres` and `/countries` URL resolve on the new books app — routing the filter/sort grammar verbatim onto the existing browse actions, and 301ing `/genres/:id` to the equivalent filter page.

**Architecture:** `Books::BrowseController` already reads `params[:filter]` and `params[:sort]`, and `Books::BrowseQuery.normalized_type` / `.normalized_sort` already accept exactly the legacy vocabulary, so the legacy path segments map onto the existing actions with no controller-action changes. A new `Books::BrowsePath` PORO builds those paths (mirroring `Books::FilterPath`), replacing the query-string construction in the toolbar and canonical. A new `Books::LegacyCategoriesController` 301s `/genres/:id` into `/the-greatest/:slug/books`.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, ViewComponent, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-07-books-legacy-genres-routes-design.md`

## Global Constraints

- Run every command from `web-app/`. Docs live at the project root, not `web-app/docs/`.
- Lint with `bundle exec standardrb`, never `bin/rubocop`. Never run brakeman.
- **Never run a destructive DB command against development.** The books data exists only in dev and takes hours to rebuild. `ActiveRecord::FixtureSet.create_fixtures` TRUNCATES.
- **No code comments unless the plan supplies them.** Where this plan gives a comment, copy it verbatim — each one records a landmine.
- Namespace all books code under `Books::`. Tests mirror the namespace (`module Books; class FooTest`).
- Services and query objects live in `app/lib/books/`, NOT `app/services/`.
- Use Rails generators for new controllers so the matching test file is created.
- Legal `sort` values are exactly `book_count` (default) and `name`. Legal `filter` values are exactly `genre` (default), `location`, `subject`. These come from `Books::BrowseQuery::SORTS` and `::TYPES` — read them from those constants, never re-spell them in application code.
- **Route segment constraints must not contain regexp anchors** (`\A`, `\z`, `^`, `$`) — Rails anchors segment constraints itself and raises `ArgumentError` on an anchored one.
- **`assert_recognizes` ignores `host!`** — always pass a full `http://#{HOST}/path` or negative cases pass vacuously.
- `HOST` in routing tests is `Rails.application.config.domains[:books]`.
- Commit after each task with a message body explaining *why*, ending with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/books/browse_path.rb` (create) | Build a browse path from axis/type/sort/page. Pure, no DB. |
| `config/routes.rb` (modify, lines 451-455) | The 13 legacy browse routes, replacing the current 4. |
| `app/controllers/books/legacy_categories_controller.rb` (create) | 301 `/genres/:id` → `/the-greatest/:slug/books`. |
| `app/components/books/browse_toolbar_component.rb` (modify) | Take `axis:` instead of `base_path:`; delegate path building to `BrowsePath`. |
| `app/views/books/browse/genres.html.erb` (modify, line 12) | Pass `axis:` to the toolbar. |
| `app/views/books/browse/countries.html.erb` (modify, line 11) | Pass `axis:` to the toolbar. |
| `app/controllers/books/browse_controller.rb` (modify) | Canonical via `BrowsePath`; collapse the query-string form. |

---

### Task 1: `Books::BrowsePath`

A pure path builder, mirroring `Books::FilterPath` (`app/lib/books/filter_path.rb`) — same `self.call(**)` + private-segment-methods shape.

**Files:**
- Create: `web-app/app/lib/books/browse_path.rb`
- Test: `web-app/test/lib/books/browse_path_test.rb`

**Interfaces:**
- Consumes: `Books::BrowseQuery.normalized_type(type)` → String, `Books::BrowseQuery.normalized_sort(sort)` → String, `Books::BrowseQuery::TYPES` → `%w[genre location subject]`, `Books::BrowseQuery::SORTS` → `%w[book_count name]`. All already exist in `app/lib/books/browse_query.rb`.
- Produces: `Books::BrowsePath.call(axis:, type: nil, sort: nil, page: nil)` → String path. `axis` is `:genres` or `:countries` (Symbol or String). Unknown axis raises `KeyError`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/books/browse_path_test.rb`:

```ruby
require "test_helper"

module Books
  class BrowsePathTest < ActiveSupport::TestCase
    test "the bare genres path omits every default" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "genre", sort: "book_count")
    end

    test "a non-default type becomes a filtered-by segment" do
      assert_equal "/genres/filtered-by/location", Books::BrowsePath.call(axis: :genres, type: "location")
      assert_equal "/genres/filtered-by/subject", Books::BrowsePath.call(axis: :genres, type: "subject")
    end

    test "a non-default sort becomes a sorted-by segment" do
      assert_equal "/genres/sorted-by/name", Books::BrowsePath.call(axis: :genres, sort: "name")
    end

    test "both axes compose in the legacy order" do
      assert_equal "/genres/filtered-by/subject/sorted-by/name",
        Books::BrowsePath.call(axis: :genres, type: "subject", sort: "name")
    end

    test "a page beyond the first appends a page segment last" do
      assert_equal "/genres/page/3", Books::BrowsePath.call(axis: :genres, page: 3)
      assert_equal "/genres/filtered-by/location/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :genres, type: "location", sort: "name", page: 2)
    end

    test "page one and below emit no page segment" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: 1)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: 0)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: nil)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: "")
    end

    # A path segment is unconstrained input from a URL. Normalizing here means an
    # unknown value can never reach a generated path, so it cannot mint a
    # soft-duplicate URL for a crawler to follow.
    test "an unknown type or sort collapses to the default rather than appearing in the path" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "nonsense", sort: "nonsense")
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "theme")
    end

    test "the countries axis has no type segment even when a type is passed" do
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries)
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries, type: "location")
      assert_equal "/countries/sorted-by/name", Books::BrowsePath.call(axis: :countries, sort: "name")
      assert_equal "/countries/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :countries, sort: "name", page: 2)
    end

    test "a string axis is accepted" do
      assert_equal "/genres", Books::BrowsePath.call(axis: "genres")
    end

    test "an unknown axis raises rather than emitting a wrong path" do
      assert_raises KeyError do
        Books::BrowsePath.call(axis: :authors)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/books/browse_path_test.rb`
Expected: FAIL — `NameError: uninitialized constant Books::BrowsePath`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/books/browse_path.rb`:

```ruby
module Books
  # Builds the legacy browse grammar (/genres/filtered-by/:filter/sorted-by/:sort).
  # Mirrors Books::FilterPath: the routes are unnamed, so this PORO is the only
  # place the grammar is spelled out. Values normalize through BrowseQuery, so an
  # unknown filter or sort collapses to the default instead of reaching a path.
  class BrowsePath
    BASES = {genres: "/genres", countries: "/countries"}.freeze

    def self.call(**options)
      new(**options).call
    end

    def initialize(axis:, type: nil, sort: nil, page: nil)
      @axis = axis.to_sym
      @base = BASES.fetch(@axis)
      @type = Books::BrowseQuery.normalized_type(type)
      @sort = Books::BrowseQuery.normalized_sort(sort)
      @page = page.to_i
    end

    def call
      "#{@base}#{filter_segment}#{sort_segment}#{page_segment}"
    end

    private

    def filter_segment
      return "" if @axis == :countries
      return "" if @type == Books::BrowseQuery::TYPES.first

      "/filtered-by/#{@type}"
    end

    def sort_segment
      return "" if @sort == Books::BrowseQuery::SORTS.first

      "/sorted-by/#{@sort}"
    end

    def page_segment
      (@page > 1) ? "/page/#{@page}" : ""
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/books/browse_path_test.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/browse_path.rb test/lib/books/browse_path_test.rb
git add app/lib/books/browse_path.rb test/lib/books/browse_path_test.rb
git commit -m "$(cat <<'EOF'
Add Books::BrowsePath to build the legacy browse grammar

The browse routes are about to become path-based rather than
query-string based, and like the 80 filter routes they will be unnamed.
This PORO becomes the single place the grammar is spelled out, mirroring
Books::FilterPath.

Values normalize through BrowseQuery on the way in, so an unknown filter
or sort collapses to the default instead of reaching a generated path.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The legacy route table

Replace the four current browse routes with thirteen. `books/legacy_categories#show` does not exist yet — Task 3 creates it. A route pointing at a missing controller is fine for `assert_recognizes`, which only resolves the path, so this task is independently testable.

**Files:**
- Modify: `web-app/config/routes.rb:451-455` (the `genres`/`countries` block)
- Test: `web-app/test/routing/books_browse_routing_test.rb` (create)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: routes `books/browse#genres`, `books/browse#countries` with `params[:filter]`, `params[:sort]`, `params[:page]`; and `books/legacy_categories#show` with `params[:id]`. Named helpers `books_genres_path`, `books_genres_page_path`, `books_countries_path`, `books_countries_page_path` survive unchanged.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/routing/books_browse_routing_test.rb`:

```ruby
require "test_helper"

class BooksBrowseRoutingTest < ActionDispatch::IntegrationTest
  HOST = Rails.application.config.domains[:books]

  BROWSE_CASES = [
    ["/genres", "genres", {}],
    ["/genres/page/2", "genres", {page: "2"}],
    ["/genres/sorted-by/name", "genres", {sort: "name"}],
    ["/genres/sorted-by/book_count/page/3", "genres", {sort: "book_count", page: "3"}],
    ["/genres/filtered-by/location", "genres", {filter: "location"}],
    ["/genres/filtered-by/subject/page/2", "genres", {filter: "subject", page: "2"}],
    ["/genres/filtered-by/subject/sorted-by/name", "genres", {filter: "subject", sort: "name"}],
    ["/genres/filtered-by/location/sorted-by/name/page/4",
      "genres", {filter: "location", sort: "name", page: "4"}],
    ["/countries", "countries", {}],
    ["/countries/page/2", "countries", {page: "2"}],
    ["/countries/sorted-by/name", "countries", {sort: "name"}],
    ["/countries/sorted-by/name/page/5", "countries", {sort: "name", page: "5"}]
  ].freeze

  BROWSE_CASES.each do |path, action, expected|
    test "routes #{path} to browse##{action}" do
      assert_recognizes(
        {controller: "books/browse", action: action}.merge(expected),
        {path: "http://#{HOST}#{path}", method: :get}
      )
    end
  end

  test "routes a category slug to the legacy show redirect" do
    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "fiction"},
      {path: "http://#{HOST}/genres/fiction", method: :get}
    )
  end

  # There is a real, active location category named "Page" (slug "page"), so the
  # bare path must resolve it while the paginated path stays pagination.
  test "the paginated genres path wins over the catch-all show route" do
    assert_recognizes(
      {controller: "books/browse", action: "genres", page: "2"},
      {path: "http://#{HOST}/genres/page/2", method: :get}
    )

    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "page"},
      {path: "http://#{HOST}/genres/page", method: :get}
    )
  end

  # There is a real, active subject category named "Search" (slug "search").
  # Legacy shadowed it with a JSON typeahead endpoint purely because collection
  # routes are declared before the member route; nothing points a JSON client at
  # this app, so it resolves as the category it is.
  test "the legacy search path resolves the category named Search" do
    assert_recognizes(
      {controller: "books/legacy_categories", action: "show", id: "search"},
      {path: "http://#{HOST}/genres/search", method: :get}
    )
  end

  # BrowseQuery.normalized_* silently falls back to the default for ANY input, so
  # without these constraints /genres/sorted-by/<anything> would be an unbounded
  # space of indexable soft-duplicates. An out-of-vocabulary sort must NOT reach
  # the controller -- it falls through to the show route, which 404s in Task 3.
  test "an out-of-vocabulary sort does not reach the browse action" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/genres/sorted-by/nonsense", method: :get)
    end

    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/sorted-by/nonsense", method: :get)
    end
  end

  test "an out-of-vocabulary filter does not reach the browse action" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/genres/filtered-by/theme", method: :get)
    end
  end

  test "a non-numeric page does not route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/page/abc", method: :get)
    end
  end

  # /countries has no legacy show route, so an unknown countries path must 404
  # rather than silently resolving something.
  test "there is no countries show route" do
    assert_raises ActionController::RoutingError do
      Rails.application.routes.recognize_path("http://#{HOST}/countries/french", method: :get)
    end
  end

  test "the bare browse helpers still generate the unparameterised paths" do
    assert_equal "/genres", Rails.application.routes.url_helpers.books_genres_path
    assert_equal "/genres/page/2", Rails.application.routes.url_helpers.books_genres_page_path(page: 2)
    assert_equal "/countries", Rails.application.routes.url_helpers.books_countries_path
    assert_equal "/countries/page/2", Rails.application.routes.url_helpers.books_countries_page_path(page: 2)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/routing/books_browse_routing_test.rb`
Expected: FAIL — the `sorted-by` / `filtered-by` / `genres/:id` cases raise `ActionController::RoutingError` because those routes do not exist yet.

- [ ] **Step 3: Replace the route block**

In `web-app/config/routes.rb`, replace exactly these five lines (currently at 451-455):

```ruby
    get "genres", to: "books/browse#genres", as: :books_genres
    get "genres/page/:page", to: "books/browse#genres", as: :books_genres_page, constraints: {page: /\d+/}

    get "countries", to: "books/browse#countries", as: :books_countries
    get "countries/page/:page", to: "books/browse#countries", as: :books_countries_page, constraints: {page: /\d+/}
```

with:

```ruby
    # Legacy browse grammar, ported verbatim so no /genres or /countries URL needs
    # a redirect: BrowseController already reads params[:filter] and params[:sort],
    # and route segments populate params exactly as query parameters do. Only the
    # bare forms are named -- Books::BrowsePath builds every parameterised path,
    # mirroring Books::FilterPath.
    #
    # The sort and filter constraints are LOAD-BEARING, not cosmetic:
    # BrowseQuery.normalized_* falls back to the default for any input, so an
    # unconstrained segment would turn /genres/sorted-by/<anything> into an
    # unbounded space of indexable soft-duplicates. Anchors (\A, \z, ^, $) raise
    # ArgumentError in a segment constraint -- Rails anchors them itself.
    browse_sort = /(?:book_count|name)/
    browse_filter = /(?:genre|location|subject)/

    get "genres", to: "books/browse#genres", as: :books_genres
    get "genres/page/:page", to: "books/browse#genres", as: :books_genres_page,
      constraints: {page: /\d+/}
    get "genres/sorted-by/:sort", to: "books/browse#genres",
      constraints: {sort: browse_sort}
    get "genres/sorted-by/:sort/page/:page", to: "books/browse#genres",
      constraints: {sort: browse_sort, page: /\d+/}
    get "genres/filtered-by/:filter", to: "books/browse#genres",
      constraints: {filter: browse_filter}
    get "genres/filtered-by/:filter/page/:page", to: "books/browse#genres",
      constraints: {filter: browse_filter, page: /\d+/}
    get "genres/filtered-by/:filter/sorted-by/:sort", to: "books/browse#genres",
      constraints: {filter: browse_filter, sort: browse_sort}
    get "genres/filtered-by/:filter/sorted-by/:sort/page/:page", to: "books/browse#genres",
      constraints: {filter: browse_filter, sort: browse_sort, page: /\d+/}

    # MUST stay last of the /genres routes: it matches any single segment, so every
    # path above has to be declared first to win. /genres/page resolves the real
    # location category named "Page"; /genres/page/2 stays pagination.
    get "genres/:id", to: "books/legacy_categories#show"

    get "countries", to: "books/browse#countries", as: :books_countries
    get "countries/page/:page", to: "books/browse#countries", as: :books_countries_page,
      constraints: {page: /\d+/}
    get "countries/sorted-by/:sort", to: "books/browse#countries",
      constraints: {sort: browse_sort}
    get "countries/sorted-by/:sort/page/:page", to: "books/browse#countries",
      constraints: {sort: browse_sort, page: /\d+/}
```

Note there is deliberately **no** `countries/:id` route — legacy `resources :countries` is `only: [:index]`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/routing/books_browse_routing_test.rb`
Expected: PASS, 20 runs, 0 failures.

- [ ] **Step 5: Confirm nothing else regressed**

Run: `bin/rails test test/routing test/controllers/books`
Expected: PASS. If `browse_controller_test.rb` fails here, stop and report — it should not; its query-string requests still work until Task 5.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb config/routes.rb test/routing/books_browse_routing_test.rb
git add config/routes.rb test/routing/books_browse_routing_test.rb
git commit -m "$(cat <<'EOF'
Route the legacy /genres and /countries grammar verbatim

Every legacy path in both families except the two bare index pages was
404ing. BrowseController already reads params[:filter] and params[:sort],
and BrowseQuery already normalizes exactly the legacy vocabulary, so the
segments map onto the existing actions with no controller changes.

The sort and filter constraints are load-bearing. normalized_* falls back
to the default for any input, so an unconstrained segment would make
/genres/sorted-by/<anything> an unbounded space of indexable
soft-duplicates -- the exact crawl trap this work exists to avoid.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `Books::LegacyCategoriesController`

301 `/genres/:id` to the filter page for that category. Legacy's show action rendered `BookListQuery.call(categories: [category])`, which is exactly what `/the-greatest/:slug/books` renders, so this is a redirect to existing content rather than a page to rebuild.

**Files:**
- Create: `web-app/app/controllers/books/legacy_categories_controller.rb`
- Test: `web-app/test/controllers/books/legacy_categories_controller_test.rb`

**Interfaces:**
- Consumes: the `get "genres/:id"` route from Task 2. `Books::FilterPath.call(categories: [category])` → String (exists at `app/lib/books/filter_path.rb`). `LegacyIdMap.lookup(model:, legacy_id:)` → Integer or nil (exists at `app/models/legacy_id_map.rb`).
- Produces: nothing later tasks consume.

- [ ] **Step 1: Generate the controller**

```bash
bin/rails generate controller books/legacy_categories show --skip-routes --no-helper
```

Delete the generated view file — this action only redirects:

```bash
rm -rf app/views/books/legacy_categories
```

- [ ] **Step 2: Write the failing test**

Overwrite the generated `web-app/test/controllers/books/legacy_categories_controller_test.rb` with:

```ruby
require "test_helper"

module Books
  class LegacyCategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
    end

    test "redirects a category slug to its filter page permanently" do
      get "/genres/fiction"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/fiction/books"
    end

    test "redirects a location category, not only a genre" do
      get "/genres/france"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/france/books"
    end

    test "redirects a subject category" do
      get "/genres/politics"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/politics/books"
    end

    # Legacy ids were NOT preserved -- CategoryMigrator is a fresh-id migrator --
    # so a numeric legacy id can only resolve through LegacyIdMap.
    test "redirects a numeric legacy id through the id map" do
      category = categories(:books_classics_genre)
      LegacyIdMap.record(model: "Books::Category", legacy_id: 987654, new_id: category.id)

      get "/genres/987654"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/classics/books"
    end

    # 206 books categories have a purely numeric slug. A slug must beat a
    # coincidentally equal legacy id, matching legacy's friendly.find ordering.
    # update_column, not update!: Category#should_generate_new_friendly_id? is
    # `slug.blank? || name_changed?`, so an explicit slug: on create is silently
    # overwritten from the name.
    test "a numeric slug wins over the same number as a legacy id" do
      collider = Books::Category.create!(name: "Collider Genre", category_type: :genre)
      collider.update_column(:slug, "555555")
      LegacyIdMap.record(
        model: "Books::Category", legacy_id: 555555, new_id: categories(:books_novels_genre).id
      )

      get "/genres/555555"

      assert_response :moved_permanently
      assert_redirected_to "/the-greatest/555555/books"
    end

    test "404s a soft-deleted category the way legacy does" do
      assert categories(:books_deleted_genre).deleted

      get "/genres/retired-genre"

      assert_response :not_found
    end

    test "404s a numeric legacy id that maps to a soft-deleted category" do
      LegacyIdMap.record(
        model: "Books::Category", legacy_id: 424242, new_id: categories(:books_deleted_genre).id
      )

      get "/genres/424242"

      assert_response :not_found
    end

    test "404s an unknown slug" do
      get "/genres/no-such-category-anywhere"

      assert_response :not_found
    end

    test "404s an unmapped numeric id" do
      get "/genres/99999999"

      assert_response :not_found
    end

    # Books::Category is STI-scoped. A music category must never resolve here.
    test "404s a category belonging to another domain" do
      music = categories(:music_rock_genre)
      assert_equal "Music::Category", music.type

      get "/genres/#{music.slug}"

      assert_response :not_found
    end
  end
end
```

All seven fixture names used above were verified to exist in `test/fixtures/categories.yml` when this plan was written. Confirm they still do before running — fixture names are semantic, not `one`/`two`:

```bash
grep -n "^books_fiction_genre:\|^books_novels_genre:\|^books_classics_genre:\|^books_politics_subject:\|^books_france_location:\|^books_deleted_genre:\|^music_rock_genre:" test/fixtures/categories.yml
```

Expected: 7 matches. Read the file to find a replacement if any is missing — never guess a fixture name.

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/controllers/books/legacy_categories_controller_test.rb`
Expected: FAIL — the generated action renders a missing template rather than redirecting.

- [ ] **Step 4: Write the implementation**

Overwrite `web-app/app/controllers/books/legacy_categories_controller.rb`:

```ruby
class Books::LegacyCategoriesController < ApplicationController
  # Legacy /genres/:id rendered BookListQuery.call(categories: [category]) --
  # exactly what /the-greatest/:slug/books renders -- so this redirects to
  # existing content rather than duplicating it.
  def show
    redirect_to Books::FilterPath.call(categories: [find_category!]),
      status: :moved_permanently
  end

  private

  # Slug before id, matching legacy's Category.active.friendly.find AND because
  # 206 books categories have a purely numeric slug that must beat a
  # coincidentally equal legacy id. Scoped to .active so the 21,191 soft-deleted
  # categories 404 the way legacy does.
  def find_category!
    Books::Category.active.find_by(slug: params[:id]) || find_by_legacy_id!
  end

  # Category ids were not preserved by the migration, so a numeric id resolves
  # through LegacyIdMap. find_by!(id:), never .find: Category uses friendly_id
  # with :finders, which resolves slugs before primary keys.
  def find_by_legacy_id!
    raise ActiveRecord::RecordNotFound unless /\A\d+\z/.match?(params[:id])

    new_id = LegacyIdMap.lookup(model: "Books::Category", legacy_id: params[:id])
    raise ActiveRecord::RecordNotFound if new_id.nil?

    Books::Category.active.find_by!(id: new_id)
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/controllers/books/legacy_categories_controller_test.rb`
Expected: PASS, 10 runs, 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/controllers/books/legacy_categories_controller.rb test/controllers/books/legacy_categories_controller_test.rb
git add app/controllers/books/legacy_categories_controller.rb test/controllers/books/legacy_categories_controller_test.rb
git commit -m "$(cat <<'EOF'
Redirect legacy /genres/:id to the equivalent filter page

Legacy's category show action rendered a ranked book list for one
category, which is what /the-greatest/:slug/books already renders --
so this is a 301 to existing content, not a second page competing with
the filter page for the same query.

Slug resolves before id, both to match legacy's friendly.find and
because 206 books categories have a purely numeric slug that must beat a
coincidentally equal legacy id. Ids were not preserved by the migration,
so numeric ids resolve through LegacyIdMap.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Switch the UI and canonical to the path form

The toolbar currently builds `?filter=&sort=` query strings. Move it onto `BrowsePath`, changing its interface from `base_path:` to `axis:` — it no longer appends to a base, it builds a structured path.

**Files:**
- Modify: `web-app/app/components/books/browse_toolbar_component.rb`
- Modify: `web-app/app/views/books/browse/genres.html.erb:11-13`
- Modify: `web-app/app/views/books/browse/countries.html.erb:11`
- Modify: `web-app/app/controllers/books/browse_controller.rb:17-41`
- Test: `web-app/test/components/books/browse_toolbar_component_test.rb` (modify)
- Test: `web-app/test/controllers/books/browse_controller_test.rb` (modify)
- Test: `web-app/e2e/tests/books/browse.spec.ts` (modify)

**Interfaces:**
- Consumes: `Books::BrowsePath.call(axis:, type: nil, sort: nil, page: nil)` from Task 1; the routes from Task 2.
- Produces: `Books::BrowseToolbarComponent.new(axis:, sort:, type: nil, show_types: false)` — `base_path:` is gone.

- [ ] **Step 1: Rewrite the component test**

Overwrite `web-app/test/components/books/browse_toolbar_component_test.rb`:

```ruby
require "test_helper"

module Books
  class BrowseToolbarComponentTest < ViewComponent::TestCase
    test "the default type and sort omit both segments from every active link" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres,
        type: Books::BrowseQuery::TYPES.first,
        sort: Books::BrowseQuery::SORTS.first,
        show_types: true
      ))

      assert_selector "a[href='/genres']", count: 2
    end

    test "a non-active link composes both axes into path segments" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "subject", sort: "name", show_types: true
      ))

      assert_selector "a[href='/genres/filtered-by/location/sorted-by/name']"
      assert_selector "a[href='/genres/filtered-by/subject']"
    end

    test "no link carries a query string" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "location", sort: "name", show_types: true
      ))

      page.all("a").each do |link|
        assert_not_includes link[:href], "?"
      end
    end

    test "show_types false omits the type group entirely" do
      render_inline(Books::BrowseToolbarComponent.new(
        axis: :genres, type: "genre", sort: "book_count", show_types: false
      ))

      assert_selector "[aria-label='Category type']", count: 0
    end

    test "the countries axis builds countries paths" do
      render_inline(Books::BrowseToolbarComponent.new(axis: :countries, sort: "name"))

      assert_selector "a[href='/countries']"
      assert_selector "a[href='/countries/sorted-by/name']"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/components/books/browse_toolbar_component_test.rb`
Expected: FAIL — `ArgumentError: missing keyword: :base_path` / `unknown keyword: :axis`.

- [ ] **Step 3: Rewrite the component**

Overwrite `web-app/app/components/books/browse_toolbar_component.rb`:

```ruby
module Books
  class BrowseToolbarComponent < ViewComponent::Base
    TYPE_LABELS = {"genre" => "Genres", "location" => "Settings", "subject" => "Subjects"}.freeze
    SORT_LABELS = {"book_count" => "Most books", "name" => "Name"}.freeze

    def initialize(axis:, sort:, type: nil, show_types: false)
      @axis = axis
      @sort = sort
      @type = type
      @show_types = show_types
    end

    private

    attr_reader :axis, :sort, :type, :show_types

    def type_links
      TYPE_LABELS.map do |value, label|
        {label: label, path: path_for(type: value, sort: sort), active: value == type}
      end
    end

    def sort_links
      SORT_LABELS.map do |value, label|
        {label: label, path: path_for(type: type, sort: value), active: value == sort}
      end
    end

    # Both axes ride in every link so the toggles compose. BrowsePath omits the
    # defaults, so the default view has exactly one URL rather than three.
    def path_for(type:, sort:)
      Books::BrowsePath.call(axis: axis, type: type, sort: sort)
    end
  end
end
```

`app/components/books/browse_toolbar_component.html.erb` needs no change — it only reads `type_links` and `sort_links`.

- [ ] **Step 4: Run the component test to verify it passes**

Run: `bin/rails test test/components/books/browse_toolbar_component_test.rb`
Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 5: Update the two views**

In `web-app/app/views/books/browse/genres.html.erb`, replace:

```erb
    <%= render Books::BrowseToolbarComponent.new(
          base_path: books_genres_path, type: @type, sort: @sort, show_types: true
        ) %>
```

with:

```erb
    <%= render Books::BrowseToolbarComponent.new(
          axis: :genres, type: @type, sort: @sort, show_types: true
        ) %>
```

In `web-app/app/views/books/browse/countries.html.erb`, replace:

```erb
    <%= render Books::BrowseToolbarComponent.new(base_path: books_countries_path, sort: @sort) %>
```

with:

```erb
    <%= render Books::BrowseToolbarComponent.new(axis: :countries, sort: @sort) %>
```

- [ ] **Step 6: Move the canonical onto `BrowsePath`**

In `web-app/app/controllers/books/browse_controller.rb`, replace these two lines in `#genres`:

```ruby
    filter = (@type == Books::BrowseQuery::TYPES.first) ? {} : {filter: @type}
    @canonical_path = paged? ? books_genres_page_path(page: page_number, **filter) : books_genres_path(**filter)
```

with:

```ruby
    # The sort is deliberately dropped: a sort variant is the same result set
    # reordered, so it canonicalizes to the unsorted path.
    @canonical_path = Books::BrowsePath.call(axis: :genres, type: @type, page: page_number)
```

and in `#countries` replace:

```ruby
    @canonical_path = paged? ? books_countries_page_path(page: page_number) : books_countries_path
```

with:

```ruby
    @canonical_path = Books::BrowsePath.call(axis: :countries, page: page_number)
```

`paged?` is now unused — delete the private method:

```ruby
  def paged?
    page_number > 1
  end
```

- [ ] **Step 7: Update the affected controller tests**

In `web-app/test/controllers/books/browse_controller_test.rb`, make exactly these six edits. Leave every other test alone.

Replace:

```ruby
    test "genres accepts a type filter" do
      get "/genres", params: {filter: "subject"}
```
with:
```ruby
    test "genres accepts a type filter" do
      get "/genres/filtered-by/subject"
```

Replace:
```ruby
    test "genres accepts a sort and its canonical omits it" do
      get "/genres", params: {sort: "name"}
```
with:
```ruby
    test "genres accepts a sort and its canonical omits it" do
      get "/genres/sorted-by/name"
```

Replace:
```ruby
    test "the canonical keeps the type because it is different content" do
      get "/genres", params: {filter: "subject"}

      assert_select "link[rel=canonical][href$='/genres?filter=subject']"
    end
```
with:
```ruby
    test "the canonical keeps the type because it is different content" do
      get "/genres/filtered-by/subject"

      assert_select "link[rel=canonical][href$='/genres/filtered-by/subject']"
    end
```

Replace:
```ruby
      get "/genres/page/2", params: {filter: "subject"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/page/2?filter=subject']"
```
with:
```ruby
      get "/genres/filtered-by/subject/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/filtered-by/subject/page/2']"
```

Replace:
```ruby
    test "a bogus sort falls back rather than erroring" do
      get "/genres", params: {sort: "nonsense"}

      assert_response :success
    end
```
with:
```ruby
    # The route constraint is what keeps /genres/sorted-by/<anything> from being
    # an unbounded space of indexable soft-duplicates of /genres.
    test "a bogus sort in the path is a 404, not a soft duplicate" do
      get "/genres/sorted-by/nonsense"

      assert_response :not_found
    end
```

Replace:
```ruby
    test "countries accepts a sort" do
      get "/countries", params: {sort: "name"}
```
with:
```ruby
    test "countries accepts a sort" do
      get "/countries/sorted-by/name"
```

- [ ] **Step 8: Run the controller and component tests**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb test/components/books/browse_toolbar_component_test.rb`
Expected: PASS, 0 failures.

If `assert_queries_count 4` in `"genres renders no N+1"` fails, stop and report the actual count rather than editing the number — nothing in this task should change the query count.

- [ ] **Step 9: Update the E2E spec**

In `web-app/e2e/tests/books/browse.spec.ts`, in the test `'the type toggle switches which categories are listed'`, replace:

```typescript
    await expect(page).toHaveURL(/filter=subject/);
```

with:

```typescript
    await expect(page).toHaveURL('/genres/filtered-by/subject');
```

- [ ] **Step 10: Run the E2E spec**

The E2E suite needs a local server. `bin/dev` self-terminates in a non-TTY shell, so build assets and boot the server directly:

```bash
yarn build:all
bin/rails server -p 3000
```

Then, in a separate shell: `yarn test:e2e e2e/tests/books/browse.spec.ts`
Expected: 5 passed.

If the server is already listening on port 3000, check what it is serving before trusting the run.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb app/components/books/browse_toolbar_component.rb app/controllers/books/browse_controller.rb test/components/books/browse_toolbar_component_test.rb test/controllers/books/browse_controller_test.rb
git add app/components/books/browse_toolbar_component.rb app/controllers/books/browse_controller.rb app/views/books/browse/genres.html.erb app/views/books/browse/countries.html.erb test/components/books/browse_toolbar_component_test.rb test/controllers/books/browse_controller_test.rb e2e/tests/books/browse.spec.ts
git commit -m "$(cat <<'EOF'
Publish the browse toolbar and canonical in the legacy path form

The toolbar built ?filter=&sort= query strings, which meant the site
published a second URL grammar alongside the legacy path form the routes
now serve. Move both the toolbar and the canonical onto BrowsePath so
there is exactly one shape.

The toolbar takes axis: instead of base_path: -- it no longer appends to
a base, it builds a structured path.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Collapse the query-string form

`?filter=` / `?sort=` URLs were live on the preview host and are still reachable. 301 them into the path form so there is one canonical shape, and so a crawler cannot mint query-string variants of pages this branch makes more crawlable.

**Files:**
- Modify: `web-app/app/controllers/books/browse_controller.rb`
- Test: `web-app/test/controllers/books/browse_controller_test.rb` (add tests)

**Interfaces:**
- Consumes: `Books::BrowsePath.call(axis:, type: nil, sort: nil, page: nil)` from Task 1; the routes from Task 2.
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

Append these tests to `web-app/test/controllers/books/browse_controller_test.rb`, immediately before the `private` keyword:

```ruby
    test "the query string form redirects permanently to the path form" do
      get "/genres", params: {filter: "subject"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/filtered-by/subject"
    end

    test "both query axes collapse into one path" do
      get "/genres", params: {filter: "location", sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/filtered-by/location/sorted-by/name"
    end

    test "a query sort on countries collapses too" do
      get "/countries", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/countries/sorted-by/name"
    end

    test "a query page collapses to a path page" do
      get "/genres", params: {page: "2"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/page/2"
    end

    # A path page plus a query sort has to keep the page, which arrives as a
    # PATH parameter rather than a query one.
    test "a query sort on an already-paged path keeps the page" do
      get "/genres/page/2", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/sorted-by/name/page/2"
    end

    # Junk normalizes away rather than 301ing to another junk URL.
    test "an unknown query value collapses to the bare path" do
      get "/genres", params: {filter: "nonsense", sort: "nonsense"}

      assert_response :moved_permanently
      assert_redirected_to "/genres"
    end

    test "a default query value collapses to the bare path without looping" do
      get "/genres", params: {filter: "genre", sort: "book_count"}

      assert_response :moved_permanently
      assert_redirected_to "/genres"

      get "/genres"

      assert_response :success
    end

    # The guard must read request.query_parameters, NOT params -- on a routed
    # path the values arrive as path parameters, and reading params would make
    # every one of these redirect to itself forever.
    test "a routed path with the same values does not redirect" do
      get "/genres/filtered-by/subject/sorted-by/name"

      assert_response :success
    end

    test "an unrelated query parameter does not trigger a redirect" do
      get "/genres", params: {utm_source: "newsletter"}

      assert_response :success
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb`
Expected: FAIL — the query-string requests return `200 OK` instead of `301`.

- [ ] **Step 3: Add the guard**

In `web-app/app/controllers/books/browse_controller.rb`, add the constant below the existing `TITLES` constant:

```ruby
  QUERY_FORM_KEYS = %w[filter sort page].freeze
```

and add this `before_action` **above** the existing `before_action :cache_for_index_page`, so a redirect halts the chain before the 6-hour cache headers are set:

```ruby
  before_action :collapse_query_form
```

Then add these private methods:

```ruby
  # PR #204 published /genres?filter=location before the legacy path grammar was
  # routed. Collapsing it leaves one canonical shape and stops a crawler minting
  # query-string variants of a page this branch makes more crawlable.
  #
  # request.query_parameters, NOT params: on a routed path such as
  # /genres/filtered-by/location the same values arrive as PATH parameters, and
  # reading params would redirect every routed request to itself forever.
  def collapse_query_form
    return if request.query_parameters.slice(*QUERY_FORM_KEYS).empty?

    redirect_to Books::BrowsePath.call(
      axis: action_name.to_sym,
      type: params[:filter],
      sort: params[:sort],
      page: params[:page]
    ), status: :moved_permanently
  end
```

`action_name` is `"genres"` or `"countries"`, which are exactly `Books::BrowsePath::BASES`' keys — an axis that is ever not one of those raises `KeyError` rather than silently building a wrong path.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Run the whole suite**

Run: `bin/rails db:test:prepare test`
Expected: 0 failures, 0 errors. Record the runs count — it should be the previous total plus roughly 51 (10 from Task 1, 20 from Task 2, 10 from Task 3, 2 net from Task 4, 9 from Task 5).

- [ ] **Step 6: Lint**

Run: `bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 7: Manually verify against the dev server**

With the server from Task 4 Step 10 running:

```bash
for p in /genres /genres/fiction /genres/page/2 /genres/page \
         "/genres/sorted-by/name" "/genres/filtered-by/location" \
         "/genres/filtered-by/subject/sorted-by/name" \
         "/genres/sorted-by/nonsense" "/genres?filter=subject" \
         /countries "/countries/sorted-by/name" "/countries/sorted-by/bogus"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: dev-new.thegreatestbooks.org" "http://localhost:3000$p")
  echo "$code  $p"
done
```

Expected: `200` for `/genres`, `/genres/page/2`, both `sorted-by/name`, both `filtered-by` paths and `/countries`; `301` for `/genres/fiction`, `/genres/page` and `/genres?filter=subject`; `404` for both `nonsense`/`bogus` paths.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/books/browse_controller.rb test/controllers/books/browse_controller_test.rb
git commit -m "$(cat <<'EOF'
Collapse the browse query-string form into the path form

PR #204 published /genres?filter=location before the legacy path grammar
was routed, so two URL shapes currently render the same page. 301 the
query form into the path form so there is one canonical shape, and so a
crawler cannot mint query-string variants of pages this branch makes
more crawlable.

The guard reads request.query_parameters rather than params: on a routed
path the same values arrive as path parameters, and reading params would
redirect every routed request to itself forever.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done when

- `bin/rails test` is green with roughly 51 more runs than before.
- `bundle exec standardrb` reports no offenses.
- `yarn test:e2e e2e/tests/books/browse.spec.ts` is 5/5.
- The Task 5 Step 7 curl table matches expectations exactly.
