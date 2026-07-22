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
- **The legacy date-penalty math is extracted to a public `ItemRankings::DatePenalty` PORO** (Task 2) and unit-tested directly — the calculator's private `calculate_score_penalty` becomes a thin adapter. No private methods are tested; the adapter wiring is covered by the existing public `call`-based calculator tests.
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

### Task 2: Legacy date-penalty parity — extract `ItemRankings::DatePenalty` + wire it in

Reproduce the legacy TheGreatestBooks date penalty: a yearly-award list, or an item with no publication year, takes the full penalty — checked **before** the `list.year_published` guard (legacy order). Extract the pure math into a public, unit-tested `ItemRankings::DatePenalty` PORO (owner call — no testing of private methods), and make the calculator's `calculate_score_penalty` a thin adapter. This is a shared change (all domains): inert for music/games award lists (0 exist), re-ranks ~1% of their nil-year items.

**Files:**
- Create: `web-app/app/lib/item_rankings/date_penalty.rb`
- Modify: `web-app/app/lib/item_rankings/calculator.rb` (`calculate_score_penalty` → adapter)
- Test: `web-app/test/lib/item_rankings/date_penalty_test.rb` (create)

**Interfaces:**
- Produces: `ItemRankings::DatePenalty.call(list_year:, item_year:, yearly_award:, max_age:, max_penalty_percentage:) → Float | nil` — pure legacy math.
- Consumes: `Books::Book#release_year` (Task 1); `ranking_configuration.{apply_list_dates_penalty?, max_list_dates_penalty_age, max_list_dates_penalty_percentage}`; `list.{year_published, yearly_award?}`; `list_item.listable`.

- [ ] **Step 1: Write the failing PORO test**

Create `web-app/test/lib/item_rankings/date_penalty_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module ItemRankings
  class DatePenaltyTest < ActiveSupport::TestCase
    def penalty(list_year: 2000, item_year: 1980, yearly_award: false, max_age: 50, max_penalty_percentage: 80)
      ItemRankings::DatePenalty.call(
        list_year: list_year, item_year: item_year, yearly_award: yearly_award,
        max_age: max_age, max_penalty_percentage: max_penalty_percentage
      )
    end

    test "graduated penalty for an item older than the list within max_age" do
      # year_difference = 20; ((50-20)/50)*80/100 = 0.48
      assert_in_delta 0.48, penalty(item_year: 1980), 0.0001
    end

    test "max penalty when the item is newer than the list" do
      assert_in_delta 0.80, penalty(item_year: 2005), 0.0001
    end

    test "no penalty when the item is older than max_age" do
      assert_nil penalty(item_year: 1940) # diff 60 > 50
    end

    test "max penalty when the item has no year" do
      assert_in_delta 0.80, penalty(item_year: nil), 0.0001
    end

    test "a yearly-award list forces max penalty even with a good year gap" do
      assert_in_delta 0.80, penalty(item_year: 1940, yearly_award: true), 0.0001
    end

    test "a yearly-award list max-penalizes even with no list year" do
      assert_in_delta 0.80, penalty(list_year: nil, item_year: 1980, yearly_award: true), 0.0001
    end

    test "nil when the penalty config is incomplete" do
      assert_nil penalty(max_age: nil)
      assert_nil penalty(max_penalty_percentage: nil)
    end

    test "nil when the list has no year and the item is not award/nil-year" do
      assert_nil penalty(list_year: nil)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/lib/item_rankings/date_penalty_test.rb`
Expected: FAIL — `uninitialized constant ItemRankings::DatePenalty`.

- [ ] **Step 3: Create the PORO**

Create `web-app/app/lib/item_rankings/date_penalty.rb`:

```ruby
# frozen_string_literal: true

module ItemRankings
  # Pure legacy per-item "list dates" recency penalty, mirroring the legacy
  # TheGreatestBooks calculate_score_penalty. Returns a penalty fraction (0..1)
  # or nil (no penalty). Order matches legacy: award lists and items with an
  # unknown year take the full penalty, checked before the list-year guard.
  class DatePenalty
    def self.call(list_year:, item_year:, yearly_award:, max_age:, max_penalty_percentage:)
      return nil if max_age.nil? || max_penalty_percentage.nil?

      return max_penalty_percentage / 100.0 if yearly_award || item_year.nil?

      return nil if list_year.nil?

      year_difference = list_year - item_year

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
  end
end
```

- [ ] **Step 4: Run the PORO test to verify pass**

Run: `bin/rails test test/lib/item_rankings/date_penalty_test.rb`
Expected: PASS (all 8).

- [ ] **Step 5: Wire the calculator adapter to the PORO**

Replace `calculate_score_penalty` in `web-app/app/lib/item_rankings/calculator.rb` (currently ~lines 90-115) with a thin adapter that extracts the values and delegates the math:

```ruby
    def calculate_score_penalty(list, list_item)
      item = list_item.listable
      item_year = item.respond_to?(:release_year) ? item.release_year : nil

      ItemRankings::DatePenalty.call(
        list_year: list.year_published,
        item_year: item_year,
        yearly_award: list.yearly_award?,
        max_age: ranking_configuration.max_list_dates_penalty_age,
        max_penalty_percentage: ranking_configuration.max_list_dates_penalty_percentage
      )
    end
```

(The public `call`-based calculator tests — e.g. music albums' "call handles penalty calculations when enabled" — exercise this adapter end-to-end through `prepare_items`; they must stay green, confirming the adapter feeds `item.release_year`/`yearly_award?` correctly.)

- [ ] **Step 6: Run the full item_rankings suite (adapter wiring + no regression)**

Run: `bin/rails test test/lib/item_rankings/`
Expected: PASS — the existing music/movies/games calculator `call` tests still pass, confirming the adapter refactor is behavior-preserving for the pre-existing cases.

- [ ] **Step 7: standardrb + commit**

Run: `bundle exec standardrb app/lib/item_rankings/date_penalty.rb app/lib/item_rankings/calculator.rb test/lib/item_rankings/date_penalty_test.rb` → no offenses.

```bash
git add app/lib/item_rankings/date_penalty.rb app/lib/item_rankings/calculator.rb test/lib/item_rankings/date_penalty_test.rb
git commit -m "$(cat <<'EOF'
Extract ItemRankings::DatePenalty for legacy date-penalty parity (inc 6b task 2)

Pure PORO mirroring the legacy TheGreatestBooks calculate_score_penalty: a
yearly-award list, or an item with no publication year, takes the full
penalty, checked before the list.year_published guard. The calculator's
calculate_score_penalty is now a thin adapter. Shared across domains (inert
for music/games award lists; re-ranks their nil-year items, ~1%).

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
- [ ] Confirm the only edits to existing music/games tests are the two deliberate denial-test flips (Task 4). Task 2 refactors `calculate_score_penalty` into a `DatePenalty` adapter but changes no existing test. Any other change to an existing assertion is a red flag — stop and investigate.
- [ ] Sanity-check the reframing held: `grep -rn "num_years_covered" app/` shows no books RC applies it; `calculate_books_year_range` was left untouched.

## Notes / carried context

- **Deferred follow-up PR (not in 6b):** gate the shared `ranked_lists` / `penalty_applications` / `list_items` / `list_penalties` mutations on domain write (the 6a `require_domain_write!` pattern), closing the pre-existing viewer-write gap that 6b's RC-path registration newly exposes for books (6b grants **read** only; the denial-test flips are GET requests).
- RC create requires **manage** (admin), not editor — `Books::RankingConfigurationPolicy` (via `ApplicationPolicy#create? → manage?`-gated in the RC controller). The editor-denied create test in Task 4 pins this.
