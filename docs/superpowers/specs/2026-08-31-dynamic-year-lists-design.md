# Dynamic Year Lists — Design

Date: 2026-08-31
Status: Approved, ready for implementation planning
Scope: Books, Games, Music::Albums, Music::Songs. Books is the priority and the only domain
with existing data; the other three gain the capability and use it when they want a year.

## Summary

Every November and December, 200+ "Best Books of <year>" lists appear at once. Each covers a
single year, so each is heavily penalised — but 200 heavily-penalised lists still swamp a
corpus of 623, because influence in the ranking engine is weight × length, and presence beats
position.

The existing answer, carried over from the legacy site: give the year its own
`RankingConfiguration` with its own penalties, rank the year's lists there in isolation, and
feed the *result* back into the main configuration as exactly two lists — a top 100 and an
overflow. The main configuration sees two lists for 2025 rather than the 43 currently attached
to the 2025 configuration, out of the 70 books lists carrying `year_published = 2025`.

The mechanism is sound and stays. What changes is that every step around it stops being
manual: the year configuration is assembled by one action, the two output lists are created
and owned by a generator, and the recalculation order that makes the output correct is
enforced by the code rather than remembered by the operator.

## Background: the legacy implementation

`the-greatest-books/admin/app/models/ranking_configuration.rb#create_dynamic_list`, plus a
button in `app/views/admin/ranking_configurations/show.html.erb` and a `create_dynamic_lists`
member route.

```ruby
def create_dynamic_list
  return unless primary_mapped_list.present?
  ActiveRecord::Base.transaction do
    primary_mapped_list.list_items.destroy_all
    secondary_mapped_list&.list_items&.destroy_all
    ranked_books = Book.sorted_by_rank(self)
    if primary_mapped_list_cutoff_limit.present?
      ranked_books.limit(primary_mapped_list_cutoff_limit).each_with_index { ... }
      ranked_books.offset(primary_mapped_list_cutoff_limit).each_with_index { ... }
    else
      ranked_books.each_with_index { ... }
    end
  end
end
```

Note `limit` then `offset`: `primary_mapped_list_cutoff_limit` is a **count**, not a rank
boundary. The design below keeps that meaning for its sibling column.

Everything else was hand work, repeated per year: create the configuration, pick its
penalties, attach the year's lists, hand-create both output lists with their metadata and
penalties, attach those to the main configuration, set the three mapped-list columns, click
the button, then refresh the main configuration.

### The legacy penalty model differed, and this matters

Legacy `ListCon belongs_to :ranking_configuration`, and `ListConList` joined a `list_con` to a
**ranked_list**. Both the penalty definition and its per-list attachment were scoped to one
configuration, so a list could carry a penalty in one configuration and not another.

The new app split that: `Penalty` is global, `list_penalties` attaches penalty→list globally,
and `penalty_applications` attaches penalty→configuration with a value. A list therefore
carries the same penalty tags everywhere, and **the only lever a year configuration has is
which penalties it applies and at what value.** You cannot exempt one list locally. That is
why excluding a whole penalty category from year configurations is the correct mechanism
rather than merely a tidy one.

## What is already in the new app

The three columns migrated over and are live: `ranking_configurations.primary_mapped_list_id`,
`secondary_mapped_list_id`, `primary_mapped_list_cutoff_limit`, with `belongs_to`
associations, form fields, permitted params, and a card on the admin show page. Only the
generation code is missing.

Real data in development:

| id | Configuration | Lists | Penalty apps | Mapped lists | Cutoff |
|---|---|---|---|---|---|
| 5 | The Best Books of 2024 | 60 | 12 | 746 / 747 | 100 |
| 6 | The Best Books of 2023 | 30 | 11 | 1041 / 1042 | 100 |
| 7 | The Best Books of 2025 | 43 | 13 | 1088 / 1089 | 100 |
| 8 | May 2026 (primary) | 623 | 41 | — | — |

The year configurations and the main configuration share **zero** lists. The mechanism works
exactly as intended.

`Services::Lists::GenerateUserFavorites` (PRs #273/#274) already solved this problem shape:
a generated list identified by `auto_generated_kind` rather than by name, whose wiring —
penalties, `RankedList`, weight recalculation — is re-asserted as an invariant on every run,
with `List` and `ListItem` guards blocking hand edits. This design extends that pattern
rather than introducing a second way of doing the same thing.

## The problems, with evidence

### 1. Hand-created output lists have drifted, and two are dead

| List | Items | Weight in main config |
|---|---|---|
| 1089 — 2025 Honorable Mention | 790 | 30 |
| 747 — 2024 Honorable Mention | 1,114 | **0** |
| 1042 — 2023 Honorable Mention | 723 | **0** |

From `calculated_weight_details`:

- **747**: `voter_count_unknown = true` (85), `high_quality_source = false`, plus static
  penalties 50 + 50 and `voter_names_unknown` 5 → 190% → capped at 100% → weight 0.
- **1089**: `voter_count_unknown = false`, `high_quality_source = true` → 105% → quality bonus
  ×2/3 → 70% → weight 30.

Identical lists in every meaningful respect; different hand entry. **1,837 items currently
contribute nothing to the books rankings.**

### 2. The recalculation order is undocumented and unenforced

`create_dynamic_list` reads the year configuration's rankings. If those are stale, the output
is wrong, silently. After regeneration the main configuration is stale until refreshed
separately. Nothing in the code expresses either dependency.

### 3. Year configurations are assembled by hand, and have drifted too

| | 2023 | 2024 | 2025 | main |
|---|---|---|---|---|
| exponent | 1.5 | 1.5 | 3.0 | 3.0 |
| bonus_pool_percentage | 2.0 | 2.0 | 6.0 | 3.0 |
| apply_list_dates_penalty | false | false | false | true |
| penalty applications | 11 | 12 | 13 | 41 |

### 4. Penalty coverage in a year configuration is silent when incomplete

`WeightCalculatorV1#calculate_static_penalties_with_details` skips a list's `list_penalty`
when the configuration has no matching `penalty_application`. Omitting a penalty does not
neutralise it — it makes it **invisible**.

Measured: the 43 lists on configuration 7 carry only 5 distinct static penalties, and all 5
are applied. Nothing is being ignored *today*. But the set only covers what today's lists
happen to carry — a 2026 list tagged "only covers 1 specific country" (main applies it at 20)
would have that restriction ignored entirely.

## Design

### 1. Data model

**`ranking_configurations`** gains two nullable integer columns:

- `year` — the year this configuration scopes to; `NULL` on the main configuration. Today the
  year exists only inside the name string. Both the generator (to name lists and stamp
  `year_published`) and the clone action (to compute the next year) need it as data.
- `secondary_mapped_list_cutoff_limit` — a **count**, matching its sibling. Applied as
  `offset(primary_cutoff).limit(secondary_cutoff)`.

Validations: both `numericality: {only_integer: true, greater_than: 0}, allow_nil: true`. No
uniqueness on `(type, year)` — competing configurations for the same year are legitimate, and
which lists are "the" output is determined by the mapped-list pointers, not by the year.

**`lists`** gains `auto_generated_year` (integer, nullable), and `auto_generated_kind` gains
two values alongside `user_favorites: 0`:

```ruby
enum :auto_generated_kind, {user_favorites: 0, year_top: 1, year_honorable_mention: 2},
  prefix: :generated
```

The unique index changes from `(type, auto_generated_kind)` to:

```ruby
add_index :lists, [:type, :auto_generated_kind, :auto_generated_year],
  unique: true, nulls_not_distinct: true,
  where: "auto_generated_kind IS NOT NULL",
  name: "index_lists_on_type_and_auto_generated_kind_and_year"
```

PostgreSQL is 17.4 and Rails 8.1 round-trips `nulls_not_distinct` through the schema dumper
(it is parsed back from `inddef` in `postgresql/schema_statements.rb`). `NULLS NOT DISTINCT`
keeps `user_favorites` rows — whose year is `NULL` — collapsed to one per domain, exactly as
today, while permitting one `year_top` and one `year_honorable_mention` per year per domain.
One index, not two.

**Per-`RankingConfiguration`-subclass**, a `generated_list_class` returning the domain's
`List` subclass (`Books::List`, `Games::List`, `Music::Albums::List`, `Music::Songs::List`),
paired with a `supports_year_rollups?` predicate that returns `false` on the base class and
`true` wherever `generated_list_class` is defined. The predicate is what the guard and the
admin view test — not `respond_to?`, which would answer `true` everywhere because the base
class defines the method in order to raise. `Books::Authors::RankingConfiguration` and
`Music::Artists::RankingConfiguration` define neither, so year rollups are unavailable there:
an author is not released in a year.

Generated names derive from the existing `media_noun_plural`, which capitalises correctly for
all four supported domains: "The 100 Greatest Books of 2025", "The Greatest Books of 2025 -
Honorable Mention".

**The mapped-list pointers become outputs, not inputs.** With list identity keyed on
`(type, kind, year)`, `primary_mapped_list_id` and `secondary_mapped_list_id` are a
denormalisation the generator maintains so the admin page can link to the lists. On the form
they become read-only, which is what stops the two sources of truth diverging.

### 2. `Actions::Admin::CreateNextYearConfiguration`

One action, no form. Run from any configuration in the domain; it derives everything from the
type.

**Target year.** The highest `year` among that domain's year configurations, plus one. If the
domain has none, the current year.

**Source and settings.** The previous year's configuration where one exists, so tuning carries
forward (2025's exponent 3.0 and bonus 6.0 survive rather than reverting to main's 3.0/3.0).
Otherwise the domain's `default_primary`. Four fields are **forced**, not copied, because they
are structurally true of any year configuration:

- `apply_list_dates_penalty = false`. All three existing year configurations set this. It
  matters most in the first-year case: cloning from main would inherit `true` and penalise
  2026 books for appearing on 2026 lists.
- `max_list_dates_penalty_age = nil`, `max_list_dates_penalty_percentage = nil`.
- `primary = false`, `global = true`, `published_at = nil`, `archived = false`.
- `year` = target year; `name` = "The Best <Noun> of <year>".

Not copied: `primary_mapped_list_id`, `secondary_mapped_list_id`, `inherited_from_id`. Year
configurations are independent copies, not inheritance children — 2025 diverged from 2024 on
purpose.

**Cutoffs.** `primary_mapped_list_cutoff_limit` from the source, defaulting to **100**;
`secondary_mapped_list_cutoff_limit` from the source, defaulting to **400** — giving ranks
101–500, comfortably under main's "contains over 500 items" threshold of 500.

**Penalties — the union rule.** Every `penalty_application` from the source year at its tuned
value, then every penalty the domain's `default_primary` applies that the source lacks, at
main's value, **excluding**:

- every penalty whose `category` is `list_time_scope`, and
- any penalty with `dynamic_type: :num_years_covered`, regardless of category.

The second clause is belt-and-braces. Today there are **zero uncategorized penalties** and the
one dynamic time penalty is correctly categorised, but `category` is nullable and a penalty
created in admin could arrive without one.

The rule is justified by the data: **all 7 `list_time_scope` penalties are absent from all
three year configurations.** The exclusion was already being applied by hand, consistently;
it simply was not written down. Inside a single-year configuration a time-scope penalty fires
on everything or nothing, so it carries no signal either way.

Every other category discriminates fine within a year — `voter_expertise`,
`voter_participation`, `list_subject_scope` ("Best Australian Books of 2025" is still narrower
than "Best Books of 2025"), and `list_integrity`.

Starting from the previous year rather than from main protects three values deliberately tuned
upward on the year configuration:

| Penalty | main | 2025 |
|---|---|---|
| Voters: not critics, authors, or experts | 60 | 70 |
| Voters: are mostly from a single country/location | 5 | 20 |
| List: only covers 1 specific genre | 20 | 40 |

Applied to real data, creating a 2026 books configuration copies all 13 of 2025's applications
untouched and adds roughly 20 from main, closing gaps such as "only covers 1 specific country"
(20) and "has a focus on a specific theme" (40).

**It reports its work**: the year created, how many applications were copied from the source,
how many added from main, and how many skipped as time-scope. That report is what makes the
automation auditable, and it is the same information a standing coverage check would give,
delivered when it matters.

### 3. `Services::Lists::GenerateDynamicLists`

`call(ranking_configuration:)`, returning the standard
`Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Invoked from
`GenerateDynamicListsJob`, queued by `Actions::Admin::GenerateDynamicLists`.

**Guards.** Fails with a clear message when the configuration has no `year`, no
`generated_list_class`, or no `primary_mapped_list_cutoff_limit`. Legacy silently dumped
everything into one list in that last case.

**The ordered pipeline**, which is the part currently left to the operator:

1. `Rankings::BulkWeightCalculator.new(year_config).call` — the year configuration's list
   weights.
2. `year_config.calculate_rankings` — **synchronously**, so step 3 cannot read stale ranks.
3. Write both lists.
4. `Rankings::BulkWeightCalculator.new(main_config).call_for_ids([rl_top.id, rl_hm.id])` —
   just the two affected rows, using the existing `call_for_ids` path.
5. `CalculateRankingsJob.perform_async(main_config.id)` — safe as async, because the lists are
   fully written and weighted before it is enqueued.

Measured cost: steps 1–2 take **0.3–0.6s** per year configuration (43–60 lists, ~900–1,200
items). Step 5 is the heavy one — 623 lists for books, then author rankings, then the search
reindex — but it is the identical job the existing **Refresh Rankings** button already queues.
This adds no new load to the serial Sidekiq queue; it removes a step the operator had to
remember to perform second.

**List identity** is `(type, auto_generated_kind, auto_generated_year)`, found via
`find_or_create_by!`, never by name. The user-favorites work was bitten twice by name-based
lookup, which cannot survive a rename.

**Item windows.** Primary: ranks 1…`primary_cutoff`. Secondary:
`offset(primary_cutoff).limit(secondary_cutoff)`. Positions renumber from 1 in each list.
Written with `delete_all` + `insert_all`, bypassing the `ListItem` callbacks deliberately —
those guards exist to stop humans editing generated rows and need no escape hatch here.
Each row carries `metadata: {rank:, score:}` from the source `RankedItem` for debugging, and
`verified: true`.

**Fields re-asserted on every run** — the drift fix:

| Field | Value | Reason |
|---|---|---|
| `num_years_covered` | `1` | The only time penalty games/albums/songs have (see below) |
| `number_of_voters` | count of **active** source lists | See below |
| `voter_count_unknown` | `false` | This is what zeroed 747 and 1042 |
| `high_quality_source` | `true` | The other half of that fix |
| `voter_names_unknown` | `true` | Honest; costs 5%; matches 1089 today |
| `voter_count_estimated` | `false` | |
| `year_published` | the configuration's `year` | |
| `category_specific`, `location_specific`, `creator_specific` | `false` | |

**Deliberately left alone after creation**: `name`, `description`, and `status`. Names are the
operator's to reword. `status` is the operator's lever for pulling a list out of the rankings
and must survive a re-run — the same rule `GenerateUserFavorites` settled on.

**Penalties attached** (as `list_penalties`, never as `PenaltyApplication` values — attaching a
tag is a fact about the list; setting its value is an editorial judgement the generator does
not make):

- The domain's static one-year penalty, looked up by name via a per-subclass constant, where
  one exists. Books only, and the name is exactly
  `"List: only covers 1 year (yearly book awards, best of the year, etc)"`. A missing penalty
  logs a warning and continues, matching `GenerateUserFavorites::STANDARD_PENALTY_NAME` — a
  half-wired list beats no list.
- `Global::Penalty` "List: is a follow up/honorable mention to a different list" on the
  secondary list. Already applied in all four domains: books 50, games 40, albums 50, songs 50.

**Wiring re-asserted**: a `RankedList` joining each output list to the domain's
`default_primary`, created if absent — the same invariant-maintenance that lets a
half-wired list be repaired by the next run rather than staying inert.

#### Why `num_years_covered = 1` is mandatory

The four domains penalise time scope by two different mechanisms:

| Domain | Mechanism | Value |
|---|---|---|
| Books | **Static** `Books::Penalty` "List: only covers 1 year" | 50 |
| Games | **Dynamic** `Global::Penalty` "List: number of years covered" | 50 |
| Albums / Songs | **Dynamic**, same Global penalty | 60 |

The dynamic form fires off `list.num_years_covered`. Without setting it, a "100 Greatest
Albums of 2026" rollup would enter the music rankings with **no time penalty at all**, weighing
like an all-time list. For books it is inert, since main applies only the static form — so
setting it is correct everywhere. Double-counting would require a configuration to apply both
the static and dynamic forms, which none does and which would be visible in admin.

#### Why `number_of_voters` counts source lists

The 43 lists on configuration 7 hold voter counts of
`[1×17, 3, 3, 4, 5, 6, 6, 7, 8, 8, 10×5, 11, 12, 12, 16, 16, 19, 25, 25, 50]` — 40 present,
3 nil, summing to 303. Seventeen are single-critic picks.

Counting lists (43) rather than summing voters (303), because:

- **The underlying counts are already priced in.** A 1-voter source list is hammered by the
  voter-count penalty inside the year configuration; a 50-voter list is not. That weight
  decides how much each source shapes the rollup's *content*. Summing prices the same evidence
  twice.
- **303 is the less true number.** `number_of_voters` renders publicly
  (`app/views/books/lists/show.html.erb:19`). "303 voters" reads as one electorate of 303,
  which it is not — those 17 single-critic lists overlap in personnel. "43" describes what the
  rollup is: 43 ballots aggregated.
- **Summing needs an arbitrary nil rule** for the 3 lists without counts.
- **It changes nothing today.** Books' median voter count is 24; both 43 and 303 clear it, so
  the penalty is zero either way. The number only bites in a thin configuration — a first-year
  games rollup from 8 sources against a median of 11 — and there "8 independent sources
  agreed" is the honest measure.

Scoped to **active** source lists, matching `ItemRankings::Calculator#prepare_lists`, which
reads only `status: :active`. Deactivating a source self-corrects the count on the next run.

Median voter counts for reference: books 24, games 11, albums 20, songs 17.

### 4. Admin surface

- **Form**: add `year` and `secondary_mapped_list_cutoff_limit` alongside the existing
  `primary_mapped_list_cutoff_limit`. The form has never rendered fields for
  `primary_mapped_list_id` / `secondary_mapped_list_id` — the controller permits them but
  nothing offers them, so those values arrived only via migration. Leave the form that way and
  **remove both `_id` keys from the permitted params**, since the generator now owns them.
- **Show page**: extend the existing mapped-lists card with the year, both cutoffs, and each
  generated list linked with its item count and last-generated time.
- **Actions dropdown** (`app/views/admin/ranking_configurations/show.html.erb`, which
  hard-codes its entries): add **Create Next Year's Configuration**, and **Generate Dynamic
  Lists** shown only when `year` is present. Both names added to `allowed_action_names`.

The existing `List#prevent_destroy_when_auto_generated` and
`ListItem#prevent_destroy_when_auto_generated` guards key on `auto_generated_kind` alone, so
the two new kinds inherit edit and delete protection with no new code. Consequence: an adopted
list cannot be deleted through admin without first clearing `auto_generated_kind`. That is
correct for live lists and is documented rather than given an escape hatch.

### 5. Adopting the existing data

`lib/tasks/dynamic_lists.rake`:

**`dynamic_lists:adopt`** — walks every configuration with a `primary_mapped_list_id`, which is
a clean bridge: the pointers already identify the right lists, so no name matching is needed.
Takes the year from `primary_mapped_list.year_published` (data, not a name parse), then:

- sets `year` on the configuration if nil;
- sets `secondary_mapped_list_cutoff_limit` to 400 if nil;
- stamps `auto_generated_kind: :year_top` + `auto_generated_year` on the primary list;
- stamps `auto_generated_kind: :year_honorable_mention` + `auto_generated_year` on the
  secondary list.

Idempotent, reports every adoption, and re-running no-ops. Configurations 5/6/7 and lists
746/747, 1041/1042, 1088/1089 land with no guessing.

**`dynamic_lists:regenerate[Type]`** — runs the generator across every year configuration of a
type and enqueues the main configuration's recalculation **once** at the end rather than per
year. The service takes a flag to suppress its own step 5 so the batch can coalesce.

## Expected effect on live books rankings

The year configurations had **zero** `ranked_items` before this work, because the books
migration has no ranked-items migrator — rankings are computed in the new app, and only the
main configuration had ever been refreshed. All three were calculated during design (890 /
1,214 / 904 items, 0.3–0.6s each) and produce credible results: *James* at #1 for 2024,
*Audition* for 2025, *The Heaven & Earth Grocery Store* for 2023.

Comparing the new engine's output against the legacy contents currently sitting in the six
lists:

| Year | Top 100 kept | Changed | Overflow legacy → new | Kept |
|---|---|---|---|---|
| 2025 | 85/100 | 15 | 790 → 400 | 385 |
| 2024 | 92/100 | 8 | 1,114 → 400 | 392 |
| 2023 | 77/100 | 23 | 723 → 400 | 313 |

2023 diverges most, consistent with its lower exponent (1.5) and thinnest source pool (30).

The material change is to the overflow lists: 2024 and 2023 go from **0 contributing items to
400 each** (their weight climbs from 0 to roughly 30 once `voter_count_unknown` is false and
`high_quality_source` true), while 2025 sheds its 390-item tail. Net, the books rankings gain
roughly 410 items of real signal and lose the ranks-501+ noise — books named on a single
obscure list. **This will visibly move the books top lists.** It is the intended outcome, not
a side effect.

## Testing

Minitest, fixtures, Mocha. Per project convention: 100% coverage of public methods, no private
method tests, controller tests assert behaviour only.

- **`CreateNextYearConfiguration`**: the union rule; `list_time_scope` excluded;
  `dynamic_type: num_years_covered` excluded regardless of category; a source year's tuned
  value beats main's; forced `apply_list_dates_penalty = false` on a first-year clone from
  main; year derivation with and without an existing year configuration.
- **`GenerateDynamicLists`**: both windows at the cutoffs; the secondary cap truncating;
  idempotency across repeated runs; every re-asserted field; penalties attached but no
  `PenaltyApplication` created; `RankedList` created on the main configuration; `name`,
  `description` and `status` untouched on a second run; guard failures return an error
  `Result` rather than raising.
- **The repair case explicitly**: a list seeded in the 747 shape
  (`voter_count_unknown: true, high_quality_source: false`) comes out corrected.
- **`GenerateDynamicListsJob`** and both admin actions: integration-level, status codes and
  effects.
- **Adoption task**: idempotency, year derived from `year_published`, and the 400 default.

Wiring assertions get verified by deleting the line under test and watching them go red —
`assert_empty`-style assertions have passed against deleted features in this codebase before.

Fixture names in this project are semantic, never `one`/`two`; existing `lists.yml` and
`ranking_configurations.yml` entries get checked before new ones are added. New fixtures needed:
a year configuration, and one list of each new generated kind.

**E2E** (Playwright, `web-app/e2e/tests/`): the admin flow end to end — create next year's
configuration, attach a list, generate, see both output lists. Per-domain spec layout gets
checked before placement, since E2E specs exist per domain and this is shared admin surface.

## Rollout

All development-only. Books data exists solely in development and the books site is not yet
live, so there is no production migration risk here. Games, albums and songs gain the
capability with no existing year configurations to adopt.

1. `dynamic_lists:adopt`, and read its report.
2. Verify the six lists carry the right kind and year, and that configurations 5/6/7 have
   `year` and both cutoffs.
3. Generate **2023 only**, then inspect the books top 100. Smallest change that exercises the
   whole pipeline against real data.
4. Then 2024 and 2025 individually, or `dynamic_lists:regenerate` for the batch with a single
   main-configuration recalculation at the end.

## Out of scope

- **A public per-year page.** The two generated lists already render publicly as lists.
- **A staleness warning in admin.** The enforced ordering inside the generator is the safety
  mechanism; a warning was considered and declined.
- **Automatic routing of incoming lists to a year configuration.** Attaching a list stays an
  editorial decision. No rule could reproduce it: 70 books lists carry `year_published = 2025`
  but only 43 belong to the 2025 cohort, `num_years_covered` is unset on every books list, and
  `yearly_award` is false on all 43.
- **Nightly regeneration.** Deliberately on-demand.
- **Cleaning up duplicate penalty records.** `Books::Penalty` 24 "List: honorable mention" and
  `Global::Penalty` 4 "List: is a follow up/honorable mention to a different list" encode the
  same concept, and "Voters: specific voter details are lacking" exists only on year
  configurations. Noted, not addressed here.
- **`ranking_configurations.list_limit`.** Declared, validated, rendered in admin, and read by
  no calculator. Pre-existing dead weight, untouched.
