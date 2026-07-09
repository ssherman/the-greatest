# Lists Migration (legacy `lists` + `list_items`) — Design

**Status:** Approved 2026-07-09.
**Scope:** Increment **2a** of Phase 2 (lists & rankings). Migrate the legacy `lists` table into the STI `Books::List` (**preserving ids**) and `list_items` into the polymorphic `list_items` (fresh ids, `listable = Books::Book`). No schema change. Unblocks 2b (ranking_configurations reference `lists` via `primary/secondary_mapped_list_id`; `ranked_lists` via `list_id`) and 2c (`list_penalties.list_id`).
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md` (§Lists, §Enum re-encoding cheatsheet).
**Depends on (all merged):** users (`submitted_by_id`), books (`list_items.listable = Books::Book`), and the Phase-0 `lists` id-range reservation (existing app lists sit at id ≥ 10,001; legacy ids 1–1,175 fit below with no collision, so **no `setval`**).

## Goal

Get all 1,030 legacy lists into `Books::List` with **ids preserved** and all 65,252 legacy `list_items` into `list_items`, faithfully, idempotently, and re-runnably.

## Legacy data (local restore, introspected 2026-07-09)

`lists`: **1,030 rows, max id 1,175**. `list_items`: **65,252 rows**. No `type` column on legacy `lists` (books-only app → constant `"Books::List"`).

Facts that drive the design:

| Fact | Value | Handling |
|---|---|---|
| `lists.status` distribution (old enum) | unapproved(0) 243, approved(1) 14, **active(2) 759**, rejected(3) 5, inactive(4) 3, pending(5) 6; **0 null** | **symbol-remap** (D-status) — a raw int copy would corrupt 759 `active`→`rejected` |
| `lists.name` | all present | direct (model requires presence) |
| `lists.url` | all present, **0 fail** the model's RFC2396 format | direct |
| `lists.estimated_quality` | all present (0 null) | direct (new col NOT NULL default 0) |
| `submitted_by_id` | 209 rows set / 11 distinct submitters, **0 missing** from migrated `User` | direct; fail-loud DB FK |
| `formatted_text` / `unformatted_text` | **627** / **0** populated | `simplified_content ← formatted_text`; `unformatted_text` ignored (always empty) |
| `raw_html` | **157** populated; **475 lists have formatted_text but blank raw_html** | `raw_content ← raw_html`; regenerating from raw_html would lose those 475 → **preserve** (D-simplified) |
| `books_json` (jsonb) | 567 null, 386 JSON-string (180 empty `""`), **77 real arrays** | **skipped** → `items_json` nil (D-items-json); real items live in `list_items` |
| `list_items.book_id` (nullable) | **0 null** | **no pending items** — `listable` is always a `Books::Book` |
| `list_items` orphan `list_id` | **0** | every item's list is among the 1,030 |
| `list_items` `book_id` missing from `Books::Book` | **0** of 24,362 distinct | fail-loud guard (D-li-failloud) |
| duplicate `[list_id, book_id]` | **0** | natural key clean → safe upsert, no intra-batch conflict |
| `list_items.position` | 38,183 null (58%), **0 ≤ 0** | null→null (model allows blank; non-null all > 0) |
| `pending_book_data` (text) | 948 non-blank, **mixed serialization**: 546 JSON objects `{"title":…,"authors":…}` + 402 YAML `--- !ruby/hash:ActiveSupport::HashWithIndifferentAccess\ntitle:…` (legacy Rails `serialize` drift) | `metadata ← parse(pending_book_data)` — parse **both** formats (D-metadata) |
| `list_items.verified` | no legacy column | default `false` |
| timestamps | `lists` and `list_items` `created_at` span years | **preserved** |

## Decisions

- **D-write-lists — `BulkUpsertMigrator` keyed on `:id`** (like `UserMigrator`). Lists preserve id, and bulk `upsert_all` **bypasses the `List` callbacks** — crucially `before_save :auto_simplify_content`, which would overwrite `simplified_content` by re-running `Services::Html::SimplifierService` on `raw_content` (see D-simplified) — and the validations. Legacy `created_at`/`updated_at` preserved (`record_timestamps?` = false). Idempotent on `id`.
- **D-status — symbol-remap** old `{unapproved:0, approved:1, active:2, rejected:3, inactive:4, pending:5}` → new `{unapproved:0, approved:1, rejected:2, active:3}` via the explicit map `{0=>0, 1=>1, 2=>3, 3=>2, 4=>0, 5=>0}` (inactive/pending have no new equivalent → `unapproved`). The migrator **raises** on any status int not in the map (fail-loud; all 1,030 rows are 0–5 today).
- **D-simplified — preserve legacy `formatted_text`** (owner decision, 2026-07-09): `simplified_content ← formatted_text`, `raw_content ← raw_html`. Regenerating `simplified_content` from `raw_html` via the new simplifier would set it nil for the 475 lists that have `formatted_text` but no `raw_html`. Bulk upsert (D-write-lists) is what makes preservation possible (the callback is bypassed). `unformatted_text` is always empty and ignored.
- **D-items-json — skip `books_json`** (owner decision, 2026-07-09): `items_json` is left **nil** for all lists. `books_json` is ~55% null / ~17% empty-string / only 7.5% real arrays, and the authoritative, structured item data is migrated into `list_items`. Avoids storing junk that would fail `items_json_format` on any later AR edit.
- **D-write-list-items — `BulkUpsertMigrator`** on the unique index `[list_id, listable_type, listable_id]` (like `CategoryItemMigrator`). All 65,252 rows have a non-null `book_id`, so there are **no NULL-in-unique-index** rows (Postgres treats NULLs as distinct, which would break upsert idempotency) and **no pending items**. The **0 duplicate `[list_id, book_id]`** finding guarantees no intra-batch `ON CONFLICT` double-touch. Legacy timestamps preserved.
- **D-li-failloud — guard the polymorphic `listable`.** `list_items.listable` has no DB FK (polymorphic), so a `book_id` with no migrated `Books::Book` would silently create a dangling item. `preload_context` loads the `Books::Book` id set; `build_rows` **raises** naming the legacy `list_item` id + `book_id` if the book is missing (mirrors `CategoryItemMigrator`). `list_id` has a real DB FK to `lists` (all present; lists migrate first).
- **D-metadata — parse `pending_book_data` (JSON *or* YAML) to a plain Hash** before upsert (plain jsonb column; a raw string would store as a jsonb string scalar). The legacy column mixes two serializations (Rails `serialize` drift): JSON objects (`{…}`) and YAML tagged `!ruby/hash:ActiveSupport::HashWithIndifferentAccess`. Detect by leading `---` → `YAML.safe_load(str, permitted_classes: [Symbol, ActiveSupport::HashWithIndifferentAccess], aliases: true)`, else `JSON.parse`, then `.to_h` (string keys, jsonb-storable). Blank → nil; an unparseable value raises (base rescue names the legacy id). All 948 real values verified to normalize to `{"title"=>…, "authors"=>…}`. (Discovered at e2e — the fail-loud guard correctly halted on the first YAML row rather than storing junk.)
- **D-no-finalize — none.** No counter caches on `lists`/`list_items`; sequence already reserved (no `setval`).

## Schema change

**None.** `lists` and `list_items` already have every needed column. No new index.

## Source → target mapping

### `lists` → `lists` (preserve id, `type = "Books::List"`)

| new column | legacy source | handling |
|---|---|---|
| `id` | `id` | **preserved** (unique_by :id) |
| `type` | (constant) | `"Books::List"` |
| `name` | `name` | direct |
| `description` | `description` | direct |
| `source` | `source` | direct |
| `url` | `url` | direct (all valid) |
| `status` | `status` | **symbol-remap** `{0=>0,1=>1,2=>3,3=>2,4=>0,5=>0}` (D-status) |
| `year_published` | `year_published` | direct |
| `number_of_voters` | `number_of_voters` | direct |
| `estimated_quality` | `estimated_quality` | direct (NOT NULL; all present) |
| `submitted_by_id` | `submitted_by_id` | direct (users preserved; DB FK) |
| `high_quality_source`, `category_specific`, `location_specific`, `yearly_award`, `voter_count_unknown`, `voter_names_unknown` | same names | direct (null→null) |
| `raw_content` | `raw_html` | direct |
| `simplified_content` | `formatted_text` | direct (D-simplified) |
| `items_json` | — | **nil** (D-items-json) |
| `created_at` / `updated_at` | same | **preserved** |

Left null/default (no legacy equivalent): `creator_specific`, `num_years_covered`, `source_country_origin`, `voter_count_estimated`, `wizard_state`, `musicbrainz_series_id`.
Dropped legacy columns: `lp_css_selector_mappings`, `ranked`, `ai_generated_description`, `percentage_western`, `unformatted_text` (empty).

### `list_items` → `list_items` (fresh id, natural key `[list_id, listable_type, listable_id]`)

| new column | legacy source | handling |
|---|---|---|
| `id` | — | fresh (auto) |
| `list_id` | `list_id` | direct (lists preserve id; DB FK) |
| `listable_type` | (constant) | `"Books::Book"` |
| `listable_id` | `book_id` | direct (books preserve id); fail-loud guard (D-li-failloud) |
| `position` | `position` | direct (null→null) |
| `metadata` | `pending_book_data` | **parsed** to Hash (D-metadata); blank → nil |
| `verified` | — | `false` |
| `created_at` / `updated_at` | same | **preserved** |

## Migrators

- **`Services::BooksMigration::ListMigrator`** — `BulkUpsertMigrator`: `legacy_model = LegacyBooks::List` (new read-only model, `table_name = "lists"`), `target_model = List`, `unique_by: :id`, `record_timestamps?` = false. `build_rows` maps per the table above with a private `remap_status` (explicit hash, raises on unknown) — inline, mirroring `UserMigrator` (no separate transformer for bulk migrators). No `finalize`.
- **`Services::BooksMigration::ListItemMigrator`** — `BulkUpsertMigrator`: `legacy_model = LegacyBooks::ListItem` (`table_name = "list_items"`), `target_model = ListItem`, `unique_by: :index_list_items_on_list_and_listable_unique`, `record_timestamps?` = false. `preload_context` builds the `Books::Book` id set; `build_rows` sets `listable = Books::Book`, parses `pending_book_data`, and raises on a missing book (D-li-failloud). No `finalize`.
- New read-only legacy models `LegacyBooks::List` and `LegacyBooks::ListItem`.

## Orchestration

Add `data_migration:lists` (→ `ListMigrator.call`) and `data_migration:list_items` (→ `ListItemMigrator.call`). Insert into `data_migration:all` after the existing entries, **`:lists` before `:list_items`** (list_items' FK + guard need lists + books), e.g. `[…, :category_items, :external_links, :lists, :list_items]`.

## Testing (Minitest + Mocha, stub `legacy_each`)

**ListMigrator:**
- Maps a fully-populated legacy list → `Books::List` with id preserved, `type = "Books::List"`, `raw_content ← raw_html`, `simplified_content ← formatted_text`, `items_json` nil, booleans + submitter direct, timestamps preserved.
- **status remap:** each of 0–5 → correct new value (`2→active(3)`, `3→rejected(2)`, `4→unapproved`, `5→unapproved`); an unknown status int **raises** (result `success: false`, error names the legacy id).
- `auto_simplify_content` does **not** run: a list with `raw_html` present keeps `simplified_content` = the legacy `formatted_text` (not the simplifier's output) — proves the callback is bypassed.
- Idempotent: re-run leaves `List.count` unchanged, updates in place.

**ListItemMigrator:**
- Maps a legacy item → `list_items` row: `listable` = the `Books::Book`, `list_id` preserved, `position` direct, `verified` false, `metadata` = parsed `pending_book_data`, timestamps preserved.
- Null `position` and blank `pending_book_data` → null `position` / nil `metadata`.
- **Fail-loud:** a `book_id` with no `Books::Book` → `success: false`, error names the legacy `list_item` id.
- Idempotent on `[list_id, listable]`: re-run leaves count unchanged, no duplicates.

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the migrated baseline, run `data_migration:lists` then `:list_items` (twice), then verify:
- `List.where(type: "Books::List").count == 1030`; ids 1–1,175 present; **no collision** with the reserved ≥10,001 app lists.
- `status` distribution: `{unapproved: 252, approved: 14, rejected: 5, active: 759}` (252 = 243 unapproved + 3 inactive + 6 pending).
- `simplified_content` present on 627; `raw_content` present on 157; `items_json` null on all 1,030; timestamps preserved.
- `ListItem.where(listable_type: "Books::Book").count == 65252`; 0 rows with a null/dangling `listable_id`; `metadata` present on 948; distinct `list_id` = 761.
- Idempotent: second run leaves both counts unchanged.
- Full suite green; `standardrb` + `brakeman` clean (0 new).

## Out of scope
- `ranking_configurations`, `ranked_lists` (2b); penalties (2c).
- `books_json → items_json` (D-items-json); `ranked`, `lp_css_selector_mappings`, `ai_generated_description`, `percentage_western`.
- Re-simplifying `raw_html` through the new simplifier (D-simplified).

## References
- Parent design: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`
- Prior increment (template): `docs/superpowers/specs/2026-07-07-users-migration-design.md` (bulk, preserve id, timestamps) · `category_item_migrator.rb` (bulk join + fail-loud guard)
- `BulkUpsertMigrator`: `app/lib/services/books_migration/bulk_upsert_migrator.rb`
- `List` / `Books::List`: `app/models/list.rb`, `app/models/books/list.rb`; `ListItem`: `app/models/list_item.rb`
