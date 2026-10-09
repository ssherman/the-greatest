# Books Legacy Sync, Increment 3: the User-Data Sync — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `data_migration:sync` keep legacy users' lists, list items, reviews, saved searches, reading goals, recommendation settings and corrections matched to legacy (routed through redirects), add the user-data half of `data_migration:sync_report`, and rewrite the launch docs for a cutover with no truncate.

**Architecture:** A `BookRoute` tells each user-data migrator where a legacy book id lands: itself, its merge survivor, `:deleted`, `:waiting` (above the books watermark, not copied yet) or `:missing`. In sync mode the user-data migrators overwrite legacy-origin rows and delete the ones legacy no longer has, behind a mass-deletion guard. List items are synced list by list through a pure `UserListItemPlan`, which `UserDataDiff` (the report) also uses, so the report and the run count the same way. `Sync` appends the user-data steps after the catalog, and the rake task rebuilds the favorites lists after a successful run.

**Tech Stack:** Rails 8.1, PostgreSQL, Minitest 6 + Mocha + fixtures, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md` (§6 user-data sync, the user-data half of §7, §8 rollout docs). Increments 1 (#365) and 2 (#368) are merged.

## Global Constraints

- Ceilings (`Services::BooksMigration::RESERVED_CEILINGS`): `users` 150,000; `user_lists` 1,000,000; `reviews` 250,000; `saved_searches` 20,000; `corrections` 10,000. "Legacy-origin" = id below the ceiling. Reading goals use `ReadingGoalMigrator::RESERVED_ID_FLOOR` (10,000).
- The sync may overwrite and delete legacy-origin rows only. New-app rows (ids at or above the ceiling) and other domains' rows (`Games::UserList`, music) are never touched.
- Users are never deleted: a legacy deletion is counted, not applied (spec §6).
- **Carried MUST from increment 2:** a user-data row whose book sits above the books watermark and is not here yet is *skipped and counted* (`waiting`), never raised. A later run picks it up.
- No test opens the legacy connection. Stub `legacy_each` / `legacy_items_for`, or pass a `FakeLegacySource`.
- Test ids: fixtures hash ids far above every ceiling, and fixture loading leaves each sequence above them, so a record created without an explicit id is **new-app** by id. Every test record meant to be legacy-origin gets an explicit id below its ceiling.
- A test class whose code path calls `bump_sequence_to_floor!` (reviews, saved searches, corrections finalize) includes `SequenceIsolation` and declares those tables with `isolate_sequences`.
- Run Rails commands from `web-app/`. Lint is `bundle exec standardrb` (not rubocop). Do not run brakeman.
- Never run a destructive command against the development database. No migrations in this increment.
- Minitest 6: `assert_equal nil, x` is a hard failure; use `assert_nil`.
- No new pages, so no Playwright spec (spec §9).
- Merging to main deploys to production. Nothing here runs on deploy; the sync only runs after `sync_init`.

## Decisions this plan makes (spec silent or amended)

1. **Deletes happen in sync mode only.** `data_migration:all` keeps today's behavior, apart from decision 9. It is about to be retired, and Shane runs it weekly in production until the switch-over.
2. **List items sync list by list in sync mode.** For each batch of 1,000 legacy-origin `Books::UserList` ids here, the migrator reads legacy's items for those lists, plans them (`UserListItemPlan`), deletes the stale rows and upserts the rest in one transaction. Streaming every legacy item (the `:all` path) cannot delete items legacy removed or collapse merge collisions without holding all 3.2M pairs in memory.
3. **A book that is neither here, redirected nor waiting fails the run for list items and reviews**, naming the legacy rows, like increment 2's catalog steps. Corrections keep today's *skip*: two legacy changesets name books legacy itself deleted, and the full migration has always skipped them.
4. **Review collisions keep the newer review, meaning the higher legacy id.** That is the order `ReviewMigrator` already dedupes in. A key held here by a *new-app* review (id at or above the ceiling) keeps the new-app review: the legacy row is skipped and counted (`held_by_new_app`).
5. **A mass-deletion guard.** An empty or half-restored legacy database looks exactly like mass deletion. `Services::BooksMigration.guard_deletion!` refuses when a step would delete more than `max(500, 5%)` of a table's legacy-origin rows, unless `SYNC_ALLOW_DELETES=1`. It covers user lists, reviews and saved searches. List items are not guarded: users remove books from lists all the time, and the user-lists step runs first and catches an empty legacy.
6. **Saved searches lose only categories deleted here** (no `Books::Category` row). A soft-deleted category stays in the criteria, as today. The search already filters it out. An unmapped legacy category still raises, because categories run first. This applies in both modes.
7. **The favorites rebuild runs from the rake task**, after a successful sync. `user_favorites_lists:rebuild` is a rake task with five steps, not a service, and `:all` runs it the same way, as a task.
8. **`user_lists`, `user_list_items`, `reviews`, `saved_searches` and `corrections` refuse after `sync_init`.** Run by hand, their full-migration mode ignores redirects and never deletes, so they would fail on a merged book or leave rows legacy removed. The sync replaces them. `users`, `reading_goals`, `recommendation_configs`, `news_posts` and `description_safety_net` stay runnable. This supersedes increment 2's decision 7 for those five tasks.
9. **Position renumbering touches legacy-origin lists only, in both modes** (spec §6). New-app lists keep their own positions.
10. **Report vs sync.** The report's `update` column (legacy `updated_at` newer than here) is report-only. The sync overwrites every legacy-origin row anyway. Insert, delete, drop, wait, collision and held-by-new-app counts are computed the same way on both sides and pinned by an equality test (spec §9). Saved searches' "categories removed" appears in the sync's output only. The report would need every legacy criteria blob to count it.
11. **`review_summaries` is rebuilt as a sync step** (`SummaryRecalculator.backfill_all!`). `insert_all` and `upsert_all` bypass the after-commit that maintains it, as the `reviews` rake task already says.
12. **The user-data steps go after `book_images`**, in `:all`'s order: user lists, list items, reading goals, saved searches, recommendation configs, reviews, review summaries, corrections. They are all after `news_posts`, as increment 2 required.

## Review Focus

1. **An empty or half-restored legacy database** (a restore in progress, the wrong `DATABASE_URL`). The sync must refuse rather than delete legacy-origin lists, reviews or saved searches. Pinned in Tasks 2, 4 and 5: `refuses past the deletion guard and deletes nothing`.
2. **A merge that commits while a sync runs**, so the run's redirects snapshot is stale. A list item or review on the just-merged book must fail the run and name the legacy row, never write an orphan. Pinned in Tasks 3 and 4: `fails naming the legacy row when the book is neither here nor redirected`.
3. **A legacy list whose items include books still inside the delay.** Those items wait, the rest land, positions come out 1..N with no gap, and the run succeeds. Pinned in Task 3: `skips an item on a book the run has not copied yet, and counts it`, and Task 7: `carries a list item on a book the run brought over and waits on one still inside the delay`.
4. **A user-data step that fails after the catalog steps succeeded.** The watermarks must not move, so the next run retries the same scope. Pinned in Task 7: `a failed user-data step leaves the watermarks`.
5. **Two reviews by one user that a merge puts on the same book, when the older one is already here.** The newer one must win without tripping `index_reviews_on_user_and_reviewable`. Pinned in Task 4: `a merge that gives one user two reviews of a book keeps the newer`.

Not unit-testable, so checked in the dev rehearsal (spec §9): `LegacySource`'s new queries against the real legacy schema (the digest SQL most of all), and the run time of the list-by-list item sync over ~600k lists.

---

## File Structure

| File | Responsibility |
|---|---|
| `web-app/app/lib/services/books_migration/sync_scope.rb` (modify) | adds `books_watermark` |
| `web-app/app/lib/services/books_migration/sync_plan.rb` (modify) | sets it |
| `web-app/app/lib/services/books_migration/book_route.rb` (create) | where a legacy book id lands |
| `web-app/app/lib/services/books_migration.rb` (modify) | `guard_deletion!` |
| `web-app/app/lib/services/books_migration/user_list_migrator.rb` (modify) | sync-mode deletes + counts |
| `web-app/app/lib/services/books_migration/user_list_item_plan.rb` (create) | one batch of lists' target state |
| `web-app/app/lib/services/books_migration/user_list_item_migrator.rb` (modify) | list-by-list sync; legacy-origin renumber |
| `web-app/app/lib/services/books_migration/review_migrator.rb` (modify) | sync-mode overwrite, routing, collisions, deletes |
| `web-app/app/lib/services/books_migration/saved_search_migrator.rb` (modify) | deleted-category removal; sync-mode deletes |
| `web-app/app/lib/services/books_migration/correction_migrator.rb` (modify) | sync-mode routing + counts |
| `web-app/app/lib/services/books_migration/sync.rb` (modify) | user-data steps |
| `web-app/lib/tasks/data_migration.rake` (modify) | favorites rebuild after sync; guards; report user data |
| `web-app/app/lib/services/books_migration/legacy_source.rb` (modify) | user-data queries |
| `web-app/app/lib/services/books_migration/user_data_diff.rb` (create) | the report's user-data numbers |
| `web-app/app/lib/services/books_migration/sync_report.rb` (modify) | renders the user-data half |
| `web-app/test/support/books_legacy_sync_helper.rb` (modify) | `books_watermark`, fake user-data queries |
| Tests (create) | `book_route_test.rb`, `deletion_guard_test.rb`, `user_list_migrator_sync_test.rb`, `user_list_item_plan_test.rb`, `user_list_item_migrator_sync_test.rb`, `review_migrator_sync_test.rb`, `saved_search_migrator_sync_test.rb`, `correction_migrator_sync_test.rb`, `user_data_diff_test.rb` under `web-app/test/lib/services/books_migration/` |
| Tests (modify) | `sync_plan_test.rb`, `sync_test.rb`, `sync_report_test.rb`, `web-app/test/lib/tasks/data_migration_test.rb` |
| `docs/launch-todo.md` (rewrite), `docs/features/books-legacy-sync.md`, `AGENTS.md`, `docs/features/goodreads-import.md`, `docs/features/books-author-enrichment.md`, `docs/features/v1-user-migration.md` (modify) | no-truncate cutover |

---

### Task 1: BookRoute, the scope's books watermark, and the deletion guard

**Files:**
- Modify: `web-app/app/lib/services/books_migration/sync_scope.rb`
- Modify: `web-app/app/lib/services/books_migration/sync_plan.rb:33-43`
- Create: `web-app/app/lib/services/books_migration/book_route.rb`
- Modify: `web-app/app/lib/services/books_migration.rb` (after `raise_if_at_ceiling!`)
- Modify: `web-app/test/support/books_legacy_sync_helper.rb`
- Test: `web-app/test/lib/services/books_migration/book_route_test.rb`, `web-app/test/lib/services/books_migration/deletion_guard_test.rb`, `web-app/test/lib/services/books_migration/sync_plan_test.rb`

**Interfaces:**
- Produces: `SyncScope#books_watermark` (Integer: the books watermark this run advances to). `Services::BooksMigration::BookRoute.new(scope, book_ids_here: Set)` with `#call(book_id)` → `Integer | :deleted | :waiting | :missing`. `Services::BooksMigration.guard_deletion!(label, doomed_count, total_count)` raises or returns nil. Test helper `sync_scope(..., books_watermark: Float::INFINITY)`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/books_migration/book_route_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::BookRouteTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def route(redirects: [], here: [10, 20], books_watermark: 1_000)
    Services::BooksMigration::BookRoute.new(
      sync_scope(redirects: redirects, books_watermark: books_watermark),
      book_ids_here: here.to_set
    )
  end

  test "a book that is here lands on itself" do
    assert_equal 10, route.call(10)
  end

  test "a merged book lands on its survivor" do
    assert_equal 20, route(redirects: [["Books::Book", 5, 20]]).call(5)
  end

  test "a deleted book is :deleted" do
    assert_equal :deleted, route(redirects: [["Books::Book", 5, nil]]).call(5)
  end

  test "a book above the watermark that is not here yet is :waiting" do
    assert_equal :waiting, route.call(1_001)
  end

  test "a book at or below the watermark that is neither here nor redirected is :missing" do
    assert_equal :missing, route.call(1_000)
    assert_equal :missing, route.call(7)
  end

  test "a merge into a book that is not here either is :missing" do
    assert_equal :missing, route(redirects: [["Books::Book", 5, 30]]).call(5)
  end

  test "an author redirect does not route a book" do
    assert_equal :missing, route(redirects: [["Books::Author", 5, 20]]).call(5)
  end
end
```

`web-app/test/lib/services/books_migration/deletion_guard_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::DeletionGuardTest < ActiveSupport::TestCase
  def with_env(name, value)
    previous = ENV[name]
    ENV[name] = value
    yield
  ensure
    ENV[name] = previous
  end

  test "allows up to the floor whatever the table size" do
    assert_nil Services::BooksMigration.guard_deletion!("user_lists", 500, 600)
  end

  test "allows up to five percent of a large table" do
    assert_nil Services::BooksMigration.guard_deletion!("user_lists", 30_000, 600_000)
  end

  test "refuses past both, naming the table and the counts" do
    error = assert_raises(RuntimeError) { Services::BooksMigration.guard_deletion!("reviews", 501, 600) }

    assert_includes error.message, "reviews"
    assert_includes error.message, "501 of 600"
    assert_includes error.message, "SYNC_ALLOW_DELETES=1"
  end

  test "SYNC_ALLOW_DELETES=1 lets it through" do
    with_env("SYNC_ALLOW_DELETES", "1") do
      assert_nil Services::BooksMigration.guard_deletion!("reviews", 600, 600)
    end
  end
end
```

Append to `web-app/test/lib/services/books_migration/sync_plan_test.rb`, inside the class:

```ruby
  test "the scope carries the books watermark the run advances to" do
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)
    legacy = FakeLegacySource.new(book_rows: [[1_001, 3.days.ago], [1_002, 1.hour.ago]])

    assert_equal 1_001, Services::BooksMigration::SyncPlan.build(legacy: legacy).scope.books_watermark
  end

  test "with no new books the scope's books watermark stays where it was" do
    init_watermarks(books: 1_000, authors: 500, book_identifiers: 5_000)

    assert_equal 1_000, Services::BooksMigration::SyncPlan.build(legacy: FakeLegacySource.new).scope.books_watermark
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/book_route_test.rb test/lib/services/books_migration/deletion_guard_test.rb test/lib/services/books_migration/sync_plan_test.rb`
Expected: FAIL. `sync_scope` rejects `books_watermark:` (ArgumentError, unknown keyword), `NoMethodError: undefined method 'guard_deletion!'`, and `undefined method 'books_watermark'`.

- [ ] **Step 3: Implement**

`web-app/app/lib/services/books_migration/sync_scope.rb`, replacing the Struct line and its comment:

```ruby
module Services
  module BooksMigration
    # What one data_migration:sync run may write (spec §5): the legacy books,
    # authors and book_identifiers rows it brings over, and the redirects that
    # every other book or author id is routed through. books_watermark is the
    # books watermark this run advances to: a legacy book above it has not been
    # copied yet, so user data on it waits for a later run (spec §6). Built by
    # SyncPlan, read by the migrators through their sync: argument.
    SyncScope = Struct.new(:book_ids, :author_ids, :identifier_ids, :redirects, :books_watermark, keyword_init: true)
  end
end
```

`web-app/app/lib/services/books_migration/sync_plan.rb`: compute `@next_watermarks` before `@scope` and pass it in. Replace lines 33-43 with:

```ruby
        @next_watermarks = {
          "books" => books.ids.max || @watermarks["books"],
          "authors" => authors.ids.max || @watermarks["authors"],
          "book_identifiers" => identifiers.ids.max || @watermarks["book_identifiers"]
        }
        @scope = SyncScope.new(
          book_ids: books.ids.to_set - redirects.redirected_ids("Books::Book"),
          author_ids: authors.ids.to_set - redirects.redirected_ids("Books::Author"),
          identifier_ids: identifiers.ids.to_set,
          redirects: redirects,
          books_watermark: @next_watermarks["books"]
        )
```

Create `web-app/app/lib/services/books_migration/book_route.rb`:

```ruby
module Services
  module BooksMigration
    # Where a legacy user-data row's book lands in a sync run (spec §6): the book
    # itself, its merge survivor, :deleted (the row is dropped and counted), or
    # :waiting, a legacy book above the books watermark that this run has not
    # copied yet because of the 24h delay (skipped and counted; a later run picks
    # the row up). :missing is a book that is none of these: removed here without
    # callbacks, or merged while this run was going. The caller decides whether
    # that fails the run.
    class BookRoute
      def initialize(scope, book_ids_here: ::Books::Book.pluck(:id).to_set)
        @redirects = scope.redirects
        @watermark = scope.books_watermark
        @here = book_ids_here
      end

      def call(book_id)
        resolved = @redirects.resolve("Books::Book", book_id)
        return :deleted if resolved == :deleted
        return resolved if @here.include?(resolved)
        return :waiting if resolved == book_id && book_id > @watermark

        :missing
      end
    end
  end
end
```

`web-app/app/lib/services/books_migration.rb`, after `raise_if_at_ceiling!`:

```ruby
    # A sync deletes legacy-origin rows that legacy no longer has (spec §6). An
    # empty or half-restored legacy database looks exactly like mass deletion, so
    # a step refuses past max(DELETION_FLOOR, DELETION_SHARE of the table) unless
    # SYNC_ALLOW_DELETES=1.
    DELETION_FLOOR = 500
    DELETION_SHARE = 0.05

    def self.guard_deletion!(label, doomed, total)
      return if doomed <= [DELETION_FLOOR, (total * DELETION_SHARE).floor].max
      return if ENV["SYNC_ALLOW_DELETES"] == "1"

      raise "#{label}: would delete #{doomed} of #{total} legacy-origin rows that legacy no longer has. " \
        "Check the legacy database; if the deletions are real, re-run with SYNC_ALLOW_DELETES=1"
    end
```

`web-app/test/support/books_legacy_sync_helper.rb`, replace `sync_scope`:

```ruby
  # redirects: rows for Services::BooksMigration::Redirects.new, [[item_type, from_id, to_id], ...]
  # books_watermark defaults to nothing waiting, so a book that is not here is :missing.
  def sync_scope(book_ids: [], author_ids: [], identifier_ids: [], redirects: [], books_watermark: Float::INFINITY)
    Services::BooksMigration::SyncScope.new(
      book_ids: book_ids.to_set,
      author_ids: author_ids.to_set,
      identifier_ids: identifier_ids.to_set,
      redirects: Services::BooksMigration::Redirects.new(redirects),
      books_watermark: books_watermark
    )
  end
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/`
Expected: PASS, including every increment 2 test that uses `sync_scope`.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/sync_scope.rb web-app/app/lib/services/books_migration/sync_plan.rb web-app/app/lib/services/books_migration/book_route.rb web-app/app/lib/services/books_migration.rb web-app/test/support/books_legacy_sync_helper.rb web-app/test/lib/services/books_migration/book_route_test.rb web-app/test/lib/services/books_migration/deletion_guard_test.rb web-app/test/lib/services/books_migration/sync_plan_test.rb
git commit -m "Route user data through redirects, and guard sync deletions"
```

---

### Task 2: User lists — delete what legacy no longer has

**Files:**
- Modify: `web-app/app/lib/services/books_migration/user_list_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/user_list_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `guard_deletion!` (Task 1).
- Produces: sync-mode result data `{inserted:, deleted:, items_deleted:}`. Full mode is unchanged.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class Services::BooksMigration::UserListMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  setup do
    @user = users(:regular_user)
    @kept = ::Books::UserList.create!(id: 500, user: @user, name: "Kept", list_type: :custom)
    @gone = ::Books::UserList.create!(id: 501, user: @user, name: "Deleted On Legacy", list_type: :custom)
    UserListItem.create!(user_list: @gone, listable: ::Books::Book.create!(title: "On A Gone List"), position: 1)
  end

  def legacy_list(id, overrides = {})
    {
      "id" => id, "user_id" => @user.id, "name" => "Legacy #{id}", "description" => nil, "list_type" => 4,
      "view_mode" => nil, "public" => true, "position" => 1,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 2, 1)
    }.merge(overrides)
  end

  def run_migrator(rows, sync: sync_scope)
    migrator = Services::BooksMigration::UserListMigrator.new(sync: sync)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  test "deletes a legacy-origin books list legacy no longer has, with its items" do
    result = run_migrator([legacy_list(500)])

    assert result[:success], result[:error]
    refute ::UserList.exists?(501)
    refute UserListItem.exists?(user_list_id: 501)
    assert_equal({inserted: 0, deleted: 1, items_deleted: 1}, result[:data].slice(:inserted, :deleted, :items_deleted))
  end

  test "overwrites a list legacy still has" do
    run_migrator([legacy_list(500, "name" => "Renamed On Legacy"), legacy_list(501)])

    assert_equal "Renamed On Legacy", @kept.reload.name
  end

  test "leaves new-app lists and other domains' lists alone" do
    new_app = ::Books::UserList.create!(id: 1_000_500, user: @user, name: "New App", list_type: :custom)
    games = ::Games::UserList.create!(id: 502, user: @user, name: "Games", list_type: :custom)

    result = run_migrator([legacy_list(500), legacy_list(501)])

    assert result[:success], result[:error]
    assert ::UserList.exists?(new_app.id)
    assert ::UserList.exists?(games.id)
  end

  test "counts what it inserts" do
    result = run_migrator([legacy_list(500), legacy_list(501), legacy_list(503)])

    assert_equal({inserted: 1, deleted: 0}, result[:data].slice(:inserted, :deleted))
  end

  test "refuses past the deletion guard and deletes nothing" do
    Services::BooksMigration.expects(:guard_deletion!).with("user_lists", 1, 2).raises(RuntimeError, "would delete 1 of 2")

    result = run_migrator([legacy_list(500)])

    refute result[:success]
    assert_includes result[:error], "would delete 1 of 2"
    assert ::UserList.exists?(501)
  end

  test "the full migration deletes nothing" do
    result = run_migrator([legacy_list(500)], sync: nil)

    assert result[:success], result[:error]
    assert ::UserList.exists?(501)
    refute result[:data].key?(:deleted)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/user_list_migrator_sync_test.rb`
Expected: FAIL. List 501 still exists, and `result[:data]` has no `:inserted`/`:deleted`. "leaves new-app lists alone", "overwrites" and "the full migration deletes nothing" may already pass.

- [ ] **Step 3: Implement**

In `user_list_migrator.rb`, add these private methods and change `build_rows`'s first line:

```ruby
      # Sync mode (spec §6) remembers which lists legacy has, so finalize can
      # delete the legacy-origin ones it no longer has.
      def preload_context
        return unless sync

        @here_ids = legacy_origin_lists.pluck(:id).to_set
        @legacy_ids = Set.new
        @items_deleted = 0
      end

      def build_rows(attrs)
        @legacy_ids << attrs["id"] if sync
        [{
          # ... the existing hash, unchanged ...
        }]
      end

      # Runs only after every legacy row was read and written, so a failed run
      # deletes nothing. Items go first: user_list_items has a plain foreign key.
      def finalize
        return unless sync

        @doomed_ids = (@here_ids - @legacy_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("user_lists", @doomed_ids.size, @here_ids.size)
        @doomed_ids.each_slice(1_000) do |ids|
          ::UserList.transaction do
            @items_deleted += ::UserListItem.where(user_list_id: ids).delete_all
            ::UserList.where(id: ids).delete_all
          end
        end
      end

      def extra_result_data
        return {} unless sync

        {inserted: (@legacy_ids - @here_ids).size, deleted: @doomed_ids.size, items_deleted: @items_deleted}
      end

      # Books lists below the ceiling came from legacy. New-app lists sit above it,
      # and other domains' lists are never this migrator's.
      def legacy_origin_lists
        ::Books::UserList.where(id: ...RESERVED_CEILINGS.fetch("user_lists"))
      end
```

Add one sentence to the class comment: "In data_migration:sync it also deletes legacy-origin Books lists that legacy no longer has (spec §6)."

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/user_list_migrator_sync_test.rb test/lib/services/books_migration/user_list_migrator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/user_list_migrator.rb web-app/test/lib/services/books_migration/user_list_migrator_sync_test.rb
git commit -m "Sync deletes books user lists legacy no longer has"
```

---

### Task 3: User list items — list by list, routed, collisions collapsed

**Files:**
- Create: `web-app/app/lib/services/books_migration/user_list_item_plan.rb`
- Modify: `web-app/app/lib/services/books_migration/user_list_item_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/user_list_item_plan_test.rb`, `web-app/test/lib/services/books_migration/user_list_item_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `BookRoute` (Task 1).
- Produces: `UserListItemPlan.call(legacy_rows, here_rows, route)` → `Plan(keep: {[list_id, book_id] => legacy_attrs}, stale_ids: [Integer], inserted:, dropped:, waiting:, collisions:, missing: [legacy item ids])`. `here_rows` is `[[id, user_list_id, listable_type, listable_id], ...]`. Migrator sync-mode result data `{inserted:, deleted:, dropped:, waiting:, collisions:}`. Private `legacy_items_for(list_ids)` → Array of legacy attribute hashes (stubbed in tests).

- [ ] **Step 1: Write the failing tests**

`user_list_item_plan_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::UserListItemPlanTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  def route(redirects: [])
    Services::BooksMigration::BookRoute.new(sync_scope(redirects: redirects), book_ids_here: Set[10, 20, 30])
  end

  def row(id, list_id, book_id, position)
    {"id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position}
  end

  test "counts as inserted only the items not already here" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 10, 1), row(2, 7, 20, 2)], [[90, 7, "Books::Book", 10]], route
    )

    assert_equal [[7, 10], [7, 20]], plan.keep.keys
    assert_equal 1, plan.inserted
    assert_empty plan.stale_ids
  end

  test "an item here that legacy does not have is stale, whatever its type" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 10, 1)], [[90, 7, "Books::Book", 30], [91, 7, "Games::Game", 10]], route
    )

    assert_equal [90, 91], plan.stale_ids
  end

  test "a null position sorts last when collapsing a collision" do
    plan = Services::BooksMigration::UserListItemPlan.call(
      [row(1, 7, 5, nil), row(2, 7, 20, 4)], [], route(redirects: [["Books::Book", 5, 20]])
    )

    assert_equal 2, plan.keep[[7, 20]]["id"]
    assert_equal 1, plan.collisions
  end

  test "collects missing books instead of raising" do
    plan = Services::BooksMigration::UserListItemPlan.call([row(1, 7, 99, 1)], [], route)

    assert_equal [1], plan.missing
  end
end
```

`user_list_item_migrator_sync_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::UserListItemMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper

  setup do
    @user = users(:regular_user)
    @list = ::Books::UserList.create!(id: 600, user: @user, name: "Legacy List", list_type: :custom)
    @book = ::Books::Book.create!(title: "Plain")
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_item(id, book_id, position, list_id: @list.id, read_date: nil)
    {
      "id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position, "read_date" => read_date,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 1, 2)
    }
  end

  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY)
    migrator = Services::BooksMigration::UserListItemMigrator.new(
      sync: sync_scope(redirects: redirects, books_watermark: books_watermark)
    )
    migrator.define_singleton_method(:legacy_items_for) do |list_ids|
      rows.select { |row| list_ids.include?(row["user_list_id"]) }
    end
    migrator.call
  end

  def listed(list = @list) = UserListItem.where(user_list_id: list.id).order(:position).pluck(:listable_id)

  def add_here(list, book, position)
    UserListItem.insert_all([{
      user_list_id: list.id, listable_type: "Books::Book", listable_id: book.id, position: position,
      created_at: Time.current, updated_at: Time.current
    }])
  end

  test "routes an item on a merged book onto the survivor" do
    result = run_sync([legacy_item(1, 200_001, 1)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert result[:success], result[:error]
    assert_equal [@survivor.id], listed
    assert_equal 1, result[:data][:inserted]
  end

  test "a merge that leaves two items for one book keeps the one at the lower position" do
    result = run_sync(
      [legacy_item(2, 200_001, 1), legacy_item(3, @book.id, 3), legacy_item(4, @survivor.id, 5)],
      redirects: [["Books::Book", 200_001, @survivor.id]]
    )

    assert result[:success], result[:error]
    assert_equal [@survivor.id, @book.id], listed
    assert_equal 1, result[:data][:collisions]
  end

  test "drops an item whose book was deleted and counts it" do
    result = run_sync([legacy_item(1, 200_002, 1)], redirects: [["Books::Book", 200_002, nil]])

    assert result[:success], result[:error]
    assert_empty listed
    assert_equal 1, result[:data][:dropped]
  end

  test "skips an item on a book the run has not copied yet, and counts it" do
    result = run_sync([legacy_item(1, @book.id, 1), legacy_item(2, 200_003, 2), legacy_item(3, @survivor.id, 3)],
      books_watermark: 200_000)

    assert result[:success], result[:error]
    assert_equal [@book.id, @survivor.id], listed
    assert_equal [1, 2], UserListItem.where(user_list_id: @list.id).order(:position).pluck(:position)
    assert_equal 1, result[:data][:waiting]
  end

  test "fails naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([legacy_item(77, 150_000, 1)], books_watermark: 200_000)

    refute result[:success]
    assert_includes result[:error], "77"
  end

  test "deletes an item legacy no longer has from a legacy-origin list" do
    add_here(@list, @book, 1)

    result = run_sync([legacy_item(1, @survivor.id, 1)])

    assert_equal [@survivor.id], listed
    assert_equal({inserted: 1, deleted: 1}, result[:data].slice(:inserted, :deleted))
  end

  test "an item already here takes legacy's values and is not counted as inserted" do
    add_here(@list, @book, 1)

    result = run_sync([legacy_item(1, @book.id, 1, read_date: Date.new(2024, 5, 1))])

    assert_equal Date.new(2024, 5, 1), UserListItem.find_by(user_list_id: @list.id, listable_id: @book.id).completed_on
    assert_equal 0, result[:data][:inserted]
  end

  test "leaves a new-app list's items and positions alone" do
    new_app = ::Books::UserList.create!(id: 1_000_600, user: @user, name: "New App", list_type: :custom)
    add_here(new_app, @book, 5)
    add_here(new_app, @survivor, 9)

    result = run_sync([legacy_item(1, @book.id, 4)])

    assert result[:success], result[:error]
    assert_equal [5, 9], UserListItem.where(user_list_id: new_app.id).order(:position).pluck(:position)
    assert_equal [1], UserListItem.where(user_list_id: @list.id).pluck(:position)
  end
end
```

In the existing `user_list_item_migrator_test.rb` setup, give `@list` an explicit legacy-origin id: `::Books::UserList.create!(id: 610, user: @user, name: "Books I've Read", list_type: :read)`. Created without an id, a list is new-app by id, and decision 9 stops renumbering it. Do the same for any other `Books::UserList` that file creates and expects renumbered, using ids 611, 612 and so on.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/user_list_item_plan_test.rb test/lib/services/books_migration/user_list_item_migrator_sync_test.rb`
Expected: FAIL. `uninitialized constant Services::BooksMigration::UserListItemPlan`. The migrator tests fail because sync mode still streams `legacy_each`, which opens the legacy table (error), and the new-app list is renumbered.

- [ ] **Step 3: Implement**

Create `web-app/app/lib/services/books_migration/user_list_item_plan.rb`:

```ruby
module Services
  module BooksMigration
    # What one batch of legacy-origin user lists should hold after a sync (spec §6).
    # UserListItemMigrator applies it and UserDataDiff only counts it, so the
    # report and the run agree.
    #
    # Each legacy item's book goes through BookRoute. Two legacy items that land
    # on the same book in one list (a merge) collapse to the one at the lower
    # position. Items on deleted books are dropped, items on books the run has not
    # copied yet wait, and items on :missing books are collected for the caller.
    # Every row here that the plan does not keep is stale: legacy removed it, or a
    # merge or replay relink put it there.
    class UserListItemPlan
      Plan = Struct.new(:keep, :stale_ids, :inserted, :dropped, :waiting, :collisions, :missing, keyword_init: true)

      # legacy_rows: legacy user_list_books attribute hashes (String keys).
      # here_rows: [[id, user_list_id, listable_type, listable_id], ...] for the same lists.
      def self.call(legacy_rows, here_rows, route)
        keep = {}
        counts = Hash.new(0)
        missing = []
        ordered = legacy_rows.sort_by { |row| [row["position"] || UserListItemMigrator::NULL_POSITION_SENTINEL, row["id"]] }
        ordered.each do |row|
          book_id = route.call(row["book_id"])
          case book_id
          when :deleted then counts[:dropped] += 1
          when :waiting then counts[:waiting] += 1
          when :missing then missing << row["id"]
          else
            key = [row["user_list_id"], book_id]
            if keep.key?(key)
              counts[:collisions] += 1
            else
              keep[key] = row
            end
          end
        end

        present = Set.new
        stale_ids = []
        here_rows.each do |id, list_id, type, listable_id|
          if type == "Books::Book" && keep.key?([list_id, listable_id])
            present << [list_id, listable_id]
          else
            stale_ids << id
          end
        end

        Plan.new(
          keep: keep, stale_ids: stale_ids, inserted: keep.keys.count { |key| !present.include?(key) },
          dropped: counts[:dropped], waiting: counts[:waiting], collisions: counts[:collisions], missing: missing
        )
      end
    end
  end
end
```

Modify `user_list_item_migrator.rb`:

1. Add `LIST_BATCH = 1_000` under `UPSERT_BATCH`.
2. Add a public `call` above `private`:

```ruby
      # Sync mode (spec §6) works list by list instead of streaming every legacy
      # item: each batch of legacy-origin lists is made to match legacy, which is
      # what lets it delete items legacy removed and collapse merge collisions.
      def call
        return super unless sync

        @count = 0
        @stats = {inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0}
        route = BookRoute.new(sync)
        Services::BooksMigration.without_search_indexing do
          legacy_origin_list_ids.each_slice(LIST_BATCH) { |list_ids| sync_lists(list_ids, route) }
        end
        finalize
        {success: true, data: {model: model_key, count: @count}.merge(@stats)}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end
```

3. Replace `build_rows` and add the sync helpers (private):

```ruby
      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated Books::Book for legacy user_list_books.book_id=#{book_id.inspect} (user_list_book id=#{attrs["id"]})"
        end

        [item_row(attrs, attrs["user_list_id"], book_id)]
      end

      def item_row(attrs, list_id, book_id)
        {
          user_list_id: list_id,
          listable_type: "Books::Book",
          listable_id: book_id,
          position: attrs["position"] || NULL_POSITION_SENTINEL,
          completed_on: attrs["read_date"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      def sync_lists(list_ids, route)
        here = ::UserListItem.where(user_list_id: list_ids).pluck(:id, :user_list_id, :listable_type, :listable_id)
        plan = UserListItemPlan.call(legacy_items_for(list_ids), here, route)
        if plan.missing.any?
          raise "legacy user_list_books #{plan.missing.first(10).join(", ")} name a book that is neither here " \
            "nor redirected (removed without callbacks, or merged while this run was going)"
        end

        rows = plan.keep.map { |(list_id, book_id), attrs| item_row(attrs, list_id, book_id) }
        ::UserListItem.transaction do
          ::UserListItem.where(id: plan.stale_ids).delete_all if plan.stale_ids.any?
          rows.each_slice(UPSERT_BATCH) do |slice|
            target_model.upsert_all(slice, unique_by: unique_by, record_timestamps: false)
          end
        end
        @count += rows.size
        @stats[:inserted] += plan.inserted
        @stats[:deleted] += plan.stale_ids.size
        %i[dropped waiting collisions].each { |key| @stats[key] += plan.public_send(key) }
      end

      def legacy_origin_list_ids
        ::Books::UserList.where(id: ...RESERVED_CEILINGS.fetch("user_lists")).order(:id).pluck(:id)
      end

      # Stubbed in tests, so the legacy connection is never opened.
      def legacy_items_for(list_ids)
        LegacyBooks::UserListBook.where(user_list_id: list_ids).map(&:attributes)
      end
```

4. In `finalize`'s SQL, change `WHERE ul.type = 'Books::UserList'` to:

```sql
            WHERE ul.type = 'Books::UserList'
              AND ul.id < #{RESERVED_CEILINGS.fetch("user_lists").to_i}
```

5. Class comment: replace "finalize renumbers every Books row to 1..N" with "finalize renumbers legacy-origin Books lists (below the user_lists ceiling) to 1..N; new-app lists keep their own positions". Then add: "In data_migration:sync it works list by list instead (see call and UserListItemPlan)."

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/user_list_item_plan_test.rb test/lib/services/books_migration/user_list_item_migrator_sync_test.rb test/lib/services/books_migration/user_list_item_migrator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/user_list_item_plan.rb web-app/app/lib/services/books_migration/user_list_item_migrator.rb web-app/test/lib/services/books_migration/user_list_item_plan_test.rb web-app/test/lib/services/books_migration/user_list_item_migrator_sync_test.rb web-app/test/lib/services/books_migration/user_list_item_migrator_test.rb
git commit -m "Sync user list items list by list through redirects"
```

---

### Task 4: Reviews — overwrite, route, collapse collisions, delete

**Files:**
- Modify: `web-app/app/lib/services/books_migration/review_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/review_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `BookRoute`, `guard_deletion!` (Task 1).
- Produces: sync-mode result data `{inserted:, deleted:, dropped:, waiting:, collisions:, held_by_new_app:}`. Full mode is unchanged (insert-only).

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class Services::BooksMigration::ReviewMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "reviews"

  setup do
    ::Review.delete_all
    ::ReviewSummary.delete_all
    @user = users(:regular_user)
    @other_user = users(:editor_user)
    @book = ::Books::Book.create!(title: "Reviewed")
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_review(id, overrides = {})
    {
      "id" => id, "user_id" => @user.id, "book_id" => @book.id, "title" => nil, "body" => nil, "rating" => 4,
      "created_at" => Time.utc(2025, 1, 2), "updated_at" => Time.utc(2025, 6, 7)
    }.merge(overrides)
  end

  # Rows newest first, as the real legacy_each yields them.
  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY, sync: :default)
    scope = (sync == :default) ? sync_scope(redirects: redirects, books_watermark: books_watermark) : sync
    migrator = Services::BooksMigration::ReviewMigrator.new(sync: scope)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  def here_review(id, book: @book, user: @user, rating: 2)
    ::Review.create!(id: id, user: user, reviewable: book, rating: rating)
  end

  def stats(result) = result[:data].slice(:inserted, :deleted, :dropped, :waiting, :collisions, :held_by_new_app)

  test "overwrites a review legacy edited" do
    here_review(100, rating: 2)

    result = run_sync([legacy_review(100, "rating" => 5)])

    assert result[:success], result[:error]
    assert_equal 5, ::Review.find(100).rating
    assert_equal 0, result[:data][:inserted]
  end

  test "routes a review of a merged book onto the survivor" do
    run_sync([legacy_review(101, "book_id" => 200_001)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert_equal @survivor.id, ::Review.find(101).reviewable_id
  end

  test "a merge that gives one user two reviews of a book keeps the newer" do
    here_review(102, book: @survivor, rating: 1)

    result = run_sync(
      [legacy_review(103, "book_id" => 200_001, "rating" => 5), legacy_review(102, "book_id" => @survivor.id, "rating" => 1)],
      redirects: [["Books::Book", 200_001, @survivor.id]]
    )

    assert result[:success], result[:error]
    assert_equal 5, ::Review.find(103).rating
    refute ::Review.exists?(102)
    assert_equal({inserted: 1, deleted: 1, dropped: 0, waiting: 0, collisions: 1, held_by_new_app: 0}, stats(result))
  end

  test "drops a review of a deleted book and skips one whose book has not arrived" do
    result = run_sync(
      [legacy_review(105, "book_id" => 200_003), legacy_review(104, "book_id" => 200_002)],
      redirects: [["Books::Book", 200_002, nil]], books_watermark: 200_000
    )

    assert result[:success], result[:error]
    assert_equal 0, ::Review.count
    assert_equal [1, 1], result[:data].values_at(:dropped, :waiting)
  end

  test "fails naming the legacy row when the book is neither here nor redirected" do
    result = run_sync([legacy_review(106, "book_id" => 150_000)], books_watermark: 200_000)

    refute result[:success]
    assert_includes result[:error], "106"
  end

  test "deletes a legacy-origin books review legacy no longer has, and leaves new-app reviews alone" do
    here_review(107)
    new_app = here_review(250_001, book: @survivor)

    result = run_sync([])

    assert result[:success], result[:error]
    refute ::Review.exists?(107)
    assert ::Review.exists?(new_app.id)
    assert_equal 1, result[:data][:deleted]
  end

  test "a new-app review of the same book by the same user wins over the legacy one" do
    here_review(250_002)

    result = run_sync([legacy_review(108)])

    assert result[:success], result[:error]
    refute ::Review.exists?(108)
    assert ::Review.exists?(250_002)
    assert_equal 1, result[:data][:held_by_new_app]
  end

  test "refuses past the deletion guard and deletes nothing" do
    here_review(109)
    Services::BooksMigration.expects(:guard_deletion!).with("reviews", 1, 1).raises(RuntimeError, "would delete 1 of 1")

    result = run_sync([])

    refute result[:success]
    assert ::Review.exists?(109)
  end

  test "the full migration stays insert-only" do
    here_review(110, rating: 2)

    result = run_sync([legacy_review(110, "rating" => 5)], sync: nil)

    assert result[:success], result[:error]
    assert_equal 2, ::Review.find(110).rating
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_sync_test.rb`
Expected: FAIL. No overwrite, `200_001` raises "no migrated ::Books::Book", nothing is deleted, and there are no stats keys. "the full migration stays insert-only" passes.

- [ ] **Step 3: Implement**

In `review_migrator.rb`, replace `preload_context`, `finalize` and `build_rows`'s book lookup, and add the sync methods (all private):

```ruby
      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @user_ids = ::User.pluck(:id).to_set
        @seen = Set.new
        return unless sync

        @route = BookRoute.new(sync, book_ids_here: @book_ids)
        @here_ids = legacy_origin_reviews.pluck(:id).to_set
        @kept_ids = Set.new
        @stats = {inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0, held_by_new_app: 0}
      end

      def finalize
        delete_reviews_legacy_lacks if sync
        Services::BooksMigration.bump_sequence_to_floor!("reviews")
      end

      def extra_result_data
        sync ? @stats : {}
      end

      def build_rows(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("reviews", attrs["id"])

        book_id = sync ? routed_book_id(attrs) : attrs["book_id"]
        return [] if book_id.nil?

        unless @book_ids.include?(book_id)
          raise "no migrated ::Books::Book for legacy reviews.book_id=#{book_id.inspect}"
        end

        user_id = attrs["user_id"]
        unless @user_ids.include?(user_id)
          raise "no migrated ::User for legacy reviews.user_id=#{user_id.inspect}"
        end

        # First occurrence wins, and rows arrive newest-first.
        unless @seen.add?([user_id, book_id])
          @stats[:collisions] += 1 if sync
          return []
        end

        [{
          id: attrs["id"],
          user_id: user_id,
          reviewable_type: "Books::Book",
          reviewable_id: book_id,
          title: attrs["title"]&.strip.presence,
          body: body_for(attrs),
          rating: attrs["rating"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # nil drops the row; the reason is counted.
      def routed_book_id(attrs)
        book_id = @route.call(attrs["book_id"])
        case book_id
        when :deleted, :waiting
          @stats[(book_id == :deleted) ? :dropped : :waiting] += 1
          nil
        when :missing
          raise "legacy reviews.book_id=#{attrs["book_id"]} is neither here nor redirected " \
            "(removed without callbacks, or merged while this run was going)"
        else
          book_id
        end
      end

      # Sync mode overwrites (spec §6) instead of insert-only, keyed on the id. A
      # different legacy-origin review holding the same user and book (the older
      # side of a merge collision, or one a replay relink moved here) is deleted
      # first, so the unique index takes the winner. A new-app review holding it
      # wins instead, and the legacy row is skipped.
      def flush(rows)
        return super unless sync

        holders = ::Review
          .where(reviewable_type: "Books::Book", user_id: rows.map { |row| row[:user_id] },
            reviewable_id: rows.map { |row| row[:reviewable_id] })
          .pluck(:user_id, :reviewable_id, :id)
          .to_h { |user_id, book_id, id| [[user_id, book_id], id] }
        ceiling = RESERVED_CEILINGS.fetch("reviews")
        stale = []
        writable = rows.select do |row|
          holder = holders[[row[:user_id], row[:reviewable_id]]]
          next true if holder.nil? || holder == row[:id]

          if holder >= ceiling
            @stats[:held_by_new_app] += 1
            next false
          end
          stale << holder
          true
        end

        ::Review.transaction do
          ::Review.where(id: stale).delete_all if stale.any?
          ::Review.upsert_all(writable, unique_by: :id, record_timestamps: false) if writable.any?
        end
        @kept_ids.merge(writable.map { |row| row[:id] })
        @count += writable.size
      end

      # Every legacy-origin books review the run did not keep: legacy deleted it,
      # it lost a collision, or its book was deleted here. Counted against the
      # ids here at the start, as UserDataDiff counts them.
      def delete_reviews_legacy_lacks
        doomed = (@here_ids - @kept_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("reviews", doomed.size, @here_ids.size)
        doomed.each_slice(1_000) { |ids| ::Review.where(id: ids).delete_all }
        @stats[:inserted] = (@kept_ids - @here_ids).size
        @stats[:deleted] = doomed.size
      end

      def legacy_origin_reviews
        ::Review.where(reviewable_type: "Books::Book", id: ...RESERVED_CEILINGS.fetch("reviews"))
      end
```

Class comment: after the `insert_all` paragraph, add "In data_migration:sync (spec §6) it overwrites instead, routes each book through redirects, and deletes legacy-origin books reviews that legacy no longer has. See flush."

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/review_migrator_sync_test.rb test/lib/services/books_migration/review_migrator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/review_migrator.rb web-app/test/lib/services/books_migration/review_migrator_sync_test.rb
git commit -m "Sync overwrites legacy reviews, routed, newest wins a collision"
```

---

### Task 5: Saved searches — drop deleted categories, delete what legacy lacks

**Files:**
- Modify: `web-app/app/lib/services/books_migration/saved_search_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/saved_search_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `guard_deletion!` (Task 1).
- Produces: result data `categories_removed:` (both modes); in sync mode also `inserted:` and `deleted:`.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class Services::BooksMigration::SavedSearchMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "saved_searches"

  setup do
    @user = users(:regular_user)
    @genre = ::Books::Category.create!(name: "Kept Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 31, new_id: @genre.id)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 32, new_id: 999_999_999) # deleted here
  end

  def legacy_search(id, criteria = {"genre_match_mode" => "any"})
    {
      "id" => id, "user_id" => @user.id, "name" => "Search #{id}", "description" => nil,
      "criteria" => criteria.to_json, "public" => false, "last_executed_at" => nil, "result_count" => nil,
      "created_at" => Time.utc(2025, 1, 1), "updated_at" => Time.utc(2025, 2, 1)
    }
  end

  def run_migrator(rows, sync: sync_scope)
    migrator = Services::BooksMigration::SavedSearchMigrator.new(sync: sync)
    stub = migrator.stubs(:legacy_each)
    stub.multiple_yields(*rows.zip) if rows.any?
    migrator.call
  end

  def here_search(id)
    ::Books::SavedSearch.create!(id: id, user: @user, name: "Here #{id}", criteria: {"genre_match_mode" => "any"})
  end

  test "removes a category deleted here from the criteria and counts it" do
    result = run_migrator([legacy_search(15_001, {"included_category_ids" => ["31", "32"]})], sync: nil)

    assert result[:success], result[:error]
    assert_equal [@genre.id], ::Books::SavedSearch.find(15_001).criteria["included_category_ids"]
    assert_equal 1, result[:data][:categories_removed]
  end

  test "still raises on a legacy category with no map entry" do
    result = run_migrator([legacy_search(15_001, {"included_category_ids" => ["33"]})], sync: nil)

    refute result[:success]
    assert_includes result[:error], "no LegacyIdMap for Books::Category legacy_id=33"
  end

  test "deletes a legacy-origin books search legacy no longer has" do
    here_search(15_002)

    result = run_migrator([legacy_search(15_001)])

    assert result[:success], result[:error]
    refute ::SavedSearch.exists?(15_002)
    assert_equal({inserted: 1, deleted: 1}, result[:data].slice(:inserted, :deleted))
  end

  test "leaves new-app searches alone" do
    new_app = here_search(20_001)

    run_migrator([])

    assert ::SavedSearch.exists?(new_app.id)
  end

  test "refuses past the deletion guard and deletes nothing" do
    here_search(15_002)
    Services::BooksMigration.expects(:guard_deletion!).with("saved_searches", 1, 1).raises(RuntimeError, "would delete 1 of 1")

    result = run_migrator([])

    refute result[:success]
    assert ::SavedSearch.exists?(15_002)
  end

  test "the full migration deletes nothing" do
    here_search(15_002)

    result = run_migrator([legacy_search(15_001)], sync: nil)

    assert result[:success], result[:error]
    assert ::SavedSearch.exists?(15_002)
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/saved_search_migrator_sync_test.rb`
Expected: FAIL. `999_999_999` survives in the criteria, there is no `categories_removed`, and 15_002 is not deleted.

- [ ] **Step 3: Implement**

In `saved_search_migrator.rb`, add a public `call` above `private`, and change and add private methods:

```ruby
      # Public: Migrator.call is `new.call`. Sets up the counters before the stream.
      def call
        @categories_removed = 0
        if sync
          @here_ids = legacy_origin_searches.pluck(:id).to_set
          @legacy_ids = Set.new
        end
        super
      end

      private

      # ... legacy_model, model_key unchanged ...

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("saved_searches", attrs["id"])
        @legacy_ids << attrs["id"] if sync
        # ... the rest unchanged ...
      end

      # A mapped category deleted here since is removed from the criteria and
      # counted (spec §6). A soft-deleted one stays, because the search already
      # skips it. A legacy category with no map entry still raises: categories
      # run first, so that is a missing prerequisite.
      def remap_category_ids(value)
        Array(value).filter_map do |legacy_id|
          new_id = category_map.fetch(legacy_id.to_i) do
            raise "no LegacyIdMap for Books::Category legacy_id=#{legacy_id} (run the categories migrator first)"
          end
          next new_id if category_ids_here.include?(new_id)

          @categories_removed += 1
          nil
        end
      end

      def category_ids_here
        @category_ids_here ||= ::Books::Category.pluck(:id).to_set
      end

      def finalize
        delete_searches_legacy_lacks if sync
        Services::BooksMigration.bump_sequence_to_floor!("saved_searches")
      end

      # Runs only after every legacy row was written, so a failed run deletes nothing.
      def delete_searches_legacy_lacks
        @doomed_ids = (@here_ids - @legacy_ids).to_a.sort
        Services::BooksMigration.guard_deletion!("saved_searches", @doomed_ids.size, @here_ids.size)
        legacy_origin_searches.where(id: @doomed_ids).delete_all if @doomed_ids.any?
      end

      def extra_result_data
        data = {categories_removed: @categories_removed}
        return data unless sync

        data.merge(inserted: (@legacy_ids - @here_ids).size, deleted: @doomed_ids.size)
      end

      def legacy_origin_searches
        ::Books::SavedSearch.where(id: ...RESERVED_CEILINGS.fetch("saved_searches"))
      end
```

Delete the old `finalize` (the new one replaces it). Class comment: add "A category deleted here is removed from the criteria and counted. In data_migration:sync it also deletes legacy-origin searches that legacy no longer has (spec §6)."

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/saved_search_migrator_sync_test.rb test/lib/services/books_migration/saved_search_migrator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/saved_search_migrator.rb web-app/test/lib/services/books_migration/saved_search_migrator_sync_test.rb
git commit -m "Saved searches drop deleted categories; sync deletes what legacy lacks"
```

---

### Task 6: Corrections — routed, waiting ones picked up later

**Files:**
- Modify: `web-app/app/lib/services/books_migration/correction_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/correction_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `BookRoute` (Task 1).
- Produces: sync-mode result data `{inserted:, dropped:, waiting:, missing:}`.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

class Services::BooksMigration::CorrectionMigratorSyncTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "corrections"

  setup do
    @survivor = ::Books::Book.create!(title: "Survivor")
  end

  def legacy_changeset(id, book_id)
    {
      "id" => id, "changeable_type" => "Book", "changeable_id" => book_id, "user_id" => nil, "change_data" => {},
      "notes" => "Fix it", "status" => 0, "applied_at" => nil,
      "created_at" => Time.utc(2025, 1, 2), "updated_at" => Time.utc(2025, 1, 2)
    }
  end

  def run_sync(rows, redirects: [], books_watermark: Float::INFINITY)
    migrator = Services::BooksMigration::CorrectionMigrator.new(sync: sync_scope(redirects: redirects, books_watermark: books_watermark))
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end

  test "puts a correction on a merged book's survivor" do
    result = run_sync([legacy_changeset(9_001, 200_001)], redirects: [["Books::Book", 200_001, @survivor.id]])

    assert result[:success], result[:error]
    assert_equal @survivor.id, ::Correction.find(9_001).correctable_id
    assert_equal 1, result[:data][:inserted]
  end

  test "drops a correction on a deleted book, and waits on one whose book has not arrived" do
    result = run_sync([legacy_changeset(9_002, 200_002), legacy_changeset(9_003, 200_003)],
      redirects: [["Books::Book", 200_002, nil]], books_watermark: 200_000)

    assert result[:success], result[:error]
    refute ::Correction.exists?(9_002)
    refute ::Correction.exists?(9_003)
    assert_equal [1, 1], result[:data].values_at(:dropped, :waiting)
  end

  test "a waiting correction lands once its book arrives" do
    ::Books::Book.create!(id: 200_003, title: "Arrived")

    run_sync([legacy_changeset(9_003, 200_003)], books_watermark: 200_005)

    assert_equal 200_003, ::Correction.find(9_003).correctable_id
  end

  test "skips a correction whose book is neither here nor redirected, as the full migration does" do
    result = run_sync([legacy_changeset(9_004, 150_000)], books_watermark: 200_000)

    assert result[:success], result[:error]
    refute ::Correction.exists?(9_004)
    assert_equal 1, result[:data][:missing]
  end

  test "counts only what it inserts" do
    run_sync([legacy_changeset(9_005, @survivor.id)])

    result = run_sync([legacy_changeset(9_005, @survivor.id)])

    assert_equal 0, result[:data][:inserted]
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/correction_migrator_sync_test.rb`
Expected: FAIL. 9_001 is skipped (book 200_001 is not here), and there are no stats keys.

- [ ] **Step 3: Implement**

In `correction_migrator.rb`:

```ruby
      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @user_ids = ::User.pluck(:id).to_set
        @declared = ::Books::Book.correctable_field_names.to_set
        @route = BookRoute.new(sync, book_ids_here: @book_ids) if sync
        @stats = {inserted: 0, dropped: 0, waiting: 0, missing: 0}
      end

      def extra_result_data
        sync ? @stats : {}
      end

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("corrections", attrs["id"])

        book_id = target_book_id(attrs)
        return if book_id.nil?

        mappable, unmappable = partition_change_data(attrs["change_data"])
        applied = attrs["status"] == LEGACY_STATUS_APPLIED

        # (keep the existing one-transaction comment block here unchanged)
        ::Correction.transaction do
          inserted = ::Correction.insert_all(
            [correction_row(attrs, book_id, unmappable, applied)],
            unique_by: nil, record_timestamps: false
          )
          @stats[:inserted] += inserted.length

          next if mappable.empty?

          ::CorrectionField.insert_all(
            mappable.map { |name, change| field_row(attrs, name, change, applied) },
            unique_by: nil, record_timestamps: false
          )
        end
      end

      # The book the correction lands on, or nil to skip it (counted). Sync mode
      # routes it through redirects (spec §6): a deleted book drops it, and a book
      # still inside the delay makes it wait; this migrator is insert-only, so a
      # later run picks it up. A book that is simply not here is skipped in both
      # modes, not raised -- a departure from ReviewMigrator's fail-loud rule: two
      # legacy changesets point at books legacy itself deleted, and a correction
      # for a deleted book has nothing to correct.
      def target_book_id(attrs)
        book_id = attrs["changeable_id"]
        routed = if sync
          @route.call(book_id)
        else
          @book_ids.include?(book_id) ? book_id : :missing
        end
        return routed if routed.is_a?(Integer)

        @stats[(routed == :deleted) ? :dropped : routed] += 1
        if routed == :missing
          Rails.logger.warn("CorrectionMigrator: skipped legacy changeset id=#{attrs["id"]}, no Books::Book #{book_id}")
        end
        nil
      end

      def correction_row(attrs, book_id, unmappable, applied)
        {
          id: attrs["id"],
          correctable_type: "Books::Book",
          correctable_id: book_id,
          # ... rest unchanged ...
        }
      end
```

Remove the old inline skip block (the `unless @book_ids.include?(book_id)` with its comment) from `upsert_row`. Its reasoning now lives on `target_book_id`.

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/correction_migrator_sync_test.rb test/lib/services/books_migration/correction_migrator_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/correction_migrator.rb web-app/test/lib/services/books_migration/correction_migrator_sync_test.rb
git commit -m "Sync routes corrections through redirects and waits on fresh books"
```

---

### Task 7: The user-data steps join the sync; rake wiring and guards

**Files:**
- Modify: `web-app/app/lib/services/books_migration/sync.rb`
- Modify: `web-app/lib/tasks/data_migration.rake`
- Test: `web-app/test/lib/services/books_migration/sync_test.rb`, `web-app/test/lib/tasks/data_migration_test.rb`

**Interfaces:**
- Consumes: the sync modes of Tasks 2-6.
- Produces: `Sync#steps` labels ending `... "book_images", "user_lists", "user_list_items", "reading_goals", "saved_searches", "recommendation_configs", "reviews", "review_summaries", "corrections"`. The `data_migration:sync` task invokes `user_favorites_lists:rebuild` after a successful run.

- [ ] **Step 1: Write the failing tests**

In `sync_test.rb`:

1. Add `include SequenceIsolation` and `isolate_sequences "reviews", "saved_searches", "corrections"` under `include BooksLegacySyncHelper`. The user-data steps now run in every test of this class, and three of them move sequences.
2. Extend `SYNC_MIGRATORS` with `UserListMigrator SavedSearchMigrator ReviewMigrator CorrectionMigrator`.
3. Add to `setup`, after the `NewsPostMigrator` stub:

```ruby
    Services::BooksMigration::ReadingGoalMigrator.stubs(:call).returns(success: true, data: {model: "Books::ReadingGoal", count: 0})
    Services::BooksMigration::RecommendationConfigMigrator.stubs(:call).returns(success: true, data: {model: "Books::RecommendationConfig", count: 0})
    Services::BooksMigration::UserListItemMigrator.any_instance.stubs(:legacy_items_for).returns([])
```

4. Append these tests:

```ruby
  test "runs the user-data steps after the catalog, in :all's order" do
    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal %w[book_images user_lists user_list_items reading_goals saved_searches recommendation_configs reviews review_summaries corrections],
      result.data[:steps].map(&:first).last(9)
  end

  test "carries a list item on a book the run brought over and waits on one still inside the delay" do
    user = users(:regular_user)
    ::Books::UserList.create!(id: 700, user: user, name: "Legacy", list_type: :custom)
    Services::BooksMigration::UserListMigrator.any_instance.stubs(:legacy_each).multiple_yields([{
      "id" => 700, "user_id" => user.id, "name" => "Legacy", "description" => nil, "list_type" => 4,
      "view_mode" => nil, "public" => true, "position" => 1, "created_at" => @old, "updated_at" => @old
    }])
    item = ->(id, book_id, position) {
      {"id" => id, "user_list_id" => 700, "book_id" => book_id, "position" => position, "read_date" => nil,
       "created_at" => @old, "updated_at" => @old}
    }
    Services::BooksMigration::UserListItemMigrator.any_instance.stubs(:legacy_items_for)
      .returns([item.call(1, 1_001, 1), item.call(2, 1_002, 2)])

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    assert result.success?, result.errors.inspect
    assert_equal [1_001], UserListItem.where(user_list_id: 700).pluck(:listable_id)
    items_outcome = result.data[:steps].to_h["user_list_items"]
    assert_equal 1, items_outcome[:data][:waiting]
  end

  test "a failed user-data step leaves the watermarks" do
    Services::BooksMigration::ReviewMigrator.stubs(:call).returns(success: false, error: "boom", data: {})

    result = Services::BooksMigration::Sync.call(legacy: legacy)

    refute result.success?
    assert_includes result.errors.first, "reviews failed: boom"
    assert_equal({"books" => 1_000, "authors" => 500, "book_identifiers" => 5_000}, watermarks)
  end
```

In `data_migration_test.rb`:

1. In `setup`, after the `load` block, load the favorites tasks and stub the rebuild, so the existing sync tests do not run it:

```ruby
    load Rails.root.join("lib/tasks/lists/user_favorites.rake").to_s unless Rake::Task.task_defined?("user_favorites_lists:rebuild")
    Rake::Task["user_favorites_lists:rebuild"].stubs(:invoke)
```

   The existing "all refuses once the sync watermarks exist" test loads the same file under the same guard. Leave it as it is.
2. Add `data_migration:user_lists data_migration:user_list_items data_migration:saved_searches data_migration:reviews data_migration:corrections` to the reenable list.
3. Replace the test `the user-data tasks are not guarded` with:

```ruby
  test "the user-data tasks the sync does not replace are not guarded" do
    %w[users reading_goals recommendation_configs news_posts description_safety_net].each do |name|
      refute_includes Rake::Task["data_migration:#{name}"].prerequisites, "refuse_after_sync_init", name
    end
  end

  test "the user-data tasks the sync replaces refuse after sync_init" do
    %w[user_lists user_list_items saved_searches reviews corrections].each do |name|
      assert_includes Rake::Task["data_migration:#{name}"].prerequisites, "refuse_after_sync_init", name
    end
  end
```

4. Append:

```ruby
  test "sync rebuilds the favorites lists after a successful run" do
    Services::BooksMigration::Sync.stubs(:call).returns(sync_result)
    Rake::Task["user_favorites_lists:rebuild"].expects(:invoke).once

    capture_io { Rake::Task["data_migration:sync"].invoke }
  end

  test "a failed sync does not rebuild the favorites lists" do
    Services::BooksMigration::Sync.stubs(:call).returns(sync_result(success: false, errors: ["reviews failed: boom"]))
    Rake::Task["user_favorites_lists:rebuild"].expects(:invoke).never

    capture_io { assert_raises(SystemExit) { Rake::Task["data_migration:sync"].invoke } }
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/sync_test.rb test/lib/tasks/data_migration_test.rb`
Expected: FAIL. The step labels end at `book_images`, no list item is written, the five tasks are unguarded, and the rebuild is never invoked.

- [ ] **Step 3: Implement**

`sync.rb`: append to `steps`, after `book_images`:

```ruby
          ["book_images", -> { BookImageMigrator.call(sync: scope) }],
          ["user_lists", -> { UserListMigrator.call(sync: scope) }],
          ["user_list_items", -> { UserListItemMigrator.call(sync: scope) }],
          ["reading_goals", -> { ReadingGoalMigrator.call }],
          ["saved_searches", -> { SavedSearchMigrator.call(sync: scope) }],
          ["recommendation_configs", -> { RecommendationConfigMigrator.call }],
          ["reviews", -> { ReviewMigrator.call(sync: scope) }],
          # upsert_all bypassed Review's after_commit, as in the reviews rake task.
          ["review_summaries", -> { ::Services::Reviews::SummaryRecalculator.backfill_all! }],
          ["corrections", -> { CorrectionMigrator.call(sync: scope) }]
```

Replace the class comment with:

```ruby
    # data_migration:sync (spec §5, §6): brings over only what is new on legacy, in
    # :all's dependency order, and makes legacy users' data match legacy, then
    # queues search indexing for what it inserted and advances the watermarks. Any
    # failed step stops the run with the watermarks unchanged. Catalog steps are
    # insert-only and user-data steps converge on legacy, so the next run retries
    # safely. The rake task rebuilds the favorites lists after a successful run.
```

`data_migration.rake`:

1. In `task sync:`, after `pp(indexed: result.data[:indexed])`, add:

```ruby
    # It reads the lists the sync just rewrote, as at the end of :all.
    Rake::Task["user_favorites_lists:rebuild"].invoke
```

2. Change its `desc` to: `"Bring over what is new on legacy and match legacy users' data to it (FINAL=1 drops the 24h delay)"`.
3. Extend the guarded list and its comment:

```ruby
  # Each task the sync replaces or retires refuses on its own as well, so running
  # one by hand after sync_init cannot undo cleanup either. The user-data tasks the
  # sync replaces refuse too: their full-migration mode ignores redirects and never
  # deletes. users, reading_goals, recommendation_configs, news_posts, the
  # description safety net and penalties:reconcile stay runnable.
  %i[languages authors books book_authors editions identifiers edition_amazon_identifiers categories
    category_items book_attributes book_type_categories countries author_countries book_countries
    external_links lists list_items ranking_configurations ranked_lists penalties list_penalties
    book_descriptions author_descriptions book_images
    user_lists user_list_items saved_searches reviews corrections].each do |name|
    task name => :refuse_after_sync_init
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/ test/lib/tasks/data_migration_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books_migration/sync.rb web-app/lib/tasks/data_migration.rake web-app/test/lib/services/books_migration/sync_test.rb web-app/test/lib/tasks/data_migration_test.rb
git commit -m "Sync runs the user-data steps and rebuilds the favorites lists"
```

---

### Task 8: The report's user-data half

**Files:**
- Modify: `web-app/app/lib/services/books_migration/legacy_source.rb`
- Create: `web-app/app/lib/services/books_migration/user_data_diff.rb`
- Modify: `web-app/app/lib/services/books_migration/sync_report.rb`
- Modify: `web-app/lib/tasks/data_migration.rake` (`sync_report`)
- Modify: `web-app/test/support/books_legacy_sync_helper.rb` (`FakeLegacySource`)
- Test: `web-app/test/lib/services/books_migration/user_data_diff_test.rb`, `sync_report_test.rb`, `web-app/test/lib/tasks/data_migration_test.rb`

**Interfaces:**
- Consumes: `BookRoute`, `UserListItemPlan`, and the migrators' sync result keys (Tasks 1-6).
- Produces: `UserDataDiff.call(scope:, legacy: LegacySource.new)` → Hash with keys `:users {legacy here inserted updated deleted_on_legacy}`, `:user_lists {legacy here inserted updated deleted}`, `:user_list_items {legacy here inserted deleted dropped waiting collisions missing}`, `:reviews {legacy here inserted updated deleted dropped waiting collisions held_by_new_app missing}`, `:saved_searches {legacy here inserted updated deleted}`, `:reading_goals {legacy here deleted}`, `:recommendation_configs {legacy here}`, `:corrections {legacy here inserted dropped waiting missing}`. `SyncReport.render(plan, user_data: nil)`.

- [ ] **Step 1: Extend the fake legacy source** (test support, no assertion of its own)

In `FakeLegacySource`, add keyword arguments and readers:

```ruby
    def initialize(book_rows: [], author_rows: [], book_identifier_rows: [], book_ids: nil, author_ids: nil,
      category_ids: [], books_updated_count: 0, max_book_identifier_id: 0,
      user_versions: {}, user_list_versions: {}, saved_search_versions: {}, review_rows: [],
      correction_rows: [], reading_goal_ids: [], recommendation_config_count: 0, user_list_items: [])
      # ... existing assignments ...
      @user_versions = user_versions
      @user_list_versions = user_list_versions
      @saved_search_versions = saved_search_versions
      @review_rows = review_rows
      @correction_rows = correction_rows
      @reading_goal_ids = reading_goal_ids
      @recommendation_config_count = recommendation_config_count
      @user_list_items = user_list_items
    end

    attr_reader :category_ids, :max_book_identifier_id, :user_versions, :user_list_versions,
      :saved_search_versions, :review_rows, :correction_rows, :reading_goal_ids, :recommendation_config_count

    # Same shape and digest as LegacySource's SQL: md5 of the sorted book ids joined by ",".
    def user_list_item_digests
      @user_list_items.group_by { |row| row["user_list_id"] }.transform_values do |rows|
        ids = rows.map { |row| row["book_id"] }.sort
        [ids.size, Digest::MD5.hexdigest(ids.join(","))]
      end
    end

    def user_list_items_for(list_ids) = @user_list_items.select { |row| list_ids.include?(row["user_list_id"]) }
```

Update the class comment: "Catalog rows are [id, created_at] pairs in id order. user_list_items are legacy attribute hashes; review_rows are [id, user_id, book_id, updated_at], newest first."

- [ ] **Step 2: Write the failing tests**

`user_data_diff_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::UserDataDiffTest < ActiveSupport::TestCase
  include BooksLegacySyncHelper
  include SequenceIsolation

  isolate_sequences "reviews", "corrections"

  setup do
    ::Review.delete_all
    @user = users(:regular_user)
    @editor = users(:editor_user)
    @t = Time.utc(2025, 1, 1)
  end

  def diff(legacy, redirects: [], books_watermark: 200_000)
    Services::BooksMigration::UserDataDiff.call(
      scope: sync_scope(redirects: redirects, books_watermark: books_watermark), legacy: legacy
    )
  end

  test "counts users to insert and update, and those legacy deleted" do
    User.insert_all([
      {id: 5_001, email: "same@example.com", created_at: @t, updated_at: @t},
      {id: 5_002, email: "older@example.com", created_at: @t, updated_at: @t},
      {id: 5_003, email: "gone@example.com", created_at: @t, updated_at: @t}
    ])
    legacy = FakeLegacySource.new(user_versions: {5_001 => @t, 5_002 => @t + 1.day, 5_004 => @t})

    assert_equal({legacy: 3, here: 3, inserted: 1, updated: 1, deleted_on_legacy: 1}, diff(legacy)[:users])
  end

  test "counts saved searches and reading goals legacy deleted" do
    ::Books::SavedSearch.create!(id: 15_001, user: @user, name: "Gone", criteria: {"genre_match_mode" => "any"})
    legacy = FakeLegacySource.new(saved_search_versions: {15_002 => @t}, reading_goal_ids: [1])

    result = diff(legacy)

    assert_equal({legacy: 1, here: 1, inserted: 1, updated: 0, deleted: 1}, result[:saved_searches])
    assert_equal({legacy: 1, here: 0, deleted: 0}, result[:reading_goals])
  end

  test "only lists whose items differ are planned item by item" do
    book = ::Books::Book.create!(title: "Listed")
    list = ::Books::UserList.create!(id: 900, user: @user, name: "Same", list_type: :custom)
    UserListItem.create!(user_list: list, listable: book, position: 1)
    same = {"id" => 1, "user_list_id" => 900, "book_id" => book.id, "position" => 1}
    legacy = FakeLegacySource.new(user_list_versions: {900 => @t}, user_list_items: [same])
    legacy.expects(:user_list_items_for).never

    counts = diff(legacy)[:user_list_items]

    assert_equal({legacy: 1, here: 1, inserted: 0, deleted: 0}, counts.slice(:legacy, :here, :inserted, :deleted))
  end

  test "counts list items and reviews whose book is neither here nor redirected as missing" do
    legacy = FakeLegacySource.new(
      user_list_versions: {901 => @t},
      user_list_items: [{"id" => 5, "user_list_id" => 901, "book_id" => 150_000, "position" => 1}],
      review_rows: [[300, @user.id, 150_000, @t]]
    )

    result = diff(legacy)

    assert_equal 1, result[:user_list_items][:missing]
    assert_equal 1, result[:reviews][:missing]
  end

  test "books the run itself brings over count as here" do
    legacy = FakeLegacySource.new(review_rows: [[301, @user.id, 200_500, @t]])

    result = Services::BooksMigration::UserDataDiff.call(
      scope: sync_scope(book_ids: [200_500], books_watermark: 200_500), legacy: legacy
    )

    assert_equal({inserted: 1, missing: 0, waiting: 0}, result[:reviews].slice(:inserted, :missing, :waiting))
  end

  test "its numbers equal what the following sync does" do
    init_watermarks(books: 200_000, authors: 100_000, book_identifiers: 0)
    plain = ::Books::Book.create!(id: 199_001, title: "Plain")
    survivor = ::Books::Book.create!(id: 199_002, title: "Survivor")
    other = ::Books::Book.create!(id: 199_005, title: "Removed From The List On Legacy")
    RecordRedirect.create!(item_type: "Books::Book", from_id: 199_003, to_id: survivor.id)
    RecordRedirect.create!(item_type: "Books::Book", from_id: 199_004, to_id: nil)

    kept_list = ::Books::UserList.create!(id: 800, user: @user, name: "Kept", list_type: :custom)
    gone_list = ::Books::UserList.create!(id: 801, user: @user, name: "Gone", list_type: :custom)
    UserListItem.create!(user_list: kept_list, listable: plain, position: 1)
    UserListItem.create!(user_list: kept_list, listable: other, position: 2)
    UserListItem.create!(user_list: gone_list, listable: plain, position: 1)
    ::Review.create!(id: 900, user: @user, reviewable: plain, rating: 3)
    ::Review.create!(id: 250_900, user: @editor, reviewable: survivor, rating: 3)

    list_row = ->(id) {
      {"id" => id, "user_id" => @user.id, "name" => "L#{id}", "description" => nil, "list_type" => 4,
       "view_mode" => nil, "public" => true, "position" => 1, "created_at" => @t, "updated_at" => @t}
    }
    item = ->(id, list_id, book_id, position) {
      {"id" => id, "user_list_id" => list_id, "book_id" => book_id, "position" => position, "read_date" => nil,
       "created_at" => @t, "updated_at" => @t}
    }
    review = ->(id, user, book_id) {
      {"id" => id, "user_id" => user.id, "book_id" => book_id, "title" => nil, "body" => nil, "rating" => 4,
       "created_at" => @t, "updated_at" => @t}
    }
    changeset = ->(id, book_id) {
      {"id" => id, "changeable_type" => "Book", "changeable_id" => book_id, "user_id" => nil, "change_data" => {},
       "notes" => "n", "status" => 0, "applied_at" => nil, "created_at" => @t, "updated_at" => @t}
    }

    lists = [list_row.call(800), list_row.call(802)]
    items = [
      item.call(1, 800, plain.id, 1), item.call(2, 800, 199_003, 2), item.call(3, 800, survivor.id, 3),
      item.call(4, 802, 199_004, 1), item.call(5, 802, 200_050, 2), item.call(6, 802, plain.id, 3)
    ]
    reviews = [
      review.call(903, @user, 199_003), review.call(902, @user, survivor.id),
      review.call(901, @editor, survivor.id), review.call(899, @user, 200_050), review.call(898, @editor, 199_004)
    ]
    changesets = [changeset.call(9_501, plain.id), changeset.call(9_502, 199_004), changeset.call(9_503, 200_050)]

    legacy = FakeLegacySource.new(
      user_list_versions: lists.to_h { |row| [row["id"], row["updated_at"]] },
      user_list_items: items,
      review_rows: reviews.map { |row| row.values_at("id", "user_id", "book_id", "updated_at") },
      correction_rows: changesets.map { |row| row.values_at("id", "changeable_id") }
    )
    scope = Services::BooksMigration::SyncPlan.build(legacy: legacy).scope
    expected = Services::BooksMigration::UserDataDiff.call(scope: scope, legacy: legacy)

    run = ->(klass, rows) {
      migrator = klass.new(sync: scope)
      migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
      migrator.call
    }
    list_result = run.call(Services::BooksMigration::UserListMigrator, lists)
    items_migrator = Services::BooksMigration::UserListItemMigrator.new(sync: scope)
    items_migrator.define_singleton_method(:legacy_items_for) { |ids| items.select { |row| ids.include?(row["user_list_id"]) } }
    item_result = items_migrator.call
    review_result = run.call(Services::BooksMigration::ReviewMigrator, reviews)
    correction_result = run.call(Services::BooksMigration::CorrectionMigrator, changesets)

    item_keys = %i[inserted deleted dropped waiting collisions]
    review_keys = item_keys + [:held_by_new_app]
    correction_keys = %i[inserted dropped waiting missing]
    assert_equal({inserted: 1, deleted: 1}, expected[:user_lists].slice(:inserted, :deleted))
    assert_equal expected[:user_lists].slice(:inserted, :deleted), list_result[:data].slice(:inserted, :deleted)
    assert_equal({inserted: 2, deleted: 1, dropped: 1, waiting: 1, collisions: 1}, expected[:user_list_items].slice(*item_keys))
    assert_equal expected[:user_list_items].slice(*item_keys), item_result[:data].slice(*item_keys)
    assert_equal({inserted: 1, deleted: 1, dropped: 1, waiting: 1, collisions: 1, held_by_new_app: 1},
      expected[:reviews].slice(*review_keys))
    assert_equal expected[:reviews].slice(*review_keys), review_result[:data].slice(*review_keys)
    assert_equal({inserted: 1, dropped: 1, waiting: 1, missing: 0}, expected[:corrections].slice(*correction_keys))
    assert_equal expected[:corrections].slice(*correction_keys), correction_result[:data].slice(*correction_keys)
  end
end
```

Append to `sync_report_test.rb` (check its existing helper for building a catalog report hash and reuse it as `catalog_report`; if it has none, copy the hash one of its tests builds into a `catalog_report` method):

```ruby
  def user_data
    {
      users: {legacy: 69_602, here: 69_590, inserted: 12, updated: 40, deleted_on_legacy: 2},
      user_lists: {legacy: 10, here: 9, inserted: 2, updated: 3, deleted: 1},
      user_list_items: {legacy: 100, here: 98, inserted: 5, deleted: 3, dropped: 1, waiting: 2, collisions: 1, missing: 0},
      reviews: {legacy: 20, here: 19, inserted: 1, updated: 2, deleted: 0, dropped: 0, waiting: 0, collisions: 1, held_by_new_app: 0, missing: 0},
      saved_searches: {legacy: 5, here: 5, inserted: 0, updated: 1, deleted: 0},
      reading_goals: {legacy: 3, here: 3, deleted: 0},
      recommendation_configs: {legacy: 33, here: 33},
      corrections: {legacy: 800, here: 798, inserted: 2, dropped: 0, waiting: 0, missing: 2}
    }
  end

  test "renders the user-data half when given" do
    out = Services::BooksMigration::SyncReport.new(catalog_report, user_data).render

    assert_includes out, "User data"
    assert_match(/users\s+69,602\s+69,590\s+12\s+40\s+—/, out)
    assert_includes out, "2 deleted on legacy (counted, not applied)"
    assert_match(/user_list_items\s+100\s+98\s+5\s+—\s+3\s+1\s+2/, out)
    refute_includes out, "MISSING"
  end

  test "warns when list items or reviews would fail the sync" do
    data = user_data
    data[:reviews] = data[:reviews].merge(missing: 4)

    out = Services::BooksMigration::SyncReport.new(catalog_report, data).render

    assert_includes out, "MISSING: 4"
  end

  test "without user data it prints only the catalog" do
    refute_includes Services::BooksMigration::SyncReport.new(catalog_report).render, "User data"
  end
```

In `data_migration_test.rb`, replace the `sync_report prints the plan and runs nothing` test:

```ruby
  test "sync_report prints the plan with its user data and runs nothing" do
    Services::BooksMigration::Sync.expects(:call).never
    plan = mock("plan")
    plan.stubs(:scope).returns(:the_scope)
    Services::BooksMigration::SyncPlan.expects(:build).with(final: false).returns(plan)
    Services::BooksMigration::UserDataDiff.expects(:call).with(scope: :the_scope).returns(:the_diff)
    Services::BooksMigration::SyncReport.expects(:render).with(plan, user_data: :the_diff).returns("REPORT")

    out, _err = with_env("FINAL", nil) { capture_io { Rake::Task["data_migration:sync_report"].invoke } }

    assert_includes out, "REPORT"
  end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/services/books_migration/user_data_diff_test.rb test/lib/services/books_migration/sync_report_test.rb test/lib/tasks/data_migration_test.rb`
Expected: FAIL. `uninitialized constant Services::BooksMigration::UserDataDiff`, `SyncReport#initialize` takes one argument, and `sync_report` renders without `user_data:`.

- [ ] **Step 4: Implement**

`legacy_source.rb`, before `private`:

```ruby
      def user_versions = LegacyBooks::User.pluck(:id, :updated_at).to_h

      def user_list_versions = LegacyBooks::UserList.pluck(:id, :updated_at).to_h

      def saved_search_versions = LegacyBooks::SavedSearch.pluck(:id, :updated_at).to_h

      # Newest first: ReviewMigrator keeps the newer of two reviews that collide.
      def review_rows = LegacyBooks::Review.order(id: :desc).pluck(:id, :user_id, :book_id, :updated_at)

      def correction_rows = LegacyBooks::Changeset.pluck(:id, :changeable_id)

      def reading_goal_ids = LegacyBooks::ReadingGoal.pluck(:id)

      def recommendation_config_count = LegacyBooks::RecommendationConfig.count

      # list id => [item count, md5 of its book ids in id order]. UserDataDiff
      # computes the same here, so only lists that differ are compared item by item.
      def user_list_item_digests
        LegacyBooks::UserListBook.group(:user_list_id)
          .pluck(:user_list_id, Arel.sql("COUNT(*)"), Arel.sql("md5(string_agg(book_id::text, ',' ORDER BY book_id))"))
          .to_h { |list_id, count, digest| [list_id, [count, digest]] }
      end

      def user_list_items_for(list_ids) = LegacyBooks::UserListBook.where(user_list_id: list_ids).map(&:attributes)
```

Create `web-app/app/lib/services/books_migration/user_data_diff.rb`:

```ruby
module Services
  module BooksMigration
    # The user-data half of data_migration:sync_report (spec §7): per table, what
    # the next sync would insert, update, delete and drop. Read-only.
    #
    # Insert and delete compare ids. Update compares updated_at: these migrators
    # keep legacy's timestamps, so a newer legacy row has changed. It is a report
    # number only, because the sync overwrites every legacy-origin row anyway. List
    # items compare a digest per list on both sides, and only the lists that differ
    # go through UserListItemPlan, the same plan the sync applies. Reviews and
    # corrections route and dedupe exactly as their migrators do.
    class UserDataDiff
      LIST_BATCH = 1_000

      def self.call(scope:, legacy: LegacySource.new)
        new(scope: scope, legacy: legacy).call
      end

      def initialize(scope:, legacy:)
        @legacy = legacy
        # The run's own new books count as here: the user-data steps run after them.
        @route = BookRoute.new(scope, book_ids_here: ::Books::Book.pluck(:id).to_set | scope.book_ids)
      end

      def call
        list_versions = @legacy.user_list_versions
        {
          users: users,
          user_lists: versioned(list_versions, ::Books::UserList, "user_lists"),
          user_list_items: user_list_items(list_versions.keys),
          reviews: reviews,
          saved_searches: versioned(@legacy.saved_search_versions, ::Books::SavedSearch, "saved_searches"),
          reading_goals: reading_goals,
          recommendation_configs: {legacy: @legacy.recommendation_config_count, here: ::Books::RecommendationConfig.count},
          corrections: corrections
        }
      end

      private

      def ceiling(table) = RESERVED_CEILINGS.fetch(table)

      # Users are never deleted (spec §6), so a legacy deletion is only counted.
      def users
        counts = versioned(@legacy.user_versions, ::User, "users")
        counts.merge(deleted_on_legacy: counts.delete(:deleted))
      end

      def versioned(legacy_versions, model, table)
        here = model.where(id: ...ceiling(table)).pluck(:id, :updated_at).to_h
        {
          legacy: legacy_versions.size,
          here: here.size,
          inserted: legacy_versions.keys.count { |id| !here.key?(id) },
          updated: legacy_versions.count { |id, updated_at| here.key?(id) && updated_at > here[id] },
          deleted: here.keys.count { |id| !legacy_versions.key?(id) }
        }
      end

      def user_list_items(legacy_list_ids)
        legacy_digests = @legacy.user_list_item_digests
        here_digests = here_item_digests
        counts = {
          legacy: legacy_digests.values.sum(&:first), here: here_digests.values.sum(&:first),
          inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0, missing: 0
        }
        changed = legacy_list_ids.reject { |id| legacy_digests[id] == here_digests[id] }
        changed.each_slice(LIST_BATCH) do |list_ids|
          here = ::UserListItem.where(user_list_id: list_ids).pluck(:id, :user_list_id, :listable_type, :listable_id)
          plan = UserListItemPlan.call(@legacy.user_list_items_for(list_ids), here, @route)
          counts[:inserted] += plan.inserted
          counts[:deleted] += plan.stale_ids.size
          counts[:missing] += plan.missing.size
          %i[dropped waiting collisions].each { |key| counts[key] += plan.public_send(key) }
        end
        counts
      end

      def here_item_digests
        ::UserListItem.joins(:user_list)
          .where(user_lists: {type: "Books::UserList", id: ...ceiling("user_lists")})
          .group(:user_list_id)
          .pluck(
            :user_list_id, Arel.sql("COUNT(*)"),
            Arel.sql("md5(string_agg(user_list_items.listable_id::text, ',' ORDER BY user_list_items.listable_id))")
          )
          .to_h { |list_id, count, digest| [list_id, [count, digest]] }
      end

      # Mirrors ReviewMigrator: newest first, the first row per user and routed
      # book wins, and a key a new-app review holds stays the new-app review's.
      def reviews
        counts = {dropped: 0, waiting: 0, collisions: 0, held_by_new_app: 0, missing: 0}
        new_app_keys = ::Review.where(reviewable_type: "Books::Book", id: ceiling("reviews")..)
          .pluck(:user_id, :reviewable_id).to_set
        seen = Set.new
        kept = {}
        rows = @legacy.review_rows
        rows.each do |id, user_id, book_id, updated_at|
          routed = @route.call(book_id)
          if routed.is_a?(Symbol)
            counts[(routed == :deleted) ? :dropped : routed] += 1
          elsif !seen.add?([user_id, routed])
            counts[:collisions] += 1
          elsif new_app_keys.include?([user_id, routed])
            counts[:held_by_new_app] += 1
          else
            kept[id] = updated_at
          end
        end

        here = ::Review.where(reviewable_type: "Books::Book", id: ...ceiling("reviews")).pluck(:id, :updated_at).to_h
        counts.merge(
          legacy: rows.size,
          here: here.size,
          inserted: kept.keys.count { |id| !here.key?(id) },
          updated: kept.count { |id, updated_at| here.key?(id) && updated_at > here[id] },
          deleted: here.keys.count { |id| !kept.key?(id) }
        )
      end

      def reading_goals
        legacy_ids = @legacy.reading_goal_ids.to_set
        here = ::Books::ReadingGoal.where(id: ...ReadingGoalMigrator::RESERVED_ID_FLOOR).pluck(:id)
        {legacy: legacy_ids.size, here: here.size, deleted: here.count { |id| !legacy_ids.include?(id) }}
      end

      # Mirrors CorrectionMigrator: insert-only, so only ids not here count, while
      # dropped, waiting and missing count every legacy row on such a book.
      def corrections
        rows = @legacy.correction_rows
        here = ::Correction.where(id: ...ceiling("corrections")).pluck(:id).to_set
        counts = {legacy: rows.size, here: here.size, inserted: 0, dropped: 0, waiting: 0, missing: 0}
        rows.each do |id, book_id|
          routed = @route.call(book_id)
          if routed.is_a?(Integer)
            counts[:inserted] += 1 unless here.include?(id)
          else
            counts[(routed == :deleted) ? :dropped : routed] += 1
          end
        end
        counts
      end
    end
  end
end
```

`sync_report.rb`:

```ruby
      USER_COLUMNS = "%-24s %10s %10s %8s %8s %8s %8s %8s  %s"
      USER_KEYS = %i[legacy here inserted updated deleted dropped waiting].freeze

      def self.render(plan, user_data: nil)
        new(plan.report, user_data).render
      end

      def initialize(report, user_data = nil)
        @report = report
        @user_data = user_data
      end

      def render
        lines = [
          # ... the existing catalog lines, unchanged ...
        ]
        lines += ["", *user_data_lines] if @user_data
        lines.join("\n")
      end
```

Add these private methods:

```ruby
      def user_data_lines
        data = @user_data
        [
          format(USER_COLUMNS, "User data", "legacy", "here", "insert", "update", "delete", "dropped", "waiting", ""),
          user_line("users", data[:users], "#{number(data[:users][:deleted_on_legacy])} deleted on legacy (counted, not applied)"),
          user_line("user_lists", data[:user_lists]),
          user_line("user_list_items", data[:user_list_items], "#{number(data[:user_list_items][:collisions])} merge collisions"),
          user_line("reviews", data[:reviews],
            "#{number(data[:reviews][:collisions])} collisions, #{number(data[:reviews][:held_by_new_app])} held by a new-app review"),
          user_line("saved_searches", data[:saved_searches]),
          user_line("reading_goals", data[:reading_goals]),
          user_line("recommendation_configs", data[:recommendation_configs]),
          user_line("corrections", data[:corrections], "#{number(data[:corrections][:missing])} on books not here (skipped)"),
          missing_line
        ].compact
      end

      def user_line(label, counts, note = "")
        values = USER_KEYS.map { |key| counts.key?(key) ? number(counts[key]) : "—" }
        format(USER_COLUMNS, "  #{label}", *values, note)
      end

      # List items and reviews on a book that is neither here nor redirected
      # fail the sync (a book removed without callbacks), so say so up front.
      def missing_line
        missing = @user_data[:user_list_items][:missing] + @user_data[:reviews][:missing]
        return if missing.zero?

        "  MISSING: #{number(missing)} list items or reviews name a book that is neither here nor redirected; " \
          "the sync will fail on them"
      end
```

Update the class comment: "Prints a SyncPlan's report (spec §7): what data_migration:sync would do now, and, given UserDataDiff's numbers, the user-data half."

`data_migration.rake`, the `sync_report` task:

```ruby
  desc "Print what data_migration:sync would do now (read-only; safe in production at any time)"
  task sync_report: :environment do
    plan = Services::BooksMigration::SyncPlan.build(final: ActiveModel::Type::Boolean.new.cast(ENV["FINAL"]) || false)
    puts Services::BooksMigration::SyncReport.render(plan, user_data: Services::BooksMigration::UserDataDiff.call(scope: plan.scope))
  end
```

- [ ] **Step 5: Run to verify they pass**

Run: `bin/rails test test/lib/services/books_migration/ test/lib/tasks/data_migration_test.rb`
Expected: PASS.

If the equality test's expected literals disagree with what the diff computes, re-derive them from the fixture comments before touching any production code. The literals were worked out by hand:
- **user_lists:** 802 inserted, 801 deleted.
- **items, list 800:** plain is kept, survivor is inserted via 199_003, item 3 collides, and `other` is stale, so it is deleted.
- **items, list 802:** 199_004 is dropped, 200_050 waits, and plain is inserted.
- **reviews:** 903 is inserted, 902 collides, 901 is held by 250_900, 899 waits, 898 is dropped, and 900 is deleted.
- **corrections:** 9_501 is inserted, 9_502 is dropped, and 9_503 waits.

A disagreement between the two sides is a real finding. Fix the side that departs from its migrator.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/books_migration/legacy_source.rb web-app/app/lib/services/books_migration/user_data_diff.rb web-app/app/lib/services/books_migration/sync_report.rb web-app/lib/tasks/data_migration.rake web-app/test/support/books_legacy_sync_helper.rb web-app/test/lib/services/books_migration/user_data_diff_test.rb web-app/test/lib/services/books_migration/sync_report_test.rb web-app/test/lib/tasks/data_migration_test.rb
git commit -m "sync_report prints the user-data half, counted as the sync counts"
```

---

### Task 9: Docs for a cutover with no truncate

**Files:**
- Rewrite: `docs/launch-todo.md`
- Modify: `docs/features/books-legacy-sync.md`, `AGENTS.md`, `docs/features/goodreads-import.md`, `docs/features/books-author-enrichment.md`, `docs/features/v1-user-migration.md`

No tests (documentation). The completion check is Step 3's grep.

- [ ] **Step 1: Rewrite `docs/launch-todo.md`** with exactly this content:

````markdown
# Books launch todo

The manual steps for moving thegreatestbooks.org onto this app, and for the weeks after. Nothing here
runs on deploy. When a merge leaves a step that someone has to run by hand at launch, add it here, with
a pointer to the doc that explains it.

Production's books data is not truncated before launch any more. Until the switch-over (section 2) the
weekly `data_migration:all` keeps it in step with legacy. From the switch-over on, this database's
books catalog is the master: merges, deletes and fixes made here stay, and the weekly
`data_migration:sync` brings over only what is new on legacy while keeping legacy users' lists,
reviews and saved searches matched to legacy. Details: `docs/features/books-legacy-sync.md`.

## 1. Until the switch-over: the weekly full migration

Run these in this order after each `data_migration:all`.

1. **`bin/rails data_migration:all`.** It includes `penalties:reconcile`, `author_countries`,
   `recommendation_configs` and the favorites-list rebuild.
2. **Search and rankings.** The migrators load with search indexing off, so run
   `bin/rails search:books:recreate_and_reindex_all`. Then recalculate the books list weights and
   rankings. Author rankings follow from the book rankings: `Books::CalculateAuthorRankingsJob` runs
   on the 04:00 UTC cron, or by hand.
3. **Cover images.** Make sure Sidekiq is up, because this queues about 148k jobs. Then run
   `bin/rails data_migration:book_images`. It is idempotent, and the primary-image count should
   come out close to 37,296.
4. **V1 Firebase accounts.** Follow the four steps in `docs/features/v1-user-migration.md`,
   "Running it": export, import, `firebase:backfill_v1_uids`, then shred the file. The import comes
   before the backfill. The user overwrite resets `users.auth_uid`, so the backfill runs every time.

The duplicate sweep can already run: `bin/rails "books:find_duplicates[100]"` first, then `[all]`
(about 21k ranked books on the `serial` queue, days). It only writes candidate pairs, and those
survive the weekly run. Do not merge, delete or edit books yet: the next `:all` would undo it.

## 2. Switching over (once)

1. **Before** starting the final `:all`, read legacy's highest `book_identifiers` id:
   `bin/rails runner 'puts LegacyBooks::BookIdentifier.maximum(:id)'`.
2. Run the final `data_migration:all` and the section 1 steps after it.
3. `BOOK_IDENTIFIERS_FROM=<that id> bin/rails data_migration:sync_init`.

From then on `data_migration:all`, the catalog tasks and the user-data tasks the sync replaces refuse
to run. Cleanup can start (section 4).

## 3. Every week after the switch-over

1. **`bin/rails data_migration:sync_report`.** Read-only, safe any time. A `MISSING` line means the
   sync will fail on rows whose book was removed without callbacks. A large delete count means
   legacy looks wrong: check it before syncing.
2. **`bin/rails data_migration:sync`.** It brings over new books and authors (with their cover
   images and search indexing), new book identifiers, users, user lists and list items, reading
   goals, saved searches, recommendation settings, reviews and corrections, then rebuilds the
   favorites lists. A step that would delete more than 5% of a table (and over 500 rows) refuses;
   if the deletions are real, re-run with `SYNC_ALLOW_DELETES=1`.
3. **`bin/rails firebase:backfill_v1_uids`.** The user overwrite still resets `auth_uid` from legacy.
4. **`bin/rails books:goodreads_replay:apply`.** The sync puts legacy users' list items and reviews
   back the way legacy has them, which undoes the replay's approved relinks until this re-applies
   them.
5. **Rankings.** The books list weights and book rankings. Author rankings follow.

## 4. Cleanup, after the switch-over

These change the catalog, so they wait for section 2. Each runs once, not after every sync, because
the sync never undoes them.

1. **Stored-name normalization.** `ANALYZE` the tables that have `lower()` expression indexes. Then
   run `bin/rails books:normalize_names:report`, and after reading its output,
   `books:normalize_names:apply`.
2. **Open Library key backfill.** Run `bin/rails "books:ol_backfill[100]"`, read
   `bin/rails books:ol_backfill_report`, then `bin/rails "books:ol_backfill[all]"`. It checks or adds an
   Open Library key on every book, ranked first. Top-ranked books ran at about 4 books a minute before
   the fast pass was sped up, so the full run is likely 2-4 weeks and the top few thousand ranked books
   finish in the first days. It shares Open Library's one `/resolve` slot with the wizard and the
   Goodreads replay, so all of them slow down while it runs. It pauses 4 seconds after each
   `/resolve` so the others can get the slot, but do not run the Goodreads replay or the
   legacy-import finishing steps while it runs: when they cannot get the slot they decide rows
   without Open Library. Every merge deploys, and a deploy stops a running backfill (it is not
   requeued), so expect to run the task again during the weeks it runs; it carries on, because
   logged books are skipped. Details: `docs/features/open-library-backfill.md`.
3. **Duplicates.** Review the pairs the sweep found in the Duplicates queue and merge them. Every
   merge is recorded as a redirect, so the sync never brings the merged book back.
4. **The Goodreads replay.** Run these in order. Sidekiq must be running for `resolve`.

   ```bash
   bin/rails books:goodreads:seed_legacy_pages   # legacy scraped Goodreads pages into the page cache (~39k)
   bin/rails books:goodreads_replay:load         # the legacy imports: uploads (legacy R2) and rows
   bin/rails books:goodreads_replay:fix_slugs
   bin/rails books:goodreads_replay:apply
   bin/rails books:goodreads_replay:resolve      # queues jobs; re-run until both counts are 0
   bin/rails books:goodreads_replay:duplicates
   bin/rails books:goodreads_replay:junk
   bin/rails books:goodreads_replay:apply
   bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
   ```

   - `seed_legacy_pages` only needs to run once. It never overwrites a cached page, so running it
     again is harmless.
   - Nothing changes the catalog until `config.x.goodreads_replay.auto_apply` is on. Until then the
     replay only records proposed fixes, under Books → Repair Verdicts. Turn it on only after the
     50-per-kind hand check (spec §12.9).
   - Its merges and provisional marks are catalog changes and stick. Its relinks of legacy users'
     list items and reviews are undone by each sync and re-applied by `apply` (section 3).
   - Details: `docs/features/goodreads-import.md`, "Legacy seed" and "Legacy replay".
5. **Open Library `/resolve` under parallel load: done in #358.** On 2026-10-06 four Goodreads imports
   resolving at once left `/resolve` timing out at 60 s for 25 minutes, until the API container was
   restarted. Queries the Rails client had abandoned kept running and piled up in one 6 GB DuckDB pool.
   #358 runs one `/resolve` at a time, answers the rest with an instant 503 busy, and stops a query at
   a server-side deadline. The Rails client waits out a busy reply within its 60 s budget, and busy
   never counts toward the breaker.
   - What remains is capacity. A `/resolve` takes about 13 s, and every caller shares the one slot.
     A client that cannot get the slot within its budget gives up, and the finder decides that row
     without Open Library. Watch the flag rate when many members upload at once after launch.

### Decide at launch

- **Author enrichment:** `bin/rails "books:authors:enrich[all]"`, or `[13654]` for the ranked
  authors only. About 58k authors have no ranked book. After the switch-over.
- **Book AI enrichment:** `bin/rails "books:enrich_missing[<limit>]"`. Nothing queues it
  automatically.
- **Amazon enrichment of ranked books:** `bin/rails books:amazon_enrich_ranked`. It has never been
  run.

## 5. Cutover

1. Take legacy offline.
2. `FINAL=1 bin/rails data_migration:sync`. `FINAL=1` drops the 24-hour delay, so the last day's
   books come over too. Run `sync_report` with `FINAL=1` first.
3. Section 3, steps 3-5.
4. **Finish the failed and stuck legacy Goodreads imports.** Only now: they write into legacy users'
   lists, which every sync rewrites to match legacy, so a finishing import run earlier is undone by
   the next sync.
   - `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy` lists what it would do. Then run
     `bin/rails "books:goodreads_replay:finish_legacy[1]"`, one import at a time, and wait until it is
     no longer in progress before running the next. Running imports are skipped, not counted, so
     starting them back to back queues them all at once. Four at once overloaded the Open Library VM
     on 2026-10-06 (section 4, item 5). Each import also fetches Goodreads pages on the line member
     uploads use.
   - Approve or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`,
     "Finishing legacy imports".
5. **The Firebase bulk import, one last time** (`docs/features/v1-user-migration.md`, "Running it"),
   then never again (section 7).

## 6. Pointing thegreatestbooks.org at this app

- **Issue the TLS certificate on the server before merging the hostname change.** Merging deploys.
  If nginx references a certificate that doesn't exist, it crash-loops, and one nginx container
  fronts every site. The deploy job still shows green.
- **Firebase authorized domains** must list every books hostname that sign-in and the reset emails
  use. A missing domain fails silently on password reset.
- **Stripe, in this order** (`docs/guides/stripe-account-setup.md`, sections 7 and 11):
  1. Re-check the legacy guard just before launch (section 7).
  2. Delete legacy's webhook endpoint by hand in the Stripe Dashboard. Never run
     `rake stripe:delete_webhooks` once the hostname points here: it would delete this app's
     endpoint.
  3. Retire legacy's `/support`.
  4. Run `bin/rails billing:backfill_email_stamps`.
  5. Set `MEMBERSHIP_EMAIL_SCOPE=all`.

  If you reverse steps 4 and 5, or skip step 4, every legacy member gets a welcome email at the
  next 05:00 UTC sweep.
- After the deploy, check Admin → Webhook Events for `ignored` rows.

## 7. After launch

- **Stop re-running the Firebase bulk import.** An import replaces the whole account, so once real
  people use these accounts it would reset changed passwords and verified emails. The export and
  `firebase:backfill_v1_uids` stay safe to re-run.
- **The Open Library key and duplicate-key backfill** (books list wizard) waits until after the
  switch. It is not specced yet.
- **Remove the `LEGACY_R2_*` credentials from production secrets** after the last replay load and
  the last cover-image run.
- **Remove the stale `FIREBASE_PROJECT_ID`** from production secrets. The project id is hardcoded
  now, so the variable does nothing and could mislead someone later.
````

- [ ] **Step 2: Update the other docs**

`docs/features/books-legacy-sync.md`:
- In the Tasks table, replace the `data_migration:sync` row's description with: "Weekly. New legacy books, authors and their rows, new `book_identifiers` on any book, new categories/languages/countries/news posts; users, user lists and items, reading goals, saved searches, recommendation settings, reviews and corrections matched to legacy; then the favorites rebuild. `FINAL=1` drops the 24h delay (the cutover run)."
- Replace the line under the table with: "After `sync_init`, `data_migration:all`, every catalog task and the user-data tasks the sync replaces (`user_lists`, `user_list_items`, `saved_searches`, `reviews`, `corrections`) abort with \"use data_migration:sync\"."
- In "How it decides what is new", replace "every step is insert-only." with "catalog steps are insert-only and user-data steps converge on legacy."
- Replace the "Not synced" section's last sentence ("User lists, list items, reviews, saved searches and corrections are increment 3.") with this new section, placed before "Not synced":

```markdown
## Users' data

Legacy stays the source of truth for legacy users' data until the cutover. Each run makes the
legacy-origin rows (ids below their table's ceiling) match legacy, and never touches new-app rows
or other domains' lists.

| Data | Each run |
|---|---|
| Users | Overwritten by id. A user legacy deleted is counted, never deleted (the row carries music and games data). |
| User lists | Overwritten. Books lists legacy deleted are deleted, with their items. |
| List items | Synced list by list. Each book goes through redirects: a merged book lands on the survivor, two items that land on one book keep the lower position, an item on a deleted book is dropped. Items legacy removed are deleted. Positions are renumbered 1..N on legacy-origin lists only. |
| Reviews | Overwritten. Two reviews a merge puts on one book keep the newer (higher legacy id). A new-app review of the same book by the same user wins. Reviews legacy deleted are deleted. Review summaries are rebuilt. |
| Saved searches | Overwritten; ones legacy deleted are deleted. A category deleted here is removed from the criteria. |
| Reading goals, recommendation settings | As in the full migration. |
| Corrections | Insert-only, routed through redirects. |

A row on a legacy book that is not here yet (above the books watermark, inside the 24h delay) is
skipped and counted as `waiting`; a later run picks it up. A list item or review on a book that is
neither here, redirected nor waiting fails the run and names the legacy rows: the book was removed
without callbacks, or merged while the run was going.

**Deletion guard.** An empty or half-restored legacy database looks like mass deletion. A step that
would delete more than `max(500, 5%)` of a table's legacy-origin rows refuses, unless
`SYNC_ALLOW_DELETES=1`. It covers user lists, reviews and saved searches.

**The Goodreads replay's relinks** move legacy users' list items and reviews. Each sync puts them
back to match legacy, and `books:goodreads_replay:apply` re-applies the approved ones after every
sync. Its merges are redirects and stick.

**Report.** `sync_report` prints, per table, legacy and here counts and what the sync would insert,
update, delete, drop and leave waiting. List items are compared by a digest per list, and only lists
that differ are planned item by item, through the same plan the sync applies. `update` (legacy
`updated_at` newer than here) is a report number only: the sync overwrites every legacy-origin row.
```

`AGENTS.md`: replace the paragraph that begins "Do not swing the other way on the production side either:" and ends "rather than scheduling them once." with:

```markdown
Do not swing the other way on the production side either. **Production's books data is not live
user data yet, but it stops being disposable at the legacy-sync switch-over.** Books has not
launched and nobody signs in as those rows today. There is no pre-launch truncate any more
(`docs/features/books-legacy-sync.md`). Until `data_migration:sync_init` runs, the weekly
`data_migration:all` still overwrites books from legacy. After it (`LegacySyncWatermark.exists?`),
merges, deletes and edits made in production are kept: the catalog there is the master, and the
weekly `data_migration:sync` only adds what is new on legacy and re-matches legacy users' data.
Music and games ARE live on the same database, so a destructive command there is an outage. Any
books step you plan for production that runs downstream of the sync (uid write-backs, the Goodreads
replay's `apply`) is a **repeating** step: it re-runs after each sync and again in the final launch
sequence. Design those steps to be idempotent and then actually exercise that, rather than
scheduling them once.
```

`docs/features/goodreads-import.md`:
- Replace the bullet starting "**In production, run it on the final books migration pass only.**" with:

  `- **In production, run it at the cutover only, after the final sync** (docs/launch-todo.md, section 5). It writes into legacy users' lists and reviews, and every data_migration:sync rewrites those to match legacy, so an earlier run is undone by the next sync.`

- In the following bullet, delete the two sentences that begin "One whose written rows a truncate emptied" and "That is why every finishing import is rejected and then deleted before a truncate." Keep the rest of the bullet.

`docs/features/books-author-enrichment.md`: at the start of the "**Launch sequence.**" paragraph, insert: "Superseded on 2026-10-09: there is no pre-launch truncate any more. The legacy sync keeps this database's catalog from the switch-over on (`docs/features/books-legacy-sync.md`), so the truncate-list warnings below only matter for a development rebuild."

`docs/features/v1-user-migration.md`, "Re-running it": replace "the whole data migration is rehearsed against production more than once before books launches. Truncating resets `users.auth_uid`, so the backfill is re-run after **every** pass." with "legacy users keep coming over until the cutover: first through the weekly `data_migration:all`, then through `data_migration:sync`. Both overwrite users from legacy, which resets `users.auth_uid`, so the backfill is re-run after **every** run."

- [ ] **Step 3: Check nothing still plans a truncate**

Run: `grep -rn -i "truncat" docs/launch-todo.md AGENTS.md docs/features/books-legacy-sync.md docs/features/v1-user-migration.md docs/features/goodreads-import.md`
Expected: only AGENTS.md's lines about fixture loading and the `DROP`/`TRUNCATE` hook, and goodreads-import.md line ~62 ("truncating books for a migration pass empties them too"). That line describes a development rebuild and stays.

- [ ] **Step 4: Commit**

```bash
git add docs/launch-todo.md docs/features/books-legacy-sync.md AGENTS.md docs/features/goodreads-import.md docs/features/books-author-enrichment.md docs/features/v1-user-migration.md
git commit -m "Launch docs: switch-over and weekly sync replace the truncate"
```

---

## Final verification (after Task 9)

- `bin/rails test` (full suite, output to a file; read the tail): 0 failures, 0 errors, no new warning lines.
- `bundle exec standardrb`: clean.
- `CI=1 bin/rails zeitwerk:check`: clean (two new files in `app/lib/services/books_migration/`).
