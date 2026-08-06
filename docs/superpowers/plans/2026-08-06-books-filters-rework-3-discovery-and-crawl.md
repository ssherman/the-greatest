# Books Filters Rework — Increment 3: Discovery & Crawl Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the internal-link surface the legacy sidebar provided — with `/genres` and `/countries` browse pages — and make the filter space's crawl policy explicit, so the combinatorial tail stops being a crawl frontier.

**Architecture:** Two page-cached browse pages listing single-facet filter URLs, linked from the books footer and from each filter pane. A crawl-class predicate on `Books::FilterPath` (which already owns the grammar) feeds the existing `@indexable` flag, and two robots.txt lines disallow every comma-bearing filter path — the comma being exactly the class boundary, since `FilterPath` emits one only for a multi-valued segment.

**Tech Stack:** Rails 8.1, ViewComponent, pagy (path-based), DaisyUI 5 / Tailwind 4, Minitest, Playwright. Design spec: `docs/superpowers/specs/2026-08-05-books-filters-rework-design.md` §7 and §9. Increments 1 and 2 are merged on this branch.

## Global Constraints

- Run **all** commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Worktree `/home/shane/dev/the-greatest/.claude/worktrees/books-filters-typeahead`, branch **`worktree-books-filters-typeahead`**. Never `main`. Do not `cd` to the original repo root.
- Baseline entering this increment: **5623 runs, 0 failures**; `e2e/tests/books/filters.spec.ts` 16/16.
- The worktree shares the test database `the_greatest_test` — do not run tests concurrently with another worktree.
- **Use Rails generators.** Components: `bin/rails generate view_component:component Books::Foo` — note the `view_component:` prefix, the bare `generate component` form does not exist. Controllers: `bin/rails generate controller`.
- Namespace media code under `Books::`; tests mirror the namespace. Query objects live in `app/lib/books/`, **not** `app/services/`.
- **No code comments** unless recording a genuine landmine.
- Component tests may assert structural contracts but never class names, layout, or copy. Controller tests assert behavior.
- **THE DEVELOPMENT DATABASE IS NOT DISPOSABLE.** Never `db:drop`/`db:reset`/`db:schema:load`, never `ActiveRecord::FixtureSet.create_fixtures` (it TRUNCATES). **No migration or schema change in this increment.**
- Lint with `bundle exec standardrb`, **not** `bin/rubocop`. Never run brakeman.
- **Gate before "done":** `bin/rails test` passing and `bundle exec standardrb` clean.
- Every commit message ends with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## Existing interfaces you will use (do not recreate)

```ruby
Books::FilterPath.call(categories:, countries:, year_start:, year_end:, page:, ranking_configuration:)
Books::FilterParams.call(params)     # raises RecordNotFound on unknown slug / over cap
Books::FilterPath                    # already owns the URL grammar; the crawl predicate belongs here

# app/controllers/concerns/cacheable.rb
cache_for_index_page                 # expires_in 6.hours, public, stale_while_revalidate 1.hour + skips the session cookie
prevent_caching

# app/controllers/concerns/path_based_pagination.rb
pagy_path(collection, limit:)        # path-based /page/N, raises RecordNotFound past the last page
reject_paged_request!

# app/helpers/books/default_helper.rb
books_robots_content                 # already renders <meta name="robots">; reads @indexable and params[:ranking_configuration_id]
```

`Category` has `active`, `sorted_by_name`, `sorted_by_item_count`, and the `category_type` enum (`genre`/`location`/`subject`). `Books::Country` has `filterable`, `sorted_by_name`, `book_count`.

## Decisions this plan locks in

1. **`/genres` serves every category type**, selected by `?filter=genre|location|subject`, defaulting to `genre` — legacy's exact URL and param. `/countries` needs no type param.
2. **`?sort=book_count|name`**, defaulting to `book_count`. Sort is a view preference over identical content, so **the canonical omits it**; the type param is genuinely different content, so the canonical keeps it.
3. **Pagination uses the existing `/page/:n` path form**, not `?page=`, matching every other books index.
4. **Cards link to single-facet filter URLs only** — `/the-greatest/:slug/books` and `/the-greatest-books/written-by/:slug/authors`. That is class 1 in §9, the only class this increment creates a frontier for.
5. **Rows with `item_count`/`book_count` of zero are excluded.** They render as links to pages with no results, which is the thin-content shape the crawl policy exists to avoid.

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/books/filter_path.rb` *(modify)* | add `.indexable?` crawl-class predicate |
| `app/controllers/books/ranked_items_controller.rb` *(modify)* | fold the predicate into `@indexable` |
| `public/robots.txt` *(modify)* | two Disallow lines |
| `app/lib/books/browse_query.rb` *(new)* | paginatable, sorted, type-filtered relation for both browse pages |
| `app/controllers/books/browse_controller.rb` *(new)* | `#genres` and `#countries` |
| `app/components/books/browse_card_component.rb` + `.html.erb` *(new)* | one card: name, count, link |
| `app/components/books/browse_toolbar_component.rb` + `.html.erb` *(new)* | type and sort toggles |
| `app/views/books/browse/genres.html.erb`, `countries.html.erb` *(new)* | |
| `config/routes.rb` *(modify)* | 4 routes (2 pages × bare and `/page/:n`) |
| `app/views/layouts/books/application.html.erb` *(modify)* | footer links |
| `app/components/books/filter_pane_component.html.erb` *(modify)* | "Browse all …" link |
| `e2e/tests/books/browse.spec.ts` *(new)* | |

**Task order:** 1 crawl predicate + robots → 2 `BrowseQuery` → 3 `/genres` → 4 `/countries` → 5 footer + pane links → 6 E2E + gate.

---

### Task 1: Crawl-class predicate and robots.txt

**Files:**
- Modify: `app/lib/books/filter_path.rb`, `app/controllers/books/ranked_items_controller.rb`, `public/robots.txt`
- Test: `test/lib/books/filter_path_test.rb`, `test/controllers/books/ranked_items_controller_test.rb`

**Interfaces:**
- Produces: `Books::FilterPath.indexable?(categories:, countries:)` → `false` when `categories.size > 1` or `countries.size > 1`, else `true`. Class 1 (one facet) and class 2 (one category **plus** one country) both stay indexable; only the multi-value tail is excluded.

It lives on `FilterPath` because that class already owns the grammar and already receives the resolved filter set, so no caller has to learn the rule.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/books/filter_path_test.rb`, inside the class:

```ruby
    test "a single facet is indexable" do
      assert Books::FilterPath.indexable?(categories: [categories(:books_novels_genre)], countries: [])
      assert Books::FilterPath.indexable?(categories: [], countries: [books_countries(:french)])
    end

    test "no filters at all is indexable" do
      assert Books::FilterPath.indexable?(categories: [], countries: [])
    end

    test "one category plus one country stays indexable" do
      assert Books::FilterPath.indexable?(
        categories: [categories(:books_novels_genre)],
        countries: [books_countries(:french)]
      )
    end

    test "two categories are not indexable" do
      assert_not Books::FilterPath.indexable?(
        categories: [categories(:books_novels_genre), categories(:books_fiction_genre)],
        countries: []
      )
    end

    test "two countries are not indexable" do
      assert_not Books::FilterPath.indexable?(
        categories: [],
        countries: [books_countries(:french), books_countries(:japanese)]
      )
    end

    test "the comma in a path marks exactly the non-indexable set" do
      pairs = [
        [[categories(:books_novels_genre)], []],
        [[categories(:books_novels_genre), categories(:books_fiction_genre)], []],
        [[], [books_countries(:french), books_countries(:japanese)]]
      ]

      pairs.each do |cats, countries|
        path = Books::FilterPath.call(categories: cats, countries: countries)
        assert_equal !path.include?(","), Books::FilterPath.indexable?(categories: cats, countries: countries)
      end
    end
```

The last test is the load-bearing one: it pins the invariant the robots.txt rules depend on — a comma appears in the path **if and only if** the URL is non-indexable.

Append to `test/controllers/books/ranked_items_controller_test.rb`:

```ruby
  test "a multi-category filter URL is noindex" do
    get "/the-greatest/fiction,novels/books"

    assert_response :success
    assert_select "meta[name=robots][content*=noindex]"
  end

  test "a single-category filter URL is indexable" do
    RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

    get "/the-greatest/novels/books"

    assert_response :success
    assert_select "meta[name=robots][content=?]", /\Aindex/
  end
```

Check the existing file's `setup` block for the host and `@rc` names before writing these, and match them.

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/books/filter_path_test.rb test/controllers/books/ranked_items_controller_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'indexable?'`.

- [ ] **Step 3: Implement**

In `app/lib/books/filter_path.rb`, add above `def self.call`:

```ruby
    def self.indexable?(categories: [], countries: [])
      Array(categories).size <= 1 && Array(countries).size <= 1
    end
```

In `app/controllers/books/ranked_items_controller.rb`, change the final line of `#index` from
`@indexable = !@filtered || @ranked_books.any?` to:

```ruby
    @indexable = Books::FilterPath.indexable?(categories: @categories, countries: @countries) &&
      (!@filtered || @ranked_books.any?)
```

In `public/robots.txt`, add below the existing `Disallow` lines:

```
# Filter URLs combining two or more categories or countries. FilterPath emits a
# comma only for a multi-valued segment, so the comma is exactly that boundary.
Disallow: /the-greatest/*,*
Disallow: /*written-by/*,*
```

- [ ] **Step 4: Verify passing**

Run: `bin/rails test test/lib/books/filter_path_test.rb test/controllers/books/ranked_items_controller_test.rb`
Expected: all pass, including every pre-existing test in both files.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/filter_path.rb app/controllers/books/ranked_items_controller.rb
git add -A
git commit -m "$(cat <<'EOF'
Make the filter crawl policy explicit

Single-facet and one-category-plus-one-country URLs stay indexable; anything
combining two or more of either is noindex and robots-disallowed. FilterPath
emits a comma only for a multi-valued segment, so two Disallow lines cover
the whole tail, and a test pins that invariant.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Books::BrowseQuery`

**Files:**
- Create: `app/lib/books/browse_query.rb`
- Test: `test/lib/books/browse_query_test.rb`

**Interfaces:**
- Produces:
  ```ruby
  Books::BrowseQuery.categories(type: "genre", sort: "book_count")  # => ActiveRecord::Relation of Books::Category
  Books::BrowseQuery.countries(sort: "book_count")                  # => Relation of Books::Country
  Books::BrowseQuery::TYPES  # => %w[genre location subject]
  Books::BrowseQuery::SORTS  # => %w[book_count name]
  ```
  Returns an unpaginated **relation** so the controller can hand it to `pagy_path`. Tasks 3 and 4 call these.

Rules: active only; `item_count`/`book_count` greater than zero; `unknown` excluded from countries via `filterable`; unknown `type` or `sort` values fall back to the defaults rather than raising, since they arrive from user-editable query strings and a 404 on `?sort=nonsense` would be hostile. `sort: "book_count"` orders `<count> DESC, name ASC`; `sort: "name"` orders `name ASC`.

Note the public API says `book_count` for both axes even though the category column is `item_count` — the param name is legacy's and is shared by both pages; map it internally.

- [ ] **Step 1: Write the failing test**

Create `test/lib/books/browse_query_test.rb`:

```ruby
require "test_helper"

module Books
  class BrowseQueryTest < ActiveSupport::TestCase
    test "categories returns only the requested type" do
      types = Books::BrowseQuery.categories(type: "subject").map { |c| c.category_type.to_s }.uniq

      assert_equal ["subject"], types
    end

    test "categories defaults to genres" do
      types = Books::BrowseQuery.categories.map { |c| c.category_type.to_s }.uniq

      assert_equal ["genre"], types
    end

    test "an unknown type falls back to genre rather than raising" do
      assert_equal Books::BrowseQuery.categories.to_a, Books::BrowseQuery.categories(type: "nonsense").to_a
    end

    test "categories excludes soft-deleted rows" do
      assert_not_includes Books::BrowseQuery.categories.to_a, categories(:books_deleted_genre)
    end

    test "categories excludes rows with no items" do
      empty = Books::Category.create!(name: "Empty Genre", category_type: :genre, item_count: 0)

      assert_not_includes Books::BrowseQuery.categories.to_a, empty
    end

    test "categories excludes other media types" do
      assert_not_includes Books::BrowseQuery.categories(type: "genre").to_a, categories(:music_rock_genre)
    end

    test "categories sorts by count then name by default" do
      counts = Books::BrowseQuery.categories.map(&:item_count)

      assert_equal counts.sort.reverse, counts
    end

    test "categories sorts by name on request" do
      names = Books::BrowseQuery.categories(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "an unknown sort falls back to count rather than raising" do
      assert_equal Books::BrowseQuery.categories.to_a, Books::BrowseQuery.categories(sort: "nonsense").to_a
    end

    test "countries exclude the unknown bucket and empty rows" do
      slugs = Books::BrowseQuery.countries.map(&:slug)

      assert_not_includes slugs, "unknown"
      assert_not_includes slugs, "algerian"
      assert_includes slugs, "french"
    end

    test "countries sort by count then name by default" do
      counts = Books::BrowseQuery.countries.map(&:book_count)

      assert_equal counts.sort.reverse, counts
    end

    test "countries sort by name on request" do
      names = Books::BrowseQuery.countries(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "both return relations so the controller can paginate them" do
      assert_kind_of ActiveRecord::Relation, Books::BrowseQuery.categories
      assert_kind_of ActiveRecord::Relation, Books::BrowseQuery.countries
    end
  end
end
```

`algerian` has `book_count: 1` after increment 2's tie-break fixture change — **check `test/fixtures/books/countries.yml` before writing that assertion** and pick a genuinely zero-count country, or create one in the test.

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/books/browse_query_test.rb`
Expected: FAIL — uninitialized constant.

- [ ] **Step 3: Implement**

Create `app/lib/books/browse_query.rb`:

```ruby
module Books
  class BrowseQuery
    TYPES = %w[genre location subject].freeze
    SORTS = %w[book_count name].freeze

    def self.categories(type: nil, sort: nil)
      scope = Books::Category.active
        .where(category_type: normalized_type(type))
        .where("item_count > 0")

      (normalized_sort(sort) == "name") ? scope.order(name: :asc) : scope.order(item_count: :desc, name: :asc)
    end

    def self.countries(sort: nil)
      scope = Books::Country.filterable.where("book_count > 0")

      (normalized_sort(sort) == "name") ? scope.order(name: :asc) : scope.order(book_count: :desc, name: :asc)
    end

    def self.normalized_type(type)
      TYPES.include?(type.to_s) ? type.to_s : TYPES.first
    end

    def self.normalized_sort(sort)
      SORTS.include?(sort.to_s) ? sort.to_s : SORTS.first
    end
  end
end
```

- [ ] **Step 4: Verify passing**

Run: `bin/rails test test/lib/books/browse_query_test.rb`
Expected: all pass.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/browse_query.rb test/lib/books/browse_query_test.rb
git add app/lib/books/browse_query.rb test/lib/books/browse_query_test.rb
git commit -m "$(cat <<'EOF'
Add Books::BrowseQuery

Feeds the /genres and /countries browse pages. Returns relations so the
controller can paginate them, excludes zero-count rows because those link to
empty result pages, and falls back on unknown type/sort values rather than
404ing on a hand-edited query string.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `/genres`

**Files:**
- Create: `app/controllers/books/browse_controller.rb`, `app/views/books/browse/genres.html.erb`
- Create: `app/components/books/browse_card_component.{rb,html.erb}`, `app/components/books/browse_toolbar_component.{rb,html.erb}`
- Modify: `config/routes.rb`
- Test: `test/controllers/books/browse_controller_test.rb`, `test/components/books/browse_card_component_test.rb`

**Interfaces:**
- Consumes: `Books::BrowseQuery`, `pagy_path`, `cache_for_index_page`.
- Produces: `books_genres_path`, `books_genres_page_path`. Task 5 links to them.

`Books::BrowseCardComponent.new(record:, count:, path:)` renders one card — name, count, and a link to the single-facet filter URL. It takes an explicit `path:` so the same component serves both pages.

`Books::BrowseToolbarComponent.new(base_path:, type:, sort:, show_types:)` renders the type and sort toggles as links, so both work with JS off and give crawlers a bounded set of variants.

Routes to add inside the books `DomainConstraint` block:

```ruby
    get "genres", to: "books/browse#genres", as: :books_genres
    get "genres/page/:page", to: "books/browse#genres", as: :books_genres_page, constraints: {page: /\d+/}
```

- [ ] **Step 1: Write the failing tests**

Create `test/controllers/books/browse_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class BrowseControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
    end

    test "genres renders and links to single-facet filter URLs" do
      get "/genres"

      assert_response :success
      assert_select "a[href='/the-greatest/fiction/books']"
    end

    test "genres is edge cacheable" do
      get "/genres"

      assert_match "max-age", response.headers["Cache-Control"].to_s
      assert_match "public", response.headers["Cache-Control"].to_s
    end

    test "genres is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/genres"

      assert_select "meta[name=robots][content^=index]"
    end

    test "genres accepts a type filter" do
      get "/genres", params: {filter: "subject"}

      assert_response :success
      assert_select "a[href='/the-greatest/politics/books']"
    end

    test "genres accepts a sort and its canonical omits it" do
      get "/genres", params: {sort: "name"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres']"
    end

    test "the canonical keeps the type because it is different content" do
      get "/genres", params: {filter: "subject"}

      assert_select "link[rel=canonical][href$='/genres?filter=subject']"
    end

    test "a bogus sort falls back rather than erroring" do
      get "/genres", params: {sort: "nonsense"}

      assert_response :success
    end

    test "a page past the last is a 404" do
      get "/genres/page/9999"

      assert_response :not_found
    end

    test "genres renders no N+1" do
      assert_queries_count 3 do
        get "/genres"
      end
    end
  end
end
```

The `assert_queries_count` number is a placeholder — run it, read the actual count, and pin **that** value. The point is that adding a row must not add a query, so state the observed number and keep it.

Create `test/components/books/browse_card_component_test.rb`:

```ruby
require "test_helper"

module Books
  class BrowseCardComponentTest < ViewComponent::TestCase
    test "renders the name, a delimited count and the given path" do
      render_inline(Books::BrowseCardComponent.new(
        record: categories(:books_fiction_genre), count: 15875, path: "/the-greatest/fiction/books"
      ))

      assert_selector "a[href='/the-greatest/fiction/books']"
      assert_text "Fiction"
      assert_text "15,875"
    end

    test "works for a country too" do
      render_inline(Books::BrowseCardComponent.new(
        record: books_countries(:french), count: 1210, path: "/the-greatest-books/written-by/french/authors"
      ))

      assert_selector "a[href='/the-greatest-books/written-by/french/authors']"
      assert_text "French"
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb test/components/books/browse_card_component_test.rb`
Expected: routing errors and uninitialized constants.

- [ ] **Step 3: Generate the pieces**

```bash
bin/rails generate view_component:component Books::BrowseCard
bin/rails generate view_component:component Books::BrowseToolbar
```

- [ ] **Step 4: Implement**

`app/controllers/books/browse_controller.rb`:

```ruby
class Books::BrowseController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :cache_for_index_page

  TITLES = {
    "genre" => "Book Genres",
    "location" => "Book Settings",
    "subject" => "Book Subjects"
  }.freeze

  def genres
    @type = Books::BrowseQuery.normalized_type(params[:filter])
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    @indexable = true
    @page_title = TITLES.fetch(@type)
    @canonical_path = (@type == Books::BrowseQuery::TYPES.first) ? books_genres_path : books_genres_path(filter: @type)

    @pagy, @records = pagy_path(Books::BrowseQuery.categories(type: @type, sort: @sort), limit: 120)
  end
end
```

`app/components/books/browse_card_component.rb`:

```ruby
module Books
  class BrowseCardComponent < ViewComponent::Base
    def initialize(record:, count:, path:)
      @record = record
      @count = count
      @path = path
    end

    private

    attr_reader :record, :count, :path
  end
end
```

`app/components/books/browse_card_component.html.erb`:

```erb
<%= link_to path, class: "card bg-base-100 border border-base-300 hover:border-primary transition-colors" do %>
  <div class="card-body p-4">
    <h2 class="card-title text-base"><%= record.name %></h2>
    <p class="text-sm text-base-content/70"><%= pluralize(number_with_delimiter(count), "book") %></p>
  </div>
<% end %>
```

`app/components/books/browse_toolbar_component.rb`:

```ruby
module Books
  class BrowseToolbarComponent < ViewComponent::Base
    TYPE_LABELS = {"genre" => "Genres", "location" => "Settings", "subject" => "Subjects"}.freeze
    SORT_LABELS = {"book_count" => "Most books", "name" => "Name"}.freeze

    def initialize(base_path:, sort:, type: nil, show_types: false)
      @base_path = base_path
      @sort = sort
      @type = type
      @show_types = show_types
    end

    private

    attr_reader :base_path, :sort, :type, :show_types

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

    # Both axes ride in every link so the toggles compose, and the defaults are
    # omitted so the default view has exactly one URL rather than three.
    def path_for(type:, sort:)
      query = {}
      query[:filter] = type if type.present? && type != Books::BrowseQuery::TYPES.first
      query[:sort] = sort if sort.present? && sort != Books::BrowseQuery::SORTS.first

      query.any? ? "#{base_path}?#{query.to_query}" : base_path
    end
  end
end
```

`app/components/books/browse_toolbar_component.html.erb`:

```erb
<div class="flex flex-wrap items-center gap-4">
  <% if show_types %>
    <div class="join" role="group" aria-label="Category type">
      <% type_links.each do |link| %>
        <%= link_to link[:label], link[:path],
              class: "btn btn-sm join-item #{"btn-active" if link[:active]}",
              aria: {current: (link[:active] ? "true" : nil)} %>
      <% end %>
    </div>
  <% end %>

  <div class="join" role="group" aria-label="Sort by">
    <% sort_links.each do |link| %>
      <%= link_to link[:label], link[:path],
            class: "btn btn-sm join-item #{"btn-active" if link[:active]}",
            aria: {current: (link[:active] ? "true" : nil)} %>
    <% end %>
  </div>
</div>
```

`app/views/books/browse/genres.html.erb`:

```erb
<%
  content_for :page_title, "#{@page_title} | The Greatest Books"
  content_for :meta_description, "Browse #{@page_title.downcase} and see how many books each covers."
  content_for :canonical_url, request.base_url + @canonical_path if @canonical_path
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance"><%= @page_title %></h1>

  <div class="flex justify-center">
    <%= render Books::BrowseToolbarComponent.new(
          base_path: books_genres_path, type: @type, sort: @sort, show_types: true
        ) %>
  </div>

  <% if @records.any? %>
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <% @records.each do |record| %>
        <%= render Books::BrowseCardComponent.new(
              record: record, count: record.item_count, path: "/the-greatest/#{record.slug}/books"
            ) %>
      <% end %>
    </div>

    <div class="flex justify-center">
      <%== @pagy.series_nav(slots: 5) %>
    </div>
  <% else %>
    <p class="text-center text-base-content/70 py-16">Nothing to browse here yet.</p>
  <% end %>
</div>
```

`count:` is passed explicitly rather than read inside the card because the two axes use different columns — `item_count` on `Books::Category`, `book_count` on `Books::Country`.

- [ ] **Step 5: Verify passing, then pin the query count**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb test/components/books/browse_card_component_test.rb`
Fix the `assert_queries_count` to the observed value and re-run.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "$(cat <<'EOF'
Add the /genres browse page

Restores the internal-link surface the legacy sidebar provided, as a
page-cached grid of single-facet filter URLs. Serves all three category
types via ?filter=, matching legacy's URL. The canonical keeps the type,
which is different content, and drops the sort, which is not.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `/countries`

**Files:**
- Modify: `app/controllers/books/browse_controller.rb`, `config/routes.rb`
- Create: `app/views/books/browse/countries.html.erb`
- Test: `test/controllers/books/browse_controller_test.rb` (add)

**Interfaces:**
- Produces: `books_countries_path`, `books_countries_page_path`.

Routes:

```ruby
    get "countries", to: "books/browse#countries", as: :books_countries
    get "countries/page/:page", to: "books/browse#countries", as: :books_countries_page, constraints: {page: /\d+/}
```

The action mirrors `#genres` without the type axis: `@sort`, `@indexable = true`, `@page_title = "Book Origins"`, `@canonical_path = books_countries_path`, and `pagy_path(Books::BrowseQuery.countries(sort: @sort), limit: 120)`. The view is `genres.html.erb` with `show_types: false` and card paths of `/the-greatest-books/written-by/#{record.slug}/authors`.

Use the label **"Origins"** in the H1 and toolbar, matching increment 2's modal copy — the page is about a book's national tradition, not the author's birthplace. The URL stays `/countries` because that is legacy's.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/books/browse_controller_test.rb`:

```ruby
    test "countries renders and links to single-facet filter URLs" do
      get "/countries"

      assert_response :success
      assert_select "a[href='/the-greatest-books/written-by/french/authors']"
    end

    test "countries excludes the unknown bucket" do
      get "/countries"

      assert_select "a[href*='written-by/unknown']", false
    end

    test "countries is edge cacheable and indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/countries"

      assert_match "public", response.headers["Cache-Control"].to_s
      assert_select "meta[name=robots][content^=index]"
    end

    test "countries accepts a sort" do
      get "/countries", params: {sort: "name"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries']"
    end

    test "a countries page past the last is a 404" do
      get "/countries/page/9999"

      assert_response :not_found
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb`
Expected: FAIL — no route matches `/countries`.

- [ ] **Step 3: Implement**

Add to `config/routes.rb`, beside the `genres` routes:

```ruby
    get "countries", to: "books/browse#countries", as: :books_countries
    get "countries/page/:page", to: "books/browse#countries", as: :books_countries_page, constraints: {page: /\d+/}
```

Add to `app/controllers/books/browse_controller.rb`:

```ruby
  def countries
    @sort = Books::BrowseQuery.normalized_sort(params[:sort])
    @indexable = true
    @page_title = "Book Origins"
    @canonical_path = books_countries_path

    @pagy, @records = pagy_path(Books::BrowseQuery.countries(sort: @sort), limit: 120)
  end
```

Create `app/views/books/browse/countries.html.erb`:

```erb
<%
  content_for :page_title, "#{@page_title} | The Greatest Books"
  content_for :meta_description, "Browse books by national origin and see how many books each covers."
  content_for :canonical_url, request.base_url + @canonical_path if @canonical_path
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance"><%= @page_title %></h1>

  <div class="flex justify-center">
    <%= render Books::BrowseToolbarComponent.new(base_path: books_countries_path, sort: @sort) %>
  </div>

  <% if @records.any? %>
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
      <% @records.each do |record| %>
        <%= render Books::BrowseCardComponent.new(
              record: record, count: record.book_count,
              path: "/the-greatest-books/written-by/#{record.slug}/authors"
            ) %>
      <% end %>
    </div>

    <div class="flex justify-center">
      <%== @pagy.series_nav(slots: 5) %>
    </div>
  <% else %>
    <p class="text-center text-base-content/70 py-16">Nothing to browse here yet.</p>
  <% end %>
</div>
```

Note `count: record.book_count` here versus `record.item_count` in `genres.html.erb` — different columns on the two models, which is why the card takes `count:` explicitly.

- [ ] **Step 4: Verify passing**

Run: `bin/rails test test/controllers/books/browse_controller_test.rb`
Expected: all pass, genres tests included.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb
git add -A
git commit -m "$(cat <<'EOF'
Add the /countries browse page

Mirrors /genres for the origin axis, linking to the written-by filter URLs
and excluding the unknown bucket. Labelled "Origins" to match the modal.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire the browse pages into the UI

**Files:**
- Modify: `app/views/layouts/books/application.html.erb` — footer links
- Modify: `app/components/books/filter_pane_component.html.erb` + `.rb` — "Browse all …" link
- Test: `test/components/books/filter_pane_component_test.rb`

The browse pages are the sole discovery surface for the single-facet long tail now that the sidebar is gone. Orphaned, they cannot do that job.

- [ ] **Step 1: Write the failing test**

Append to `test/components/books/filter_pane_component_test.rb`:

```ruby
    test "links out to the matching browse page" do
      render_pane(axis: :category)
      assert_selector "a[href='/genres']"

      render_pane(axis: :country, results_src: "/filters/countries")
      assert_selector "a[href='/countries']"
    end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/components/books/filter_pane_component_test.rb`
Expected: FAIL — no matching link.

- [ ] **Step 3: Implement**

In `app/components/books/filter_pane_component.rb`, add two private methods:

```ruby
    def browse_path
      (axis == "category") ? helpers.books_genres_path : helpers.books_countries_path
    end

    def browse_label
      (axis == "category") ? "Browse all genres" : "Browse all origins"
    end
```

In `app/components/books/filter_pane_component.html.erb`, insert between the browse container and the cap notice:

```erb
  <%= link_to browse_label, browse_path, class: "link link-primary text-sm mt-2",
        data: {turbo_frame: "_top"} %>
```

**The `data: {turbo_frame: "_top"}` is required.** This link sits inside the pane's turbo-frame, and Turbo navigates a link into its enclosing frame by default — so without `_top` the entire `/genres` page, layout and all, would render inside the pane. This is the same rule that makes the modal's form carry `data-turbo-frame="_top"`.

In `app/views/layouts/books/application.html.erb`, replace the footer block:

```erb
    <footer class="footer footer-center p-10 bg-base-300 text-base-content">
      <nav class="grid grid-flow-col gap-4">
        <%= link_to "Genres", books_genres_path, class: "link link-hover" %>
        <%= link_to "Origins", books_countries_path, class: "link link-hover" %>
        <%= link_to "Lists", books_lists_path, class: "link link-hover" %>
      </nav>
      <aside>
        <p>Copyright © 2026 - All rights reserved by <%= domain_name %></p>
      </aside>
    </footer>
```

Confirm `books_lists_path` exists before including that third link — it is in `config/routes.rb` as `books_lists`. If it is missing for any reason, drop that one link rather than inventing a route.

- [ ] **Step 3: Verify** — `bin/rails test test/components/books/ test/controllers/books/` all pass.

- [ ] **Step 4: Lint, rebuild, commit**

```bash
bundle exec standardrb
yarn build:all
git add -A
git commit -m "$(cat <<'EOF'
Link the browse pages from the footer and the filter panes

They are the only discovery surface for the single-facet long tail now that
the sidebar is gone, so they cannot be orphaned. The pane link deliberately
omits data-turbo-frame so it navigates the page rather than loading into
the pane.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: E2E and the gate

**Files:**
- Create: `e2e/tests/books/browse.spec.ts`

- [ ] **Step 1: Write the spec**

```ts
import { test, expect } from '@playwright/test';

test.describe('Books browse pages', () => {
  test('a genre card navigates to its filter page', async ({ page }) => {
    await page.goto('/genres');

    const card = page.locator("a[href^='/the-greatest/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('a country card navigates to its filter page', async ({ page }) => {
    await page.goto('/countries');

    const card = page.locator("a[href*='written-by/']").first();
    const href = await card.getAttribute('href');
    await card.click();

    await expect(page).toHaveURL(href!);
    await expect(page.getByTestId('filter-chip')).toHaveCount(1);
  });

  test('the type toggle switches which categories are listed', async ({ page }) => {
    await page.goto('/genres');
    const before = await page.locator("a[href^='/the-greatest/']").first().getAttribute('href');

    await page.getByRole('link', { name: 'Subjects' }).click();

    await expect(page).toHaveURL(/filter=subject/);
    expect(await page.locator("a[href^='/the-greatest/']").first().getAttribute('href')).not.toBe(before);
  });

  test('the footer links reach both browse pages', async ({ page }) => {
    await page.goto('/');

    await page.getByRole('contentinfo').getByRole('link', { name: 'Genres' }).click();
    await expect(page).toHaveURL('/genres');
  });

  test('the filter pane links out to the browse page', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Filters' }).click();
    await page.getByRole('button', { name: /Category/ }).click();

    await page.getByRole('link', { name: /Browse all genres/ }).click();

    await expect(page).toHaveURL('/genres');
  });
});
```

- [ ] **Step 2: Build, serve, run**

`bin/dev` self-terminates in a non-TTY shell — use `yarn build:all` then a background `bin/rails server`, and confirm port 3000 is this worktree's. Caddy proxies `dev-new.thegreatestbooks.org` → localhost:3000; the books routes are hostname-constrained.

Run both books specs: `yarn test:e2e e2e/tests/books/browse.spec.ts` and `yarn test:e2e e2e/tests/books/filters.spec.ts` (the latter must still be 16/16 — Task 5 modified the pane component).

- [ ] **Step 3: Full gate**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 4: Verify robots.txt is served**

```bash
curl -s -H "Host: dev-new.thegreatestbooks.org" http://localhost:3000/robots.txt
```

Confirm both new Disallow lines appear.

- [ ] **Step 5: Commit**

---

## Done when

- [ ] `bin/rails test` → 0 failures, 0 errors
- [ ] `bundle exec standardrb` → clean
- [ ] `e2e/tests/books/filters.spec.ts` 16/16 and `browse.spec.ts` passing
- [ ] `/genres` and `/countries` return 200, are edge-cacheable, indexable, and paginate on `/page/:n`
- [ ] A two-category filter URL renders `noindex`; a one-category one does not
- [ ] `/robots.txt` carries both Disallow lines
- [ ] Neither browse page is orphaned — both reachable from the footer and from the panes

## Landmines

- **`Books::FilterPath.indexable?` and the robots.txt rules must agree.** The comma-in-path test in Task 1 is what pins that; if it ever fails, one of the two has drifted and the tail is either crawlable or over-blocked.
- **Zero-count rows must be excluded** from both browse pages — they link to empty result pages, which is the thin content the crawl policy exists to prevent.
- **The pane's "Browse all" link MUST carry `data-turbo-frame="_top"`.** It sits inside the pane's turbo-frame, and Turbo navigates a link into its enclosing frame by default — without it, the whole `/genres` page renders inside the pane.
- **`pagy_path` raises past the last page on purpose** — an empty 200 would let a crawler mint unbounded thin pages that the 6-hour edge cache then stores.
- **`cache_for_index_page` skips the session cookie.** Never add anything user-specific to these pages; Cloudflare would cache one visitor's view for everyone.
- **`assert_queries_count` must be pinned to an observed number**, not a guess — the card grid renders counts in a loop, exactly the shape that regresses into an N+1.
- **`ActiveRecord::FixtureSet.create_fixtures` truncates every table it names.** Books data exists only in development and takes hours to rebuild.
- The worktree shares `the_greatest_test` with the main checkout — do not run tests concurrently.
