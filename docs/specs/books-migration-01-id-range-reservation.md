# Books Migration — ID Range Reservation for `users` & `user_lists`

## Status
- **Status**: Not Started
- **Priority**: High (time-sensitive — must run while new-app data is still small)
- **Created**: 2026-06-10
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Reserve the low primary-key ID range on `users` and `user_lists` for the future Greatest Books migration, so that when the books site's `user_lists` (and their owning `users`) are imported **preserving their original auto-increment IDs**, they don't collide with IDs the new app mints for music/games/movies users in the meantime.

The mechanism is two-part, run **now** while music/games/movies data is negligible: (1) bump the Postgres sequences for both tables above a reserved, **per-table** ceiling so all *new* rows land in the high range; (2) relocate ("renumber in place") the handful of *existing* new-app rows that currently occupy the reserved low range up into the high range, remapping every foreign key that references them.

- **Goal**: Guarantee that books rows can be imported with `id` unchanged, with zero PK collisions and zero broken URLs.
- **Non-goals**: The actual books ETL/import job; the `Books::UserList` STI subclass; the books domain layout; migrating any books table *other* than `users`/`user_lists` (each gets its own reservation decision when its import is specced).

## Context & Links
- **Why book IDs must be preserved**: the compatibility alias `GET /user_lists/:id` (`user_list_path`) was added so legacy books URLs keep resolving after migration. See `config/routes.rb:257` (`get "user_lists/:id", to: "my_lists#show", as: :user_list`) and `docs/features/user-lists.md` (“My Lists Read Surface → Routing & Layout”). Preserving book PKs means those URLs work with **zero redirects**.
- **Schema (authoritative)**: `web-app/db/schema.rb` (version `2026_04_22_040533`) — `user_lists`, `user_list_items`, `users`. **Single Postgres database** — there is no multi-DB / `connects_to` topology; the migration runs on the default connection.
- **Books inventory at time of writing (production, legacy books site)**:
  - `UserList.order(:id).last.id` → **603,614**
  - `User.order(:id).last.id` → **69,198**
  - These are **max IDs**, not counts, and **will grow** before migration completes (migration window is "a few months"). See the growth-risk edge case below.
- Related: `docs/specs/completed/user-lists-01-data-model.md`, `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md`.

## Interfaces & Contracts

### Domain Model (diffs only)
- **No column or index changes.** This is a sequence + data-relocation migration only.
- Both PKs are already `bigint` (range ~9.2×10¹⁸; confirmed `web-app/db/schema.rb:620` `users`, `:604` `user_lists`), so the reserved ceilings cost nothing in storage and leave effectively unlimited headroom above them.
- New migration(s) under `web-app/db/migrate/` using raw SQL via the bare `execute "..."` / `select_value` helpers (the project convention — see `web-app/db/migrate/20260422040533_set_user_lists_view_mode_default.rb`). No schema.rb column diff results; see "Schema-dump caveat" below.
- A single source-of-truth constant for the per-table ceilings (proposed home: a small initializer or a constant module, e.g. `BooksMigration::RESERVED_CEILINGS`), referenced by the migration and any future books ETL.

### Reserved ID Ranges
| Table | Reserved for books (preserved IDs) | New-app rows (relocated + future) | Sequence restart value | Books max id today | Headroom |
|---|---|---|---|---|---|
| `users` | `[1, 150_000)` | `>= 150_000` | `150_000` | 69,198 | ~2.2× |
| `user_lists` | `[1, 1_000_000)` | `>= 1_000_000` | `1_000_000` | 603,614 | ~1.65× |

> **Per-table ceilings** (decided by the owner): `users` = `150_000`, `user_lists` = `1_000_000`. `user_list_items.id` is **not** reserved (not URL-facing); its IDs may be freshly assigned on import as long as `user_list_id` is remapped.
>
> ⚠️ **These ceilings are deliberately tight** (only ~1.65–2.2× over today's books max). Because books rows keep their original sub-ceiling IDs and the books site keeps growing until migration, the ceiling must still exceed the books max id **at import time**. **Re-confirm both books max IDs immediately before the books import** (`User.order(:id).last.id`, `UserList.order(:id).last.id`); if either is approaching its ceiling, raise that ceiling before importing. The cost of a higher ceiling is zero (bigint); the cost of an over-tight ceiling is a failed import with PK collisions.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| — | — | No new endpoints. | — | — |

> The existing `GET /user_lists/:id` alias depends on books PKs being preserved; this spec is what makes that safe. Source of truth: `config/routes.rb:257`.

### FKs to remap when relocating an existing new-app row
Verified against `web-app/db/schema.rb` (version `2026_04_22_040533`). **Any FK added before this migration ships must be added to the remap set** (re-verify at implementation time — see Sub-Agent Plan #1).

- **`user_lists` relocation** → cascade to `user_list_items.user_list_id` (single FK; `web-app/db/schema.rb:596` column, `:688` `add_foreign_key`).
- **`users` relocation** → cascade to all 7 FK columns referencing `users.id`:
  | `table.column` | column def | `add_foreign_key` |
  |---|---|---|
  | `ai_chats.user_id` | schema.rb:59 | schema.rb:649 |
  | `domain_roles.user_id` | schema.rb:103 | schema.rb:652 |
  | `external_links.submitted_by_id` | schema.rb:123 | schema.rb:653 |
  | `lists.submitted_by_id` | schema.rb:286 | schema.rb:663 |
  | `penalties.user_id` | schema.rb:502 | schema.rb:679 |
  | `ranking_configurations.user_id` | schema.rb:567 | schema.rb:687 |
  | `user_lists.user_id` | schema.rb:613 | schema.rb:689 |

> **Ordering**: relocate `users` first (which repoints `user_lists.user_id` among the 7), then relocate `user_lists` (which repoints `user_list_items.user_list_id`). `user_lists.user_id` is a *value* remapped during the users step; it is untouched when `user_lists.id` itself is renumbered.

### Relocation contract (renumber-in-place)
Postgres FK constraints created by Rails (`foreign_key: true` / `add_foreign_key`) default to `ON UPDATE NO ACTION` and are **not deferrable**, so they are checked at the **end of each statement**. Updating a parent PK while children still reference the old id therefore violates the FK mid-transaction. The robust pattern (row counts are tiny) is **drop FK → remap parent + children → re-add FK → verify no orphans → commit**, all inside one transaction:

1. Bump the table's sequence to its ceiling **first** (so newly allocated ids land `>= ceiling`).
2. Build an `old_id → new_id` map for rows where `id < ceiling`, where `new_id = nextval(seq)`.
3. Drop the referencing FK constraint(s).
4. `UPDATE` the parent `id` and every referencing FK column via the map.
5. Re-add the FK constraint(s).
6. Assert orphan count `= 0` for every dependent; `raise` (→ rollback) otherwise.

### Behaviors (pre/postconditions)
- **Preconditions**: run while new-app `users`/`user_lists` counts are small; no books data present yet in the new app; DB snapshot taken.
- **Postconditions**:
  - The next `User.create!` yields `id >= 150_000`; the next `UserList`-subclass create yields `id >= 1_000_000`.
  - No `users` row with `id < 150_000` and no `user_lists` row with `id < 1_000_000` exists (reserved ranges are empty and stay empty until the books import fills them).
  - All FK references for any relocated row are repointed; no orphaned `user_list_items`, `ai_chats`, `domain_roles`, `external_links`, `lists`, `penalties`, `ranking_configurations`.
- **Edge cases & failure modes**:
  - **Existing rows in the reserved range** — music/games/movies already minted IDs 1,2,3…. These MUST be relocated before/with the sequence bump, else book IDs 1..N collide with them. The sequence bump alone is insufficient.
  - **Books growth past a tight ceiling** — because the ceilings are tight, re-confirm both books max IDs immediately before import (see Reserved ID Ranges warning). Raise a ceiling before importing if books has grown near it.
  - **Idempotency** — the migration must be safe to re-run: only `RESTART` a sequence if its current value is below the target; skip relocation for rows already `>= ceiling`.
  - **Schema-dump caveat** — `db/schema.rb` does NOT capture sequence `RESTART` values, so `db:schema:load` (CI, fresh dev DBs) starts sequences at 1 again. That's acceptable: the reservation only needs to hold in **production** (and any environment that will receive the books import). Document it; do not switch to `structure.sql` for this alone.
  - **Sequence below table max** — never `RESTART` to a value `<= MAX(id)` of the table; guard with `GREATEST(ceiling, max_id + 1)`.
  - **Relocation collisions** — assign renumbered ids from `nextval` *after* the sequence bump, so renumbered rows can't collide with each other or with future inserts.
  - **Auth safety** — confirmed: identity resolution keys off `users.auth_uid` (Firebase UID, `schema.rb:622`), `email` (`:628`), and `confirmation_token` (`:624`) — **never** `users.id`. Renumbering a user touches only the 7 FKs; no auth/session attribute changes.

### Non-Functionals
- **Performance**: touches only the small current new-app row set; runs in a single transaction; negligible runtime now (the whole point of doing it early).
- **Safety**: wrap relocation + FK remap in one transaction; verify FK integrity (no orphans) before commit. Take a DB snapshot before running in production.
- **Security/roles**: `users` renumbering must not change any auth-relevant attribute (confirmed: auth keys off `auth_uid`/`email`/`confirmation_token`, not PK). No role/permission semantics change.
- **Reversibility**: sequence `RESTART` is not cleanly reversible (define `down` as a no-op with a comment, or restore from snapshot).

## Acceptance Criteria
- [ ] A guarded, idempotent migration sets the `users` sequence to `>= 150_000` and the `user_lists` sequence to `>= 1_000_000` (only bumping when below the target).
- [ ] All pre-existing `users` rows with `id < 150_000` and `user_lists` rows with `id < 1_000_000` are relocated to `>= ceiling`, with every FK in the remap set repointed and no orphaned dependents.
- [ ] After running: `User.create!(...).id >= 150_000` and a `UserList`-subclass create yields `id >= 1_000_000` (test asserts each boundary).
- [ ] `user_list_items` for relocated lists still resolve to the correct parent, and all 7 `users` dependents still resolve to the correct user (FK integrity test).
- [ ] Re-running the migration is a no-op and does not error; loading a fresh schema (CI) does not error (sequences simply start at 1 there — documented).
- [ ] A simulated books import (insert a row at a low reserved id, e.g. `user_lists.id = 42`) succeeds without collision and `GET /user_lists/42` resolves it.
- [ ] Reserved ranges, the per-table ceilings, the tight-ceiling re-confirm step, and the schema-dump caveat are documented in `docs/features/user-lists.md` (or a new books-migration doc) and cross-linked.

### Golden Examples
```text
# Before (new-app, music/games/movies only)
SELECT last_value FROM user_lists_id_seq;   -> 7
SELECT id FROM user_lists ORDER BY id;       -> 1,2,3,4,5,6,7   (new-app)

# After this migration
SELECT last_value FROM user_lists_id_seq;   -> 1000006   (ceiling + relocated rows)
SELECT id FROM user_lists ORDER BY id;       -> 1000000 .. 1000006   (relocated)
-- reserved range [1, 1_000_000) is now empty

SELECT last_value FROM users_id_seq;         -> 150_000 + (relocated user count)
-- reserved range [1, 150_000) is now empty

# Later, at books import (preserving original IDs)
INSERT INTO user_lists (id, ...) VALUES (42, ...);   -- no collision
GET /user_lists/42                                   -- 200, owner-only show
```

### Optional Reference Snippets (≤40 lines each, non-authoritative)
```ruby
# reference only — guarded, idempotent per-table sequence bump
module BooksMigration
  RESERVED_CEILINGS = { "users" => 150_000, "user_lists" => 1_000_000 }.freeze
end

class ReserveBooksIdRanges < ActiveRecord::Migration[8.1]
  def up
    BooksMigration::RESERVED_CEILINGS.each do |table, ceiling|
      seq      = "#{table}_id_seq"
      max_id   = select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
      last_val = select_value("SELECT last_value FROM #{seq}").to_i
      target   = [ceiling, max_id + 1].max
      execute("ALTER SEQUENCE #{seq} RESTART WITH #{target}") if last_val < target
      relocate_below_ceiling(table, ceiling) # see relocation snippet
    end
  end

  def down
    # Sequence reservation is intentionally irreversible; restore from snapshot.
  end
end
```

```ruby
# reference only — relocate sub-ceiling user_lists (drop FK → remap → re-add → verify).
# `users` follows the same shape but drops/re-adds all 7 FK constraints in the remap table.
ceiling = BooksMigration::RESERVED_CEILINGS["user_lists"]
execute(<<~SQL)
  CREATE TEMP TABLE ul_remap ON COMMIT DROP AS
    SELECT id AS old_id, nextval('user_lists_id_seq') AS new_id
    FROM user_lists WHERE id < #{ceiling} ORDER BY id;
SQL
remove_foreign_key :user_list_items, :user_lists
execute("UPDATE user_lists ul SET id = r.new_id
         FROM ul_remap r WHERE ul.id = r.old_id")
execute("UPDATE user_list_items i SET user_list_id = r.new_id
         FROM ul_remap r WHERE i.user_list_id = r.old_id")
add_foreign_key :user_list_items, :user_lists
orphans = select_value(<<~SQL).to_i
  SELECT COUNT(*) FROM user_list_items i
  LEFT JOIN user_lists ul ON ul.id = i.user_list_id WHERE ul.id IS NULL
SQL
raise "orphaned user_list_items: #{orphans}" if orphans.positive?
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture. Migrations use `ActiveRecord::Migration[8.1]`, bare `execute`/`select_value`, explicit `def up`/`def down` for irreversible ops, no `disable_ddl_transaction!`.
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Do not paste the full migration into the spec; the migration in `web-app/db/migrate/` is authoritative.
- Treat production data as sacred: snapshot first, single transaction, verify no orphaned FKs before commit.

### Required Outputs
- Migration(s) in `web-app/db/migrate/` (sequence bump + relocation/remap), paths listed in “Key Files Touched”.
- Passing tests demonstrating the Acceptance Criteria (per-table boundary asserts + FK integrity + idempotency).
- Updated: “Implementation Notes”, “Deviations”, “Documentation Updated”.

### Sub-Agent Plan
1) codebase-analyzer → **re-confirm** the full set of FK columns referencing `users`/`user_lists` at implementation time (schema may have grown beyond the 7 + 1 verified here).
2) codebase-pattern-finder → existing raw-SQL/data migration patterns in `web-app/db/migrate/` (e.g. `20260422040533_set_user_lists_view_mode_default.rb`).
3) web-search-researcher → Postgres `ALTER SEQUENCE … RESTART` semantics & `nextval`/FK `NO ACTION` edge cases (official docs first).
4) technical-writer → update `docs/features/*` and cross-refs.

### Test Seed / Fixtures
- Reuse `test/fixtures/user_lists.yml`, `user_list_items.yml`, `users.yml`. Add a focused test that inserts a low-id (e.g. `id: 42`) `user_list` post-migration to prove the reserved range accepts a "book" row without collision, and that `GET /user_lists/42` resolves it.

---

## Implementation Notes (living)
- Approach taken:
- Important decisions (resolved):
  - **Relocate vs delete+recreate → RESOLVED: renumber in place.** Preserves all real user data and custom lists; few rows; single transaction with FK remap. The delete+recreate fallback was rejected: `User#create_default_user_lists` (`app/models/user.rb:129`) only fires `after_create`, so deleting existing lists would orphan *existing* users' defaults with no backfill.
  - **`users` relocation blast radius → RESOLVED: auth-safe, 7 FKs.** Identity keys off `auth_uid`/`email`/`confirmation_token`, not `users.id` (confirmed in `web-app/db/schema.rb` + project auth services). Renumbering repoints exactly the 7 FK columns listed above.
  - **Ceiling values → RESOLVED: per-table, `users = 150_000`, `user_lists = 1_000_000`** (owner decision). Tight (~1.65–2.2× over today's books max), so **re-confirm books max IDs immediately before the books import** and raise a ceiling if books has grown near it.
  - **Single database → CONFIRMED.** No `connects_to`; migration targets the default connection.

### Key Files Touched (paths only)
- `web-app/db/migrate/` (new migration[s])
- `web-app/db/schema.rb` (version bump only; no column diff)
- `docs/features/user-lists.md` (or new `docs/features/books-migration.md`)
- `web-app/test/...` (migration boundary + FK integrity tests)

### Challenges & Resolutions
- …

### Deviations From Plan
- …

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- When migrating additional books tables, make a per-table reservation decision (URL-facing PK → preserve in a reserved block; non-URL-facing → free to renumber) and record it here or in a sibling spec.
- If more sites are migrated later, consider a reusable `reserve_id_range(table, ceiling:)` migration helper (per-source ID blocks), and revisit whether the tight per-table ceilings chosen here want more headroom.

## Related PRs
- #…

## Documentation Updated
- [ ] `documentation.md`
- [ ] `docs/features/user-lists.md` (reserved ranges + alias dependency + tight-ceiling re-confirm step)
- [ ] Class docs (if a `BooksMigration` constant/helper is introduced)
