# Books Migration — ID Range Reservation for `users` & `user_lists`

## Status
- **Status**: Not Started
- **Priority**: High (time-sensitive — must run while new-app data is still small)
- **Created**: 2026-06-10
- **Started**:
- **Completed**:
- **Developer**:

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
- [ ] A guarded, idempotent migration sets the `users` and `user_lists` sequences to `>= 1_000_000_000` (only bumping when below it).
- [ ] All pre-existing `users`/`user_lists` rows with `id < 1_000_000_000` are relocated to `>= 1_000_000_000` (or deleted + recreated, if explicitly chosen), with every FK in the remap set repointed and no orphaned dependents.
- [ ] After running: `User.create!(...).id >= 1_000_000_000` and `UserList`-subclass create yields `id >= 1_000_000_000` (test asserts the boundary).
- [ ] `user_list_items` for relocated lists still resolve to the correct parent (FK integrity test).
- [ ] Re-running the migration is a no-op and does not error; loading a fresh schema (CI) does not error (sequence simply starts at 1 there — documented).
- [ ] A simulated books import (insert a row at a low reserved id, e.g. `id = 42`) succeeds without collision and `GET /user_lists/42` resolves it.
- [ ] Reserved ranges + the schema-dump caveat are documented in `docs/features/user-lists.md` (or a new books-migration doc) and cross-linked.

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
- Important decisions:
  - **Open decision — relocate vs delete+recreate the existing new-app rows.** Recommended: **renumber in place** (preserves real user data; few rows; single transaction with FK remap). Fallback the owner floated: delete all new-app `user_lists` and let the signup callback recreate defaults — simpler but destroys any custom lists and won't re-create defaults for *existing* users without a backfill. Decide before implementing.
  - **Open decision — `users` relocation blast radius.** Renumbering a `user` repoints 7 FK columns (see remap set). Confirm nothing keys off `users.id` outside FKs (sessions/auth key off firebase uid/email — verify). If relocation is judged too risky, the alternative is to offset *book users* on import into a separate high block instead (book user IDs are less URL-facing than list IDs) — but that diverges from the uniform low-range reservation; default is uniform.
  - **Ceiling value** = `1_000_000_000`. Re-confirm books max id near migration time stays well under it.

### Key Files Touched (paths only)
- `db/migrate/` (new migration[s])
- `db/schema.rb` (version bump only; no column diff)
- `docs/features/user-lists.md` (or new `docs/features/books-migration.md`)
- `test/...` (migration boundary + FK integrity tests)

### Challenges & Resolutions
- …

### Deviations From Plan
- …

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- When migrating additional books tables, make a per-table reservation decision (URL-facing PK → preserve in a reserved block; non-URL-facing → free to renumber) and record it here or in a sibling spec.
- Consider a reusable `reserve_id_range(table, ceiling:)` migration helper if more sites are migrated later (per-source ID blocks).

## Related PRs
- #…

## Documentation Updated
- [ ] `documentation.md`
- [ ] `docs/features/user-lists.md` (reserved ranges + alias dependency)
- [ ] Class docs (if a `BooksMigration` constant/helper is introduced)
