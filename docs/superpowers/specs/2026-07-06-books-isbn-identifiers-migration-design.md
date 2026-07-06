# Books ISBN Identifiers Migration (work-level ISBN/ASIN/EAN) — Design

**Status:** Approved 2026-07-06.
**Scope:** One migration increment on top of Phase 1a/1b + editions + identifiers + categories (all merged). Migrate the deferred legacy ISBN family — `book_identifiers` types 1-4 (isbn10/isbn13/asin/ean13, book-level) **and** `editions.identifiers` jsonb (edition-level) — into **work-level** polymorphic `Identifier` rows on `Books::Book`. Adds four `books_work_*` enum values (code-only) and reuses the existing per-row `IdentifierMigrator` pattern.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.
**Supersedes** the parent design's tentative "edition-level types attach to the book's default edition" note (§Model-by-model → book_identifiers) — see Decision D1.

## Goal

Preserve every legacy ISBN, ISBN-13, ASIN, and EAN-13 as a work-level `Identifier` on the matching `Books::Book`, drawn from **both** legacy sources and deduped on the identifier natural key, with search suppressed and the load idempotent/re-runnable.

## Decisions (from brainstorming 2026-07-06)

- **D1 — one level, work-level.** All ISBN-family identifiers attach to `Books::Book` (work level), **not** to `Books::Edition`. Rationale: the legacy "merge" feature stuffed all ISBNs/EANs/ASINs into work-level `book_identifiers` because editions were never exposed; 69% of books (74,136 of the 106,174 with ISBNs) have **no edition**, so edition-level placement cannot represent them without synthesizing editions (rejected in the editions increment). Work-level ISBN is also a legitimate permanent **discovery index** ("this work was published under these ISBNs"). Edition-level ISBN population is deferred to a future ISBN-lookup API service — the only component that will have trustworthy edition↔ISBN attribution.
- **D2 — both sources, deduped.** Feed the work-level identifiers from **both** `book_identifiers` types 1-4 and `editions.identifiers` jsonb (edition ISBNs folded up to their parent `Books::Book`). The two sources are complementary (sampled 150 books: 2,706 book-only values, 1,590 edition-only, 282 shared), so both are needed for zero loss. Dedup is automatic via the identifier natural key.
- **D3 — reclassify ASIN by ISBN-10 shape.** A legacy `asin` value matching `/\A\d{9}[\dX]\z/i` (10 chars, 9 digits + digit/X) is stored as `books_work_isbn10`; otherwise (real `B0…` Kindle codes, etc.) as `books_work_asin`. ~87% of legacy type-3 "asin" values are actually ISBN-10s; Kindle ASINs (letters in the first 9 chars) never match the shape check and are preserved as ASINs. Shape check only — **no** ISBN-10 checksum validation (a bad-checksum ISBN is still an ISBN, not an ASIN). Reclassification also improves dedup: a physical book's ISBN-10 that appeared as both type-1 and type-3 collapses to one `books_work_isbn10` row.
- **D4 — EAN faithful.** `ean` / type-4 → `books_work_ean13` verbatim (no folding into isbn13, even though for books EAN-13 == ISBN-13). Keeps the legacy distinction; the same 13-digit number may exist as both `books_work_isbn13` and `books_work_ean13` (different-type rows) — acceptable, owner can dedupe later.
- **D5 — faithful values.** Strip surrounding whitespace, skip blanks. No ISBN checksum validation, no reformatting. Values are already clean (0 blanks, 0 dashes/spaces in the introspected sample).
- **D6 — source is the typed jsonb, not `flat_identifiers`.** `editions.flat_identifiers` (text) is an untyped flattened value list and cannot distinguish isbn10/isbn13/asin/ean; the typed `editions.identifiers` jsonb is the source.

## Framework reused (already on `main`)

`Services::BooksMigration::Migrator` base (batched `legacy_each` streaming as String-keyed attribute hashes, idempotent, `without_search_indexing`, per-row error context that names the offending legacy id and hard-aborts). `Services::BooksMigration::IdentifierMigrator` base (`< Migrator`): pure `strip_openlibrary_key`, and `upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)` = `find_or_create_by!` on the natural key that skips blank values and nil identifiable ids. `LegacyBooks::Record` read-only replica base, `LegacyBooks::BookIdentifier`, `LegacyBooks::Edition`. `data_migration:identifiers` rake task.

The `Identifier` natural key (unique index `index_identifiers_on_lookup_unique`) is `(identifiable_type, identifier_type, value, identifiable_id)` → this is what gives cross-source and cross-run dedup for free. `Identifier belongs_to :identifiable, polymorphic: true` with `validates :identifiable, presence: true` → an `identifiable_id` with no migrated `Books::Book` fails validation and hard-aborts the run (fail-loud, consistent with `BookMigrator#remap_language` / `CategoryItemMigrator`). No FK exists on the polymorphic column, so the per-row `find_or_create_by!` validation is what enforces this — a reason **not** to switch to bulk upsert without an explicit id-preload guard.

## Legacy data (local restore, introspected 2026-07-06)

`book_identifiers` (columns: `id, identifier, identifier_type, book_id, created_at, updated_at` — **only `book_id`, no `edition_id`**):

| `identifier_type` | meaning | rows | this pass |
|---|---|---|---|
| 1 | isbn10 | 127,729 | → `books_work_isbn10` |
| 2 | isbn13 | 128,801 | → `books_work_isbn13` |
| 3 | asin | 10,329 | → `books_work_isbn10` (if ISBN-10-shaped) else `books_work_asin` |
| 4 | ean13 | 315 | → `books_work_ean13` |
| 5 | goodreads | 154,524 | already migrated (unchanged) → `books_work_goodreads_id` |

Types 1-4 = **267,174** rows across **106,174** distinct books; **74,136** of those books have **no edition** (only 32,038 do). Type-3 sample: ~13% start with `B` (real Kindle ASIN), ~87% look like ISBN-10. Values: 0 blank, 0 with dash/space.

`editions.identifiers` (jsonb, present on all 148,296 editions; keys `isbn_10`/`isbn_13`/`ean` are **arrays**, `asin` is a **string**):

| jsonb key | shape | this pass |
|---|---|---|
| `isbn_10` | Array | → `books_work_isbn10` (one row per element) |
| `isbn_13` | Array | → `books_work_isbn13` |
| `ean` | Array | → `books_work_ean13` |
| `asin` | String | → `books_work_isbn10` (if ISBN-10-shaped) else `books_work_asin` |

Multi-valued arrays occur (sampled 21,475 editions: 543 with >1 ean, 114 with >1 isbn_10, 2 with >1 isbn_13). Est. ~2.1 values/edition → **~311k** edition-sourced values (pre-dedup). Every legacy `edition.book_id` resolves to a migrated `Books::Book` (all 148,296 editions migrated with `book_id` passthrough) — fail-loud is a safety net, not an expected path.

## Schema change (code-only, no DB migration)

`identifier_type` is already an `integer` column. Add four values to `Identifier`'s enum in the free work-level slots (existing `books_work_*` use 0-4):

```ruby
books_work_isbn13: 5,
books_work_isbn10: 6,
books_work_asin: 7,
books_work_ean13: 8,
```

No migration, no index change (the unique lookup index is type-agnostic). Update the annotated schema comment in `identifier.rb`.

## Source → target implementation

### Shared helper in `IdentifierMigrator` (base)

A pure class method, testable in isolation and shared by both migrators:

```ruby
ISBN10_SHAPE = /\A\d{9}[\dX]\z/i

# Given a legacy "asin" value, return the work-level identifier_type symbol:
# ISBN-10-shaped -> :books_work_isbn10, else -> :books_work_asin.
def self.asin_identifier_type(value)
  ISBN10_SHAPE.match?(value.to_s.strip) ? :books_work_isbn10 : :books_work_asin
end
```

### Migrator 1 — extend `BookIdentifierMigrator` (`book_identifiers` types 1-4)

Currently emits only type-5 (goodreads). Extend `upsert_row` to also map types 1-4 to work-level identifiers on `Books::Book` (`book_id` preserved = direct). Type→symbol:

| type | symbol |
|---|---|
| 1 | `:books_work_isbn10` |
| 2 | `:books_work_isbn13` |
| 3 | `asin_identifier_type(value)` |
| 4 | `:books_work_ean13` |
| 5 | `:books_work_goodreads_id` (unchanged) |

Any other type → skip (defensive). `identifiable_id = attrs["book_id"]`, `value = attrs["identifier"]`. Update the class comment (the "types 1..4 are deferred" note is now fulfilled) and `model_key` (e.g. `"Identifier (book_identifiers)"`).

### Migrator 2 — new `EditionIsbnIdentifierMigrator` (`editions.identifiers` jsonb)

`< IdentifierMigrator`, `legacy_model = LegacyBooks::Edition`, `model_key = "Identifier (edition ISBN)"`. `upsert_row` reads `attrs["identifiers"]` (a Hash from the jsonb column; guard non-Hash/nil), resolves `book_id = attrs["book_id"]` (preserved = the `Books::Book` id directly), and for each value emits a work-level identifier on `Books::Book`:

- `Array(ids["isbn_10"])` → `:books_work_isbn10`
- `Array(ids["isbn_13"])` → `:books_work_isbn13`
- `Array(ids["ean"])` → `:books_work_ean13`
- `Array(ids["asin"])` → `asin_identifier_type(each)` (`Array("B0…")` wraps the string uniformly; `Array(nil)` = `[]`)

Each value: `to_s.strip`, skip blank (handled by `upsert_identifier`). Multi-valued arrays fan out to one `upsert_identifier` call per element. No `LegacyIdMap` needed (book ids preserved; editions are only *read* here, not their new ids).

### Dedup semantics

`upsert_identifier` is `find_or_create_by!` on `(identifiable_type, identifier_type, value, identifiable_id)`. Therefore:
- The same ISBN present in both `book_identifiers` and an edition's jsonb → one row.
- The same ISBN across two editions of the same book → one row (both fold to the same `Books::Book`).
- A physical book's ISBN-10 arriving as both type-1 and (reclassified) type-3 → one `books_work_isbn10` row.
- A number that is both an `isbn_13` and an `ean` value → **two** rows (`books_work_isbn13` + `books_work_ean13`, different types) — intended (D4).

### Orchestration

`data_migration:identifiers` runs, in order: `BookIdentifierMigrator` (now incl. ISBN), `BookWorkIdentifierMigrator`, `AuthorIdentifierMigrator`, `EditionIdentifierMigrator`, **`EditionIsbnIdentifierMigrator`** (new, appended). `:all` is unchanged (it already includes `:identifiers`). Both new-work migrators require only `books` migrated (already ordered before `identifiers`).

## Performance

~267k + ~311k = ~578k `find_or_create_by!` calls (~4× the proven 154k goodreads run). On a resync (rows already present) each is a single indexed SELECT on the unique index (no `Books::Book` load, since `create!`/validation only fires on insert). Acceptable for a periodic full sync. **Escape hatch (documented, not built):** if a run is too slow, port both to `BulkUpsertMigrator` (batched `upsert_all`, `unique_by: :index_identifiers_on_lookup_unique`, `ON CONFLICT DO NOTHING`) — which then requires (a) in-batch dedup by natural key and (b) a `@known_book_ids` preload that RAISES on an unknown `book_id` (mirroring `CategoryItemMigrator`) to keep fail-loud, since the polymorphic column has no FK.

## Testing (Minitest + Mocha, stub `legacy_each`)

`BookIdentifierMigrator` test (update existing):
- **Flip** the "ignores non-goodreads types (isbn/asin/ean deferred)" test → now asserts types 1-4 migrate to the correct work-level types.
- type 1 → `books_work_isbn10`; type 2 → `books_work_isbn13`; type 4 → `books_work_ean13`.
- type 3 ISBN-10-shaped (`"0375755349"`) → `books_work_isbn10`; type 3 Kindle (`"B01K0T9772"`) → `books_work_asin`; type 3 with `X` check digit (`"037575534X"`) → `books_work_isbn10`.
- type 5 still → `books_work_goodreads_id` (regression).
- idempotent on rerun; search suppression (`SearchIndexRequest` unchanged); fail-loud when `book_id` has no `Books::Book`.

`EditionIsbnIdentifierMigrator` test (new):
- jsonb with `isbn_10`/`isbn_13`/`ean`/`asin` populated → correct types on the parent `Books::Book` (via `book_id`).
- multi-valued array (`ean: ["x","y"]`) → two rows.
- `asin` reclassification (ISBN-10-shaped vs `B0…`).
- empty/`{}`/nil/non-Hash `identifiers` → no rows, no error.
- cross-source dedup: a value already inserted by `BookIdentifierMigrator` is not duplicated.
- idempotent; search suppression; fail-loud on missing `Books::Book`.

`IdentifierMigrator` test (extend): unit-test `asin_identifier_type` (ISBN-10, ISBN-10-with-X, `B0…`, blank/nil, 13-digit).

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the migrated baseline, run `data_migration:identifiers`, then verify:
- New work-level ISBN identifier counts by type are non-zero and stable across a second run (idempotency); `Identifier.count` unchanged on rerun.
- Spot-check a known physical book: its ISBN-10/13 present as `books_work_isbn10/13`; a known Kindle-only book: `books_work_asin` present, not misfiled as isbn10.
- 0 identifiers point at a nonexistent `Books::Book` (fail-loud held).
- `pending_index`/`SearchIndexRequest` unchanged (search suppression held).
- Full test suite green (`bin/rails test`), standardrb + brakeman clean.

## Out of scope
- Edition-level ISBN identifiers (`books_edition_isbn*`) — deferred to the future ISBN-lookup service (D1).
- `librarything`, `bookshop_org`, OCLC, wikidata, google identifiers (not in the legacy ISBN family).
- ISBN normalization/validation/reformatting, cross-type dedup of isbn13-vs-ean13 (D4).
- Any change to the already-migrated goodreads/openlibrary identifiers.

## References
- Parent design: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`
- Prior increment (identifiers): `docs/superpowers/specs/2026-07-04-books-identifiers-migration-design.md` + plan
- `Identifier` model/enum: `web-app/app/models/identifier.rb`
- Existing identifier migrators: `web-app/app/lib/services/books_migration/{identifier,book_identifier,book_work_identifier,edition_identifier,author_identifier}_migrator.rb`
