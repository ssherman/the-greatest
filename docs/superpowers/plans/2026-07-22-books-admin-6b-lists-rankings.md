# Books Admin — Increment 6b: Lists + Ranking Configurations + Legacy Date-Penalty Parity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the books admin's Lists and Ranking-Configuration surfaces, and make the new books rankings reproduce the legacy TheGreatestBooks date penalty.

**Architecture:** `Admin::Books::ListsController` / `Admin::Books::RankingConfigurationsController` are thin subclasses of their shared base controllers (like games); lists views are one-line shared-component wrappers, RC needs no views (inherits the shared ones). The ranking parity is a two-part fix: `Books::Book#release_year` (the generic interface the item-ranking calculator checks for) and two legacy edge cases (`yearly_award? → max`, `nil item year → max`) added to the shared `ItemRankings::Calculator`.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, ViewComponent, Turbo Frames, DaisyUI 5, Playwright.

## Global Constraints

- Run all commands from `web-app/`. Lint with `bundle exec standardrb` (NOT rubocop). Do not run brakeman.
- Namespace all books code `Books::`; tests mirror the namespace (`module Admin; module Books`).
- Controller tests assert **behavior only** (status, redirect, record deltas) — never HTML/CSS/copy.
- Check actual fixture names before referencing; auth in integration tests via `sign_in_as(user, stub_auth: true)`; turbo/JSON requests use `as: :turbo_stream` / `as: :json`.
- `raise_on_missing_callback_actions` is ON in dev+test — never name an action in a `before_action only: […]` list before it exists.
- **STI subclasses have no per-model fixtures** (a `test/fixtures/books/lists.yml` would break the suite). Use the shared `test/fixtures/lists.yml` (which has `Books::List` rows) or build records in-test (the games controller tests build lists in-test — mirror that).
- **`ItemRankings::Calculator#calculate_score_penalty` is `private`.** The parity fix is the crux of this increment and its exact per-branch values can't be isolated through the public `call` (the penalty is one input among list weight/position/bonus-pool to the WeightedListRank gem). Task 2 therefore verifies the branch parity by calling the method via `send` — a deliberate, scoped exception to "never test private methods," because it directly pins legacy behavior.
- The date penalty only runs when `ranking_configuration.apply_list_dates_penalty?` is true (`item_rankings/calculator.rb:80`).
- Verify with `bin/rails test` (+ `test:system` for UI) and `bundle exec standardrb`; Playwright via `yarn test:e2e`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Branch `books-admin-6b` (already created off main).

---

### Task 1: `Books::Book#release_year`

`Books::Book` exposes `first_published_year`; every other rankable item (`Music::Album`, `Games::Game`, `Movies::Movie`) exposes `release_year`, which the shared item-ranking calculator checks via `respond_to?(:release_year)`. Add the alias so books participate in the date penalty (and fix the known `MyListsController#csv_row` gap).

**Files:**
- Modify: `web-app/app/models/books/book.rb`
- Test: `web-app/test/models/books/book_test.rb`

**Interfaces:**
- Produces: `Books::Book#release_year → Integer | nil` (returns `first_published_year`).

- [ ] **Step 1: Write the failing test**

Add to `web-app/test/models/books/book_test.rb` (inside the existing `Books::BookTest`):

```ruby
  test "release_year returns first_published_year" do
    book = ::Books::Book.new(first_published_year: 1869)
    assert_equal 1869, book.release_year
  end

  test "release_year is nil when first_published_year is nil" do
    assert_nil ::Books::Book.new(first_published_year: nil).release_year
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/books/book_test.rb -n "/release_year/"`
Expected: FAIL — `NoMethodError: undefined method 'release_year'`.

- [ ] **Step 3: Add the method**

In `web-app/app/models/books/book.rb`, add inside the class body (near the other instance methods):

```ruby
  # The item-ranking calculator and CSV export use the generic `release_year`
  # interface that every other medium exposes; books store it as first_published_year.
  def release_year
    first_published_year
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/books/book_test.rb -n "/release_year/"`
Expected: PASS.

- [ ] **Step 5: standardrb + commit**

Run: `bundle exec standardrb app/models/books/book.rb test/models/books/book_test.rb` → no offenses.

```bash
git add app/models/books/book.rb test/models/books/book_test.rb
git commit -m "$(cat <<'EOF'
Add Books::Book#release_year delegating to first_published_year (inc 6b task 1)

Matches the generic item interface the item-ranking calculator and CSV
export expect; every other medium already exposes release_year.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Legacy date-penalty parity in the shared `ItemRankings::Calculator`

Reproduce the legacy TheGreatestBooks date penalty: a yearly-award list, or an item with no publication year, takes the full penalty — checked **before** the `list.year_published` guard (legacy order). This is a shared change (all domains); it's inert for music/games award lists (0 exist) and re-ranks ~1% of their nil-year items.

**Files:**
- Modify: `web-app/app/lib/item_rankings/calculator.rb` (rewrite `calculate_score_penalty`, ~line 90)
- Test: `web-app/test/lib/item_rankings/books/calculator_test.rb` (create)
- Test: `web-app/test/lib/item_rankings/music/albums/calculator_test.rb` (add one cross-domain assertion)

**Interfaces:**
- Consumes: `Books::Book#release_year` (Task 1); `ranking_configuration.{apply_list_dates_penalty?, max_list_dates_penalty_age, max_list_dates_penalty_percentage}`; `list.{year_published, yearly_award?}`; `list_item.listable`.
- Produces: `ItemRankings::Calculator#calculate_score_penalty(list, list_item) → Float | nil` with legacy branch order.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/item_rankings/books/calculator_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module ItemRankings
  module Books
    class CalculatorTest < ActiveSupport::TestCase
      setup do
        @rc = ranking_configurations(:books_global)
        @rc.update!(apply_list_dates_penalty: true, max_list_dates_penalty_age: 50, max_list_dates_penalty_percentage: 80)
        @calculator = ItemRankings::Books::Calculator.new(@rc)
      end

      def penalty_for(list_year:, first_published_year:, yearly_award: false)
        list = ::Books::List.create!(name: "L#{rand(1_000_000)}", status: :approved, year_published: list_year, yearly_award: yearly_award)
        book = ::Books::Book.create!(title: "B#{rand(1_000_000)}", first_published_year: first_published_year)
        list_item = list.list_items.create!(listable: book, position: 1)
        @calculator.send(:calculate_score_penalty, list, list_item)
      end

      test "book older than the list within max_age gets a graduated penalty" do
        # year_difference = 20; ((50-20)/50)*80/100 = 0.48
        assert_in_delta 0.48, penalty_for(list_year: 2000, first_published_year: 1980), 0.0001
      end

      test "book newer than the list gets the max penalty" do
        assert_in_delta 0.80, penalty_for(list_year: 2000, first_published_year: 2005), 0.0001
      end

      test "book older than max_age gets no penalty" do
        # year_difference = 60 > 50
        assert_nil penalty_for(list_year: 2000, first_published_year: 1940)
      end

      test "item with no publication year gets the max penalty" do
        assert_in_delta 0.80, penalty_for(list_year: 2000, first_published_year: nil), 0.0001
      end

      test "a yearly-award list gives the item the max penalty even with a good year gap" do
        # would otherwise be no penalty (diff 60 > 50); award forces max
        assert_in_delta 0.80, penalty_for(list_year: 2000, first_published_year: 1940, yearly_award: true), 0.0001
      end

      test "a yearly-award list with no year_published still max-penalizes" do
        assert_in_delta 0.80, penalty_for(list_year: nil, first_published_year: 1980, yearly_award: true), 0.0001
      end

      test "no penalty config yields nil" do
        @rc.update!(max_list_dates_penalty_age: nil, max_list_dates_penalty_percentage: nil)
        assert_nil penalty_for(list_year: 2000, first_published_year: 1990)
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failures**

Run: `bin/rails test test/lib/item_rankings/books/calculator_test.rb`
Expected: FAIL — with the current code, `item with no publication year` returns `nil` (line 95 skip) not `0.80`; `yearly-award` cases don't force max; `yearly-award with no year_published` returns nil at the `list.year_published` guard.

- [ ] **Step 3: Rewrite `calculate_score_penalty`**

Replace the method in `web-app/app/lib/item_rankings/calculator.rb` (currently ~lines 90-115) with:

```ruby
    def calculate_score_penalty(list, list_item)
      max_age = ranking_configuration.max_list_dates_penalty_age
      max_penalty_percentage = ranking_configuration.max_list_dates_penalty_percentage
      return nil if max_age.nil? || max_penalty_percentage.nil?

      item = list_item.listable
      item_year = (item.respond_to?(:release_year) ? item.release_year : nil)

      # Legacy parity: award lists and items with no known year take the full
      # penalty, regardless of the list's own publication year (checked first).
      return max_penalty_percentage / 100.0 if list.yearly_award? || item_year.nil?

      return nil unless list.year_published.present?

      year_difference = list.year_published - item_year

      penalty = if year_difference <= 0
        max_penalty_percentage / 100.0
      elsif year_difference > max_age
        nil
      else
        p = ((max_age - year_difference).to_f / max_age) * max_penalty_percentage
        p / 100.0
      end

      (penalty == 0) ? nil : penalty
    end
```

- [ ] **Step 4: Run books calculator test to verify pass**

Run: `bin/rails test test/lib/item_rankings/books/calculator_test.rb`
Expected: PASS (all 7).

- [ ] **Step 5: Add the cross-domain assertion (shared behavior)**

Add to `web-app/test/lib/item_rankings/music/albums/calculator_test.rb` (inside the existing test class), pinning that the nil-year rule is shared, not books-only. Reuse the RC's already-wired fixture list/album (no fragile `create!`); `update_column` bypasses validations for the nil-year setup:

```ruby
        test "an album with no release year gets the max penalty (shared date-penalty parity)" do
          @ranking_configuration.update!(apply_list_dates_penalty: true, max_list_dates_penalty_age: 30, max_list_dates_penalty_percentage: 50)
          list_item = @ranking_configuration.ranked_lists.first.list.list_items.first
          list_item.list.update!(year_published: 2000)
          list_item.listable.update_column(:release_year, nil)
          assert_in_delta 0.50, @calculator.send(:calculate_score_penalty, list_item.list, list_item), 0.0001
        end
```

- [ ] **Step 6: Run both calculator tests + full item_rankings suite**

Run: `bin/rails test test/lib/item_rankings/`
Expected: PASS — no regressions in the existing music/movies/games calculator tests.

- [ ] **Step 7: standardrb + commit**

Run: `bundle exec standardrb app/lib/item_rankings/calculator.rb test/lib/item_rankings/books/calculator_test.rb test/lib/item_rankings/music/albums/calculator_test.rb` → no offenses.

```bash
git add app/lib/item_rankings/calculator.rb test/lib/item_rankings/books/calculator_test.rb test/lib/item_rankings/music/albums/calculator_test.rb
git commit -m "$(cat <<'EOF'
Match legacy date penalty: yearly-award + nil-year items take max penalty (inc 6b task 2)

Reproduces the legacy TheGreatestBooks calculate_score_penalty: a yearly-award
list, or an item with no publication year, gets the full penalty, checked
before the list.year_published guard. Shared across domains (inert for
music/games award lists; re-ranks their nil-year items, ~1%).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Books Lists admin

Thin `Admin::Books::ListsController` (games minus the wizard), `Books::List` in the `LISTS` registry, one-line views, the DomainNav "Lists" item, and the shared `ShowComponent` wizard-button guard.

**Files:**
- Modify: `web-app/config/routes.rb` (books admin namespace)
- Create: `web-app/app/controllers/admin/books/lists_controller.rb`
- Create: `web-app/app/views/admin/books/lists/{index,show,new,edit}.html.erb` + `{_form,_table}.html.erb`
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`LISTS`)
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`CONFIGS[:books][:items]`)
- Modify: `web-app/app/components/admin/lists/show_component.html.erb` (wizard guard)
- Test: `web-app/test/controllers/admin/books/lists_controller_test.rb` (create) — its `show` test asserts no "Launch Wizard" button, covering the wizard guard for books
- Test: `web-app/test/lib/admin/domain_routing_test.rb`, `web-app/test/lib/admin/domain_nav_test.rb`

**Interfaces:**
- Produces routes: `admin_books_lists_path`, `admin_books_list_path(l)`, `new_/edit_admin_books_list_path`.
- Produces: `Admin::Books::ListsController` (all actions inherited from `Admin::ListsBaseController`).

- [ ] **Step 1: Add the route**

In `web-app/config/routes.rb`, inside the books admin namespace (`module: "admin/books", as: "admin_books"`), add — **no** wizard/`items` nested routes (books list items ride the global shared `ListItemsController`):

```ruby
      resources :lists
```

Verify: `bin/rails routes -g admin_books_lists` → `admin_books_lists`, `admin_books_list`, `new_/edit_admin_books_list`.

- [ ] **Step 2: Write the failing controller test**

Create `web-app/test/controllers/admin/books/lists_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        host! Rails.application.config.domains[:books]

        @list = ::Books::List.create!(name: "Test Books List", status: :approved, year_published: 2020)
      end

      test "index redirects unauthenticated users" do
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "show renders without a wizard button" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success
        assert_no_match "Launch Wizard", response.body
      end

      test "creates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", 1) do
          post admin_books_lists_path, params: {books_list: {name: "New List", status: "unapproved"}}
        end
        assert_redirected_to admin_books_list_path(::Books::List.order(:id).last)
      end

      test "updates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_list_path(@list), params: {books_list: {name: "Renamed"}}
        @list.reload
        assert_redirected_to admin_books_list_path(@list)
        assert_equal "Renamed", @list.name
      end

      test "destroys a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", -1) do
          delete admin_books_list_path(@list)
        end
        assert_redirected_to admin_books_lists_path
      end
    end
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `bin/rails test test/controllers/admin/books/lists_controller_test.rb`
Expected: FAIL — `Admin::Books::ListsController` uninitialized.

- [ ] **Step 4: Create the controller**

Create `web-app/app/controllers/admin/books/lists_controller.rb`:

```ruby
class Admin::Books::ListsController < Admin::ListsBaseController
  include Admin::DomainScopedAuth

  private

  def policy_class = ::Books::ListPolicy

  def item_label = "Book"

  protected

  def list_class = ::Books::List

  def lists_path = admin_books_lists_path

  def list_path(list) = admin_books_list_path(list)

  def new_list_path = new_admin_books_list_path

  def edit_list_path(list) = edit_admin_books_list_path(list)

  def param_key = :books_list

  def items_count_name = "books_count"

  def listable_includes = [:authors]

  def wizard_path(_list) = nil
end
```

- [ ] **Step 5: Create the views (one-line component wrappers, mirroring games)**

`web-app/app/views/admin/books/lists/index.html.erb`:
```erb
<% content_for :title, "Book Lists" %>
<%= render Admin::Lists::IndexComponent.new(lists: @lists, pagy: @pagy, domain_config: domain_config, selected_status: @selected_status, search_query: @search_query) %>
```
`_table.html.erb`:
```erb
<%= render Admin::Lists::TableComponent.new(lists: lists, pagy: pagy, domain_config: domain_config, search_query: search_query) %>
```
`show.html.erb`:
```erb
<% content_for :title, @list.name %>
<%= render Admin::Lists::ShowComponent.new(list: @list, domain_config: domain_config) %>
```
`new.html.erb`:
```erb
<% content_for :title, "New Book List" %>
<%= render Admin::Lists::NewComponent.new(list: @list, domain_config: domain_config) %>
```
`edit.html.erb`:
```erb
<% content_for :title, "Edit #{@list.name}" %>
<%= render Admin::Lists::EditComponent.new(list: @list, domain_config: domain_config) %>
```
`_form.html.erb`:
```erb
<%= render Admin::Lists::FormComponent.new(list: @list, domain_config: domain_config) %>
```

- [ ] **Step 6: Guard the shared wizard button**

In `web-app/app/components/admin/lists/show_component.html.erb`, wrap the "Launch Wizard" `link_to` (currently `<%= link_to domain_config[:wizard_path_proc].call(list), class: "btn btn-secondary" do %> … <% end %>`) in a presence guard:

```erb
      <% wizard_link = domain_config[:wizard_path_proc].call(list) %>
      <% if wizard_link.present? %>
        <%= link_to wizard_link, class: "btn btn-secondary" do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
            <path fill-rule="evenodd" d="M5 2a1 1 0 011 1v1h1a1 1 0 010 2H6v1a1 1 0 01-2 0V6H3a1 1 0 010-2h1V3a1 1 0 011-1zm0 10a1 1 0 011 1v1h1a1 1 0 110 2H6v1a1 1 0 11-2 0v-1H3a1 1 0 110-2h1v-1a1 1 0 011-1zM12 2a1 1 0 01.967.744L14.146 7.2 17.5 9.134a1 1 0 010 1.732l-3.354 1.935-1.18 4.455a1 1 0 01-1.933 0L9.854 12.8 6.5 10.866a1 1 0 010-1.732l3.354-1.935 1.18-4.455A1 1 0 0112 2z" clip-rule="evenodd" />
          </svg>
          <span>Launch Wizard</span>
          <% if list.wizard_state.present? && list.wizard_state["completed_at"].blank? %>
            <span class="badge badge-warning badge-sm">In Progress</span>
          <% end %>
        <% end %>
      <% end %>
```

- [ ] **Step 7: Register the list + nav item**

In `web-app/app/lib/admin/domain_routing.rb`, add to `LISTS`:
```ruby
      "Books::List" => {
        domain: :books,
        listable_type: "Books::Book",
        item_label: "Book",
        path: ->(l) { URL_HELPERS.admin_books_list_path(l) },
        autocomplete_path: -> { URL_HELPERS.search_admin_books_books_path }
      },
```

In `web-app/app/lib/admin/domain_nav.rb`, append to `CONFIGS[:books][:items]` (after the Categories item):
```ruby
          {label: "Lists", icon: :list, path: -> { URL_HELPERS.admin_books_lists_path }},
```

- [ ] **Step 8: Registry + nav + component tests**

Add to `web-app/test/lib/admin/domain_routing_test.rb`:
```ruby
    test "LISTS resolves a books list to the books book typeahead" do
      config = Admin::DomainRouting.list_config(::Books::List.new)
      assert_equal :books, config[:domain]
      assert_equal "Book", config[:item_label]
      assert_equal Rails.application.routes.url_helpers.search_admin_books_books_path, config[:autocomplete_path]
    end
```

Add to `web-app/test/lib/admin/domain_nav_test.rb`:
```ruby
    test "the books nav includes a Lists item" do
      item = Admin::DomainNav.config_for(:books)[:items].find { |i| i[:label] == "Lists" }
      assert item, "books nav is missing a Lists item"
      assert_equal "/admin/lists", item[:path]
    end
```

(The wizard guard is verified for books by the controller `show` test above — `assert_no_match "Launch Wizard"`. The games/music direction, where the button still renders, is covered by their existing lists show tests, which render the same shared component with a real `wizard_path`.)

- [ ] **Step 9: Run the lists tests**

Run: `bin/rails test test/controllers/admin/books/lists_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb test/controllers/admin/games/lists_controller_test.rb`
Expected: PASS — including the games lists show test (confirms the wizard-guard change didn't hide the button where a real path exists).

- [ ] **Step 10: standardrb + commit**

Run standardrb on the touched Ruby files → no offenses.

```bash
git add config/routes.rb app/controllers/admin/books/lists_controller.rb app/views/admin/books/lists app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb app/components/admin/lists/show_component.html.erb test/controllers/admin/books/lists_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "$(cat <<'EOF'
Add books lists admin, no wizard (inc 6b task 3)

Thin Admin::Books::ListsController + one-line views + Books::List in the
LISTS registry + DomainNav Lists item. Books has no wizard: wizard_path
returns nil and the shared Lists::ShowComponent guards the Launch Wizard
button on the path being present.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Books Ranking Configurations admin

Thin `Admin::Books::RankingConfigurationsController` (no new views — inherits the shared RC views), the registry `path:` that gates books-domain auth for the shared ranked-lists/penalty views, and the two denial-test flips.

**Files:**
- Modify: `web-app/config/routes.rb` (books admin namespace)
- Create: `web-app/app/controllers/admin/books/ranking_configurations_controller.rb`
- Modify: `web-app/app/lib/admin/domain_routing.rb` (`RANKING_CONFIGURATIONS`)
- Modify: `web-app/app/lib/admin/domain_nav.rb` (`CONFIGS[:books][:items]`)
- Test: `web-app/test/controllers/admin/books/ranking_configurations_controller_test.rb` (create)
- Test: `web-app/test/controllers/admin/ranked_lists_controller_test.rb`, `web-app/test/controllers/admin/penalty_applications_controller_test.rb` (flip denial tests)
- Test: `web-app/test/lib/admin/domain_routing_test.rb`, `web-app/test/lib/admin/domain_nav_test.rb`

**Interfaces:**
- Produces routes: `admin_books_ranking_configurations_path`, `admin_books_ranking_configuration_path(rc)`, `new_/edit_admin_books_ranking_configuration_path`, `execute_action_admin_books_ranking_configuration_path(rc)`, `index_action_admin_books_ranking_configurations_path`.

- [ ] **Step 1: Add the route**

In the books admin namespace of `web-app/config/routes.rb`:
```ruby
      resources :ranking_configurations do
        member { post :execute_action }
        collection { post :index_action }
      end
```
Verify: `bin/rails routes -g admin_books_ranking`.

- [ ] **Step 2: Write the failing controller test**

Create `web-app/test/controllers/admin/books/ranking_configurations_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  module Books
    class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @rc = ranking_configurations(:books_global)
        host! Rails.application.config.domains[:books]
      end

      test "index redirects unauthenticated users" do
        get admin_books_ranking_configurations_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_response :success
      end

      test "index allows a books domain viewer to read" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_ranking_configurations_path
        assert_response :success
      end

      test "show for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_ranking_configuration_path(@rc)
        assert_response :success
      end

      test "index tolerates a sort-injection attempt" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_nothing_raised do
          get admin_books_ranking_configurations_path(sort: "'; DROP TABLE ranking_configurations; --")
        end
        assert_response :success
      end

      test "creates a ranking configuration for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::RankingConfiguration.count", 1) do
          post admin_books_ranking_configurations_path, params: {ranking_configuration: {name: "New Books RC"}}
        end
        assert_redirected_to admin_books_ranking_configuration_path(::Books::RankingConfiguration.order(:id).last)
      end

      test "does not allow a books editor to create (manage required)" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        assert_no_difference("::Books::RankingConfiguration.count") do
          post admin_books_ranking_configurations_path, params: {ranking_configuration: {name: "Nope"}}
        end
      end
    end
  end
end
```

(The base controller uses `params.require(:ranking_configuration)` — a generic key, no `param_key` hook. `Books::RankingConfiguration.new(name: "x")` is valid on its own: `algorithm_version`/`exponent`/`bonus_pool_percentage`/`min_list_weight` all carry DB defaults, so `name` alone creates successfully.)

- [ ] **Step 3: Run to verify failure**

Run: `bin/rails test test/controllers/admin/books/ranking_configurations_controller_test.rb`
Expected: FAIL — controller uninitialized.

- [ ] **Step 4: Create the controller**

Create `web-app/app/controllers/admin/books/ranking_configurations_controller.rb`:

```ruby
module Admin
  module Books
    class RankingConfigurationsController < Admin::RankingConfigurationsController
      include Admin::DomainScopedAuth

      private

      def policy_class = ::Books::RankingConfigurationPolicy

      def domain_name = "books"

      def ranking_configuration_class = ::Books::RankingConfiguration

      def ranking_configurations_path(**opts) = admin_books_ranking_configurations_path(**opts)

      def ranking_configuration_path(config, **opts) = admin_books_ranking_configuration_path(config, **opts)

      def new_ranking_configuration_path = new_admin_books_ranking_configuration_path

      def edit_ranking_configuration_path(config) = edit_admin_books_ranking_configuration_path(config)

      def execute_action_ranking_configuration_path(config, **opts) = execute_action_admin_books_ranking_configuration_path(config, **opts)

      def index_action_ranking_configurations_path(**opts) = index_action_admin_books_ranking_configurations_path(**opts)
    end
  end
end
```

- [ ] **Step 5: Register the RC path + nav item**

In `web-app/app/lib/admin/domain_routing.rb`, change the `"Books::RankingConfiguration"` entry's `path`:
```ruby
      "Books::RankingConfiguration" => {
        domain: :books,
        list_type: "Books::List",
        ranked_item_includes: nil,
        path: ->(rc) { URL_HELPERS.admin_books_ranking_configuration_path(rc) }
      },
```

In `web-app/app/lib/admin/domain_nav.rb`, append to `CONFIGS[:books][:items]`:
```ruby
          {label: "Rankings", icon: :chart, path: -> { URL_HELPERS.admin_books_ranking_configurations_path }}
```

- [ ] **Step 6: Flip the two denial tests (auth landmine)**

In `web-app/test/controllers/admin/ranked_lists_controller_test.rb`, the test at ~line 183 ("should deny access to a books ranking configuration for a user with only a books domain role") now grants **read** access — rewrite it to mirror the games test directly below it:

```ruby
    test "should allow access to a books ranking configuration for a user with only a books domain role" do
      books_config = ranking_configurations(:books_global)
      @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
      sign_in_as(@regular_user, stub_auth: true)

      get admin_ranking_configuration_ranked_lists_path(books_config)

      assert_response :success
    end
```

In `web-app/test/controllers/admin/penalty_applications_controller_test.rb`, the equivalent test at ~line 226 — same flip (rename to "should allow…", change the final assertion to `assert_response :success`; keep the `get admin_ranking_configuration_penalty_applications_path(books_config)` request).

- [ ] **Step 7: Registry + nav assertions**

Add to `web-app/test/lib/admin/domain_routing_test.rb`:
```ruby
    test "RANKING_CONFIGURATIONS resolves a books RC path" do
      rc = ranking_configurations(:books_global)
      assert_equal Rails.application.routes.url_helpers.admin_books_ranking_configuration_path(rc),
        Admin::DomainRouting.ranking_configuration_config(rc)[:path]
    end
```

Add to `web-app/test/lib/admin/domain_nav_test.rb`:
```ruby
    test "the books nav includes a Rankings item" do
      item = Admin::DomainNav.config_for(:books)[:items].find { |i| i[:label] == "Rankings" }
      assert item, "books nav is missing a Rankings item"
      assert_equal "/admin/ranking_configurations", item[:path]
    end
```

- [ ] **Step 8: Run the RC + affected shared tests**

Run: `bin/rails test test/controllers/admin/books/ranking_configurations_controller_test.rb test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb`
Expected: PASS — including the two flipped tests now asserting books-domain read access.

- [ ] **Step 9: standardrb + commit**

Run standardrb on the touched Ruby files → no offenses.

```bash
git add config/routes.rb app/controllers/admin/books/ranking_configurations_controller.rb app/lib/admin/domain_routing.rb app/lib/admin/domain_nav.rb test/controllers/admin/books/ranking_configurations_controller_test.rb test/controllers/admin/ranked_lists_controller_test.rb test/controllers/admin/penalty_applications_controller_test.rb test/lib/admin/domain_routing_test.rb test/lib/admin/domain_nav_test.rb
git commit -m "$(cat <<'EOF'
Add books ranking-configurations admin + registry path (inc 6b task 4)

Thin controller (inherits the shared RC views) + DomainNav Rankings item.
Registering Books::RankingConfiguration's path gates books-domain auth for
the shared ranked-lists/penalty views; the two books-denial tests flip to
allowed (read) by design.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Playwright smoke specs

Mirror `e2e/tests/books/admin/authors.spec.ts` (the `books-admin` project, stored auth state). Books admin list items ride the shared typeahead; keep the specs to index + create + one show/typeahead interaction.

**Files:**
- Create: `web-app/e2e/tests/books/admin/lists.spec.ts`
- Create: `web-app/e2e/tests/books/admin/ranking-configurations.spec.ts`

- [ ] **Step 1: Write the lists spec**

Create `web-app/e2e/tests/books/admin/lists.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

test.describe("Books admin — lists", () => {
  test("lists index and links to New List", async ({ page }) => {
    await page.goto("/admin/lists");
    await expect(page.getByRole("heading", { name: "Book Lists", level: 1 })).toBeVisible();
  });

  test("creates a list and shows it without a wizard button", async ({ page }) => {
    const name = `E2E List ${Date.now()}`;
    await page.goto("/admin/lists/new");
    await page.locator('input[name="books_list[name]"]').fill(name);
    await page.getByRole("button", { name: "Create Book List" }).click();
    await expect(page.getByRole("heading", { name, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: "Launch Wizard" })).toHaveCount(0);
  });
});
```
(Index `<h1>` is `"#{item_label} Lists"` → "Book Lists"; the form submit is `"Create #{item_label} List"` → "Create Book List", from `Admin::Lists::IndexComponent` / `FormComponent`.)

- [ ] **Step 2: Write the ranking-configurations spec**

Create `web-app/e2e/tests/books/admin/ranking-configurations.spec.ts`:

```ts
import { test, expect } from "@playwright/test";

test.describe("Books admin — ranking configurations", () => {
  test("lists ranking configurations", async ({ page }) => {
    await page.goto("/admin/ranking_configurations");
    await expect(page.getByRole("heading", { level: 1 }).first()).toBeVisible();
  });

  test("creates a ranking configuration", async ({ page }) => {
    const name = `E2E RC ${Date.now()}`;
    await page.goto("/admin/ranking_configurations/new");
    await page.locator('input[name="ranking_configuration[name]"]').fill(name);
    await page.getByRole("button", { name: /Create|Save/ }).click();
    await expect(page.getByText(name)).toBeVisible();
  });
});
```
(Verify the shared RC index/new/form headings + submit label and the `name` input selector against `app/views/admin/ranking_configurations/*`; adjust selectors to the exact rendered markup.)

- [ ] **Step 3: Validate they register**

Run: `yarn playwright test --list e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts` → the specs list under `[books-admin]`.

- [ ] **Step 4: Run them (dev server up)**

Run: `yarn test:e2e e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts`
Expected: all pass. If the dev server is unavailable, the specs still register; note it and run when the server is up (`bin/dev`, `bin/rails e2e:admin` if the role lapsed). Fix any selector that fails against the real rendered markup (do not weaken assertions to force a pass).

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts
git commit -m "$(cat <<'EOF'
Add books lists + ranking-configurations Playwright smoke specs (inc 6b task 5)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] `bin/rails test` — full suite green (baseline 4805/0 after 6a; expect that plus the new tests).
- [ ] `bundle exec standardrb` — no offenses.
- [ ] `yarn test:e2e e2e/tests/books/admin/lists.spec.ts e2e/tests/books/admin/ranking-configurations.spec.ts` — pass (dev server up).
- [ ] Confirm the only edits to existing music/games tests are the two deliberate denial-test flips (Task 4) and the one shared-calculator assertion (Task 2). Any other change to an existing assertion is a red flag — stop and investigate.
- [ ] Sanity-check the reframing held: `grep -rn "num_years_covered" app/` shows no books RC applies it; `calculate_books_year_range` was left untouched.

## Notes / carried context

- **Deferred follow-up PR (not in 6b):** gate the shared `ranked_lists` / `penalty_applications` / `list_items` / `list_penalties` mutations on domain write (the 6a `require_domain_write!` pattern), closing the pre-existing viewer-write gap that 6b's RC-path registration newly exposes for books (6b grants **read** only; the denial-test flips are GET requests).
- RC create requires **manage** (admin), not editor — `Books::RankingConfigurationPolicy` (via `ApplicationPolicy#create? → manage?`-gated in the RC controller). The editor-denied create test in Task 4 pins this.
