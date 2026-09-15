# Books penalty reconciliation — design

**Date:** 2026-09-15
**Status:** approved design, awaiting implementation plan
**Domain:** books (migration + one books-only branch in the shared weight calculator)

## 1. What this is

Three corrections to how the legacy books penalties came across in the data migration,
found while checking why the primary configuration (RC 8, "May 2026") seemed to be
missing six penalties:

1. **One honorable-mention penalty.** Legacy RC 63 ("The Best Books of 2025") spelled it
   `List: honorable mention`; the migration minted `Books::Penalty` 24 for it instead of
   reusing `Global::Penalty` 4 (`List: is a follow up/honorable mention to a different
   list`). Same shape for `List: only covers books with a weird criteria(books to help
   you survive the digital age, etc)` → `Books::Penalty` 48 instead of `Global::Penalty` 7.
2. **Books moves from seven static year-span penalties to the dynamic
   `num_years_covered` global**, with a per-list value reviewed by hand, and a books
   curve in the calculator so the dynamic penalty actually discriminates on books.
3. **Already-migrated databases self-heal** through an idempotent reconcile step, so the
   fix does not depend on whether production is truncated before the next run.

### What was checked and is NOT a bug

- RC 8 carries 41 `penalty_applications`; legacy RC 68 carries exactly 41 `list_cons`.
  Nothing was dropped. Legacy `inherit_list_cons` is copy-on-create (`list_con.dup` in
  `RankingConfiguration#init_from_inherited`), so a config's own rows are its complete
  set and nulling `inherited_from_id` loses nothing.
- `Voters: specific voter details are lacking` (`Books::Penalty` 21) was dropped from the
  primary lineage at legacy RC 58 and survives only on the year lists (RC 5/6/7). It is
  a different concept from `Voters: Unknown Names`: only 7 of its 36 lists have
  `voter_names_unknown = true`, and legacy priced them 40 vs 5. **Decision: keep it as
  is.** Not touched by this work.
- `location_specific` and `voter_count_estimated` are new-app dynamic types with no
  legacy counterpart. Not touched: `voter_count_estimated` would be inert (0 books lists
  set it) and `location_specific` would double-penalise 100 of the 138 flagged lists
  that already carry a static location penalty. Separate decision, separate work.

### Non-goals

- No change to music/games/authors penalties or their curve. Their quadratic stays
  byte-for-byte.
- No admin UI. Per-list values live in a checked-in file (see §4).
- No sweep for books lists that *should* have had a year-span penalty in legacy but never
  got one. The review covers the 207 legacy lists that carry one.
- No fix for the `Penalties::Backfill` id-keying problem beyond removing the nine entries
  this work makes dead (§8).

## 2. Decisions

| # | Decision |
|---|---|
| 1 | **The resolver is where legacy names become new penalties.** Two new `GLOBAL_ALIASES`; the seven year-span names map to the `num_years_covered` global. Downstream migrators change only where they must (§3). |
| 2 | **Per-list `num_years_covered` is authoritative from `config/books_migration/num_years_covered.yml`**, keyed by list id (ids survive the migration). A list absent from the file gets its legacy bucket. The migrator reads values only; comments are for the reviewer. |
| 3 | **The derive task reads the legacy database only** and never rewrites an existing entry. New ids are appended; delete the file to regenerate from scratch. |
| 4 | **Yearly-award lists stay at 1.** Legacy's intent for `only covers 1 year (yearly book awards …)` was "each pick is best-of-one-year"; the parser never runs on that bucket. |
| 5 | **Conflicting buckets across legacy configs: the highest legacy RC id wins** (68 is the primary). Exactly one legacy list (237: buckets 1 and 25) is affected, and it appears in the review file. |
| 6 | **Books curve:** `max × (1 − ln(years) / ln(BOOKS_FULL_COVERAGE_YEARS))`, clamped to `0..max`, 0 at ≥ `BOOKS_FULL_COVERAGE_YEARS` years; the constant is 200. At max 50 this yields 50 / 35 / 28 / 20 / 13 / 9 / 6.5 for 1 / 5 / 10 / 25 / 50 / 75 / 100 years against legacy's 50 / 40 / 30 / 20 / 10 / 7 / 5. |
| 7 | **The reconcile step is by name, never by id.** Development ids are not production ids. Source and target penalties are located by their legacy/seed names (globals by `dynamic_type` where they have one), `user_id: nil` only. |
| 8 | **Reconcile treats every configuration uniformly**: any RC holding a year-span application gets `(num_years_covered global, MAX(value))`, including user-owned clones. No special-casing of RC 8. |
| 9 | **Order in `data_migration:all`:** `penalties` → `list_penalties` (now also sets `num_years_covered`) → `penalties:reconcile`. Reconcile runs after the per-list values exist so no list is ever without both its static and its dynamic time-scope signal. |
| 10 | **Weights are recalculated and persistence is verified by reading rows back**, not by trusting the job's success message (see `books-weights-drifted-2x`). |

## 3. Migration changes

### 3.1 `Services::BooksMigration::PenaltyResolver`

Two entries added to `GLOBAL_ALIASES` (legacy name → seeded global name):

```
"List: only covers books with a weird criteria(books to help you survive the digital age, etc)"
  => "List: only covers items with a weird criteria"
"List: honorable mention"
  => "List: is a follow up/honorable mention to a different list"
```

A new `YEAR_SPAN_BUCKETS` constant, legacy name → bucket years:

```
"List: only covers 1 year (yearly book awards, best of the year, etc)" => 1
"List: only covers 5 years"   => 5
"List: only covers 10 years"  => 10
"List: only covers 25 years"  => 25
"List: only covers 50 years"  => 50
"List: only covers 75 years"  => 75
"List: only covers 100 years" => 100
```

`call` checks `YEAR_SPAN_BUCKETS` before the alias lookup and returns
`[:reuse, globals_by_dynamic_type.fetch("num_years_covered")]` for those names. This is
the same shape genre already takes (`only covers 1 specific genre` → `category_specific`).

Everything downstream falls out of existing machinery:

- `PenaltyMigrator` records seven `LegacyIdMap "Penalty"` rows pointing at one global
  (many-to-one is already the documented shape of that map).
- `PenaltyApplicationMigrator` collapses them into one `(global 17, RC)` application with
  `value = MAX(points)` — its existing `[penalty, rc]` collision rule. For RC 68 → 8 that
  is 50, the legacy one-year value, which is also where the books curve peaks.
- `ListPenaltyMigrator` already drops `list_con_lists` whose target penalty is dynamic
  (`ListPenalty` is static-only), so no orphan `list_penalties` are written.

### 3.2 New `Services::BooksMigration::NumYearsCoveredMigrator`

Runs inside `data_migration:list_penalties`, after `ListPenaltyMigrator`. Subclass of
`Migrator`.

- **Source rows:** legacy `list_con_lists` joined to `ranked_lists` for `list_id`, limited
  to `list_con_id`s whose `LegacyIdMap "Penalty"` target is the `num_years_covered` global
  (so it is driven by the resolver's decision, not by re-matching names). Carries the
  legacy `list_con.name` and `ranking_configuration_id`.
- **Bucket:** `PenaltyResolver::YEAR_SPAN_BUCKETS.fetch(list_con.name)`.
- **Per list, in memory:** keep the row with the highest `ranking_configuration_id`
  (Decision 5).
- **Value:** `overrides[list_id] || bucket`, where `overrides` is the YAML from §4 loaded
  once in `preload`.
- **Write:** `Books::List.where(id: list_id).update_all(num_years_covered: value)` per
  list — plain overwrite, idempotent, no callbacks (search indexing is suppressed by the
  base class for the run anyway; nothing else on `List` needs to fire).
- **Missing parents:** skip `ListMigrator.superseded_legacy_list_ids`, raise on any other
  missing list, exactly as `ListPenaltyMigrator` does.
- **Override ids with no list:** counted and reported in the result as `unknown_override_ids`,
  not raised — a reviewed file should not brick the migration because a list was deleted.
- **Guards:** raises if the Penalty map is empty (run `penalties` first) or no
  `Books::List` exists (run `lists` first).
- **Result:** `{success:, data: {model: "Books::List#num_years_covered", count:, overrides_applied:, unknown_override_ids: [...]}}`.

It does **not** clear `num_years_covered` on lists that have no year-span row. Legacy has
no such value to migrate, and a value set by hand in admin should survive a re-run that
is not a truncate.

## 4. The review file and the derive task

### 4.1 File

`web-app/config/books_migration/num_years_covered.yml`. Plain YAML mapping of list id →
positive integer, written as text so comments survive:

```yaml
# Books lists: number of publication years the list's scope allowed.
# Generated by `bin/rails data_migration:num_years_covered:derive` from the LEGACY
# database. Edit values freely; existing entries are never rewritten. Delete the file
# to regenerate from scratch. Read by NumYearsCoveredMigrator (values only).
#
# id: years   # list name  (legacy bucket → how the number was derived)
1893: 24      # 100 Best Books of the 21st Century  (25 → 21st century so far, published 2024)
2211: 2       # Africa's 100 Best Books of the 20th Century  (100 → 21st century so far, published 2002; FROM DESCRIPTION)
237: 25       # The 10 Best Books Through Time  (1 and 25 in legacy; CONFLICT, highest RC wins → 25)
```

Loaded with `YAML.safe_load` → `Hash{Integer => Integer}`; the migrator validates every
value is a positive integer and raises naming the offending id otherwise.

### 4.2 Task `data_migration:num_years_covered:derive`

Service `Services::BooksMigration::NumYearsCoveredDeriver` (pure: takes rows, returns
entries; the rake task does the legacy reads and the file write so the parser is unit-
testable without a legacy connection).

Input per legacy list: `id`, `name`, `description`, `year_published`, and its bucket
(same join and highest-RC rule as §3.2, but read directly from legacy `list_cons` by
name because this runs before or independently of any migration).

Rules, tried in order, **on the name first; the description only if the name yields
nothing**, and the entry records which (`FROM DESCRIPTION` is the reviewer's cue for the
false positives this produced in the prototype):

| # | Pattern | Value | Note |
|---|---|---|---|
| 0 | bucket is 1 | 1 | never parsed (Decision 4) |
| 1 | `YYYY` `-`/`–`/`to`/`through`/`until` `YYYY` | end − start + 1 | years 1500–2029; end ≥ start; span < 400 |
| 2 | `past`/`last`/`previous` N `years` | N | |
| 3 | `half century` / `quarter century` | 50 / 25 | |
| 4 | `since`/`from` `YYYY` | `year_published − YYYY + 1` | uses current year and flags `NO year_published` when missing |
| 5 | decade (`1980s`, `80s`, `decade`) | 10 | |
| 6 | `21st century` | `year_published − 2000` | same flag as rule 4 |
| 7 | `20th century`, `century`, `100 years` | 100 | |
| — | `millennium` | no value | the prototype's 1000 was wrong (the list was 2000–2009); left to the reviewer |
| — | nothing matched | bucket | comment says `unparsed` |

Every entry's comment carries: list name, legacy bucket, rule/reason, and any flags
(`FROM DESCRIPTION`, `NO year_published`, `CONFLICT`). When the derived value equals the
bucket the reason still appears, so agreement is visible too.

**Regeneration:** the task loads the existing file (if any), keeps every existing line
verbatim, appends entries for ids not present, and prints how many were kept vs added.

Prototype numbers on the current legacy data, for sizing the review: 205 lists in the
new DB (207 legacy, two are superseded); 197 parsed, 143 equal to the bucket, 54 differ,
8 unparsed. Roughly ten of the 54 are description false positives the name-first rule
removes; the rest are real refinements (every "21st century" list becomes 15–24 instead
of a flat 25).

## 5. The books curve — `Rankings::WeightCalculatorV1`

The quadratic lives twice today (`calculate_temporal_coverage_penalty_with_calculation_details`
and `calculate_temporal_coverage_penalty_for_penalty`). Extract one private method:

```ruby
# => [penalty_value, calculation_details]
def temporal_coverage_penalty(years_covered, max_penalty)
```

- **Books lists** (`list.class.name =~ /^Books::/`): Decision 6. `calculation_details`
  carries `years_covered`, `full_coverage_years`, `media_type`, `formula`.
- **Everything else:** the existing `max × (1 − years/range)^2` with `range =
  calculate_media_year_range`, `exponent = 2.0`, and the existing `details` keys,
  unchanged. `calculate_books_year_range` stays defined (nothing else calls it, but
  removing it is not this work's job).

Both callers use the new method; the non-details caller discards the details. The
constant `BOOKS_FULL_COVERAGE_YEARS = 200` sits beside `PERCENTAGE_WESTERN_THRESHOLD`.

Why a log curve: for books the quadratic is flat — `calculate_books_year_range` is 5027,
so a 100-year list keeps 96 % of the max and a 1-year list 99.96 %. A data-derived range
does not help (1st-percentile `first_published_year` is 1250). The log form reproduces
the legacy gradient within a few points at every bucket.

## 6. Reconcile — `data_migration:penalties:reconcile`

Service `Services::BooksMigration::PenaltyReconciler`, idempotent, appended to
`data_migration:all` after `list_penalties`. Result reports every count below; a second
run reports all zeros.

**Step 1 — merge duplicates into globals.** Pairs, located by name with `user_id: nil`
(Decision 7):

| source (`Books::Penalty`, by legacy name) | target (`Global::Penalty`, by seed name) |
|---|---|
| `List: honorable mention` | `List: is a follow up/honorable mention to a different list` |
| `List: only covers books with a weird criteria(books to help you survive the digital age, etc)` | `List: only covers items with a weird criteria` |

For each pair, when the source exists:
- `list_penalties`: for each source row, if `(target, list)` exists delete the source
  row, else `update(penalty_id: target)`.
- `penalty_applications`: for each source row, if `(target, rc)` exists set the target's
  `value = MAX(both)` and delete the source row, else `update(penalty_id: target)`.
- `destroy` the source penalty (its `dependent: :destroy` associations are already empty).

**Step 2 — year-span statics → the dynamic global.** Sources: the seven
`YEAR_SPAN_BUCKETS` names as `Books::Penalty, user_id: nil`; target: the
`num_years_covered` global.
- For every RC with an application to any source: `find_or_initialize_by(target, rc)`,
  `value = MAX(existing target value, MAX(source values on that rc))`, save.
- `destroy` each source penalty, which cascades its `list_penalties`. The step is ordered
  after `NumYearsCoveredMigrator` so the per-list values already exist when the statics
  vanish (Decision 9); the migrator reads legacy rows, not these `list_penalties`, so the
  order is about never leaving a list with neither signal, not about data dependency.

**Step 3 — nothing else.** No weight recalculation inside the task; that is a separate,
deliberate step (§7).

On a fresh run with the new resolver, none of the sources exist and the task is a no-op.

## 7. Weights and rankings (dev, then production)

After `reconcile` on a migrated database the weights of the ~205 affected lists are stale.
Run `Services::RankingConfiguration::CalculateWeights` for each books RC that gained the
dynamic application (RC 8 and, in dev, RC 10), then **verify persistence by reading rows
back**:

```ruby
rc.ranked_lists.count { |r| r.calculated_weight_details.to_h.dig("final_calculation", "final_weight") != r.weight }
# => must be 0
```

then `calculate_rankings`. Before doing so in dev, capture a before/after of: the 205
lists' weights, the top 25 books, and the western share — the ranking movement is shown
to Shane before any of this is scheduled against production.

Production: books is a rehearsal copy that is truncated and re-migrated before launch, so
the normal path is "fresh run with the new resolver", and the reconcile step is insurance
for an incremental re-run. Either way the weight recalculation and its persistence check
are part of the launch sequence, not of this task.

## 8. Visible effects and housekeeping

- **Public rankings explainer** (`Services::RankingConfiguration::ExplainerData`): the
  "How much time the list covers" section for books goes from seven rows to one; the
  dynamic global is already categorised `list_time_scope` and already has a public
  description, so nothing lands under "Other". `automatic_adjustments` now includes it
  for books, which is correct.
- **User ranking-configuration form** (`RankingConfigurations::PenaltyRows` via
  `Registry.penalties_for`): dynamic penalties are always listed and statics only when
  tagged on an active list, so the seven statics drop out on their own once their
  `list_penalties` cascade away. A user-owned books configuration that copied RC 8
  before this ships keeps a time-scope penalty because Step 2 upserts the dynamic
  application on every RC that held the statics.
- **`Penalties::Backfill::ENTRIES`** (`lib/tasks/penalties.rake`): remove the nine
  entries for penalties this work deletes (ids 24, 28, 29, 30, 33, 35, 40, 41, 48 in
  dev). The task already skips missing ids, but a stale entry whose id is later reused
  by another penalty would trip its mismatch exit.
- **Docs:** no feature doc enumerates the `data_migration:*` tasks today and this work
  does not add one; the rake `desc` strings and the review file's own header (§4.1) are
  the documentation of the workflow.

## 9. Testing

Minitest, fixtures, Mocha; legacy connections are stubbed as the existing migrator tests
do.

- **`PenaltyResolver`:** the two aliases reuse the globals; each of the seven year-span
  names reuses the `num_years_covered` global; a static name that matches nothing still
  creates a `Books` penalty (regression).
- **`NumYearsCoveredMigrator`:** override beats bucket; bucket applies when absent;
  highest-RC wins on conflict; superseded list skipped, other missing list raises;
  non-positive override value raises naming the id; unknown override id is reported not
  raised; a list with no year-span row is left untouched; second run is a no-op.
- **`NumYearsCoveredDeriver`:** one case per rule in §4.2 plus: name beats description;
  description-only match is flagged; missing `year_published` is flagged; bucket-1 never
  parsed; `millennium` yields no value; regeneration keeps an existing edited line and
  appends only new ids.
- **`WeightCalculatorV1`:** books at max 50 pins the seven bucket points to one decimal
  (1 → 50.0, 5 → 34.8, 10 → 28.3, 25 → 19.6, 50 → 13.1, 75 → 9.3, 100 → 6.5), 0 at 200
  and above, clamped never negative; a music
  list at the same inputs still gets the quadratic (assert the exact pre-change value so
  the extraction is proven behaviour-preserving); details hash keys for each branch.
- **`PenaltyReconciler`:** merge with a colliding `list_penalty` and a colliding
  application (MAX wins); non-colliding rows are repointed; statics on two RCs produce
  two dynamic applications at each RC's own MAX; statics and duplicates are gone
  afterwards; **the task run twice reports all-zero counts the second time and leaves
  the database identical**; fresh state (no sources) is a no-op.
- **Rake wiring:** `test/tasks/data_migration_test.rb` gains the new tasks and asserts
  `all` orders `list_penalties` before `penalties:reconcile`.
- **Lint:** `bundle exec standardrb`; `CI=1 bin/rails zeitwerk:check` (no new `app/lib`
  directory, but the check is cheap).
- **No new E2E:** no new page or flow. The explainer and the user RC form are existing
  pages whose content shrinks; their existing tests cover rendering.

## 10. Implementation order

1. Calculator extraction + books branch (pure, tested first — everything else depends on
   the dynamic penalty meaning something on books).
2. Resolver aliases + `YEAR_SPAN_BUCKETS`.
3. `NumYearsCoveredDeriver` + rake task; generate the file from the legacy DB; Shane
   reviews the ~60 flagged lines.
4. `NumYearsCoveredMigrator` + wiring into `list_penalties`.
5. `PenaltyReconciler` + rake task + `all` ordering; backfill entries removed.
6. Run in dev on a snapshot (`COMPOSE_PROJECT_NAME=the-greatest bin/snapshot-dev-db.sh
   --label pre-penalty-reconcile` from the worktree), recalc weights with the persistence
   check, show before/after.
