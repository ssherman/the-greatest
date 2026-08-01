# Public Lists UI — Increment 3 (Games `/lists`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the games list pages to parity with books, behind shared base classes so neither the query nor the index action is written twice — and stop serving unapproved list submissions publicly.

**Architecture:** A root `ListsQuery` base owns the whole relation and a root `PublicListsController` owns `index` and caching; each domain supplies a `list_type` string, a `lists_query_class`, a layout, and its own `show`. Books is refactored onto the bases with no behaviour change before games is added, so the refactor and the new domain are separately reviewable.

**Tech Stack:** Rails 8.1, Minitest + fixtures + Mocha, pagy 43 via `PathBasedPagination`, ViewComponent, Tailwind CSS 4 + DaisyUI 5, Playwright.

Spec: `docs/superpowers/specs/2026-08-01-lists-public-ui-design.md` ("Increment 3 — games `/lists`"). Increments 1 and 2 merged as PRs #191 and #192.

## Global Constraints

- **Run all Rails and yarn commands from `web-app/`.** Docs live at the project root.
- **Lint is `bundle exec standardrb`**, never `bin/rubocop`. **Never run `bin/brakeman`.**
- **The development database is not disposable.** A `PreToolUse` hook blocks `db:drop`/`db:reset`/`db:schema:load`, `create_fixtures`, and bulk `delete_all`/`update_all` in `rails runner`. `db:test:prepare` is allowlisted.
- **No code comments** unless this plan shows one explicitly.
- **Never use the `prose` class** — `@tailwindcss/typography` is not installed.
- **Escape all database-sourced content.** No `raw`, `html_safe`, or `simple_format(..., sanitize: false)`.
- **`assert_queries_count` blocks must call `ActiveRecord::Base.connection.clear_query_cache` first.** Rails 8 scopes the AR query cache to the whole test method, so a warm-up request followed by an identical measured one is served entirely from cache and the pin asserts nothing. Proved on increment 2 by injecting a 41-query N+1 and watching the pin pass.
- Games views start at `<div class="space-y-8">` — the layout already provides `<main class="container mx-auto px-4 py-8">`.
- Index paginates at **50**; the show page's game grid stays at **100**.
- **Pagination is full-page navigation, never a Turbo Frame.**
- Controller tests assert behavior — status codes, params, assigns. Never HTML, CSS, or copy.
- Commit after each task. Do not push and do not open a PR.

## Landmines (verified 2026-08-01)

1. **`lists(:games_list)` is `approved` (1), not `active` (3), and 14 test files use it.** Once `show` filters to active, every existing games lists test fetching `@list` will 404. **Do not change the fixture** — the wizard, admin and model tests depend on its status. Task 4 rewrites that one test file's `setup` instead.
2. **Games currently serves unapproved list submissions publicly.** `Games::ListsController#show` does a bare `Games::List.find`; `/lists/11371` (unapproved) returns **200** against dev. 133 unapproved of 152. Closing it is a deliberate behaviour change matching spec D9 for books.
3. **The existing games E2E spec targets `a.card`.** `Lists::CardComponent` renders `div.card` with a stretched link inside, so those selectors break. Task 5 fixes them.
4. **Games routes live inside `scope "(/rc/:ranking_configuration_id)"`** — adding `lists/page/:page` there gives the rc variant free. Do not add separate `rc/...` list routes for games.
5. **`games_list_path_with_rc(list, rc)` already exists** in `Games::DefaultHelper`. Task 1 adds the index-level sibling rather than inventing a convention.
6. Games is small — **19 active lists of 152**. Sorting by `newest` is near-meaningless today; pagination and search are future-proofing.

## File structure

| File | Responsibility |
|---|---|
| `app/lib/lists_query.rb` (new) | base: scope, sort whitelist, search, ordering |
| `app/lib/books/lists_query.rb` (modify) | subclass — `list_type` only |
| `app/lib/games/lists_query.rb` (new) | subclass — `list_type` only |
| `app/controllers/public_lists_controller.rb` (new) | base: `index`, `apply_caching`, item counts |
| `app/controllers/books/lists_controller.rb` (modify) | `show` + config only |
| `app/controllers/games/lists_controller.rb` (modify) | `show` + config only |
| `app/helpers/{books,games}/default_helper.rb` (modify) | rc-aware list path helpers |
| `app/views/books/lists/index.html.erb` (modify) | use the rc-aware helpers |
| `app/views/games/lists/{index,show}.html.erb` (modify) | shared components, controls, single container |
| `config/routes.rb` (modify) | games `lists/page/:page` + page-1 redirects |
| `e2e/tests/games/public/lists.spec.ts` (modify) | updated selectors + new coverage |

---

### Task 1: rc-aware path helpers, and fix the books index

On `/rc/:id/lists` the sort links, search form action and card hrefs all drop the rc segment while pagination keeps it — so previewing an alternate ranking configuration bounces you to the default one on the first click. Books has this bug now; games would inherit it. Fixing it in both domains first is why this task leads.

Books needs helpers because it declares its rc routes explicitly. Games' routes sit inside an optional `scope "(/rc/…)"`, so passing `ranking_configuration_id:` to the ordinary helper already produces the path segment — its helper only decides whether to pass it.

**Files:**
- Modify: `app/helpers/books/default_helper.rb`, `app/helpers/games/default_helper.rb`
- Modify: `app/views/books/lists/index.html.erb`
- Test: `test/helpers/books/default_helper_test.rb`, `test/helpers/games/default_helper_test.rb`

**Interfaces:**
- Consumes: route helpers `books_lists_path`, `books_rc_lists_path`, `books_list_path`, `books_rc_list_path`, `games_lists_path`.
- Produces: `books_lists_path_with_rc(**options)`, `books_list_path_with_rc(id, **options)`, `games_lists_path_with_rc(**options)`. Task 3's games index view uses the games one.

- [ ] **Step 1: Write the failing helper tests**

Append to `test/helpers/books/default_helper_test.rb`, inside the existing class:

```ruby
test "lists path keeps the ranking configuration when one is present" do
  params[:ranking_configuration_id] = "8"

  assert_equal "/rc/8/lists", books_lists_path_with_rc
  assert_equal "/rc/8/lists/12", books_list_path_with_rc(12)
end

test "lists path omits the ranking configuration when there is none" do
  assert_equal "/lists", books_lists_path_with_rc
  assert_equal "/lists/12", books_list_path_with_rc(12)
end

test "lists path passes query options through" do
  assert_equal "/lists?sort=newest", books_lists_path_with_rc(sort: "newest")

  params[:ranking_configuration_id] = "8"
  assert_equal "/rc/8/lists?sort=newest", books_lists_path_with_rc(sort: "newest")
end
```

Append to `test/helpers/games/default_helper_test.rb`, inside the existing class:

```ruby
test "lists path keeps the ranking configuration when one is present" do
  params[:ranking_configuration_id] = "4"

  assert_equal "/rc/4/lists", games_lists_path_with_rc
end

test "lists path omits the ranking configuration when there is none" do
  assert_equal "/lists", games_lists_path_with_rc
end

test "lists path passes query options through" do
  assert_equal "/lists?sort=newest", games_lists_path_with_rc(sort: "newest")
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/helpers/books/default_helper_test.rb test/helpers/games/default_helper_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'books_lists_path_with_rc'`.

- [ ] **Step 3: Add the books helpers**

Append inside `module Books::DefaultHelper`:

```ruby
def books_lists_path_with_rc(**options)
  rc = params[:ranking_configuration_id].presence
  rc ? books_rc_lists_path(rc, **options) : books_lists_path(**options)
end

def books_list_path_with_rc(id, **options)
  rc = params[:ranking_configuration_id].presence
  rc ? books_rc_list_path(rc, id, **options) : books_list_path(id, **options)
end
```

- [ ] **Step 4: Add the games helper**

Append inside `module Games::DefaultHelper`, beside the existing `games_list_path_with_rc`:

```ruby
def games_lists_path_with_rc(**options)
  rc = params[:ranking_configuration_id].presence
  rc ? games_lists_path(ranking_configuration_id: rc, **options) : games_lists_path(**options)
end
```

The shape differs from books' because games' routes are inside an optional `scope "(/rc/:ranking_configuration_id)"`, so `ranking_configuration_id:` becomes a path segment rather than a query parameter.

- [ ] **Step 5: Run the helper tests**

```bash
bin/rails test test/helpers/books/default_helper_test.rb test/helpers/games/default_helper_test.rb
```

Expected: PASS.

- [ ] **Step 6: Use the helpers in the books index view**

In `app/views/books/lists/index.html.erb`, replace four path calls:

- `form_with url:` → `books_lists_path_with_rc`
- the "Weight" sort link → `books_lists_path_with_rc(q: @query)`
- the "Recently added" sort link → `books_lists_path_with_rc(sort: "newest", q: @query)`
- the card's `path:` → `books_list_path_with_rc(ranked_list.list_id)`

Leave the "Clear" link as plain `books_lists_path` — clearing a search should return to the canonical unfiltered index.

- [ ] **Step 7: Pin the books behaviour**

Append to `test/controllers/books/lists_controller_test.rb`:

```ruby
test "rc-scoped index keeps the rc segment in its own controls" do
  get "/rc/#{@rc.id}/lists"

  assert_response :success
  assert_select "a[href=?]", "/rc/#{@rc.id}/lists/#{@list.id}"
  assert_select "form[action=?]", "/rc/#{@rc.id}/lists"
end
```

`assert_select` on an href or form action is a routing assertion, not a markup one — the sanctioned exception this project already uses for the book-page link test.

- [ ] **Step 8: Run, lint, commit**

```bash
bin/rails test test/controllers/books test/helpers
bundle exec standardrb --fix app/helpers app/views/books/lists test/helpers test/controllers/books
bundle exec standardrb
git add app/helpers app/views/books/lists/index.html.erb test/helpers test/controllers/books/lists_controller_test.rb
git commit -m "Keep the ranking configuration in list index controls

On /rc/:id/lists the sort links, search form and card hrefs dropped the
rc segment while pagination kept it, so previewing an alternate ranking
configuration bounced you to the default one on the first click."
```

---

### Task 2: Extract the shared bases and refactor books onto them

Pure refactor — **books behaviour must not change**, and its existing tests are the proof. Doing this before games exists means the extraction is reviewable on its own, and games becomes a handful of lines.

This also removes the duplicated sort-validation ternary flagged during increment 2: `normalize_sort` lands on the base query and both the controller and the query call it.

**Files:**
- Create: `app/lib/lists_query.rb`
- Create: `app/controllers/public_lists_controller.rb`
- Modify: `app/lib/books/lists_query.rb`
- Modify: `app/controllers/books/lists_controller.rb`
- Test: `test/lib/lists_query_test.rb`

**Interfaces:**
- Consumes: `List.search_text(query)`, `lists.activated_at` (increment 1); `PathBasedPagination#pagy_path`, `Cacheable` (already on main).
- Produces:
  - `ListsQuery::SORTS` → `%w[weight newest]`
  - `ListsQuery.normalize_sort(value)` → `"weight"` or `"newest"`, falling back to `"weight"`
  - `ListsQuery.list_type` → abstract, raises `NotImplementedError`
  - `ListsQuery.call(ranking_configuration:, sort: "weight", query: nil)` → ordered `RankedList` relation with `:list` preloaded
  - `PublicListsController` — provides `index`, `apply_caching`, and requires subclasses to define `self.lists_query_class` and `self.ranking_configuration_class`, and to set their own `layout`

Task 3 subclasses both for games.

- [ ] **Step 1: Write the base-query tests**

Create `test/lib/lists_query_test.rb`:

```ruby
require "test_helper"

class ListsQueryTest < ActiveSupport::TestCase
  test "normalize_sort accepts the whitelist" do
    assert_equal "weight", ListsQuery.normalize_sort("weight")
    assert_equal "newest", ListsQuery.normalize_sort("newest")
  end

  test "normalize_sort falls back to weight for anything else" do
    assert_equal "weight", ListsQuery.normalize_sort("bogus")
    assert_equal "weight", ListsQuery.normalize_sort(nil)
    assert_equal "weight", ListsQuery.normalize_sort("'; DROP TABLE lists; --")
  end

  test "the base class refuses to run without a list type" do
    assert_raises(NotImplementedError) { ListsQuery.list_type }
  end
end
```

The third test is the one that matters: it pins that a subclass which forgets `list_type` fails loudly rather than silently querying every domain's lists at once.

- [ ] **Step 2: Run to verify they fail**

```bash
bin/rails test test/lib/lists_query_test.rb
```

Expected: FAIL — `NameError: uninitialized constant ListsQuery`.

- [ ] **Step 3: Write the base query**

Create `app/lib/lists_query.rb`:

```ruby
class ListsQuery
  SORTS = %w[weight newest].freeze

  def self.list_type
    raise NotImplementedError, "#{name} must define .list_type"
  end

  def self.normalize_sort(value)
    SORTS.include?(value.to_s) ? value.to_s : "weight"
  end

  def self.call(ranking_configuration:, sort: "weight", query: nil)
    new(ranking_configuration: ranking_configuration, sort: sort, query: query).call
  end

  def initialize(ranking_configuration:, sort:, query:)
    @ranking_configuration = ranking_configuration
    @sort = self.class.normalize_sort(sort)
    @query = query
  end

  def call
    scope = @ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: self.class.list_type, status: ::List.statuses[:active]})
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
```

`Arel.sql` is required — Rails 8 raises `UnknownAttributeReference` for a raw order string containing `NULLS LAST`. `lists.id ASC` is the pagination-stability tiebreak.

- [ ] **Step 4: Reduce the books query to a subclass**

Replace `app/lib/books/lists_query.rb` entirely:

```ruby
module Books
  class ListsQuery < ::ListsQuery
    def self.list_type
      "Books::List"
    end
  end
end
```

`Books::ListsQuery::SORTS` still resolves through inheritance, so nothing referencing it breaks.

- [ ] **Step 5: Run the books query tests unchanged**

```bash
bin/rails test test/lib/lists_query_test.rb test/lib/books/lists_query_test.rb
```

Expected: PASS. **Do not modify `test/lib/books/lists_query_test.rb`** — it passing untouched is the evidence the refactor preserved behaviour. If any test there fails, the extraction is wrong; fix the base, not the test.

- [ ] **Step 6: Write the base controller**

Create `app/controllers/public_lists_controller.rb`:

```ruby
class PublicListsController < ApplicationController
  include Pagy::Method
  include Cacheable
  include PathBasedPagination

  before_action :load_ranking_configuration
  before_action :apply_caching

  def self.lists_query_class
    raise NotImplementedError, "#{name} must define .lists_query_class"
  end

  def index
    @sort = ListsQuery.normalize_sort(params[:sort])
    @query = params[:q].is_a?(String) ? params[:q].presence : nil
    @indexable = @query.blank?

    @pagy, @ranked_lists = pagy_path(
      self.class.lists_query_class.call(
        ranking_configuration: @ranking_configuration, sort: @sort, query: @query
      ),
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

`params[:q].is_a?(String)` is not optional — a nested `q[a]=1` otherwise arrives as `ActionController::Parameters` and 500s in `url_for` on the sort links. That defect shipped once and was fixed; do not reintroduce it.

`@item_counts` is one grouped query. Never `includes(list: :list_items)` — that loads every list item into memory to call `.size`.

- [ ] **Step 7: Reduce the books controller**

Replace `app/controllers/books/lists_controller.rb` entirely:

```ruby
class Books::ListsController < PublicListsController
  layout "books/application"

  def self.ranking_configuration_class
    Books::RankingConfiguration
  end

  def self.lists_query_class
    Books::ListsQuery
  end

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
end
```

The `include` lines, the two `before_action`s, `index` and `apply_caching` all move to the base. `show` is unchanged, character for character — copy it across rather than retyping.

- [ ] **Step 8: Run the whole books suite unchanged**

```bash
bin/rails test test/controllers/books test/lib/books test/lib/lists_query_test.rb
```

Expected: PASS with **no edits to any existing books test**. That is the entire acceptance criterion for this task: a behaviour-preserving refactor proven by tests written before it.

- [ ] **Step 9: Run the full suite**

```bash
bin/rails test
```

Expected: 0 failures. This touches a controller base class, so anything inheriting behaviour indirectly would surface here.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/lib app/controllers test/lib
bundle exec standardrb
git add app/lib/lists_query.rb app/lib/books/lists_query.rb app/controllers/public_lists_controller.rb app/controllers/books/lists_controller.rb test/lib/lists_query_test.rb
git commit -m "Extract ListsQuery and PublicListsController bases

Books is refactored onto them with no behaviour change -- its existing
tests pass untouched. A domain now supplies a list_type, a query class, a
layout and its own show action. normalize_sort lives on the base, so the
sort whitelist is no longer duplicated between controller and query."
```

---

### Task 3: Games query, routes, controller, and index view

With the bases in place this is small: a three-line query subclass, a controller that declares two class methods and keeps its own `show`, and a rewritten index view.

**Files:**
- Create: `app/lib/games/lists_query.rb`
- Modify: `config/routes.rb` — the games `scope "(/rc/:ranking_configuration_id)"` block
- Modify: `app/controllers/games/lists_controller.rb`
- Modify: `app/views/games/lists/index.html.erb`
- Test: `test/lib/games/lists_query_test.rb`, `test/controllers/games/lists_controller_test.rb`

**Interfaces:**
- Consumes: `ListsQuery` and `PublicListsController` from Task 2; `games_lists_path_with_rc` from Task 1; `Lists::CardComponent.new(ranked_list:, item_count:, path:, noun:)` from increment 1.
- Produces: route helper `games_lists_page_path(page)`; `Games::ListsQuery`.

- [ ] **Step 1: Write the games query test**

Create `test/lib/games/lists_query_test.rb`:

```ruby
require "test_helper"

module Games
  class ListsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:games_global)
      @heavy = create_list("Heavy Games List", weight: 90, activated_at: 3.days.ago, source: "IGN")
      @light = create_list("Light Games List", weight: 10, activated_at: 1.day.ago, source: "Polygon")
    end

    test "returns active games lists ordered by weight" do
      result = Games::ListsQuery.call(ranking_configuration: @rc)

      assert_equal [@heavy.list_id, @light.list_id], result.map(&:list_id)
    end

    test "excludes lists that are not active" do
      @light.list.update!(status: :unapproved)

      assert_equal [@heavy.list_id], Games::ListsQuery.call(ranking_configuration: @rc).map(&:list_id)
    end

    test "orders by activated_at descending for the newest sort" do
      result = Games::ListsQuery.call(ranking_configuration: @rc, sort: "newest")

      assert_equal [@light.list_id, @heavy.list_id], result.map(&:list_id)
    end

    test "filters by search" do
      assert_equal [@light.list_id], Games::ListsQuery.call(ranking_configuration: @rc, query: "Polygon").map(&:list_id)
    end

    test "returns only games lists" do
      result = Games::ListsQuery.call(ranking_configuration: @rc)

      assert result.all? { |ranked_list| ranked_list.list.is_a?(Games::List) }
    end

    private

    def create_list(name, weight:, activated_at: Time.current, source: nil)
      list = Games::List.create!(name: name, source: source, status: :active)
      list.update_column(:activated_at, activated_at)
      RankedList.create!(list: list, ranking_configuration: @rc, weight: weight)
    end
  end
end
```

`create_list` returns the **`RankedList`**, so assertions compare against `@heavy.list_id`, not `@heavy.id` — different numbers. `update_column` bypasses increment 1's `before_save` callback, which would otherwise overwrite `activated_at` with `Time.current`. The fixture `lists(:games_list)` is `approved` and never appears, which is why the expected counts are 2.

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/lib/games/lists_query_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Games::ListsQuery`.

- [ ] **Step 3: Write the games query**

Create `app/lib/games/lists_query.rb`:

```ruby
module Games
  class ListsQuery < ::ListsQuery
    def self.list_type
      "Games::List"
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

```bash
bin/rails test test/lib/games/lists_query_test.rb
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Add the routes**

In `config/routes.rb`, inside the games `scope "(/rc/:ranking_configuration_id)"` block, directly **above** the existing `get "lists", …`:

```ruby
      get "lists/page/1", to: redirect("/lists", status: 301)
      get "lists/:id/page/1", to: redirect("/lists/%{id}", status: 301), constraints: {id: /\d+/}
```

and directly **below** it:

```ruby
      get "lists/page/:page", to: "games/lists#index", as: :games_lists_page, constraints: {page: /\d+/}
```

Rails matches in declaration order, so the page-1 redirects must precede the generic routes. They target the non-rc canonical path deliberately: an alternate ranking configuration's page 1 is still duplicate content, and `/rc/…` is noindex anyway.

Also add `constraints: {id: /\d+/}` to the existing `get "lists/:id"` line, for symmetry with books.

- [ ] **Step 6: Write the failing controller tests**

Append to `test/controllers/games/lists_controller_test.rb`:

```ruby
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
  get "/lists?q=games"

  assert_response :success
  assert_not @controller.view_assigns["indexable"]
  assert_match(/no-store/, response.headers["Cache-Control"])
end

test "index is indexable and cacheable by default" do
  get "/lists"

  assert @controller.view_assigns["indexable"]
  assert_match(/public/, response.headers["Cache-Control"])
end

test "a nested q param does not blow up" do
  get "/lists?q[a]=1"

  assert_response :success
  assert_nil @controller.view_assigns["query"]
end

test "index pagination is path-based" do
  get "/lists"

  assert_equal "/lists/page/2", @controller.view_assigns["pagy"].page_url(2)
end

test "index resolves a path-based page" do
  seed_lists(60)

  get "/lists/page/2"

  assert_response :success
  assert_equal 2, @controller.view_assigns["pagy"].page
end

test "index 404s past the last page" do
  get "/lists/page/99"
  assert_response :not_found
end

test "page one of the index redirects to the canonical path" do
  get "/lists/page/1"
  assert_redirected_to "/lists"
  assert_response :moved_permanently
end
```

and this private helper beside the existing `seed_list_items`:

```ruby
def seed_lists(count)
  count.times do |i|
    list = Games::List.create!(name: "Filler List #{i}", status: :active)
    RankedList.create!(list: list, ranking_configuration: @rc, weight: i)
  end
end
```

- [ ] **Step 7: Run to verify they fail**

```bash
bin/rails test test/controllers/games/lists_controller_test.rb
```

Expected: FAIL — `@sort`, `@indexable` and `@query` are nil, and `/lists/page/2` has no route.

- [ ] **Step 8: Reduce the games controller**

Replace the top of `app/controllers/games/lists_controller.rb` so the class inherits the base and keeps only its own `show`:

```ruby
class Games::ListsController < PublicListsController
  layout "games/application"

  def self.ranking_configuration_class
    Games::RankingConfiguration
  end

  def self.lists_query_class
    Games::ListsQuery
  end

  def show
```

Delete the `include Pagy::Method`, `include Cacheable`, `include PathBasedPagination` lines, both `before_action` lines, and the whole old `index` method — all of that now lives on `PublicListsController`. Leave `show` exactly as it is for now; Task 4 rewrites it.

- [ ] **Step 9: Rewrite the index view**

Replace `app/views/games/lists/index.html.erb` entirely:

```erb
<%
  content_for :page_title, "Greatest Video Game Lists | The Greatest Games"
  content_for :meta_description, "Every curated list we aggregate to build the game rankings, weighted by quality, credibility and scope."
%>

<div class="space-y-8">
  <h1 class="text-3xl sm:text-4xl font-bold text-center text-balance">Greatest Video Game Lists</h1>

  <p class="max-w-3xl mx-auto text-center text-base-content/80">
    These are the lists we aggregate to build the rankings. Each one carries a weight based on its
    quality, credibility and scope — the higher the weight, the more it counts.
  </p>

  <div class="flex flex-col sm:flex-row gap-4 sm:items-center sm:justify-between">
    <%= form_with url: games_lists_path_with_rc, method: :get, class: "join" do |f| %>
      <%= f.hidden_field :sort, value: @sort %>
      <%= f.search_field :q, value: @query, placeholder: "Search lists",
            "aria-label": "Search lists by name, source or url",
            class: "input input-bordered join-item" %>
      <%= f.submit "Search", class: "btn btn-primary join-item" %>
    <% end %>

    <div class="join" role="group" aria-label="Sort lists">
      <%= link_to "Weight", games_lists_path_with_rc(q: @query),
            class: "btn join-item #{"btn-active" if @sort == "weight"}" %>
      <%= link_to "Recently added", games_lists_path_with_rc(sort: "newest", q: @query),
            class: "btn join-item #{"btn-active" if @sort == "newest"}" %>
    </div>
  </div>

  <% if @query %>
    <p class="text-center text-base-content/70">
      <%= pluralize(@pagy.count, "list") %> matching “<%= @query %>”.
      <%= link_to "Clear", games_lists_path, class: "link" %>
    </p>
  <% end %>

  <% if @ranked_lists.any? %>
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <% @ranked_lists.each do |ranked_list| %>
        <%= render Lists::CardComponent.new(
              ranked_list: ranked_list,
              item_count: @item_counts.fetch(ranked_list.list_id, 0),
              path: games_list_path(ranked_list.list_id, ranking_configuration_id: params[:ranking_configuration_id].presence),
              noun: "games"
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
      <div class="text-6xl mb-4">🎮</div>
      <h2 class="text-2xl font-bold mb-2">No lists found</h2>
      <p class="text-base-content/70">Try a different search.</p>
    </div>
  <% end %>
</div>
```

The `“ ”` are U+201C/U+201D. The outer `container mx-auto px-4 py-8` is gone — the layout provides it and nesting doubled the padding.

**Do not use the pre-existing `games_list_path_with_rc(list, rc)` for the card path.** It applies a
different rule — it includes the rc segment only when the configuration is *not* the default primary
— so on `/rc/4/lists` where 4 *is* the default primary, the cards would drop the segment while the
sort links kept it. The inline `ranking_configuration_id: params[:ranking_configuration_id].presence`
form matches `games_lists_path_with_rc`'s rule exactly, and is what the current games index view
already does.

- [ ] **Step 10: Run the tests**

```bash
bin/rails test test/controllers/games/lists_controller_test.rb
```

Expected: PASS. The pre-existing `show` tests still pass because `show` is untouched so far.

- [ ] **Step 11: Pin the index query count**

Append:

```ruby
test "index issues a bounded number of queries regardless of list count" do
  seed_lists(40)

  get "/lists"
  assert_response :success

  ActiveRecord::Base.connection.clear_query_cache
  assert_queries_count(4) { get "/lists" }
end
```

Run it, read the true count from the failure, set that number. Then **prove it discriminates**: temporarily replace `@item_counts` in `PublicListsController` with a per-list loop, confirm the pin FAILS, restore it, confirm it passes. Report both. Then bump `seed_lists(40)` to `seed_lists(80)` and confirm the count is unchanged.

- [ ] **Step 12: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/games app/controllers/games app/views/games/lists test/lib/games test/controllers/games config/routes.rb
bundle exec standardrb
git add app/lib/games/lists_query.rb config/routes.rb app/controllers/games/lists_controller.rb app/views/games/lists/index.html.erb test/lib/games test/controllers/games/lists_controller_test.rb
git commit -m "Convert the games list index to the shared base and card

Games::ListsQuery is now three lines and the controller declares two
class methods; index, caching and item counts come from
PublicListsController. Replaces the bare limit(50) that truncated
silently at list 51, and the includes(list: :list_items) that loaded
every item to call .size."
```

---

### Task 4: `Games::ListsController#show` and the show view

Three changes: only active lists resolve, the weight breakdown replaces the summary component, and the Turbo Frame goes away.

**Files:**
- Modify: `app/controllers/games/lists_controller.rb`
- Modify: `app/views/games/lists/show.html.erb`
- Test: `test/controllers/games/lists_controller_test.rb`

**Interfaces:**
- Consumes: `Lists::WeightBreakdownComponent.new(ranked_list:)` from increment 1 — `ranked_list` may be nil, in which case it renders "This list is not used for any active rankings."
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Rewrite the test setup so existing tests keep working**

`lists(:games_list)` is `approved`, so once `show` filters to active every existing test fetching it will 404. **Do not change the fixture** — 14 test files depend on its status.

Replace the `setup` block in `test/controllers/games/lists_controller_test.rb`:

```ruby
setup do
  host! "dev.thegreatest.games"
  @rc = ranking_configurations(:games_global)
  @list = Games::List.create!(name: "Games Test List", source: "Games Source", status: :active)
  @ranked_list = RankedList.create!(list: @list, ranking_configuration: @rc, weight: 8)
end
```

Two existing tests call `lists(:games_list)` inside their body rather than using `@list` — "list show pagination is path-based" and "list show resolves a path-based page". Change both to use `@list`.

- [ ] **Step 2: Write the failing tests**

Append:

```ruby
test "show 404s for a non-active list" do
  @list.update!(status: :unapproved)

  get "/lists/#{@list.id}"

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

test "page one of a list redirects to the canonical path" do
  get "/lists/#{@list.id}/page/1"

  assert_redirected_to "/lists/#{@list.id}"
  assert_response :moved_permanently
end

test "show survives a list item whose listable no longer exists" do
  ListItem.create!(list: @list, listable_type: "Games::Game", listable_id: 999_999_999, position: 1)

  get "/lists/#{@list.id}"

  assert_response :success
end
```

- [ ] **Step 3: Run to verify they fail**

```bash
bin/rails test test/controllers/games/lists_controller_test.rb
```

Expected: FAIL — the non-active list still renders 200, `@indexable` is nil, and `/lists/:id/page/1` renders instead of redirecting.

- [ ] **Step 4: Rewrite the show action**

Replace `show` in `app/controllers/games/lists_controller.rb`:

```ruby
  def show
    @list = Games::List.where(status: :active).find_by!(id: params[:id])
    @ranked_list = @ranking_configuration.ranked_lists.find_by(list: @list)
    @indexable = @ranked_list.present?

    list_items_query = @list.list_items.includes(
      listable: [
        :categories,
        :platforms,
        {game_companies: :company},
        {primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}}}
      ]
    ).order(Arel.sql("list_items.position ASC NULLS LAST, list_items.id ASC"))

    @pagy, @pagy_list_items = pagy_path(list_items_query, limit: 100)
  end
```

Changes: `status: :active` scoping with `find_by!`, `@indexable`, and the `list_items.id ASC` tiebreak — 1,002 of games' 2,706 list items have no position, so without it their order is unstable across requests. The preload chain is unchanged; keep it exactly. `@pagy_list_items` keeps its name because the view already uses it.

- [ ] **Step 5: Update the show view**

Three edits to `app/views/games/lists/show.html.erb`:

1. Change the outer `<div class="container mx-auto px-4 py-8">` to `<div class="space-y-8">`.
2. Replace the `Lists::SimplePenaltySummaryComponent` render **and the `<div class="card bg-base-200 shadow-xl mb-6">` wrapper around it** with one line — the breakdown component brings its own card:

```erb
    <%= render Lists::WeightBreakdownComponent.new(ranked_list: @ranked_list) %>
```

Move it **outside** the `<% if @ranked_list %>` guard that currently wraps that block. The component handles a nil `ranked_list` itself and renders "This list is not used for any active rankings", which is exactly what a list outside the ranking configuration needs.

3. Remove the `turbo_frame_tag "list_items"` wrapper, keeping its contents. Pagination becomes full-page navigation. **Keep the `<% next unless list_item.item %>` guard** inside the loop.

Leave `Games::CardComponent` and the game grid classes alone — games' cards are a different aspect ratio from books' and that ladder is deliberate.

**Do not delete `Lists::SimplePenaltySummaryComponent`** — `music/songs/lists/show` and `music/albums/lists/show` still render it and music is out of scope. Its test must stay green.

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/controllers/games/lists_controller_test.rb test/components/lists
```

Expected: PASS, including the pre-existing `SimplePenaltySummaryComponent` test.

- [ ] **Step 7: Pin the show query count**

Append:

```ruby
test "show issues a bounded number of queries and preloads covers" do
  game = games_games(:super_mario_bros)
  ListItem.create!(list: @list, listable: game, position: 1)
  seed_list_items(@list, 20)

  covered = [game] + Games::Game.where(title: (0...5).map { |i| "Filler Game #{i}" }).to_a
  covered.each do |covered_game|
    image = Image.new(parent: covered_game, primary: true)
    image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
    image.save!
  end

  get "/lists/#{@list.id}"
  assert_response :success

  ActiveRecord::Base.connection.clear_query_cache
  assert_queries_count(12) { get "/lists/#{@list.id}" }
end
```

Two things to check before running, because both have made this exact pin vacuous before:

- **Verify the games games fixture name.** `games_games(:super_mario_bros)` must exist — read `test/fixtures/games/games.yml` and use whatever the first entry is actually called. Do not invent a name.
- **Verify `seed_list_items`' filler title format.** The existing helper names them `"Filler Game #{i}"`; the `covered` lookup must match exactly or it returns nothing and the pin goes vacuous.

Attaching real covers is load-bearing: with no attached image the card's cover lookup short-circuits and dropping the preload is a no-op on the count. Prove it discriminates by temporarily removing `{primary_image: …}` from the `includes` chain and confirming the count jumps, then restore it.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/games app/views/games/lists test/controllers/games
bundle exec standardrb
git add app/controllers/games/lists_controller.rb app/views/games/lists/show.html.erb test/controllers/games/lists_controller_test.rb
git commit -m "Scope the games list page to active lists and show the full breakdown

/lists/:id served any list including the 133 unapproved submissions --
the same leak the books page closed. Swaps the penalty summary for the
full weight breakdown, adds a list_items.id tiebreak for the 1,002 items
with no position, and drops the Turbo Frame so pagination advances the
URL."
```

---

### Task 5: E2E spec and full-suite verification

**Files:**
- Modify: `e2e/tests/games/public/lists.spec.ts`

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing.

- [ ] **Step 1: Fix the broken selectors**

The current markup wrapped each card in a link, so the spec locates cards as `page.locator('a.card')`. `Lists::CardComponent` renders `div.card` with a stretched link on the title.

There are **six** `a.card` locators — lines 14, 21, 33, 46, 58 and 70. Replace each with
`page.locator('.card h3 a')`. Line 22 then reads the card's name via
`firstListCard.locator('.card-title').textContent()`; since the locator is now the anchor itself,
change it to `firstListCard.textContent()`.

Leave line 75 alone — `div.card .card-title a` targets *game* cards on the show page, which still
render through `Games::CardComponent` and are unchanged by this increment.

- [ ] **Step 2: Add coverage for the new controls**

Append inside the existing `test.describe`:

```typescript
test('pagination links are path-based', async ({ page }) => {
  await page.goto('/lists');

  await expect(page.locator('nav.pagy').first()).toBeVisible();
});

test('the newest sort is reachable and keeps its state', async ({ page }) => {
  await page.goto('/lists');

  await page.getByRole('link', { name: 'Recently added' }).click();

  await expect(page).toHaveURL(/sort=newest/);
});

test('search narrows the results', async ({ page }) => {
  await page.goto('/lists?q=the');

  await expect(page.getByText(/matching/)).toBeVisible();
});

test('page one redirects to the canonical path', async ({ page }) => {
  await page.goto('/lists/page/1');

  await expect(page).toHaveURL(/\/lists$/);
});

test('the list page shows the full weight breakdown', async ({ page }) => {
  await page.goto('/lists');
  await page.locator('.card h3 a').first().click();

  await expect(page.getByRole('heading', { name: 'How good is this list?' })).toBeVisible();
  await expect(page.getByText('Base weight')).toBeVisible();
});
```

A dev server is already running; do not start one. **If a selector misses, fix the selector — never weaken an assertion.** Games has only 19 active lists, so `?q=the` may match none; if so, pick a substring that does match rather than deleting the assertion.

- [ ] **Step 3: Run the spec**

```bash
yarn test:e2e e2e/tests/games/public/lists.spec.ts
```

Expected: PASS, including the pre-existing tests.

- [ ] **Step 4: Run the full gate**

```bash
bin/rails db:test:prepare
bin/rails test
bundle exec standardrb
yarn build:all
```

Expected: 0 failures, no offenses, clean build. Record the suite total before starting so the delta is checkable.

`bin/rails test:system` has 5 pre-existing `set_rack_session` errors in the music-admin wizard test — unrelated, reproduces on `main`. **If any NEW system failure appears, report it rather than explaining it away.**

- [ ] **Step 5: Sanity-check against real dev data**

```bash
bin/rails runner 'rc = Games::RankingConfiguration.default_primary; puts "games lists: #{Games::ListsQuery.call(ranking_configuration: rc).count} (expect 19)"; brc = Books::RankingConfiguration.default_primary; puts "books lists: #{Books::ListsQuery.call(ranking_configuration: brc).count} (expect 622)"'
```

Both numbers matter — the books one proves the Task 2 refactor did not change its behaviour against real data.

- [ ] **Step 6: Commit**

```bash
git add e2e/tests/games/public/lists.spec.ts
git commit -m "Update the games lists E2E spec for the shared card component

The card is now a div with a stretched link on the title rather than a
whole-card anchor, so the a.card selectors no longer match. Adds coverage
for sorting, search, path-based pagination and the weight breakdown."
```

---

## Verification checklist

- [ ] `bin/rails test` passes with zero failures
- [ ] `bundle exec standardrb` reports no offenses
- [ ] `yarn build:all` succeeds
- [ ] `yarn test:e2e e2e/tests/games/public/lists.spec.ts` passes
- [ ] `Games::ListsQuery` returns 19 and `Books::ListsQuery` returns 622 against dev
- [ ] **No existing books test was edited** — the Task 2 refactor is behaviour-preserving
- [ ] An unapproved games list 404s on `/lists/:id`
- [ ] Both query pins were seen to fail before being set, and hold when rows are added
- [ ] `/rc/:id/lists` keeps its rc segment in the sort links, search form and card hrefs, in **both** domains
- [ ] `Lists::SimplePenaltySummaryComponent` and its test are untouched
- [ ] Nothing pushed and no PR opened

## Landmine summary

1. `lists(:games_list)` is `approved`; 14 files use it. Rewrite the test's `setup`, never the fixture.
2. Games serves 133 unapproved lists publicly today. Closing that is intentional and changes behaviour.
3. The E2E spec's `a.card` selectors break on the shared component.
4. Games routes are already inside `scope "(/rc/…)"` — do not add separate rc routes.
5. `clear_query_cache` before every `assert_queries_count`, and attach real covers or the preload pin is vacuous.
6. `params[:q].is_a?(String)` or a nested `q[a]=1` 500s in `url_for`.
7. `Arel.sql` around any order string containing `NULLS LAST`.
8. Page-1 redirects must precede the generic pagination routes.
9. Task 2 is a refactor: if an existing books test fails, fix the base class, not the test.
