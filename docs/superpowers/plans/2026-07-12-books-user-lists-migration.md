# Books User Lists Migration (Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `Books::UserList` STI subclass, then migrate the legacy books site's 282,922 `user_lists` and 3,096,597 `user_list_books` into the new app's `user_lists` / `user_list_items` tables.

**Architecture:** Two `BulkUpsertMigrator` subclasses. `UserListMigrator` preserves legacy ids (upserts on `:id`) — safe because `user_lists` is a reserved-ceiling table. `UserListItemMigrator` takes fresh ids and upserts on the natural-key unique index, then normalizes positions to a contiguous 1..N in a single `finalize` SQL statement. No schema changes.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + Mocha + fixtures, `standardrb`.

**Design doc:** `docs/superpowers/specs/2026-07-12-books-user-lists-migration-design.md` — read it first. It carries the introspection numbers and the six named decisions (`D-enum-convention`, `D-normalize-positions`, `D-drop-dead-columns`, `D-verbatim-defaults`, `D-data-only`, `D-no-schema`).

## Global Constraints

- **Run every command from `web-app/`.** Docs live at the project root in `docs/`, NOT `web-app/docs/`.
- **Lint with `bundle exec standardrb`** (NOT `bin/rubocop` — omakase, conflicting style). `--fix` autocorrects.
- **No code comments** unless they state a constraint the code cannot show. Existing migrators carry a class-level comment explaining *why*; match that and nothing more.
- **No schema migration.** Both target tables, both enums, `completed_on`, and the natural-key unique index already exist. If you find yourself writing `db/migrate/`, stop — you've misread the plan.
- **No test legacy database is required or created.** Every migrator test stubs `legacy_each`; the `LegacyBooks::*` connection is never opened in test (`LegacyBooks::Record` skips `connects_to` in the test env).
- **Never test private methods.** Assert on the rows that land in the database, not on `build_rows`.
- **Fail loud, never silently skip.** An unmapped enum value or an unmigrated book raises, naming the legacy id.
- **`Books::UserList` must stay OUT of `UserList::DEFAULT_SUBCLASSES` and `UserList::DOMAIN_SUBCLASSES`** (`D-data-only`). Adding it would create books lists for every new signup and half-wire `/my_lists` on a domain with no public routes.

---

### Task 1: `Books::UserList` STI subclass

The one piece of new product code. Everything downstream depends on this class existing, because `UserListMigrator` writes `type = "Books::UserList"` and `UserListItemMigrator`'s `finalize` filters on it.

**Files:**
- Create: `web-app/app/models/books/user_list.rb`
- Create: `web-app/test/models/books/user_list_test.rb`
- Modify: `docs/features/user-lists.md` (class-hierarchy diagram + "What's Not Yet Implemented")

**Interfaces:**
- Produces: `Books::UserList < ::UserList` with `enum :list_type, {favorites: 0, read: 1, reading: 2, want_to_read: 3, custom: 4}`. Tasks 2 and 3 depend on the string `"Books::UserList"` and on those five integer values.

- [ ] **Step 1: Generate the model and its test with the Rails generator**

The project requires generators (they create the matching test file). `--parent` makes it an STI subclass; `--no-migration` is essential — this table already exists.

```bash
bin/rails generate model Books::UserList --parent UserList --no-migration
```

Expected: creates `app/models/books/user_list.rb` and `test/models/books/user_list_test.rb`. It must NOT create anything under `db/migrate/`. If it does, delete the migration file.

- [ ] **Step 2: Write the failing test**

Replace the whole of `web-app/test/models/books/user_list_test.rb`. (The schema-annotation header block is added automatically in Step 6 — don't hand-write it.)

```ruby
require "test_helper"

module Books
  class UserListTest < ActiveSupport::TestCase
    test "default_list_types" do
      assert_equal [:favorites, :read, :reading, :want_to_read], Books::UserList.default_list_types
    end

    test "listable_class" do
      assert_equal Books::Book, Books::UserList.listable_class
    end

    test "list_type enum uses the new-app convention, not the legacy integers" do
      assert_equal({"favorites" => 0, "read" => 1, "reading" => 2, "want_to_read" => 3, "custom" => 4},
        Books::UserList.list_types.to_h)
    end

    test "default_list_name_for returns the legacy display name for each default type" do
      assert_equal "My Favorite Books", Books::UserList.default_list_name_for(:favorites)
      assert_equal "Books I've Read", Books::UserList.default_list_name_for(:read)
      assert_equal "Books I'm Reading", Books::UserList.default_list_name_for(:reading)
      assert_equal "Books I Want to Read", Books::UserList.default_list_name_for(:want_to_read)
    end

    test "default_list_name_for raises on unknown list_type" do
      assert_raises(KeyError) { Books::UserList.default_list_name_for(:bogus) }
    end

    test "completed_on is enabled only for the read list" do
      assert_equal [:read], Books::UserList.completed_on_list_types

      user = users(:regular_user)
      read_list = Books::UserList.create!(user: user, name: "Books I've Read", list_type: :read)
      reading_list = Books::UserList.create!(user: user, name: "Books I'm Reading", list_type: :reading)

      assert read_list.completed_on_enabled?
      assert_not reading_list.completed_on_enabled?
    end

    test "ranking_configuration_class" do
      assert_equal Books::RankingConfiguration, Books::UserList.ranking_configuration_class
    end

    test "list_type_icons covers every non-custom type and excludes custom" do
      assert_equal [:favorites, :read, :reading, :want_to_read], Books::UserList.list_type_icons.keys
      assert_not_includes Books::UserList.list_type_icons.keys, :custom
    end

    test "only accepts Books::Book as a listable" do
      user = users(:regular_user)
      list = Books::UserList.create!(user: user, name: "My Favorite Books", list_type: :favorites)
      item = UserListItem.new(user_list: list, listable: music_albums(:dark_side_of_the_moon))

      assert_not item.valid?
      assert_includes item.errors[:listable_type], "Music::Album is not compatible with Books::UserList"
    end

    test "is deliberately excluded from DEFAULT_SUBCLASSES and DOMAIN_SUBCLASSES" do
      assert_not_includes UserList::DEFAULT_SUBCLASSES, "Books::UserList"
      assert_equal [], UserList.subclasses_for(:books)
    end
  end
end
```

The last test is load-bearing, not ceremony: it pins `D-data-only`. Adding `Books::UserList` to either constant would silently create four books lists for every new signup and route `/my_lists` to a domain with no public book pages.

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/models/books/user_list_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'default_list_types'` (the generated subclass is empty; the base class raises `NotImplementedError` for the abstract class methods).

- [ ] **Step 4: Write the implementation**

Replace the whole of `web-app/app/models/books/user_list.rb`. Note `< ::UserList` — inside `module Books`, a bare `UserList` would resolve to `Books::UserList` itself.

```ruby
module Books
  class UserList < ::UserList
    has_many :items, through: :user_list_items, source: :listable, source_type: "Books::Book"

    enum :list_type, {favorites: 0, read: 1, reading: 2, want_to_read: 3, custom: 4}

    def self.default_list_types
      [:favorites, :read, :reading, :want_to_read]
    end

    def self.listable_class
      Books::Book
    end

    def self.default_list_name_for(list_type)
      {
        favorites: "My Favorite Books",
        read: "Books I've Read",
        reading: "Books I'm Reading",
        want_to_read: "Books I Want to Read"
      }.fetch(list_type.to_sym)
    end

    def self.list_type_icons
      {favorites: "heart", read: "check", reading: "book-open", want_to_read: "bookmark"}
    end

    def self.completed_on_list_types
      [:read]
    end

    def self.ranking_configuration_class
      Books::RankingConfiguration
    end

    def self.listable_display_includes
      [:authors, :categories, :primary_image]
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/models/books/user_list_test.rb
```

Expected: PASS, 10 runs, 0 failures, 0 errors.

- [ ] **Step 6: Annotate the model and lint**

```bash
bundle exec annotaterb models
bundle exec standardrb app/models/books/user_list.rb test/models/books/user_list_test.rb
```

Expected: `annotaterb` prepends the `user_lists` schema comment block to both files (matching every sibling model); `standardrb` reports no offenses.

- [ ] **Step 7: Update the feature doc**

In `docs/features/user-lists.md`, add Books to the STI hierarchy diagram (~line 12). Replace:

```
└── Movies::UserList                     list_type: favorites, watched, want_to_watch, custom
```

with:

```
├── Movies::UserList                     list_type: favorites, watched, want_to_watch, custom
└── Books::UserList                      list_type: favorites, read, reading, want_to_read, custom
```

Then, in the "What's Not Yet Implemented" section, replace this stale bullet:

```
- `Books::UserList` and a books layout — books item model doesn't exist yet; the read surface works automatically once `Books::UserList` lands.
```

with:

```
- A books layout and books UI wiring. `Books::UserList` exists (Phase 3 of the books data migration) but is deliberately **data-only**: it is absent from both `DEFAULT_SUBCLASSES` (so new signups still get **12** default lists, not 16) and `DOMAIN_SUBCLASSES` (so `/my_lists` does not serve the books domain). The books domain has no public routes, no book show page, and no `Search::ListableAutocomplete` config yet. Adding it to those two constants is the follow-up once the books public UI lands.
```

- [ ] **Step 8: Run the full model suite and commit**

```bash
bin/rails test test/models/
```

Expected: PASS, 0 failures, 0 errors. (Confirms the new subclass didn't perturb `create_default_user_lists`, which still iterates only the four `DEFAULT_SUBCLASSES`.)

```bash
git add web-app/app/models/books/user_list.rb web-app/test/models/books/user_list_test.rb docs/features/user-lists.md
git commit -m "Add Books::UserList STI subclass (data-only, not wired into UI)"
```

---

### Task 2: `UserListMigrator` — legacy `user_lists` → `Books::UserList`

**Files:**
- Create: `web-app/app/models/legacy_books/user_list.rb`
- Create: `web-app/app/lib/services/books_migration/user_list_migrator.rb`
- Create: `web-app/test/lib/services/books_migration/user_list_migrator_test.rb`
- Modify: `web-app/test/models/legacy_books/record_test.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `Books::UserList` from Task 1 (the `"Books::UserList"` type string and the five `list_type` integers).
- Produces: `Services::BooksMigration::UserListMigrator.call` → `{success:, data: {model: "Books::UserList", count:}}`. Task 3 depends on `user_lists` rows existing at their **legacy ids** (its `user_list_id` is a straight copy).

- [ ] **Step 1: Add the read-only legacy model**

Create `web-app/app/models/legacy_books/user_list.rb`. This is a `table_name` shim on the read-only legacy replica connection, identical in shape to `LegacyBooks::List`.

```ruby
module LegacyBooks
  class UserList < Record
    self.table_name = "user_lists"
  end
end
```

Add it to the existing assertion in `web-app/test/models/legacy_books/record_test.rb`, inside the `"legacy models point at the legacy tables"` test:

```ruby
      assert_equal "user_lists", LegacyBooks::UserList.table_name
```

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lib/services/books_migration/user_list_migrator_test.rb`. The `legacy_row` helper deliberately carries `greatest_books_list`, `best_ranked`, and `date_read` — every test therefore proves the migrator drops them without raising `UnknownAttributeError`.

```ruby
require "test_helper"

module Services
  module BooksMigration
    class UserListMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
      end

      def run_migrator(rows)
        migrator = UserListMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 300001,
          "user_id" => @user.id,
          "name" => "Books I've Read",
          "description" => "desc",
          "list_type" => 0,
          "view_mode" => nil,
          "public" => nil,
          "position" => nil,
          "greatest_books_list" => true,
          "best_ranked" => true,
          "date_read" => Date.new(2020, 1, 1),
          "created_at" => Time.utc(2015, 1, 2, 3, 4, 5),
          "updated_at" => Time.utc(2016, 2, 3, 4, 5, 6)
        }.merge(overrides)
      end

      test "maps a legacy user_list to Books::UserList, preserving id" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::UserList", result[:data][:model]

        list = ::UserList.find(300001)
        assert_instance_of Books::UserList, list
        assert_equal @user, list.user
        assert_equal "Books I've Read", list.name
        assert_equal "desc", list.description
        assert list.read?
        assert list.default_view?
        assert_not list.public?
        assert_nil list.position
        assert_equal Time.utc(2015, 1, 2, 3, 4, 5), list.created_at
        assert_equal Time.utc(2016, 2, 3, 4, 5, 6), list.updated_at
      end

      test "remaps every legacy list_type to the new-app enum" do
        result = run_migrator([
          legacy_row("id" => 300010, "list_type" => 0),
          legacy_row("id" => 300011, "list_type" => 1),
          legacy_row("id" => 300012, "list_type" => 2),
          legacy_row("id" => 300013, "list_type" => 3),
          legacy_row("id" => 300014, "list_type" => 4)
        ])

        assert result[:success], result[:error]
        assert_equal "read", ::UserList.find(300010).list_type
        assert_equal "reading", ::UserList.find(300011).list_type
        assert_equal "want_to_read", ::UserList.find(300012).list_type
        assert_equal "favorites", ::UserList.find(300013).list_type
        assert_equal "custom", ::UserList.find(300014).list_type
      end

      test "fails loud on an unmapped list_type" do
        result = run_migrator([legacy_row("id" => 300099, "list_type" => 7)])

        refute result[:success]
        assert_match(/300099/, result[:error])
        assert_match(/list_type/, result[:error])
      end

      test "remaps view_mode, treating NULL as the default member" do
        result = run_migrator([
          legacy_row("id" => 300020, "list_type" => 0, "view_mode" => nil),
          legacy_row("id" => 300021, "list_type" => 1, "view_mode" => 1),
          legacy_row("id" => 300022, "list_type" => 2, "view_mode" => 2)
        ])

        assert result[:success], result[:error]
        assert_equal "default_view", ::UserList.find(300020).view_mode
        assert_equal "table_view", ::UserList.find(300021).view_mode
        assert_equal "grid_view", ::UserList.find(300022).view_mode
      end

      test "fails loud on an unmapped view_mode" do
        result = run_migrator([legacy_row("id" => 300098, "view_mode" => 9)])

        refute result[:success]
        assert_match(/300098/, result[:error])
        assert_match(/view_mode/, result[:error])
      end

      test "a null public becomes false and a true public is preserved" do
        result = run_migrator([
          legacy_row("id" => 300030, "list_type" => 0, "public" => nil),
          legacy_row("id" => 300031, "list_type" => 1, "public" => true)
        ])

        assert result[:success], result[:error]
        assert_not ::UserList.find(300030).public?
        assert ::UserList.find(300031).public?
      end

      test "drops greatest_books_list, best_ranked and date_read" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        list = ::UserList.find(300001)
        assert_not list.respond_to?(:greatest_books_list)
        assert_not list.respond_to?(:best_ranked)
        assert_not list.respond_to?(:date_read)
      end

      test "is idempotent on id" do
        run_migrator([legacy_row])

        assert_no_difference -> { ::UserList.count } do
          run_migrator([legacy_row("name" => "Renamed")])
        end
        assert_equal "Renamed", ::UserList.find(300001).name
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/user_list_migrator_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::UserListMigrator`.

- [ ] **Step 4: Write the implementation**

Create `web-app/app/lib/services/books_migration/user_list_migrator.rb`.

```ruby
module Services
  module BooksMigration
    # Legacy `user_lists` -> STI Books::UserList, preserving id. Preservation is safe
    # because `user_lists` is a reserved-ceiling table (RESERVED_CEILINGS = 1_000_000) and
    # the legacy MAX(id) is 604,880 — every new-app row already lives at >= 1_000_001. It is
    # also load-bearing: the /user_lists/:id compatibility alias resolves a list by its raw
    # primary key, so the legacy books URLs only keep working if the ids survive.
    #
    # list_type is symbol-remapped: legacy is [read, reading, want_to_read, favorite, custom]
    # but every new-app subclass puts a plural `favorites` at 0. view_mode's legacy default
    # member is NULL, not 0. `public` is nullable in legacy but NOT NULL here.
    # greatest_books_list / best_ranked / date_read are dropped — dead legacy flags with no
    # new-schema home. Bulk upsert_all bypasses the UserList callbacks and validations.
    # Idempotent on id.
    class UserListMigrator < BulkUpsertMigrator
      LIST_TYPE_MAP = {3 => 0, 0 => 1, 1 => 2, 2 => 3, 4 => 4}.freeze
      VIEW_MODE_MAP = {nil => 0, 1 => 1, 2 => 2}.freeze

      private

      def legacy_model
        LegacyBooks::UserList
      end

      def model_key
        "Books::UserList"
      end

      def target_model
        ::UserList
      end

      def unique_by
        :id
      end

      def record_timestamps?
        false
      end

      def build_rows(attrs)
        [{
          id: attrs["id"],
          type: "Books::UserList",
          user_id: attrs["user_id"],
          name: attrs["name"],
          description: attrs["description"],
          list_type: remap_list_type(attrs["list_type"]),
          view_mode: remap_view_mode(attrs["view_mode"]),
          public: attrs["public"] || false,
          position: attrs["position"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def remap_list_type(old)
        LIST_TYPE_MAP.fetch(old) { raise "unmapped legacy user_lists.list_type=#{old.inspect}" }
      end

      def remap_view_mode(old)
        VIEW_MODE_MAP.fetch(old) { raise "unmapped legacy user_lists.view_mode=#{old.inspect}" }
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/lib/services/books_migration/user_list_migrator_test.rb test/models/legacy_books/record_test.rb
```

Expected: PASS, 10 runs, 0 failures, 0 errors.

- [ ] **Step 6: Add the rake task**

In `web-app/lib/tasks/data_migration.rake`, add this task immediately after the existing `:list_penalties` task (leave the `:all` task alone — Task 3 wires both new tasks into it at once):

```ruby
  desc "Migrate legacy user_lists into Books::UserList (preserve id; list_type + view_mode symbol-remap)"
  task user_lists: :environment do
    pp Services::BooksMigration::UserListMigrator.call
  end
```

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books_migration/user_list_migrator.rb app/models/legacy_books/user_list.rb test/lib/services/books_migration/user_list_migrator_test.rb lib/tasks/data_migration.rake
```

Expected: no offenses.

```bash
git add web-app/app/models/legacy_books/user_list.rb web-app/app/lib/services/books_migration/user_list_migrator.rb web-app/test/lib/services/books_migration/user_list_migrator_test.rb web-app/test/models/legacy_books/record_test.rb web-app/lib/tasks/data_migration.rake
git commit -m "Add UserListMigrator (legacy user_lists -> Books::UserList, id preserved)"
```

---

### Task 3: `UserListItemMigrator` — legacy `user_list_books` → `user_list_items`

The 3.1M-row load. Fresh ids on the natural key, plus the position-normalizing `finalize` pass.

**Files:**
- Create: `web-app/app/models/legacy_books/user_list_book.rb`
- Create: `web-app/app/lib/services/books_migration/user_list_item_migrator.rb`
- Create: `web-app/test/lib/services/books_migration/user_list_item_migrator_test.rb`
- Modify: `web-app/test/models/legacy_books/record_test.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`

**Interfaces:**
- Consumes: `Books::UserList` (Task 1) and `user_lists` rows at their legacy ids (Task 2).
- Produces: `Services::BooksMigration::UserListItemMigrator.call` → `{success:, data: {model: "UserListItem", count:}}`.

- [ ] **Step 1: Add the read-only legacy model**

Create `web-app/app/models/legacy_books/user_list_book.rb`:

```ruby
module LegacyBooks
  class UserListBook < Record
    self.table_name = "user_list_books"
  end
end
```

Add to the same assertion in `web-app/test/models/legacy_books/record_test.rb`:

```ruby
      assert_equal "user_list_books", LegacyBooks::UserListBook.table_name
```

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lib/services/books_migration/user_list_item_migrator_test.rb`.

Two things to understand before reading the position tests. First, `finalize` renumbers, so a lone item that came in at legacy position 3 lands at position **1** — that is the feature, not a bug. Second, the renumber's tie-break is `ORDER BY position, id` where `id` is the **new** `user_list_items` id; rows stream in legacy-id order and `upsert_all` inserts them in that order, so the sequence assigns ascending new ids in legacy-id order. Ties therefore break by legacy id, deterministically, on every run.

`regular_user` already owns a `Music::Albums::UserList` favorites list via fixtures, so the guard test below creates a `:custom` music list — `custom` is exempt from `one_default_per_type_per_user`.

```ruby
require "test_helper"

module Services
  module BooksMigration
    class UserListItemMigratorTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @list = Books::UserList.create!(user: @user, name: "Books I've Read", list_type: :read)
        @book = Books::Book.create!(title: "Item Book")
      end

      def run_migrator(rows)
        migrator = UserListItemMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def legacy_row(overrides = {})
        {
          "id" => 5000001,
          "user_list_id" => @list.id,
          "book_id" => @book.id,
          "position" => 3,
          "read_date" => Date.new(2021, 7, 4),
          "created_at" => Time.utc(2018, 5, 6, 7, 8, 9),
          "updated_at" => Time.utc(2019, 6, 7, 8, 9, 10)
        }.merge(overrides)
      end

      test "maps a legacy user_list_book to a Books::Book listable" do
        result = run_migrator([legacy_row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "UserListItem", result[:data][:model]

        item = UserListItem.find_by(user_list_id: @list.id, listable_type: "Books::Book", listable_id: @book.id)
        assert_not_nil item
        assert_equal @book, item.listable
        assert_equal Date.new(2021, 7, 4), item.completed_on
        assert_equal Time.utc(2018, 5, 6, 7, 8, 9), item.created_at
        assert_equal Time.utc(2019, 6, 7, 8, 9, 10), item.updated_at
        assert_equal 1, item.position
      end

      test "a null read_date becomes a null completed_on" do
        run_migrator([legacy_row("read_date" => nil)])

        item = UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id)
        assert_nil item.completed_on
      end

      test "renumbers positions to a contiguous 1..N, nulls last and ties broken by legacy id" do
        second = Books::Book.create!(title: "Second")
        third = Books::Book.create!(title: "Third")
        fourth = Books::Book.create!(title: "Fourth")

        result = run_migrator([
          legacy_row("id" => 5000001, "book_id" => fourth.id, "position" => nil),
          legacy_row("id" => 5000002, "book_id" => second.id, "position" => 7),
          legacy_row("id" => 5000003, "book_id" => third.id, "position" => 7),
          legacy_row("id" => 5000004, "book_id" => @book.id, "position" => 2)
        ])

        assert result[:success], result[:error]
        assert_equal [[@book.id, 1], [second.id, 2], [third.id, 3], [fourth.id, 4]],
          UserListItem.where(user_list_id: @list.id).order(:position).pluck(:listable_id, :position)
      end

      test "no sentinel position survives the renumber" do
        run_migrator([legacy_row("position" => nil)])

        assert_equal 0, UserListItem.where(position: UserListItemMigrator::NULL_POSITION_SENTINEL).count
      end

      test "the renumber leaves non-Books user_list_items untouched" do
        music_list = Music::Albums::UserList.create!(user: @user, name: "Renumber Guard", list_type: :custom)
        music_item = UserListItem.create!(user_list: music_list,
          listable: music_albums(:dark_side_of_the_moon), position: 5)

        run_migrator([legacy_row])

        assert_equal 5, music_item.reload.position
      end

      test "fails loud when the book is not migrated" do
        missing = Books::Book.maximum(:id).to_i + 999_999
        result = run_migrator([legacy_row("id" => 5000042, "book_id" => missing)])

        refute result[:success]
        assert_match(/5000042/, result[:error])
      end

      test "is idempotent on [user_list, listable]" do
        run_migrator([legacy_row])

        assert_no_difference -> { UserListItem.count } do
          run_migrator([legacy_row("read_date" => Date.new(2022, 1, 1))])
        end

        item = UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id)
        assert_equal Date.new(2022, 1, 1), item.completed_on
        assert_equal 1, item.position
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/user_list_item_migrator_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::UserListItemMigrator`.

- [ ] **Step 4: Write the implementation**

Create `web-app/app/lib/services/books_migration/user_list_item_migrator.rb`.

Two non-obvious details. (1) `upsert_batch` must be overridden as a **method** — the base class's `def upsert_batch; UPSERT_BATCH; end` resolves `UPSERT_BATCH` lexically against `BulkUpsertMigrator`, so redefining the constant alone would silently keep the batch at 1,000. (2) `finalize` must be raw SQL: `BulkUpsertMigrator` runs it *outside* `without_search_indexing`, so anything that fires AR callbacks would leak a `SearchIndexRequest` per row.

```ruby
module Services
  module BooksMigration
    # Legacy `user_list_books` -> polymorphic user_list_items (listable = Books::Book), fresh id.
    # Bulk upsert on the natural-key unique index [user_list_id, listable_type, listable_id];
    # legacy already enforces UNIQUE [user_list_id, book_id], so no intra-batch ON CONFLICT
    # double-touch. listable has no DB FK (polymorphic), so a book_id with no migrated
    # Books::Book is a fail-loud raise naming the legacy user_list_books id.
    #
    # position: nullable in legacy (779 rows) and drifted (gaps, plus 689 duplicate
    # [list, position] pairs), but NOT NULL here and the app assumes a contiguous 1..N. NULLs
    # enter as NULL_POSITION_SENTINEL — int max, so it sorts last and cannot collide (legacy
    # MAX(position) is 12,411) — and finalize renumbers every Books row to 1..N. Ordering by
    # (position, id) is stable across runs, so a re-run (whose upsert resets positions to
    # their legacy values) converges on the identical result.
    #
    # completed_on <- read_date. Legacy created_at/updated_at preserved.
    class UserListItemMigrator < BulkUpsertMigrator
      NULL_POSITION_SENTINEL = 2_147_483_647
      UPSERT_BATCH = 5_000

      private

      def legacy_model
        LegacyBooks::UserListBook
      end

      def model_key
        "UserListItem"
      end

      def target_model
        ::UserListItem
      end

      def unique_by
        :index_user_list_items_on_list_and_listable_unique
      end

      def record_timestamps?
        false
      end

      def upsert_batch
        UPSERT_BATCH
      end

      def preload_context
        @book_ids = Books::Book.pluck(:id).to_set
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy user_list_books.book_id=#{book_id.inspect} (user_list_book id=#{attrs["id"]})"
        end

        [{
          user_list_id: attrs["user_list_id"],
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"] || NULL_POSITION_SENTINEL,
          completed_on: attrs["read_date"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      def finalize
        target_model.connection.execute(<<~SQL.squish)
          UPDATE user_list_items
          SET position = ranked.new_position
          FROM (
            SELECT uli.id,
                   ROW_NUMBER() OVER (
                     PARTITION BY uli.user_list_id
                     ORDER BY uli.position, uli.id
                   ) AS new_position
            FROM user_list_items uli
            JOIN user_lists ul ON ul.id = uli.user_list_id
            WHERE ul.type = 'Books::UserList'
          ) ranked
          WHERE user_list_items.id = ranked.id
            AND user_list_items.position <> ranked.new_position
        SQL
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/lib/services/books_migration/user_list_item_migrator_test.rb test/models/legacy_books/record_test.rb
```

Expected: PASS, 9 runs, 0 failures, 0 errors.

- [ ] **Step 6: Add the rake task and wire both new tasks into `:all`**

In `web-app/lib/tasks/data_migration.rake`, add after the `:user_lists` task from Task 2:

```ruby
  desc "Migrate legacy user_list_books into user_list_items (listable = Books::Book; renumbers positions 1..N)"
  task user_list_items: :environment do
    pp Services::BooksMigration::UserListItemMigrator.call
  end
```

Then extend the `:all` task. Replace:

```ruby
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links, :lists, :list_items, :ranking_configurations, :ranked_lists, :penalties, :list_penalties]
```

with:

```ruby
  task all: [:languages, :users, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items, :external_links, :lists, :list_items, :ranking_configurations, :ranked_lists, :penalties, :list_penalties, :user_lists, :user_list_items]
```

Order matters: `user_lists` must run after `users`, and `user_list_items` after both `user_lists` and `books`.

- [ ] **Step 7: Verify the rake tasks are registered**

```bash
bin/rails -T data_migration | grep user_list
```

Expected: both `data_migration:user_lists` and `data_migration:user_list_items` are listed with their descriptions.

- [ ] **Step 8: Run the full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
bin/brakeman --no-pager
```

Expected: full suite green (0 failures, 0 errors), no lint offenses, no new brakeman warnings.

```bash
git add web-app/app/models/legacy_books/user_list_book.rb web-app/app/lib/services/books_migration/user_list_item_migrator.rb web-app/test/lib/services/books_migration/user_list_item_migrator_test.rb web-app/test/models/legacy_books/record_test.rb web-app/lib/tasks/data_migration.rake
git commit -m "Add UserListItemMigrator (legacy user_list_books -> user_list_items, positions renumbered)"
```

---

### Task 4: End-to-end verification against the real legacy database

Unit tests stub the legacy connection, so nothing so far has touched real data. This task runs the migration against the restored legacy database in development and checks every number from the design doc. **Do not skip it** — every previous increment of this migration surfaced at least one landmine here that no unit test could have caught.

**Files:**
- None created. This task produces a verification record appended to the design doc.

**Interfaces:**
- Consumes: `data_migration:user_lists` and `data_migration:user_list_items` from Tasks 2 and 3.

- [ ] **Step 1: Confirm the prerequisites are loaded**

```bash
bin/rails runner 'puts({users: User.count, books: Books::Book.count, existing_user_lists: UserList.count}.inspect)'
```

Expected: `users` ≥ 69,459 · `books` = 126,204 · `existing_user_lists` = 254 if Phase 3 has not run yet (the Music/Games/Movies rows at ids 1,000,001+; it will be higher on a re-run). If books or users are missing, run `bin/rails data_migration:all` first — Phase 3 depends on both.

- [ ] **Step 2: Re-confirm the reserved ceiling still holds**

`IdRangeReservationService`'s own comment requires this check immediately before the import, because the legacy books site is still growing.

```bash
bin/rails runner 'max = LegacyBooks::UserList.maximum(:id); ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("user_lists"); puts "legacy MAX(user_lists.id)=#{max} ceiling=#{ceiling} ok=#{max < ceiling}"'
```

Expected: `ok=true` (as of 2026-07-12: max 604,880 against a 1,000,000 ceiling). **If this prints `ok=false`, STOP** — do not run the migration. The ceiling must be raised first (zero cost on a bigint PK), which is a change to `RESERVED_CEILINGS` plus a re-run of `IdRangeReservationService`.

- [ ] **Step 3: Run the user_lists migration**

```bash
time bin/rails data_migration:user_lists
```

Expected: `{success: true, data: {model: "Books::UserList", count: 282922}}`.

- [ ] **Step 4: Verify the user_lists load**

```bash
bin/rails runner '
  b = Books::UserList.all
  puts "total:      #{b.count} (expect 282922)"
  puts "list_type:  #{b.group(:list_type).count} (expect favorites 69428, read 69440, reading 69423, want_to_read 69400, custom 5231)"
  puts "view_mode:  #{b.group(:view_mode).count} (expect default_view 282244, table_view 422, grid_view 256)"
  puts "public:     #{b.where(public: true).count} (expect 115)"
  puts "id range:   #{b.minimum(:id)}..#{b.maximum(:id)} (expect 265341..604880)"
  dupes = b.where.not(list_type: :custom).group(:user_id, :list_type).having("COUNT(*) > 1").count.size
  puts "dup default (user_id, list_type): #{dupes} (expect 0)"
'
```

`Books::UserList.all` auto-scopes to `type = "Books::UserList"` via STI, so these counts can never accidentally include the Music/Games/Movies rows.

Expected: every line matches its stated expectation. The duplicate-default check confirms `one_default_per_type_per_user` is satisfiable by the loaded data — `upsert_all` bypasses that validation, so this is the only place it gets checked.

- [ ] **Step 5: Run the user_list_items migration**

This is the 3.1M-row load; expect it to take several minutes.

```bash
time bin/rails data_migration:user_list_items
```

Expected: `{success: true, data: {model: "UserListItem", count: 3096597}}`.

- [ ] **Step 6: Verify the user_list_items load**

```bash
bin/rails runner '
  items = UserListItem.where(user_list_id: Books::UserList.select(:id))
  puts "total:        #{items.count} (expect 3096597)"
  puts "non-Books listable_type: #{items.where.not(listable_type: "Books::Book").count} (expect 0)"
  puts "completed_on: #{items.where.not(completed_on: nil).count} (expect 79721)"
  sentinel = Services::BooksMigration::UserListItemMigrator::NULL_POSITION_SENTINEL
  puts "sentinel survivors: #{items.where(position: sentinel).count} (expect 0)"
  puts "min position: #{items.minimum(:position)} (expect 1)"
  puts "dup (list, position): #{items.group(:user_list_id, :position).having("COUNT(*) > 1").count.size} (expect 0)"
  outside_read = items.where.not(completed_on: nil)
    .joins("JOIN user_lists ul ON ul.id = user_list_items.user_list_id")
    .where("ul.list_type <> ?", Books::UserList.list_types[:read])
    .count
  puts "completed_on outside the read list: #{outside_read} (expect 0)"
'
```

Expected: all seven lines match. The last check is the sharpest one available: legacy only ever set `read_date` on read lists, so any row where `completed_on` lands outside the `read` list means the `list_type` remap is wrong — and it would be wrong *silently*, since every value in `LIST_TYPE_MAP` is individually valid.

- [ ] **Step 7: Prove idempotency**

```bash
bin/rails data_migration:user_lists
bin/rails data_migration:user_list_items
```

Then re-run the verification from Steps 4 and 6. Expected: identical output — same counts, same positions, no duplicates. (Recall from the design doc that the item migrator's re-run is idempotent *in outcome* but not a no-op: its upsert resets positions to the legacy values and `finalize` renumbers them back to the same 1..N.)

- [ ] **Step 8: Record the results and commit**

Append a `## Verification (e2e, <date>)` section to `docs/superpowers/specs/2026-07-12-books-user-lists-migration-design.md` with the actual observed numbers from Steps 3–7, plus the wall-clock time of each load. If any number differs from the expectation, do NOT paper over it — investigate and report before committing.

```bash
git add docs/superpowers/specs/2026-07-12-books-user-lists-migration-design.md
git commit -m "Record e2e verification of the books user-lists migration"
```

---

## Done When

- [ ] `Books::UserList` exists, is tested, and is absent from `DEFAULT_SUBCLASSES` / `DOMAIN_SUBCLASSES`
- [ ] `bin/rails test` green; `bundle exec standardrb` clean; `bin/brakeman --no-pager` clean
- [ ] `data_migration:user_lists` and `data_migration:user_list_items` both registered and in `:all`
- [ ] E2E run reproduces every count in the design doc's assertion table, and a second run is idempotent
- [ ] `docs/features/user-lists.md` reflects the new subclass and its data-only status
