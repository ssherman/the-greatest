# Public Lists UI — Increment 2 (Books `/lists`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the books curated-list pages — `/lists` with sorting and search, `/lists/:id` with the weight breakdown and a paginated book grid, legacy 301s, and the book page's list links.

**Architecture:** A query object owns the index relation, a controller owns caching and indexability, and the two shared components from increment 1 do the rendering. `Books::CardComponent` is refactored from a `RankedItem` wrapper to a plain `book:`/`rank:` pair so the ranked index and the list show page can both use it.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, pagy 43 via `PathBasedPagination`, ViewComponent, Tailwind CSS 4 + DaisyUI 5, Playwright.

Spec: `docs/superpowers/specs/2026-08-01-lists-public-ui-design.md` ("Increment 2 — books `/lists`"). Increment 1 merged as PR #191 (merge `2d77d82`).

## Global Constraints

- **Run all Rails and yarn commands from `web-app/`.** Docs live at the project root.
- **Lint is `bundle exec standardrb`**, never `bin/rubocop`. **Never run `bin/brakeman`.**
- **The development database is not disposable.** Books data exists only in dev and takes hours to rebuild. A `PreToolUse` hook blocks `db:drop`/`db:reset`/`db:schema:load`, `create_fixtures`, and bulk `delete_all`/`update_all` in `rails runner`. `db:test:prepare` is allowlisted.
- **Use Rails generators** for controllers; never hand-create files a generator owns.
- **No code comments** unless this plan shows one explicitly.
- **Never use the `prose` class** — `@tailwindcss/typography` is not installed.
- **Escape all database-sourced content.** No `raw`, `html_safe`, or `simple_format(..., sanitize: false)`. A stored-XSS defect shipped from that pattern in an earlier increment.
- **Preload `{file_attachment: :blob}` on every `primary_image`**, and any `assert_queries_count` block must actually render a cover. Omitting it is a 200-query N+1 that already shipped once.
- Books views start at `<div class="space-y-8">` — the layout already provides `<main class="container mx-auto px-4 py-8">`. No second container.
- Grid ladder for book cards is exactly `grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6`.
- Index paginates at **50**; the show page's book grid paginates at **100**.
- Pagination is **full-page navigation**, never a Turbo Frame.
- Controller tests assert behavior — status codes, params, assigns. Never HTML, CSS, or copy.
- Commit after each task. Do not push and do not open a PR.

## Fixture landmines (verified 2026-08-01 against the test DB)

Two shared fixtures will silently produce wrong results if trusted:

1. **`list_items(:books_item).listable` is `nil`.** It declares `listable: one (Books::Book)`, but `test/fixtures/books/books.yml` has no `one` fixture — its first entry is `war_and_peace`. The label hashes to `listable_id: 980190962`, which matches no row. Polymorphic columns carry no foreign key, so nothing raises. **Do not build show-page tests on this fixture.** It is, however, a free test case for the nil-listable guard.
2. **`lists(:books_list).status` is `approved` (1), not `active` (3).** The index query filters to active, so this list does not appear. Tests must create their own active list rather than assume this one shows up.

Every task below creates its own records in `setup` rather than editing these shared fixtures — other suites depend on them.

## File structure

| File | Responsibility |
|---|---|
| `app/lib/books/lists_query.rb` (new) | builds the index relation: scope, sort whitelist, search |
| `app/controllers/books/lists_controller.rb` (new) | caching, indexability, pagination, rank lookup |
| `app/views/books/lists/index.html.erb` (new) | search form, sort links, card grid, pager |
| `app/views/books/lists/show.html.erb` (new) | list header, weight breakdown, book grid, pager |
| `app/components/books/card_component.rb` + `.html.erb` (modify) | takes `book:`/`rank:` instead of `ranked_item:` |
| `config/routes.rb` (modify) | 8 native routes + 9 legacy 301s |
| `app/views/books/ranked_items/index.html.erb` (modify) | updated card call site |
| `app/views/books/books/show.html.erb` (modify) | list names become links |
| `app/views/layouts/books/application.html.erb` (modify) | Lists nav entry, desktop + mobile |

---

### Task 1: Refactor `Books::CardComponent` to `book:` / `rank:`

The component currently wraps a `RankedItem`. The list show page has a book and a rank from a lookup hash, not a `RankedItem`, so the component must take them directly. `rank` is nullable and the badge is omitted when nil — today every book on an active books list is ranked, but the component must not depend on that.

Doing this first means both call sites in later tasks consume one stable interface.

**Files:**
- Modify: `app/components/books/card_component.rb`
- Modify: `app/components/books/card_component.html.erb`
- Modify: `app/views/books/ranked_items/index.html.erb:24`
- Test: `test/components/books/card_component_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Books::CardComponent.new(book:, rank:, index:)`. `book` is a `Books::Book`; `rank` is an Integer or `nil`; `index` is the zero-based position on the page, used only to pick the image loading strategy. Tasks 3 and 4 render it.

- [ ] **Step 1: Update the existing tests to the new interface**

In `test/components/books/card_component_test.rb`, replace every `Books::CardComponent.new(ranked_item: @ranked_item, index: N)` with `Books::CardComponent.new(book: @book, rank: 42, index: N)`. The `setup` block's `RankedItem.create!` is no longer needed — delete it, keeping `@book = books_books(:war_and_peace)`.

Then append a test for the nullable rank:

```ruby
test "omits the rank badge when the book has no rank" do
  render_inline(Books::CardComponent.new(book: @book, rank: nil, index: 0))

  assert_no_selector ".badge"
  assert_selector "a[href='/book/war-and-peace']", count: 1
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/components/books/card_component_test.rb
```

Expected: FAIL — `ArgumentError: missing keywords: :book, :rank` (the component still requires `ranked_item:`).

- [ ] **Step 3: Change the component class**

Replace the top of `app/components/books/card_component.rb`:

```ruby
class Books::CardComponent < ViewComponent::Base
  def initialize(book:, rank:, index:)
    @book = book
    @rank = rank
    @index = index
  end

  private

  attr_reader :book, :rank, :index
```

Delete the now-dead `ranked_item` attr_reader and the `def book` / `def rank` methods that derived from it. Leave `author_names`, `cover`, `loading_strategy` and `fetch_priority` exactly as they are.

- [ ] **Step 4: Guard the badge in the template**

In `app/components/books/card_component.html.erb`, wrap the rank badge:

```erb
    <div class="flex items-start justify-between gap-2">
      <% if rank %>
        <div class="badge badge-primary font-bold">
          <span class="sr-only">Rank </span>#<%= rank %>
        </div>
      <% end %>
      <% if book.first_published_year %>
        <span class="text-xs text-base-content/70"><%= book.first_published_year %></span>
      <% end %>
    </div>
```

- [ ] **Step 5: Update the ranked index call site**

`app/views/books/ranked_items/index.html.erb:24` becomes:

```erb
        <%= render Books::CardComponent.new(book: ranked_item.item, rank: ranked_item.rank, index: index) %>
```

- [ ] **Step 6: Run the component and ranked-index tests**

```bash
bin/rails test test/components/books/card_component_test.rb test/controllers/books/ranked_items_controller_test.rb
```

Expected: PASS. The controller test exercises the updated call site.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/components/books app/views/books test/components/books
bundle exec standardrb
git add app/components/books app/views/books/ranked_items test/components/books
git commit -m "Take book and rank directly in Books::CardComponent

The list show page has a book and a rank from a lookup hash, not a
RankedItem. rank is nullable so a future unranked book renders without a
badge instead of raising."
```

---

### Task 2: `Books::ListsQuery`

One object owning the index relation, following `Books::RankedBooksQuery`. Keeping it separate from the controller means increment 4's penalty filter changes one file.

**Files:**
- Create: `app/lib/books/lists_query.rb`
- Test: `test/lib/books/lists_query_test.rb`

**Interfaces:**
- Consumes: `List.search_text(query)` and `lists.activated_at`, both from increment 1.
- Produces: `Books::ListsQuery.call(ranking_configuration:, sort: "weight", query: nil)` → a `RankedList` relation, ordered, with `:list` preloaded. `Books::ListsQuery::SORTS` is `%w[weight newest]`. Task 3 paginates the result.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/books/lists_query_test.rb`:

```ruby
require "test_helper"

module Books
  class ListsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @heavy = create_list("Heavy List", weight: 90, activated_at: 3.days.ago, source: "Guardian")
      @light = create_list("Light List", weight: 10, activated_at: 1.day.ago, source: "Times")
    end

    test "returns active books lists in the ranking configuration ordered by weight" do
      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "excludes lists that are not active" do
      @light.list.update!(status: :unapproved)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id], result.map(&:list_id)
    end

    test "orders by activated_at descending for the newest sort" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@light.list_id, @heavy.list_id], result.map(&:list_id)
    end

    test "puts lists with no activated_at last in the newest sort" do
      @light.list.update_column(:activated_at, nil)

      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "falls back to weight for an unrecognised sort" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, sort: "'; DROP TABLE lists; --")

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "breaks weight ties by list id so pagination is stable" do
      tied = create_list("Tied List", weight: 90, activated_at: 5.days.ago)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, tied.list_id, @light.list_id].sort, result.map(&:list_id).sort
      assert_operator result.map(&:list_id).index(@heavy.list_id), :<, result.map(&:list_id).index(tied.list_id)
    end

    test "filters by search across name, source and url" do
      assert_equal [@light.list_id], Books::ListsQuery.call(ranking_configuration: @rc, query: "Times").map(&:list_id)
      assert_equal [@heavy.list_id], Books::ListsQuery.call(ranking_configuration: @rc, query: "heavy").map(&:list_id)
    end

    test "ignores a blank search" do
      result = Books::ListsQuery.call(ranking_configuration: @rc, query: "   ")

      assert_equal 2, result.size
    end

    test "excludes lists belonging to another ranking configuration" do
      other = Books::RankingConfiguration.create!(name: "Other", global: true, primary: false, algorithm_version: 1)
      create_list("Elsewhere", weight: 99, ranking_configuration: other)

      result = Books::ListsQuery.call(ranking_configuration: @rc)

      assert_equal 2, result.size
    end

    private

    def create_list(name, weight:, activated_at: Time.current, source: nil, ranking_configuration: nil)
      list = Books::List.create!(name: name, source: source, status: :active)
      list.update_column(:activated_at, activated_at)
      RankedList.create!(list: list, ranking_configuration: ranking_configuration || @rc, weight: weight)
    end
  end
end
```

`update_column` sets `activated_at` directly because the `before_save` callback from increment 1 would otherwise overwrite it with `Time.current` on every save.

`create_list` returns the **`RankedList`**, not the list — which is why every assertion compares `result.map(&:list_id)` against `@heavy.list_id` rather than `@heavy.id`. Those are different numbers; mixing them up produces tests that fail for the wrong reason.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/lib/books/lists_query_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Books::ListsQuery`.

- [ ] **Step 3: Write the query object**

Create `app/lib/books/lists_query.rb`:

```ruby
module Books
  class ListsQuery
    SORTS = %w[weight newest].freeze

    def self.call(ranking_configuration:, sort: "weight", query: nil)
      new(ranking_configuration: ranking_configuration, sort: sort, query: query).call
    end

    def initialize(ranking_configuration:, sort:, query:)
      @ranking_configuration = ranking_configuration
      @sort = SORTS.include?(sort.to_s) ? sort.to_s : "weight"
      @query = query
    end

    def call
      scope = @ranking_configuration.ranked_lists
        .joins(:list)
        .where(lists: {type: "Books::List", status: ::List.statuses[:active]})
        .includes(:list)

      scope = scope.where(list_id: ::List.search_text(@query).select(:id)) if @query.present?

      scope.order(Arel.sql(order_clause))
    end

    private

    def order_clause
      if @sort == "newest"
        "lists.activated_at DESC NULLS LAST, lists.id ASC"
      else
        "ranked_lists.weight DESC, lists.id ASC"
      end
    end
  end
end
```

`::List.statuses[:active]` rather than the `:active` symbol: the condition targets a joined table, and passing the integer removes any dependence on ActiveRecord resolving the enum through the association.

`Arel.sql` is required — Rails 8 raises `UnknownAttributeReference` for a raw string order containing `NULLS LAST`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/lib/books/lists_query_test.rb
```

Expected: PASS, 9 tests.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/books test/lib/books
bundle exec standardrb
git add app/lib/books/lists_query.rb test/lib/books/lists_query_test.rb
git commit -m "Add Books::ListsQuery

Owns the curated-list index relation: active books lists in the ranking
configuration, a two-value sort whitelist, and search over name, source
and url. Both orderings tiebreak on lists.id so pagination is stable --
273 books lists share a weight in the 0-10 bucket alone."
```

---

### Task 3: Routes, `Books::ListsController#index`, and the index view

**Files:**
- Create: `app/controllers/books/lists_controller.rb`
- Create: `app/views/books/lists/index.html.erb`
- Modify: `config/routes.rb` — inside the books `DomainConstraint` block, beside the existing `books_rc` routes
- Test: `test/controllers/books/lists_controller_test.rb`

**Interfaces:**
- Consumes: `Books::ListsQuery.call(ranking_configuration:, sort:, query:)` from Task 2; `Lists::CardComponent.new(ranked_list:, item_count:, path:, noun:)` from increment 1.
- Produces: route helpers `books_lists_path`, `books_lists_page_path(page)`, `books_list_path(id)`, `books_list_page_path(id, page)` and their `books_rc_*` equivalents. Tasks 4, 6 and 7 use `books_list_path`.

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside `constraints DomainConstraint.new(Rails.application.config.domains[:books])`, directly above the existing `root to: "books/ranked_items#index"` line:

```ruby
    get "lists", to: "books/lists#index", as: :books_lists
    get "lists/page/:page", to: "books/lists#index", as: :books_lists_page, constraints: {page: /\d+/}
    get "lists/:id", to: "books/lists#show", as: :books_list, constraints: {id: /\d+/}
    get "lists/:id/page/:page", to: "books/lists#show", as: :books_list_page,
      constraints: {id: /\d+/, page: /\d+/}

    get "rc/:ranking_configuration_id/lists", to: "books/lists#index", as: :books_rc_lists
    get "rc/:ranking_configuration_id/lists/page/:page", to: "books/lists#index",
      as: :books_rc_lists_page, constraints: {page: /\d+/}
    get "rc/:ranking_configuration_id/lists/:id", to: "books/lists#show", as: :books_rc_list,
      constraints: {id: /\d+/}
    get "rc/:ranking_configuration_id/lists/:id/page/:page", to: "books/lists#show",
      as: :books_rc_list_page, constraints: {id: /\d+/, page: /\d+/}
```

These are declared explicitly rather than wrapped in a `scope "(/rc/…)"`. The one `scope` block in the books section is the legacy `/books/:id` 301 namespace; joining it would make these redirect targets.

- [ ] **Step 2: Generate the controller shell**

```bash
bin/rails generate controller Books::Lists index show --no-helper --no-assets --skip-routes
rm app/views/books/lists/index.html.erb app/views/books/lists/show.html.erb
```

Generate **before** writing tests — the generator writes `test/controllers/books/lists_controller_test.rb` and would clobber the file Step 3 creates. Delete both placeholder views immediately: a generated `<h1>Books::Lists#index</h1>` would make Step 5's first assertion pass for the wrong reason. Task 3 writes the index view; Task 4 writes the show view.

- [ ] **Step 3: Write the failing controller tests**

Create `test/controllers/books/lists_controller_test.rb`:

```ruby
require "test_helper"

module Books
  class ListsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      @list = Books::List.create!(name: "Guardian 100", source: "The Guardian", status: :active)
      @ranked_list = RankedList.create!(list: @list, ranking_configuration: @rc, weight: 80)
    end

    test "index renders" do
      get "/lists"
      assert_response :success
    end

    test "index is indexable and cacheable by default" do
      get "/lists"

      assert @controller.view_assigns["indexable"]
      assert_match(/public/, response.headers["Cache-Control"])
    end

    test "index accepts the newest sort" do
      get "/lists?sort=newest"

      assert_response :success
      assert_equal "newest", @controller.view_assigns["sort"]
    end

    test "index falls back to weight for an unknown sort" do
      get "/lists?sort=bogus"

      assert_response :success
      assert_equal "weight", @controller.view_assigns["sort"]
    end

    test "search suppresses indexing and edge caching" do
      get "/lists?q=guardian"

      assert_response :success
      assert_not @controller.view_assigns["indexable"]
      assert_match(/no-store/, response.headers["Cache-Control"])
    end

    test "path-based pagination resolves the page" do
      seed_lists(60)

      get "/lists/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "404s past the last page" do
      get "/lists/page/99"
      assert_response :not_found
    end

    test "renders an explicit ranking configuration" do
      get "/rc/#{@rc.id}/lists"
      assert_response :success
    end

    test "item counts are loaded for the page" do
      ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)

      get "/lists"

      assert_equal 1, @controller.view_assigns["item_counts"][@list.id]
    end

    private

    def seed_lists(count)
      count.times do |i|
        list = Books::List.create!(name: "Filler #{i}", status: :active)
        RankedList.create!(list: list, ranking_configuration: @rc, weight: i)
      end
    end
  end
end
```

`host!` is required — every books route lives behind a `DomainConstraint`.

- [ ] **Step 4: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: FAIL — `ActionView::MissingTemplate` for `books/lists/index`, because Step 2 deleted the placeholder. Every assertion about `@sort`, `@indexable` and `@item_counts` fails too, since the generated action sets nothing.

- [ ] **Step 5: Write the controller**

Replace `app/controllers/books/lists_controller.rb` entirely:

```ruby
class Books::ListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  layout "books/application"

  before_action :load_ranking_configuration
  before_action :apply_caching

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def index
    @sort = Books::ListsQuery::SORTS.include?(params[:sort].to_s) ? params[:sort].to_s : "weight"
    @query = params[:q].presence
    @indexable = @query.blank?

    @pagy, @ranked_lists = pagy_path(
      Books::ListsQuery.call(ranking_configuration: @ranking_configuration, sort: @sort, query: @query),
      limit: 50
    )

    @item_counts = ListItem.where(list_id: @ranked_lists.map(&:list_id)).group(:list_id).count
  end

  private

  def apply_caching
    return prevent_caching if params[:q].present?

    (action_name == "show") ? cache_for_show_page : cache_for_index_page
  end
end
```

`@item_counts` is one grouped query over the 50 lists on the page. Do **not** use `includes(list: :list_items)` — on books that loads all 58,691 `list_items` into memory to call `.size`.

- [ ] **Step 6: Write the index view**

Create `app/views/books/lists/index.html.erb`:

```erb
<%
  content_for :page_title, "The Greatest Books Lists | The Greatest Books"
  content_for :meta_description, "Every published best-books list we aggregate to build the rankings, weighted by quality, credibility and scope."
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance">The Lists</h1>

  <p class="max-w-3xl mx-auto text-center text-base-content/80">
    These are the lists we aggregate to build the rankings. Each one carries a weight based on its
    quality, credibility and scope — the higher the weight, the more it counts.
  </p>

  <div class="flex flex-col sm:flex-row gap-4 sm:items-center sm:justify-between">
    <%= form_with url: books_lists_path, method: :get, class: "join" do |f| %>
      <%= f.hidden_field :sort, value: @sort %>
      <%= f.search_field :q, value: @query, placeholder: "Search lists",
            "aria-label": "Search lists by name, source or url",
            class: "input input-bordered join-item" %>
      <%= f.submit "Search", class: "btn btn-primary join-item" %>
    <% end %>

    <div class="join" role="group" aria-label="Sort lists">
      <%= link_to "Weight", books_lists_path(q: @query),
            class: "btn join-item #{"btn-active" if @sort == "weight"}" %>
      <%= link_to "Recently added", books_lists_path(sort: "newest", q: @query),
            class: "btn join-item #{"btn-active" if @sort == "newest"}" %>
    </div>
  </div>

  <% if @query %>
    <p class="text-center text-base-content/70">
      <%= pluralize(@pagy.count, "list") %> matching “<%= @query %>”.
      <%= link_to "Clear", books_lists_path, class: "link" %>
    </p>
  <% end %>

  <% if @ranked_lists.any? %>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <% @ranked_lists.each do |ranked_list| %>
        <%= render Lists::CardComponent.new(
              ranked_list: ranked_list,
              item_count: @item_counts.fetch(ranked_list.list_id, 0),
              path: books_list_path(ranked_list.list_id),
              noun: "books"
            ) %>
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
      <h2 class="text-2xl font-bold mb-2">No lists found</h2>
      <p class="text-base-content/70">Try a different search.</p>
    </div>
  <% end %>
</div>
```

The `“ ”` are U+201C/U+201D curly quotes. `@query` is escaped by default ERB output.

- [ ] **Step 7: Run the tests**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: PASS, 9 tests. `#show` is not yet implemented, and no test above exercises it.

- [ ] **Step 8: Pin the index query count**

Append to `test/controllers/books/lists_controller_test.rb`:

```ruby
test "index issues a bounded number of queries regardless of list count" do
  seed_lists(40)

  get "/lists"
  assert_response :success

  assert_queries_count(8) { get "/lists" }
end
```

Run it, read the actual count from the failure message, and set the number to what it actually is. Then add one more list and re-run to confirm the count does not grow — that is what the test is for.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books app/views/books/lists test/controllers/books config/routes.rb
bundle exec standardrb
git add config/routes.rb app/controllers/books/lists_controller.rb app/views/books/lists/index.html.erb test/controllers/books/lists_controller_test.rb
git commit -m "Add the books curated-list index at /lists

Sorting by weight or recently-added and search over name, source and url
ride as query params, so PathBuilder carries them through pagination
unchanged. Search suppresses both indexing and edge caching -- otherwise
every query string mints its own six-hour Cloudflare entry."
```

---

### Task 4: `Books::ListsController#show` and the show view

**Files:**
- Modify: `app/controllers/books/lists_controller.rb`
- Create: `app/views/books/lists/show.html.erb`
- Test: `test/controllers/books/lists_controller_test.rb`

**Interfaces:**
- Consumes: `Books::CardComponent.new(book:, rank:, index:)` from Task 1; `Lists::WeightBreakdownComponent.new(ranked_list:)` from increment 1; the routes from Task 3.
- Produces: nothing later tasks depend on beyond the rendered page.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/books/lists_controller_test.rb`:

```ruby
test "show renders an active list" do
  get "/lists/#{@list.id}"
  assert_response :success
end

test "show 404s for a non-active list" do
  @list.update!(status: :unapproved)

  get "/lists/#{@list.id}"

  assert_response :not_found
end

test "show 404s for an unknown id" do
  get "/lists/999999"
  assert_response :not_found
end

test "show is indexable when the list is in the ranking configuration" do
  get "/lists/#{@list.id}"

  assert @controller.view_assigns["indexable"]
end

test "show is not indexable when the list is outside the ranking configuration" do
  @ranked_list.destroy!

  get "/lists/#{@list.id}"

  assert_response :success
  assert_not @controller.view_assigns["indexable"]
end

test "show paginates its items" do
  seed_items(120)

  get "/lists/#{@list.id}/page/2"

  assert_response :success
  assert_equal 2, @controller.view_assigns["pagy"].page
end

test "show 404s past the last item page" do
  get "/lists/#{@list.id}/page/99"
  assert_response :not_found
end

test "show loads ranks for the books on the page" do
  book = books_books(:war_and_peace)
  ListItem.create!(list: @list, listable: book, position: 1)
  RankedItem.create!(item: book, ranking_configuration: @rc, rank: 7, score: 50)

  get "/lists/#{@list.id}"

  assert_equal 7, @controller.view_assigns["ranks"][book.id]
end

test "show survives a list item whose listable no longer exists" do
  ListItem.create!(list: @list, listable_type: "Books::Book", listable_id: 999_999_999, position: 1)

  get "/lists/#{@list.id}"

  assert_response :success
end
```

and this private helper beside `seed_lists`:

```ruby
def seed_items(count)
  now = Time.current
  rows = Array.new(count) { |i| {title: "Item Book #{i}", slug: "item-book-#{i}", created_at: now, updated_at: now} }
  ids = Books::Book.insert_all(rows, returning: :id).rows.flatten
  ListItem.insert_all(
    ids.each_with_index.map do |id, i|
      {list_id: @list.id, listable_id: id, listable_type: "Books::Book",
       position: i + 1, created_at: now, updated_at: now}
    end
  )
end
```

`insert_all` skips callbacks deliberately — creating books row-by-row also enqueues a `SearchIndexRequest` each, which dominates the runtime.

The last test is the nil-listable guard. It matters: `list_items(:books_item)` in the shared fixtures already points at a book id that does not exist, so this is a real shape in this codebase.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb -n "/show/"
```

Expected: FAIL — the `show` action has no implementation, so the template is missing.

- [ ] **Step 3: Implement `show`**

Add to `app/controllers/books/lists_controller.rb`, directly below `index`:

```ruby
  def show
    @list = Books::List.where(status: :active).find_by!(id: params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
    @indexable = @ranked_list.present?

    @pagy, @list_items = pagy_path(
      @list.list_items
        .includes(listable: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC")),
      limit: 100
    )

    book_ids = @list_items.filter_map { |item| item.listable_id if item.listable_type == "Books::Book" }
    @ranks = RankedItem.where(
      ranking_configuration: @ranking_configuration, item_type: "Books::Book", item_id: book_ids
    ).pluck(:item_id, :rank).to_h
  end
```

`find_by!(id:)` scoped to `status: :active`, so a non-active list 404s rather than leaking a pending submission. `Books::List` does not use friendly_id, so an id lookup is unambiguous here — unlike `Books::Book`.

`{file_attachment: :blob}` is not optional; omitting it is a 200-query N+1 per page.

- [ ] **Step 4: Write the show view**

Create `app/views/books/lists/show.html.erb`:

```erb
<%
  content_for :page_title, truncate("#{@list.name}#{" from #{@list.source}" if @list.source.present?} | The Greatest Books", length: 70)
  content_for :meta_description, truncate("All #{@pagy.count} books on “#{@list.name}”#{", from #{@list.source}" if @list.source.present?}. #{@list.description}", length: 160)
%>

<div class="space-y-8">
  <div class="space-y-3">
    <h1 class="text-3xl sm:text-4xl font-bold text-balance"><%= @list.name %></h1>

    <div class="flex flex-wrap gap-2">
      <% if @list.source.present? %>
        <span class="badge badge-ghost badge-lg">Source: <%= @list.source %></span>
      <% end %>
      <% if @list.year_published.present? %>
        <span class="badge badge-ghost badge-lg"><%= @list.yearly_award? ? "Yearly Award" : @list.year_published %></span>
      <% end %>
      <span class="badge badge-ghost badge-lg"><%= pluralize(@pagy.count, "book") %></span>
      <% if @list.number_of_voters.present? %>
        <span class="badge badge-ghost badge-lg"><%= number_with_delimiter(@list.number_of_voters) %> voters</span>
      <% end %>
    </div>

    <% if @list.description.present? %>
      <p class="max-w-3xl text-base-content/80"><%= @list.description %></p>
    <% end %>

    <% if @list.url.present? %>
      <%= link_to "View the original list", @list.url, rel: "noopener nofollow",
            target: "_blank", class: "btn btn-sm btn-primary" %>
    <% end %>
  </div>

  <%= render Lists::WeightBreakdownComponent.new(ranked_list: @ranked_list) %>

  <% if @list_items.any? %>
    <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-4 sm:gap-6">
      <% @list_items.each_with_index do |list_item, index| %>
        <% book = list_item.listable %>
        <% next unless book %>
        <%= render Books::CardComponent.new(book: book, rank: @ranks[book.id], index: index) %>
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
      <h2 class="text-2xl font-bold mb-2">No books on this list yet</h2>
    </div>
  <% end %>
</div>
```

`next unless book` is the nil-listable guard the last test pins. The description and name are escaped by default ERB output — do not reach for `simple_format(..., sanitize: false)`.

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: PASS, all 19 tests.

- [ ] **Step 6: Pin the show query count with a real cover**

Append:

```ruby
test "show issues a bounded number of queries and preloads covers" do
  book = books_books(:war_and_peace)
  ListItem.create!(list: @list, listable: book, position: 1)
  seed_items(20)

  get "/lists/#{@list.id}"
  assert_response :success

  assert_queries_count(12) { get "/lists/#{@list.id}" }
end
```

Run it, read the real count from the failure, set the number. Then add 10 more items and confirm the count is unchanged — that is the point. The request renders the grid, so the cover association is genuinely touched; increment 1's pin passed while missing 200 image queries precisely because its block never rendered one.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/books app/views/books/lists test/controllers/books
bundle exec standardrb
git add app/controllers/books/lists_controller.rb app/views/books/lists/show.html.erb test/controllers/books/lists_controller_test.rb
git commit -m "Add the books list detail page at /lists/:id

Ordered by list position with a list_items.id tiebreak, since 389 of the
622 active books lists carry no positions at all. Ranks come from one
lookup over the page's book ids. Only active lists resolve -- unapproved
rows are user submissions, which legacy leaked."
```

---

### Task 5: Legacy 301s

Every legacy list URL that this increment does not implement. `/lists/:id` and `/lists/page/:n` need no redirect — list ids were preserved by the migration, so those shapes are byte-identical already.

**Files:**
- Modify: `config/routes.rb` — directly above the Task 3 `get "lists", …` line
- Test: `test/controllers/books/lists_controller_test.rb`

**Interfaces:**
- Consumes: the routes from Task 3.
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/books/lists_controller_test.rb`:

```ruby
test "legacy sorted-by weight redirects to the canonical index" do
  get "/lists/sorted-by/weight"
  assert_redirected_to "/lists"
  assert_response :moved_permanently
end

test "legacy sorted-by created_at redirects to the newest sort" do
  get "/lists/sorted-by/created_at"
  assert_redirected_to "/lists?sort=newest"
  assert_response :moved_permanently
end

test "legacy paged sorted-by redirects to the canonical index" do
  get "/lists/sorted-by/weight/page/3"
  assert_redirected_to "/lists"
  assert_response :moved_permanently
end

test "legacy collection pages redirect to the canonical index" do
  ["/lists/search_results", "/lists/condensed", "/lists/help",
    "/lists/pending_lists", "/lists/specialized_edit"].each do |path|
    get path
    assert_redirected_to "/lists"
    assert_response :moved_permanently
  end
end

test "legacy view-prefixed list detail redirects to the plain path" do
  get "/v/grid/lists/#{@list.id}"
  assert_redirected_to "/lists/#{@list.id}"
  assert_response :moved_permanently
end

test "legacy view-prefixed index redirects to the canonical index" do
  get "/v/table/lists"
  assert_redirected_to "/lists"
  assert_response :moved_permanently
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb -n "/legacy/"
```

Expected: FAIL — `ActionController::RoutingError` on each path.

- [ ] **Step 3: Add the redirects**

In `config/routes.rb`, immediately **above** the `get "lists", to: "books/lists#index"` line added in Task 3:

```ruby
    get "lists/sorted-by/created_at(/page/:page)", to: redirect("/lists?sort=newest", status: 301)
    get "lists/sorted-by/:sort(/page/:page)", to: redirect("/lists", status: 301)
    get "lists/search_results", to: redirect("/lists", status: 301)
    get "lists/condensed", to: redirect("/lists", status: 301)
    get "lists/help", to: redirect("/lists", status: 301)
    get "lists/pending_lists", to: redirect("/lists", status: 301)
    get "lists/specialized_edit", to: redirect("/lists", status: 301)
    get "v/:view_type/lists", to: redirect("/lists", status: 301)
    get "v/:view_type/lists/page/:page", to: redirect("/lists", status: 301), constraints: {page: /\d+/}
    get "v/:view_type/lists/:id", to: redirect("/lists/%{id}", status: 301), constraints: {id: /\d+/}
    get "v/:view_type/lists/:id/page/:page", to: redirect("/lists/%{id}", status: 301),
      constraints: {id: /\d+/, page: /\d+/}
```

The `created_at` rule must precede the generic `:sort` rule — Rails matches in declaration order and `:sort` would otherwise swallow it. `%{id}` is Rails' segment interpolation in a redirect string.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
bin/rails test test/controllers/books/lists_controller_test.rb
```

Expected: PASS, all tests including the six new ones.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix config/routes.rb test/controllers/books
bundle exec standardrb
git add config/routes.rb test/controllers/books/lists_controller_test.rb
git commit -m "Add 301s from the legacy books list urls

/lists/:id and /lists/page/:n need no redirect -- list ids were preserved
by the migration, so those shapes are already byte-identical. Everything
this increment does not implement folds back to the canonical index."
```

---

### Task 6: Book-page list links and the Lists nav entry

Spec decision D13: the book detail page's "Appears on these lists" section ships as plain text in increment 1 and becomes links here. The books layout also gains its Lists nav entry, which increment 1 deliberately deferred because the route did not exist yet.

**Files:**
- Modify: `app/views/books/books/show.html.erb:94`
- Modify: `app/views/layouts/books/application.html.erb` — the mobile dropdown `<ul>` and the desktop `<ul class="menu menu-horizontal px-1">`
- Test: `test/controllers/books/books_controller_test.rb`

**Interfaces:**
- Consumes: `books_list_path` from Task 3.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Append to `test/controllers/books/books_controller_test.rb`, inside the existing class:

```ruby
test "list names on the book page link to the list" do
  book = books_books(:war_and_peace)
  list = Books::List.create!(name: "Guardian 100", status: :active)
  RankedList.create!(list: list, ranking_configuration: @rc, weight: 50)
  ListItem.create!(list: list, listable: book, position: 1)

  get "/book/#{book.slug}"

  assert_response :success
  assert_select "a[href=?]", "/lists/#{list.id}"
end
```

The existing `setup` block already defines `@rc = ranking_configurations(:books_global)` and `@book = books_books(:war_and_peace)`, so the test above reuses `@rc` directly. `assert_select` on a link target is a behavioral assertion about routing, not a copy or styling assertion.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/controllers/books/books_controller_test.rb -n "/link to the list/"
```

Expected: FAIL — the list name renders as plain text, so no matching anchor exists.

- [ ] **Step 3: Link the list names**

In `app/views/books/books/show.html.erb`, replace line 94:

```erb
              <li class="text-base-content/80"><%= list_item.list.name %></li>
```

with:

```erb
              <li><%= link_to list_item.list.name, books_list_path(list_item.list_id), class: "link link-hover" %></li>
```

- [ ] **Step 4: Add the nav entries**

In `app/views/layouts/books/application.html.erb`, in the mobile dropdown `<ul>`, below the existing Books entry:

```erb
            <li><%= link_to "Lists", books_lists_path %></li>
```

and the identical line in the desktop `<ul class="menu menu-horizontal px-1">`.

- [ ] **Step 5: Run the books controller tests**

```bash
bin/rails test test/controllers/books
```

Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/views/books app/views/layouts/books test/controllers/books
bundle exec standardrb
git add app/views/books/books/show.html.erb app/views/layouts/books/application.html.erb test/controllers/books/books_controller_test.rb
git commit -m "Link the book page's list names and add the Lists nav entry

Spec D13. Increment 1 shipped these as plain text because the /lists
routes did not exist yet."
```

---

### Task 7: Playwright coverage

Every new user-facing page needs an end-to-end spec. These run against a local dev server, not the test database, so they assert on structure rather than exact records.

**Files:**
- Create: `web-app/e2e/tests/books/lists.spec.ts`

**Interfaces:**
- Consumes: all routes and views from Tasks 3-6.
- Produces: nothing.

- [ ] **Step 1: Write the spec**

Create `web-app/e2e/tests/books/lists.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books lists index', () => {
  test('loads and renders the heading', async ({ page }) => {
    const response = await page.goto('/lists');

    expect(response?.status()).toBe(200);
    await expect(page.getByRole('heading', { name: 'The Lists', level: 1 })).toBeVisible();
  });

  test('is reachable from the nav', async ({ page }) => {
    await page.goto('/');

    await page.locator('.menu-horizontal').getByRole('link', { name: 'Lists', exact: true }).click();

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('pagination links are path-based', async ({ page }) => {
    await page.goto('/lists');

    await expect(page.locator('nav.pagy a[href="/lists/page/2"]').first()).toBeVisible();
  });

  test('the newest sort carries through pagination', async ({ page }) => {
    await page.goto('/lists?sort=newest');

    await expect(page.locator('nav.pagy a[href*="/lists/page/2"][href*="sort=newest"]').first()).toBeVisible();
  });

  test('search narrows the results and is noindex', async ({ page }) => {
    await page.goto('/lists?q=the');

    await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', /noindex/);
    await expect(page.getByText(/matching/)).toBeVisible();
  });

  test('a card links through to the list detail page', async ({ page }) => {
    await page.goto('/lists');

    const firstCard = page.locator('.card h3 a').first();
    const name = (await firstCard.textContent())?.trim() ?? '';
    await firstCard.click();

    await expect(page).toHaveURL(/\/lists\/\d+$/);
    await expect(page.getByRole('heading', { level: 1, name })).toBeVisible();
  });
});

test.describe('Books list detail', () => {
  test('renders the weight breakdown and a book grid', async ({ page }) => {
    await page.goto('/lists');
    await page.locator('.card h3 a').first().click();

    await expect(page.getByRole('heading', { name: 'How good is this list?' })).toBeVisible();
    await expect(page.getByText('Base weight')).toBeVisible();
    await expect(page.locator('.card').first()).toBeVisible();
  });

  test('legacy sorted-by url redirects to the canonical index', async ({ page }) => {
    await page.goto('/lists/sorted-by/weight');

    await expect(page).toHaveURL(/\/lists$/);
  });

  test('legacy view-prefixed detail url redirects to the plain path', async ({ page }) => {
    await page.goto('/lists');
    const href = await page.locator('.card h3 a').first().getAttribute('href');

    await page.goto(`/v/grid${href}`);

    await expect(page).toHaveURL(new RegExp(`${href}$`));
  });
});
```

- [ ] **Step 2: Start the dev server and run the spec**

In one shell:

```bash
bin/dev
```

In another:

```bash
yarn test:e2e e2e/tests/books/lists.spec.ts
```

Expected: PASS, 9 tests. If a selector misses because the dev database's first list has no items or no weight details, adjust the selector — do **not** weaken an assertion to make it pass.

- [ ] **Step 3: Commit**

```bash
git add e2e/tests/books/lists.spec.ts
git commit -m "Add Playwright coverage for the books list pages

Covers the index heading, nav entry, path-based pagination, sort
persistence through pagination, search noindex, click-through to detail,
the weight breakdown, and both legacy redirect families."
```

---

### Task 8: Full-suite verification

**Files:** none.

- [ ] **Step 1: Run the full suite**

```bash
bin/rails db:test:prepare
bin/rails test
```

Expected: PASS, 0 failures and 0 errors. Record the total before starting so the delta is checkable.

- [ ] **Step 2: Run the system tests**

```bash
bin/rails test:system
```

Expected: the 5 pre-existing `set_rack_session` errors in `test/system/admin/music/songs/wizard_review_step_test.rb` and nothing else. That failure is unrelated to this work and reproduces on `main`. **If any new system test failure appears, stop and report it.**

- [ ] **Step 3: Lint**

```bash
bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 4: Build assets**

```bash
yarn build:all
```

Expected: clean.

- [ ] **Step 5: Sanity-check against real dev data**

```bash
bin/rails runner 'rc = Books::RankingConfiguration.default_primary; q = Books::ListsQuery.call(ranking_configuration: rc); puts "lists: #{q.count} (expect 622)"; puts "newest top: #{Books::ListsQuery.call(ranking_configuration: rc, sort: "newest").first&.list&.name}"; puts "search: #{Books::ListsQuery.call(ranking_configuration: rc, query: "guardian").count}"'
```

Expected: 622 lists. The other two lines are smoke checks — they must not raise.

- [ ] **Step 6: Confirm a clean tree**

```bash
git status --short
git diff main --stat
```

Expected: clean tree; the diff touches only the files named in this plan.

---

## Verification checklist

- [ ] `bin/rails test` passes with zero failures
- [ ] `bin/rails test:system` shows only the pre-existing `set_rack_session` errors
- [ ] `bundle exec standardrb` reports no offenses
- [ ] `yarn build:all` succeeds
- [ ] `yarn test:e2e e2e/tests/books/lists.spec.ts` passes against a running dev server
- [ ] `Books::ListsQuery` returns 622 lists against dev
- [ ] Both `assert_queries_count` pins hold when more rows are added, and the show-page pin renders a cover
- [ ] Nothing pushed and no PR opened

## Landmines

1. **`list_items(:books_item).listable` is `nil`** — it points at a nonexistent book id. Never build a show-page test on it; Task 4 creates its own items.
2. **`lists(:books_list).status` is `approved`, not `active`** — it will not appear in the index.
3. **`{file_attachment: :blob}`** on every `primary_image` preload, and the query-count pin must render a cover.
4. **`Arel.sql` around any order string containing `NULLS LAST`** — Rails 8 raises `UnknownAttributeReference` otherwise.
5. **`lists.id ASC` / `list_items.id ASC` tiebreaks** — 273 books lists share a weight bucket and 389 lists have no item positions at all.
6. **`prevent_caching` whenever `params[:q]` is present**, or Cloudflare stores an entry per query string.
7. **The `created_at` redirect must precede the generic `:sort` redirect** — Rails matches in declaration order.
8. **Do not join the new routes to the existing `scope "(/rc/…)"` block** in the books section — that block is the legacy `/books/:id` 301 namespace.
9. **Escape everything** — no `simple_format(..., sanitize: false)` on list names or descriptions.
10. **`host! "dev-new.thegreatestbooks.org"`** in every books integration test, or the `DomainConstraint` rejects the request.
