# Books Editions Migration — Design

**Status:** Approved 2026-07-04 (one flagged decision — see `default_edition_id`).
**Scope:** A single migration increment on top of Phase 1a (languages/authors) and Phase 1b (books/book_authors, both merged): legacy `editions` → `books_editions`, plus the `default_edition_id` back-reference on the already-migrated `books_books`.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.

## Goal

Migrate the legacy `editions` table (148,296 rows) into `books_editions` with **fresh auto ids + `LegacyIdMap("Books::Edition")`** (the map is required by the later identifiers pass), writing through the real `Books::Edition` model, search suppressed. Then set `default_edition_id` on `books_books` for the books that have editions.

## Framework reused (already on `main`)

`Services::BooksMigration::Migrator` base (batched, idempotent, `without_search_indexing`, subclass hooks `legacy_model`/`model_key`/`upsert_row`/optional `finalize`, per-row error context), `LegacyBooks::Record` read-only replica base, `LegacyIdMap.record/lookup`, the `data_migration:*` rake orchestrator, and the pure-transformer pattern.

## Source → target field mapping

Legacy `editions` columns: `id, title, description, identifiers, ol_edition_id, metadata, publication_year, book_binding, book_id, last_refreshed, popularity, created_at, updated_at, flat_identifiers`.

New `books_editions` columns: `id, book_binding, edition_type(NOT NULL default standard), metadata(jsonb NOT NULL), page_count, popularity, publication_year, subtitle, title, volume_number, book_id(NOT NULL), language_id`.

| Legacy | New | Handling |
|---|---|---|
| `title` | `title` | direct (0 blank in legacy) |
| `publication_year` | `publication_year` | direct |
| `popularity` | `popularity` | direct (30,476 nil — allowed) |
| `book_binding` (int) | `book_binding` | **enum re-encode by symbol** (see below) |
| `metadata` (jsonb) | `metadata` | copy as-is; `nil` → `{}` (target is NOT NULL; all 148,296 rows have it) |
| `book_id` | `book_id` | direct **passthrough** — books preserve their id, so no remap. Set in the migrator (parent FK). |
| — | `edition_type` | **omit** → model default `:standard` |
| `description` | — | **drop** (0 non-blank in legacy; no target column) |
| `last_refreshed` | — | drop (no target column) |
| `language_id` | `language_id` = `nil` | legacy `editions` has **no language column** (the parent design's "remap language" was aspirational) |
| `ol_edition_id`, `identifiers`, `flat_identifiers` | — | **deferred to the identifiers increment** |

`subtitle`, `page_count`, `volume_number`: no legacy source → left nil.

The transformer is **pure** (String-keyed hash in → symbol-keyed attrs out, no DB): it returns `{title:, publication_year:, popularity:, book_binding:, metadata:}`. `book_id` (the parent FK, a direct passthrough) is set by the migrator; `language_id` has no legacy source and is left nil (the model defaults it). This mirrors the established transformer/migrator split.

## `book_binding` re-encoding (map by symbol — never copy ints)

Legacy enum: `{paperback:0, hardcover:1, ebook:2, audible:3, mass_market_paperback:4, audio:5, library_binding:6, collectable:7, leather_bound:8, other:9}`.
New `Books::Edition` enum: `{hardcover:0, paperback:1, mass_market:2, ebook:3, audiobook:4, library_binding:5, leather_bound:6, other:7}`.

Two-step map (legacy int → legacy symbol → new symbol), assigning the **new symbol** to the enum (never an int):

```
legacy int → legacy symbol → new symbol
0  paperback             → :paperback
1  hardcover             → :hardcover
2  ebook                 → :ebook
3  audible               → :audiobook
4  mass_market_paperback → :mass_market
5  audio                 → :audiobook
6  library_binding       → :library_binding
7  collectable           → :other        (0 rows in legacy)
8  leather_bound         → :leather_bound
9  other                 → :other
nil                      → nil
```

All legacy values present (0,1,2,3,4,5,6,8,9,nil) are covered. An unknown non-nil legacy value → **raise** (the base Migrator's per-row rescue names the offending edition's legacy id). This is the enum re-encoding landmine the parent design warns about; the two-step map makes the symbol mapping explicit.

Legacy `book_binding` distribution (for reference): 0→66,874 · 1→23,198 · 2→14,034 · 3→32,528 · 4→4,097 · 5→928 · 6→318 · 8→841 · 9→5,445 · nil→33.

## Id strategy & idempotency

Editions are not URL-facing, so they take **fresh auto ids** from the sequence (no explicit-id inserts, so **no `reset_pk_sequence!`** — unlike the preserved-id book/author migrators). Editions have no natural business key, so the **`LegacyIdMap` is the dedup key**:

```
new_id = LegacyIdMap.lookup(model: "Books::Edition", legacy_id: attrs["id"])
edition = new_id ? Books::Edition.find(new_id) : Books::Edition.new
edition.assign_attributes(EditionTransformer.call(attrs))
edition.book_id = attrs["book_id"]
edition.save!
LegacyIdMap.record(model: "Books::Edition", legacy_id: attrs["id"], new_id: edition.id)
```

`save!` + `LegacyIdMap.record` run in a **per-row transaction** so a crash between them can't leave a mapped-but-unrecorded edition that a re-run would duplicate. Re-running finds the existing edition via the map and updates it in place — idempotent.

## `default_edition_id` back-reference — ⚠️ flagged decision

**Data:** 87,536 of 126,204 books (69%) have **no** legacy edition; only 38,668 do.

**Decision (made in the owner's absence — confirm or override):** do **not** fabricate editions. In `finalize`, a single set-based SQL statement sets `default_edition_id` to each book's most-popular edition, for books that have editions only:

```sql
UPDATE books_books b
SET default_edition_id = e.id
FROM (
  SELECT DISTINCT ON (book_id) id, book_id
  FROM books_editions
  ORDER BY book_id, popularity DESC NULLS LAST, id ASC
) e
WHERE e.book_id = b.id;
```

The 87,536 editionless books keep `default_edition_id = NULL` (the FK is nullable, `ON DELETE nullify`). This statement bypasses AR callbacks entirely (no `SearchIndexRequest` flood — important because the base Migrator's `finalize` runs **outside** the `without_search_indexing` block, and `Books::Book` includes `SearchIndexable`). It is deterministic and idempotent (re-running recomputes the same pick).

**Rejected alternative:** synthesize a minimal edition (title = book title, `edition_type: :standard`) for each editionless book and point `default_edition_id` at it (the parent design's original wording). Rejected for now because it fabricates ~87,536 edition rows and the books public UI is still deferred, so nothing consumes `default_edition_id` yet — YAGNI. Easy to add later as an additive step if the UI needs a guaranteed default edition.

## Search suppression

The edition-creation pass runs inside the base Migrator's `without_search_indexing`. `Books::Edition` has no `SearchIndexable` include and no reindex callbacks, so it has no search side effects anyway (belt-and-suspenders). The `default_edition_id` `UPDATE` uses raw set-based SQL (no callbacks), so it also creates no index requests.

## Orchestrator

Add `data_migration:editions` (runs `Services::BooksMigration::EditionMigrator.call`); extend `:all` to `[:languages, :authors, :books, :book_authors, :editions]` (editions after books; independent of book_authors).

## Files

- Create `web-app/app/models/legacy_books/edition.rb` (`self.table_name = "editions"`).
- Create `web-app/app/lib/services/books_migration/edition_transformer.rb` (pure).
- Create `web-app/app/lib/services/books_migration/edition_migrator.rb` (fresh id + map, `finalize` = `default_edition_id` back-reference).
- Modify `web-app/lib/tasks/data_migration.rake`.
- Tests: `edition_transformer_test.rb`, `edition_migrator_test.rb`.

## Testing

Connection-free unit tests (stub `legacy_each` with Mocha `multiple_yields`; never open the legacy connection):

- **Transformer:** each legacy binding int maps to the correct new symbol; `audible` and `audio` both → `:audiobook`; `collectable` → `:other`; `nil` binding → `nil`; unknown int → raise; `metadata` nil → `{}`; `edition_type` not emitted (model default applies); pure (no DB).
- **Migrator:** creates editions with fresh ids, records `LegacyIdMap("Books::Edition")`, sets `book_id` directly; idempotent (re-run updates in place, no dupes, map stable); search indexing suppressed during load; `finalize` sets `default_edition_id` to the most-popular edition (popularity desc, nulls last, id asc tiebreak) and leaves a book with no editions at `NULL`.

## End-to-end verification (real legacy DB, dev target)

Run `data_migration:editions`; expect `EditionMigrator.call` → `{success: true, count: 148296}`; `Books::Edition.count == 148296`; `LegacyIdMap.where(model: "Books::Edition").count == 148296`; `Books::Book.where.not(default_edition_id: nil).count == 38668`; `pending_book_index == 0`. Proactively scan for legacy editions whose `book_id` has no migrated book (orphaned FK) before/after the run, the way the blank-title scan preempted issues in Phase 1b.

## Out of scope (per parent design)

Identifiers (`ol_edition_id`, `identifiers`/`flat_identifiers` jsonb, edition-level ISBN/ASIN → deferred to the identifiers increment), `book_versions`, edition `language_id` (no legacy source).
