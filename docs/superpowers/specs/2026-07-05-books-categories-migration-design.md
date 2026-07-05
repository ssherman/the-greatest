# Books Categories Migration (categories + category_items) — Design

**Status:** Approved 2026-07-05.
**Scope:** One migration increment on top of Phase 1a/1b + editions + identifiers (all merged): migrate legacy `categories` → STI `Books::Category` (fresh id + `LegacyIdMap`, **slug preserved**) and legacy `book_categories` → the polymorphic `category_items` join. Introduces a reusable `BulkUpsertMigrator` base for high-volume join/child tables (reused by Phase 3's `user_list_items`).
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.

## Goal

Populate `categories` (STI `Books::Category`) and `category_items` (polymorphic) from the two legacy tables, writing categories through the real `Books::Category` model (so STI, enums, and validations apply) with their **legacy slug preserved verbatim**, and loading the ~1.8M join rows through a batched `upsert_all` with search suppressed and idempotency on the natural keys.

## Framework reused (already on `main`)

`Services::BooksMigration::Migrator` base (batched streaming via `legacy_each`, idempotent, `without_search_indexing`, per-row error context, subclass hooks `legacy_model`/`model_key`/`upsert_row`/optional `finalize`), `LegacyBooks::Record` read-only replica base, `LegacyIdMap.record/lookup`, `data_migration:*` rake orchestrator.

## Legacy data (local restore, introspected 2026-07-05)

`categories` (73,913 rows):

| Fact | Value |
|---|---|
| `deleted = true` | 21,182 (28%) — **migrated**, flag preserved |
| `name` null/blank | 0 |
| `slug` null/blank | 0; **globally unique** (0 dupes across all rows incl. deleted) |
| `parent_category_id` present | 51; **0 orphans**, 0 non-deleted-child-of-deleted-parent |
| `merged_category_names` non-empty | 1,372 (Postgres text array) |
| `category_type` | 0=genre 20,254 / 1=location 16,690 / 2=subject 36,969 |
| `import_source` | nil 356 / 0=amazon 2,274 / 1=open_library 18,942 / 2=openai 51,612 / 3=goodreads 729 |

`book_categories` (1,828,730 rows):

| Fact | Value |
|---|---|
| `deleted = true` | 0 (the "skip deleted book_categories" rule in the parent design is a no-op) |
| null `book_id`/`category_id` | 0 |
| `category_id` not in `categories` | 0 |
| `book_id` not in `books` | 0 (all books migrate) |
| points to a **soft-deleted** category | **915** → **NOT migrated** (legacy data-corruption, owner decision) |
| duplicate `[category_id, book_id]` pairs | 0 |
| **net rows migrated** | **1,827,815** |

Legacy `categories` columns used: `id, name, description, import_source, slug, merged_category_names, deleted, category_type, parent_category_id`. Ignored: `book_count` (recomputed as `item_count`), `primary`, `location`, `ai_fix_response`, `created_at/updated_at`. Legacy `book_categories` columns used: `book_id, category_id` (its `id`, `deleted`, timestamps are not needed).

## Source → target mapping

### `categories` → `Books::Category` (fresh id + `LegacyIdMap`, slug preserved)

| new `categories` (`type = "Books::Category"`) | from legacy `categories` | handling |
|---|---|---|
| `name` | `name` | direct |
| `description` | `description` | direct |
| `category_type` | `category_type` | **direct int copy** — enums identical (`genre:0, location:1, subject:2`), new enum is a superset |
| `import_source` | `import_source` | **direct int copy** (nil stays nil; nullable) — enums identical (`amazon:0, open_library:1, openai:2, goodreads:3`), new is a superset |
| `deleted` | `deleted` | direct (incl. the 21,182 soft-deleted) |
| `slug` | `slug` | **preserved verbatim** (see below) |
| `alternative_names` | `merged_category_names` | `Array(...)` passthrough (NOT NULL default `[]`) |
| `parent_id` | `parent_category_id` | remapped through `LegacyIdMap` in `finalize` (self-referential) |
| `item_count` | — | recomputed in `CategoryItemMigrator.finalize` (default 0 until then) |

Dropped: `book_count`, `primary`, `location`, `ai_fix_response`.

**Enum int-copy (validated in console):** assigning the raw legacy integer to a Rails enum attribute maps it to the correct symbol (`category_type = 2` → `subject`; `import_source = 3` → `goodreads`; `nil` stays `nil`). No re-encoding — the landmine is `List.status`/`Edition.book_binding`, not these. The transformer passes the integer straight through.

**Slug preservation (the one novel behavior):** `Books::Category` uses `friendly_id :name, use: [:slugged, :scoped, :finders], scope: :type`, and `should_generate_new_friendly_id?` returns `slug.blank? || name_changed?`. On a fresh AR insert `name_changed?` is true, so a naive `save!` **regenerates** the slug from the name and breaks the legacy URL (validated: legacy slug `metaphysical-visionary-fiction` is overwritten to `speculative-fiction`). To preserve the exact legacy slug, the migrator sets `slug` and defines a **per-instance** override before `save!`:

```ruby
category.assign_attributes(CategoryTransformer.call(attrs)) # includes slug
def category.should_generate_new_friendly_id? = false
category.save!
```

This is localized to the migrator (the app model is untouched, keeps its normal regenerate-on-rename behavior) and is validated to keep the assigned slug byte-for-byte. Legacy slugs are globally unique, so there is no collision within `Books::Category` (the `(type, slug)` index is non-unique regardless).

**Parent remap (self-referential, 51 rows):** categories get fresh ids, so `parent_category_id` must be remapped. The migrator stashes `[legacy_id, parent_legacy_id]` for each parented row during the main pass, then in `finalize` resolves **both** ends through `LegacyIdMap` and `Books::Category.where(id: child_new_id).update_all(parent_id: parent_new_id)`. `update_all` bypasses FriendlyId (no slug regen) and callbacks, and touches only the new DB (`LegacyIdMap` + `categories`) so migrator tests stay connection-free. `finalize` runs after the full pass, so every parent is already mapped; 0 orphans means every link resolves.

### `book_categories` → `category_items` (bulk `upsert_all`, natural key)

| new `category_items` | from legacy `book_categories` | handling |
|---|---|---|
| `category_id` | `category_id` | remapped via the **active-only** category map (see below); row dropped if unmapped |
| `item_type` | — | constant `"Books::Book"` |
| `item_id` | `book_id` | direct (books preserve their id) |

**Active-only category map:** `preload_context` builds `{legacy_category_id → new_id}` from `LegacyIdMap` joined to `categories` filtered `deleted = false`:

```ruby
LegacyIdMap.where(model: "Books::Category")
  .joins("INNER JOIN categories ON categories.id = legacy_id_maps.new_id")
  .where(categories: {deleted: false})
  .pluck(:legacy_id, :new_id).to_h
```

Because the map contains only active categories, the 915 `book_categories` rows pointing at soft-deleted categories get no hit and are skipped — exactly the owner's "don't migrate the corrupt rows" decision, with no extra branching.

## Reusable base: `BulkUpsertMigrator < Migrator`

High-volume join/child tables can't use the per-row `upsert_row` path (1.8M individual AR saves). `BulkUpsertMigrator` overrides `call` to stream legacy rows, map each to 0+ target-row hashes, buffer, and `upsert_all` per batch:

```ruby
class BulkUpsertMigrator < Migrator
  UPSERT_BATCH = 1000

  def call
    @count = 0
    buffer = []
    preload_context
    Services::BooksMigration.without_search_indexing do
      legacy_each do |attrs|
        build_rows(attrs).each { |row| buffer << row }
        if buffer.size >= UPSERT_BATCH
          flush(buffer)
          buffer = []
        end
      rescue => e
        raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows upserted): #{e.message}"
      end
      flush(buffer) if buffer.any?
    end
    finalize
    {success: true, data: {model: model_key, count: @count}}
  rescue => e
    {success: false, error: e.message, data: {model: model_key, count: @count}}
  end

  private

  def preload_context
  end

  def flush(rows)
    target_model.upsert_all(rows, unique_by: unique_by, record_timestamps: true)
    @count += rows.size
  end
end
```

Subclass contract: `legacy_model`, `model_key`, `target_model`, `unique_by`, `build_rows(attrs) -> [Hash, ...]`; optional `preload_context`, `finalize`. `record_timestamps: true` satisfies the NOT-NULL `created_at`/`updated_at`, is idempotent on `unique_by`, and preserves `created_at` on re-run (validated in Rails 8.1). Each `upsert_all` batch is its own statement/transaction — no giant wrapping transaction; a mid-run failure leaves prior batches committed and the run resumes idempotently.

`CategoryItemMigrator` sets `target_model = CategoryItem`, `unique_by = :index_category_items_on_category_id_and_item_type_and_item_id`, and `finalize` recomputes `item_count`:

```sql
UPDATE categories c
SET item_count = (SELECT COUNT(*) FROM category_items ci WHERE ci.category_id = c.id)
WHERE c.type = 'Books::Category';
```

Correlated form so every `Books::Category` (including soft-deleted / empty ones) is set to its true count (0 where none), scoped to `Books::Category` so other domains' counts are untouched. `upsert_all` bypasses the `counter_cache` and the `after_save` reindex callback (validated), so this one set-based pass is the only counter maintenance and there is no `SearchIndexRequest` flood.

## Idempotency & search

- **Categories:** `LegacyIdMap` keyed `("Books::Category", legacy_id)` — first run inserts + records, re-runs `find(new_id)` + update. Fresh ids (categories is a shared table; legacy category ids would collide with music/games categories), matching the languages/editions pattern.
- **category_items:** the `(category_id, item_type, item_id)` unique index; `upsert_all` ON CONFLICT is a no-op for existing rows. No `LegacyIdMap` for the join.
- **Search:** categories write through AR inside `without_search_indexing`; `Books::Category` has no search callbacks of its own, and the `category_items` `upsert_all` bypasses `CategoryItem`'s `after_save` reindex entirely. No reindex step.
- **Deletes not propagated** (parent-design invariant); counts only grow across reruns.

## Dependency order & orchestration

Runs after `identifiers`, before Phase 2's `lists`:

```
… editions → identifiers → categories → category_items → (Phase 2: lists …)
```

`data_migration:categories` (CategoryMigrator) and `data_migration:category_items` (CategoryItemMigrator) are independently runnable; `category_items` depends on `categories` (needs the id-map). `:all` becomes `[:languages, :authors, :books, :book_authors, :editions, :identifiers, :categories, :category_items]`.

## Files

Create:
- `web-app/app/models/legacy_books/category.rb` (`self.table_name = "categories"`)
- `web-app/app/models/legacy_books/book_category.rb` (`self.table_name = "book_categories"`)
- `web-app/app/lib/services/books_migration/category_transformer.rb`
- `web-app/app/lib/services/books_migration/category_migrator.rb`
- `web-app/app/lib/services/books_migration/bulk_upsert_migrator.rb`
- `web-app/app/lib/services/books_migration/category_item_migrator.rb`
- Tests for each of the above (transformer, both migrators, and the bulk base).

Modify:
- `web-app/lib/tasks/data_migration.rake` — add `:categories` + `:category_items`; wire into `:all` after `:identifiers`.

## Testing (Minitest + Mocha, connection-free)

Stub `legacy_each` with `multiple_yields`; never open the legacy connection. `finalize` in both migrators touches only the new DB (`LegacyIdMap` / `categories` / `category_items`), so it runs in tests.

- **`CategoryTransformer`** (pure): name/description/deleted passthrough; `category_type`/`import_source` int copy (incl. `import_source` nil → nil); `merged_category_names` array → `alternative_names`; nil array → `[]`; `slug` passthrough.
- **`CategoryMigrator`**: fresh id + `LegacyIdMap` recorded; **slug preserved** even though it differs from `name.parameterize` (the key assertion); soft-deleted category migrated with `deleted: true`; idempotent re-run (no dup, map stable, updates in place); `parent_id` remapped in finalize through the map (parent + child in the same run); search suppressed.
- **`BulkUpsertMigrator`** (via a tiny test subclass or through `CategoryItemMigrator`): batches across the `UPSERT_BATCH` boundary; `build_rows` returning `[]` contributes nothing; idempotent; per-row error context includes the legacy id.
- **`CategoryItemMigrator`**: maps `category_id` via the active map; `item_type`/`item_id` correct; **row whose category is soft-deleted (absent from the active map) is skipped**; idempotent on the unique key (re-run no dup); `finalize` recomputes `item_count` (including 0 for an empty/soft-deleted category); search indexing suppressed (no `SearchIndexRequest`).

## End-to-end verification (real legacy DB, dev target)

Run against the populated dev DB (books/authors/editions already migrated). The `categories` pass is ~74k AR upserts (minutes); the `category_items` pass is ~1.8M rows in ~1,828 `upsert_all` batches.

```bash
bin/rails data_migration:categories
bin/rails data_migration:category_items
bin/rails runner 'puts "cats=#{Books::Category.count} deleted=#{Books::Category.where(deleted: true).count} parented=#{Books::Category.where.not(parent_id: nil).count} items=#{CategoryItem.where(item_type: "Books::Book").count} pending_book_index=#{SearchIndexRequest.where(parent_type: "Books::Book").count}"'
```

Expected: both migrators `{success: true, ...}`; `cats=73913`, `deleted=21182`, `parented=51`, `items≈1827815` (915 corrupt rows dropped), `pending_book_index` unchanged. Spot-checks:
- A known slug survives verbatim: `Books::Category.find_by(slug: "metaphysical-visionary-fiction")` is present (name "Speculative Fiction").
- `item_count` is populated: top categories by `item_count` match the legacy `book_count` order (Fiction, Nonfiction, …), soft-deleted categories have `item_count = 0`.
- No `category_items` reference a soft-deleted category:
  `CategoryItem.joins("JOIN categories c ON c.id = category_items.category_id").where(categories: {deleted: true}).count` = 0.

> A `{success: false, ...}` result names the offending legacy row id and the count that succeeded; the run is idempotent, so it resumes.

## Out of scope

Legacy `deleted_categories` (a separate table), category images, and any category→author `category_items` (legacy only relates categories to books). Edition-level ISBN follow-up (`book_identifiers` types 1-4 + `editions.flat_identifiers`) remains deferred from the identifiers increment.
