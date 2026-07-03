# Lists ID-Range Reservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reserve the low primary-key range on the shared `lists` table so legacy Greatest Books list IDs can be imported unchanged (URL continuity) without colliding with the music/games/movies lists already in the new app.

**Architecture:** Extend the existing, generic `Services::BooksMigration` reservation (which already reserved `users` ≤150k and `user_lists` ≤1M) to also cover `lists`. Add `lists` to `RESERVED_CEILINGS` and `FOREIGN_KEYS`, add a new `POLYMORPHIC_FOREIGN_KEYS` map for the one polymorphic reference to lists (`ai_chats.parent`), and two service fixes: (a) re-add only the FKs that were actually dropped (so the FK-less `ranked_lists.list_id` doesn't get a brand-new FK), and (b) shift polymorphic `ai_chats.parent_id`. A thin, idempotent migration runs the service; a snapshot-first operational run applies it in production.

**Tech Stack:** Rails 8.1, PostgreSQL 17, Minitest + fixtures, `Services::` object with a `{success:, data:/error:}` result hash. Raw SQL via `ActiveRecord::Base.connection`.

## Global Constraints

- Run all commands from `web-app/`.
- Lint with `bundle exec standardrb` (NOT rubocop). Tests: `bin/rails test`.
- **`lists` ceiling = `10_000`.** This value MUST, at run time, exceed the **new-app** `lists` `MAX(id)` (dev is 1,475), because the relocation is an additive `id + ceiling` shift that is only collision-free when every existing row is below the ceiling. It must also exceed the **legacy** `lists` `MAX(id)` (1,175) at import time so imported book lists fit in `[1, ceiling)`. Before the production run, confirm `SELECT max(id) FROM lists` (new-app prod) is well under `10_000`; raise the ceiling if not (zero cost on a bigint PK).
- The reservation service must remain **idempotent** (safe to re-run: a second run is a no-op) and run in a **single transaction**.
- **Do not add any new domain foreign key.** In particular, `ranked_lists.list_id` currently has no DB-level FK; the reservation must shift it but must NOT create an FK for it.
- Production is an operational, snapshot-first step — not performed by this plan's automated run.
- `db/schema.rb` does not capture sequence `RESTART` values; `db:schema:load` (CI/fresh DBs) starts sequences at 1. That is acceptable — the reservation only needs to hold where the books import runs (prod + dev).

## Columns that reference `lists.id` (authoritative — verified against `db/schema.rb` @ 2026_07_01_163004 and `pg_constraint`)

| Child table | Column | Real DB FK? |
|---|---|---|
| `list_items` | `list_id` | yes |
| `list_penalties` | `list_id` | yes |
| `ranked_lists` | `list_id` | **no** (shift only, never add FK) |
| `ranking_configurations` | `primary_mapped_list_id` | yes |
| `ranking_configurations` | `secondary_mapped_list_id` | yes |
| `ai_chats` | `parent_id` (where `parent_type = 'List'`) | polymorphic — no FK |

---

### Task 1: Extend the reservation service to cover `lists`

**Files:**
- Modify: `web-app/app/lib/services/books_migration.rb` (add `lists` to `RESERVED_CEILINGS`/`FOREIGN_KEYS`; add `POLYMORPHIC_FOREIGN_KEYS`; update module comment)
- Modify: `web-app/app/lib/services/books_migration/id_range_reservation_service.rb` (drop→collect, re-add only dropped, add polymorphic shift)
- Test: `web-app/test/lib/services/books_migration/id_range_reservation_service_test.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::RESERVED_CEILINGS`, `FOREIGN_KEYS`, `POLYMORPHIC_FOREIGN_KEYS` (constants); `Services::BooksMigration::IdRangeReservationService.call` → `{success: true, data: {...}}` or `{success: false, error: String}`.
- Produces: after `.call`, no `lists` row has `id < 10_000`; every column above is shifted by `10_000` for rows that were below it; the `lists` sequence is `>= 10_000`; **no** `ranked_lists → lists` FK exists.

- [ ] **Step 1: Rename the misleading test constant and add the lists ceiling constant**

In `test/lib/services/books_migration/id_range_reservation_service_test.rb`, the constant currently named `LISTS_CEILING` actually fetches the `user_lists` ceiling. Rename it and add a real lists ceiling. Replace the two constant lines at the top of the class:

```ruby
  USERS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("users")
  USER_LISTS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("user_lists")
  LISTS_CEILING = Services::BooksMigration::RESERVED_CEILINGS.fetch("lists")
```

Then update the two existing references to the old name:
- In test "relocates reserved-range rows above the ceiling and remaps their FKs", change `RESERVED_LIST_ID + LISTS_CEILING` (both occurrences that refer to `user_lists`) to `RESERVED_LIST_ID + USER_LISTS_CEILING`.
- In test "leaves no users or user_lists rows below the ceiling", change `WHERE id < #{LISTS_CEILING}` (the `user_lists` assertion) to `WHERE id < #{USER_LISTS_CEILING}`.

- [ ] **Step 2: Seed lists + all its referencing rows in the test setup**

In the same file, replace the `lists` insert inside `seed_reserved_range_rows` (the `RESERVED_OTHER_LIST_ID` row) and append the child/reference rows. Add these constants next to the existing `RESERVED_*` constants:

```ruby
  RESERVED_LIST_ITEM_ID = 21
  RESERVED_RC_ID = 31
  RESERVED_RANKED_LIST_ID = 41
  RESERVED_PENALTY_ID = 51
  RESERVED_LIST_PENALTY_ID = 61
  RESERVED_AI_CHAT_ID = 71
```

Append to the end of `seed_reserved_range_rows` (the `lists` row at `RESERVED_OTHER_LIST_ID = 11` is already seeded earlier in that method; keep it):

```ruby
    @conn.execute(<<~SQL)
      INSERT INTO list_items (id, list_id, verified, created_at, updated_at)
      VALUES (#{RESERVED_LIST_ITEM_ID}, #{RESERVED_OTHER_LIST_ID}, false, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ranking_configurations
        (id, type, name, primary_mapped_list_id, secondary_mapped_list_id, created_at, updated_at)
      VALUES (#{RESERVED_RC_ID}, 'Games::RankingConfiguration', 'Reserved RC',
              #{RESERVED_OTHER_LIST_ID}, #{RESERVED_OTHER_LIST_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ranked_lists (id, list_id, ranking_configuration_id, created_at, updated_at)
      VALUES (#{RESERVED_RANKED_LIST_ID}, #{RESERVED_OTHER_LIST_ID}, #{RESERVED_RC_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO penalties (id, type, name, created_at, updated_at)
      VALUES (#{RESERVED_PENALTY_ID}, 'Global::Penalty', 'Reserved Penalty', now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO list_penalties (id, list_id, penalty_id, created_at, updated_at)
      VALUES (#{RESERVED_LIST_PENALTY_ID}, #{RESERVED_OTHER_LIST_ID}, #{RESERVED_PENALTY_ID}, now(), now())
    SQL
    @conn.execute(<<~SQL)
      INSERT INTO ai_chats (id, model, parent_type, parent_id, created_at, updated_at)
      VALUES (#{RESERVED_AI_CHAT_ID}, 'test-model', 'List', #{RESERVED_OTHER_LIST_ID}, now(), now())
    SQL
```

- [ ] **Step 3: Fix the existing `submitted_by_id` assertion (the lists row now relocates)**

In test "relocates reserved-range rows above the ceiling and remaps their FKs", the `lists` row at id 11 will now be relocated to `11 + LISTS_CEILING`. Change the `lists.submitted_by_id` assertion's WHERE clause:

```ruby
    # lists.submitted_by_id -> users remapped (users ceiling); the lists row itself relocated by LISTS_CEILING.
    assert_equal RESERVED_USER_ID + USERS_CEILING,
      @conn.select_value("SELECT submitted_by_id FROM lists WHERE id = #{RESERVED_OTHER_LIST_ID + LISTS_CEILING}").to_i
```

- [ ] **Step 4: Write the failing lists-reservation test**

Add these test methods to the file:

```ruby
  test "relocates lists and remaps every column that references lists.id" do
    result = Services::BooksMigration::IdRangeReservationService.call
    assert result[:success], "service should succeed: #{result[:error]}"

    relocated = RESERVED_OTHER_LIST_ID + LISTS_CEILING

    assert_equal relocated, relocated_id("lists", RESERVED_OTHER_LIST_ID)
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM list_items WHERE id = #{RESERVED_LIST_ITEM_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM ranked_lists WHERE id = #{RESERVED_RANKED_LIST_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT list_id FROM list_penalties WHERE id = #{RESERVED_LIST_PENALTY_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT primary_mapped_list_id FROM ranking_configurations WHERE id = #{RESERVED_RC_ID}").to_i
    assert_equal relocated,
      @conn.select_value("SELECT secondary_mapped_list_id FROM ranking_configurations WHERE id = #{RESERVED_RC_ID}").to_i
  end

  test "remaps the polymorphic ai_chats reference to a relocated list" do
    Services::BooksMigration::IdRangeReservationService.call

    assert_equal RESERVED_OTHER_LIST_ID + LISTS_CEILING,
      @conn.select_value("SELECT parent_id FROM ai_chats WHERE id = #{RESERVED_AI_CHAT_ID}").to_i
  end

  test "does not create a foreign key for the FK-less ranked_lists.list_id" do
    refute @conn.foreign_key_exists?("ranked_lists", "lists", column: "list_id"),
      "precondition: ranked_lists.list_id must have no FK"

    Services::BooksMigration::IdRangeReservationService.call

    refute @conn.foreign_key_exists?("ranked_lists", "lists", column: "list_id"),
      "reservation must not add a ranked_lists -> lists FK"
  end

  test "leaves no lists rows below the lists ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    assert_equal 0, @conn.select_value("SELECT COUNT(*) FROM lists WHERE id < #{LISTS_CEILING}").to_i
  end

  test "next List create lands at or above the lists ceiling" do
    Services::BooksMigration::IdRangeReservationService.call

    list = Books::List.create!(name: "Post-reservation List")
    assert_operator list.id, :>=, LISTS_CEILING
  end

  test "is idempotent for lists: a second run does not shift the list again" do
    assert Services::BooksMigration::IdRangeReservationService.call[:success]
    relocated = relocated_id("lists", RESERVED_OTHER_LIST_ID)

    assert Services::BooksMigration::IdRangeReservationService.call[:success]
    assert_equal relocated, relocated_id("lists", RESERVED_OTHER_LIST_ID)
  end

  test "a simulated book-list import at a low reserved id succeeds without collision" do
    Services::BooksMigration::IdRangeReservationService.call

    @conn.execute(<<~SQL)
      INSERT INTO lists (id, type, name, status, estimated_quality, created_at, updated_at)
      VALUES (42, 'Books::List', 'Imported Book List', 0, 0, now(), now())
    SQL

    assert_equal 42, @conn.select_value("SELECT id FROM lists WHERE id = 42").to_i
    assert List.exists?(42), "book list at reserved id 42 should be findable"
  end
```

- [ ] **Step 5: Run the new tests — verify they FAIL**

Run: `bin/rails test test/lib/services/books_migration/id_range_reservation_service_test.rb`
Expected: FAIL — `KeyError: key not found: "lists"` from `RESERVED_CEILINGS.fetch("lists")` (the `lists` ceiling constant does not exist yet).

- [ ] **Step 6: Add `lists` to the reservation constants + the polymorphic map**

In `app/lib/services/books_migration.rb`, update the module comment's first sentence to name `lists`, then set the three constants:

```ruby
    RESERVED_CEILINGS = {
      "users" => 150_000,
      "user_lists" => 1_000_000,
      "lists" => 10_000
    }.freeze

    FOREIGN_KEYS = {
      "users" => [
        ["ai_chats", "user_id"],
        ["domain_roles", "user_id"],
        ["external_links", "submitted_by_id"],
        ["lists", "submitted_by_id"],
        ["penalties", "user_id"],
        ["ranking_configurations", "user_id"],
        ["user_lists", "user_id"]
      ],
      "user_lists" => [
        ["user_list_items", "user_list_id"]
      ],
      "lists" => [
        ["list_items", "list_id"],
        ["list_penalties", "list_id"],
        ["ranked_lists", "list_id"],
        ["ranking_configurations", "primary_mapped_list_id"],
        ["ranking_configurations", "secondary_mapped_list_id"]
      ]
    }.freeze

    # Polymorphic references have no DB FK. Rails stores the STI *base* class name
    # in the `_type` column, so every list's ai_chat is `parent_type = "List"`.
    # Format: [child_table, id_column, type_column, type_value].
    POLYMORPHIC_FOREIGN_KEYS = {
      "lists" => [
        ["ai_chats", "parent_id", "parent_type", "List"]
      ]
    }.freeze
```

- [ ] **Step 7: Make the service re-add only dropped FKs and shift polymorphic refs**

In `app/lib/services/books_migration/id_range_reservation_service.rb`, replace `call`, `drop_foreign_keys`, and `add_foreign_keys`, and add `relocate_polymorphic_rows`:

```ruby
      def call
        ActiveRecord::Base.transaction do
          dropped = drop_foreign_keys
          relocate_rows
          relocate_polymorphic_rows
          add_foreign_keys(dropped)
          bump_sequences
        end
        success({ceilings: RESERVED_CEILINGS})
      rescue => e
        failure(e.message)
      end
```

```ruby
      # Polymorphic references have no FK to drop/re-add; shift the id column for
      # rows whose *_type matches the reserved table, by that table's ceiling.
      def relocate_polymorphic_rows
        POLYMORPHIC_FOREIGN_KEYS.each do |table, refs|
          ceiling = RESERVED_CEILINGS.fetch(table)
          refs.each do |child, id_column, type_column, type_value|
            connection.execute(
              "UPDATE #{child} SET #{id_column} = #{id_column} + #{ceiling} " \
              "WHERE #{type_column} = #{connection.quote(type_value)} AND #{id_column} < #{ceiling}"
            )
          end
        end
      end
```

```ruby
      # Returns the FKs it actually dropped, so add_foreign_keys re-adds only
      # those — a column in FOREIGN_KEYS without a real DB FK (ranked_lists.list_id)
      # is shifted but must NOT gain a new FK.
      def drop_foreign_keys
        dropped = []
        each_foreign_key do |child, column, table|
          if connection.foreign_key_exists?(child, table, column: column)
            connection.remove_foreign_key(child, table, column: column)
            dropped << [child, column, table]
          end
        end
        dropped
      end

      # Re-adding a validated FK forces Postgres to verify every child row points
      # at a real parent — the integrity guarantee, done by the database.
      def add_foreign_keys(dropped)
        dropped.each do |child, column, table|
          connection.add_foreign_key(child, table, column: column)
        end
      end
```

- [ ] **Step 8: Run the full test file — verify it PASSES**

Run: `bin/rails test test/lib/services/books_migration/id_range_reservation_service_test.rb`
Expected: PASS (all tests, including the pre-existing users/user_lists ones).

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/books_migration.rb app/lib/services/books_migration/id_range_reservation_service.rb test/lib/services/books_migration/id_range_reservation_service_test.rb
git add app/lib/services/books_migration.rb app/lib/services/books_migration/id_range_reservation_service.rb test/lib/services/books_migration/id_range_reservation_service_test.rb
git commit -m "Reserve lists ID range for books migration (service + tests)"
```

---

### Task 2: Migration that applies the reservation

**Files:**
- Create: `web-app/db/migrate/<timestamp>_reserve_lists_id_range.rb` (via generator)
- Modify: `web-app/db/schema.rb` (version bump only — no column diff)

**Interfaces:**
- Consumes: `Services::BooksMigration::IdRangeReservationService.call`.
- Produces: a migration whose `up` reserves the `lists` range (and no-ops `users`/`user_lists`, already reserved); `down` is intentionally a no-op.

- [ ] **Step 1: Generate the migration file**

Run: `bin/rails generate migration ReserveListsIdRange`
Expected: creates `db/migrate/<timestamp>_reserve_lists_id_range.rb` (timestamp after `20260701163004`).

- [ ] **Step 2: Replace the migration body**

Replace the generated file's contents with:

```ruby
class ReserveListsIdRange < ActiveRecord::Migration[8.1]
  # Reserves the low PK range on the shared `lists` table for the future books
  # import (preserves original book-list IDs so legacy /lists/:id URLs keep
  # working). Re-runs Services::BooksMigration::IdRangeReservationService, which
  # now also relocates existing new-app `lists` rows above the `lists` ceiling,
  # remaps every column referencing lists.id (incl. the polymorphic
  # ai_chats.parent), and bumps the lists sequence. `users`/`user_lists` were
  # reserved by an earlier migration and are a no-op here.
  # See docs/superpowers/plans/2026-07-03-lists-id-range-reservation.md and
  # docs/specs/completed/books-migration-01-id-range-reservation.md.
  #
  # Idempotent — safe to re-run. db/schema.rb does NOT capture sequence RESTART
  # values, so db:schema:load starts sequences at 1 again; acceptable because the
  # reservation only needs to hold where the books import runs (prod + dev).
  def up
    result = Services::BooksMigration::IdRangeReservationService.call
    raise "Lists ID range reservation failed: #{result[:error]}" unless result[:success]
  end

  def down
    # Intentionally irreversible: relocating rows and restarting sequences cannot
    # be cleanly undone. Restore from a snapshot if reversal is ever needed.
  end
end
```

- [ ] **Step 3: Apply the migration to the test DB (updates schema.rb version)**

Run: `RAILS_ENV=test bin/rails db:migrate`
Expected: migration runs; `db/schema.rb` version line becomes the new timestamp; no column diff.

- [ ] **Step 4: Apply to dev and verify the reserved range is clear**

> Note: this relocates the ~1,484 existing dev music/games lists to `>= 10_000` (and their `ai_chats`/`list_items`/etc.). That is the intended dev setup for the books migration. Snapshot dev first only if you care about its current state.

Run:
```bash
bin/rails db:migrate
bin/rails runner 'puts ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM lists WHERE id < 10000")'
```
Expected: prints `0` (no lists rows below the ceiling).

- [ ] **Step 5: Verify idempotency (second service run is a no-op)**

Run: `bin/rails runner 'p Services::BooksMigration::IdRangeReservationService.call'`
Expected: `{:success=>true, :data=>{...}}` and (re-checking) `SELECT COUNT(*) FROM lists WHERE id < 10000` is still `0`.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/*_reserve_lists_id_range.rb db/schema.rb
git commit -m "Add ReserveListsIdRange migration"
```

---

### Task 3: Document the `lists` reservation

**Files:**
- Modify: `docs/features/user-lists.md` (Reserved ID Ranges section)

**Interfaces:**
- Consumes: nothing. Produces: docs reflecting the added `lists` reservation.

- [ ] **Step 1: Add `lists` to the reserved-ranges table and note the collision-safety constraint**

In `docs/features/user-lists.md`, in the "Reserved ID Ranges (Books Migration)" table, add a `lists` row:

```markdown
| `lists` | `[1, 10_000)` | `>= 10_000` |
```

Then, immediately after the table, add:

```markdown
`lists` was reserved in a later migration (`db/migrate/*_reserve_lists_id_range.rb`) so legacy `/lists/:id` URLs keep resolving after import. Its ceiling (`10_000`) must exceed the **new-app** `lists` `MAX(id)` at run time (the relocation is an additive shift, collision-free only when all rows are below the ceiling) — re-confirm before running in production. The reservation also remaps the one **polymorphic** reference to lists, `ai_chats.parent` (`parent_type = 'List'`), which has no FK. See `docs/superpowers/plans/2026-07-03-lists-id-range-reservation.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/features/user-lists.md
git commit -m "Document lists ID-range reservation"
```

---

## Self-Review

**1. Spec coverage** (against the design doc's Phase 0 + this plan's goal):
- Reserve `lists` range → Task 1 (constants) + Task 2 (migration). ✓
- Relocate existing new-app list rows + remap FKs → Task 1 `FOREIGN_KEYS["lists"]` (5 columns) + tests. ✓
- Polymorphic `ai_chats` reference → Task 1 `POLYMORPHIC_FOREIGN_KEYS` + `relocate_polymorphic_rows` + test. ✓
- No spurious `ranked_lists → lists` FK → Task 1 drop/re-add fix + explicit refute test. ✓
- Bump `lists` sequence → inherited from `bump_sequences` (iterates `FOREIGN_KEYS.each_key`, now includes `lists`); covered by "next List create ≥ ceiling" test. ✓
- Idempotent, single transaction → existing service structure + idempotency test. ✓
- Snapshot-first prod run → Global Constraints + migration comment. ✓
- Ceiling sizing constraint (must exceed new-app max) → Global Constraints + docs. ✓

**2. Placeholder scan:** No TBD/TODO. All code shown in full. Migration timestamp is produced by the generator (Task 2 Step 1), not hardcoded. ✓

**3. Type consistency:** `IdRangeReservationService.call` returns `{success:, data:/error:}` (unchanged). New constant `POLYMORPHIC_FOREIGN_KEYS` referenced only in `relocate_polymorphic_rows`. Test constant renamed `LISTS_CEILING`→`USER_LISTS_CEILING` with all references updated (Task 1 Step 1); new `LISTS_CEILING` fetches `"lists"`. `foreign_key_exists?`/`add_foreign_key`/`remove_foreign_key` signatures match the existing service usage. ✓
