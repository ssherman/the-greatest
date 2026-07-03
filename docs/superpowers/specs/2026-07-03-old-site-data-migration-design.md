# Old Site → New Site Data Migration — Design

## Status
- **Status**: Design / brainstorming complete — awaiting review
- **Created**: 2026-07-03
- **Owner**: Shane Sherman
- **Type**: Design doc (seeds per-phase implementation specs)

## Overview

Migrate the public data of the legacy **TheGreatestBooks** app (`the-greatest-books/admin/`,
Rails 8) into the new multi-domain **The Greatest** app (`web-app/`), transforming the old
single-purpose schema into the new namespaced/polymorphic/STI object model.

The migration must be **idempotent and re-runnable** (a repeated one-way `old → new` sync until
cutover), and must **preserve the primary-key IDs** of URL-facing entities so the legacy public
URLs keep resolving. The old site is entirely **ID-based** (no slugs), so preserving PKs is what
keeps `/items/:id`, `/books/:id`, `/authors/:id`, `/lists/:id`, `/user_lists/:id` working.

### Goals
- A per-model **transformation layer** (old row → new attributes) that is unit-testable in isolation.
- **Idempotent** upserts — rerun any time, converge to the same result.
- **Preserve IDs** for `books_books`, `books_authors`, `lists`, `users`, `user_lists`.
- Correct handling of enum re-encodings, polymorphic/STI targets, and FK remapping.
- Clean decomposition into shippable phases.

### Non-goals
- Migrating derived/output data that the new app recomputes (`ranked_books` → `ranked_items`).
- Images (deferred — legacy uses custom S3 keys, new uses ActiveStorage; a separate sub-project).
- Archived ranking configurations (future: materialized views).
- Any legacy model with no new-site equivalent (see **Out of scope**).
- The actual production cutover / DNS / routing swap.

## Background & constraints

- **Topology**: old and new are **separate databases on the same Postgres server**. Postgres cannot
  join across databases, so the migration runs **inside the new Rails app** with a **second,
  read-only connection** to the legacy DB. No table-name collisions (distinct databases).
- **URLs are ID-based**: legacy has no slugs. Preserving PKs = zero-redirect URL continuity. The new
  models use FriendlyId with `:finders`, so `/books/123` still resolves by ID; fresh slugs are
  generated during migration.
- **DB reset before import**: the owner will reset the new DB before the real import, so the target
  is effectively greenfield at import time. The migration is still designed to be idempotent across
  reruns (it will be run "constantly" to sync).
- **Active configs only**: only **non-archived** `ranking_configurations` are migrated, and their
  penalty `points` are already percentages (0–100) — so they map straight into
  `PenaltyApplication.value` (validated 0–100) with no clamping.
- **Search**: the new `SearchIndexable` callbacks queue a `SearchIndexRequest` per write. OpenSearch
  is not in real use yet, so we **suppress these callbacks during migration** (otherwise millions of
  request rows) and rely on normal search tooling to index later. No reindex step in this migration.

## Architecture

### Legacy read connection
- Add a `legacy_books` entry to `config/database.yml` (same host, legacy DB, **read-only** role).
- Define a minimal, read-only base model `LegacyBooks::Record < ApplicationRecord` (abstract,
  `connects_to database: { reading: :legacy_books }`), with thin subclasses per legacy table we read
  (`LegacyBooks::Book`, `LegacyBooks::Author`, …) exposing only the columns/associations we need.
- Reads are batched (`in_batches` / keyset pagination) to bound memory on large tables.

### Transformation layer (Transformer per model)
- One **pure** `Transformer` per model under `app/lib/services/books_migration/transformers/`:
  input = a legacy row (or attribute hash), output = a new-model attributes hash. No DB writes, no
  side effects → trivially unit-testable with fixtures of real legacy shapes.
- Transformers own all enum re-encoding, field renames, and value normalization.

### Write path (hybrid)
- **Through new AR models** for entities needing slugs / validations / normalization
  (`Books::Author`, `Books::Book`, `Books::Edition`, `List`, `Category`, `RankingConfiguration`,
  `Penalty`, `UserList`) — via `find_or_initialize_by(id:)` (preserved-PK) or a `legacy_id_map`
  lookup, assign, `save!`.
- **`upsert_all`** (raw, fast) for high-volume join/child tables with no meaningful callbacks
  (`books_book_authors`, `list_items`, `identifiers`, `category_items`, `ranked_lists`,
  `penalty_applications`, `list_penalties`, `user_list_items`), keyed on their natural unique index.
- **Search suppression**: wrap each migrator run in a `Services::BooksMigration.without_search_indexing { }`
  helper (thread-local flag checked by `SearchIndexable#queue_for_indexing`) so bulk writes don't
  enqueue `SearchIndexRequest` rows.
- **Counter caches** (`categories.item_count`) are recomputed once at the end rather than per-row.

### Idempotency & `legacy_id_map`
- **Preserved-PK entities** (`books_books`, `books_authors`, `lists`, `users`, `user_lists`):
  `new_id == legacy_id`; upsert on `id`. No lookup table needed.
- **Fresh-PK entities** (`languages`, `categories`, `books_editions`, `ranking_configurations`,
  `penalties`): a dedicated **`legacy_id_map(model, legacy_id, new_id)`** table (new DB) records the
  mapping on first insert, reused on reruns and for FK remapping. Keeps domain tables free of
  `legacy_id` columns.
- **Join tables**: no mapping needed — matched on their natural composite key once parent IDs resolve.

### Dependency order & orchestration
A single orchestrator rake task (`data_migration:all`) runs migrators in FK-dependency order; each
migrator is independently runnable (`data_migration:books`, etc.):

```
languages → users → authors → books → editions → identifiers
  → categories → category_items → lists → list_items → external_links
  → ranking_configurations → ranked_lists → penalties(list_cons)
  → user_lists → user_list_items
  → (finalize: recompute counter caches, setval sequences)
```

### ID preservation strategy

| Table | Keep old IDs? | Mechanism |
|---|---|---|
| `books_books`, `books_authors` | **Yes** (book/author URLs) | Books-only tables → insert with explicit `id`, `setval` sequence above legacy max after load. No reservation needed (assumes empty at import; guaranteed by the planned reset). |
| `lists` | **Yes** (list URLs) | **Phase 0 ID-range reservation** — shared table, music/games occupy low IDs; extend `Services::BooksMigration`. |
| `users`, `user_lists` | **Yes** | **Already reserved** (`docs/specs/completed/books-migration-01-id-range-reservation.md`) — ceilings `users` 150k, `user_lists` 1M. |
| `ranking_configurations` | No (`/rc/:id` is low-traffic) | Fresh id + `legacy_id_map`; **active/non-archived only**. |
| `categories` | No (URLs use slug) | Fresh id, **preserve slug** + `legacy_id_map`. |
| `books_editions`, join tables, `penalties`, `identifiers`, `external_links`, `user_list_items` | No | Fresh id; match on natural key / `legacy_id_map`. |

> `user_list_items.id` is deliberately **not** reserved (not URL-facing) — fresh ids, `user_list_id`
> remapped (already preserved).

## Model-by-model mapping

### Reference tables
- **`languages` → `languages`**: `name` → `name`; generate `slug`; `iso_639_1/3` = nil (legacy has
  none). Fresh id + map. Match on `name` to avoid dupes across reruns.
- **`users` → `users`** (preserve id): `auth_uid`, `auth_data`, `email`, `email_verified`,
  `external_provider` (enum 0–4 identical), `display_name`, `name`, `photo_url`, `provider_data`,
  `role` (enum 0–2 identical), `sign_in_count`, `last_sign_in_at`, `stripe_customer_id`. Drop
  `external_provider_uid`, `migrated`, `paid`, `goodreads_import`, etc. (no new columns).
  **Edge case**: `email` is `uniqueness: true` — on a non-reset rerun, an already-present new-site
  user with the same email would conflict; the reset makes this moot, but the migrator should match
  on `id`/`email` and skip re-creating. `after_create :create_default_user_lists` fires → see User lists.

### Authors — `authors` → `books_authors` (preserve id)
| new | from old |
|---|---|
| `name` | `name` |
| `sort_name` | `family_name` (fallback: `name`) |
| `birth_year`, `death_year`, `description` | same |
| `alternate_names` | `alternative_names` (+ merge `alternate_title` style variants if present) |
| `kind` | default `person` |
| `slug` | generated (FriendlyId) |
| — | `ol_author_id` → `Identifier` `books_author_openlibrary_id` |
Dropped: `gender`, `normalized_name`, `nationality_text`, `calculated_score`, OL cover/photo ids,
`search_string`, `wikipedia_url` (→ optionally an `external_link` later).

### Books — `books` → `books_books` (preserve id) + `editions` → `books_editions` + identifiers
| new `books_books` | from old `books` |
|---|---|
| `title` | `title` |
| `subtitle` | `sub_title` |
| `description` | `description` |
| `first_published_year` | `first_year_published` |
| `sort_title` | `sort_title` |
| `alternate_titles` | `alternate_titles` + `alternate_title_1` |
| `original_language_id` | remap old `original_language_id` via language `legacy_id_map` |
| `book_kind` | default `standalone` |
| `slug` | generated |
| `default_edition_id` | set after editions load (most-popular edition; synthesize a minimal one if none) |
Dropped/ignored: `book_type` (use categories instead — owner), `ol_work_id` (**no longer used** —
owner), `goodreads_id` → `Identifier` `books_work_goodreads_id`, all `ai_*`/`search_string`/`*_image_key`/
`primary_amazon_url`/`origin_countries`/`series*` (series handled by the new `books_series` model, not
in this pass).

**`editions` → `books_editions`** (fresh id + map): `book_id` (preserved), `book_binding`
(**symbol-remap**, see cheatsheet), `publication_year`, `popularity`, `title`, `edition_type` default
`standard`, `language_id`, `metadata`; `ol_edition_id` → `Identifier` `books_edition_openlibrary_id`;
`identifiers`/`flat_identifiers` jsonb → `Identifier` rows. `book_versions` is **skipped** in this pass.

**`book_identifiers` → `identifiers`** (polymorphic): edition-level types (ISBN/ASIN/EAN/bookshop)
attach to the book's (default) edition; work-level types (openlibrary/goodreads/librarything) attach
to the `Books::Book`. Old `identifier_type` (1..8) is **symbol-remapped** (see cheatsheet); exact
work-vs-edition placement finalized in Phase 1 with TDD.

### `book_authors` → `books_book_authors` (fresh id, natural key `[book_id, author_id]`)
`author_id`, `book_id` (both preserved → direct), `position`; new `role` default `0`, `credited_as` nil.

### Categories — `categories` → `categories` (STI `Books::Category`, fresh id + map, **preserve slug**)
`name`, `slug` (preserve), `category_type` (enum 0–2 identical), `import_source` (enum 0–3 identical),
`parent_category_id` → `parent_id` (self-referential; resolve via map, two-pass or ordered),
`deleted`, `description`, `merged_category_names` → `alternative_names`, `book_count` → recomputed
`item_count`. `type = "Books::Category"`. Dropped: `primary`, `location`, `ai_fix_response`.

**`book_categories` → `category_items`** (natural key `[category_id, item]`): `category_id` (map),
`item = Books::Book` (preserved id). Skip rows where old `deleted = true`.

### Lists — `lists` → `lists` (STI `Books::List`, preserve id)
`name`, `description`, `source`, `url`, `year_published`, `number_of_voters`, `submitted_by_id`
(user preserved), `estimated_quality`, `high_quality_source`, `category_specific`,
`location_specific`, `yearly_award`, `voter_count_unknown`, `voter_names_unknown`;
`status` **symbol-remap** (see cheatsheet); `raw_html` → `raw_content`;
`formatted_text`/`unformatted_text` → `simplified_content`; `books_json` → `items_json`.
`type = "Books::List"`.

**`list_items` → `list_items`** (natural key `[list_id, listable]`): `list_id` (preserved),
`listable = Books::Book` (old `book_id`, preserved), `position`, `pending_book_data` → `metadata`,
`verified` default false. Rows with null `book_id` become pending items (`listable` nil).

### Ranking — `ranking_configurations` (**active/non-archived only**) → STI `Books::RankingConfiguration`
Fresh id + map. `name`, `description`, `algorithm_version`, `apply_list_dates_penalty`,
`bonus_pool_percentage`, `exponent`, `global`, `list_limit`, `min_list_weight`, `primary`,
`primary_mapped_list_cutoff_limit`, `published_at`, `user_id` (preserved);
`inherit_list_cons` → `inherit_penalties`; `max_age_for_penalty` → `max_list_dates_penalty_age`;
`max_penalty_percentage` → `max_list_dates_penalty_percentage`;
`primary_mapped_list_id`/`secondary_mapped_list_id` (list preserved id, direct);
`inherited_from_id` (map, only if parent is also active). `archived = false`.
Dropped: `starting_score`, `min_max_normalization`, `list_cons_are_percentages`,
`apply_global_age_penalty`.

**`ranked_lists` → `ranked_lists`** (natural key `[list_id, ranking_configuration_id]`, active RCs
only): `list_id` (preserved), `ranking_configuration_id` (map), `weight`.

**`ranked_books` → NOT migrated** — recomputed by the new ranking system after load.

### Penalties — `list_cons` + `list_con_lists` → `penalties` + `penalty_applications` + `list_penalties`
The old model attaches a penalty (`list_con`) to a **ranking_configuration** with `points`; the new
model splits definition / per-config application / per-list attachment across three tables. Only
penalties belonging to **active** ranking configs are migrated.

- Each old `list_con` →
  - `Penalty` (`type = "Books::Penalty"`, `name`, `description`, `dynamic_type` copied directly —
    old enum 0–4 is a subset of the new enum with **identical integer values**), fresh id + map;
  - `PenaltyApplication` (`penalty_id` = mapped, `ranking_configuration_id` = mapped config,
    `value` = old `points`; already 0–100 for active configs).
- **Static** `list_con` (`dynamic_type` nil) only: each `list_con_list` → a `ListPenalty`
  (`list_id` = the `ranked_list`'s `list_id`, `penalty_id` = mapped). Natural key `[list_id, penalty_id]`.
- **Dynamic** `list_con` (`dynamic_type` set): **no** `ListPenalty` rows — the new model forbids
  attaching dynamic penalties to lists (`ListPenalty#penalty_must_be_static`); they apply per-config.

### User lists — `user_lists` → `user_lists` (STI `Books::UserList`, preserve id) + items
**Prerequisite**: create `Books::UserList < UserList` (thin STI subclass mirroring
`Music::*/Games::UserList`) defining `default_list_types` for `read/reading/want_to_read/favorite/custom`
and name/icon/`completed_on` behavior.

`user_lists` → `user_lists`: `user_id` (preserved), `name`, `list_type` (enum 0–4 → `Books::UserList`
types), `public`, `description`, `position`, `view_mode` (old `nil` → new `default_view`/0).
`type = "Books::UserList"`. Dedup the 4 system lists against those auto-created by
`User#create_default_user_lists` (match by `list_type`); custom lists insert fresh with preserved id.

**`user_list_books` → `user_list_items`** (fresh id, natural key `[user_list_id, listable]`):
`user_list_id` (preserved), `listable = Books::Book` (preserved), `position`, `read_date` →
`completed_on`.

### External links — `links` → `external_links` (polymorphic parent)
`parent = Books::Book` (preserved), `url`, `name`, `description`, `submitted_by_id` → `submitted_by`
(user preserved); `source` inferred from URL host (default `other`), `link_category` default,
`public` true. Fresh id, natural key `[parent, url]`.

### Enum re-encoding cheatsheet (the landmines — raw integer copy would corrupt data)
| Field | Old → New | Note |
|---|---|---|
| `List.status` | old `{unapproved:0, approved:1, active:2, rejected:3, inactive:4, pending:5}` → new `{unapproved:0, approved:1, rejected:2, active:3}` | **map by symbol**; `active`/`rejected` swap ints; `inactive`,`pending` → `unapproved` |
| `Edition.book_binding` | old `{paperback:0, hardcover:1, ebook:2, audible:3, mass_market_paperback:4, audio:5, library_binding:6, collectable:7, leather_bound:8, other:9}` → new `{hardcover:0, paperback:1, mass_market:2, ebook:3, audiobook:4, library_binding:5, leather_bound:6, other:7}` | **map by symbol**; `audible`+`audio` → `audiobook`; `collectable` → `other` |
| `book_identifiers.identifier_type` | old `{isbn10:1, isbn13:2, asin:3, ean13:4, goodreads_id:5, librarything_id:6, openlibrary_id:7, bookshop_org_id:8}` → new `Identifier` `books_edition_*` / `books_work_*` | **map by symbol** + work/edition placement |
| `Category.category_type` | `{genre:0, location:1, subject:2}` | identical ints (new has more) — direct |
| `Category.import_source` | `{amazon:0, open_library:1, openai:2, goodreads:3}` | identical ints — direct |
| `list_cons.dynamic_type` → `Penalty.dynamic_type` | `{number_of_voters:0 … category_specific:4}` | new enum is a superset; **ints 0–4 identical** — direct |
| `User.external_provider`, `User.role` | identical ints — direct |
| `user_lists.view_mode` | old `{default_view:nil, table_view:1, grid_view:2}` → new `{default_view:0,…}` | `nil` → `0` |

## Legacy data volumes (local restore 2026-07-03)

Full prod dump restored locally into `the_greatest_books_legacy` (container `the-greatest-db-1`,
`localhost:6543`), 0 errors. The `ol_editions`/`ol_works`/`ol_covers` tables are empty (truncated in
prod long ago). Counts / max-ids that size the phases:

| Table | Rows | max(id) | Note |
|---|---|---|---|
| `books` | 126,204 | 141,785 | preserve id; `setval` after |
| `authors` | 58,193 | 66,839 | preserve id; `setval` after |
| `book_authors` | 126,869 | — | join |
| `editions` | 148,296 | — | → `books_editions` |
| `book_identifiers` | 421,698 | — | → `identifiers` |
| `categories` | 73,913 | — | fresh id + map |
| `book_categories` | 1,828,730 | — | → `category_items` (heavy — batch) |
| `lists` | 1,030 | **1,175** | **Phase 0 reservation ceiling must exceed 1,175 + growth** |
| `list_items` | 65,252 | — | |
| `ranking_configurations` | 47 total / **4 active** | — | migrate non-archived only |
| `ranked_lists` | 17,379 | — | active RCs only |
| `ranked_books` | 1,853,585 | — | **not migrated** (recomputed) |
| `list_cons` | 1,869 | — | → penalties (active RCs only) |
| `list_con_lists` | 48,720 | — | → `list_penalties` (static only) |
| `users` | 69,459 | 69,498 | reserved ceiling 150k ✓ (~2.15× headroom) |
| `user_lists` | 282,922 | 604,880 | reserved ceiling 1M ✓ (~1.65× — tight; re-confirm near import) |
| `user_list_books` | 3,096,597 | — | → `user_list_items` (heaviest — batch) |
| `links` | 13,404 | — | → `external_links` |
| `languages` | 201 | — | |

## Out of scope (no new-site equivalent, or per owner)
`ai_chats`, `ai_responses`, `goodreads_books`, `goodreads_imports`, `subscriptions`, `reading_goals`,
`reading_goal_books`, `donations`, `saved_searches`, `recommendation_configs`, `merge_runs`,
`merge_results`, `blogs`, `blog_posts`, `comments`, `reviews`, `sellers`, `sales`,
`bookshop_search_results`, `changesets`, `csv_exports`, `deleted_categories`, `webhook_events`,
`versions` (PaperTrail), `ol_editions`/`ol_works`/`ol_covers`, `pending_list_items`, `nationalities`/
`author_nationalities`/`countries`/`book_countries` (no model yet), `book_versions`, `book_type`,
`ranked_books`, **images** (deferred), **archived ranking_configurations** (future: materialized views).

## Phasing / decomposition

Each phase gets its own implementation spec (`docs/specs/`) + plan.

- **Phase 0 — `lists` ID-range reservation** *(urgent / time-sensitive)*
  Extend `Services::BooksMigration` (`RESERVED_CEILINGS`, `FOREIGN_KEYS`) to cover `lists`: bump the
  `lists` sequence above a reserved ceiling and relocate existing music/games/movies list rows (with
  FK remap for `list_items.list_id`, `ranked_lists.list_id`, `list_penalties.list_id`,
  `ranking_configurations.primary_mapped_list_id`/`secondary_mapped_list_id`, etc.) into the high
  range. Mirrors the completed `users`/`user_lists` reservation. Must run while music/games list data
  is still small. Confirm legacy `lists MAX(id)` near import time to size the ceiling.

- **Phase 1 — ETL framework + core entities**
  Legacy connection + `LegacyBooks::` models; `legacy_id_map`; `Transformer`/`Migrator` base classes;
  orchestrator rake task; search-callback suppression + counter-cache/sequence finalize step.
  Migrators: languages, users, authors, books, editions, identifiers, book_authors, categories,
  category_items, external_links.

- **Phase 2 — lists & rankings**
  lists, list_items, ranking_configurations (active only), ranked_lists, penalties
  (`list_cons`→penalties/penalty_applications/list_penalties).

- **Phase 3 — user data**
  `Books::UserList` STI subclass (prerequisite) + user_lists, user_list_books → user_list_items.

## Open questions / future
- **Identifier placement** (work vs edition) for a few legacy `book_identifiers` types — finalized in
  Phase 1 via TDD against real legacy rows.
- **`List.status` fallbacks** — `inactive`/`pending` → `unapproved` (assumed; confirm against data).
- **Deletes** — not propagated in any phase (owner confirmed). A reconciliation sweep can be added
  later if a true mirror is ever needed.
- **Images**, **archived RCs**, **series**, **multi-book groupings** — separate future sub-projects.

## References
- Completed reservation spec: `docs/specs/completed/books-migration-01-id-range-reservation.md`
- Reusable service: `app/lib/services/books_migration.rb` (`RESERVED_CEILINGS`, `FOREIGN_KEYS`)
- New schema: `web-app/db/schema.rb`; Legacy schema: `the-greatest-books/admin/db/schema.rb`
- Legacy issues context: `docs/issues_with_old_site.md`
- New object model: `docs/superpowers/specs/2026-06-29-books-object-model-design.md`
