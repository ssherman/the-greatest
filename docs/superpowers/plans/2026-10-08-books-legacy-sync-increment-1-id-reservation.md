# Books Legacy Sync — Increment 1: Id Reservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the new app from handing out `books_books`, `books_authors`, `reviews` and `saved_searches` ids that legacy is about to use, by moving those four id sequences up to reserved ceilings and making the four id-preserving migrators respect them.

**Architecture:** Four new entries in `Services::BooksMigration::RESERVED_CEILINGS` plus three module functions: `bump_sequence_to_floor!` (sequence only, never backward, never below max id + 1), `reserve_sequence_floors!` (all four tables) and `raise_if_at_ceiling!` (legacy-id guard). A data migration calls `reserve_sequence_floors!` on deploy. `BookMigrator`, `AuthorMigrator`, `ReviewMigrator` and `SavedSearchMigrator` call the guard per row and replace their `reset_pk_sequence!` finalize with `bump_sequence_to_floor!`, so the weekly `data_migration:all` can never pull a sequence back below its ceiling.

**Tech Stack:** Rails 8.1, PostgreSQL sequences, Minitest 6 + Mocha.

**Spec:** `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md` §3 (this plan amends §3 in Task 3: no refusal, see "Deviation" below).

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the repository root.
- Ceilings, verbatim from the spec: `books_books` 250,000; `books_authors` 120,000; `reviews` 250,000; `saved_searches` 20,000.
- No rows are relocated. Do **not** call or extend `IdRangeReservationService` (its relocation would shift the preserved legacy ids).
- A sequence is never moved backward, and its next id is never at or below the table's current max id.
- Use the Rails generator for the migration (`bin/rails generate migration ...`). Run `db:migrate` with `ANNOTATERB_SKIP_ON_DB_TASKS=1`.
- Lint with `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- Minitest 6: `assert_nil` for nil, never `assert_equal nil, x`.
- Commit on branch `worktree-books-legacy-sync`; never commit to `main`; do not push.

**Deviation from spec §3 (decided while planning):** the spec says the reservation step "refuses if the table's max id is already at or above the ceiling". It does not refuse. It runs inside a schema migration on deploy, and a migration that raises crash-loops the web container and takes down all four sites (`bin/docker-entrypoint` runs `db:prepare` before the server). Refusing would protect nothing: when rows sit above the ceiling, the sequence simply goes to max id + 1, and the per-row `raise_if_at_ceiling!` guard in the migrators is what actually stops a legacy id from entering the reserved range. Task 3 updates the spec.

## Review Focus

1. **Tables already above the ceiling.** Test fixtures use hashed ids far above 250,000, and the sequence after `db:schema:load` sits at 1. The bump must go to max id + 1 without raising. Pinned in Task 1 ("uses max id + 1 when rows already sit above the ceiling").
2. **A sequence already past the target** (new-app rows created, then deleted). It must not move backward. Pinned in Task 1 ("never moves a sequence backward").
3. **A legacy id exactly equal to the ceiling.** The guard must raise at `==`, not only at `>`. Pinned in Task 1 (boundary pair) and in each migrator test in Task 2.
4. **Re-running** the migration, or the migrators' finalize after it. It must be a no-op the second time. Pinned in Task 1 ("is idempotent").
5. **Vacuous sequence tests.** Two traps: sequence changes are not rolled back with the test transaction (an earlier test may already have pushed a sequence past the ceiling), and fixture ids are hashed far above every ceiling (so the old max + 1 already clears it). Task 1 positions each sequence explicitly and uses ceilings relative to the current max. Task 2 pins the call for books/authors, and empties the table and starts the sequence low for reviews/saved searches. Task 2's Step 3 lists the exact expected failures, and Step 6 is a mutation check.

---

### Task 1: The ceilings and the sequence-floor functions

**Files:**
- Modify: `web-app/app/lib/services/books_migration.rb`
- Create: `web-app/test/lib/services/books_migration/sequence_floor_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 2 and 3, and by later increments to mean "legacy-origin = id below the ceiling"):
  - `Services::BooksMigration::RESERVED_CEILINGS` gains `"books_books" => 250_000`, `"books_authors" => 120_000`, `"reviews" => 250_000`, `"saved_searches" => 20_000`.
  - `Services::BooksMigration::SEQUENCE_FLOOR_TABLES` → `%w[books_books books_authors reviews saved_searches]`.
  - `Services::BooksMigration.bump_sequence_to_floor!(table, ceiling: RESERVED_CEILINGS.fetch(table))` → `Integer`, the id the sequence will hand out next.
  - `Services::BooksMigration.reserve_sequence_floors!` → `Hash{String => Integer}` (table → next id), one entry per `SEQUENCE_FLOOR_TABLES` table.
  - `Services::BooksMigration.raise_if_at_ceiling!(table, id)` → `nil`, or raises `RuntimeError` whose message contains `"reserved ceiling"`, the table name and the ceiling.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/services/books_migration/sequence_floor_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::SequenceFloorTest < ActiveSupport::TestCase
  CEILINGS = Services::BooksMigration::RESERVED_CEILINGS

  # Sequence changes are NOT rolled back with the test transaction, so every test
  # positions the sequence itself instead of trusting where an earlier test left it.

  def connection
    ActiveRecord::Base.connection
  end

  def sequence_for(table)
    connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
  end

  def set_next_value(table, value)
    connection.execute("SELECT setval(#{connection.quote(sequence_for(table))}, #{value}, false)")
  end

  def peek_next_value(table)
    last_value, is_called = connection.select_rows("SELECT last_value, is_called FROM #{sequence_for(table)}").first
    ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
  end

  def max_id(table)
    connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
  end

  test "moves the sequence up to the ceiling when every row is below it" do
    set_next_value("books_books", 1)
    ceiling = max_id("books_books") + 1_000

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: ceiling)

    assert_equal ceiling, returned
    assert_equal ceiling, peek_next_value("books_books")
  end

  test "uses max id + 1 when rows already sit above the ceiling" do
    set_next_value("books_books", 1)
    above = max_id("books_books")
    assert_operator above, :>, 1, "fixtures should hold books_books rows"

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: 1)

    assert_equal above + 1, returned
    assert_equal above + 1, peek_next_value("books_books")
  end

  test "never moves a sequence backward" do
    ceiling = max_id("books_books") + 1_000
    set_next_value("books_books", ceiling + 5_000)

    returned = Services::BooksMigration.bump_sequence_to_floor!("books_books", ceiling: ceiling)

    assert_equal ceiling + 5_000, returned
    assert_equal ceiling + 5_000, peek_next_value("books_books")
  end

  test "is idempotent" do
    set_next_value("books_authors", 1)
    ceiling = max_id("books_authors") + 1_000

    first = Services::BooksMigration.bump_sequence_to_floor!("books_authors", ceiling: ceiling)
    second = Services::BooksMigration.bump_sequence_to_floor!("books_authors", ceiling: ceiling)

    assert_equal [ceiling, ceiling], [first, second]
    assert_equal ceiling, peek_next_value("books_authors")
  end

  test "an empty table gets exactly its configured ceiling" do
    ::SavedSearch.delete_all
    set_next_value("saved_searches", 1)

    returned = Services::BooksMigration.bump_sequence_to_floor!("saved_searches")

    assert_equal CEILINGS.fetch("saved_searches"), returned
    assert_equal CEILINGS.fetch("saved_searches"), ::Books::SavedSearch.create!(
      user: users(:regular_user), criteria: {"genre_match_mode" => "any"}
    ).id
  end

  test "reserve_sequence_floors! moves all four catalog tables to at least their ceilings" do
    Services::BooksMigration::SEQUENCE_FLOOR_TABLES.each { |table| set_next_value(table, 1) }

    result = Services::BooksMigration.reserve_sequence_floors!

    assert_equal %w[books_books books_authors reviews saved_searches], result.keys
    result.each do |table, next_id|
      assert_operator next_id, :>=, CEILINGS.fetch(table), table
      assert_operator next_id, :>, max_id(table), table
      assert_equal next_id, peek_next_value(table), table
    end
  end

  test "reserve_sequence_floors! leaves the relocated tables alone" do
    before = %w[users user_lists lists].index_with { |table| peek_next_value(table) }

    Services::BooksMigration.reserve_sequence_floors!

    assert_equal before, %w[users user_lists lists].index_with { |table| peek_next_value(table) }
  end

  test "raise_if_at_ceiling! accepts an id just below the ceiling" do
    assert_nil Services::BooksMigration.raise_if_at_ceiling!("books_books", CEILINGS.fetch("books_books") - 1)
  end

  test "raise_if_at_ceiling! raises at exactly the ceiling, naming the table and ceiling" do
    error = assert_raises(RuntimeError) do
      Services::BooksMigration.raise_if_at_ceiling!("books_books", CEILINGS.fetch("books_books"))
    end

    assert_includes error.message, "reserved ceiling"
    assert_includes error.message, "books_books"
    assert_includes error.message, "250000"
  end

  test "the catalog ceilings are the values the spec reserved" do
    assert_equal(
      {"books_books" => 250_000, "books_authors" => 120_000, "reviews" => 250_000, "saved_searches" => 20_000},
      CEILINGS.slice("books_books", "books_authors", "reviews", "saved_searches")
    )
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/sequence_floor_test.rb`
Expected: FAIL/ERROR, with `NoMethodError: undefined method 'bump_sequence_to_floor!'`, `uninitialized constant Services::BooksMigration::SEQUENCE_FLOOR_TABLES` and the ceilings assertion failing.

- [ ] **Step 3: Implement**

In `web-app/app/lib/services/books_migration.rb`, replace the module comment and the `RESERVED_CEILINGS` block (lines 4–19 today) with:

```ruby
  # Reserves low primary-key ID ranges for the Greatest Books migration. Books rows
  # are imported preserving their original auto-increment IDs in `[1, ceiling)`;
  # every new-app row lives at `>= ceiling`. See
  # docs/specs/completed/books-migration-01-id-range-reservation.md (users,
  # user_lists, lists) and docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md
  # (the four catalog tables).
  module BooksMigration
    # Per-table reserved ceilings: books rows keep their original IDs below the
    # ceiling; new-app rows are minted at `>= ceiling`. Sized with headroom over
    # the legacy books site's MAX(id) -- re-confirm it is still well under each
    # ceiling before the cutover, and raise a ceiling if needed (cost is zero on a
    # bigint PK).
    #
    # users/user_lists/lists (as of 2026-06/07) were reserved by relocating
    # new-app rows up (IdRangeReservationService). The four catalog tables
    # (legacy max on 2026-10-08: books 175,879; authors 80,329; reviews 153,446;
    # saved searches 6,070) hold only legacy rows, so they are reserved by moving
    # the sequence alone -- see SEQUENCE_FLOOR_TABLES.
    RESERVED_CEILINGS = {
      "users" => 150_000,
      "user_lists" => 1_000_000,
      "lists" => 10_000,
      "books_books" => 250_000,
      "books_authors" => 120_000,
      "reviews" => 250_000,
      "saved_searches" => 20_000
    }.freeze

    # Reserved by sequence only. Never pass these to IdRangeReservationService:
    # its relocation shifts every row below the ceiling, which here means the
    # preserved legacy ids themselves.
    SEQUENCE_FLOOR_TABLES = %w[books_books books_authors reviews saved_searches].freeze
```

Then add these module functions directly above `SUPPRESS_KEY = :books_migration_suppress_search`:

```ruby
    def self.reserve_sequence_floors!
      SEQUENCE_FLOOR_TABLES.index_with { |table| bump_sequence_to_floor!(table) }
    end

    # Moves the table's id sequence so the next id is at least the ceiling and
    # above every existing row. Never moves it backward. Returns the next id.
    def self.bump_sequence_to_floor!(table, ceiling: RESERVED_CEILINGS.fetch(table))
      connection = ActiveRecord::Base.connection
      sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
      max_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i
      last_value, is_called = connection.select_rows("SELECT last_value, is_called FROM #{sequence}").first
      current_next = ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
      target = [ceiling, max_id + 1].max
      return current_next if current_next >= target

      connection.execute("SELECT setval(#{connection.quote(sequence)}, #{target}, false)")
      target
    end

    # A legacy id at or above the ceiling would land in the range new-app rows
    # are minted from, and from then on "below the ceiling" would no longer mean
    # "came from legacy".
    def self.raise_if_at_ceiling!(table, id)
      ceiling = RESERVED_CEILINGS.fetch(table)
      return if id.to_i < ceiling

      raise "legacy #{table} id #{id} reaches the reserved ceiling #{ceiling}; raise RESERVED_CEILINGS[#{table.inspect}]"
    end

```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/sequence_floor_test.rb test/lib/services/books_migration/id_range_reservation_service_test.rb`
Expected: PASS, 0 failures. (The reservation service iterates `FOREIGN_KEYS`, not `RESERVED_CEILINGS`, so its tests are unaffected by the new keys.)

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/books_migration.rb test/lib/services/books_migration/sequence_floor_test.rb
git add app/lib/services/books_migration.rb test/lib/services/books_migration/sequence_floor_test.rb
git commit -m "Reserve id ceilings for the four books catalog tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The four id-preserving migrators respect the ceilings

**Files:**
- Modify: `web-app/app/lib/services/books_migration/book_migrator.rb`
- Modify: `web-app/app/lib/services/books_migration/author_migrator.rb`
- Modify: `web-app/app/lib/services/books_migration/review_migrator.rb`
- Modify: `web-app/app/lib/services/books_migration/saved_search_migrator.rb`
- Test: `web-app/test/lib/services/books_migration/book_migrator_test.rb`
- Test: `web-app/test/lib/services/books_migration/author_migrator_test.rb`
- Test: `web-app/test/lib/services/books_migration/review_migrator_test.rb`
- Test: `web-app/test/lib/services/books_migration/saved_search_migrator_test.rb`

**Interfaces:**
- Consumes (Task 1): `Services::BooksMigration.raise_if_at_ceiling!(table, id)`, `Services::BooksMigration.bump_sequence_to_floor!(table)`, `Services::BooksMigration::RESERVED_CEILINGS`.
- Produces: nothing new for later tasks. The migrators' public behavior (`.call` → `{success:, data:/error:}`) is unchanged except that a legacy id at or above the ceiling now fails the run.

- [ ] **Step 1: Move the existing test ids below the new ceilings**

The review and saved-search tests use legacy id 900,001/900,002, which is above the new ceilings (250,000 and 20,000) and would now fail the guard. Rename them (checked: neither file uses `200_00` or `15_00` today):

```bash
cd web-app
sed -i 's/900_00/200_00/g' test/lib/services/books_migration/review_migrator_test.rb
sed -i 's/900_00/15_00/g' test/lib/services/books_migration/saved_search_migrator_test.rb
grep -c "900_0" test/lib/services/books_migration/review_migrator_test.rb test/lib/services/books_migration/saved_search_migrator_test.rb
```

Expected: both counts `0`. (The book and author tests use 90,001/90,002, already below their ceilings.)

- [ ] **Step 2: Write the failing tests**

**Why two styles of sequence test.** Fixture ids are hashed and sit far above every new ceiling. For
`books_books` and `books_authors` (whose fixture rows cannot be deleted without breaking foreign
keys) the old `reset_pk_sequence!` already yields max + 1 ≥ ceiling, so a "next id ≥ ceiling"
assertion would pass with the old code. Those two pin the call instead; Task 1 tests what the call
does. `reviews` and `saved_searches` can be emptied inside the test transaction (`reviews` already
is, in `setup`), so they assert the real sequence, which max + 1 cannot satisfy.

Add these helpers to `review_migrator_test.rb` and `saved_search_migrator_test.rb` (directly after
the existing `run_migrator` helper):

```ruby
  # Sequence changes survive the test transaction, so start low: otherwise an
  # earlier test that already pushed the sequence past the ceiling would make the
  # finalize assertion pass with finalize deleted.
  def start_sequence_low(table)
    connection = ActiveRecord::Base.connection
    sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
    connection.execute("SELECT setval(#{connection.quote(sequence)}, 1, false)")
  end

  def next_sequence_value(table)
    ActiveRecord::Base.connection.select_value("SELECT nextval(pg_get_serial_sequence('#{table}', 'id'))").to_i
  end
```

**`book_migrator_test.rb`:** replace the test `"resets the books_books sequence above the max migrated id"` with:

```ruby
  test "moves the books_books sequence to the reserved floor after the load" do
    Services::BooksMigration.expects(:bump_sequence_to_floor!).with("books_books")

    result = run_migrator([{"id" => 90005, "title" => "Seq Probe Book", "original_language_id" => nil}])

    assert result[:success], result[:error]
  end

  test "fails the run when a legacy book id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

    result = run_migrator([{"id" => ceiling, "title" => "Too High", "original_language_id" => nil}])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::Books::Book.exists?(ceiling)
  end
```

**`author_migrator_test.rb`:** the helper `run_migrator` takes no arguments and always yields `legacy_rows`. Change it to accept rows:

```ruby
  def run_migrator(rows = legacy_rows)
    migrator = Services::BooksMigration::AuthorMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
    migrator.call
  end
```

Then replace the test `"resets the books_authors sequence above the max id"` with:

```ruby
  test "moves the books_authors sequence to the reserved floor after the load" do
    Services::BooksMigration.expects(:bump_sequence_to_floor!).with("books_authors")

    result = run_migrator

    assert result[:success], result[:error]
  end

  test "fails the run when a legacy author id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("books_authors")

    result = run_migrator([{"id" => ceiling, "name" => "Too High", "family_name" => "High", "alternative_names" => nil}])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::Books::Author.exists?(ceiling)
  end
```

**`review_migrator_test.rb`:** replace the test `"advances the id sequence past the migrated ids"` with:

```ruby
  test "moves the reviews sequence to the reserved ceiling after the load" do
    start_sequence_low("reviews")

    run_migrator([legacy_review(200_001)])

    next_id = next_sequence_value("reviews")
    assert_operator next_id, :>=, Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")
    assert_operator next_id, :>, 200_001
  end

  test "fails the run when a legacy review id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")

    result = run_migrator([legacy_review(ceiling)])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::Review.exists?(ceiling)
  end
```

**`saved_search_migrator_test.rb`:** replace the test `"resets the primary key sequence past the migrated maximum"` with:

```ruby
  test "moves the saved_searches sequence to the reserved ceiling after the load" do
    # Fixture ids are hashed far above 20,000; empty the table so max + 1 cannot
    # reach the ceiling by itself. Nothing references saved_searches by foreign key.
    ::SavedSearch.delete_all
    start_sequence_low("saved_searches")

    run_migrator([legacy_row])

    fresh = ::Books::SavedSearch.create!(user: users(:regular_user), criteria: {"genre_match_mode" => "any"})
    assert_operator fresh.id, :>=, Services::BooksMigration::RESERVED_CEILINGS.fetch("saved_searches")
  end

  test "fails the run when a legacy saved search id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("saved_searches")

    result = run_migrator([legacy_row({"genre_match_mode" => "any"}, {"id" => ceiling})])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::SavedSearch.exists?(ceiling)
  end
```

- [ ] **Step 3: Run the tests to verify the new ones fail**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/book_migrator_test.rb test/lib/services/books_migration/author_migrator_test.rb test/lib/services/books_migration/review_migrator_test.rb test/lib/services/books_migration/saved_search_migrator_test.rb`
Expected, 8 failures and nothing else:
- the four "fails the run when ... reaches the reserved ceiling" tests FAIL (the row is created and the run succeeds);
- the books and authors "reserved floor after the load" tests FAIL with a Mocha "not all expectations were satisfied" (finalize still calls `reset_pk_sequence!`);
- the reviews and saved-searches "reserved ceiling after the load" tests FAIL (the next id is max + 1: 200,002 and 15,002).

Every other test PASSES, which confirms the id renames in Step 1 changed nothing else.

- [ ] **Step 4: Implement**

`book_migrator.rb`: change the class comment's last sentence and the two methods:

```ruby
    # LegacyIdMap (languages migrate first) — the first real consumer of the map.
    # Moves the PK sequence to the reserved ceiling after load
    # (Services::BooksMigration::RESERVED_CEILINGS).
    class BookMigrator < Migrator
```

```ruby
      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_books", attrs["id"])
        book = ::Books::Book.find_or_initialize_by(id: attrs["id"])
        book.assign_attributes(BookTransformer.call(attrs))
        book.original_language_id = remap_language(attrs["original_language_id"])
        book.save!
      end
```

```ruby
      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("books_books")
      end
```

`author_migrator.rb`:

```ruby
    # Preserved-id migrator: books_authors is a books-only table, so legacy author
    # ids are kept verbatim (author URLs). Writes through Books::Author so
    # FriendlyId slugs, name normalization, and the kind enum all apply. Moves the
    # PK sequence to the reserved ceiling after load so later auto-inserts never
    # take an id legacy will hand out.
    class AuthorMigrator < Migrator
```

```ruby
      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("books_authors", attrs["id"])
        author = ::Books::Author.find_or_initialize_by(id: attrs["id"])
        author.assign_attributes(AuthorTransformer.call(attrs))
        author.save!
      end

      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("books_authors")
      end
```

`review_migrator.rb`: replace `finalize` and its comment, and add the guard as the first line of `build_rows`:

```ruby
      # insert_all with explicit ids never advances the sequence, so without this the
      # first review a real user writes collides with a migrated row -- and it must sit
      # at the reserved ceiling, not max + 1, or new reviews take ids legacy will use.
      # finalize runs outside without_search_indexing, so keep it callback-free.
      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("reviews")
      end
```

```ruby
      def build_rows(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("reviews", attrs["id"])

        book_id = attrs["book_id"]
```

`saved_search_migrator.rb`: replace the second and third sentences of the class comment (from "Preservation is safe without a reserved ceiling" to "the books_countries case, not user_lists.") with:

```ruby
    # Legacy saved_searches -> Books::SavedSearch (STI on the shared saved_searches
    # table), ids preserved below the reserved ceiling
    # (Services::BooksMigration::RESERVED_CEILINGS). It is load-bearing: /searches/:id is
    # a bookmarked URL that must keep resolving.
```

and change `upsert_row`'s first line and `finalize`:

```ruby
      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("saved_searches", attrs["id"])
        search = ::Books::SavedSearch.find_or_initialize_by(id: attrs["id"])
```

```ruby
      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("saved_searches")
      end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/books_migration/`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Mutation check (do not commit)**

Temporarily delete the `raise_if_at_ceiling!` line from `review_migrator.rb#build_rows` and re-run `bin/rails test test/lib/services/books_migration/review_migrator_test.rb`: the ceiling test must FAIL. Then temporarily change `review_migrator.rb#finalize` back to `target_model.connection.reset_pk_sequence!("reviews")`: the sequence test must FAIL. Restore both (`git diff` should show only the Step 4 changes).

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/books_migration/ test/lib/services/books_migration/
git add app/lib/services/books_migration/{book,author,review,saved_search}_migrator.rb test/lib/services/books_migration/{book,author,review,saved_search}_migrator_test.rb
git commit -m "Keep migrated catalog ids below their reserved ceilings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The data migration, the spec amendment, and verification

**Files:**
- Create: `web-app/db/migrate/<timestamp>_reserve_books_catalog_id_ranges.rb` (via generator)
- Modify: `web-app/db/schema.rb` (version line only, written by `db:migrate`)
- Modify: `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md` (§3)

**Interfaces:**
- Consumes (Task 1): `Services::BooksMigration.reserve_sequence_floors!`.
- Produces: nothing for later tasks.

- [ ] **Step 1: Generate the migration**

Run: `cd web-app && bin/rails generate migration ReserveBooksCatalogIdRanges`

Replace the generated file's body with:

```ruby
class ReserveBooksCatalogIdRanges < ActiveRecord::Migration[8.1]
  # Moves the books_books, books_authors, reviews and saved_searches id sequences up
  # to their Services::BooksMigration::RESERVED_CEILINGS, so rows this app creates
  # (Goodreads imports, member reviews) never take an id legacy will hand out before
  # the books cutover. Sequence only: no rows move, because every row in these tables
  # came from legacy. Idempotent, never moves a sequence backward, and never raises
  # on data -- a raising migration crash-loops the web container for all four sites.
  #
  # db/schema.rb does not capture sequence values, so a db:schema:load database starts
  # low again; the four migrators' finalize puts the floor back on their next run.
  # See docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md §3.
  def up
    Services::BooksMigration.reserve_sequence_floors!
  end

  def down
    # Nothing to undo: a higher sequence start is harmless.
  end
end
```

- [ ] **Step 2: Run it against the development database**

Run: `cd web-app && ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`
Expected: the migration runs with no error; `git diff db/schema.rb` shows only the `ActiveRecord::Schema[8.1].define(version: ...)` line changing.

- [ ] **Step 3: Verify the sequences on development**

Write this to the session scratchpad as `check_floors.rb` and run it with `bin/rails runner <path>`:

```ruby
conn = ActiveRecord::Base.connection
Services::BooksMigration::SEQUENCE_FLOOR_TABLES.each do |table|
  seq = conn.select_value("SELECT pg_get_serial_sequence(#{conn.quote(table)}, 'id')")
  last_value, is_called = conn.select_rows("SELECT last_value, is_called FROM #{seq}").first
  next_id = ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
  max_id = conn.select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
  puts format("%-15s max %9d  next %9d  ceiling %9d", table, max_id, next_id, Services::BooksMigration::RESERVED_CEILINGS.fetch(table))
end
```

Expected: for each table, `next` equals its ceiling (books 250,000; authors 120,000; reviews 250,000; saved_searches 20,000), and `max` is below it. Dev's books max was 176,175 on 2026-10-08. Record the output for the PR description.

Re-run `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate:redo VERSION=<timestamp>` and the check again: same numbers (idempotent).

- [ ] **Step 4: Amend the spec**

In `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md` §3, replace the sentence

```
A new step sets each sequence to its ceiling and **refuses if the
table's max id is already at or above the ceiling** (something unexpected is there; stop and look).
It is idempotent: a sequence already at or past the ceiling is left alone.
```

with

```
A new step, run by a data migration on deploy, sets each sequence to
`max(ceiling, max id + 1)`, never moving it backward. It is idempotent. It does **not** refuse when
rows already sit above the ceiling (amended while planning increment 1): a raising migration
crash-loops the web container for all four sites, and the migrators' per-row ceiling guard is what
actually keeps legacy ids out of the reserved range.
```

- [ ] **Step 5: Full suite and lint**

Run: `cd web-app && bin/rails test && bundle exec standardrb`
Expected: 0 failures, 0 errors, no offenses, and no new warning lines in the test output (AGENTS.md: a clean run emits only the two known upstream warnings, plus the known `MultiJson` one).

- [ ] **Step 6: Commit**

```bash
cd web-app
git add db/migrate/*_reserve_books_catalog_id_ranges.rb db/schema.rb ../docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md
git commit -m "Reserve the catalog id ranges on deploy

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

**Before merge (for the PR description, not a code step):** production's maxes were confirmed below every ceiling on 2026-10-08 (books 175,877, authors 80,328, reviews 153,444, saved searches 6,053). The migration cannot raise on data, so no further read-only check is required, but quote those numbers in the PR.
