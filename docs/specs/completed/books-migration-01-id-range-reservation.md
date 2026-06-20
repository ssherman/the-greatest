# Books Migration — ID Range Reservation for `users` & `user_lists`

## Status
- **Status**: Completed
- **Priority**: High (time-sensitive — must run while new-app data is still small)
- **Created**: 2026-06-10
- **Started**: 2026-06-12
- **Completed**: 2026-06-20 (code + tests merged; migration run + verified on dev. **Production run is a deploy-time operational step — snapshot first.**)
- **Developer**: Shane Sherman

## Overview
Reserve the low primary-key ID range on `users` and `user_lists` for the future Greatest Books migration, so that when the books site's ~265k `user_lists` (and their owning `users`) are imported **preserving their original auto-increment IDs**, they don't collide with IDs the new app mints for music/games users in the meantime.

The mechanism is two-part, run **now** while music/games data is negligible: (1) bump the Postgres sequences for both tables above a reserved ceiling so all *new* rows land in the high range; (2) relocate the handful of *existing* music/games rows that currently occupy the reserved low range up into the high range (FKs remapped).

- **Goal**: Guarantee that books rows can be imported with `id` unchanged, with zero PK collisions and zero broken URLs.
- **Non-goals**: The actual books ETL/import job; the `Books::UserList` STI subclass; the books domain layout; migrating any books table *other* than `users`/`user_lists` (each gets its own reservation decision when its import is specced).

## Context & Links
- **Why book IDs must be preserved**: the compatibility alias `GET /user_lists/:id` (`user_list_path`) was added so legacy books URLs keep resolving after migration. See `config/routes.rb` and `docs/features/user-lists.md` (“My Lists Read Surface → Routing & Layout”). Preserving book PKs means those URLs work with **zero redirects**.
- **Schema (authoritative)**: `db/schema.rb` — `user_lists`, `user_list_items`, `users`.
- **Books inventory at time of writing**: ~265,341 `user_lists` on the legacy books site (will grow before migration).
- Related: `docs/specs/completed/user-lists-01-data-model.md`, `docs/specs/completed/user-lists-02-ui-and-cached-page-integration.md`.

## Interfaces & Contracts

### Domain Model (diffs only)
- **No column or index changes.** This is a sequence + data-relocation migration only.
- Both PKs are already `bigint` (range ~9.2×10¹⁸), so the reserved ceiling costs nothing in storage and leaves effectively unlimited headroom above it.
- New migration(s) under `db/migrate/` (raw SQL via `execute`/`ActiveRecord::Base.connection`). No schema.rb column diff results; see "Schema-dump caveat" below.
- A single source-of-truth constant for the ceiling (proposed home: a small initializer or a constant on a migration helper, e.g. `BooksMigration::ID_CEILING`), referenced by the migration and any future books ETL.

### Reserved ID Ranges
| Table | Reserved for books (preserved IDs) | New-app rows (relocated + future) | Sequence restart value |
|---|---|---|---|
| `users` | `[1, 1_000_000_000)` | `>= 1_000_000_000` | `1_000_000_000` |
| `user_lists` | `[1, 1_000_000_000)` | `>= 1_000_000_000` | `1_000_000_000` |

> Ceiling `1_000_000_000` is ~3,700× the current book max (265,341) — ample room for books to keep growing before migration. `user_list_items.id` is **not** reserved (not URL-facing); its IDs may be freshly assigned on import as long as `user_list_id` is remapped.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| — | — | No new endpoints. | — | — |

> The existing `GET /user_lists/:id` alias depends on books PKs being preserved; this spec is what makes that safe. Source of truth: `config/routes.rb`.

### FKs to remap when relocating an existing new-app row
- **`user_lists` relocation** → cascade to `user_list_items.user_list_id` (single FK; see `db/schema.rb:688`).
- **`users` relocation** → cascade to all FK columns referencing `users` (per `db/schema.rb`): `ai_chats.user_id`, `domain_roles.user_id`, `external_links.submitted_by_id`, `lists.submitted_by_id`, `penalties.user_id`, `ranking_configurations.user_id`, `user_lists.user_id`. Any FK added before this migration ships must be added to the remap set.

### Behaviors (pre/postconditions)
- **Preconditions**: run while new-app `users`/`user_lists` counts are small; no books data present yet in the new app.
- **Postconditions**:
  - The next `User.create!` and `UserList.create!` both yield `id >= 1_000_000_000`.
  - No `users` or `user_lists` row exists with `id < 1_000_000_000` (the reserved range is empty and stays empty until the books import fills it).
  - All FK references for any relocated row are repointed; no orphaned `user_list_items`, `ai_chats`, etc.
- **Edge cases & failure modes**:
  - **Existing rows in the reserved range** — music/games already minted IDs 1,2,3…. These MUST be relocated (or deleted+recreated) before/with the sequence bump, else book IDs 1..N collide with them. The sequence bump alone is insufficient.
  - **Idempotency** — the migration must be safe to re-run: only `RESTART` a sequence if its current value is below the ceiling; skip relocation for rows already `>= ceiling`.
  - **Schema-dump caveat** — `db/schema.rb` does NOT capture sequence `RESTART` values, so `db:schema:load` (CI, fresh dev DBs) will start sequences at 1 again. That's acceptable: the reservation only needs to hold in **production** (and any environment that will receive the books import). Document it; do not switch to `structure.sql` for this alone.
  - **Sequence below table max** — never `RESTART` to a value `<= MAX(id)` of the table; guard with `GREATEST(ceiling, max_id + 1)`.
  - **Relocation collisions** — when renumbering in place, assign new IDs from the top of the sequence (post-bump) so renumbered rows can't collide with each other or future inserts.

### Non-Functionals
- **Performance**: touches only the small current new-app row set; runs in a single transaction; negligible runtime now (the whole point of doing it early).
- **Safety**: wrap relocation + FK remap in one transaction; verify FK integrity (no orphans) before commit. Take a DB snapshot before running in production.
- **Security/roles**: `users` renumbering must not change any auth-relevant attribute (firebase uid, email, sessions key off uid/email, not PK — confirm before running). No role/permission semantics change.
- **Reversibility**: sequence `RESTART` is not cleanly reversible (define `down` as a no-op with a comment, or restore from snapshot).

## Acceptance Criteria
- [x] A guarded, idempotent migration sets the `users` and `user_lists` sequences to `>= 1_000_000_000` (only bumping when below it).
- [x] All pre-existing `users`/`user_lists` rows with `id < 1_000_000_000` are relocated to `>= 1_000_000_000` (renumber in place), with every FK in the remap set repointed and no orphaned dependents.
- [x] After running: `User.create!(...).id >= 1_000_000_000` and `UserList`-subclass create yields `id >= 1_000_000_000` (test asserts the boundary).
- [x] `user_list_items` for relocated lists still resolve to the correct parent (FK integrity test).
- [x] Re-running the migration is a no-op and does not error; loading a fresh schema (CI) does not error (sequence simply starts at 1 there — documented).
- [x] A simulated books import (insert a row at a low reserved id, `id = 42`) succeeds without collision (service test asserts the row persists and is findable; `GET /user_lists/:id` resolution is covered by the existing `my_lists_controller` tests).
- [x] Reserved ranges + the schema-dump caveat are documented in `docs/features/user-lists.md` and cross-linked.

### Golden Examples
```text
# Before (new-app, music/games only)
SELECT last_value FROM user_lists_id_seq;   -> 7
SELECT id FROM user_lists ORDER BY id;       -> 1,2,3,4,5,6,7   (music/games)

# After this migration
SELECT last_value FROM user_lists_id_seq;   -> 1000000000
SELECT id FROM user_lists ORDER BY id;       -> 1000000000 .. 1000000006   (relocated)
-- reserved range [1, 1e9) is now empty

# Later, at books import (preserving original IDs)
INSERT INTO user_lists (id, ...) VALUES (42, ...);   -- no collision
GET /user_lists/42                                   -- 200, owner-only show
```

### Optional Reference Snippet (≤40 lines, non-authoritative)
```ruby
# reference only — guarded, idempotent sequence bump (relocation handled separately)
class ReserveBooksIdRanges < ActiveRecord::Migration[8.0]
  CEILING = 1_000_000_000

  def up
    %w[users user_lists].each do |table|
      seq      = "#{table}_id_seq"
      max_id   = select_value("SELECT COALESCE(MAX(id), 0) FROM #{table}").to_i
      last_val = select_value("SELECT last_value FROM #{seq}").to_i
      target   = [CEILING, max_id + 1].max
      # only move the sequence forward; never backward
      execute("ALTER SEQUENCE #{seq} RESTART WITH #{target}") if last_val < target
    end
    # NOTE: relocating existing sub-ceiling rows + FK remap is a separate,
    # transactional data step (see "FKs to remap"); do it BEFORE book import.
  end

  def down
    # Sequence reservation is intentionally irreversible; restore from snapshot.
  end
end
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Do not paste the full migration into the spec; the migration in `db/migrate/` is authoritative.
- Treat production data as sacred: snapshot first, single transaction, verify no orphaned FKs before commit.

### Required Outputs
- Migration(s) in `db/migrate/` (sequence bump + relocation/remap), paths listed in “Key Files Touched”.
- Passing tests demonstrating the Acceptance Criteria (boundary asserts + FK integrity + idempotency).
- Updated: “Implementation Notes”, “Deviations”, “Documentation Updated”.

### Sub-Agent Plan
1) codebase-analyzer → confirm the full set of FK columns referencing `users`/`user_lists` at implementation time (schema may have grown).
2) codebase-pattern-finder → find existing raw-SQL/data migration patterns in `db/migrate/`.
3) web-search-researcher → Postgres `ALTER SEQUENCE … RESTART` semantics & `setval` edge cases (official docs first).
4) technical-writer → update `docs/features/*` and cross-refs.

### Test Seed / Fixtures
- Reuse `test/fixtures/user_lists.yml`, `user_list_items.yml`, `users.yml`. Add a focused test that inserts a low-id (e.g. `id: 42`) `user_list` post-migration to prove the reserved range accepts a "book" row without collision.

---

## Implementation Notes (living)
- Approach taken:
  - Logic lives in a service object, `Services::BooksMigration::IdRangeReservationService` (`app/lib/services/books_migration/id_range_reservation_service.rb`), matching the project's "skinny models, fat services" convention and making it independently unit-testable. The thin migration `db/migrate/20260612235510_reserve_books_id_ranges.rb` just calls the service and raises on failure.
  - The ceiling + the full FK remap set live as constants in the Zeitwerk explicit-namespace file `app/lib/services/books_migration.rb` (`Services::BooksMigration::ID_CEILING`, `Services::BooksMigration::FOREIGN_KEYS`), reusable by the future books ETL.
  - **Relocation = additive bijection.** Every reserved-range PK (and every FK referencing it) is shifted by exactly `ID_CEILING` (`UPDATE … SET id = id + CEILING WHERE id < CEILING`). Parents and children shift by the same constant, so a child's repointed FK always lands on its parent's new id. This is trivially collision-free and idempotent (the `< CEILING` guard skips already-relocated rows).
  - **FK handling = drop → shift → re-add, in one transaction.** FKs are non-deferrable `ON UPDATE NO ACTION`, so a plain parent UPDATE would violate them mid-statement. The service drops the involved FKs, shifts the ids, then re-adds the FKs — and re-adding a validated FK *is* the "no orphaned dependents before commit" integrity check (Postgres scans every row). Portable, no special DB privileges, no constraint-definition changes.
  - **Sequence bump** uses `ALTER SEQUENCE … RESTART WITH GREATEST(CEILING, MAX(id)+1)`, guarded by `last_value < target` so it only ever moves forward and a re-run is a no-op.
- Important decisions:
  - **Resolved — relocate vs delete+recreate.** Chose **renumber in place** (owner confirmed). Local DB had real synced-prod data (20 users, 242 user_lists incl. custom lists); deletion would destroy them. FKs remapped: `user_lists.user_id` (×242) and `lists.submitted_by_id` (×14) for users; `user_list_items.user_list_id` (×20) for user_lists.
  - **Resolved — `users` relocation blast radius.** Verified nothing keys off `users.id` outside FKs: there is no `sessions` table; auth keys off Firebase `auth_uid`/`email`. The full 7-FK `users` remap set was re-confirmed against current `db/schema.rb` (version `2026_04_22_040533`) — unchanged from the spec's list.
  - **Ceiling value** = `1_000_000_000`. Re-confirm books max id near migration time stays well under it.

### Key Files Touched (paths only)
- `web-app/db/migrate/20260612235510_reserve_books_id_ranges.rb` (new migration)
- `web-app/app/lib/services/books_migration.rb` (namespace + `ID_CEILING`/`FOREIGN_KEYS` constants)
- `web-app/app/lib/services/books_migration/id_range_reservation_service.rb` (relocation + sequence-bump logic)
- `web-app/db/schema.rb` (version bump only → `2026_06_12_235510`; no column diff)
- `web-app/test/lib/services/books_migration/id_range_reservation_service_test.rb` (boundary + FK integrity + idempotency + simulated book-import tests)
- `docs/features/user-lists.md` (reserved ranges + schema-dump caveat, cross-linked)

### Challenges & Resolutions
- **Non-deferrable FK constraints** would reject a parent-PK UPDATE mid-statement → resolved by dropping + re-adding the FKs within the transaction (re-add doubles as the integrity check).
- **`PendingMigrationError` when running tests** (migration newer than `schema.rb`) → applied the migration to the **test** DB (`RAILS_ENV=test bin/rails db:migrate`), which also produced the `schema.rb` version bump, while leaving the synced-prod dev data untouched until the owner runs `db:migrate` on dev.

### Deviations From Plan
- **Logic in a `Services::` object, not inline in the migration** (the spec's reference snippet inlined it). Done for testability + the project's "skinny models, fat services" convention; the constant lives in the service namespace rather than a standalone initializer.
- **Additive `+CEILING` offset** rather than compacting relocated ids to start exactly at `CEILING` (the golden example showed `1000000000..`). New ids are `CEILING + old_id` (e.g. user 5 → `1000000005`). This is a pure bijection → simpler, provably collision-free, and idempotent; it still satisfies every acceptance criterion (`id >= 1_000_000_000`).

## Acceptance Results
- **Date**: 2026-06-20
- **Verifier**: Shane Sherman
- **Tests**: `web-app/test/lib/services/books_migration/id_range_reservation_service_test.rb` — 5 runs / 16 assertions, 0 failures. Full sweep of `test/lib/services/`, `user_test`, `user_list_test`, `user_list_item_test` — 490 runs / 1596 assertions, 0 failures.
- **Dev DB run** (synced-prod data: 20 users, 242 user_lists) — `bin/rails db:migrate` applied `20260612235510_reserve_books_id_ranges`; post-run verification:

| Check | Result |
|---|---|
| `users` with `id < 1e9` | **0 / 20** (min id `1000000001`) |
| `user_lists` with `id < 1e9` | **0 / 242** (min id `1000000001`) |
| `users_id_seq.last_value` | `1000000021` |
| `user_lists_id_seq.last_value` | `1000000243` |
| Orphaned `user_lists` / `user_list_items` / `lists` | **0 / 0 / 0** |
| `User.create!` boundary | id `1000000021` (≥ 1e9) ✓ |
| `Games::UserList.create!` boundary | id `1000000255` (≥ 1e9) ✓ |

- **FKs remapped**: `user_lists.user_id` (×242), `lists.submitted_by_id` (×14), `user_list_items.user_list_id` (×20) — zero orphans.
- **Outstanding (operational)**: run in production after a DB snapshot; re-confirm legacy books `MAX(id)` is still well under `1_000_000_000` near migration time. The migration is idempotent, so a re-run after a partial failure is safe.

## Future Improvements
- When migrating additional books tables, make a per-table reservation decision (URL-facing PK → preserve in a reserved block; non-URL-facing → free to renumber) and record it here or in a sibling spec.
- Consider a reusable `reserve_id_range(table, ceiling:)` migration helper if more sites are migrated later (per-source ID blocks).

## Related PRs
- #…

## Documentation Updated
- [ ] `documentation.md`
- [x] `docs/features/user-lists.md` (reserved ranges + alias dependency + schema-dump caveat)
- [x] Class docs (`Services::BooksMigration` namespace + service carry inline doc comments)
