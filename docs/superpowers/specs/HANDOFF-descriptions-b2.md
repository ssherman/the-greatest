# Handoff — Descriptions increment (b2)

Written 2026-07-29 at the end of the session that shipped (a) and (b1). Delete this file once b2's
plan exists; it is a session bridge, not a spec.

## Where things stand

`main` is at `a51dd75`. Two increments of the descriptions subsystem are merged:

- **(a), PR #180** — polymorphic `Description` model, `Descriptions::Resolver`,
  `Descriptions::SourcePriority::ORDER`, `Describable` concern in eleven content models.
- **(b1), PR #181** — `Services::DescriptionColumnBackfill` + `data_migration:description_columns`.
  Lifted the five in-app games/music `description` columns onto rows. **Dev run executed and
  verified: 11,382 rows. Production is still at 0.**

Spec: `docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md` — read the Backfill and
Increments sections plus decisions D5, D10, D11, D14, D15.

## What b2 is

Backfill `Description` rows from the **legacy books database** (`legacy_books` connection):

| Migrator | Source | Rows |
|---|---|---|
| `Services::BooksMigration::BookDescriptionMigrator` | legacy `books`: `ai_generated_description` 111,447 + `goodreads_description` 8,162 + `description` 20,242 | 139,851 |
| `Services::BooksMigration::AuthorDescriptionMigrator` | legacy `authors`: `ai_description` 38,114 + `description` 8,670 | 46,784 |
| books/authors safety net | in-app rows with a `description` and no row after the above | ~50 + ~21 |

Total ≈ 186,635. Both migrators subclass `Services::BooksMigration::BulkUpsertMigrator`.

**Why it matters:** this is what gives `/book/:slug` real content. Today only 39% of ranked books have
a description in the new app, because `BookTransformer` ported the wrong column — the legacy site
displays `description_to_display`, which resolves to `ai_generated_description` for 87.5% of books.
The books public UI is blocked on this.

## Conflict semantics — settled, do not re-litigate

Override `BulkUpsertMigrator`'s `upsert_all` with **`insert_all`**, same as b1. No `finalize` pass. On a
clean table the rows do not exist, so the 2,139 legacy `use_description` books get `rank: :preferred` on
first insert; later runs skip existing keys while still picking up anything new.

The owner ruled on 2026-07-29 that this is a **one-time lift** — no descriptions get edited on the legacy
site before launch — so there is no need to re-sync changed legacy text, and no need to design for it.

Naive `upsert_all` is not an option: it resets `rank: :preferred` to `:normal` and overwrites content on
every run, and can transiently double-occupy `index_descriptions_one_preferred_per_key`, raising a
`PG::UniqueViolation` that `ON CONFLICT` cannot absorb (the arbiter is the *other* index), aborting the
whole batch.

## Landmines

- **The books/authors backfills read the LEGACY columns, never the current in-app `description`
  column.** That column already *is* the legacy raw `description` from the earlier migration, so
  reading both double-creates.
- **`Services::Descriptions::*` is unusable.** Inside `module Services`, `Descriptions` resolves
  lexically to `Services::Descriptions`, shadowing the real namespace — `Descriptions::Resolver` and
  `::SourcePriority` both `NameError`. Same for bare `Games::`/`Music::` inside `module Services`
  (they hit `Services::Games`/`Services::Music`); use a leading `::` or string keys + `constantize`.
- **`upsert_all` bypasses validations**, so the DB constraints are the only guard: the
  `nulls_not_distinct` natural-key index, `descriptions_content_not_blank`,
  `descriptions_source_name_matches_source` (biconditional — `source_name` must be NULL for every
  named source), and the partial preferred index.
- **Intra-batch duplicate keys** raise `PG::CardinalityViolation` and kill the batch — the landmine
  `ListPenaltyMigrator` needed `@seen` for. b2's `build_rows` looks safe by construction, but state
  why in a comment or dedup explicitly.
- **`.presence`, never truthiness.** 41 of b1's source rows were empty strings; the legacy columns will
  have their own. `descriptions_content_not_blank` rejects the whole batch if one gets through.
- **`source_name` is stripped, not verbatim** — legacy has `"Publisher "` with a trailing space, and
  `source_name` is inside the unique key.
- **Source-name normalisation is dirty**: `wikipedia`/`Wikipedia`/`WIkipedia`/`"Wikipedia "` (~10,638),
  `OpenLibrary` 7,513, `Google` 1,448, `Publisher` ~203, long tail of magazines. Map to `:wikipedia`
  + `:cc_by_sa_4`, `:openlibrary` + `:cc0`, `:other` + `source_name`, `:publisher`.
- **The safety net's sizing needs re-checking after the migrators run.** The spec estimates ~50 books
  and ~21 authors, but dev has 20,242 `Books::Book` and 8,670 `Books::Author` rows with a non-blank
  `description` column. The gap depends entirely on the source-name normalisation being complete. If
  it drops rows, the safety net stamps `:manual` provenance onto legacy-sourced text, which D10 exists
  to prevent. Verify cardinality *after* the migrators, before writing.
- **`Descriptions::SourcePriority::ORDER` is contractual.** `ai_generated` before `goodreads` before
  the sourced values reproduces legacy `default`; `ai_generated` before `wikipedia` reproduces the
  legacy author page's `ai_description || description`. Do not reorder.
- **The legacy DB is often not running.** `psql` to localhost:5432 fails with connection refused;
  `LegacyBooks::*` models read it when it is up. `LegacyBooks::Book#use_description` returns a raw
  **integer**, not an enum string.
- **Snapshot before any run**: `bin/snapshot-dev-db.sh --label pre-b2`. The books data in development
  exists nowhere else and takes hours to rebuild. `db:drop`/`db:reset`/`db:schema:load` and
  `create_fixtures` are hook-blocked.

## Verification style

Exact counts plus a no-op second run, matching PRs #159–#181. For the production run, use an
**invariant** (per model, `Description` rows at the backfilled key == source records with non-blank
description) rather than a hardcoded total — production totals legitimately differ from dev.

## After b2

(c) write paths — rewire the two AI description tasks (they currently clobber via
`parent.update!(description:)`) and the two IGDB providers to write their own source's row; add
`Admin::DescriptionsController` mirroring `Admin::ImagesController`; strip the description field from
nine admin forms; build the bulk set-preferred-by-list action the owner actually used on the legacy
site. (d) read paths — five public and nine admin views to `primary_description`, plus
`Descriptions::AttributionComponent`, which closes a live CC BY-SA attribution gap inherited from the
legacy site. (e) drop the eleven columns, as its own PR after a–d run in production.

**Deploy-ordering dependency:** `data_migration:description_columns` (b1) and b2's tasks must all have
run in **production** before (d) deploys, or every games, music and books page silently loses its
description.

## Also parked

`docs/superpowers/specs/2026-07-27-books-public-ui-carryover.md` holds the fully-settled books public
UI design — scope, URL scheme, the numeric-slug collision that forces `/book/:slug` singular, user-list
wiring. Its one open question is which books get public routes: 24,242 are ranked, 101,892 are on zero
curated lists (Goodreads-importer arrivals living on user lists).
