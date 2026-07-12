# User Lists Migration (legacy `user_lists` + `user_list_books`) — Design

**Status:** Design approved by owner 2026-07-12 (all four decisions). Spec pending owner review.
**Scope:** **Phase 3** of the old-site data migration. Introduce the `Books::UserList` STI subclass, then migrate legacy **`user_lists`** (282,922) into `user_lists` and **`user_list_books`** (3,096,597) into `user_list_items`. No schema changes.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.
**Legacy feature reference:** `docs/old_site/user-lists-feature.md` (documents the legacy models, enums, and callbacks verbatim).
**Depends on (all merged):** users (ids preserved, all 69,459 present), books (ids preserved, all 126,204 present), Phase 2b (`Books::RankingConfiguration`, for `ranking_configuration_class`).

## The core problem

Two things have to happen together, and only one of them is a migration.

The new app already ships a **complete user-lists feature** — `UserList` (STI) + `UserListItem` (polymorphic `listable`), with live subclasses for Music (albums + songs), Games, and Movies, plus the whole `/my_lists` UI, policies, and Stimulus controllers. Books is the one domain with **no subclass**: `UserList::DOMAIN_SUBCLASSES` literally carries the comment *"Books has no subclass yet."*

So Phase 3 is: define `Books::UserList`, then bulk-load the legacy rows into the existing tables. The shapes line up closely — the new schema was clearly designed with the legacy one in view — but four things need explicit handling: the `list_type` enum integers differ, `view_mode` used `NULL` as its default member, `position` is nullable and drifted in legacy but is `NOT NULL` in the new schema, and three legacy columns have no new home.

## Legacy data (local restore, introspected 2026-07-12)

**`user_lists`** — 282,922 rows, ids **265,341–604,880**.

| column | notes |
|---|---|
| `list_type` | integer, **never NULL**. Legacy `enum :list_type, [:read, :reading, :want_to_read, :favorite, :custom]` → 0–4. Distribution: 0=**69,440**, 1=**69,423**, 2=**69,400**, 3=**69,428**, 4=**5,231**. |
| `view_mode` | integer, legacy `enum :view_mode, {default_view: nil, table_view: 1, grid_view: 2}` — **NULL is the default member**, not missing data. Distribution: NULL=**282,244**, 1=**422**, 2=**256**. |
| `public` | boolean, **nullable** (default false). true on **115** rows. |
| `position` | **NULL on all 282,922 rows** (legacy: "not auto-managed"). |
| `name` | NOT NULL, no blanks. |
| `greatest_books_list`, `best_ranked`, `date_read` | no new-schema home — see D-drop-dead-columns. |
| `user_id` | real FK to `users`. |

**`user_list_books`** — 3,096,597 rows, ids 4,114,631–10,556,871.

| column | notes |
|---|---|
| `position` | **779 rows NULL**; min 1, max 12,411; **689 `(user_list_id, position)` pairs duplicated**. |
| `read_date` | non-null on **79,721** rows — **all** of them on `list_type = 0` (read) lists. |
| `(user_list_id, book_id)` | UNIQUE in legacy. |
| `book_id` | real FK; **0** rows reference a book that isn't migrated (all 126,204 legacy books are in `books_books`). |
| distinct `book_id` | 112,405. |

**Cross-checks against the already-migrated target:**
- Every legacy `user_id` resolves: `users` holds all 69,459 legacy ids (preserved), plus new-app users relocated to ≥ 150,001.
- **No duplicate `(user_id, list_type)` among non-custom lists** — so `UserList#one_default_per_type_per_user` is satisfiable by the migrated data.
- Max lists held by a single user: 415.

**Existing target state (dev, pre-Phase-3):** `user_lists` 254 rows (ids 1,000,001–1,000,254; Music/Games/Movies), `user_list_items` 26 rows. The Phase-3 load is purely additive and cannot collide with either.

## The ID-preservation guarantee

`user_lists` is one of the three **reserved-ceiling tables** established in Phase 1 (`Services::BooksMigration::RESERVED_CEILINGS`):

```ruby
RESERVED_CEILINGS = {"users" => 150_000, "user_lists" => 1_000_000, "lists" => 10_000}
```

`IdRangeReservationService` already relocated the new-app `user_lists` rows above the ceiling and bumped the sequence. That service's own comment instructs: *"re-confirm the legacy MAX(id) is still well under each ceiling before the books import."* **Confirmed: legacy `MAX(user_lists.id) = 604,880`, comfortably under 1,000,000.** So `UserListMigrator` preserves legacy ids and upserts on `:id`.

`user_list_items` is **not** a reserved table (it's a child, and `FOREIGN_KEYS["user_lists"]` lists it only as an FK to remap). It therefore takes **fresh ids**, upserted on its natural key — exactly what `ListItemMigrator` does for `list_items`.

## Decisions

- **D-enum-convention — `Books::UserList` follows the new app's enum convention, and the migrator remaps by symbol.** Every other domain declares `favorites` (plural) at 0; legacy declares `favorite` (singular) at 3. Books gets `{favorites: 0, read: 1, reading: 2, want_to_read: 3, custom: 4}` and the migrator carries `LIST_TYPE_MAP = {3 => 0, 0 => 1, 1 => 2, 2 => 3, 4 => 4}`, fail-loud on an unmapped value. This is the same symbol-remap pattern as the Phase-2a `lists.status` remap. Safe because STI subclasses declare their `list_type` integers **independently** — `UserList#one_default_per_type_per_user` already notes this, and it scopes by `type` for exactly that reason.

- **D-normalize-positions — insert legacy `position` verbatim, then renumber every Books row to a contiguous 1..N in `finalize`.** The 779 NULLs go in as `NULL_POSITION_SENTINEL = 2_147_483_647` (int max: sorts last, and cannot collide — legacy max position is 12,411). `finalize` then runs a single `UPDATE … FROM ROW_NUMBER() OVER (PARTITION BY user_list_id ORDER BY position, id)` scoped to `ul.type = 'Books::UserList'`, which fixes the NULLs, the gaps, and the 689 duplicate-position ties in one statement. This reuses the exact SQL idiom already in `UserListItem#shift_positions_up`, and legacy itself shipped a `fix_positions` repair method for precisely this drift.

- **D-drop-dead-columns — drop `greatest_books_list`, `best_ranked`, and list-level `date_read`.** Evidence: `greatest_books_list` is **stale noise**, not derivable state. It is true on 51,128 favorite lists, but only **3,370** favorite lists contain any books at all — **50,840** of the flagged lists are *empty*, and **3,082** lists that do have books are *not* flagged. It correlates with nothing. `best_ranked` tracks it to within 3 rows. The community-ranking feature they fed (`GenerateRankedUsersList`) does not exist in the new app. List-level `date_read` is 48 rows and the legacy doc itself calls it *"largely unused"*. No schema change, nothing preserved.

- **D-verbatim-defaults — migrate exactly what legacy has; do not backfill missing default lists.** A handful of legacy users are missing one of their four defaults (19 missing read, 36 reading, 59 want_to_read, 31 favorites). Those users arrive without that list. The migrator stays a pure one-to-one copy that invents no rows; an idempotent "ensure defaults exist" path can be added later (legacy had exactly that, `ensure_list_type_exists`).

- **D-data-only — `Books::UserList` is defined but not wired into the UI or new-signup defaults.** It stays **out of** `UserList::DEFAULT_SUBCLASSES` and `UserList::DOMAIN_SUBCLASSES`. The books domain has no public routes, no book show page, and no `Search::ListableAutocomplete` config, so `/my_lists` on books would half-work. Wiring is **not** just those two constants — see `docs/features/user-lists.md` ("What's Not Yet Implemented") for the full follow-up list, in particular the `release_year` vs `first_published_year` landmine: `MyListsController`'s CSV export calls `listable.release_year`, which every other listable has but `Books::Book` does not, so a naive two-constant wiring would 500 on the first CSV download from a books list.

- **D-no-schema — no migration.** Both target tables, both enums, `completed_on`, and the natural-key unique index all already exist.

## Source → target mapping

### `user_lists` → `user_lists` (STI `Books::UserList`, id preserved)

| target column | source | notes |
|---|---|---|
| `id` | `id` | preserved (reserved range) |
| `type` | — | literal `"Books::UserList"` |
| `user_id` | `user_id` | real DB FK → fail-loud for free |
| `name` | `name` | verbatim |
| `description` | `description` | verbatim |
| `list_type` | `list_type` | `LIST_TYPE_MAP`, fail-loud on unmapped |
| `view_mode` | `view_mode` | `VIEW_MODE_MAP = {nil => 0, 1 => 1, 2 => 2}`, fail-loud on unmapped |
| `public` | `public` | coalesce NULL → `false` (legacy nullable → new `NOT NULL`) |
| `position` | `position` | all NULL; target column is nullable — pass through |
| `created_at` / `updated_at` | same | preserved |
| — | `greatest_books_list`, `best_ranked`, `date_read` | **dropped** (D-drop-dead-columns) |

### `user_list_books` → `user_list_items` (fresh id, natural key)

| target column | source | notes |
|---|---|---|
| `user_list_id` | `user_list_id` | ids preserved above, so this is a straight copy; real DB FK |
| `listable_type` | — | literal `"Books::Book"` |
| `listable_id` | `book_id` | **polymorphic — no DB FK**; guarded in Ruby (see below) |
| `position` | `position` | coalesce NULL → `NULL_POSITION_SENTINEL`, then renumbered in `finalize` |
| `completed_on` | `read_date` | verbatim |
| `created_at` / `updated_at` | same | preserved |

## Components

**1. `app/models/books/user_list.rb`** — `Books::UserList < ::UserList`

```ruby
has_many :items, through: :user_list_items, source: :listable, source_type: "Books::Book"
enum :list_type, {favorites: 0, read: 1, reading: 2, want_to_read: 3, custom: 4}
```

- `default_list_types` → `[:favorites, :read, :reading, :want_to_read]`
- `listable_class` → `Books::Book` (which already declares the reciprocal `has_many :user_list_items, as: :listable`)
- `default_list_name_for` → legacy names preserved: `"My Favorite Books"`, `"Books I've Read"`, `"Books I'm Reading"`, `"Books I Want to Read"`
- `list_type_icons` → `{favorites: "heart", read: "check", reading: "book-open", want_to_read: "bookmark"}`
- `completed_on_list_types` → `[:read]` (the only type legacy ever set `read_date` on)
- `ranking_configuration_class` → `Books::RankingConfiguration`
- `listable_display_includes` → `[:authors, :categories, :primary_image]`

**2. `app/models/legacy_books/user_list.rb` + `user_list_book.rb`** — read-only `table_name` shims on `LegacyBooks::Record`, same as every other legacy model.

**3. `app/lib/services/books_migration/user_list_migrator.rb`** — `BulkUpsertMigrator`, `target_model: UserList`, `unique_by: :id`, `record_timestamps?: false`. Holds `LIST_TYPE_MAP` and `VIEW_MODE_MAP`. Idempotent on id.

**4. `app/lib/services/books_migration/user_list_item_migrator.rb`** — `BulkUpsertMigrator`, `target_model: UserListItem`, `unique_by: :index_user_list_items_on_list_and_listable_unique`, `record_timestamps?: false`, `upsert_batch` raised to **5,000** for the 3.1M rows.

- `preload_context` → `@book_ids = Books::Book.pluck(:id).to_set`. Necessary because `listable` is polymorphic and has **no DB FK**: a `book_id` with no migrated `Books::Book` must raise in Ruby, naming the legacy `user_list_books.id`. Same guard as `ListItemMigrator` (current data has zero such rows, but the guard is the pattern).
- `finalize` → the renumber SQL. Raw SQL, per `BulkUpsertMigrator`'s note that *"finalize runs OUTSIDE `without_search_indexing` — keep it callback-free"*.

```sql
UPDATE user_list_items SET position = ranked.new_position
FROM (
  SELECT uli.id,
         ROW_NUMBER() OVER (PARTITION BY uli.user_list_id ORDER BY uli.position, uli.id) AS new_position
  FROM user_list_items uli
  JOIN user_lists ul ON ul.id = uli.user_list_id
  WHERE ul.type = 'Books::UserList'
) ranked
WHERE user_list_items.id = ranked.id
  AND user_list_items.position <> ranked.new_position
```

**5. `lib/tasks/data_migration.rake`** — `data_migration:user_lists` and `data_migration:user_list_items`, appended to `:all` in that order.

## Idempotency

`UserListMigrator` upserts on `:id` — a re-run rewrites identical rows.

`UserListItemMigrator` deserves an explicit note, because it is **idempotent in outcome but not a no-op**. A re-run's upsert resets each row's `position` back to its legacy value (sentinel, gaps, ties), and `finalize` then renumbers it again. Because the renumber orders by `(position, id)` — both stable across runs — it converges on the **identical** 1..N. The `AND position <> new_position` guard means the second run's UPDATE still touches the same rows it did the first time, rather than skipping them. This is correct and deterministic; it is simply not free.

## Data flow

```
users → books → user_lists → user_list_items
```

## Error handling

Fail loud, never silently skip:
- unmapped `list_type` or `view_mode` → raise naming the value
- `book_id` with no migrated `Books::Book` → raise naming the legacy `user_list_books.id`
- bad `user_id` or `user_list_id` → `ActiveRecord::InvalidForeignKey` from the real DB FK

`BulkUpsertMigrator` already wraps any per-row raise with the legacy id and the count upserted so far, and each batch is its own statement — a mid-run failure leaves prior batches committed and the run resumes idempotently.

## Testing

**Unit** (`test/lib/services/books_migration/`, mirroring the existing migrator tests — `legacy_each` stubbed, legacy connection never opened):
- `user_list_migrator_test.rb` — `type` is `Books::UserList`; `LIST_TYPE_MAP` for all five values + fail-loud raise on an unmapped one; `VIEW_MODE_MAP` incl. NULL→`default_view` + fail-loud; `public` NULL→false; the three dead columns are absent from the built row; legacy id and timestamps preserved; idempotent re-run.
- `user_list_item_migrator_test.rb` — `listable_type`/`listable_id`; `completed_on ← read_date`; NULL position → sentinel; the `finalize` renumber produces contiguous 1..N and breaks duplicate ties by id; raise naming the legacy id when a `book_id` has no migrated book; timestamps preserved.
- `test/models/books/user_list_test.rb` — enum, `default_list_types`, `listable_class`, `default_list_name_for`, `completed_on_list_types`, `ranking_configuration_class`; and that `Books::UserList` is **absent** from `DEFAULT_SUBCLASSES`/`DOMAIN_SUBCLASSES` (D-data-only is load-bearing — adding it silently would create books lists for every new signup).

**E2E** (real legacy DB, run manually, not in CI):

| assertion | expected |
|---|---|
| `user_lists` where `type = 'Books::UserList'` | **282,922** |
| by `list_type` | favorites **69,428** / read **69,440** / reading **69,423** / want_to_read **69,400** / custom **5,231** |
| `public = true` | **115** |
| `view_mode` | default_view **282,244** / table_view **422** / grid_view **256** |
| `user_list_items` on Books lists | **3,096,597**, all `listable_type = 'Books::Book'` |
| `completed_on` non-null | **79,721**, all on `read` lists |
| positions | `MIN = 1`; **0** sentinel rows remain; **0** duplicate `(user_list_id, position)` pairs |
| `one_default_per_type_per_user` | **0** duplicate `(user_id, list_type)` among non-custom |
| re-run | counts and positions unchanged |

Full suite (`bin/rails test`) green.

## Verification (e2e vs the real legacy database, 2026-07-12)

Run against the restored legacy database in development, twice (the second run proving idempotency).

**Pre-flight.** Prerequisites present: 69,480 users (69,459 legacy + 21 new-app), 126,204 `Books::Book`, 254 pre-existing Music/Games/Movies `user_lists`. Reserved-ceiling re-confirmed as `IdRangeReservationService` requires: legacy `MAX(user_lists.id)` = **604,880** against a ceiling of **1,000,000** → `ok=true`.

**Load times.** `user_lists` 282,922 rows in **28s**. `user_list_items` 3,096,597 rows in **3m26s**.

| assertion | expected | observed |
|---|---|---|
| `Books::UserList` count | 282,922 | **282,922** ✅ |
| by `list_type` | favorites 69,428 / read 69,440 / reading 69,423 / want_to_read 69,400 / custom 5,231 | **exact** ✅ |
| `view_mode` | default_view 282,244 / table_view 422 / grid_view 256 | **exact** ✅ |
| `public = true` | 115 | **115** ✅ |
| id range (ids preserved) | 265,341..604,880 | **265,341..604,880** ✅ |
| duplicate `(user_id, list_type)` among non-custom | 0 | **0** ✅ |
| `user_list_items` on Books lists | 3,096,597 | **3,096,597** ✅ |
| non-`Books::Book` `listable_type` | 0 | **0** ✅ |
| `completed_on` non-null | 79,721 | **79,721** ✅ |
| sentinel positions surviving | 0 | **0** ✅ |
| min position | 1 | **1** ✅ |
| duplicate `(user_list_id, position)` | 0 | **0** ✅ |
| `completed_on` outside the `read` list | 0 | **0** ✅ |

**Position normalization proved exactly, not just approximately.** A per-list aggregate over all 282,922 Books lists found **0** lists where `MAX(position) <> COUNT(*)` or `MIN(position) <> 1`. Together with the zero-duplicates result, that means every list's positions are exactly the set `{1..N}`. Spot-check on the largest list (id 537,509, 12,408 items): positions are exactly `1..12408`.

**Other domains untouched.** The renumber's `WHERE ul.type = 'Books::UserList'` scoping held on real data: the 26 pre-existing Music/Games/Movies `user_list_items` still carry their original positions, and the 254 non-Books `user_lists` are unchanged. Totals: `user_list_items` 3,096,623 = 3,096,597 + 26.

**Idempotency.** Both migrations re-run start to finish. Every count above is identical, and positions remain exactly 1..N — confirming the design note that the item migrator's re-run resets positions to their legacy values and `finalize` renumbers them back to the same result, converging rather than drifting.

**Suite:** 4,526 runs, 0 failures, 0 errors. `standardrb` clean. `brakeman` unchanged (31 pre-existing warnings, 0 new).

One caveat worth carrying forward: `NULL_POSITION_SENTINEL` is exactly `INT_MAX`, and `position` is a 4-byte integer. Between the first batch and `finalize`, sentinel rows are live in the table — so if a user could add an item to a not-yet-finalized `Books::UserList`, `UserListItem#set_position`'s `MAX(position) + 1` would overflow. `D-data-only` means no UI *offers* this path, but it is not airtight: `UserListItemsController#load_user_list` does `current_user.user_lists.find(params[:user_list_id])` with no type/domain filter, and `POST /user_lists/:user_list_id/items` is a global route gated only by `owner?`. So the owner of a migrated books list could reach it with a crafted request — nobody else, since the lookup is scoped to `current_user`. The failure mode is a loud `ActiveModel::RangeError` (a self-inflicted 500 for that one request) — no data corruption, no cross-user or cross-domain impact. Separately, a run that fails partway leaves sentinel positions live in the table indefinitely (`finalize` is skipped on failure) until a successful re-run. Whoever wires the books UI should ensure the migration has already run to completion, or run it in a quiet window.
