# Books western-canon list penalty

Ports the legacy site's dynamic "this list is mostly Western canon" penalty
(`List#western_percentage` + `Book#is_western_canon?` + `Rankings::WeightCalculatorV4`) to the new
app's penalty model.

## Why

The legacy app penalises any list that *claims* to be global but turns out to be ≥90% Western,
exempting lists that declare a location focus up front. It is the one dynamic penalty from legacy
that never made it across, and it is the one that most changes the shape of the books rankings.

The migration already did almost all of the work. What is missing is only the calculation.

| Piece | Status |
| --- | --- |
| `Books::Penalty` #23 `List: only covers mostly "Western Canon" books` | exists, `dynamic_type: percentage_western` |
| Its `penalty_applications` on books RCs 5, 7 and 8 (primary), value `10` | exists |
| `Books::Country` with a `labels` array and a `with_label` scope | exists — 253 rows, 24 labelled `western` |
| `books_book_countries` | exists — 126,007 rows |
| `lists.location_specific` (the legacy exemption) | populated — 137 of 759 active books lists |
| A `percentage_western` branch in `Rankings::WeightCalculatorV1` | **missing — this spec** |

`Services::BooksMigration::PenaltyResolver` line 34 creates this penalty as a `Books::Penalty`
rather than reusing a global, because no global with that `dynamic_type` is seeded. So
`penalty_applications.value` already carries what legacy called `list_con.points`.

### The legacy→new mapping needs no work

Legacy attached `list_cons` to `ranked_lists` through `list_con_lists`, scoped to a
`ranking_configuration`. The new app attaches `penalties` to base `lists` through `list_penalties`.
That looks like a mapping problem, and it is not:

`ListPenalty` validates `penalty_must_be_static` — **dynamic penalties are never attached to lists
at all** in the new app. They are computed from the list at weight-calculation time and recorded in
`ranked_lists.calculated_weight_details`. Legacy instead materialised them: `WeightCalculatorV4`
writes `list_con_lists` join rows on every recalculation (`find_or_create_by` / `destroy_all`, per
list per run), and `ListsController#show` reads them back (`@ranked_list.list_cons.order(points:
:desc)`) to render a penalty breakdown on the public list page. The new app replaces the
materialised rows with the jsonb audit trail. So there is nothing to migrate: `percentage_western`
joins the five dynamic types already computed this way.

One consequence worth stating plainly: the new app has **no public penalty breakdown for books**.
(`Lists::SimplePenaltySummaryComponent` does render one, but only on the music album and song list
show pages -- `app/views/music/albums/lists/show.html.erb` and
`app/views/music/songs/lists/show.html.erb`; books' `app/views/books/lists/show.html.erb` has no
equivalent.) That gap is pre-existing and applies equally to the five dynamic types already
implemented for books, so this spec neither creates nor fixes it.

## Scope

**In:** `Books::List#percentage_western`, a `nil` base on `::List`, the `WeightCalculatorV1` branch,
Minitest coverage, fixtures.

**Out:** any admin or public UI. The new app records the computed percentage in
`calculated_weight_details` for every list that trips the penalty, which covers the audit need.
Also out: running the recalculation (see Rollout).

**Explicitly not built:** a denormalised `lists.percentage_western` column. Legacy *has* such a
column and **nothing ever writes it**. `List#western_percentage` computes live and never persists
the result; `ListsController` selects the column; and `admin/lists/show.html.erb` renders a "Western
Percentage" row behind `if @list.percentage_western.present?`, which is therefore always false. The
column, a maintenance job and its invalidation triggers would all be dead weight; see Performance
below for the measurement that makes computing live the right call.

## Design

### 1. The percentage lives on the list

```ruby
# app/models/list.rb
# Only books carry country-of-origin data, so every other media type answers
# nil and the weight calculator skips the western-canon penalty.
def percentage_western
  nil
end
```

```ruby
# app/models/books/list.rb
# Percentage of the list's books whose country of origin carries the "western"
# label, 0.0-100.0. nil when the list has no resolved book items -- an empty
# list cannot be western-biased.
def percentage_western
  items = list_items.where(listable_type: "Books::Book").where.not(listable_id: nil)
  total = items.count
  return nil if total.zero?

  western_book_ids = Books::BookCountry
    .joins(:country)
    .merge(Books::Country.with_label("western"))
    .select(:book_id)

  ((items.where(listable_id: western_book_ids).count.to_f / total) * 100).round(2)
end
```

**Why the base method on `::List` is load-bearing, not defensive.** `test/fixtures/penalties.yml`
already gives `Movies::Penalty` and `Music::Penalty` a `dynamic_type: 1` (`percentage_western`).
Without the nil base, a movies ranking configuration with that penalty applied raises
`NoMethodError` on a `Movies::List`. It also keeps every `Books::` constant out of `Rankings::`,
sidestepping the nested-namespace shadowing that has bitten this codebase repeatedly.

**Why the explicit `listable_type` filter** when `ListItem#listable_type_compatible_with_list_type`
already restricts a `Books::List` to `Books::Book` items: validations do not constrain rows written
by importers or migrations, and the filter lets the query use
`index_list_items_on_listable`. `where.not(listable_id: nil)` excludes unresolved items — legacy's
`list.books` join excluded them implicitly. (Dev currently has zero such rows for books lists.)

Books with no country row at all count toward the denominator as non-western, matching legacy's
`Book#is_western_canon?`, which returns false for them. Measured against the real development
database (`bin/rails runner`, read-only): 300 of 126,303 books have no country row at all, and a
further 34,124 have a country row but it is only the `Unknown` demonym (`Books::Country` slug
`unknown`, `labels: []`) -- also non-western under `is_western_canon?`. Combined, 34,424 books
(27.26% of all books) carry no usable recorded origin.

**What the rule actually means in practice:** "at least 90% of the books whose origin is
*recorded*" -- not 90% of the list. Because roughly a quarter of all books have no usable origin,
backfilling country data for previously-unknown books can push a list across the hard 10-point
cliff at 90% with no deploy behind it; the percentage moves purely from data entry.

### 2. The calculator branch

`Rankings::WeightCalculatorV1` gains a threshold constant and one private method, called from
`calculate_bias_penalties_with_details` alongside the existing `category_specific` and
`location_specific` blocks — it is the same kind of bias penalty.

```ruby
PERCENTAGE_WESTERN_THRESHOLD = 90.0

# Lists that declare a location focus up front ("30 Best Australian Books") are
# exempt: their western tilt is the stated premise, not unexamined bias.
def calculate_percentage_western_penalty_with_details(details)
  return 0 if list.location_specific?

  penalty_value, penalty_info = find_penalty_details_by_dynamic_type(:percentage_western)
  return 0 unless penalty_value > 0

  percentage = list.percentage_western
  return 0 if percentage.nil? || percentage < PERCENTAGE_WESTERN_THRESHOLD

  details["penalties"] << penalty_info.merge(
    "source" => "dynamic_attribute",
    "dynamic_type" => "percentage_western",
    "attribute_value" => percentage,
    "value" => penalty_value
  )
  penalty_value
end
```

**A hard cliff, not a taper.** Below 90% nothing, at 90% or above the full `penalty_application.value`
(10 on the primary configuration). This is what legacy does and what the legacy site publicly
documents on its rankings-explainer page, so the behaviour stays explainable. A power curve — the
shape `number_of_voters` and `num_years_covered` use — was considered and rejected as a separate
product decision, not a migration concern.

**The threshold is a constant, not a column.** `ranking_configurations` has precedent for tunable
penalty parameters (`max_list_dates_penalty_age`, `max_list_dates_penalty_percentage`), but legacy
hardcoded 90.0 and nothing suggests wanting to vary it per configuration. Promoting it to a column
later is additive and non-breaking.

**The check order is deliberate.** `location_specific?` is a boolean already in memory;
`find_penalty_details_by_dynamic_type` is a query but one the sibling branches already make per
list; `percentage_western` is the only expensive step and runs last. Because that lookup returns
`0` when the configuration has no such penalty, music, games and movies runs never call
`percentage_western` at all.

**`attribute_value` records the real percentage** (`94.68`), where the sibling boolean branches
record `true`. `calculated_weight_details` then explains *why* a list was penalised — the audit
trail legacy bought by writing `list_con_lists` rows.

### Performance

Measured against the real development database (126,007 country links, 759 active books lists):

- One `percentage_western` call: **2.69 ms** (two indexed counts), so a full
  `BulkWeightCalculator` run over every active books list grows by roughly **2 seconds**.
- For comparison, legacy's implementation loads every book record on the list with
  `books.includes(:countries)` and counts in Ruby.

Two seconds on a job that already rewrites every ranked list does not justify a denormalised column,
a refresh job, and invalidation on both list-item and book-country writes.

## Testing

### `Books::List#percentage_western` — `test/models/books/list_test.rb`

- all book items western → `100.0`
- mixed → correct value, rounded to two places
- a book with no country row → counted as non-western
- list with no items → `nil`
- items with `listable_id: nil` excluded from both numerator and denominator

### `::List#percentage_western` — `test/models/list_test.rb`

- a non-books list answers `nil`

### `Rankings::WeightCalculatorV1` — `test/lib/rankings/weight_calculator_v1_test.rb`

- ≥90% western, penalty applied to the configuration → value added to the total, and
  `calculated_weight_details["penalties"]` contains an entry with `"dynamic_type" =>
  "percentage_western"` and `"attribute_value"` equal to the real percentage
- <90% → contributes 0, no details entry
- ≥90% **and** `location_specific` → contributes 0 (the exemption)
- exactly 90.0 → penalised (boundary is inclusive)
- configuration has no `percentage_western` penalty → contributes 0
- list with no items → contributes 0

### Fixtures

`test/fixtures/books/countries.yml` already has `french` (`labels: [western]`) and `japanese`
(`labels: [asian]`). `test/fixtures/lists.yml` has `books_list` but `test/fixtures/list_items.yml`
gives it a single item, so the suite needs a books list with a mix of western and non-western book
items, plus a `location_specific` variant.

### Verifying the tests actually test something

Every assertion above is confirmed by breaking the code it guards and watching it go red, not by a
green run — specifically:

- delete the `return 0 if list.location_specific?` line → the exemption test must fail
- change `<` to `<=` in the threshold comparison → the boundary test must fail
- return a fixed `0.0` from `Books::List#percentage_western` → the ≥90% test must fail

This codebase has twice shipped tests that passed against deleted or broken branches
(vacuous Capybara substring matches; sort tests resolving on fixture id order). A green suite is not
evidence on its own.

### Gate

`bin/rails test` and `bundle exec standardrb`. No new user-facing page, so no Playwright test and no
system test.

## Rollout

Out of scope for the implementation, recorded so it is not lost.

**Before deploy — verify production state.** Penalty #23 and its applications on books ranking
configurations 5, 7 and 8 were confirmed in *development* only. If the application row is missing in
production the calculator is a silent no-op:

```ruby
p = Penalty.find_by(dynamic_type: :percentage_western, type: "Books::Penalty")
p&.penalty_applications&.pluck(:ranking_configuration_id, :value)
# expect the primary books configuration present with value 10
```

**After deploy — nothing recalculates on its own.** Weights change only when
`BulkCalculateWeightsJob` runs for the books ranking configurations, followed by
`CalculateRankingsJob`.

**The recalculation's blast radius is wider than just weights.** `CalculateRankingsJob`
(`app/sidekiq/calculate_rankings_job.rb`) chains `Books::CalculateAuthorRankingsJob` on success for
every books configuration, and additionally `Books::ReindexRankedFieldsJob` when the configuration
is the default primary one. So the Greatest Authors rankings and the OpenSearch ranked fields both
rebuild off the back of this change too. That needs no extra manual step -- it happens automatically
-- but it's worth stating so a change on the authors page after this rollout isn't mistaken for a
separate bug.

**The reorder is not immediately publicly visible.** `Books::RankedItemsController` includes
`Cacheable` and calls `cache_for_index_page` on `index`, which sets
`expires_in 6.hours, public: true, stale_while_revalidate: 1.hour`
(`app/controllers/concerns/cacheable.rb`). Cloudflare's edge cache can therefore keep serving the
pre-recalculation order for up to roughly 7 hours after the jobs finish, unless the cache is
purged.

**Expected impact on the primary books configuration** (measured, development data):

| | lists |
| --- | --- |
| active books lists with items | 759 |
| ≥90% western | 373 |
| of those, `location_specific` and therefore exempt | 65 |
| **penalised** | **308** |

Each penalised list loses 10 points of weight before other penalties, so the public books rankings
will shift visibly -- once the edge cache above has expired or been purged.

**One result will look wrong at a glance.** *Harold Bloom's The Western Canon* (91.32%) is
penalised, because it is a canon list rather than a location-flagged one, and legacy penalises it
for the same reason. Largest other hits: *1000 Novels Everyone Must Read* (94.68%, 997 items),
*1,000 Books to Read Before You Die* (94.32%, 969 items), *Fantasy and Horror: A Critical and
Historical Guide* (97.65%, 722 items).
