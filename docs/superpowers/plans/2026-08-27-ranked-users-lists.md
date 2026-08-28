# Ranked Users' Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aggregate every user's favorites list into one nightly-generated `List` per domain, normalized so a 500-item list cannot outvote fifty 10-item lists.

**Architecture:** A pure scoring service (`UserFavoritesTally`) turns each user's favorites list into a ballot worth `√N` points, spent evenly or by position depending on whether the user arranged the list. A thin writer (`GenerateUserFavorites`) persists the top 250 into a `List` identified by a new `auto_generated_kind` column. A nightly Sidekiq job runs all four domains. Rankings are *not* recalculated automatically.

**Tech Stack:** Rails 8.1, Postgres, Sidekiq + sidekiq-cron, Minitest + fixtures + Mocha.

**Spec:** `docs/superpowers/specs/2026-08-27-ranked-users-lists-design.md`

## Global Constraints

- Run all commands from `web-app/`. Docs live at the **project root** `docs/`, not `web-app/docs/`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). Run it before every commit.
- Never run destructive commands against the development database. A `PreToolUse` hook blocks `create_fixtures`, `db:drop`/`db:reset`/`db:schema:load`, and bulk `delete_all`/`destroy_all`/`update_all` in `rails runner`.
- Use Rails generators for models/jobs/migrations. Jobs: `bin/rails generate sidekiq:job <name>` (NOT `generate job`).
- Rails 8 enum syntax: `enum :status, {active: 0}` — colon prefix, never `enum status: {...}`.
- Services use the Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Minitest is 6.x: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Sidekiq test mode is `Sidekiq.testing!(:inline)`, set globally in `test_helper.rb`. Never `require "sidekiq/testing"`.
- Tests mirror the app namespace (`module Services; module Lists; class FooTest`).
- Root-anchor nested constants (`::Books::Book`, `::List`) inside `Books::`/`Music::` namespaces — unanchored references resolve to the wrong constant and raise a confusing `NameError`.

**Tuning values (exact, from the spec):** `max_items: 250`, `min_voters: 2`, `decay_exponent: 2.0`, ballot mass `√N`.

**Deviation from the spec, deliberate:** the spec proposed an `Actions::Admin::RegenerateUserFavoritesList` button. Admin `lists` resources have no `execute_action` route and `Admin::ListsBaseController` declares no `allowed_action_names` (unlike `Admin::RankingConfigurationsController`), so a button means new routes in four namespaces, a controller endpoint, UI and tests. Task 6 ships a rake task instead. The admin button remains a cheap follow-up if wanted.

---

### Task 1: `manually_ordered` flag on user lists

Records whether a user arranged their list rather than just appending to it. Backfilled for the 257 legacy books lists; set going forward by the reorder action (Phase B of user-lists).

**Files:**
- Create: `db/migrate/<timestamp>_add_manually_ordered_to_user_lists.rb`
- Create: `app/lib/services/user_lists/backfill_manually_ordered.rb`
- Create: `test/lib/services/user_lists/backfill_manually_ordered_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `user_lists.manually_ordered` (boolean, `default: false, null: false`), readable as `user_list.manually_ordered?`. `Services::UserLists::BackfillManuallyOrdered.call` → `Integer` (rows updated).

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration AddManuallyOrderedToUserLists
```

- [ ] **Step 2: Write the migration body**

Replace the generated file's contents:

```ruby
class AddManuallyOrderedToUserLists < ActiveRecord::Migration[8.1]
  def change
    # Postgres 11+ adds a NOT NULL column with a constant default without
    # rewriting the table, so this is safe on the ~350k user_lists rows.
    # Backfill is a separate rake task (Services::UserLists::BackfillManuallyOrdered):
    # it only matters for legacy-imported books data, which lives in development
    # only, and keeping it out of the migration keeps every fresh database and
    # test setup from paying for it.
    add_column :user_lists, :manually_ordered, :boolean, default: false, null: false
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: `add_column(:user_lists, :manually_ordered, ...)` and the schema dump updated.

- [ ] **Step 4: Write the failing test for the backfill service**

Create `test/lib/services/user_lists/backfill_manually_ordered_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module UserLists
    class BackfillManuallyOrderedTest < ActiveSupport::TestCase
      # Fixtures ship user lists whose positions already match insertion order,
      # which is exactly the "not curated" case, so they need no special handling.
      setup do
        @user = users(:editor_user)
        @list = ::Books::UserList.create!(
          user: @user, list_type: :favorites, name: "My Favorite Books"
        )
      end

      def add_item(book, position:, created_at:)
        ::UserListItem.create!(
          user_list: @list, listable: book, position: position
        ).update_columns(created_at: created_at, updated_at: created_at)
      end

      test "leaves a list whose position order matches insertion order alone" do
        add_item(books_books(:war_and_peace), position: 1, created_at: 3.days.ago)
        add_item(books_books(:got), position: 2, created_at: 2.days.ago)
        add_item(books_books(:clash), position: 3, created_at: 1.day.ago)

        BackfillManuallyOrdered.call

        refute @list.reload.manually_ordered?
      end

      test "flags a list whose position order differs from insertion order" do
        # Added oldest-first, but the newest item sits at position 1 -- the user
        # moved it there.
        add_item(books_books(:war_and_peace), position: 2, created_at: 3.days.ago)
        add_item(books_books(:got), position: 3, created_at: 2.days.ago)
        add_item(books_books(:clash), position: 1, created_at: 1.day.ago)

        BackfillManuallyOrdered.call

        assert @list.reload.manually_ordered?
      end

      test "ignores non-favorites lists" do
        read_list = ::Books::UserList.create!(
          user: @user, list_type: :read, name: "Books I've Read"
        )
        item = ::UserListItem.create!(
          user_list: read_list, listable: books_books(:war_and_peace), position: 2
        )
        item.update_columns(created_at: 1.day.ago, updated_at: 1.day.ago)
        ::UserListItem.create!(
          user_list: read_list, listable: books_books(:got), position: 1
        ).update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)

        BackfillManuallyOrdered.call

        refute read_list.reload.manually_ordered?
      end

      test "returns the number of lists it flagged" do
        add_item(books_books(:war_and_peace), position: 2, created_at: 2.days.ago)
        add_item(books_books(:got), position: 1, created_at: 1.day.ago)

        assert_equal 1, BackfillManuallyOrdered.call
      end

      test "is idempotent" do
        add_item(books_books(:war_and_peace), position: 2, created_at: 2.days.ago)
        add_item(books_books(:got), position: 1, created_at: 1.day.ago)

        BackfillManuallyOrdered.call
        assert_equal 0, BackfillManuallyOrdered.call
        assert @list.reload.manually_ordered?
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/user_lists/backfill_manually_ordered_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::UserLists::BackfillManuallyOrdered`

- [ ] **Step 6: Write the service**

Create `app/lib/services/user_lists/backfill_manually_ordered.rb`:

```ruby
# frozen_string_literal: true

module Services
  module UserLists
    # Sets user_lists.manually_ordered for favorites lists whose item order
    # differs from the order the items were added in -- i.e. the user actually
    # arranged the list rather than just appending to it.
    #
    # This only recovers signal from legacy-imported data. The new app has no
    # reorder UI yet (Phase B of user-lists), so nothing created here can be
    # curated; once that ships it sets the flag directly and this becomes a
    # one-time historical backfill.
    #
    # Detection is one-directional by design: a user who adds books in preference
    # order and never has to move anything is indistinguishable from one who
    # appends carelessly. We under-claim rather than invent a ranking.
    #
    # Only flips false -> true, so it is safe to re-run.
    class BackfillManuallyOrdered
      # list_type 0 is :favorites in every UserList subclass.
      SQL = <<~SQL.freeze
        UPDATE user_lists SET manually_ordered = true, updated_at = NOW()
        WHERE manually_ordered = false
          AND id IN (
            SELECT user_list_id FROM (
              SELECT uli.user_list_id,
                row_number() OVER (
                  PARTITION BY uli.user_list_id ORDER BY uli.position, uli.id
                ) AS position_rank,
                row_number() OVER (
                  PARTITION BY uli.user_list_id ORDER BY uli.created_at, uli.id
                ) AS insertion_rank
              FROM user_list_items uli
              JOIN user_lists ul ON ul.id = uli.user_list_id
              WHERE ul.list_type = 0
            ) ranked
            GROUP BY user_list_id
            HAVING count(*) FILTER (WHERE position_rank <> insertion_rank) > 0
          )
      SQL

      def self.call
        new.call
      end

      def call
        ::UserList.connection.exec_update(SQL)
      end
    end
  end
end
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/user_lists/backfill_manually_ordered_test.rb`
Expected: PASS, 5 runs, 0 failures

- [ ] **Step 8: Prove the tests are not vacuous**

Temporarily change `HAVING count(*) FILTER (WHERE position_rank <> insertion_rank) > 0` to `> 999999`, re-run, and confirm "flags a list whose position order differs" and "returns the number of lists it flagged" go **red**. Restore the line.

This codebase has repeatedly produced tests that passed against deleted implementations. Do not skip this step.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/user_lists/backfill_manually_ordered.rb test/lib/services/user_lists/backfill_manually_ordered_test.rb
git add db/migrate db/schema.rb app/lib/services/user_lists/backfill_manually_ordered.rb test/lib/services/user_lists/backfill_manually_ordered_test.rb
git commit -m "Add manually_ordered flag to user lists with backfill service"
```

---

### Task 2: Mark generated lists and protect them from hand edits

Gives generated lists a durable identity (legacy used `find_or_create_by(name:)`, which breaks on rename), refuses manual edits to their items, and fixes an existing orphan bug.

**Files:**
- Create: `db/migrate/<timestamp>_add_auto_generated_kind_to_lists.rb`
- Modify: `app/models/list.rb`
- Modify: `app/models/list_item.rb`
- Modify: `test/models/list_item_test.rb`
- Modify: `test/models/list_test.rb`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `lists.auto_generated_kind` (integer, nullable) with `enum :auto_generated_kind, {user_favorites: 0}, prefix: :generated` → predicate `list.generated_user_favorites?`, scope `List.generated_user_favorites`. Helper `list.auto_generated?` → Boolean. `List#ranked_lists` association.

- [ ] **Step 1: Generate the migration**

```bash
bin/rails generate migration AddAutoGeneratedKindToLists
```

- [ ] **Step 2: Write the migration body**

```ruby
class AddAutoGeneratedKindToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :auto_generated_kind, :integer

    # One generated list of each kind per domain. Partial so the column stays
    # NULL for the ~600 hand-curated lists without them colliding with each other.
    add_index :lists, [:type, :auto_generated_kind],
      unique: true,
      where: "auto_generated_kind IS NOT NULL",
      name: "index_lists_on_type_and_auto_generated_kind"
  end
end
```

- [ ] **Step 3: Run the migration**

Run: `bin/rails db:migrate`
Expected: column and index added, schema dump updated.

- [ ] **Step 4: Write the failing tests**

Append to `test/models/list_item_test.rb`, inside the existing class:

```ruby
  test "rejects creating an item on an auto-generated list" do
    list = lists(:basic_list)
    list.update!(auto_generated_kind: :user_favorites)

    item = ListItem.new(list: list, listable: books_books(:war_and_peace), position: 1)

    refute item.valid?
    assert_includes item.errors[:base].join, "managed by the generator"
  end

  test "rejects updating an item on an auto-generated list" do
    list = lists(:basic_list)
    item = ListItem.create!(list: list, listable: books_books(:war_and_peace), position: 1)
    list.update!(auto_generated_kind: :user_favorites)

    item.position = 5

    refute item.valid?
  end

  test "rejects destroying an item on an auto-generated list" do
    list = lists(:basic_list)
    item = ListItem.create!(list: list, listable: books_books(:war_and_peace), position: 1)
    list.update!(auto_generated_kind: :user_favorites)

    refute item.destroy
    assert ListItem.exists?(item.id)
  end

  test "allows items on a normal list" do
    item = ListItem.new(list: lists(:basic_list), listable: books_books(:war_and_peace), position: 1)

    assert item.valid?
  end
```

Append to `test/models/list_test.rb`, inside the existing class:

```ruby
  test "auto_generated? reflects the kind column" do
    list = lists(:basic_list)

    refute list.auto_generated?

    list.update!(auto_generated_kind: :user_favorites)

    assert list.auto_generated?
    assert list.generated_user_favorites?
  end

  test "destroying a list destroys its ranked_lists rows" do
    list = lists(:basic_list)
    config = ranking_configurations(:books_global)
    ranked_list = RankedList.create!(list: list, ranking_configuration: config, weight: 10)

    list.destroy!

    refute RankedList.exists?(ranked_list.id)
  end
```

`lists(:basic_list)` is a `Books::List` and `ranking_configurations(:books_global)` is a
`Books::RankingConfiguration`, which `RankedList`'s `list_type_matches_ranking_configuration`
validation requires.

- [ ] **Step 5: Run the tests to verify they fail**

Run: `bin/rails test test/models/list_item_test.rb test/models/list_test.rb`
Expected: FAIL — the ListItem tests pass validation when they should not, and "destroying a list destroys its ranked_lists rows" fails because `RankedList` survives.

- [ ] **Step 6: Add the enum, association and helper to List**

In `app/models/list.rb`, add to the associations block after `has_many :ai_chats`:

```ruby
  # ranked_lists.list_id carries no foreign key, so without this a destroyed list
  # silently leaves an orphan RankedList row behind and the admin ranked-lists
  # view then raises on rl.list.name.
  has_many :ranked_lists, dependent: :destroy
```

Add to the enums block, after `enum :status`:

```ruby
  # Set on lists whose items are written by a generator rather than curated by
  # hand. Identifies the generated list durably across renames -- the legacy
  # implementation looked its lists up by name, which broke on any edit.
  # Prefixed so the predicate reads generated_user_favorites? rather than
  # colliding with a bare user_favorites? on List.
  enum :auto_generated_kind, {user_favorites: 0}, prefix: :generated
```

Add to the public methods section, next to `has_penalties?`:

```ruby
  def auto_generated?
    auto_generated_kind.present?
  end
```

- [ ] **Step 7: Add the guard to ListItem**

In `app/models/list_item.rb`, add to the validations block after `validate :metadata_format`:

```ruby
  validate :list_must_not_be_auto_generated
```

Add to the callbacks block after `before_validation :parse_metadata_if_string`:

```ruby
  before_destroy :prevent_destroy_when_auto_generated
```

Add to the private section:

```ruby
  # The generator owns an auto-generated list's items and rewrites them on every
  # run, so anything edited by hand is destroyed on the next pass. Refuse the
  # edit rather than lose it silently.
  #
  # Services::Lists::GenerateUserFavorites writes through delete_all / insert_all,
  # which skip callbacks and validations by design -- so this guard needs no
  # escape hatch for the job itself.
  def list_must_not_be_auto_generated
    return if list.nil? || !list.auto_generated?

    errors.add(:base, "Items on an auto-generated list are managed by the generator and cannot be edited")
  end

  def prevent_destroy_when_auto_generated
    return if list.nil? || !list.auto_generated?

    errors.add(:base, "Items on an auto-generated list are managed by the generator and cannot be edited")
    throw :abort
  end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/models/list_item_test.rb test/models/list_test.rb`
Expected: PASS

- [ ] **Step 9: Prove the guard tests are not vacuous**

Comment out the `validate :list_must_not_be_auto_generated` line, re-run, and confirm the create and update tests go **red**. Then comment out `before_destroy :prevent_destroy_when_auto_generated`, re-run, and confirm the destroy test goes **red**. Restore both.

- [ ] **Step 10: Run the full model suite for regressions**

Run: `bin/rails test test/models/`
Expected: PASS. The new `ListItem` validation runs on every list item write in the suite; if anything goes red here it is a fixture or factory writing to a list that is somehow auto-generated — investigate rather than weaken the guard.

- [ ] **Step 11: Lint and commit**

```bash
bundle exec standardrb --fix app/models/list.rb app/models/list_item.rb test/models/list_item_test.rb test/models/list_test.rb
git add db/migrate db/schema.rb app/models/list.rb app/models/list_item.rb test/models/list_item_test.rb test/models/list_test.rb
git commit -m "Identify auto-generated lists and refuse hand edits to their items"
```

---

### Task 3: The tally — turn favorites into a ranked score

The core of the feature and where all the risk lives. Pure: reads user lists, writes nothing.

**Files:**
- Create: `config/initializers/user_favorites_list.rb`
- Create: `app/lib/services/lists/user_favorites_tally.rb`
- Create: `test/lib/services/lists/user_favorites_tally_test.rb`

**Interfaces:**
- Consumes: `user_lists.manually_ordered` from Task 1.
- Produces:
  - `Rails.application.config.x.user_favorites_list` → `ActiveSupport::OrderedOptions` with keys `max_items` (250), `min_voters` (2), `decay_exponent` (2.0).
  - `Services::Lists::UserFavoritesTally.call(user_list_class:, **options)` → `Tally` = `Struct.new(:entries, :ballot_count, keyword_init: true)`, where `entries` is an `Array<Entry>` and `Entry` = `Struct.new(:listable_id, :score, :voter_count, keyword_init: true)`, ordered best-first.

- [ ] **Step 1: Write the config initializer**

Create `config/initializers/user_favorites_list.rb`:

```ruby
# frozen_string_literal: true

# Tuning knobs for Services::Lists::UserFavoritesTally and the list it generates.
#
# These are defaults. Every key is overridable per call by keyword, which is how
# tests pin behaviour without mutating global state. Changing production
# behaviour means editing this file and deploying -- deliberate, because tuning
# is a development activity done against real data.
#
# decay_exponent only affects CURATED ballots. It barely moves the outcome
# (measured on real books data, 1.0 and 3.0 produce 245 of the same 250 books);
# what it changes is what curating does to a user's own ballot. At 2.0 a user's
# top pick carries roughly 3x a flat vote while their lower favorites still
# count. At 3.0 everything past ~#35 of a 51-book list rounds to zero.
#
# min_voters is inert for books today -- 2,651 books clear it and only 250 are
# taken -- but it stops one person's obscure pick reaching a public page in the
# domains that have almost no data yet.
Rails.application.config.x.user_favorites_list = ActiveSupport::OrderedOptions.new.merge(
  max_items: 250,
  min_voters: 2,
  decay_exponent: 2.0
)
```

- [ ] **Step 2: Write the failing tests**

Create `test/lib/services/lists/user_favorites_tally_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class UserFavoritesTallyTest < ActiveSupport::TestCase
      # Fixtures ship one books favorites ballot (regular_user, two items). These
      # tests assert exact scores, so they need to own the whole population.
      # The deletion is transaction-scoped and reverted after each test.
      setup do
        ::UserListItem.where(user_list_id: ::Books::UserList.select(:id)).delete_all
        @next_user = 0
      end

      # Each ballot needs its own user: UserList validates one default list per
      # type per user, and the tally counts distinct voters.
      #
      # User has after_create :create_default_user_lists, so the favorites list
      # already exists by the time create! returns -- find it, never create a
      # second one, which one_default_per_type_per_user would reject. (Fixture
      # users skip that callback; only User.create! fires it.)
      def build_ballot(books, manually_ordered: false)
        @next_user += 1
        user = ::User.create!(email: "voter#{@next_user}@example.com")
        list = ::Books::UserList.find_by!(user: user, list_type: :favorites)
        list.update!(manually_ordered: manually_ordered)
        books.each_with_index do |book, index|
          ::UserListItem.create!(user_list: list, listable: book, position: index + 1)
        end
        list
      end

      def filler_books(count)
        Array.new(count) { |i| ::Books::Book.create!(title: "Filler Book #{i}") }
      end

      def tally(**options)
        UserFavoritesTally.call(user_list_class: ::Books::UserList, min_voters: 1, **options)
      end

      def score_for(result, book)
        result.entries.find { |entry| entry.listable_id == book.id }&.score
      end

      test "an unordered ballot splits its mass evenly" do
        a = books_books(:war_and_peace)
        b = books_books(:got)
        c = books_books(:clash)
        build_ballot([a, b, c])

        result = tally

        # Mass is sqrt(3); three items share it equally.
        expected = Math.sqrt(3) / 3
        assert_in_delta expected, score_for(result, a), 0.0001
        assert_in_delta expected, score_for(result, b), 0.0001
        assert_in_delta expected, score_for(result, c), 0.0001
      end

      test "a curated ballot splits its mass by position" do
        a = books_books(:war_and_peace)
        b = books_books(:got)
        c = books_books(:clash)
        build_ballot([a, b, c], manually_ordered: true)

        result = tally(decay_exponent: 2.0)

        # Weights are 3^2, 2^2, 1^2 = 9, 4, 1 over a total of 14.
        mass = Math.sqrt(3)
        assert_in_delta mass * 9 / 14.0, score_for(result, a), 0.0001
        assert_in_delta mass * 4 / 14.0, score_for(result, b), 0.0001
        assert_in_delta mass * 1 / 14.0, score_for(result, c), 0.0001
      end

      test "both ballot shapes spend exactly the same total mass" do
        flat = build_ballot(filler_books(6))
        curated = build_ballot(filler_books(6), manually_ordered: true)

        result = tally

        flat_ids = flat.user_list_items.pluck(:listable_id)
        curated_ids = curated.user_list_items.pluck(:listable_id)
        total = ->(ids) { result.entries.select { |e| ids.include?(e.listable_id) }.sum(&:score) }

        assert_in_delta Math.sqrt(6), total.call(flat_ids), 0.0001
        assert_in_delta Math.sqrt(6), total.call(curated_ids), 0.0001
      end

      test "ballot mass grows as the square root of list size, not linearly" do
        one = books_books(:war_and_peace)
        build_ballot([one])
        nine = filler_books(9)
        build_ballot(nine)

        result = tally

        # A 9-item ballot is worth 3x a 1-item ballot in total, not 9x.
        nine_total = result.entries.select { |e| nine.map(&:id).include?(e.listable_id) }.sum(&:score)
        assert_in_delta 1.0, score_for(result, one), 0.0001
        assert_in_delta 3.0, nine_total, 0.0001
      end

      # THE test -- the whole reason this class exists. The numbers are chosen so
      # it fails under BOTH rejected models, which is what makes it worth having:
      #
      #   position-1 share of a curated 10-item ballot = 10^2 / sum(1..10 squared)
      #                                                = 100 / 385 = 0.2597
      #
      #   sqrt mass (ours):  favourite = sqrt(10) * 0.2597 = 0.82   popular = 2.00  -> popular wins
      #   linear mass:       favourite = 10       * 0.2597 = 2.60   popular = 2.00  -> favourite wins
      #   legacy N-p+1:      favourite = 10                         popular = 2.00  -> favourite wins
      test "one large ballot cannot outvote several small ones" do
        favourite = books_books(:war_and_peace)
        popular = books_books(:got)

        build_ballot([favourite] + filler_books(9), manually_ordered: true)
        2.times { build_ballot([popular]) }

        result = tally

        assert_operator score_for(result, popular), :>, score_for(result, favourite),
          "two single-item ballots must outweigh one 10-item ballot's top pick"
      end

      test "an item below the voter floor is excluded" do
        lonely = books_books(:war_and_peace)
        shared = books_books(:got)
        build_ballot([lonely, shared])
        build_ballot([shared])

        result = UserFavoritesTally.call(user_list_class: ::Books::UserList, min_voters: 2)

        assert_nil score_for(result, lonely)
        refute_nil score_for(result, shared)
      end

      test "reports the voter count for each item" do
        shared = books_books(:got)
        2.times { build_ballot([shared]) }

        result = tally

        assert_equal 2, result.entries.first.voter_count
      end

      test "caps the result at max_items, keeping the highest scores" do
        books = filler_books(5)
        build_ballot(books, manually_ordered: true)

        result = tally(max_items: 2)

        assert_equal 2, result.entries.size
        assert_equal [books[0].id, books[1].id], result.entries.map(&:listable_id)
      end

      test "orders entries best first" do
        loved = books_books(:war_and_peace)
        liked = books_books(:got)
        3.times { build_ballot([loved]) }
        build_ballot([liked])

        result = tally

        assert_equal [loved.id, liked.id], result.entries.map(&:listable_id)
      end

      test "reports how many ballots were counted and ignores empty lists" do
        build_ballot([books_books(:war_and_peace)])
        build_ballot([books_books(:got)])
        # This user gets an empty favorites list from the after_create callback
        # and casts no ballot.
        ::User.create!(email: "empty@example.com")

        assert_equal 2, tally.ballot_count
      end

      test "ignores lists that are not favorites" do
        user = ::User.create!(email: "reader@example.com")
        read = ::Books::UserList.find_by!(user: user, list_type: :read)
        ::UserListItem.create!(user_list: read, listable: books_books(:war_and_peace), position: 1)

        result = tally

        assert_empty result.entries
        assert_equal 0, result.ballot_count
      end

      test "ignores other domains" do
        user = ::User.create!(email: "listener@example.com")
        albums = ::Music::Albums::UserList.find_by!(user: user, list_type: :favorites)
        ::UserListItem.create!(
          user_list: albums, listable: music_albums(:dark_side_of_the_moon), position: 1
        )

        result = tally

        assert_empty result.entries
        assert_equal 0, result.ballot_count
      end

      test "returns an empty tally when there are no ballots at all" do
        result = tally

        assert_equal [], result.entries
        assert_equal 0, result.ballot_count
      end
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/user_favorites_tally_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Lists::UserFavoritesTally`

- [ ] **Step 4: Write the tally**

Create `app/lib/services/lists/user_favorites_tally.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    # Aggregates every user's favorites list for one domain into a ranked tally.
    #
    # Each user's favorites list is one ballot worth sqrt(N) points in total,
    # where N is its item count. That is the whole point of this class: the
    # legacy implementation scored each item as (N - position + 1), so a ballot's
    # total was N(N+1)/2 and 26 of 3,370 books voters controlled 63% of the
    # outcome. sqrt(N) gives an engaged user roughly 5x the per-capita influence
    # of a drive-by, and lands within 3 books of pure one-person-one-vote.
    #
    # A ballot spends its mass evenly, or by position when the user actually
    # arranged the list. Both branches sum to the same total, so curating changes
    # WHERE a user's influence lands and never how much they get -- which is what
    # keeps curation from becoming a gaming vector.
    #
    # Pure: reads user lists, writes nothing.
    class UserFavoritesTally
      Entry = Struct.new(:listable_id, :score, :voter_count, keyword_init: true)
      Tally = Struct.new(:entries, :ballot_count, keyword_init: true)

      def self.call(user_list_class:, **options)
        new(user_list_class: user_list_class, **options).call
      end

      def initialize(user_list_class:, **options)
        @user_list_class = user_list_class
        @config = Rails.application.config.x.user_favorites_list.merge(options)
      end

      def call
        scores = Hash.new(0.0)
        voters = Hash.new { |hash, key| hash[key] = Set.new }
        ballots = load_ballots

        ballots.each_value do |ballot|
          listable_ids = ballot[:listable_ids]
          mass = Math.sqrt(listable_ids.size)

          shares(ballot).each_with_index do |share, index|
            listable_id = listable_ids[index]
            scores[listable_id] += mass * share
            voters[listable_id] << ballot[:user_id]
          end
        end

        Tally.new(entries: rank(scores, voters), ballot_count: ballots.size)
      end

      private

      # One row per favorited item, ordered so each ballot arrives in position
      # order -- sorting in SQL beats re-sorting 31k rows in Ruby.
      #
      # list_type is looked up through the subclass because the enum integers are
      # declared per subclass; every one of them happens to use 0 for :favorites,
      # but reading it from the class keeps that from being load-bearing.
      def load_ballots
        favorites = @user_list_class.list_types.fetch("favorites")

        rows = ::UserListItem
          .joins(:user_list)
          .where(user_lists: {type: @user_list_class.name, list_type: favorites})
          .order(Arel.sql("user_list_items.user_list_id, user_list_items.position, user_list_items.id"))
          .pluck(
            Arel.sql("user_list_items.user_list_id"),
            Arel.sql("user_lists.user_id"),
            Arel.sql("user_lists.manually_ordered"),
            Arel.sql("user_list_items.listable_id")
          )

        rows.each_with_object({}) do |(user_list_id, user_id, manually_ordered, listable_id), ballots|
          ballot = ballots[user_list_id] ||= {
            user_id: user_id, manually_ordered: manually_ordered, listable_ids: []
          }
          ballot[:listable_ids] << listable_id
        end
      end

      # How one ballot's mass divides across its items, in position order. Both
      # branches sum to 1.0.
      def shares(ballot)
        size = ballot[:listable_ids].size
        return Array.new(size, 1.0 / size) unless ballot[:manually_ordered]

        exponent = @config[:decay_exponent].to_f
        weights = Array.new(size) { |index| (size - index)**exponent }
        total = weights.sum
        weights.map { |weight| weight / total }
      end

      # Voters are counted as a set of user ids rather than a ballot count:
      # UserList's one-default-per-type-per-user validation has no backing index,
      # so two concurrent first-visit requests can leave a user holding two
      # favorites lists. Without the set that user would vote twice.
      def rank(scores, voters)
        scores
          .reject { |listable_id, _score| voters[listable_id].size < @config[:min_voters] }
          .sort_by { |listable_id, score| [-score, listable_id] }
          .first(@config[:max_items])
          .map do |listable_id, score|
            Entry.new(listable_id: listable_id, score: score, voter_count: voters[listable_id].size)
          end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/user_favorites_tally_test.rb`
Expected: PASS, 13 runs, 0 failures

- [ ] **Step 6: Prove the normalization test is not vacuous**

Change `mass = Math.sqrt(listable_ids.size)` to `mass = listable_ids.size.to_f` (the un-normalized "each favorite is one vote" model) and re-run. Expected: **"one large ballot cannot outvote several small ones" and "ballot mass grows as the square root of list size" both go red.** Restore the line.

If that test still passes with linear mass, the fixture sizes are not discriminating and the test is worthless — fix the test, not the implementation.

- [ ] **Step 7: Sanity-check against real development data**

```bash
bin/rails runner 'r = Services::Lists::UserFavoritesTally.call(user_list_class: Books::UserList); puts "ballots=#{r.ballot_count} entries=#{r.entries.size}"; r.entries.first(10).each_with_index { |e, i| puts "#{i + 1}. #{Books::Book.find(e.listable_id).title} (#{e.voter_count} voters)" }'
```

Expected: `ballots=3370 entries=250`, and a top 10 of *Nineteen Eighty Four*, *The Lord Of The Rings*, *Crime and Punishment*, *One Hundred Years of Solitude*, *The Great Gatsby*, *The Brothers Karamazov*, *The Catcher in the Rye*, *To Kill a Mockingbird*, *Pride and Prejudice*, *Animal Farm*. This is read-only.

A different top 10 means the scoring diverged from the spec — stop and reconcile before continuing.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix config/initializers/user_favorites_list.rb app/lib/services/lists/user_favorites_tally.rb test/lib/services/lists/user_favorites_tally_test.rb
git add config/initializers/user_favorites_list.rb app/lib/services/lists/user_favorites_tally.rb test/lib/services/lists/user_favorites_tally_test.rb
git commit -m "Add UserFavoritesTally scoring service"
```

---

### Task 4: Domain wiring on the UserList subclasses

Declares which `List` each domain's favorites feed, and what that list is called. Follows the existing `listable_class` / `ranking_configuration_class` pattern on the same classes.

**Files:**
- Modify: `app/models/user_list.rb`
- Modify: `app/models/books/user_list.rb`
- Modify: `app/models/music/albums/user_list.rb`
- Modify: `app/models/music/songs/user_list.rb`
- Modify: `app/models/games/user_list.rb`
- Create: `test/models/user_list_generated_list_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: on each participating subclass — `generated_list_class` → `Class`, `generated_list_name` → `String`, `generated_list_description` → `String`. On the base class — `UserList.generating_subclasses` → `Array<Class>`, and base implementations of the three methods that raise `NotImplementedError`.

- [ ] **Step 1: Write the failing test**

Create `test/models/user_list_generated_list_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class UserListGeneratedListTest < ActiveSupport::TestCase
  test "generating_subclasses covers books, albums, songs and games" do
    assert_equal(
      ["Books::UserList", "Games::UserList", "Music::Albums::UserList", "Music::Songs::UserList"],
      UserList.generating_subclasses.map(&:name).sort
    )
  end

  test "every generating subclass declares a list class, name and description" do
    UserList.generating_subclasses.each do |klass|
      assert_operator klass.generated_list_class, :<, ::List,
        "#{klass.name}.generated_list_class must be a List subclass"
      assert_predicate klass.generated_list_name, :present?
      assert_predicate klass.generated_list_description, :present?
    end
  end

  test "the generated list class matches the domain's listable" do
    assert_equal ::Books::List, ::Books::UserList.generated_list_class
    assert_equal ::Music::Albums::List, ::Music::Albums::UserList.generated_list_class
    assert_equal ::Music::Songs::List, ::Music::Songs::UserList.generated_list_class
    assert_equal ::Games::List, ::Games::UserList.generated_list_class
  end

  test "the base class refuses to answer for a subclass that has not declared one" do
    assert_raises(NotImplementedError) { UserList.generated_list_class }
    assert_raises(NotImplementedError) { UserList.generated_list_name }
    assert_raises(NotImplementedError) { UserList.generated_list_description }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/user_list_generated_list_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'generating_subclasses'`

- [ ] **Step 3: Add the base class declarations**

In `app/models/user_list.rb`, add below `DOMAIN_SUBCLASSES`:

```ruby
  # Subclasses whose favorites feed a generated List. Music has two, because it
  # has two listables. Any subclass not listed here has no generated list and
  # answers NotImplementedError to the three declarations below.
  GENERATING_SUBCLASSES = %w[
    Books::UserList
    Music::Albums::UserList
    Music::Songs::UserList
    Games::UserList
  ].freeze
```

Add to the class methods section, next to `default_subclasses`:

```ruby
  def self.generating_subclasses
    GENERATING_SUBCLASSES.map(&:constantize)
  end

  # The List subclass this domain's favorites are aggregated into.
  def self.generated_list_class
    raise NotImplementedError, "#{name} must override .generated_list_class"
  end

  def self.generated_list_name
    raise NotImplementedError, "#{name} must override .generated_list_name"
  end

  def self.generated_list_description
    raise NotImplementedError, "#{name} must override .generated_list_description"
  end
```

- [ ] **Step 4: Declare them on Books::UserList**

In `app/models/books/user_list.rb`, add after `self.listable_display_includes`:

```ruby
    def self.generated_list_class
      ::Books::List
    end

    def self.generated_list_name
      "Our Users' Favorite Books of All Time"
    end

    def self.generated_list_description
      "The greatest books as determined by the users of this web site. " \
        "If you would like to contribute, add your favorite books to your " \
        "\"My Favorite Books\" list."
    end
```

- [ ] **Step 5: Declare them on Music::Albums::UserList**

In `app/models/music/albums/user_list.rb`, add after `self.listable_display_includes`:

```ruby
      def self.generated_list_class
        ::Music::Albums::List
      end

      def self.generated_list_name
        "Our Users' Favorite Albums of All Time"
      end

      def self.generated_list_description
        "The greatest albums as determined by the users of this web site. " \
          "If you would like to contribute, add your favorite albums to your " \
          "\"Favorite Albums\" list."
      end
```

- [ ] **Step 6: Declare them on Music::Songs::UserList**

In `app/models/music/songs/user_list.rb`, add in the same position:

```ruby
      def self.generated_list_class
        ::Music::Songs::List
      end

      def self.generated_list_name
        "Our Users' Favorite Songs of All Time"
      end

      def self.generated_list_description
        "The greatest songs as determined by the users of this web site. " \
          "If you would like to contribute, add your favorite songs to your " \
          "\"Favorite Songs\" list."
      end
```

- [ ] **Step 7: Declare them on Games::UserList**

In `app/models/games/user_list.rb`, add in the same position:

```ruby
    def self.generated_list_class
      ::Games::List
    end

    def self.generated_list_name
      "Our Users' Favorite Games of All Time"
    end

    def self.generated_list_description
      "The greatest games as determined by the users of this web site. " \
        "If you would like to contribute, add your favorite games to your " \
        "\"Favorite Games\" list."
    end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bin/rails test test/models/user_list_generated_list_test.rb`
Expected: PASS, 4 runs, 0 failures

- [ ] **Step 9: Verify Zeitwerk can still eager-load**

Run: `CI=1 bin/rails zeitwerk:check`
Expected: "All is good!"

`eager_load` is off in the test environment, so a green suite does not prove the app boots.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/models/user_list.rb app/models/books/user_list.rb app/models/music/albums/user_list.rb app/models/music/songs/user_list.rb app/models/games/user_list.rb test/models/user_list_generated_list_test.rb
git add app/models test/models/user_list_generated_list_test.rb
git commit -m "Declare the generated list each domain's favorites feed"
```

---

### Task 5: The generator — persist the tally into a List

**Files:**
- Create: `app/lib/services/lists/generate_user_favorites.rb`
- Create: `test/lib/services/lists/generate_user_favorites_test.rb`

**Interfaces:**
- Consumes: `UserFavoritesTally.call` → `Tally` (Task 3); `generated_list_class` / `generated_list_name` / `generated_list_description` (Task 4); `auto_generated_kind` enum (Task 2).
- Produces: `Services::Lists::GenerateUserFavorites.call(user_list_class:, **options)` → `Result` = `Struct.new(:success?, :data, :errors, keyword_init: true)`. On success `data` is `{list: List, item_count: Integer, ballot_count: Integer}`.

- [ ] **Step 1: Write the failing tests**

Create `test/lib/services/lists/generate_user_favorites_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class GenerateUserFavoritesTest < ActiveSupport::TestCase
      setup do
        ::UserListItem.where(user_list_id: ::Books::UserList.select(:id)).delete_all
        @next_user = 0
      end

      # User has after_create :create_default_user_lists, so the favorites list
      # already exists -- find it rather than creating a second one, which
      # one_default_per_type_per_user would reject.
      def build_ballot(books)
        @next_user += 1
        user = ::User.create!(email: "voter#{@next_user}@example.com")
        list = ::Books::UserList.find_by!(user: user, list_type: :favorites)
        books.each_with_index do |book, index|
          ::UserListItem.create!(user_list: list, listable: book, position: index + 1)
        end
        list
      end

      def generate(**options)
        GenerateUserFavorites.call(user_list_class: ::Books::UserList, min_voters: 1, **options)
      end

      test "creates the list unapproved on first run" do
        build_ballot([books_books(:war_and_peace)])

        result = generate

        assert result.success?, result.errors.inspect
        list = result.data[:list]
        assert_equal "Our Users' Favorite Books of All Time", list.name
        assert_equal "unapproved", list.status
        assert list.generated_user_favorites?
        assert_instance_of ::Books::List, list
      end

      test "writes items in tally order with sequential positions" do
        loved = books_books(:war_and_peace)
        liked = books_books(:got)
        3.times { build_ballot([loved]) }
        build_ballot([liked])

        list = generate.data[:list]
        items = list.list_items.order(:position)

        assert_equal [loved.id, liked.id], items.map(&:listable_id)
        assert_equal [1, 2], items.map(&:position)
        assert_equal ["Books::Book", "Books::Book"], items.map(&:listable_type)
        assert items.all?(&:verified?)
      end

      test "records the real ballot count as number_of_voters" do
        2.times { build_ballot([books_books(:war_and_peace)]) }

        assert_equal 2, generate.data[:list].number_of_voters
      end

      test "replaces items on a second run rather than accumulating" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        build_ballot([books_books(:got)])
        build_ballot([books_books(:got)])
        generate

        items = list.reload.list_items.order(:position)
        assert_equal 2, items.count
        assert_equal [books_books(:got).id, books_books(:war_and_peace).id], items.map(&:listable_id)
      end

      test "reuses the same list across runs" do
        build_ballot([books_books(:war_and_peace)])

        first = generate.data[:list]
        second = generate.data[:list]

        assert_equal first.id, second.id
        assert_equal 1, ::Books::List.where(auto_generated_kind: :user_favorites).count
      end

      test "does not change the status of an existing active list" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.update!(status: :active)

        generate

        assert_equal "active", list.reload.status
      end

      test "empties the list when every ballot disappears" do
        ballot = build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        ballot.user_list_items.delete_all
        result = generate

        assert result.success?, result.errors.inspect
        assert_equal 0, list.reload.list_items.count
        assert_equal 0, result.data[:ballot_count]
      end

      test "returns a failure Result rather than raising" do
        UserFavoritesTally.stubs(:call).raises(ActiveRecord::StatementInvalid, "boom")

        result = generate

        refute result.success?
        assert_includes result.errors.first, "boom"
      end

      test "leaves the list untouched when the write fails partway" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]

        ::ListItem.stubs(:insert_all).raises(ActiveRecord::StatementInvalid, "boom")
        result = generate

        refute result.success?
        assert_equal 1, list.reload.list_items.count
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/lists/generate_user_favorites_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Lists::GenerateUserFavorites`

- [ ] **Step 3: Write the generator**

Create `app/lib/services/lists/generate_user_favorites.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Lists
    # Persists a domain's UserFavoritesTally into its generated List.
    #
    # The list is found by (type, auto_generated_kind), never by name -- the
    # legacy implementation looked its lists up by name and could not survive a
    # rename.
    #
    # Items are written with delete_all / insert_all, which skip the ListItem
    # callbacks and validations. That is deliberate on both counts: the guard
    # added in ListItem exists to stop humans editing generated rows, and it
    # needs no escape hatch for this class.
    class GenerateUserFavorites
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(user_list_class:, **options)
        new(user_list_class: user_list_class, **options).call
      end

      def initialize(user_list_class:, **options)
        @user_list_class = user_list_class
        @options = options
      end

      def call
        tally = UserFavoritesTally.call(user_list_class: @user_list_class, **@options)
        list = find_or_create_list

        ::List.transaction do
          list.list_items.delete_all
          ::ListItem.insert_all(item_rows(list, tally.entries)) if tally.entries.any?
          list.update!(number_of_voters: tally.ballot_count)
        end

        Result.new(
          success?: true,
          data: {list: list, item_count: tally.entries.size, ballot_count: tally.ballot_count},
          errors: []
        )
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def find_or_create_list
        klass = @user_list_class.generated_list_class

        # STI scopes this to the domain's own List subclass via the type column,
        # so the partial unique index on (type, auto_generated_kind) is what makes
        # "one generated list per domain" true.
        klass.find_or_create_by!(auto_generated_kind: :user_favorites) do |list|
          list.name = @user_list_class.generated_list_name
          list.description = @user_list_class.generated_list_description
          list.source = "The Greatest Users"
          # New domains start switched off: visible in admin, contributing nothing
          # to rankings until someone activates them deliberately.
          list.status = :unapproved
        end
      end

      def item_rows(list, entries)
        now = Time.current
        listable_type = @user_list_class.listable_class.name

        entries.each_with_index.map do |entry, index|
          {
            list_id: list.id,
            listable_id: entry.listable_id,
            listable_type: listable_type,
            position: index + 1,
            verified: true,
            metadata: {voter_count: entry.voter_count, score: entry.score.round(6)},
            created_at: now,
            updated_at: now
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/lists/generate_user_favorites_test.rb`
Expected: PASS, 9 runs, 0 failures

- [ ] **Step 5: Prove the replacement test is not vacuous**

Delete the `list.list_items.delete_all` line, re-run, and confirm "replaces items on a second run rather than accumulating" goes **red** (it should fail on a duplicate-key violation or a count of 3). Restore the line.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/lists/generate_user_favorites.rb test/lib/services/lists/generate_user_favorites_test.rb
git add app/lib/services/lists/generate_user_favorites.rb test/lib/services/lists/generate_user_favorites_test.rb
git commit -m "Add GenerateUserFavorites to persist the tally into a List"
```

---

### Task 6: Nightly job, schedule entry and rake task

**Files:**
- Create: `app/sidekiq/generate_user_favorites_lists_job.rb` (via generator)
- Create: `test/sidekiq/generate_user_favorites_lists_job_test.rb` (via generator)
- Modify: `config/schedule.yml`
- Create: `lib/tasks/lists/user_favorites.rake`

**Interfaces:**
- Consumes: `UserList.generating_subclasses` (Task 4); `GenerateUserFavorites.call` (Task 5).
- Produces: `GenerateUserFavoritesListsJob.new.perform(user_list_class_name = nil)`. With no argument it runs every generating subclass; with a class name it runs only that one.

- [ ] **Step 1: Generate the job**

```bash
bin/rails generate sidekiq:job generate_user_favorites_lists
```

- [ ] **Step 2: Write the failing test**

Replace the contents of `test/sidekiq/generate_user_favorites_lists_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class GenerateUserFavoritesListsJobTest < ActiveSupport::TestCase
  test "runs every generating subclass exactly once" do
    UserList.generating_subclasses.each do |klass|
      Services::Lists::GenerateUserFavorites
        .expects(:call)
        .with(user_list_class: klass)
        .once
        .returns(success_result)
    end

    GenerateUserFavoritesListsJob.new.perform
  end

  test "runs only the named subclass when given one" do
    Services::Lists::GenerateUserFavorites
      .expects(:call)
      .with(user_list_class: ::Books::UserList)
      .returns(success_result)

    GenerateUserFavoritesListsJob.new.perform("Books::UserList")
  end

  test "one domain failing does not stop the others" do
    # Books is first in GENERATING_SUBCLASSES, so if the job aborted on the first
    # failure the .once expectations below would go unmet -- which is exactly
    # what makes this test discriminating.
    Services::Lists::GenerateUserFavorites
      .expects(:call)
      .with(user_list_class: ::Books::UserList)
      .once
      .returns(failure_result)
    (UserList.generating_subclasses - [::Books::UserList]).each do |klass|
      Services::Lists::GenerateUserFavorites
        .expects(:call)
        .with(user_list_class: klass)
        .once
        .returns(success_result)
    end

    # It still raises, so Sidekiq records the failure -- but only after every
    # other domain has been regenerated.
    assert_raises(RuntimeError) { GenerateUserFavoritesListsJob.new.perform }
  end

  test "raises when a domain fails so Sidekiq records the failure" do
    Services::Lists::GenerateUserFavorites.stubs(:call).returns(failure_result)

    error = assert_raises(RuntimeError) { GenerateUserFavoritesListsJob.new.perform }
    assert_includes error.message, "boom"
  end

  test "rejects a class that is not a generating subclass" do
    Services::Lists::GenerateUserFavorites.expects(:call).never

    assert_raises(ArgumentError) do
      GenerateUserFavoritesListsJob.new.perform("Nope::UserList")
    end
  end

  private

  def success_result
    Services::Lists::GenerateUserFavorites::Result.new(
      success?: true, data: {list: nil, item_count: 0, ballot_count: 0}, errors: []
    )
  end

  def failure_result
    Services::Lists::GenerateUserFavorites::Result.new(
      success?: false, data: nil, errors: ["boom"]
    )
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/sidekiq/generate_user_favorites_lists_job_test.rb`
Expected: FAIL — the generated job's `perform` does nothing.

- [ ] **Step 4: Write the job**

Replace the contents of `app/sidekiq/generate_user_favorites_lists_job.rb`:

```ruby
# frozen_string_literal: true

# Rebuilds every domain's generated "Our Users' Favorite ..." list from user
# favorites. Scheduled nightly in config/schedule.yml.
#
# Deliberately does NOT recalculate rankings. Ranking recalculation is a heavy
# cascade (600+ lists, then author rankings, then a search reindex) onto a queue
# that is already a throughput bottleneck, and it stays on the deliberate admin
# refresh so a night of favoriting can never silently reshuffle the site.
#
# The legacy implementation ran from UserListBook after_create/after_destroy/
# after_update, so a single user working through their favorites queued hundreds
# of full recomputations.
class GenerateUserFavoritesListsJob
  include Sidekiq::Job

  def perform(user_list_class_name = nil)
    failures = []

    subclasses_for(user_list_class_name).each do |klass|
      result = Services::Lists::GenerateUserFavorites.call(user_list_class: klass)

      if result.success?
        Rails.logger.info {
          "Generated #{klass.name} favorites list: #{result.data[:item_count]} items " \
            "from #{result.data[:ballot_count]} ballots"
        }
      else
        # Collected rather than raised, so one domain's failure still leaves the
        # other three regenerated.
        failures << "#{klass.name}: #{result.errors.join(", ")}"
        Rails.logger.error { "Failed to generate #{klass.name} favorites list: #{result.errors.join(", ")}" }
      end
    end

    raise "User favorites list generation failed -- #{failures.join("; ")}" if failures.any?
  end

  private

  def subclasses_for(name)
    return ::UserList.generating_subclasses if name.blank?

    klass = ::UserList.generating_subclasses.find { |candidate| candidate.name == name }
    raise ArgumentError, "#{name} is not a generating UserList subclass" if klass.nil?

    [klass]
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/sidekiq/generate_user_favorites_lists_job_test.rb`
Expected: PASS, 5 runs, 0 failures

- [ ] **Step 6: Add the schedule entry**

Append to `config/schedule.yml`:

```yaml

user_favorites_lists:
  class: GenerateUserFavoritesListsJob
  cron: "0 3 * * *"
  description: "Rebuild each domain's generated users' favorites list"
```

Note the leading blank line — the existing file's last entry has no trailing newline, so check the result with `tail -8 config/schedule.yml` and fix the spacing if the new key ran onto the previous line.

- [ ] **Step 7: Verify the schedule file still parses**

Run: `bin/rails runner 'pp YAML.load_file(Rails.root.join("config/schedule.yml")).keys'`
Expected: `["search_indexing", "books_author_rankings", "billing_reconcile_all", "user_favorites_lists"]`

- [ ] **Step 8: Add the rake tasks**

Create `lib/tasks/lists/user_favorites.rake`:

```ruby
# frozen_string_literal: true

namespace :user_favorites_lists do
  desc "Rebuild the generated users' favorites list for every domain, or one (e.g. Books::UserList)"
  task :generate, [:user_list_class] => :environment do |_task, args|
    GenerateUserFavoritesListsJob.new.perform(args[:user_list_class])
    puts "Done."
  end

  desc "Backfill user_lists.manually_ordered from item insertion order (one-time, safe to re-run)"
  task backfill_manually_ordered: :environment do
    count = Services::UserLists::BackfillManuallyOrdered.call
    puts "Flagged #{count} user list(s) as manually ordered."
  end
end
```

- [ ] **Step 9: Verify the tasks are registered**

Run: `bin/rails -T user_favorites_lists`
Expected: both tasks listed with their descriptions.

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb --fix app/sidekiq/generate_user_favorites_lists_job.rb test/sidekiq/generate_user_favorites_lists_job_test.rb lib/tasks/lists/user_favorites.rake
git add app/sidekiq/generate_user_favorites_lists_job.rb test/sidekiq/generate_user_favorites_lists_job_test.rb config/schedule.yml lib/tasks/lists/user_favorites.rake
git commit -m "Add nightly job, schedule entry and rake tasks for users' favorites lists"
```

---

### Task 7: Retire the legacy books lists and run the backfill

One-time cleanup. Books lists exist in development only, so this is a rake task rather than a migration — a migration would be a no-op in production and dead weight in every test setup.

**Files:**
- Modify: `lib/tasks/lists/user_favorites.rake`

**Interfaces:**
- Consumes: `auto_generated_kind` enum (Task 2); `Books::UserList.generated_list_name` (Task 4).
- Produces: `user_favorites_lists:adopt_legacy_books_list` rake task.

- [ ] **Step 1: Add the cleanup task**

Append to `lib/tasks/lists/user_favorites.rake`, inside the `user_favorites_lists` namespace:

```ruby
  # The legacy site kept three lists built from user favorites: a top 100, a
  # 6,933-item "honorable mention" holding everything from 101 down, and an older
  # stale artifact. The honorable mention is retired outright -- at weight 0 it
  # contributed nothing, and all 2,854 books it uniquely carried score at the
  # engine's floor of 1.00.
  #
  # The top 100 is kept and adopted: it already owns its public URL, its
  # RankedList row, its weight and its penalties. Renaming it in place preserves
  # all of that.
  #
  # Books data lives in development only, so this finds lists by name and no-ops
  # when they are absent -- safe to run anywhere, safe to re-run.
  desc "Adopt the legacy books users' list and delete the retired ones (one-time, safe to re-run)"
  task adopt_legacy_books_list: :environment do
    keep = ::Books::List.find_by(name: "Our Users' Top 100 Favorite Books of All Time")

    if keep
      keep.update!(
        name: ::Books::UserList.generated_list_name,
        description: ::Books::UserList.generated_list_description,
        auto_generated_kind: :user_favorites
      )
      puts "Adopted list #{keep.id} as the generated books users' list."
    else
      puts "No legacy top-100 list found; nothing to adopt."
    end

    [
      "Our Users' Honorable Mention Favorite Books of All Time",
      "Our Users' Favorite Books of All Time"
    ].each do |name|
      # Skip the list we just renamed into this slot.
      doomed = ::Books::List.where(name: name).where.not(id: keep&.id).to_a
      doomed.each do |list|
        items = list.list_items.count
        # RankedList is destroyed by the association added in Task 2; counted here
        # so the output says what actually went.
        ranked = list.ranked_lists.count
        list.destroy!
        puts "Deleted list #{list.id} \"#{name}\" (#{items} items, #{ranked} ranked_list row(s))."
      end
      puts "No list named \"#{name}\"; nothing to delete." if doomed.empty?
    end
  end
```

- [ ] **Step 2: Verify the task is registered**

Run: `bin/rails -T user_favorites_lists`
Expected: three tasks listed.

- [ ] **Step 3: Snapshot the development database**

```bash
bin/snapshot-dev-db.sh --label pre-ranked-users-lists
```

The next steps write to development. The books data exists only there and takes hours to rebuild from the legacy database; a snapshot turns that into a ~1 minute restore.

- [ ] **Step 4: Record the before state**

```bash
bin/rails runner 'List.where("name ILIKE ?", "%Our Users%").each { |l| puts [l.id, l.name, l.status, l.list_items.count, l.number_of_voters].inspect }; puts "ranked books: #{RankedItem.where(ranking_configuration_id: 8).count}"'
```

Expected: lists 268, 463 and 464 as described in the spec, and 24,242 ranked books. Keep this output.

- [ ] **Step 5: Run the backfill**

```bash
bin/rails user_favorites_lists:backfill_manually_ordered
```

Expected: `Flagged 257 user list(s) as manually ordered.`

A materially different number means the detection query diverged from the spec's measurement — stop and reconcile.

- [ ] **Step 6: Run the adoption**

```bash
bin/rails user_favorites_lists:adopt_legacy_books_list
```

Expected: adoption of 463, deletion of 464 (6,933 items, 1 ranked_list row) and 268 (1,774 items, 0 ranked_list rows).

- [ ] **Step 7: Regenerate the books list**

```bash
bin/rails user_favorites_lists:generate[Books::UserList]
```

- [ ] **Step 8: Verify the result against the spec**

```bash
bin/rails runner 'l = Books::List.find_by(auto_generated_kind: :user_favorites); puts "#{l.id} #{l.name} status=#{l.status} items=#{l.list_items.count} voters=#{l.number_of_voters}"; l.list_items.order(:position).limit(10).each { |i| puts "#{i.position}. #{i.listable.title} (#{i.metadata["voter_count"]} voters)" }; puts "orphan ranked_lists: #{ActiveRecord::Base.connection.select_value("SELECT count(*) FROM ranked_lists rl LEFT JOIN lists l ON l.id = rl.list_id WHERE l.id IS NULL")}"'
```

Expected: list 463, name "Our Users' Favorite Books of All Time", `status=active` (its pre-existing status is preserved), 250 items, 3,370 voters, a top 10 matching the spec's table, and **0 orphan ranked_lists**.

- [ ] **Step 9: Run the full suite and the linter**

```bash
bin/rails test
bundle exec standardrb
```

Expected: all green, and no new warning lines. A clean run emits no warnings beyond `weighted_list_rank`'s position `puts` and npm/yarn during `test:prepare`.

- [ ] **Step 10: Commit**

```bash
bundle exec standardrb --fix lib/tasks/lists/user_favorites.rake
git add lib/tasks/lists/user_favorites.rake
git commit -m "Add one-time task to adopt the legacy books users' list and retire the rest"
```

---

## Post-implementation notes

**Not done here, deliberately:**

- **The admin regenerate button.** See the deviation note in Global Constraints. `bin/rails user_favorites_lists:generate` covers it.
- **The `ranked_lists.list_id` foreign key.** `List#ranked_lists` with `dependent: :destroy` fixes the orphan bug at the application level. Adding the database constraint is only safe if production also has zero orphans (development has zero across 833 rows); check before proposing it.
- **Activating music, songs and games.** Their lists are created `unapproved` on the first nightly run. Activating them is a deliberate decision once the data justifies it — 1 games ballot and 3 album ballots today.
- **Recalculating books rankings.** The generated list changing does not move any book until `Actions::Admin::RefreshRankings` runs for the books configuration. Expect the ranked book count to drop by roughly 2,854 when it does, all of them previously tied at the floor score of 1.00.
- **Reorder UI.** Phase B of user-lists. When it lands it sets `user_list.manually_ordered = true`; nothing in this feature needs to change.

**Expect on the first real ranking refresh:** the generated list is ~91.6% western against a 90.0% penalty threshold, so it will take the 10-point western-canon penalty. It sits 1.6 points over the line, so its weight may flip by 10 between weight recalculations.
