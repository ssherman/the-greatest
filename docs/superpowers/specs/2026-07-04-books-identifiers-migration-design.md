# Books Identifiers Migration (work + author level) — Design

**Status:** Approved 2026-07-04.
**Scope:** One migration increment on top of Phase 1a/1b + editions (all merged): migrate the legacy identifier data that attaches to entities which always exist (`Books::Book`, `Books::Author`, the 18 editions that carry one) into the polymorphic `identifiers` table. **Edition-level ISBN/ASIN/EAN placement is explicitly deferred** to a separate follow-up.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.

## Goal

Populate `identifiers` (polymorphic) with the work-level and author-level external ids from four legacy sources, writing through the real `Identifier` model, search suppressed, idempotent via the identifier's natural key.

## Framework reused (already on `main`)

`Services::BooksMigration::Migrator` base (batched, idempotent, `without_search_indexing`, per-row error context, subclass hooks `legacy_model`/`model_key`/`upsert_row`/optional `finalize`), `LegacyBooks::{Record,Book,Author,Edition}` read-only replica models, `LegacyIdMap.record/lookup` (editions have fresh ids + a map from the editions increment), `data_migration:*` rake orchestrator.

## Source → target mapping

| Legacy source | Rows | Value handling | Target `identifiable` | `identifier_type` |
|---|---|---|---|---|
| `book_identifiers` **type 5** (goodreads) | 154,524 | as-is (bare numeric, e.g. `"1079398"`) | `Books::Book`, id = `book_id` (preserved) | `books_work_goodreads_id` (3) |
| `books.goodreads_id` | 3,406 | as-is | `Books::Book`, id = `book.id` | `books_work_goodreads_id` (3) |
| `books.ol_work_id` | 31,602 | strip OL key (`/works/OL20600W` → `OL20600W`) | `Books::Book`, id = `book.id` | `books_work_openlibrary_id` (2) |
| `authors.ol_author_id` | 16,542 | strip OL key (`/authors/OL…A`) | `Books::Author`, id = `author.id` (preserved) | `books_author_openlibrary_id` (33) |
| `editions.ol_edition_id` | 18 | strip OL key (`/books/OL…M`) | `Books::Edition`, id via `LegacyIdMap.lookup("Books::Edition", legacy_edition_id)` | `books_edition_openlibrary_id` (16) |

Legacy `book_identifiers` columns: `id, identifier, identifier_type, book_id` (clean — 0 null/blank values, 0 natural-key dupes; the value column is `identifier`, the FK is `book_id`). Book/author ids are preserved, so their identifiable_id is the legacy id directly. Editions have fresh ids, so the legacy edition id is remapped through `LegacyIdMap`. All values fit `Identifier.value` (≤255; observed max 119).

**OpenLibrary key normalization:** the legacy OL columns store the path form (`/works/OL20600W`, `/authors/OL9100206A`, `/books/OL25955852M`). Store the bare canonical key (`OL20600W`) — the `identifier_type` already encodes work/author/edition, so the prefix is redundant. Rule: take the basename after the last `/`, blank→nil. Goodreads ids are bare and stored verbatim.

**Design note:** the parent design said drop `ol_work_id`; the owner reversed that — OpenLibrary work ids are real, stable external identifiers (31,602 of them) worth keeping even though OpenLibrary isn't queried today. `ol_work_id`, `ol_author_id`, `ol_edition_id` are all genuine OL keys (confirmed), not local PK ints. `books.ol_work_id` is NOT the same as the (unused) `books_work_oclc/wikidata` — it maps to `books_work_openlibrary_id`.

## Idempotency

`Identifier` has a DB UNIQUE index on `(identifiable_type, identifier_type, value, identifiable_id)`, so each row is a `find_or_create_by!` on that natural key. **No `LegacyIdMap` for the identifiers themselves** — the natural key is the dedup. Re-running creates no duplicates. The two goodreads sources (`book_identifiers` type 5 and `books.goodreads_id`) both target `books_work_goodreads_id` on the same book; identical values collapse to one row, distinct values coexist (both valid).

## Architecture

One migrator per legacy source table (each fits the base `Migrator`'s single-`legacy_model` streaming and reuses batching + search suppression + per-row error context). A shared base holds the two cross-cutting helpers:

- `IdentifierMigrator < Migrator` (shared): `upsert_identifier(identifiable_type:, identifiable_id:, identifier_type:, value:)` — skips nil/blank `value` and `find_or_create_by!`s the natural key; and the pure `strip_openlibrary_key(value)` (basename after last `/`, blank→nil).
- `BookIdentifierMigrator` — legacy `book_identifiers`; for **type-5 (goodreads) rows only** → Book `books_work_goodreads_id` (id = `book_id`). Types 1-4 (ISBN/ASIN/EAN) are skipped (deferred).
- `BookWorkIdentifierMigrator` — legacy `books`; `ol_work_id` → Book `books_work_openlibrary_id`, `goodreads_id` → Book `books_work_goodreads_id` (id = `book.id`); a book may yield 0–2 identifiers.
- `AuthorIdentifierMigrator` — legacy `authors`; `ol_author_id` → Author `books_author_openlibrary_id` (id = `author.id`).
- `EditionIdentifierMigrator` — legacy `editions`; `ol_edition_id` → Edition `books_edition_openlibrary_id` (id via `LegacyIdMap.lookup`; skip if the map has no entry — shouldn't happen since editions migrated first).

The `books`/`authors`/`editions` migrators scan their full source table and skip rows with no relevant identifier (acceptable one-time full read). Only `LegacyBooks::BookIdentifier` (`self.table_name = "book_identifiers"`) is new.

## Search suppression

`Identifier` has no callbacks and its polymorphic `belongs_to :identifiable` has no `touch:`, and no `as_indexed_json` includes identifiers — so creating identifiers has zero search side effects. The base `Migrator` wraps the load in `without_search_indexing` regardless (belt-and-suspenders).

## Files

- Create `web-app/app/models/legacy_books/book_identifier.rb`.
- Create `web-app/app/lib/services/books_migration/identifier_migrator.rb` (shared base + helpers).
- Create the four concrete migrators under `web-app/app/lib/services/books_migration/`.
- Modify `web-app/lib/tasks/data_migration.rake` — add `data_migration:identifiers` (runs all four), wire into `:all` after `:editions`.
- Tests for the shared helper and each migrator.

## Testing

Connection-free unit tests (stub `legacy_each` with Mocha `multiple_yields`; never open the legacy connection):

- **`strip_openlibrary_key`** (pure): `/works/OL20600W`→`OL20600W`, already-bare passthrough, nil/blank→nil.
- **Each migrator:** creates the correct `identifier_type` on the correct `identifiable` with the right value (stripped for OL, verbatim for goodreads); idempotent (re-run no dupes on the natural key); nil/blank source value skipped; `BookIdentifierMigrator` ignores non-type-5 rows; `EditionIdentifierMigrator` resolves the new edition id via `LegacyIdMap`; search indexing suppressed during the load.

## End-to-end verification (real legacy DB, dev target)

Run `data_migration:identifiers`; each migrator returns `{success: true, ...}`. Expected identifier counts (approximate — natural-key overlap between the two goodreads sources collapses some): `books_work_goodreads_id` ≈ 154,524 + net-new from `books.goodreads_id`; `books_work_openlibrary_id` = 31,602; `books_author_openlibrary_id` = 16,542; `books_edition_openlibrary_id` = 18. `pending_book_index` unchanged. Spot-check a stripped OL value has no `/` prefix.

## Out of scope (deferred to a follow-up)

`book_identifiers` types 1-4 (isbn10/13, asin, ean13 — 267,174 rows) and `editions.flat_identifiers` (edition-level ISBN/ASIN array): the edition-level ISBN placement (source-of-truth between the two, plus the editionless-book fallback for the 69% of books with no edition). Also unchanged: `books.ol_work_id` was previously marked "drop" in the parent design — this increment keeps it (owner decision).
