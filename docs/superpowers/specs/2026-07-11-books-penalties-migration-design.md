# Penalties Migration (legacy `list_cons` + `list_con_lists`) — Design

**Status:** Design approved by owner 2026-07-11 (strategy + all edge rulings). Spec pending owner review.
**Scope:** Increment **2c** (final) of Phase 2 (lists & rankings). Migrate the legacy **`list_cons`** (penalties, active RCs only) into `penalties` + `penalty_applications`, and **`list_con_lists`** (static only) into `list_penalties`. No schema changes.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.
**Depends on (all merged):** 2b ranking_configurations (`LegacyIdMap` `"Books::RankingConfiguration"` + `ranked_lists` with legacy-preserved `list_id`), 2a lists (`Books::List`, ids preserved).

## The core problem

Legacy modeled penalties ("list cons") **per ranking configuration**: a `list_con` row is a name + `points` + optional `dynamic_type`, scoped to one `ranking_configuration_id`, and `list_con_lists` flags which of that RC's `ranked_lists` it applies to. The new app splits this into three tables and a **shared** penalty concept:

- **`penalties`** — reusable definition (STI `type`, `name`, `dynamic_type`, `user_id`, `description`). No points, no RC.
- **`penalty_applications`** — `penalty` × `ranking_configuration` × `value` (unique `[penalty_id, ranking_configuration_id]`). This is where `points` lives now.
- **`list_penalties`** — `list` × `penalty` (unique `[list_id, penalty_id]`), **static penalties only** (`ListPenalty#penalty_must_be_static`). Dynamic penalties are computed by the ranking engine, never hand-attached.

The new app **already ships 19 seeded `Global::Penalty` records** (`db/seeds.rb`) — a deliberately generalized, cross-media taxonomy ("books" → "items", granular geography/years collapsed into dynamic `location_specific`/`num_years_covered`). The migration must reconcile the messy legacy penalties against this curated set.

## Owner strategy (approved 2026-07-11)

> *"The old site had a primitive version of dynamic penalties … the new way is much better. Most dynamic penalties map to global ones, except mostly-western — that's a book-specific dynamic penalty. Go penalty by penalty; if similar and global, match them; for the ones with no mapping, create book-specific penalties for now. We can refactor later."*

- **Dynamic `list_cons`** → reuse the seeded **`Global::Penalty`** singleton for that `dynamic_type`, **except `percentage_western`** ("mostly Western Canon books"), which has no global equivalent → one new **`Books::Penalty`** with `dynamic_type: percentage_western`.
- **Static `list_cons`** → reuse an existing **`Global::Penalty`** where clearly the same concept (exact name, or a small curated `books→items`/quote alias set); otherwise create a **`Books::Penalty`**, legacy name verbatim.

## Legacy data (local restore, introspected 2026-07-11)

- `list_cons`: **1,869 total; 78 belong to the 4 active RCs** (48=12, 52=12, 63=13, 68=41). Columns: `id, name, points (5–85), description, ranking_configuration_id, dynamic, dynamic_type, timestamps`.
- The legacy **`dynamic` boolean is always false**; the real signal is `dynamic_type` (integers 0–4 among active rows), which maps **1:1** to the new `Penalty` enum: 0→`number_of_voters`, 1→`percentage_western`, 2→`voter_names_unknown`, 3→`voter_count_unknown`, 4→`category_specific`.
- Among the 78: **no `(name, RC)` duplicates**; **45 distinct names** (46 distinct `(name, dynamic_type)` pairs).
- `list_con_lists`: **48,720 total; 2,351 touch active-RC list_cons** (join `ranked_list_id → ranked_lists.list_id`). Columns: `id, list_con_id, ranked_list_id, timestamps`. **0** referenced `list_id` missing a migrated `Books::List`.
- Existing target state (dev, pre-2c): 20 penalties (19 seeded `Global::Penalty` + 1 `Music`/`Games` each), 49 `penalty_applications` (music/games), 82 `list_penalties` (music/games). The 2c load is **additive** and never collides with those natural keys.

## Decisions

- **D-active-only — migrate active-RC `list_cons` only** (78 of 1,869). Scope by the RC `LegacyIdMap` legacy ids (`LegacyIdMap.where(model: "Books::RankingConfiguration").pluck(:legacy_id)`), **not** a hardcoded `[48,52,63,68]` — this ties 2c to exactly whatever RCs 2b migrated. `PenaltyMigrator` raises if that set is empty ("run `data_migration:ranking_configurations` first").
- **D-dynamic-by-type — dynamic `list_cons` resolve by `dynamic_type`, not by name.** Faithful to what the legacy engine actually computed. Consequence: the mistyped legacy row *"Voters: Voter names unknown"* carries `dynamic_type = 3` and therefore maps to Global **"Voters: Unknown Count"** (`voter_count_unknown`), *not* `voter_names_unknown` — its name is ignored (owner-confirmed).
- **D-percentage-western — one new `Books::Penalty`** named `List: only covers mostly "Western Canon" books`, `dynamic_type: percentage_western`, `user_id: nil`. No global equivalent exists (owner: book-specific). Being dynamic, it is never attached to a list (its `list_con_lists` drop, D-listpenalty-static).
- **D-static-reuse — reuse a `Global::Penalty` for a static `list_con` when the name matches exactly or via `GLOBAL_ALIASES`** (3 entries: the two `books→items` rewrites + one quote-only diff — see mapping table). Owner-approved "reuse Global (normalized)". All other static names → new `Books::Penalty` verbatim.
- **D-collision-max — on a `[penalty, RC]` collision, keep MAX(points).** The **only** collision in the active set: RC 52 has two `dynamic_type=3` rows → both target Global "Voters: Unknown Count" — *"Voter names unknown"* (pts 5, the mistype) and *"voter count unknown"* (pts 85). Result: **78 `list_cons` → 77 `penalty_applications`**. Implemented as `find_or_initialize` + `value = [existing, points].max` (per-row), which is also idempotent.
- **D-genre-static-to-dynamic — static "only covers 1 specific genre" (3 rows) reuses the *dynamic* Global `category_specific`** (name-exact match). Because that penalty is dynamic, its `list_con_lists` **cannot** become `list_penalties` and are dropped (owner-confirmed). This is the **only** place list associations are intentionally lost (12 `list_con_lists`).
- **D-listpenalty-static — `list_con_lists` → `list_penalties` for static-target `list_cons` only.** The 1,229 dynamic-side rows plus the 12 genre-static rows (→ dynamic global) are dropped; `ListPenalty#penalty_must_be_static` would reject them anyway. Net **1,110** `list_penalties`.
- **D-penalty-map — record `LegacyIdMap` key `"Penalty"`** for all 78 active-RC `list_con_id → penalty_id` (many-to-one). This is the resolver for `list_con_lists → list_penalties`. `penalty_applications` and `list_penalties` are join tables with natural keys — **no** id map of their own.
- **D-preserve — preserve `points → value`, `description`, and legacy timestamps where the row is *created*.** New `Books::Penalty` records take the legacy `list_con.description` (first-writer-wins across RCs) and legacy `created_at/updated_at`. Reused `Global::Penalty` records are **not** mutated (name/description/type left as seeded). `penalty_applications`/`list_penalties` preserve legacy timestamps.
- **D-no-schema — no migration.** All three target tables + unique indexes already exist.

## Source → target mapping

### `list_cons` (active RCs) → `penalties` (reuse-or-create) + `LegacyIdMap "Penalty"`

**Reuse existing `Global::Penalty` — 17 legacy names → 14 distinct globals** (the dynamic `t4` and the static "specific genre" rows both target the one `category_specific` global):

| legacy `list_con` name | via | target `Global::Penalty` |
|---|---|---|
| Voters: Voter Count | dyn t0 | Voters: Voter Count |
| Voters: Unknown Names | dyn t2 | Voters: Unknown Names |
| Voters: Voter names unknown | dyn t3 | Voters: Unknown Count *(D-dynamic-by-type)* |
| Voters: unknown count | dyn t3 | Voters: Unknown Count |
| Voters: voter count unknown | dyn t3 | Voters: Unknown Count |
| List: only covers 1 specific genre | dyn t4 | List: only covers 1 specific genre |
| List: Creator of the list, sells the books on the list | static (alias) | List: Creator of the list, sells the items on the list |
| List: contains over 500 books(Quantity over Quality) | static (alias) | List: contains over 500 items(Quantity over Quality) |
| List: criteria is not just "best/favorite" | static (alias) | List: criteria is not just best/favorite |
| List: is a follow up/honorable mention to a different list | static | List: is a follow up/honorable mention to a different list |
| List: only covers 1 specific gender | static | List: only covers 1 specific gender |
| List: only covers 1 specific genre | static | List: only covers 1 specific genre **[DYNAMIC → list_con_lists drop, D-genre-static-to-dynamic]** |
| List: only covers 1 specific language | static | List: only covers 1 specific language |
| Voters: are mostly from a single country/location | static | Voters: are mostly from a single country/location |
| Voters: diversity of voters is very low | static | Voters: diversity of voters is very low |
| Voters: not critics, authors, or experts | static | Voters: not critics, authors, or experts |
| Voters: restricted to a distinct criteria(race, gender, etc) | static | Voters: restricted to a distinct criteria(race, gender, etc) |

**Create new `Books::Penalty` (verbatim name, `user_id: nil`) — 29:** `percentage_western` (dynamic) + 28 statics the curated taxonomy dropped — granular geography (`1 specific city/country/continent/state/large|small region`, `partially covers 1 specific country`), time windows (`5/10/25/50/75/100 years`, `1 year`, `favorite book per year`), and finer voter/list criteria (`honorable mention`, `Only covers Series'`, `Podcast/Etc…`, `agenda/bias`, `half the voters…`, `specific voter details are lacking`, `weird criteria`, `genre fiction`, `translated/foreign`, `theme`, `aggregated lists`, `hard to find info`). Full list in the migrator's e2e assertion.

| new `penalties` column | source | handling |
|---|---|---|
| `type` | (constant) | `"Books::Penalty"` (STI via `Books::Penalty.new`); reused rows keep `"Global::Penalty"` |
| `name` | `list_con.name` | verbatim (created rows) |
| `dynamic_type` | `list_con.dynamic_type` | `percentage_western` for the one dynamic Books penalty; nil for the 28 statics |
| `user_id` | — | nil (global/unowned) |
| `description` | `list_con.description` | preserved (created rows, first-writer-wins) |
| `created_at`/`updated_at` | same | preserved (created rows) |

### `list_cons` (active RCs) → `penalty_applications` (natural key `[penalty_id, ranking_configuration_id]`)

| column | source | handling |
|---|---|---|
| `penalty_id` | `LegacyIdMap "Penalty"[list_con.id]` | mapped (reused global or created Books) |
| `ranking_configuration_id` | `LegacyIdMap "Books::RankingConfiguration"[list_con.ranking_configuration_id]` | mapped |
| `value` | `list_con.points` | direct; **MAX** on collision (D-collision-max); 5–85 all ≤100 ✓ |
| `created_at`/`updated_at` | same | preserved |

### `list_con_lists` (static-target) → `list_penalties` (natural key `[list_id, penalty_id]`)

| column | source | handling |
|---|---|---|
| `list_id` | `ranked_lists.list_id` (join on `ranked_list_id`) | direct (lists preserve id); fail-loud if not a `Books::List` |
| `penalty_id` | `LegacyIdMap "Penalty"[list_con_id]` | **static targets only**; dynamic-target rows dropped (D-listpenalty-static) |
| `created_at`/`updated_at` | same | preserved |

## Migrators (mirror 2a/2b; unit tests stub `legacy_each`)

- **`Services::BooksMigration::PenaltyResolver`** — pure. `call(list_con_attrs)` → `[:reuse, global_penalty]` or `[:create_books, {name:, dynamic_type:}]`, using preloaded `globals_by_name` + `globals_by_dynamic_type` and the `GLOBAL_ALIASES` constant. `.fetch` on the dynamic-type→global lookup so a missing seeded global fails loud. Fully unit-testable without a DB.
- **`Services::BooksMigration::PenaltyMigrator`** — `Migrator` (per-row). `legacy_model = LegacyBooks::ListCon`; `legacy_each` scopes `where(ranking_configuration_id: <RC map legacy ids>)` (raises if empty). `upsert_row`: resolve → for `:create_books` `Books::Penalty.find_or_create_by!(name:, user_id: nil)` setting `dynamic_type`/`description`/timestamps on create; record `LegacyIdMap "Penalty"`. Idempotent (find-or-create + map upsert).
- **`Services::BooksMigration::PenaltyApplicationMigrator`** — `Migrator` (per-row; ~77 rows). Preload `@penalty_map` (`"Penalty"`) + `@rc_map` (`"Books::RankingConfiguration"`), raise if either empty. `upsert_row`: `PenaltyApplication.find_or_initialize_by(penalty_id:, ranking_configuration_id:)`, `value = [value||0, points].max`, `save!` (validations on — value range + STI compatibility are a real safety net). Per-row `find_or_initialize` gives MAX-collapse and idempotency for free (no `upsert_all` "affect row twice" hazard).
- **`Services::BooksMigration::ListPenaltyMigrator`** — `BulkUpsertMigrator` on `[list_id, penalty_id]` (1,110 rows). Preload: `@penalty_map`, `@static_list_con_ids` (map entries whose penalty is `Penalty.static`), `Books::List` id set. `legacy_each`: `LegacyBooks::ListConList.joins(ranked_lists).where(list_con_id: @static_list_con_ids).select(id, list_con_id, rl.list_id)`. `build_rows`: guard `list_id` is a `Books::List` (fail-loud, names the `list_con_list` id) → `{list_id, penalty_id, timestamps}`. **Dedup `[list_id, penalty_id]` in-memory before upsert** (a natural-key collision `upsert_all` can't handle in one statement — 0 in current data, but structurally possible). `record_timestamps?` = false.
- New read-only legacy models `LegacyBooks::ListCon` (`table_name = "list_cons"`) and `LegacyBooks::ListConList` (`table_name = "list_con_lists"`).

## Orchestration

Add `data_migration:penalties` (→ `PenaltyMigrator` then `PenaltyApplicationMigrator`) and `data_migration:list_penalties` (→ `ListPenaltyMigrator`). Append to `data_migration:all` **after `:ranked_lists`**, order `:penalties` before `:list_penalties` (list_penalties need the `"Penalty"` map + static classification): `[…, :ranking_configurations, :ranked_lists, :penalties, :list_penalties]`.

## Testing (Minitest + Mocha, stub `legacy_each`)

**PenaltyResolver:** dynamic t0/t2/t3/t4 → the right seeded global (incl. the t3 mistype → `voter_count_unknown`); dynamic t1 → `[:create_books, percentage_western]`; static exact-match → reuse; static alias (`books→items`, quote) → reuse; unmatched static → `[:create_books, nil dynamic_type]`; missing seeded dynamic global → raises.

**PenaltyMigrator:** creates a `Books::Penalty` (verbatim name, preserved description/timestamps) for an unmatched static; reuses a global without mutating it; records `"Penalty"` map for every row; `dynamic_type` carried for percentage_western; idempotent (re-run: `Penalty.count` unchanged, map stable); empty RC map → `success: false`; search indexing suppressed.

**PenaltyApplicationMigrator:** maps penalty + RC, `value = points`; **MAX** on a same-`[penalty, RC]` collision; value/compatibility validations pass; idempotent (re-run unchanged); missing map → `success: false`.

**ListPenaltyMigrator:** static-target `list_con_list` → `list_penalty` (`list_id` via ranked_list join, `penalty_id` via map); **dynamic-target rows skipped**; fail-loud on a `list_id` with no `Books::List`; dedup `[list_id, penalty_id]`; idempotent.

## E2e verification (controller-run against the real legacy DB)

Reset dev DB to the 2b baseline, run `data_migration:penalties` then `:list_penalties` (twice each), then verify:
- **Penalties:** `Penalty.count == 49` (20 pre-existing + **29 new**: 28 `Books::Penalty` static + 1 `Books::Penalty` `percentage_western`); **0** new `Global::Penalty` (14 reused, unmutated); `LegacyIdMap.where(model: "Penalty").count == 78`; the 28 static Books names present verbatim; percentage_western Books penalty present.
- **penalty_applications:** **+77** (total 126); each `[penalty_id, ranking_configuration_id]` unique; RC 52 × "Voters: Unknown Count" `value == 85` (MAX proof); all `value` ≤ 100; every RC is one of the 4 mapped Books RCs.
- **list_penalties:** **+1,110** (total 1,192); every row static-penalty + existing `Books::List`; **0** dynamic-penalty rows; the 12 genre-static + 1,229 dynamic-side `list_con_lists` are **absent**.
- Idempotent: second run of each leaves all three counts unchanged.
- Full suite green; `standardrb` + `brakeman` clean (0 new).

## Out of scope
- **Archived-RC `list_cons`** (1,791) and their `list_con_lists` — excluded transitively (only active RCs were migrated in 2b).
- **Consolidating the 28 new `Books::Penalty` records** into the curated global taxonomy (dynamic `location_specific`/`num_years_covered`, merges) — owner deferred ("refactor later").
- **Mutating seeded `Global::Penalty`** rows (names/descriptions left as-is).
- `user_lists` (Phase 3).

## References
- Parent: `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`
- Prior increment (template): `docs/superpowers/specs/2026-07-09-books-ranking-configurations-migration-design.md` (2b)
- `Migrator` / `BulkUpsertMigrator`: `app/lib/services/books_migration/{migrator,bulk_upsert_migrator}.rb`
- Models: `app/models/{penalty,penalty_application,list_penalty}.rb`, `app/models/{global,books}/penalty.rb`; seeds `db/seeds.rb`
