# Open Library Data Service

A read-only backend book-data source built from Open Library's monthly dumps.
Lives in `data-sources/` at the project root, **not** inside `web-app/`.

Design: `docs/superpowers/specs/2026-09-01-open-library-data-service-design.md`
Plan: `docs/superpowers/plans/2026-09-01-open-library-data-service.md`

## What it is

Six dumps are distilled into ten Parquet tables, queried by DuckDB, and served by
a small FastAPI process. It never writes to Rails, holds nothing that is not
rebuildable from a dump, and is never on a public request path.

## Building an artifact

    cd data-sources
    uv sync --locked
    uv run python -m openlibrary.pipeline.build --root /home/shane/ol-data --memory-limit 16GB

Downloads six dumps (all must resolve to the same date), distills, derives,
validates and reports. A failed gate leaves the previous version live.

## Measured build, 2026-07-31

The first full build against real dumps. All ten tables produced, every gate passed.

| Table | Rows | Size |
|---|---:|---:|
| editions | 56,615,822 | 3.14 GB |
| works | 41,504,065 | 2.53 GB |
| identifiers | 120,498,957 | 1.86 GB |
| work_details | 22,448,953 | 0.91 GB |
| authors | 15,380,614 | 0.43 GB |
| author_names | 15,692,571 | 0.42 GB |
| work_authors | 44,739,141 | 0.36 GB |
| year_evidence | 41,372,692 | 0.34 GB |
| popularity | 41,406,604 | 0.22 GB |
| redirects | 1,790,272 | 0.016 GB |

Total artifact size: **10.23 GB** (10,234,375,552 bytes)
Total build time: **~497 s** (~8.3 minutes), dominated by `editions_staging` at 201 s
(the single-threaded 12.5 GB gzip scan)

The design estimated 5-8 GB. The measured artifact is 10.23 GB -- larger than
estimated, and dominated by exactly the two tables the design predicted would
dominate: `editions` (3.14 GB) and `identifiers` (1.86 GB, 120M rows against
an estimated ~100M). This is a measurement, not a shortfall: Parquet size was
always a measured output of the real dump, never a design assumption, and the
estimate undercounted `editions`' width.

### `identifiers` is distinct on the whole row

One edition asserting one identifier is one piece of evidence, however many of
its fields said so. The first build did not enforce that: `isbn_any` unions an
edition's `isbn_10` and `isbn_13` lists and every branch converts each raw
value to BOTH canonical forms, so an edition carrying equivalent ISBN-10 and
ISBN-13 emitted each canonical form twice; separately, an ASIN present in both
`identifiers.amazon` and an `amazon:` `source_records` entry emitted twice.

Measured on 2026-07-31: **145,964,239 rows against 120,498,957 distinct --
25,465,282 duplicates, 17.4% of the table** (isbn10 12,510,971, isbn13
12,510,930, asin 439,839, lccn 1,753, oclc 1,654, goodreads 135). Distinct on
all five columns equals distinct on `(id_type, value, edition_key, work_key)`,
so `checksum_ok` never disagrees within a grain and no aggregation choice is
needed. A `SELECT DISTINCT` over the union now enforces it, costing ~8 s of the
editions stage and 0.17 GB less on disk.

The table is still deliberately **not** unique on `value`: after the fix,
1,138,510 ISBN-13 values remain attached to more than one work. That ambiguity
is the point of an evidence table, and a caller is meant to see it.

Sanity against the design's published figures: `works` 41,504,065 and
`authors` 15,380,614 match exactly. `work_authors` came in at 44,739,141
against a published 44,739,082 -- a difference of 59, noted and not chased.

### Gate results

| Gate | Status | Detail |
|---|---|---|
| row_counts | pass | all tables within tolerance |
| field_coverage | pass | coverage within tolerance |
| redirect_closure | pass | 1,790,272 redirects, 26 cycles, 3,356 dangling |
| canary_lookups | pass | all canaries resolve |
| evaluation_set | pass | no regression on the labeled set (prepared cache, 0.6s) |

`evaluation_set` (Task 28) runs the harness against the 448-case labeled set
and fails the build if any of five metrics regresses past the bound pinned in
`openlibrary/eval/thresholds.json` -- recall@10, false-merge rate,
precision@accept, abstention rate, correct-no-match rate, each with headroom
below (or above) the value measured on the final calibrated run, recorded
alongside it as `thresholds.json`'s `measured` sibling. It skips instead of
failing when there is nothing to check against: no labeled cases, no pinned
thresholds, or -- against an artifact whose labeled works are mostly absent
from it, such as the test suite's fixture corpus -- "not the labelled dump".
Evaluating costs ~4.5s/case with no prepared cache available (~31 minutes for
the full 448-case set) and well under a second with one, which is what the
0.6s above reflects; `run_gates` never supplies a cache path explicitly, so a
real build pays the full cost unless a prepared-cache file already sits at
the conventional path under the artifact's `tmp/` directory.

Only `work` and `author` redirects are resolved against a table, and only they
can be `is_dangling = true`: 2,573 of 1,128,948 work redirects and 783 of
545,334 author ones. For the 115,990 `edition` and `other` redirects nothing
checks the target, so `is_dangling` is NULL rather than `false` -- claiming
they resolve would be an assertion nobody made. (25 of those 115,990 are
`false` rather than NULL because they are cycles, which have no terminal to
dangle.)

**An in-place rebuild has no row-count safety net.** `load_previous_report`
only reads version directories strictly *earlier* than the one being built, so
rebuilding an existing dump date finds no previous report and `row_counts`
compares against nothing. The `identifiers` deduplication below dropped that
table by 17.4% and the gate passed without comment. That is correct for a first
build of a date; it is worth knowing before treating a green in-place rebuild
as evidence that nothing moved.

### The fixture corpus carries a negative class on purpose

`data-sources/tests/fixtures/` is a 683-line, 433 KB sample of the real dumps,
regenerated by `extract_fixtures.py`. A sample of real data is almost all happy
path, and this one was: a mutation sweep found whole categories of test that
could not fail, all from one cause. The corpus contained **0** works sharing a
title fingerprint, **0** ISBNs failing their check digit, **0** ISBNs attached
to two works, **0** work-entity dangling redirects, **0** non-Latin-*script*
titles, and **0** works with a declared year but no editions -- so the
`checksum_ok` column, blocking rule 4's frequency guard, the `field_coverage`
gate and the whole of `assign_strata` had nothing that could fail against them.
Only 4 of the 12 evaluation strata were reachable.

Nine real works are now seeded by key for the exact property each supplies
(`NEGATIVE_CLASS_WORKS`), two edition predicates select real wrong check
digits, one real dangling work redirect is carried explicitly, and a marked
synthetic block of 51 works shares one title so `title_fp_freq` can exceed
`MAX_TITLE_FP_FREQ`. `test_fixture_corpus.py` asserts each class is still
present: **when one of those fails after a regeneration, restore the row --
deleting the assertion silently returns the guard above it to being
untestable.**

Two things the corpus cannot show, both left as they are. A title in one
non-Latin script alone fingerprints to the empty string, so `degenerate_title`
claims it before `non_latin_title` ever sees it -- all 30 `non_latin_title`
cases in the 450-case pool are mixed-script. And synthetic keys must stay clear
of real key space: the highest real work key in the dump is `OL45845863W`, so
anything with eight or fewer digits can collide, and the first attempt at the
synthetic block did, quietly attaching 52 real editions to works that should
have had none.

### The books export leaves out Playwright's leftovers

`Books::OpenLibrary::EvalExport` feeds the evaluation pool with every
`Books::Book`, and the development database is not only real books. Every admin
E2E spec titles its fixture with a trailing `${Date.now()}` -- `E2E Smoke Book
1784091457158`, `Tag Book 1785655579265` -- and nothing cleans them up, so
**126** of them had accumulated. None carries a single identifier, 97 have no
author, and they were eligible for every stratum in the pool: one draw put
**20 of the 450** hand-labelling cases on them, 19 in `author_less_work` alone.

The filter keys on the epoch-millisecond stamp rather than the per-spec title
prefixes, because the stamp is what every spec has in common and a new spec
with a new prefix would walk straight past a prefix list. Measured against the
development database: it matches 126 rows -- exactly the same 126 the prefix
list matches -- and no genuine book. The export went 126,330 -> 126,204, and
`rake open_library:export_books` now prints what it skipped, because a filter
that quietly starts matching real books is the failure worth catching.

This is a filter, not a cleanup: the rows are still in the development
database. Deleting them is a separate decision, and the dev database is not
disposable.

### Known weaknesses, measured at scale

- **Year regex took the first digit run -- fixed.** `work_details.declared_year`
  was extracted from free-text `first_publish_date_raw` with a first-digit-run
  regex, so a value like `"December 31, 1991"` yielded `31`, not `1991`.
  Measured at the time: **241,714 of 22,448,953** `work_details` rows (1.1%)
  carried a `declared_year < 1000` as a result. The regex was replaced with a
  pattern that matches a four-digit run (or a negative one-to-four-digit run,
  for ancient/BCE works) instead of the first digit run of any length, so a
  spelled-out date's day no longer wins over its year. Rebuilding the
  2026-07-31 artifact with the fix dropped the count to **87** (a 99.96%
  reduction); all gates still pass. A residual is accepted, not fixed: a
  hyphen used as a date separator (`"12-12-2008"`, `"OCTOBER-2008"`) still
  reads as a negative sign, since the regex engine has no lookaround to tell
  it apart from a genuine negative (BCE) year -- measured at 7 rows out of
  ~4.4M dated rows.
- **Editions pointing at a work that no longer exists in `works`.** `year_evidence`
  is anchored on `works`, so an edition whose `work_key` was merged or redirected
  away never contributes its year to the surviving work. **4,516 editions**
  (out of 56.6M) have a `work_key` absent from `works`; of the **444** distinct
  orphaned work keys involved, **361 (81%)** are found as a `source_key` in
  `redirects` -- meaning most of these are real merges whose edition-year evidence
  is silently lost, not just dangling references to keys OL deleted outright.

Everything else is left for Task 40.

## Matcher, measured

Task 27 calibrated the matcher's weight vector against the 448-case labelled set (`data-sources/src/openlibrary/eval/cases/`) and, separately, made one bounded attempt to have Splink do that instead. Four readings, same 448 cases, same real 2026-07-31 artifact:

| Reading | recall@5 | recall@10 | recall@50 | precision@accept | FALSE MERGE | false reject | abstention | correct no-match |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Equal weights, primary author names only (Task 26) | 0.895 | 0.927 | 0.951 | 0.843 | 0.1572 | -- | 0.596 | 0.179 |
| 2. Equal weights, alternate names (Task 26b) | 0.897 | 0.930 | 0.949 | 0.868 | 0.1322 | -- | 0.576 | 0.149 |
| 3. Calibration v1 (original objective) | 0.903 | 0.932 | 0.949 | 0.966 | 0.0345 | *(not measured; see below)* | 0.094 | 0.955 |
| 4. Calibration, final (amended objective) | 0.886 | 0.922 | 0.943 | 0.980 | 0.0201 | 0.0027 | 0.643 | 0.134 |

`recall misses (positives)` is **16 of 370 in all four rows**, unchanged -- it is a property of blocking, never of weights (see the R45/R46 invariant in Task 26b). Readings 1 and 2 predate `false_reject_rate` (added in reading 4's fix round); reading 3's held-out-split value, computed retroactively against the same code, is in the TEST table below.

Reading 3 looks like the best row on every column it reports -- precision 0.966, false merge 0.0345, abstention *down* to 0.094 -- and that is exactly the trap: it bought that abstention rate by silently converting true matches into rejects, which reading 3's own objective could not see. Reading 4 is the one actually shipped (`weights.json` carries it, `calibrated: true`).

### Baseline 2, by stratum (equal weights, alternate names)

```
anthology_or_collection    n=30   correct=4    false_merges=1    recall_miss=0
author_less_work           n=19   correct=7    false_merges=5    recall_miss=0
degenerate_title           n=20   correct=6    false_merges=1    recall_miss=3
easy_baseline              n=60   correct=37   false_merges=0    recall_miss=0
high_frequency_title       n=40   correct=24   false_merges=2    recall_miss=0
isbn_reuse                 n=30   correct=9    false_merges=5    recall_miss=0
no_candidates              n=50   correct=5    false_merges=3    recall_miss=5
no_popularity_signal       n=30   correct=15   false_merges=0    recall_miss=0
non_latin_title            n=30   correct=2    false_merges=0    recall_miss=2
pseudonym_or_alt_name      n=29   correct=12   false_merges=1    recall_miss=2
shared_key_collision       n=80   correct=22   false_merges=5    recall_miss=4
stale_ol_key               n=30   correct=24   false_merges=0    recall_miss=0
```

### Final calibration, by stratum

```
anthology_or_collection    n=30   correct=7    false_merges=0    recall_miss=0
author_less_work           n=19   correct=11   false_merges=0    recall_miss=0
degenerate_title           n=20   correct=6    false_merges=1    recall_miss=3
easy_baseline              n=60   correct=38   false_merges=0    recall_miss=0
high_frequency_title       n=40   correct=27   false_merges=1    recall_miss=0
isbn_reuse                 n=30   correct=2    false_merges=0    recall_miss=0
no_candidates              n=50   correct=4    false_merges=0    recall_miss=5
no_popularity_signal       n=30   correct=11   false_merges=0    recall_miss=0
non_latin_title            n=30   correct=4    false_merges=0    recall_miss=2
pseudonym_or_alt_name      n=29   correct=13   false_merges=1    recall_miss=2
shared_key_collision       n=80   correct=21   false_merges=0    recall_miss=4
stale_ol_key               n=30   correct=21   false_merges=0    recall_miss=0
```

Every stratum's false-merge count is 0 or 1 (down from baseline 2's 0-5). The cost is `correct` falling in several strata that baseline 2 answered by getting lucky on volume rather than on identity evidence -- `isbn_reuse` (9 -> 2) and `shared_key_collision` (22 -> 21) most visibly. `isbn_reuse` is by construction a stratum where one ISBN points at more than one work: the calibrated weights would rather abstain on that ambiguity than guess, which is the design's stated preference (false merge cost 10x an abstention) working as intended, not a regression in what the matcher "knows".

### The split, the objective, and why it changed mid-task

**Split:** stratified, seed `20260901`, `train_fraction=0.6` -- 268 train / 180 test cases, every stratum split independently so no stratum is absent from either side (`calibrate.split_cases`).

**Objective** (`calibrate.objective`, higher is better, bounded in `(-inf, 1]`):

```
accept_rate = n_accepted / n_cases
if accept_rate < 0.3:                 # MIN_ACCEPT_RATE floor
    return -1.0 - (0.3 - accept_rate)  # a matcher that never accepts is worthless
return (
    precision_at_accept
    - 10.0 * false_merge_rate      # FALSE_MERGE_COST: the wrong answer, recorded as fact
    -  1.0 * false_reject_rate     # FALSE_REJECT_COST: a silent duplicate a later dedup must find
    -  1.0 * 0.1 * abstention_rate # ABSTENTION_COST, 0.1 effective: a human looks and decides
)
```

`FALSE_REJECT_COST` did not exist for the first calibration run. Without it, a `reject` on a true match was free -- indistinguishable, to the objective, from a correct rejection of a real no-match case. The 2000-step random search (correctly, given that reward) found the cheapest way to raise precision and lower both false-merge rate and *reported* abstention at once: push `reject_threshold` up until it sat 0.0005 below `accept_threshold` (0.8995 vs 0.9), collapsing the abstain band to a sliver. Every score that used to land in that band -- previously an abstention, flagged for review -- became a `reject`, indistinguishable from "not in Open Library" to any caller. Measured on the held-out split: **51.9% of true matches were rejected**, while the objective reported its best score yet. The full 448-case run confirmed it at scale: `isbn_reuse` correct fell 9 -> 4 and `shared_key_collision` 22 -> 15 against baseline 2, both from matches turned into silent rejects.

The fix (R53) added `false_reject_rate` to `Metrics` -- `evaluate` now counts, among cases the label calls `match`, how many the matcher decided `reject` -- and priced it into the objective at `FALSE_REJECT_COST = 1.0` (a false merge destroys data and is 10x worse; an abstention costs one review and is 10x cheaper again). A second bug (R55) compounded the first while it was being fixed: the CLI's "baseline (all weights equal)" line, and the search's own starting point, both called `load_weights()` -- but `weights.json` is exactly the file this CLI overwrites on every run, so after the very first calibration it was reading back whatever the *previous* run had left there, not equal weights. The **second** calibration round (v2, below) was run with the amended objective but *before* this second bug was noticed or fixed: its "baseline" and its search's starting point were, unintentionally, round 1's collapsed-band file -- it inherited v1's weights by accident, through the `load_weights()` bug, not by any deliberate warm-start mechanism. `calibrate.equal_weights()` now builds the placeholder (all feature weights 1.0, `popularity_prior` 0.1, thresholds 0.9/0.4/0.05) in code, and both the baseline and the search's cold start use it; `--base PATH` (added alongside `equal_weights()`, so it did not exist for round 2) opts into starting from a specific file *in addition to*, never instead of, the equal-weights floor -- a search seeded from a weak `--base` file must still beat plain equal weights before anything gets written.

**TEST-split objective, across every round** (`min_accept_rate=0.3`):

| Weights | false_merge | false_reject | precision | abstain | objective |
|---|---:|---:|---:|---:|---:|
| `equal_weights()` | 0.0845 | 0.0128 | 0.915 | 0.561 | 0.0015 |
| v1 (original objective, no false-reject term) | 0.0500 | 0.5192 | 0.950 | 0.094 | -0.0787 |
| v2 (amended objective, accidentally inherited v1 via the `load_weights()` bug) | 0.0462 | 0.0128 | 0.954 | 0.583 | 0.4212 |
| final (amended objective, cold-started from `equal_weights()`) | **0.0328** | **0.0000** | **0.967** | 0.633 | **0.5760** |

v1's objective column is the amended formula applied *retroactively* to v1's actual weights, computed after the fact for comparison -- v1 itself was optimised against the original, false-reject-blind objective, under which it scored as the best result yet. That gap (a real result the old objective loved, that the new one prices at -0.0787) is the bug made numeric.

The final, cold-started run beats the warm-started one on every column, which is why it -- not v2 -- is what shipped: a clean start let the search settle somewhere the v1-corrupted starting point never fully recovered from. Its **training-split objective is 0.8054** against a **test-split objective of 0.5760** -- a real generalisation gap, expected and disclosed rather than hidden, from calibrating 9 feature weights and 3 thresholds on 268 labelled cases. The searched weights beat equal weights on the held-out split decisively (**0.5760 vs 0.0015**) once the objective actually priced every failure mode it can produce; `weights.json` carries the result (`calibrated: true`).

### Splink

Splink 4.0.16 (the `calibration` extra) is a record-linkage model: `Linker` takes one or two record dataframes that share raw column names and computes every declared `Comparison`'s match-level itself from `l.<col>` and `r.<col>`, both sides, unconditionally, before evaluating anything. The one concrete attempt made here -- a "books" frame of bare `unique_id`s, a "candidates" frame of `unique_id` plus the 9 `matcher.features.FEATURES` columns, an `ExactMatch` comparison per feature, and `linker.training.estimate_m_from_pairwise_labels` fed the training split's true-match pairs -- fails the same way every time it was tried (three calibration runs, identical error): a `SplinkException` wrapping a DuckDB `Binder Error: Table "l" does not have a column named "<feature>"`, because the "books" side, built from `PreparedCase`, carries no raw fields at all (only `case_id`) -- the 9 features are already pair-level comparison *outputs*, not an attribute either side of the pair owns on its own, so there is no column name Splink's generated SQL can select from both frames for any of them. This is a structural mismatch, not a fixable detail of the mapping tried: a real integration would need record-level book/work frames carrying raw fields (title, author names, year, identifiers, language) on both sides, a mapping from the 9 asymmetric features to Splink `Comparison`s defined over those raw fields (which would duplicate `matcher.features.extract`), m and u fitted on the ~269 labelled training pairs, and a translation of the resulting per-level match weights into the weighted-mean shape `scorer.score_features` expects. Splink never produced a fit to evaluate on this sample; it did not beat the random search because it never got the chance to compete.

### 4.5 seconds a case, and the prepared-cases cache

`harness.prepare` measured at ~4.5s/case across all 448 cases (33m25s on the first full run, 31m9s on a rebuild) -- almost entirely un-indexed Parquet scans in blocking rules 1-5 (`identifiers` alone is 120M rows, scanned fresh per case) plus roughly 1.5s of `load_work_views`. Weights never touch this: `prepare` runs it once, `evaluate` re-scores the result in pure Python in milliseconds, which is what makes a 2000-iteration search over 268 cases finish in minutes rather than the ~90 hours a naive per-iteration `prepare` would cost.

R54 adds a cache on top of that split: `write_prepared_cache`/`read_prepared_cache` (in `harness.py`) persist a `prepare()` result to a JSON file keyed by `dump_date`, `matcher_version`, and case count. Both CLIs take `--prepared-cache PATH`; the artifact-side copy used for this task lives at `/home/shane/ol-data/tmp/prepared-2026-07-31.json` (scratch space on the artifact host, **not** committed to the repo). The first run against a given path writes it (~31 minutes); every run after loads it in seconds. **Delete the file** after any change to blocking rules, `matcher.features`, or the labelled case set (`cases/*.jsonl`) -- the header check catches a changed dump date, a bumped `MATCHER_VERSION`, or a different case count, but a change to blocking or scoring logic that leaves all three unchanged would otherwise serve stale prepared candidates silently.

### Increment 3 is complete

All four of the increment's stated completion criteria hold: the harness
reports all five metrics (recall@5/10/50, precision@accept, false-merge,
false-reject, abstention, correct-no-match) against the real 2026-07-31
artifact and the real 448-case labeled set (see "Matcher, measured" above);
`weights.json` says whether it is calibrated and by which method
(`calibrated: true`, `calibrated_at` timestamped, the method documented under
"The split, the objective, and why it changed mid-task"); `thresholds.json`
records the measured numbers from the final calibrated run rather than
aspirations, each with a `measured` sibling recorded beside it; and the build
now fails its evaluation gate if the matcher regresses past any of those
thresholds (Task 28, `evaluation_gate` in `pipeline/gates.py`) -- verified
against the real artifact above, where it reports `pass`.
