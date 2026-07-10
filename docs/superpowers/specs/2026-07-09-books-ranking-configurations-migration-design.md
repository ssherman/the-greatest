# Ranking Migration (legacy `ranking_configurations` + `ranked_lists`) — Design

**Status:** Approved 2026-07-09.
**Scope:** Increment **2b** of Phase 2 (lists & rankings). Migrate the **active (non-archived)** legacy `ranking_configurations` (4 of 47) into the STI `Books::RankingConfiguration` (**fresh ids + `LegacyIdMap`**) and their `ranked_lists` (757 rows) into `ranked_lists` (fresh ids, natural key `[list_id, ranking_configuration_id]`). Adds one shared-schema index. Unblocks 2c (penalties: `penalty_applications.ranking_configuration_id`, `list_penalties.list_id`).
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md` (§Ranking, §Enum re-encoding cheatsheet).
**Depends on (all merged):** lists — 2a (`primary/secondary_mapped_list_id`, `ranked_lists.list_id` reference `Books::List`, ids preserved); users (RC `user_id`, though dropped — see D-user-id).

## Goal

Get the 4 active legacy ranking configurations into `Books::RankingConfiguration` (fresh ids + map) and all 757 of their `ranked_lists` into `ranked_lists`, faithfully, idempotently, and re-runnably. The 43 archived RCs and their ranked_lists are **deliberately excluded** (parent design: archived configs are a future materialized-view concern).

## Legacy data (local restore, introspected 2026-07-09)

`ranking_configurations`: **47 rows, 4 non-archived** — ids **48, 52, 63, 68**. **No `type` column** on the legacy side (books-only app → constant `"Books::RankingConfiguration"`; no STI ambiguity). `ranked_lists`: **17,379 total; 757 belong to the 4 active RCs** (RC 48=60, 52=30, 63=43, **68=624**).

The 4 active RC rows in full:

| id | name | primary | global | user_id | inherited_from_id | inherit_list_cons | prim/sec mapped list | algo | exponent | bonus_pool | min_list_weight | max_age/max_pct | cutoff | published_at |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 48 | The Best Books of 2024 | f | t | 1 | — | f | 746 / 747 | 4 | 1.5 | 2.0 | −50 | — / — | 100 | — |
| 52 | The Best Books of 2023 | f | t | 1 | 48 | t | 1041 / 1042 | 4 | 1.5 | 2.0 | −50 | — / — | 100 | — |
| 63 | The Best Books of 2025 | f | t | 1 | 48 | t | 1088 / 1089 | 4 | 3.0 | 6.0 | −50 | — / — | 100 | — |
| 68 | May 2026 | **t** | t | 1 | **67** | t | — / — | 4 | 3.0 | 3.0 | −50 | 50 / 80 | — | 2026-05-16 |

Facts that drive the design:

| Fact | Value | Handling |
|---|---|---|
| active RCs | **4 of 47** (`archived = false`) | migrate active only (§Ranking) |
| legacy STI `type` col | **none** | constant `"Books::RankingConfiguration"` |
| `global` + `user_id` | **all 4** `global=true` **and** `user_id=1` | new model **forbids** the combo → **drop `user_id`** (D-user-id) |
| `primary` | only **RC 68** (0 existing Books primary in target) | direct; `before_save` demotes no one (D-primary) |
| `inherited_from_id` | 48→(none), 52→48 (active), 63→48 (active), **68→67 (archived)** | **all nulled** (owner decision, D-inherited-from) |
| every other field vs new validations | exponent 1.5–3.0 ≤10 ✓; bonus_pool 2–6 in 0–100 ✓; min_list_weight −50 (int, no positivity req) ✓; max_age 50 / max_pct 80 / cutoff 100 all `>0` ✓; all nil-allowed columns fine | direct (with renames) |
| `primary/secondary_mapped_list_id` targets | 746, 747, 1041, 1042, 1088, 1089 — **all present as `Books::List`** | direct (lists preserve id; DB FK) |
| `ranked_lists` for active RCs | **757**; **0 null weight**; **0 orphan `list_id`**; **0 duplicate `[list_id, rc_id]`** | bulk upsert, natural key clean |
| `ranked_lists` referenced lists | all migrated as `Books::List` (max ref id 1,175) | fail-loud guard (D-rl-failloud) |
| `ranked_lists` composite unique index | **absent** (only single-column `list_id`, `ranking_configuration_id`) | **add** one (D-schema) |
| timestamps | `ranking_configurations` `created_at` spans 2024–2026 | **preserved** (verified AR keeps explicit `created_at` on create) |

## Decisions

- **D-active-only — migrate `archived = false` RCs only** (4 of 47). `RankingConfigurationMigrator#legacy_each` scopes `legacy_model.where(archived: false)`. Verified in e2e (unit tests stub `legacy_each`, like every prior migrator). `ranked_lists` inherit the filter transitively: only rows whose `ranking_configuration_id` is in the RC map are migrated (D-rl-write).
- **D-write-rc — `Migrator` (per-row AR), fresh id + `LegacyIdMap` key `"Books::RankingConfiguration"`** (mirrors `CategoryMigrator`, minus the finalize pass). Only 4 rows; per-row `save!` runs the model validations (a real safety net, since the values are near the validation limits) and records the id map that `ranked_lists` and 2c penalties depend on. `find`/`new` via the map makes it idempotent. `Books::RankingConfiguration.new` sets `type` via STI (not set in the transformer).
- **D-user-id — drop `user_id` for global configs** (deviation from parent design, forced by data). All 4 active RCs are `global=true` with `user_id=1`, but `validate :global_configurations_cannot_have_user` rejects a global config with a user. The transformer sets `user_id: attrs["global"] ? nil : attrs["user_id"]` → nil for all 4. The parent design listed `user_id` as "preserved"; reality (introspected 2026-07-09) makes that impossible. `user_id` is not semantically load-bearing for a global ranking config.
- **D-inherited-from — null `inherited_from_id` for every migrated RC** (owner decision, 2026-07-09: *"inherited_from only matters when the list is first created; fine to null them all out for now — not an important field."*). This is simpler than the parent design's "remap if the parent is active" and sidesteps the RC-68→archived-67 dangling reference entirely. **Consequence: no `finalize` pass** and no self-ref stash in the RC migrator (unlike `CategoryMigrator`). The `inherited_from_must_be_same_type` validation never fires (guarded by `if: :inherited_from_id?`).
- **D-primary — copy `primary` directly.** Only RC 68 is primary; the target has **0** existing Books primary, so the model's `only_one_primary_per_type` validation passes and its `before_save :ensure_only_one_primary_per_type` demotes nothing. Music/Games/Movies primaries are a different `type` and unaffected (validation + callback are type-scoped). On re-run, RC 68 is persisted → the "one primary" validation excludes itself → still passes.
- **D-schema — add a unique composite index on `ranked_lists [list_id, ranking_configuration_id]`** (name `index_ranked_lists_on_list_and_config_unique`). Required as the `upsert_all` conflict target (D-rl-write) and it **formalizes the model's existing** `validates :list_id, uniqueness: {scope: :ranking_configuration_id}` at the DB level — a latent integrity gap across all domains. Safe: dev has **0 duplicate** `[list_id, rc_id]` pairs and the validation already guarantees uniqueness. The existing single-column indexes are left in place (unrelated to this work).
- **D-rl-write — `BulkUpsertMigrator`** on the new unique index, natural key `[list_id, ranking_configuration_id]` (like `ListItemMigrator`). `preload_context` builds `@rc_map` (`LegacyIdMap` model `"Books::RankingConfiguration"`) and the `Books::List` id set; `legacy_each` scopes `where(ranking_configuration_id: @rc_map.keys)` (→ 757 rows; archived-RC ranked_lists inherently skipped). `weight` and timestamps preserved (`record_timestamps?` = false). The **0 null-weight** and **0 duplicate `[list_id, rc_id]`** findings mean no NULL-in-unique-index rows and no intra-batch `ON CONFLICT` double-touch.
- **D-rl-failloud — guard both FKs.** `ranked_lists.list_id` has **no DB FK** (only `ranking_configuration_id` does), so a `list_id` with no migrated `Books::List` would silently create a dangling row → `build_rows` **raises** naming the legacy `ranked_list` id + `list_id` (mirrors `ListItemMigrator`/`CategoryItemMigrator`). A `ranking_configuration_id` absent from `@rc_map` also **raises** (defensive; the `legacy_each` scope means it can't happen in the real run, but a stray active-but-unmapped RC would be a real prerequisite failure). `preload_context` **raises if `@rc_map` is empty** ("run `data_migration:ranking_configurations` first").
- **D-no-finalize-rc — none** (see D-inherited-from). No counter caches; fresh ids from the sequence (no `setval`).

## Schema change

**One migration** (standard Rails generator):

```ruby
add_index :ranked_lists, [:list_id, :ranking_configuration_id],
  unique: true, name: "index_ranked_lists_on_list_and_config_unique"
```

Formalizes the model's uniqueness validation; enables the `ranked_lists` upsert (D-schema). No column changes.

## Source → target mapping

### `ranking_configurations` (active only) → `ranking_configurations` (fresh id, `type = "Books::RankingConfiguration"`)

| new column | legacy source | handling |
|---|---|---|
| `id` | — | fresh (auto) + `LegacyIdMap` |
| `type` | (constant) | `"Books::RankingConfiguration"` (STI, set by `.new`) |
| `name`, `description` | same | direct |
| `global` | `global` | direct (all true) |
| `user_id` | `user_id` | **nil for global** (D-user-id) |
| `primary` | `primary` | direct (D-primary) |
| `archived` | (constant) | `false` (all active) |
| `published_at` | `published_at` | direct |
| `algorithm_version` | `algorithm_version` | direct |
| `inherit_penalties` | `inherit_list_cons` | **rename** |
| `min_list_weight` | `min_list_weight` | direct |
| `max_list_dates_penalty_age` | `max_age_for_penalty` | **rename** |
| `max_list_dates_penalty_percentage` | `max_penalty_percentage` | **rename** |
| `list_limit` | `list_limit` | direct (all nil) |
| `apply_list_dates_penalty` | `apply_list_dates_penalty` | direct |
| `bonus_pool_percentage` | `bonus_pool_percentage` | direct |
| `exponent` | `exponent` | direct |
| `primary_mapped_list_id` | `primary_mapped_list_id` | direct (lists preserve id; DB FK) |
| `secondary_mapped_list_id` | `secondary_mapped_list_id` | direct (DB FK) |
| `primary_mapped_list_cutoff_limit` | `primary_mapped_list_cutoff_limit` | direct |
| `inherited_from_id` | `inherited_from_id` | **nil for all** (D-inherited-from) |
| `created_at` / `updated_at` | same | **preserved** |

**Dropped legacy columns:** `starting_score`, `min_max_normalization`, `list_cons_are_percentages`, `apply_global_age_penalty` (no new-model equivalent, §Ranking).

### `ranked_lists` (active RCs) → `ranked_lists` (fresh id, natural key `[list_id, ranking_configuration_id]`)

| new column | legacy source | handling |
|---|---|---|
| `id` | — | fresh (auto) |
| `list_id` | `list_id` | direct (lists preserve id); fail-loud guard (D-rl-failloud) |
| `ranking_configuration_id` | `ranking_configuration_id` | **mapped** via `@rc_map` (D-rl-write); fail-loud if absent |
| `weight` | `weight` | direct (0 null) |
| `created_at` / `updated_at` | same | **preserved** |

Left null/default (no legacy equivalent): `calculated_weight_details`.

## Migrators

- **`Services::BooksMigration::RankingConfigurationMigrator`** — `Migrator` (per-row): `legacy_model = LegacyBooks::RankingConfiguration` (new read-only model, `table_name = "ranking_configurations"`), `model_key = "Books::RankingConfiguration"`. `legacy_each` scopes `where(archived: false)`. `upsert_row` finds via the map or `Books::RankingConfiguration.new`, assigns `RankingConfigurationTransformer.call(attrs)`, `save!`, records the map. **No `finalize`.**
- **`Services::BooksMigration::RankingConfigurationTransformer`** — pure (String-keyed hash → symbol-keyed attrs): renames + drops per the table above, `user_id` nil for global, `archived: false`, no `type`/`inherited_from_id` key. Mirrors `CategoryTransformer`.
- **`Services::BooksMigration::RankedListMigrator`** — `BulkUpsertMigrator`: `legacy_model = LegacyBooks::RankedList` (`table_name = "ranked_lists"`), `target_model = RankedList`, `unique_by: :index_ranked_lists_on_list_and_config_unique`, `record_timestamps?` = false. `preload_context` builds `@rc_map` + `Books::List` id set (raises if `@rc_map` empty); `legacy_each` scopes to `@rc_map.keys`; `build_rows` maps rc, guards list, preserves weight + timestamps.
- New read-only legacy models `LegacyBooks::RankingConfiguration` and `LegacyBooks::RankedList`.

## Orchestration

Add `data_migration:ranking_configurations` (→ `RankingConfigurationMigrator.call`) and `data_migration:ranked_lists` (→ `RankedListMigrator.call`). Append to `data_migration:all` after `:list_items`, **`:ranking_configurations` before `:ranked_lists`** (ranked_lists need the RC map + `Books::List`): `[…, :lists, :list_items, :ranking_configurations, :ranked_lists]`.

## Testing (Minitest + Mocha, stub `legacy_each`)

**RankingConfigurationMigrator / Transformer:**
- Maps an active legacy RC → `Books::RankingConfiguration` with a fresh id, records the map, `type = "Books::RankingConfiguration"`, all renames correct (`inherit_penalties ← inherit_list_cons`, `max_list_dates_penalty_age ← max_age_for_penalty`, `max_list_dates_penalty_percentage ← max_penalty_percentage`), `primary/secondary_mapped_list_id` direct, `archived = false`, timestamps preserved.
- **user_id dropped:** a `global=true, user_id=1` row → `user_id` nil, saves (proves `global_configurations_cannot_have_user` is satisfied).
- **inherited_from nulled:** a row with `inherited_from_id = 999` → new record's `inherited_from_id` nil (both active-parent and archived-parent cases collapse to nil).
- **primary:** a `primary=true` row saves as the sole Books primary.
- Dropped columns (`starting_score` etc.) are not assigned (Transformer output has no such keys).
- Idempotent: re-run leaves `Books::RankingConfiguration.count` unchanged, keeps the map, updates in place.
- Search indexing suppressed during the load (`assert_no_difference SearchIndexRequest.count`).

**RankedListMigrator:**
- Maps a legacy ranked_list → `ranked_lists` row: `list_id` direct, `ranking_configuration_id` = mapped new id, `weight` direct, timestamps preserved.
- **Fail-loud:** a `list_id` with no `Books::List` → `success: false`, error names the legacy `ranked_list` id; a `ranking_configuration_id` absent from the map → `success: false`; empty `@rc_map` (no RC migrated) → `success: false`.
- Idempotent on `[list_id, ranking_configuration_id]`: re-run leaves count unchanged, no duplicates.

**Migration:** the unique index exists and rejects a duplicate `[list_id, ranking_configuration_id]` insert.

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the migrated baseline (through 2a), run `db:migrate` (index), then `data_migration:ranking_configurations` then `:ranked_lists` (twice each), then verify:
- `Books::RankingConfiguration.count == 4`; each has a `LegacyIdMap` entry (model `"Books::RankingConfiguration"`, legacy ids 48/52/63/68); the 43 archived RCs are **absent**.
- Exactly **1** Books primary (mapped from legacy 68); its `inherited_from_id` is **nil**; all 4 have `user_id` nil and `archived = false`; renames present; `primary/secondary_mapped_list_id` resolve to existing `Books::List` rows; `created_at` preserved (e.g. RC 48 = 2024-12-29).
- `RankedList.where(ranking_configuration_id: <mapped active ids>).count == 757` (per-RC 60/30/43/624); every row's `list_id` is an existing `Books::List`; **0** dangling; `weight` preserved.
- Idempotent: second run of each leaves both counts unchanged.
- Full suite green; `standardrb` + `brakeman` clean (0 new).

## Out of scope
- Penalties — `list_cons` → `penalties`/`penalty_applications`/`list_penalties` (2c).
- **Archived RCs** (43) and their `ranked_lists` (future materialized-view concern, parent design).
- `ranked_books` (recomputed by the new ranking system, never migrated).
- `inherited_from_id` inheritance semantics (D-inherited-from — nulled for now).
- Dropping the now-prefix-redundant `index_ranked_lists_on_list_id` (left alone; unrelated cleanup).

## References
- Parent design: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md` (§Ranking)
- Prior increment (template): `docs/superpowers/specs/2026-07-09-books-lists-migration-design.md` (2a) · `category_migrator.rb` (per-row + map) · `list_item_migrator.rb` (bulk + fail-loud guard)
- `Migrator` / `BulkUpsertMigrator`: `app/lib/services/books_migration/{migrator,bulk_upsert_migrator}.rb`
- `RankingConfiguration` / `Books::RankingConfiguration`: `app/models/ranking_configuration.rb`, `app/models/books/ranking_configuration.rb`; `RankedList`: `app/models/ranked_list.rb`
