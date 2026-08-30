# Reading Goals Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the legacy Books reading-goals feature with live progress derived from dated Read-list items, reusable completion transitions, exact Cloudflare invalidation, improved owner/public UI, and an idempotent legacy import.

**Architecture:** `Books::ReadingGoal` persists only a goal definition; `Services::Books::ReadingGoals::ProgressQuery` projects books and progress from the owner's dated `Books::UserList` Read items. Generic `Services::UserLists` mutations own transactional list/completion changes and return old/new completion dates, while Books-specific services translate those changes into public goal URL purges. Public goal HTML is viewer-neutral and edge-cacheable; owner controls hydrate from a separate no-store endpoint.

**Tech Stack:** Ruby on Rails, PostgreSQL, Minitest, ViewComponent, Hotwire/Turbo, Stimulus, Tailwind CSS 4, DaisyUI 5, Sidekiq, Cloudflare purge-by-URL, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-26-reading-goals-migration-design.md`

## Global Constraints

- Work only in the `reading-goals-migration` feature branch/worktree; never commit to `main`.
- Run every Rails, Bundler, and yarn command from `web-app/`.
- Use Rails generators for models, controllers, jobs, and components; do not hand-create those framework objects.
- Follow `CLAUDE.md`, including namespacing, service placement, the `Result` shape, Minitest, StandardRB, and DataImporter conventions.
- Read `docs/external-libraries/daisyui-llms.txt` before writing or reviewing DaisyUI form/dialog markup.
- Follow `.claude/agents/ui-engineer.md` for the visual implementation and responsive/accessibility review.
- Keep `Books::ReadingGoal` Books-specific; only list transition and completion mutation services are cross-media.
- Do not add Goodreads importing, forecasts, streaks, reminders, recommendations, social feeds, or goals for other media.
- Preserve arbitrary inclusive ranges, overlapping goals, multiple goals per user, legacy ids, and progress above 100%; cap only the visual bar at 100%.
- Keep the quick widget date-free: Reading to Read stamps today, while direct Read adds stay undated.
- Use the existing controller cache helpers, path pagination, and `Cloudflare::PurgeService`; do not create another caching subsystem.
- Never put personalized controls, a usable mutation CSRF token, or session-derived HTML in a public cached response.
- Do not run destructive development-database commands.

---

### Task 1: Reading Goal Schema and Domain Model

**Files:**
- Generate/Create: `web-app/app/models/books/reading_goal.rb`
- Generate/Create: `web-app/db/migrate/*_create_books_reading_goals.rb`
- Generate/Create: `web-app/test/models/books/reading_goal_test.rb`
- Generate/Create: `web-app/test/fixtures/books/reading_goals.yml`
- Modify: `web-app/app/models/user.rb`
- Modify: `web-app/test/models/user_test.rb`
- Modify: `web-app/db/schema.rb`

**Interfaces:**
- Consumes: Existing `User` rows and PostgreSQL bigint primary keys.
- Produces: `Books::ReadingGoal` with `belongs_to :user`; `User#books_reading_goals`; scopes `public_goals`, `owned_by(user)`, `active_on(date)`, `upcoming_on(date)`, and `finished_on(date)`; sequence floor `10_000`.

- [ ] **Step 1: Generate the namespaced model without accepting the generated migration as final**

Run:

```bash
bin/rails generate model Books::ReadingGoal user:references name:string description:text target_count:integer starts_on:date ends_on:date public:boolean
```

Expected: Rails creates the model, migration, fixture, and model test under the Books namespace.

- [ ] **Step 2: Write failing model and association tests**

Add tests covering the exact contract:

```ruby
class Books::ReadingGoalTest < ActiveSupport::TestCase
  test "requires a name, positive target, and ordered dates" do
    goal = Books::ReadingGoal.new(
      user: users(:regular_user), name: "", target_count: 0,
      starts_on: Date.new(2026, 12, 31), ends_on: Date.new(2026, 1, 1)
    )

    refute goal.valid?
    assert_includes goal.errors[:name], "can't be blank"
    assert_includes goal.errors[:target_count], "must be greater than 0"
    assert_includes goal.errors[:ends_on], "must be on or after the start date"
  end

  test "date scopes use inclusive boundaries and stable ordering" do
    today = Date.new(2026, 8, 26)

    assert_equal [books_reading_goals(:active_ending_soon).id, books_reading_goals(:active_ending_later).id],
      Books::ReadingGoal.active_on(today).pluck(:id)
    assert_equal Books::ReadingGoal.upcoming_on(today).pluck(:starts_on, :id),
      Books::ReadingGoal.upcoming_on(today).pluck(:starts_on, :id).sort
    assert_equal Books::ReadingGoal.finished_on(today).pluck(:ends_on, :id),
      Books::ReadingGoal.finished_on(today).pluck(:ends_on, :id).sort.reverse
  end

  test "database constraint rejects a non-positive persisted target" do
    goal = books_reading_goals(:active_ending_soon)

    assert_raises(ActiveRecord::StatementInvalid) do
      goal.update_columns(target_count: 0)
    end
  end

  test "database constraint rejects reversed persisted dates" do
    goal = books_reading_goals(:active_ending_soon)

    assert_raises(ActiveRecord::StatementInvalid) do
      goal.update_columns(ends_on: goal.starts_on - 1.day)
    end
  end
end

class UserTest < ActiveSupport::TestCase
  test "destroying a user destroys their books reading goals" do
    user = User.create!(
      email: "reading-goal-delete@example.com", role: :user, email_verified: true
    )
    goal = Books::ReadingGoal.create!(
      user: user, name: "Delete me", target_count: 1,
      starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31)
    )

    user.destroy!

    refute Books::ReadingGoal.exists?(goal.id)
  end
end
```

Fixture records must include two active goals with different `ends_on`, one upcoming goal, one finished goal, one private goal, and one public goal owned by another user. Use explicit ids below the normal fixture sequence ceiling only in tests; production sequence behavior is asserted from PostgreSQL in the migration test.

- [ ] **Step 3: Run the focused tests and verify the new contract fails**

Run:

```bash
bin/rails test test/models/books/reading_goal_test.rb test/models/user_test.rb
```

Expected: FAIL because validations, scopes, constraints, and the User association are absent.

- [ ] **Step 4: Implement the migration and model**

Edit the generated migration to enforce the database contract and reserve low ids:

```ruby
class CreateBooksReadingGoals < ActiveRecord::Migration[8.0]
  def change
    create_table :books_reading_goals do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :target_count, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.boolean :public, null: false, default: false
      t.timestamps
    end

    add_check_constraint :books_reading_goals, "target_count > 0",
      name: "books_reading_goals_target_count_positive"
    add_check_constraint :books_reading_goals, "ends_on >= starts_on",
      name: "books_reading_goals_dates_ordered"
    add_index :books_reading_goals, [:user_id, :public, :starts_on, :ends_on],
      name: "index_books_reading_goals_for_public_date_lookup"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          SELECT setval(
            pg_get_serial_sequence('books_reading_goals', 'id'),
            10000,
            false
          )
        SQL
      end
    end
  end
end
```

Implement the model:

```ruby
module Books
  class ReadingGoal < ApplicationRecord
    belongs_to :user

    validates :name, presence: true
    validates :target_count, numericality: {only_integer: true, greater_than: 0}
    validates :starts_on, :ends_on, presence: true
    validates :public, inclusion: {in: [true, false]}
    validate :ends_on_not_before_starts_on

    scope :public_goals, -> { where(public: true) }
    scope :owned_by, ->(user) { where(user: user) }
    scope :active_on, ->(date) {
      where("starts_on <= ? AND ends_on >= ?", date, date).order(:ends_on, :id)
    }
    scope :upcoming_on, ->(date) { where("starts_on > ?", date).order(:starts_on, :id) }
    scope :finished_on, ->(date) { where("ends_on < ?", date).order(ends_on: :desc, id: :desc) }

    private

    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after the start date")
    end
  end
end
```

Add to `User`:

```ruby
has_many :books_reading_goals, class_name: "Books::ReadingGoal", dependent: :destroy
```

- [ ] **Step 5: Migrate test and development schemas, then rerun the tests**

Run:

```bash
bin/rails db:migrate
bin/rails db:test:prepare
bin/rails test test/models/books/reading_goal_test.rb test/models/user_test.rb
```

Expected: PASS, and `db/schema.rb` contains both check constraints and both indexes.

- [ ] **Step 6: Commit the schema and model**

```bash
git add app/models/books/reading_goal.rb app/models/user.rb db/migrate db/schema.rb test/models/books/reading_goal_test.rb test/models/user_test.rb test/fixtures/books/reading_goals.yml
git commit -m "Add books reading goal model"
```

### Task 2: Live Reading-Goal Progress Projection

**Files:**
- Create: `web-app/app/lib/services/books/reading_goals/progress_query.rb`
- Create: `web-app/test/lib/services/books/reading_goals/progress_query_test.rb`
- Modify: `web-app/test/fixtures/user_lists.yml`
- Modify: `web-app/test/fixtures/user_list_items.yml`

**Interfaces:**
- Consumes: `Books::ReadingGoal`; the owner's `Books::UserList.read` list; `UserListItem.completed_on`.
- Produces: `Services::Books::ReadingGoals::ProgressQuery.call(goal:, page: 1) -> Progress`, where `Progress` has `items`, `count`, `percentage`, `complete`, and `bar_percentage`; `PER_PAGE = 24`.

- [ ] **Step 1: Write the failing projection tests**

Create focused fixtures for an owner Read list and dated/undated Books items, then test:

```ruby
class Services::Books::ReadingGoals::ProgressQueryTest < ActiveSupport::TestCase
  test "projects only the owner's dated Read items inside inclusive boundaries" do
    goal = books_reading_goals(:public_goal)
    starts_item = add_read_item(goal.user, books_books(:war_and_peace), goal.starts_on)
    ends_item = add_read_item(goal.user, books_books(:cannery_row), goal.ends_on)
    add_read_item(goal.user, books_books(:of_mice_and_men), nil)
    add_read_item(users(:editor_user), books_books(:crime_and_punishment), goal.starts_on)

    result = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

    assert_equal [ends_item.id, starts_item.id], result.items.map(&:id)
    assert_equal 2, result.count
  end

  test "reports truthful over-target progress and caps only the bar" do
    goal = books_reading_goals(:public_goal)
    goal.update!(target_count: 1)
    add_read_item(goal.user, books_books(:crime_and_punishment), goal.starts_on)
    add_read_item(goal.user, books_books(:cannery_row), goal.ends_on)

    result = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

    assert_equal 200.0, result.percentage
    assert result.complete
    assert_equal 100.0, result.bar_percentage
  end

  test "orders equal dates by item id descending and pages by 24" do
    goal = books_reading_goals(:public_goal)
    items = 25.times.map do |index|
      add_read_item(goal.user, Books::Book.create!(title: "Goal book #{index}", slug: "goal-book-#{index}"), goal.starts_on)
    end

    page_one = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: 1)
    page_two = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal, page: 2)

    assert_equal items.map(&:id).sort.reverse.first(24), page_one.items.map(&:id)
    assert_equal [items.map(&:id).min], page_two.items.map(&:id)
    assert_equal 25, page_two.count
  end

  test "returns an empty projection when the owner has no Read list" do
    user = User.create!(
      email: "reading-goal-empty@example.com", role: :user, email_verified: true
    )
    Books::UserList.find_by!(user: user, list_type: :read).destroy!
    goal = Books::ReadingGoal.create!(
      user: user, name: "Empty", target_count: 12,
      starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 12, 31)
    )

    result = Services::Books::ReadingGoals::ProgressQuery.call(goal: goal)

    assert_empty result.items
    assert_equal 0, result.count
    assert_equal 0.0, result.percentage
  end

  private

  def add_read_item(user, book, completed_on)
    list = Books::UserList.find_or_create_by!(user: user, list_type: :read) do |new_list|
      new_list.name = Books::UserList.default_list_name_for(:read)
    end
    list.user_list_items.create!(listable: book, completed_on: completed_on)
  end
end
```

Add cases that place a matching book on Favorites, Reading, and another domain's list; all must be excluded. Call the same query for two overlapping goals and assert both include the shared item.

- [ ] **Step 2: Run the projection test and verify it fails**

Run:

```bash
bin/rails test test/lib/services/books/reading_goals/progress_query_test.rb
```

Expected: FAIL with `uninitialized constant Services::Books::ReadingGoals::ProgressQuery`.

- [ ] **Step 3: Implement the query with stable SQL pagination and card preloads**

```ruby
module Services
  module Books
    module ReadingGoals
      class ProgressQuery
        PER_PAGE = 24
        Progress = Struct.new(
          :items, :count, :percentage, :complete, :bar_percentage,
          keyword_init: true
        )

        def self.call(goal:, page: 1)
          new(goal: goal, page: page).call
        end

        def initialize(goal:, page: 1)
          @goal = goal
          @page = [page.to_i, 1].max
        end

        def call
          relation = projected_items
          count = relation.count
          percentage = count.zero? ? 0.0 : (count.fdiv(goal.target_count) * 100).round(1)

          Progress.new(
            items: relation.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a,
            count: count,
            percentage: percentage,
            complete: count >= goal.target_count,
            bar_percentage: [percentage, 100.0].min
          )
        end

        private

        attr_reader :goal, :page

        def projected_items
          list = ::Books::UserList.find_by(user: goal.user, list_type: :read)
          return ::UserListItem.none if list.nil?

          list.user_list_items
            .where(listable_type: "Books::Book", completed_on: goal.starts_on..goal.ends_on)
            .includes(listable: ::Books::UserList.listable_display_includes)
            .reorder(completed_on: :desc, id: :desc)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run projection tests and a query-count assertion**

Run:

```bash
bin/rails test test/lib/services/books/reading_goals/progress_query_test.rb
```

Expected: PASS. Add an `assert_queries_count` case that renders author/image access for 24 items without one query per book, and keep it passing.

- [ ] **Step 5: Commit the projection**

```bash
git add app/lib/services/books/reading_goals/progress_query.rb test/lib/services/books/reading_goals/progress_query_test.rb test/fixtures/user_lists.yml test/fixtures/user_list_items.yml
git commit -m "Project reading goal progress from read lists"
```

### Task 3: Reusable Transactional List Completion Mutations

**Files:**
- Create: `web-app/app/lib/services/user_lists/mutation_result.rb`
- Create: `web-app/app/lib/services/user_lists/add_item.rb`
- Create: `web-app/app/lib/services/user_lists/remove_item.rb`
- Create: `web-app/app/lib/services/user_lists/update_completion.rb`
- Create: `web-app/test/lib/services/user_lists/add_item_test.rb`
- Create: `web-app/test/lib/services/user_lists/remove_item_test.rb`
- Create: `web-app/test/lib/services/user_lists/update_completion_test.rb`
- Modify: `web-app/app/models/user_list.rb`
- Modify: `web-app/app/models/books/user_list.rb`
- Modify: `web-app/test/models/user_list_test.rb`

**Interfaces:**
- Consumes: A concrete `UserList`, a type-compatible listable, and optional ISO completion date input.
- Produces: `Services::UserLists::MutationResult = Struct.new(:success?, :data, :errors, keyword_init: true)`. Successful `data` is `{item:, removed_items:, listable:, old_completed_on:, new_completed_on:, transitioned:}`.
- Produces: `UserList.completion_transition_sources -> Hash<Symbol, Array<Symbol>>`; Books returns `{read: [:reading]}`.
- Produces: `AddItem.call(user_list:, listable:, today: Date.current)`, `RemoveItem.call(item:)`, and `UpdateCompletion.call(item:, completed_on:)`.

- [ ] **Step 1: Write failing declaration and service tests**

The test matrix must assert these exact state transitions:

```ruby
setup do
  @user = users(:regular_user)
  @book = books_books(:cannery_row)
  @read_list = user_lists(:regular_user_books_read)
  @reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
    list.name = Books::UserList.default_list_name_for(:reading)
  end
end

test "direct Read addition stays undated" do
  result = Services::UserLists::AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

  assert result.success?
  assert_nil result.data[:item].completed_on
  refute result.data[:transitioned]
end

test "Reading to Read removes Reading and stamps today" do
  reading_item = @reading_list.user_list_items.create!(listable: @book)

  result = Services::UserLists::AddItem.call(user_list: @read_list, listable: @book, today: Date.new(2026, 8, 26))

  assert result.success?
  refute UserListItem.exists?(reading_item.id)
  assert_equal Date.new(2026, 8, 26), result.data[:item].completed_on
  assert result.data[:transitioned]
end

test "a stale Reading membership never overwrites an existing Read date" do
  read_item = @read_list.user_list_items.create!(listable: @book, completed_on: Date.new(1999, 1, 2))
  reading_item = @reading_list.user_list_items.create!(listable: @book)

  result = Services::UserLists::AddItem.call(user_list: @read_list, listable: @book)

  assert result.success?
  refute UserListItem.exists?(reading_item.id)
  assert_equal Date.new(1999, 1, 2), read_item.reload.completed_on
end

test "a failed target save rolls back source removal" do
  source = @reading_list.user_list_items.create!(listable: @book)
  UserListItem.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(UserListItem.new))

  result = Services::UserLists::AddItem.call(user_list: @read_list, listable: @book)

  refute result.success?
  assert UserListItem.exists?(source.id)
end
```

Also assert duplicate-without-transition is a failed Result, removing Read reports its old date, other list removals report nil/nil, completion set/replace/clear work, invalid ISO dates fail without clearing a stored value, and non-completion-capable lists fail.

- [ ] **Step 2: Run focused tests and verify failures**

Run:

```bash
bin/rails test test/models/user_list_test.rb test/lib/services/user_lists/add_item_test.rb test/lib/services/user_lists/remove_item_test.rb test/lib/services/user_lists/update_completion_test.rb
```

Expected: FAIL because declarations and services do not exist.

- [ ] **Step 3: Add the generic declaration seam**

Add to `UserList`:

```ruby
def self.completion_transition_sources
  {}
end

def completion_transition_source_types
  self.class.completion_transition_sources.fetch(list_type.to_sym, [])
end
```

Add to `Books::UserList`:

```ruby
def self.completion_transition_sources
  {read: [:reading]}
end
```

Keep `completed_on_list_types` unchanged as `[:read]`; it is the independent declaration that permits date editing.

- [ ] **Step 4: Implement the shared Result and transactional services**

Use one result shape:

```ruby
module Services
  module UserLists
    MutationResult = Struct.new(:success?, :data, :errors, keyword_init: true)
  end
end
```

`AddItem` must lock the target membership and every matching source membership inside one `UserListItem.transaction`, create the target when absent, set today only when at least one source exists and the target is completion-capable and undated, destroy every matching declared source, and return the exact old/new dates. Convert `ActiveRecord::RecordInvalid` and `ActiveRecord::RecordNotUnique` into failed results without leaking a partial transition.

When the target membership already exists and there is no source transition to complete, return `MutationResult.new(success?: false, data: nil, errors: ["Item already in list"])`; Task 4 maps that one stable service error to the existing HTTP 409 contract.

`RemoveItem` must capture `old_completed_on`, destroy inside a transaction, and return `new_completed_on: nil`.

`UpdateCompletion` must first reject `item.user_list.completed_on_enabled? == false`, parse only blank or `Date.iso8601(value.to_s)`, update in a transaction, and return the old/new dates. Its parse failure is:

```ruby
MutationResult.new(success?: false, data: nil, errors: ["Completion date is invalid"])
```

Every successful service returns:

```ruby
MutationResult.new(
  success?: true,
  data: {
    item: item,
    removed_items: removed_items,
    listable: item.listable,
    old_completed_on: old_completed_on,
    new_completed_on: item.completed_on,
    transitioned: removed_items.any?
  },
  errors: []
)
```

- [ ] **Step 5: Run all generic mutation tests**

Run:

```bash
bin/rails test test/models/user_list_test.rb test/lib/services/user_lists/add_item_test.rb test/lib/services/user_lists/remove_item_test.rb test/lib/services/user_lists/update_completion_test.rb
```

Expected: PASS, including rollback assertions.

- [ ] **Step 6: Commit the generic completion layer**

```bash
git add app/models/user_list.rb app/models/books/user_list.rb app/lib/services/user_lists test/models/user_list_test.rb test/lib/services/user_lists
git commit -m "Add reusable list completion transitions"
```

### Task 4: User-List Write Endpoints and Quick-Widget Feedback

**Files:**
- Modify: `web-app/config/routes.rb`
- Modify: `web-app/app/controllers/user_list_items_controller.rb`
- Modify: `web-app/app/policies/user_list_item_policy.rb`
- Modify: `web-app/app/javascript/controllers/user_list_modal_controller.js`
- Modify: `web-app/app/javascript/controllers/user_list_add_item_controller.js`
- Modify: `web-app/test/controllers/user_list_items_controller_test.rb`
- Modify: `web-app/test/policies/user_list_item_policy_test.rb`
- Modify: `web-app/test/lint/stimulus_manifest_test.rb`

**Interfaces:**
- Consumes: Task 3 mutation services.
- Produces: `PATCH /user_list_items/:id/completion`, named `user_list_item_completion_path`.
- Produces: Add JSON `{user_list_item:, removed_user_list_items:, message:}` and remove JSON `{ok:, removed_user_list_item:, message:}`.

- [ ] **Step 1: Write failing controller tests and define browser expectations**

Controller tests must cover:

```ruby
setup do
  @user = users(:regular_user)
  @read_list = user_lists(:regular_user_books_read)
  @reading_list = Books::UserList.find_or_create_by!(user: @user, list_type: :reading) do |list|
    list.name = Books::UserList.default_list_name_for(:reading)
  end
  host! Rails.application.config.domains[:books]
end

test "adding Reading book to Read removes Reading and returns both membership changes" do
  sign_in_as users(:regular_user), stub_auth: true
  reading_item = @reading_list.user_list_items.create!(listable: books_books(:cannery_row))

  post user_list_items_path(@read_list), params: {
    user_list_item: {listable_id: books_books(:cannery_row).id}
  }, as: :json

  assert_response :created
  body = response.parsed_body
  assert_equal Date.current.iso8601, body.dig("user_list_item", "completed_on")
  assert_equal [reading_item.id], body.fetch("removed_user_list_items").pluck("id")
  assert_includes body.fetch("message"), "completed today"
end

test "direct Read add explains how to make the book count" do
  sign_in_as users(:regular_user), stub_auth: true

  post user_list_items_path(@read_list), params: {
    user_list_item: {listable_id: books_books(:cannery_row).id}
  }, as: :json

  assert_response :created
  assert_nil response.parsed_body.dig("user_list_item", "completed_on")
  assert_includes response.parsed_body.fetch("message"), "Books I've Read"
end

test "completion update is owner-only and only accepts completed_on" do
  sign_in_as users(:regular_user), stub_auth: true
  item = user_list_items(:regular_user_books_item_3)

  patch user_list_item_completion_path(item), params: {
    user_list_item: {completed_on: "2025-03-04", position: 999}
  }

  assert_redirected_to my_list_path(item.user_list)
  assert_equal Date.new(2025, 3, 4), item.reload.completed_on
  refute_equal 999, item.position
end
```

Add 404 tests for another user's item, a `303 See Other` with alert and no mutation for invalid dates, and rejection for non-completion lists. The browser behavior will be covered in Task 11 because this repository has no JavaScript unit-test runner.

- [ ] **Step 2: Run the focused endpoint and manifest tests**

Run:

```bash
bin/rails test test/controllers/user_list_items_controller_test.rb test/policies/user_list_item_policy_test.rb test/lint/stimulus_manifest_test.rb
```

Expected: FAIL because the completion route/action and multi-membership response do not exist.

- [ ] **Step 3: Route all mutations through the Task 3 services**

Add the global route beside existing user-list writes:

```ruby
patch "user_list_items/:id/completion",
  to: "user_list_items#update_completion",
  as: :user_list_item_completion
```

Add `update_completion?` to `UserListItemPolicy` as the same parent-list owner predicate used by create/destroy.

Restrict the existing `before_action :load_user_list` to `only: [:create, :destroy]`; the non-nested completion route has no `user_list_id` and resolves its item directly through `current_user.user_list_items`.

In the controller:

```ruby
def create
  listable = @user_list.class.listable_class.find(item_attrs[:listable_id])
  candidate = @user_list.user_list_items.new(listable: listable)
  authorize candidate, policy_class: UserListItemPolicy
  result = Services::UserLists::AddItem.call(user_list: @user_list, listable: listable)
  return render_mutation_failure(result) unless result.success?

  invalidate_books_goals(result)
  render json: {
    user_list_item: serialize_item(result.data[:item]),
    removed_user_list_items: result.data[:removed_items].map { |item| serialize_item(item) },
    message: mutation_message(result)
  }, status: :created
end
```

`destroy` must call `RemoveItem`, and `update_completion` must resolve through `current_user.user_list_items.find(params[:id])`, authorize `:update_completion?`, call `UpdateCompletion`, invalidate Books goals after success, and redirect with `303 See Other`. Serialize `completed_on` as ISO 8601 or nil.

Preserve the existing JSON error contract: `render_mutation_failure` returns `409 conflict` when `result.errors == ["Item already in list"]`, and otherwise returns `422 validation_failed` with the service errors. Keep the `ActiveRecord::RecordNotUnique` rescue as the concurrent duplicate fallback.

Temporarily define `invalidate_books_goals` as a private no-op guarded by `defined?(Services::Books::ReadingGoals::CompletionChangeInvalidator)`; Task 5 replaces it with the concrete call in the same commit that creates the invalidator.

- [ ] **Step 4: Apply every server-reported membership delta in both Stimulus callers**

Change modal mutation handling to accept arrays:

```javascript
this._afterMutation({
  added: { list_id: listId, item_id: data.user_list_item.id },
  removedListIds: (data.removed_user_list_items || []).map((item) => item.user_list_id)
})
this._toast("success", data.message)
```

and filter all removed ids before appending the target. Make `user_list_add_item_controller` perform the same full-state update before reloading its Turbo frame. Do not add completion dates to persisted list state; membership tuple shape remains `{list_id, item_id}` and `STATE_SCHEMA` remains `2`.

- [ ] **Step 5: Run endpoint and frontend tests**

Run:

```bash
bin/rails test test/controllers/user_list_items_controller_test.rb test/policies/user_list_item_policy_test.rb test/lint/stimulus_manifest_test.rb
yarn build
```

Expected: PASS.

- [ ] **Step 6: Commit the write integration**

```bash
git add config/routes.rb app/controllers/user_list_items_controller.rb app/policies/user_list_item_policy.rb app/javascript/controllers/user_list_modal_controller.js app/javascript/controllers/user_list_add_item_controller.js test/controllers/user_list_items_controller_test.rb test/policies/user_list_item_policy_test.rb test/lint/stimulus_manifest_test.rb
git commit -m "Use completion transitions for user list writes"
```

### Task 5: Reading-Goal Cache URL Enumeration and Invalidation

**Files:**
- Generate/Create: `web-app/app/sidekiq/books/reading_goals/purge_cached_pages_job.rb`
- Create: `web-app/app/lib/services/books/reading_goals/cached_urls.rb`
- Create: `web-app/app/lib/services/books/reading_goals/completion_change_invalidator.rb`
- Create: `web-app/app/lib/services/books/reading_goals/save_goal.rb`
- Create: `web-app/app/lib/services/books/reading_goals/destroy_goal.rb`
- Create: `web-app/test/lib/services/books/reading_goals/cached_urls_test.rb`
- Create: `web-app/test/lib/services/books/reading_goals/completion_change_invalidator_test.rb`
- Create: `web-app/test/lib/services/books/reading_goals/save_goal_test.rb`
- Create: `web-app/test/lib/services/books/reading_goals/destroy_goal_test.rb`
- Generate/Create: `web-app/test/sidekiq/books/reading_goals/purge_cached_pages_job_test.rb`
- Modify: `web-app/app/controllers/user_list_items_controller.rb`
- Modify: `web-app/test/controllers/user_list_items_controller_test.rb`

**Interfaces:**
- Consumes: `ProgressQuery`, mutation old/new dates, Books hosts, existing `Cloudflare::PurgeService`.
- Produces: `CachedUrls.call(goal:, count:) -> Array<String>` for base plus pages 2..N on every Books host.
- Produces: `CompletionChangeInvalidator.call(user:, old_completed_on:, new_completed_on:) -> Array<String>` and enqueues one JSON-native Sidekiq job when non-empty.
- Produces: `SaveGoal.call(goal:, attributes:) -> Result(success?, data: {goal:, persisted:, purge_confirmed:}, errors:)`.
- Produces: `DestroyGoal.call(goal:) -> Result(success?, data: {goal:}, errors:)`.

- [ ] **Step 1: Generate the Sidekiq job and write failing cache tests**

Run the project job generator from `web-app/`, then move/adjust the generated class only through generator-supported namespacing if necessary:

```bash
bin/rails generate sidekiq:job books/reading_goals/purge_cached_pages
```

Tests must assert:

```ruby
test "enumerates base and every existing page for every configured Books host" do
  Rails.application.config.domains.stubs(:[]).with(:books).returns("books.test,books-alt.test")

  urls = Services::Books::ReadingGoals::CachedUrls.call(goal: goal, count: 49)

  assert_equal [
    "https://books.test/reading_goals/#{goal.id}",
    "https://books.test/reading_goals/#{goal.id}/page/2",
    "https://books.test/reading_goals/#{goal.id}/page/3",
    "https://books-alt.test/reading_goals/#{goal.id}",
    "https://books-alt.test/reading_goals/#{goal.id}/page/2",
    "https://books-alt.test/reading_goals/#{goal.id}/page/3"
  ], urls
end

test "a completion moving between ranges purges both affected public goals" do
  Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async)
    .with("books", includes(old_goal_url, new_goal_url))

  Services::Books::ReadingGoals::CompletionChangeInvalidator.call(
    user: user,
    old_completed_on: Date.new(2025, 12, 31),
    new_completed_on: Date.new(2026, 1, 1)
  )
end

test "public to private saves origin first and synchronously purges every old url" do
  purge = mock
  purge.expects(:purge_urls).with(:books, kind_of(Array)).returns(success: true)
  Cloudflare::PurgeService.stubs(:new).returns(purge)

  result = Services::Books::ReadingGoals::SaveGoal.call(goal: public_goal, attributes: {public: false})

  assert result.success?
  refute public_goal.reload.public?
  assert result.data[:purge_confirmed]
end
```

Add cases for a count dropping from 25 to 24 (old `/page/2` retained), undated/same-date no-op, private goals excluded, date changed within one range, async public updates, create/delete, missing token no-op in development/test, synchronous purge failure persisting privacy plus queuing retry, 100-URL job chunking, and a failed purge result raising so Sidekiq retries it.

- [ ] **Step 2: Run cache tests and verify they fail**

Run:

```bash
bin/rails test test/lib/services/books/reading_goals test/sidekiq/books/reading_goals/purge_cached_pages_job_test.rb
```

Expected: FAIL because the cache services do not exist.

- [ ] **Step 3: Implement exact URL enumeration**

`CachedUrls` must use `ProgressQuery::PER_PAGE`, omit `/page/1`, always include the base page even at count zero, and split the configured domain value exactly like `Services::News::CachedUrls`. Build `https://HOST/reading_goals/ID` plus `/page/N` directly so this independently testable task does not depend on routes introduced in Task 6.

```ruby
pages = [1, (count.to_i.fdiv(ProgressQuery::PER_PAGE)).ceil].max
```

- [ ] **Step 4: Implement completion-change invalidation using post-write counts**

Find only `user.books_reading_goals.public_goals` whose inclusive range contains old or new non-nil dates. For each affected goal, compute `after_count` from `ProgressQuery.call(goal: goal).count` and infer the old count:

```ruby
delta = (contains?(goal, new_completed_on) ? 1 : 0) -
  (contains?(goal, old_completed_on) ? 1 : 0)
before_count = after_count - delta
urls = CachedUrls.call(goal: goal, count: before_count) +
  CachedUrls.call(goal: goal, count: after_count)
```

Return early when old and new dates are equal. Enqueue only the unique URL union.

- [ ] **Step 5: Implement goal write services and synchronous privacy revocation**

Use the standard Result struct inside each service. `SaveGoal` must capture public URLs and projected count before assignment, save validation failures without purging, capture after URLs, and:

- enqueue the before/after union for ordinary create/update;
- for public-to-private, make the record private first and synchronously call `Cloudflare::PurgeService#purge_urls(:books, batch)` in chunks of 100;
- treat a missing token outside production as confirmed without constructing `Cloudflare::Configuration`;
- on synchronous failure, log an alert, enqueue the same old URLs for retry, and return `success?: false`, `persisted: true`, `purge_confirmed: false`.

`DestroyGoal` captures public URLs before destroy and enqueues them only after successful destroy.

- [ ] **Step 6: Implement the purge job**

Reuse the proven News job's token guard and 100-URL chunking, but raise on a failed Books purge so Sidekiq retries as required by this feature:

```ruby
module Books
  module ReadingGoals
    class PurgeCachedPagesJob
      include Sidekiq::Job
      sidekiq_options retry: 5

      MAX_URLS_PER_REQUEST = 100
      PurgeError = Class.new(StandardError)

      def perform(domain, urls)
        return if domain.blank? || urls.blank?
        return if ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"].blank?

        service = Cloudflare::PurgeService.new
        urls.each_slice(MAX_URLS_PER_REQUEST) do |batch|
          result = service.purge_urls(domain.to_sym, batch)
          Rails.logger.info "Books::ReadingGoals purge #{batch.size} URLs on #{domain}: #{result[:success]}"
          next if result[:success]

          Rails.logger.error "Books::ReadingGoals purge failed on #{domain}: #{result[:error]}"
          raise PurgeError, result[:error] || "Cloudflare purge failed"
        end
      end
    end
  end
end
```

- [ ] **Step 7: Replace the temporary controller no-op with Books orchestration**

```ruby
def invalidate_books_goals(result)
  return unless result.data[:listable].is_a?(Books::Book)

  Services::Books::ReadingGoals::CompletionChangeInvalidator.call(
    user: result.data[:item].user_list.user,
    old_completed_on: result.data[:old_completed_on],
    new_completed_on: result.data[:new_completed_on]
  )
end
```

Controller tests must expect no enqueue for direct undated Read adds and one invalidation call for Reading-to-Read, dated Read removal, and completion set/change/clear.

- [ ] **Step 8: Run cache and endpoint tests**

Run:

```bash
bin/rails test test/lib/services/books/reading_goals test/sidekiq/books/reading_goals/purge_cached_pages_job_test.rb test/controllers/user_list_items_controller_test.rb
```

Expected: PASS.

- [ ] **Step 9: Commit cache invalidation**

```bash
git add app/lib/services/books/reading_goals app/sidekiq/books/reading_goals app/controllers/user_list_items_controller.rb test/lib/services/books/reading_goals test/sidekiq/books/reading_goals test/controllers/user_list_items_controller_test.rb
git commit -m "Invalidate cached reading goal pages"
```

### Task 6: Reading-Goal Routes, Authorization, and Controllers

**Files:**
- Generate/Create: `web-app/app/controllers/books/reading_goals_controller.rb`
- Generate/Create: `web-app/app/controllers/books/my/reading_goals_controller.rb`
- Generate/Create: `web-app/app/controllers/books/reading_goal_state_controller.rb`
- Create: `web-app/app/policies/books/reading_goal_policy.rb`
- Modify: `web-app/config/routes.rb`
- Modify: `web-app/app/views/layouts/books/application.html.erb`
- Create: `web-app/test/controllers/books/reading_goals_controller_test.rb`
- Create: `web-app/test/controllers/books/my/reading_goals_controller_test.rb`
- Create: `web-app/test/controllers/books/reading_goal_state_controller_test.rb`
- Create: `web-app/test/policies/books/reading_goal_policy_test.rb`
- Create: `web-app/test/routing/books_reading_goals_routes_test.rb`

**Interfaces:**
- Consumes: Tasks 1, 2, and 5 model/query/write services.
- Produces: Books-domain routes from the approved spec, `Books::ReadingGoalPolicy`, viewer-neutral public show, authenticated owner CRUD, authenticated no-store state JSON.

- [ ] **Step 1: Generate controller shells**

Run:

```bash
bin/rails generate controller Books::ReadingGoals --skip-routes --skip-helper --skip-assets
bin/rails generate controller Books::My::ReadingGoals --skip-routes --skip-helper --skip-assets
bin/rails generate controller Books::ReadingGoalState --skip-routes --skip-helper --skip-assets
```

Expected: namespaced controller/test shells are generated; remove generator-created empty views that are not named actions.

- [ ] **Step 2: Write failing route, policy, cache, and CRUD tests**

Assert every approved route is Books-domain constrained, including:

```ruby
assert_routing({method: :get, path: "/reading_goals/123"},
  controller: "books/reading_goals", action: "show", id: "123")
assert_routing({method: :get, path: "/my/reading-goals"},
  controller: "books/my/reading_goals", action: "index")
assert_routing({method: :get, path: "/reading_goal_state/123"},
  controller: "books/reading_goal_state", action: "show", id: "123")
```

Controller tests must assert:

```ruby
test "anonymous public show is cacheable, viewer-neutral, and has no session cookie" do
  get books_reading_goal_path(public_goal), headers: {"HOST" => books_host}

  assert_response :success
  assert_includes response.headers.fetch("Cache-Control"), "public"
  assert_includes response.headers.fetch("Cache-Control"), "max-age=86400"
  assert_nil response.headers["Set-Cookie"]
  refute_includes response.body, edit_books_my_reading_goal_path(public_goal)
  refute_includes response.body, "data-signed-in"
end

test "private owner and admin show are no-store while strangers receive no-store 404" do
  [private_goal.user, users(:admin_user), users(:editor_user)].each do |viewer|
    sign_in_as viewer, stub_auth: true
    get books_reading_goal_path(private_goal), headers: {"HOST" => books_host}
    expected = (viewer == private_goal.user || viewer.admin?) ? :success : :not_found
    assert_response expected
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
  end
end
```

Also cover 24-item pagination, `/page/1` 301, past-last 404, `?page=1` redirecting to the bare URL, valid `?page=N` redirecting to `/page/N`, malformed query pages returning 404, grouped index ordering, defaults, validation 422, ownership/admin scope, create/update/delete Results, public-to-private unconfirmed-purge warning, state endpoint auth/no-store/manage boolean, and all three legacy redirects. Restrict controller assertions to response behavior, assigned records, cache/security headers, and redirects; presentation copy and styling belong in component and Playwright coverage.

- [ ] **Step 3: Run controller/policy/routing tests and verify failures**

Run:

```bash
bin/rails test test/controllers/books test/policies/books/reading_goal_policy_test.rb test/routing/books_reading_goals_routes_test.rb
```

Expected: FAIL because routes, policy, and actions do not exist.

- [ ] **Step 4: Add Books-constrained canonical and legacy routes**

Inside the existing Books `DomainConstraint` block, declare static owner paths before numeric public ids:

```ruby
get "my/reading-goals", to: "books/my/reading_goals#index", as: :books_my_reading_goals
get "my/reading-goals/new", to: "books/my/reading_goals#new", as: :new_books_my_reading_goal
post "my/reading-goals", to: "books/my/reading_goals#create"
get "my/reading-goals/:id/edit", to: "books/my/reading_goals#edit", as: :edit_books_my_reading_goal, constraints: {id: /\d+/}
patch "my/reading-goals/:id", to: "books/my/reading_goals#update", as: :books_my_reading_goal, constraints: {id: /\d+/}
delete "my/reading-goals/:id", to: "books/my/reading_goals#destroy", constraints: {id: /\d+/}

get "reading_goal_state/:id", to: "books/reading_goal_state#show", as: :books_reading_goal_state, constraints: {id: /\d+/}
get "reading_goals", to: redirect("/my/reading-goals", status: 301)
get "reading_goals/new", to: redirect("/my/reading-goals/new", status: 301)
get "reading_goals/:id/edit", to: redirect("/my/reading-goals/%{id}/edit", status: 301), constraints: {id: /\d+/}
get "reading_goals/:id", to: "books/reading_goals#show", as: :books_reading_goal, constraints: {id: /\d+/}
get "reading_goals/:id/page/1", to: redirect("/reading_goals/%{id}", status: 301), constraints: {id: /\d+/}
get "reading_goals/:id/page/:page", to: "books/reading_goals#show", as: :books_reading_goal_page, constraints: {id: /\d+/, page: /[1-9]\d*/}
```

Place `reading_goals/new` and `reading_goals/:id/edit` before the numeric public show route so route order is unambiguous.

- [ ] **Step 5: Implement policy and public controller**

Policy rules are: public/owner/admin show; signed-in create; owner/admin update/edit/destroy; scope all for admins and owned rows otherwise.

The public controller includes `Pagy::Method`, `Cacheable`, and `PathBasedPagination`, uses `layout "books/application"`, and chooses cache behavior only after loading the goal:

```ruby
def set_goal_and_cache_policy
  @reading_goal = Books::ReadingGoal.find(params[:id])
  if @reading_goal.public?
    cache_for_show_page
  else
    prevent_caching
    raise ActiveRecord::RecordNotFound unless Books::ReadingGoalPolicy.new(current_user, @reading_goal).show?
  end
end
```

Do not call `current_user` on the public branch. Remove the unused `data-signed-in="<%= signed_in? %>"` attribute from the Books layout; every auth-aware controller already uses the `tg_uid` cookie/no-store state pattern, and leaving this session read in the shared layout would personalize cacheable HTML. Before querying progress, canonicalize a query-string `page` parameter: an exact positive integer `1` redirects permanently to `books_reading_goal_path`, an integer greater than one redirects permanently to `books_reading_goal_page_path`, and arrays/hashes/zero/negative/non-numeric/leading-zero values raise `ActiveRecord::RecordNotFound`:

```ruby
def canonicalize_query_page
  return unless request.query_parameters.key?("page")

  raw = request.query_parameters["page"]
  raise ActiveRecord::RecordNotFound unless raw.is_a?(String) && raw.match?(/\A[1-9]\d*\z/)

  location = if raw.to_i == 1
    books_reading_goal_path(@reading_goal)
  else
    books_reading_goal_page_path(@reading_goal, raw.to_i)
  end
  redirect_to location, status: :moved_permanently
end
```

In `show`, call `ProgressQuery` with the route-segment page and then `pagy_path_count(@progress.count, limit: ProgressQuery::PER_PAGE)` to reject pages beyond the result while rendering `@progress.items`.

- [ ] **Step 6: Implement owner CRUD and defaults**

Require sign-in and `prevent_caching` for every action. Resolve the policy scope so admins retain legacy management access. New defaults are exactly:

```ruby
year = Date.current.year
current_user.books_reading_goals.build(
  name: "My #{year} Reading Goal",
  description: "My yearly reading goal",
  target_count: 12,
  starts_on: Date.new(year, 1, 1),
  ends_on: Date.new(year, 12, 31),
  public: false
)
```

Group the index with Task 1 scopes using one captured `today = Date.current`. Create/update must delegate to `SaveGoal`; delete delegates to `DestroyGoal`. Validation failures render the form with status 422. A persisted public-to-private result with `purge_confirmed: false` redirects to the owner index with an explicit alert that the origin is private but edge purge confirmation failed.

The only assignable goal attributes are:

```ruby
params.require(:reading_goal).permit(
  :name, :description, :target_count, :starts_on, :ends_on, :public
)
```

- [ ] **Step 7: Implement the state endpoint**

Require sign-in, call `prevent_caching`, find the goal, and return:

```ruby
render json: {
  can_manage: Books::ReadingGoalPolicy.new(current_user, goal).update?,
  manage_url: edit_books_my_reading_goal_path(goal)
}
```

Return an uncached 404 when the goal itself is not public and the viewer cannot show it.

- [ ] **Step 8: Run all routing/controller/policy tests**

Run:

```bash
bin/rails test test/controllers/books test/policies/books/reading_goal_policy_test.rb test/routing/books_reading_goals_routes_test.rb
```

Expected: PASS.

- [ ] **Step 9: Commit the HTTP surface**

```bash
git add config/routes.rb app/controllers/books app/policies/books/reading_goal_policy.rb app/views/layouts/books/application.html.erb test/controllers/books test/policies/books/reading_goal_policy_test.rb test/routing/books_reading_goals_routes_test.rb
git commit -m "Add reading goal routes and controllers"
```

### Task 7: Reading-Goal Components, Forms, and Public/Owner Pages

**Files:**
- Generate/Create: `web-app/app/components/books/reading_goals/progress_component.rb`
- Generate/Create: `web-app/app/components/books/reading_goals/progress_component.html.erb`
- Generate/Create: `web-app/app/components/books/reading_goals/goal_card_component.rb`
- Generate/Create: `web-app/app/components/books/reading_goals/goal_card_component.html.erb`
- Generate/Create: `web-app/app/components/books/reading_goals/book_card_component.rb`
- Generate/Create: `web-app/app/components/books/reading_goals/book_card_component.html.erb`
- Generate/Create: `web-app/test/components/books/reading_goals/progress_component_test.rb`
- Generate/Create: `web-app/test/components/books/reading_goals/goal_card_component_test.rb`
- Generate/Create: `web-app/test/components/books/reading_goals/book_card_component_test.rb`
- Create: `web-app/app/views/books/reading_goals/show.html.erb`
- Create: `web-app/app/views/books/my/reading_goals/index.html.erb`
- Create: `web-app/app/views/books/my/reading_goals/new.html.erb`
- Create: `web-app/app/views/books/my/reading_goals/edit.html.erb`
- Create: `web-app/app/views/books/my/reading_goals/_form.html.erb`
- Create: `web-app/app/javascript/controllers/books/reading_goal_state_controller.js`
- Modify: `web-app/app/javascript/manifests/books_web.js`
- Modify: `web-app/test/lint/stimulus_manifest_test.rb`
- Modify: Task 6 controller tests only for cache-safety and authorization behavior exposed by the rendered response.

**Interfaces:**
- Consumes: Task 6 instance variables and routes; `Books::CardComponent`.
- Produces: reusable progress/card components; semantic form; viewer-neutral public page with hydrated Manage link.

- [ ] **Step 1: Read the required UI references before editing markup**

Run:

```bash
sed -n '1,260p' docs/external-libraries/daisyui-llms.txt
sed -n '1,260p' ../.claude/agents/ui-engineer.md
```

Expected: review the DaisyUI 5 form/dialog/progress guidance and the project UI brief before choosing classes.

- [ ] **Step 2: Generate the three ViewComponents**

Run:

```bash
bin/rails generate component Books::ReadingGoals::Progress
bin/rails generate component Books::ReadingGoals::GoalCard
bin/rails generate component Books::ReadingGoals::BookCard
```

Expected: sidecar component Ruby/template/test files are generated in the configured project layout.

- [ ] **Step 3: Write failing component and rendered-page tests**

Assert that the progress component exposes text and native semantics independently of color:

```ruby
render_inline Books::ReadingGoals::ProgressComponent.new(
  count: 15, target_count: 12, percentage: 125.0, bar_percentage: 100.0
)

assert_text "15 of 12 books"
assert_text "125%"
assert_selector "progress[value='100'][max='100']"
```

Goal-card tests assert date range, Public/Private badge, progress, View/Edit/Delete, and Copy Share Link only for public goals. Book-card tests assert the standard `Books::CardComponent` content plus `Completed August 26, 2026`. Playwright covers active/upcoming/finished headings, useful empty states, form labels/help/errors, owner/description/range on show, and the 24-card grid. The public controller test retains the security assertion that no server-rendered Manage URL appears in cacheable HTML.

- [ ] **Step 4: Run component and controller render tests**

Run:

```bash
bin/rails test test/components/books/reading_goals test/controllers/books/reading_goals_controller_test.rb test/controllers/books/my/reading_goals_controller_test.rb
```

Expected: FAIL because components and views are empty or absent.

- [ ] **Step 5: Implement accessible components and pages**

`ProgressComponent` receives primitive values, renders `X of Y books` and formatted percentage, and uses `<progress max="100" value="bar_percentage">` with an accessible label.

`GoalCardComponent` receives `goal:` and `progress:`, uses the approved actions, uses `data-turbo-confirm` for Delete, and gives Copy Share Link a readonly source plus the existing `clipboard-copy` Stimulus controller. Register `clipboard-copy` in `books_web.js`; it is currently registered only in the admin bundle.

`BookCardComponent` receives `item:` and `index:`, renders `Books::CardComponent.new(book: item.listable, index: index)`, and visibly prints `item.completed_on.to_fs(:long)`.

The public show page uses `Books::CardComponent::GRID_CONTAINER_CLASS`, path-based Pagy links, a no-books empty state, and a hidden Manage anchor containing no URL until state hydration succeeds.

The owner form uses exactly these parameter names:

```erb
<%= form_with model: reading_goal, scope: :reading_goal,
      url: reading_goal.persisted? ? books_my_reading_goal_path(reading_goal) : books_my_reading_goals_path do |form| %>
  <%= form.text_field :name, required: true %>
  <%= form.text_area :description %>
  <%= form.number_field :target_count, min: 1, required: true %>
  <%= form.date_field :starts_on, required: true %>
  <%= form.date_field :ends_on, required: true %>
  <%= form.check_box :public %>
<% end %>
```

Under each field, render `reading_goal.errors.full_messages_for(:name)`, `:description`, `:target_count`, `:starts_on`, `:ends_on`, or `:public` for that field only. Explain: “Public goals can be shared with anyone who has the link.”

- [ ] **Step 6: Hydrate the Manage link from the no-store state endpoint**

The Books-only Stimulus controller reads goal id and state URL values, skips fetch without the `tg_uid` cookie, fetches JSON with same-origin credentials, and only then assigns `href = data.manage_url` and reveals the link when `data.can_manage` is true. Register it as `books--reading-goal-state` in `books_web.js` and satisfy the manifest lint test.

- [ ] **Step 7: Run components, controller renders, and frontend lint/build**

Run:

```bash
bin/rails test test/components/books/reading_goals test/controllers/books/reading_goals_controller_test.rb test/controllers/books/my/reading_goals_controller_test.rb test/lint/stimulus_manifest_test.rb
yarn build
yarn build:css
```

Expected: PASS with no missing Stimulus registration or asset build failure.

- [ ] **Step 8: Commit goal UI**

```bash
git add app/components/books/reading_goals app/views/books/reading_goals app/views/books/my/reading_goals app/javascript/controllers/books/reading_goal_state_controller.js app/javascript/manifests/books_web.js test/components/books/reading_goals test/controllers/books test/lint/stimulus_manifest_test.rb
git commit -m "Build reading goal owner and public pages"
```

### Task 8: Completion-Date Editor on Books I've Read

**Files:**
- Generate/Create: `web-app/app/components/user_lists/show/completion_dialog_component.rb`
- Generate/Create: `web-app/app/components/user_lists/show/completion_dialog_component.html.erb`
- Generate/Create: `web-app/test/components/user_lists/show/completion_dialog_component_test.rb`
- Create: `web-app/app/javascript/controllers/user_list_completion_controller.js`
- Modify: `web-app/app/javascript/manifests/web_shared.js`
- Modify: `web-app/app/components/user_lists/show/item_component.rb`
- Modify: `web-app/app/components/user_lists/show/item_component/item_component.html.erb`
- Modify: `web-app/app/views/my_lists/show.html.erb`
- Modify: `web-app/test/components/user_lists/show/item_component_test.rb`
- Modify: `web-app/test/controllers/my_lists_controller_test.rb`
- Modify: `web-app/test/lint/stimulus_manifest_test.rb`

**Interfaces:**
- Consumes: `user_list_item_completion_path`, completion-capable list declaration, Task 4 update action.
- Produces: one accessible dialog per list page; Edit completion date trigger in grid/list/table views for the owner only.

- [ ] **Step 1: Re-read the pinned dialog/form guidance and generate the component**

Run:

```bash
rg -n "dialog|modal|form-control|date" docs/external-libraries/daisyui-llms.txt
bin/rails generate component UserLists::Show::CompletionDialog
```

Expected: the dialog API and component files are available before markup is written.

- [ ] **Step 2: Write failing component, item, and controller-render tests**

Tests must assert:

- owner + Books Read list: each view mode has an “Edit completion date for TITLE” button;
- non-owner, Reading, Favorites, and other non-capable lists: no edit button/dialog;
- one dialog exists per page, not one per item;
- dialog has a labeled date input, Save, Clear date, and Cancel;
- trigger data contains item id/date/title but no general mass-assignment fields;
- Turbo frame links still target `_top` for book navigation.

Use selectors such as:

```ruby
assert_selector "button[data-action='user-list-completion#open'][data-item-id='#{item.id}']"
assert_selector "dialog#completion-date-dialog", count: 1
assert_selector "input[type='date'][name='user_list_item[completed_on]']"
```

- [ ] **Step 3: Run the focused UI tests and verify failures**

Run:

```bash
bin/rails test test/components/user_lists/show test/controllers/my_lists_controller_test.rb test/lint/stimulus_manifest_test.rb
```

Expected: FAIL because there is no edit action or dialog controller.

- [ ] **Step 4: Pass owner editability into item rendering**

Change `ItemComponent#initialize` to accept `completion_editable: false`. Add the trigger alongside the displayed completion date in all three view modes. In grid view, wrap the standard Books card and place the completion line/button beneath it so cover dimensions remain unchanged. The button carries:

```erb
data-action="user-list-completion#open"
data-item-id="<%= item.id %>"
data-item-title="<%= title %>"
data-completed-on="<%= item.completed_on&.iso8601 %>"
```

Pass `completion_editable: @owner && show_completed` from `my_lists/show`.

- [ ] **Step 5: Implement one Turbo-backed dialog and Stimulus controller**

Render the dialog once after the `list_items` frame. Its `form_with` method is PATCH; the controller updates its action to `/user_list_items/${id}/completion`, title, and date on open. `clear` sets the date input to `""` and calls `form.requestSubmit()`. `cancel` calls `dialog.close()` and restores focus to the opening button. Escape and backdrop close behavior must preserve native `<dialog>` keyboard semantics.

Register `user-list-completion` in `web_shared.js`; do not register it only in Books because the component is the intended cross-media completion surface.

- [ ] **Step 6: Run UI tests and asset build**

Run:

```bash
bin/rails test test/components/user_lists/show test/controllers/my_lists_controller_test.rb test/lint/stimulus_manifest_test.rb
yarn build
```

Expected: PASS.

- [ ] **Step 7: Commit completion-date UI**

```bash
git add app/components/user_lists/show app/views/my_lists/show.html.erb app/javascript/controllers/user_list_completion_controller.js app/javascript/manifests/web_shared.js test/components/user_lists/show test/controllers/my_lists_controller_test.rb test/lint/stimulus_manifest_test.rb
git commit -m "Add read-list completion date editor"
```

### Task 9: Responsive My Books Navigation Group

**Files:**
- Modify: `web-app/app/views/books/shared/_nav_links.html.erb`
- Modify: `web-app/app/javascript/controllers/user_list_state_controller.js`
- Modify: `web-app/test/controllers/my_lists_controller_test.rb`
- Modify: `web-app/test/controllers/my_reviews_controller_test.rb`
- Modify: `web-app/test/controllers/saved_searches_controller_test.rb`
- Modify: `web-app/e2e/tests/books/account/my-lists.spec.ts`

**Interfaces:**
- Consumes: Existing `variant: :horizontal/:vertical` nav partial and signed-in user-list hydration.
- Produces: hidden `#navbar_my_books` wrapper; desktop dropdown and inline mobile children ordered Lists, Reading Goals, Reviews, Saved Searches.

- [ ] **Step 1: Update the hydration-hook integration assertion and write failing Playwright nav expectations**

Update the existing Rails integration assertion from the three removed ids to the one cache-safe hydration hook:

```ruby
assert_includes response.body, 'id="navbar_my_books"'
refute_includes response.body, 'id="navbar_my_lists"'
```

In Playwright, desktop must expose a single visible `<details><summary>My Books</summary>` whose links are ordered Lists, Reading Goals, Reviews, Saved Searches. The vertical drawer must render “My Books” as an inline menu title with the same visible child order and no nested disclosure. Playwright must assert signed-in hydration reveals the responsive `#navbar_my_books` copy. Keep a Rails regression assertion that Music/Games layouts still emit `#navbar_my_lists`; this Books-only nav refactor must not strand those shared-controller links hidden.

- [ ] **Step 2: Run nav tests and verify failures**

Run:

```bash
bin/rails test test/controllers/my_lists_controller_test.rb test/controllers/my_reviews_controller_test.rb test/controllers/saved_searches_controller_test.rb
yarn build
```

Expected: FAIL because the three top-level links still exist.

- [ ] **Step 3: Replace top-level personal links with the responsive group**

Use the partial's existing `variant` local. Horizontal markup is one hidden dropdown; vertical markup is one hidden inline section. Preserve client hydration by shipping the entire wrapper hidden in cacheable HTML.

Make the shared state controller choose the Books group without breaking the existing Music/Games links:

```javascript
const selector = this.domain === "books" ? "#navbar_my_books" : "#navbar_my_lists"
document.querySelectorAll(selector).forEach((element) => {
  element.classList.toggle("hidden", !visible)
})
```

The persisted state shape does not change, so keep `STATE_SCHEMA = 2`.

- [ ] **Step 4: Update Playwright nav expectations and run focused tests**

Change the existing Books account test to reveal `#navbar_my_books`, open the desktop summary, and assert all four ordered child links. Add a mobile viewport assertion that the drawer shows the inline section without an additional disclosure.

Run:

```bash
bin/rails test test/controllers/my_lists_controller_test.rb test/controllers/my_reviews_controller_test.rb test/controllers/saved_searches_controller_test.rb
yarn build
```

Expected: PASS.

- [ ] **Step 5: Commit navigation**

```bash
git add app/views/books/shared/_nav_links.html.erb app/javascript/controllers/user_list_state_controller.js test/controllers/my_lists_controller_test.rb test/controllers/my_reviews_controller_test.rb test/controllers/saved_searches_controller_test.rb e2e/tests/books/account/my-lists.spec.ts
git commit -m "Group personal links under My Books"
```

### Task 10: Idempotent Legacy Reading-Goal Migration and Repair Report

**Files:**
- Generate/Create: `web-app/app/models/legacy_books/reading_goal.rb`
- Generate/Create: `web-app/app/models/legacy_books/reading_goal_book.rb`
- Generate/Create: `web-app/test/models/legacy_books/reading_goal_test.rb`
- Generate/Create: `web-app/test/models/legacy_books/reading_goal_book_test.rb`
- Create: `web-app/app/lib/services/books_migration/reading_goal_migrator.rb`
- Create: `web-app/app/lib/services/books_migration/reading_goal_verification.rb`
- Create: `web-app/test/lib/services/books_migration/reading_goal_migrator_test.rb`
- Create: `web-app/test/lib/services/books_migration/reading_goal_verification_test.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`
- Modify: `web-app/test/lib/tasks/data_migration_test.rb`

**Interfaces:**
- Consumes: Legacy `reading_goals` and `reading_goal_books`; already-migrated users, Books user lists, and user-list items.
- Produces: `Services::BooksMigration::ReadingGoalMigrator.call` bulk-upsert result hash; `ReadingGoalVerification.call` standard Result with definition counts and repair-category counts; rake tasks `data_migration:reading_goals` and `data_migration:verify_reading_goals`.

- [ ] **Step 1: Generate read-only legacy model shells without migrations or fixtures**

Run:

```bash
bin/rails generate model LegacyBooks::ReadingGoal --skip-migration --skip-fixture
bin/rails generate model LegacyBooks::ReadingGoalBook --skip-migration --skip-fixture
```

Expected: Rails generates both model and matching test shells without creating target schema for legacy tables.

- [ ] **Step 2: Write failing migrator and verification tests without opening the legacy connection**

Stub `legacy_each` and legacy model relations, following existing migration tests. Assert exact mapping:

```ruby
assert_equal({
  id: 438,
  user_id: user.id,
  name: "500 by 2035",
  description: "Long goal",
  target_count: 500,
  starts_on: Date.new(2020, 1, 1),
  ends_on: Date.new(2035, 12, 31),
  public: true,
  created_at: legacy_created_at,
  updated_at: legacy_updated_at
}, captured_row.symbolize_keys)
refute_includes captured_row.keys.map(&:to_s), "percentage_done"
```

Add tests for null public becoming false, missing owner, target <= 0, reversed/missing dates, blank name, legacy id >= 10,000, conflicting low target ids, idempotent rerun, timestamp preservation, and a next generated id at or above both 10,000 and `maximum(:id) + 1`.

Verification fixtures must model one stale legacy membership, one date disagreement, one missing qualifying Read item, one percentage mismatch, and one overlapping-goal inclusion; assert each category separately rather than summing them.

- [ ] **Step 3: Run migration tests and verify failures**

Run:

```bash
bin/rails test test/lib/services/books_migration/reading_goal_migrator_test.rb test/lib/services/books_migration/reading_goal_verification_test.rb test/lib/tasks/data_migration_test.rb
```

Expected: FAIL because migration services and tasks do not exist and the generated legacy models still inherit from `ApplicationRecord`.

- [ ] **Step 4: Make the generated legacy models read-only connection models**

```ruby
module LegacyBooks
  class ReadingGoal < Record
    self.table_name = "reading_goals"
  end

  class ReadingGoalBook < Record
    self.table_name = "reading_goal_books"
  end
end
```

Do not add associations that can write or cascade on the legacy connection. The generated model tests only assert the explicit table name and inheritance from `LegacyBooks::Record`; stub connection access so they never open the legacy database.

- [ ] **Step 5: Implement the bulk-upsert migrator and reserved-id preflight**

Subclass `BulkUpsertMigrator`. Set `target_model` to `Books::ReadingGoal`, `unique_by` to `:id`, `legacy_model` to `LegacyBooks::ReadingGoal`, and `record_timestamps?` to false. Preload target user ids and all legacy goal ids. Before flushing, reject:

- maximum legacy id `>= 10_000`;
- any target id below 10,000 absent from the legacy id set;
- missing users, blank names, non-positive targets, missing/reversed dates.

`build_rows` returns one hash with the approved column mapping and no percentage.

Finalize the sequence with quoted SQL equivalent to:

```ruby
next_id = [10_000, Books::ReadingGoal.maximum(:id).to_i + 1].max
sequence = connection.select_value(
  "SELECT pg_get_serial_sequence('books_reading_goals', 'id')"
)
connection.execute(
  "SELECT setval(#{connection.quote(sequence)}, #{next_id}, false)"
)
```

Never call `reset_pk_sequence!` for this table.

- [ ] **Step 6: Implement the verification report**

Load the legacy goals once, derive `legacy_ids`, and scope every definition count to `Books::ReadingGoal.where(id: legacy_ids)` so legitimate new-app goals at ids 10,000+ do not make the import totals fail. For each legacy goal, compare maps with this exact classification:

```ruby
legacy_memberships = LegacyBooks::ReadingGoalBook
  .where(reading_goal_id: legacy_goal.id)
  .pluck(:book_id, :read_date).to_h
read_list_id = Books::UserList.where(user_id: legacy_goal.user_id, list_type: :read).pick(:id)
canonical = if read_list_id
  UserListItem.where(user_list_id: read_list_id, listable_type: "Books::Book")
    .pluck(:listable_id, :completed_on).to_h
else
  {}
end
projected = canonical.select do |_book_id, completed_on|
  completed_on.present? && (legacy_goal.start_date..legacy_goal.end_date).cover?(completed_on)
end

stale_count += legacy_memberships.keys.count { |book_id| !canonical.key?(book_id) }
disagreement_count += legacy_memberships.count do |book_id, read_date|
  canonical.key?(book_id) && canonical[book_id] != read_date
end
missing_count += (projected.keys - legacy_memberships.keys).size
derived_percentage = (legacy_memberships.size.fdiv(legacy_goal.number_of_books) * 100).round(2)
stored_percentage = legacy_goal.percentage_done.nil? ? BigDecimal("0") : BigDecimal(legacy_goal.percentage_done.to_s)
drift_count += 1 unless stored_percentage == BigDecimal(derived_percentage.to_s)
```

Return:

```ruby
Result.new(
  success?: errors.empty?,
  data: {
    imported_goals: imported_scope.count,
    distinct_owners: imported_scope.distinct.count(:user_id),
    public_goals: imported_scope.public_goals.count,
    id_range: imported_scope.minimum(:id)..imported_scope.maximum(:id),
    missing_imported_owners: missing_owner_count,
    unexpected_low_target_ids: unexpected_low_ids,
    persisted_goal_book_rows: 0,
    persisted_percentage_columns: 0,
    repairs: {
      stale_memberships: stale_count,
      date_disagreements: disagreement_count,
      missing_qualifying_books: missing_count,
      percentage_drift: drift_count
    }
  },
  errors: errors
)
```

Compute `persisted_goal_book_rows` by checking the target connection for `reading_goal_books` and `books_reading_goal_books` and counting them only if present; compute `persisted_percentage_columns` by intersecting `Books::ReadingGoal.column_names` with `%w[percentage percentage_done]`. Do not hard-code those two zeroes without inspecting the target schema.

The production report asserts the approved definition totals `399`, `374`, `8`, and id range `1..438`; repair counts are reported as evidence and do not fail the run. Compute the new projection from canonical dated Read-list items, never by creating a target join table.

- [ ] **Step 7: Add ordered rake tasks that abort on failure**

```ruby
desc "Migrate legacy reading goals after Books user-list items"
task reading_goals: :environment do
  result = Services::BooksMigration::ReadingGoalMigrator.call
  pp result
  abort "reading_goals migration failed: #{result[:error]}" unless result[:success]
end

desc "Verify imported reading goals and report intentional live-projection repairs"
task verify_reading_goals: :environment do
  result = Services::BooksMigration::ReadingGoalVerification.call
  pp result.data
  abort "reading_goals verification failed: #{result.errors.join('; ')}" unless result.success?
end
```

Insert `:reading_goals` into `data_migration:all` immediately after `:user_list_items` and before `:saved_searches`/`:reviews`.

- [ ] **Step 8: Run migration tests**

Run:

```bash
bin/rails test test/models/legacy_books/reading_goal_test.rb test/models/legacy_books/reading_goal_book_test.rb test/lib/services/books_migration/reading_goal_migrator_test.rb test/lib/services/books_migration/reading_goal_verification_test.rb test/lib/tasks/data_migration_test.rb
```

Expected: PASS, including the second-run idempotency assertion.

- [ ] **Step 9: Commit migration code**

```bash
git add app/models/legacy_books app/lib/services/books_migration/reading_goal_migrator.rb app/lib/services/books_migration/reading_goal_verification.rb lib/tasks/data_migration.rake test/models/legacy_books test/lib/services/books_migration test/lib/tasks/data_migration_test.rb
git commit -m "Migrate legacy reading goals"
```

### Task 11: End-to-End Feature Coverage and Final Verification

**Files:**
- Create: `web-app/e2e/tests/books/account/reading-goals.spec.ts`

**Interfaces:**
- Consumes: complete Tasks 1–10 feature surface.
- Produces: browser-level regression coverage and verification evidence for branch handoff.

- [ ] **Step 1: Write the authenticated Playwright flow**

Use a serial describe so the same goal/book can move through a real lifecycle. The test must:

1. open My Books → Reading Goals;
2. create a private current-year goal and observe it under Active;
3. edit target/description/range and make it public;
4. copy/inspect its stable `/reading_goals/:id` share URL;
5. put a known book on Reading, then toggle Read and observe Reading removed, Read added, completion today, and goal progress incremented;
6. open Books I've Read, set a historical date, change it, clear it, and observe goal membership after each action;
7. restore an in-range date, then remove the book from Read and observe progress decrement;
8. directly add a second book to Read, confirm it is initially undated, then set an in-range completion date so the public card/date projection remains covered;
9. create a second goal that stays private for the anonymous-denial check and retain both ids for the next serial test.

Use role/test-id selectors, not CSS classes. Assert dialog focus and keyboard Escape/Cancel behavior. Do not enter a completion date in the quick widget because that control must not exist.

- [ ] **Step 2: Write anonymous public/private and responsive nav coverage in the same serial suite**

Retain the created public/private goal ids in module variables, then create a fresh `browser.newContext({baseURL: "https://dev-new.thegreatestbooks.org", ignoreHTTPSErrors: true})` with no storage state. Assert public 200 and private 404 in pages from that anonymous context, then close it. On the public page assert owner, description, inclusive range, truthful progress text, completion dates, and absence of Manage. In the authenticated context, assert the My Books dropdown at desktop width and the inline drawer group at mobile width, then delete both goals through their confirmation flows and remove the second test book from Read so reruns begin from the same membership state.

- [ ] **Step 3: Run focused Rails tests and the frontend build before the browser suite**

Run:

```bash
bin/rails test test/models/books/reading_goal_test.rb test/lib/services/books/reading_goals test/lib/services/user_lists test/controllers/books test/controllers/user_list_items_controller_test.rb test/components/books/reading_goals test/components/user_lists/show
yarn build
```

Expected: PASS.

- [ ] **Step 4: Run the Books account/public Playwright files**

Run:

```bash
yarn test:e2e --project=books-account e2e/tests/books/account/reading-goals.spec.ts e2e/tests/books/account/my-lists.spec.ts
```

Expected: PASS. If the local HTTPS app is not running, start it with the repository's documented E2E command rather than weakening the test.

- [ ] **Step 5: Run formatting, full backend, asset, and schema verification**

Run:

```bash
bundle exec standardrb
bin/rails test
yarn build
yarn build:css
git diff --check
git status --short
```

Expected: StandardRB clean; all Rails tests pass with zero failures/errors; both asset builds succeed; no whitespace errors; only intentional feature-branch files are modified.

- [ ] **Step 6: Inspect the final diff against the approved spec**

Run:

```bash
git diff origin/main...HEAD --stat
git diff origin/main...HEAD -- docs/superpowers/specs/2026-08-26-reading-goals-migration-design.md config/routes.rb app/models/books/reading_goal.rb app/lib/services/books/reading_goals app/lib/services/user_lists
```

Expected: no Goodreads importer, no goal/book join table, no stored percentage, no server-personalized public goal markup, and no unrelated changes.

- [ ] **Step 7: Commit end-to-end coverage and any verified integration adjustments**

```bash
git add e2e/tests/books
git commit -m "Verify reading goals end to end"
```

- [ ] **Step 8: Use the completion and review skills before branch handoff**

Invoke `superpowers:requesting-code-review`, address technically verified findings through `superpowers:receiving-code-review`, rerun affected tests, then invoke `superpowers:verification-before-completion`. When every check is green, invoke `superpowers:finishing-a-development-branch` and present merge/PR/keep options without committing to or merging into `main` automatically.
