# Rankings explainer page

**Date:** 2026-08-29
**Status:** Approved, ready for an implementation plan
**Branch:** `worktree-books-rankings-page`

## Problem

The legacy books site has `/rankings` (`app/views/default/rankings.html.erb` in
`the-greatest-books/admin`). It opens with three short paragraphs and then dumps every
penalty as a bare `name: -points` list. It explains nothing about how weight is
actually computed, never mentions how an individual book scores, and its "ideal weight
of 150" prose does not match this app, where weight starts at 100.

This app has `/rankings` for music and games and **nothing for books**.
`FooterComponent#site_links` carries an explicit exception for it:

```ruby
# "Ranking Details" is deliberately absent for books: music and games each
# define a /rankings page and books does not, so listing it there would link
# every books page to a 404.
```

The music and games pages are near-verbatim copies of each other and share two defects:

1. **They describe the date penalty backwards.** Both say "when an item was released
   long before the list was published, we gradually reduce how much that list-placement
   counts... so a classic album doesn't get unfairly penalized." `ItemRankings::DatePenalty`
   does the opposite — an item published the *same year* as the list takes the maximum
   penalty, decaying to zero once the item is `max_age` years older than the list.
   Classics take **no** penalty; that is the entire point of the feature. The legacy
   books page describes it correctly, so this is a regression introduced when the
   music/games copy was written.
2. **They list penalties by bare name**, the same failure as the legacy page.

Neither page says the single most explanatory thing about the system: that placement
*on* a list is worth far more than position *within* it.

## Goals

A page that gives a casual visitor a short, honest summary of how the site works and
why the result is trustworthy, then gives an interested reader the full mechanism. It
must answer the site's most common piece of user mail — "this is too western focused" —
with numbers rather than deflection. One implementation serves books, music and games.

## Measurements (dev, 2026-08-29)

Dev weights were stale before this work: the books configuration had not had
`CalculateWeights` run since 2026-07-23, and the western-canon penalty was attached
on 2026-05-16 but applying to **zero of 623 lists**. Recalculating changed 249 list
weights and brought the penalty onto 303 lists. Books rankings and author rankings were
then refreshed. Music and games weights were already current. All numbers below are
post-recalculation.

### Configurations

| | exponent | bonus pool | date penalty | median voters | lists | ranked items | penalties |
|---|---|---|---|---|---|---|---|
| Books | 3.0 | 3.0 | 80% / 50yr | 24 | 623 | 21,390 | 41 |
| Music albums | 4.0 | 4.0 | 50% / 30yr | 20 | 37 | 3,905 | 17 |
| Music songs | 4.0 | 4.0 | 50% / 30yr | 17 | 20 | 5,084 | 17 |
| Games | 5.0 | 4.0 | 35% / 20yr | 11 | 19 | 1,484 | 15 |

Books authors is a fifth configuration (13,653 ranked authors) with no ranked lists and
its own score formula. It is out of scope for this page.

### Penalties

49 penalties exist; 47 are attached to a default primary configuration. **None are
user-specific.** By STI type: `Global::Penalty` 18, `Books::Penalty` 27,
`Music::Penalty` 1, `Games::Penalty` 1 — so music and games each contribute exactly one
domain-specific penalty and the rest are shared. This is why one shared implementation
carries nearly all the value.

Description quality is poor: of the 47, only **22** have real text, **18** carry
auto-generated filler of the form `"System-wide penalty: <name>"`, and **7** are blank.

Books lists average 3.3 penalties each. The most common: voters mostly from one country
(321 lists), voter count below median (320), western canon (303), unknown voter names
(204). Only 7% of books lists are flagged `high_quality_source`.

### Position barely matters

With the books defaults (exponent 3.0, bonus pool 3.0, median list length 50), being on
a list is worth the list's full weight and position adds at most ~24% on top:

| list length | #1 | middle | last | top/bottom |
|---|---|---|---|---|
| 10 | 119.8 | 104.3 | 100.0 | 1.20x |
| 50 | 123.1 | 103.2 | 100.0 | 1.23x |
| 100 | 123.5 | 103.1 | 100.0 | 1.24x |
| 500 | 123.9 | 103.0 | 100.0 | 1.24x |

(list weight 100). The ratio is ~1.24x at every length. Consensus across lists dominates
by design, and nothing on the site currently says so.

### Western tilt

| | western share |
|---|---|
| Median source list | 92% |
| Top 50 books | 92% |
| **Top 100 books** | **94%** |
| Top 250 books | 96% |
| Top 1000 books | 90% |
| Global Canon (150 books, max 3/country) | **45%** |

The aggregate output is slightly *more* western than the median input. Weighting
redistributes influence among sources that overwhelmingly agree with each other, so it
cannot correct a tilt this uniform. `Books::GlobalCanonQuery` is what actually corrects
it, and it does so by re-selecting under a per-country cap — skipping 1,358 books to
fill 150 slots.

## Design

### Architecture

One shared engine, three thin callers.

**`Services::RankingConfiguration::ExplainerData`** — new, in the existing cross-domain
`app/lib/services/ranking_configuration/`. Takes one or more configurations, returns a
Result carrying config facts, penalties grouped by category, stat counts, and the worked
example. Every query lives here so N+1s are guarded in one place.

**`app/components/rankings/`** — one component per section, following the cross-domain
`app/components/lists/` precedent:

| Component | Renders |
|---|---|
| `Rankings::PageComponent` | Shell: summary, stats, section order |
| `Rankings::WeightExampleComponent` | The live worked example |
| `Rankings::PenaltyTableComponent` | Five category groups, prose + tables |
| `Rankings::ScoreCurveComponent` | Presence vs position |
| `Rankings::ConfigurationFactsComponent` | The configuration's real numbers |

**`Books::DefaultController#rankings`** — new controller (books has none),
`layout "books/application"`, `cache_for_index_page` like its siblings.
`Music::DefaultController#rankings` and `Games::DefaultController#rankings` shrink to
picking configurations and delegating.

**Routes** — `get "rankings"` in the books constraint block, as `:books_rankings`.

**Footer** — `FooterComponent#rankings_path` gains the books branch; the exception
comment above `site_links` goes away.

Fixing the copy once fixes it for all three domains: the inverted date-penalty paragraph
cannot survive because there is only one copy of it afterward.

### Penalty categories

New nullable enum `category` on `penalties`, exposed in the admin form, backfilled for
all 49 rows.

| Category | Books | Covers |
|---|---|---|
| `voter_expertise` | 7 | Who voted — critics vs public, diversity, declared bias |
| `voter_participation` | 3 | How many voted and what is known about them |
| `list_time_scope` | 7 | "Only covers 10 years" and its siblings |
| `list_subject_scope` | 16 | One country, genre, gender, language |
| `list_integrity` | 8 | Undocumented, aggregated, creator sells the books |

Nullable on purpose. An uncategorized penalty renders under a visible "Other" heading
rather than silently vanishing from the page — the failure mode must be visible, not
silent.

### Penalty descriptions

All 49 rewritten as plain sentences that read well to a visitor **and** still help pick
the right penalty in admin. One text serving both audiences; no second column.

Canonical text lives in an idempotent rake task checked into the repo, keyed by penalty
id, so the copy is reviewable in the PR and the same task runs against production.

### Content

Sections run flat down the page rather than behind expanders — this is a transparency
page and hiding its content undercuts it. Only the 49-row reference table is collapsed,
per category, in a native `<details>`.

**1. Summary.** What we do, why lists are not counted equally, and the consequence: a
book many good lists agree on beats a book that tops one list. Three live stat tiles.

**2. Why we think this is accurate.** Consensus over authority; every list's weight is
public; both repositories are open source; we actively correct known biases.

**3. Why the list still skews western.** High on the page, not buried. States the 94%
figure first, then: the median list we ingest is 92% western; the three structural
reasons carried over from the legacy `new_rankings.html.erb` (one-way translation flows,
anglophone markets under-translating, canon inertia); what we do (303 of 623 lists carry
the penalty, regional lists exempt because their focus is declared honestly); why that is
not enough, said plainly; and Global Canon at 45% western, framed as the answer rather
than a side feature, with the regional collections alongside. Closes with an ask for
high-participation non-western lists.

**4. How a list earns its weight.** Starts at 100; penalties subtract percentage points;
high-quality sources get their total cut by a third (only 7% of books lists qualify);
floor at the configured minimum. Live worked example.

**5. What we penalize.** Five groups, prose plus 2-3 examples each, then the collapsed
full table: name, description, value.

**6. How a book earns its score.** Presence is worth the list's full weight; position
adds at most ~24%, with the table above. The best available answer to "why isn't my
favourite #1".

**7. Correcting for recency.** Stated correctly: same year as the list takes the full
80% cut, decaying to zero at 50 years; yearly awards always take the maximum.

**8. Automatic adjustments.** Voter-count curve, unknown voter count, western tilt.

**9. The current configuration.** A facts table of real numbers.

**10. Open source and contributing.** Both repositories, Discord, contact.

### Worked example

Hand-picked list id per domain so the surrounding prose can name real numbers, with a
fallback to the highest-weight active list if that list is ever archived or deleted. The
page must not be able to break because of a data change.

`min_list_weight` on the books configuration is `-50` and is **inert** — total penalty is
capped at 100%, so weight floors at 0 and -50 is unreachable. The page states the floor
as 0. The column is left alone.

## Testing

- Controller test per domain: status, assigns, no errors. Behavior only, no copy assertions.
- Component test per component.
- Service test: grouping, uncategorized fallback, worked-example fallback when the
  pinned list is gone.
- `assert_queries_count` guard on the page.
- Model test for the `category` enum.
- Rake task test: idempotent, and re-running does not duplicate or clobber.
- Playwright E2E for the new books page.
- `bin/rails test` and `bundle exec standardrb`. The existing daisyUI v4 lint covers classes.

## Out of scope

- **Making the western penalty proportional.** `percentage_western` is the only dynamic
  penalty that is a binary cliff — 89% western pays nothing, 90% pays the full 10% —
  where voter count and years-covered both use a squared curve that scales with
  severity. Making it proportional would be consistent with the rest of the system and
  would bite harder where it should, but it is an algorithm change with a ranking shift
  behind it. Spec separately.
- **A page listing archived ranking configurations.** The legacy page links to one; this
  app has no equivalent and it is deliberately skipped.
- Books authors ranking configuration.
- Per-list weight breakdowns on books and games list pages (music already has them).

## Rollout

1. Migration adding `penalties.category`.
2. Rake task: backfill categories and rewrite all 49 descriptions. Run on dev, then production.
3. Deploy.

**Open question for production:** dev weights were stale by two months and the western
penalty was applying to nothing. Whether production is in the same state is unverified
from here. If it is, running `CalculateWeights` plus a ranking refresh in production will
move the public rankings — a visible change that should be deliberate and probably
announced, not a side effect of shipping this page.

**Verify persistence, do not trust the success message.** Books' `ranked_lists.weight`
had drifted to roughly **2x** the value the algorithm computes — legacy-scale weights
written by the books migration in May 2026 and never recalculated. While clearing it,
one `Services::RankingConfiguration::CalculateWeights` run returned
`{success: true, message: "...249 ranked lists..."}` while rows kept their old `weight`
and their May `updated_at`; a second, identical run persisted 620 rows correctly. The
mechanism was not identified and is not reproduced here. Music and games show zero drift
(0 of 38, 0 of 21, 0 of 20 rows disagreeing), consistent with the cause being migration
scale rather than a live calculator fault.

The operational rule that follows: after running weight calculation anywhere that
matters, **assert that `ranked_lists.weight` equals
`calculated_weight_details.final_calculation.final_weight`** before treating the run as
done, and re-run rankings only once that holds. A one-line check:

```ruby
rc.ranked_lists.count { |r| r.calculated_weight_details.to_h.dig("final_calculation", "final_weight") != r.weight }
# => must be 0
```
