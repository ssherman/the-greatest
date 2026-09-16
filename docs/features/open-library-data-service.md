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
| evaluation_set | pass | no regression on the labeled set (prepared cache, 0.5s) |

`evaluation_set` (Task 28) runs the harness against the 448-case labeled set
and fails the build if any of six metrics regresses past the bound pinned in
`openlibrary/eval/thresholds.json` -- recall@10, false-merge rate,
precision@accept, abstention rate, correct-no-match rate, and false-reject
rate -- each with headroom below (or above) the value measured on the final
calibrated run, recorded alongside it as `thresholds.json`'s `measured`
sibling; all six checks live in one table, `harness.THRESHOLD_CHECKS`, shared
by the gate and by `tests/openlibrary/test_eval_regression.py`, so a
threshold pinned in the JSON without a matching entry there fails a test
rather than going unenforced. It skips instead of
failing when there is nothing to check against: no labeled cases, no pinned
thresholds, or -- against an artifact whose labeled works are mostly absent
from it, such as the test suite's fixture corpus -- "not the labelled dump".
Evaluating costs ~4.5s/case with no prepared cache (~31 minutes for the
full 448-case set) and well under a second with one, which is what the
timing above reflects -- that row was produced by calling `evaluation_gate`
directly with an explicit `prepared_cache=` after the cache had been rebuilt
against this artifact. **A real build always pays the full cost** (R60):
`run_gates` calls the gate with no cache path and the gate never looks for
one on its own, because its job is to evaluate the labelled set against the
artifact it is gating, and an in-place rebuild of the same dump date would
otherwise have been gated against the previous build's candidates. An
explicit `prepared_cache` is for callers who can vouch for it, and even then
the file is refused unless its header's artifact timestamp and code
fingerprint match (see "the prepared-cases cache" below).

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

Task 27 calibrated the matcher's weight vector against the 448-case labelled set (`data-sources/src/openlibrary/eval/cases/`) and, separately, made one bounded attempt to have Splink do that instead; the whole-branch review of Increment 3 then changed the decision stage (matcher v2, below); the PR #308 review then found rule 6 was not volume-guarded like every other blocking rule (R64, below). Seven readings, same 448 cases, same real 2026-07-31 artifact:

| Reading | recall@5 | recall@10 | recall@50 | precision@accept | FALSE MERGE | false reject | abstention | correct no-match |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Equal weights, primary author names only (Task 26) | 0.895 | 0.927 | 0.951 | 0.843 | 0.1572 | -- | 0.596 | 0.179 |
| 2. Equal weights, alternate names (Task 26b) | 0.897 | 0.930 | 0.949 | 0.868 | 0.1322 | -- | 0.576 | 0.149 |
| 3. Calibration v1 (original objective) | 0.903 | 0.932 | 0.949 | 0.966 | 0.0345 | *(not measured; see below)* | 0.094 | 0.955 |
| 4. Calibration, final (amended objective) -- matcher v1 as shipped | 0.886 | 0.922 | 0.943 | 0.980 | 0.0201 | 0.0027 | 0.643 | 0.134 |
| 5. Matcher v2 decision rules, reading 4's weights, before the R59 reject-band extension | 0.886 | 0.922 | 0.943 | 0.993 | 0.0068 | 0.0027 | 0.658 | 0.090 |
| 6. Matcher v2 (v2 rules, reading 4's vector re-validated, `language_agreement` 0.0) | 0.886 | 0.922 | 0.943 | 0.993 | 0.0068 | 0.0000 | 0.661 | 0.090 |
| 7. **Matcher v2 + R64, shipped** (rule 6 volume-guards itself; same vector re-validated again) | 0.886 | 0.922 | 0.943 | **0.993** | **0.0068** | **0.0000** | 0.665 | 0.060 |

`recall misses (positives)` is **16 of 370 in all seven rows**, unchanged -- it is a property of blocking, never of weights or decision rules (see the R45/R46 invariant in Task 26b). Readings 1 and 2 predate `false_reject_rate` (added in reading 4's fix round); reading 3's held-out-split value, computed retroactively against the same code, is in the TEST table below.

Reading 3 looks like the best row on every column it reports -- precision 0.966, false merge 0.0345, abstention *down* to 0.094 -- and that is exactly the trap: it bought that abstention rate by silently converting true matches into rejects, which reading 3's own objective could not see. Reading 4 was matcher v1 as shipped at the end of Task 28. Reading 6 shipped as matcher v2: the same weight vector under the v2 decision rules, which took the false-merge rate from 3 accepts in 149 to 1 in 146 and the false rejects to zero. The remaining false merge is `high_frequency_title-017`, whose label is a recorded **contested tiebreak** -- the matcher accepted the work carrying the book's exact ISBN; the labeller chose a duplicate work on contamination grounds and wrote "flip to OL19760957W if identifier-first should hold". The cost of v2 is three correct no-matches (9 -> 6 of 67) and one correct accept: `no_candidates-036` is R59 working as ruled (a frequency-suppressed title with nothing else to look up now abstains); `shared_key_collision-080` is an R58 cost (its best candidate carried author evidence only and a score under the reject threshold -- v1 rejected it on the score, v2 abstains for want of identity evidence, because the identity guard runs before the threshold bands); `degenerate_title-015` is the correct accept R58 was predicted to lose (a `match` v1 accepted on author agreement alone); and one no-match is rule 6's arbitrary fallbacks landing on the other side of the reject threshold this rebuild (see "Why rule 6 was noise" below). R59 also turned `degenerate_title-007` (labelled `ambiguous`, shelf refused) from a wrong reject into a correct abstain. Re-scoring the v2 cache under the v1 decision rules isolates the rules from the rebuild: the rules alone move exactly eight decisions -- the seven named here plus `no_candidates-030` -- and account for false merge 0.0201 -> 0.0068, false reject 0.0054 -> 0.0000, correct no-match 0.119 -> 0.090.

Reading 7 is what ships now: PR #308's review (Codex, confirmed by the controller as R64) found rule 6 was the one blocking rule that queried a bare `LIMIT MAX_CANDIDATES_PER_RULE` and never recorded a volume guard, so an overflowing fuzzy search (more than 200 works tied at jaccard 1.0 -- see "Why rule 6 was noise" below) silently admitted an arbitrary 200 of the ties instead of saying the search was incomplete. Rule 6 now follows rules 1, 3, 4 and 5: query for cap + 1, and when more come back, admit nothing and record `volume_guards_tripped`. The prepared cache was rebuilt against the fixed `blocking.py` (R60: its `code_sha256` covers that file); re-scoring the same shipped vector under it moves nothing but `correct_no_match_rate` (0.0896 -> 0.0597, 6/67 -> 4/67) and, by less than 0.005, `abstention_rate`. The two cases that move are `no_candidates-001` ("Merian Thailand") and `no_candidates-012` ("If Only Happiness Was A No Brainer") -- both genuinely absent from Open Library, both previously landed in the reject band on rule 6's arbitrary (and, before this fix, undetectable) 200-fallback overflow, best scores 0.399 and 0.361 against the 0.400 reject threshold. Under the fix, rule 6 admits nothing for either (the search overflows, so it is suppressed) and `decide` abstains -- "no candidates; search refused for volume: trigram" -- rather than asserting a refused search had confirmed a non-match. That is the fix working as intended: an abstention costs a review, which is cheaper than a decision an incomplete search was never entitled to make. Re-calibration was attempted (the correct-no-match move is over the ~0.01 trigger) and confirmed the shipped vector still wins -- see "The v2 calibration" below.

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

### Why v2: two decision-stage gaps, one stale-key path

The whole-branch review of Increment 3 read the v1 false merges and the v1 false reject case by case and found that neither the weights nor the labels were at fault -- the decision stage was:

- **Author agreement alone was identity evidence (R58).** `decide`'s guard was "any feature but the popularity prior", and `author_overlap` + `author_name_similarity` carried two of the largest calibrated weights. A candidate reached through an author shelf whose title could not be compared at all (a Bengali or Cyrillic title fingerprints to the empty string, so every title feature is `None` under R40) therefore scored its author agreement as the whole weighted mean: `degenerate_title-013` accepted at 0.913 and `pseudonym_or_alt_name-001` at 0.946, both labelled `no_match`, 2 of the 3 v1 false merges. Identity evidence is now an allow-list -- a present title feature (`title_similarity`, `title_variant_exact`, `subtitle_agreement`) or `identifier_agreement == 1.0`; author, year, language and popularity can move a score but never carry an accept on their own.
- **A refused search was a negative (R59).** Every blocking rule has a volume cap, and a tripped cap was recorded in `guards_tripped` -- which nothing downstream read. `degenerate_title-014` (Agatha Christie, Cyrillic title, shelf 1,226 works > `MAX_SHELF_SIZE` 500) came back with zero candidates and `decide` said `reject`: "not in Open Library", recorded as fact, for a book whose author's shelf the matcher had declined to open. `BlockingResult.volume_guards_tripped` now names the rules whose *cap* tripped (as distinct from the empty/short-fingerprint `title_fp` guard, which means "nothing to look up"), `PreparedCase` carries it, and `decide` abstains -- "search refused for volume: author_shelf" -- both with zero candidates and when every candidate scores under the reject threshold. The second half was added after the rebuild showed it was needed: `no_candidates-030` ("Donne Innamorate", D.H. Lawrence's shelf refused) reached the reject band on 200 rule-6 fallbacks, none of them the book, best 0.397 against a 0.4 threshold. Correct no-match cases that abstain for this reason are the accepted cost: on this set, under the shipped weights, the zero-candidate half costs one (`no_candidates-036`) and the reject-band half none.
- **Rule 1 returned stale work keys (R41).** `identifiers.work_key` is whatever the edition recorded; on 2026-07-31 it is a redirect *source* for 270 works (9,216 rows) and absent from `works` for 294. Rule 1 now resolves through `redirects` and drops keys not in `works`, because under R35 a stale hit in `identifier_hits` turns the true work into an identifier *conflict*. No labelled case hit this (0 of 448); the rebuild confirmed identical rule-1 hits on every identifier-bearing case.

`MATCHER_VERSION` is 2 because the first two change what the same candidates and the same weights decide. The prepared cache was rebuilt (31 minutes) since rule 1 changes what `prepare` produces.

**Why rule 6 was noise, measured -- and the R64 fix.** Investigating `no_candidates-030` explained why it had read as an *abstain* under v1 and a *reject* under v2 with the same weights: DuckDB's `jaccard()` is character-**set** Jaccard, not trigram similarity. For the fingerprint `donne innamorate`, 10,494,985 works clear the 0.55 floor and 973 tie at exactly 1.0 -- and rule 6 was the one blocking rule that queried a bare `ORDER BY ... LIMIT 200` and never recorded a volume guard for it, so it silently admitted an arbitrary 200 of those ties, a different set on every `prepare` (the connection sets `preserve_insertion_order=false`). An incomplete fuzzy search then looked exactly like an exhaustive one to `decide`: it could accept an arbitrary candidate, or -- as `no_candidates-030` and the two cases named above show -- land in the reject band on fallbacks none of which were the book, asserting "not in Open Library" for a search that was never complete enough to say so.

PR #308's review (Codex, ruling R64) closed this: rule 6 now follows the same contract as rules 1, 3, 4 and 5 -- query for `MAX_CANDIDATES_PER_RULE + 1`, and when more come back, admit nothing and record `volume_guards_tripped` instead. This closes the "rule 6 is nondeterministic / retire it" carry-forward from the v2 measurement directly: under the cap, rule 6's candidate set is now exactly as deterministic as every other rule's, and over the cap it deterministically contributes nothing rather than an arbitrary something. The remaining cost is what "Matcher, measured" describes for reading 7 -- two correct no-matches become abstentions -- which is the design's stated preference (an abstention costs a review; a wrong "not in Open Library" costs more) rather than a regression. In the per-rule split below rule 6 still reaches **zero** labelled works on this artifact, so retiring it remains an open Increment 4 question, but no longer for the nondeterminism reason -- only because it has not yet been observed to help.

### Matcher v2, by stratum (reading 6)

```
anthology_or_collection    n=30   correct=7    false_merges=0    recall_miss=0
author_less_work           n=19   correct=11   false_merges=0    recall_miss=0
degenerate_title           n=20   correct=6    false_merges=0    recall_miss=3
easy_baseline              n=60   correct=38   false_merges=0    recall_miss=0
high_frequency_title       n=40   correct=27   false_merges=1    recall_miss=0
isbn_reuse                 n=30   correct=2    false_merges=0    recall_miss=0
no_candidates              n=50   correct=2    false_merges=0    recall_miss=5
no_popularity_signal       n=30   correct=11   false_merges=0    recall_miss=0
non_latin_title            n=30   correct=4    false_merges=0    recall_miss=2
pseudonym_or_alt_name      n=29   correct=13   false_merges=0    recall_miss=2
shared_key_collision       n=80   correct=20   false_merges=0    recall_miss=4
stale_ol_key               n=30   correct=21   false_merges=0    recall_miss=0
```

Against reading 4: `degenerate_title` and `pseudonym_or_alt_name` each lose their one false merge (R58); `degenerate_title`'s `correct` is unchanged at 6 because it trades `-015` (a correct author-only accept, now an abstain) for `-007` (an `ambiguous` case whose refused shelf now abstains instead of rejecting); `no_candidates` loses two `correct` (`-036` under R59 and one rule-6 flicker) and `shared_key_collision` one (`-080`, an R58 abstain on an author-only candidate v1 had rejected on score). Nothing else moves.

Reading 7 (R64) moves exactly one line of this table from reading 6: `no_candidates` `correct` 2 -> 0 (`no_candidates-001` and `no_candidates-012`, both now abstentions instead of correct rejects -- see "Matcher, measured" above). Every other stratum, in every reading in this file, is unchanged.

### Recall by blocking rule (reading 7)

For each blocking rule, how many of the 370 labelled works a candidate carrying that rule reached, and how many were reached by **no other rule** (`harness.rule_recall_split`, printed by the harness CLI). Increment 4 needs this to decide what blocking can shed. Identical to reading 6 -- R64 changes rule 6's admission when the fuzzy search overflows, not which works any rule reaches, and rule 6 never overflows for a labelled case on this artifact:

| rule | reached | only by this rule |
|---|---:|---:|
| identifier | 285 | 35 |
| existing_key | 80 | 2 |
| author_title_fp | 196 | 2 |
| title_fp | 169 | 6 |
| author_shelf | 261 | 32 |
| trigram | 0 | 0 |

Rules 1 (identifiers) and 5 (the author shelf) are load-bearing -- 67 labelled works are reached by one of them alone. Rules 2 and 3 are almost entirely redundant with the others and rule 6 has never reached a labelled work (see above).

### The v2 calibration: what the search found, and why reading 4's vector still ships

`MATCHER_VERSION` 2 changes what the same candidates and weights decide, so the vector was re-fitted per the procedure: cache rebuilt, `calibrate` run cold from `equal_weights()` with the fixed seed. R61 made the calibration honest about coverage first: per-feature presence over the training split is measured and printed, and a feature no training pair ever exercised is pinned to weight 0.0 and removed from the search knobs -- `language_agreement` had **0 present values in 40,735 pairs** (the labelled books carry no language; the feature cannot fire without one) and had shipped at 1.0 under `calibrated: true`. The written file now also records `method: "random-search"`.

The cold start (seed 20260901, 2000 steps) then converged into a poor basin: its last improvement was at step 271 (TRAIN objective 0.3959, four false merges left in the training split), 6000 steps only reached 0.4027, and two other seeds did no better (TEST objectives -1.05 and -0.09 on their own splits). Meanwhile reading 4's vector, re-scored under the v2 rules, sits at TRAIN 0.8090 / TEST 0.9339 -- a better vector was already known. So the CLI's documented warm start was run: `--base <reading 4's file>`, whose write gate demands a TEST win over both equal weights (0.6056) and the base. The search moved one knob (`reject_threshold`, TRAIN 0.8090 -> 0.8097) and lost on TEST (0.9339 -> 0.9286), and the CLI left the file untouched. The vector that ships is therefore reading 4's, under `matcher_version: 2`, with `language_agreement` set to 0.0 per R61 (verified to change no score and no decision on the labelled set) and `calibrated_at` left at the time it was actually fitted. Writing the cold-start result would have shipped a false-merge rate of 0.0355 and re-pinned the gate to hide it.

**TEST-split objective, v2 rules** (`min_accept_rate=0.3`, same seed and split as the v1 table):

| Weights | false_merge | false_reject | precision | abstain | objective |
|---|---:|---:|---:|---:|---:|
| `equal_weights()` | 0.0303 | 0.0000 | 0.970 | 0.611 | 0.6056 |
| v2 cold start, seed 20260901, 2000 steps (written, superseded) | 0.0169 | 0.0064 | 0.983 | 0.644 | 0.7427 |
| `--base` warm start from reading 4's vector | 0.0000 | 0.0064 | 1.000 | 0.650 | 0.9286 |
| **reading 4's vector under v2 rules (shipped)** | **0.0000** | **0.0000** | **1.000** | 0.661 | **0.9339** |

The corrected handback diagnosis, while on the subject of the objective: the ~64-66% abstention rate is not where the abstention cost (0.1 per abstention) balanced anything. The shipped vector accepts 146 of 448 cases, an accept rate of 0.326 against the objective's hard floor of 0.30 -- the search drove accepts down as far as the floor allowed because every accept it gave up removed false-merge risk at ten times the price of the abstention it created. **The accept-rate floor is the binding constraint**; lowering the abstention cost would change nothing, and raising the floor is the only knob that would trade abstentions back for accepts.

**Re-calibration under R64, and the R65 near-miss it exposed.** R64's fix changes `blocking.py`, so its `code_sha256` moved and the prepared cache was rebuilt; `correct_no_match_rate` moving 0.0896 -> 0.0597 is over this project's ~0.01 re-calibration trigger, so calibration was re-run against the rebuilt cache. A bare cold start (no `--base`, exactly the documented CLI invocation) scored TEST 0.7416 -- comfortably above the naive equal-weights floor (0.6044) the write gate compared it to, and so it wrote, overwriting the shipped vector's own 0.9339 with a vector that was worse on every axis that matters (TEST false_merge 0.0169 and a nonzero false_reject 0.0064, against the shipped vector's 0.0000/0.0000). This is the same trap the original v2 calibration already documented above (a cold start once needed `--base` to avoid shipping a 0.0355 false-merge rate) recurring in a new form: nothing in the write gate compared the candidate against what `--out` already held. The regression was caught by inspecting the run's own printed floor (obviously just equal weights, not the known-good vector) rather than by any gate, the shipped vector was restored from git, and calibration was re-run with `--base` pointed at it -- the documented procedure -- which correctly reached TEST 0.9275, short of the shipped vector's 0.9333 under the rebuilt cache, and left `weights.json` untouched.

That near-miss is now closed structurally (ruling R65), not just avoided by a human reading the numbers this one time: `calibrate.main`'s write gate folds a third candidate into the floor whenever `--out` already exists and is itself `calibrated` -- that file's own TEST score, evaluated fresh against the same split -- so `floor_score = max(equal, base, current_out)`. A bare cold start can no longer overwrite a better vector than itself just because it beat equal weights; the "not written" message now names which of the three floors actually won. `weights.json` is unchanged by all of this: reading 7 ships the same vector as reading 6, `calibrated_at` unmoved, only re-validated against the R64-fixed cache and (twice) against a fresh calibration search that failed to beat it.

**Gate and cache policy.** The build gate evaluates the labelled set against the artifact it is gating and never reads a prepared cache on its own (R60); the cache header now fingerprints the artifact build and the four modules whose code determines what `prepare` produces, so a stale cache is refused with the mismatch printed rather than documented as a hazard. The thresholds in `thresholds.json` are re-pinned from reading 7 with the same headroom policy as Task 28; the file carries each bound beside its `measured` value and a `source` line naming the run, and the per-bound reasoning is here (see also `tests/openlibrary/test_pipeline_gates.py`): recall@10 >= 0.90, false merge <= 0.015 (two merges in 146 accepts pass, three fail), precision >= 0.98, abstention <= 0.70, correct no-match >= 0.04 (loosened from 0.05 under R64: two `no_candidates` cases that used to land in the reject band on rule 6's now-suppressed overflow correctly abstain instead, so the measured rate moved 0.090 -> 0.060 -- a real change in what "correct no-match" means for those two cases, not a flicker to paper over), false reject <= 0.005 (one passes, two fail).

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

R54 adds a cache on top of that split: `write_prepared_cache`/`read_prepared_cache` (in `harness.py`) persist a `prepare()` result to a JSON file. Both CLIs take `--prepared-cache PATH`; the artifact-side copy used for this task lives at `/home/shane/ol-data/tmp/prepared-2026-07-31.json` (scratch space on the artifact host, **not** committed to the repo). The first run against a given path writes it (~31 minutes); every run after loads it in seconds. The header carries five values and the file is trusted only when all five match (R60): `dump_date`, `matcher_version`, `n_cases`, `artifact_built_at` (the version directory's `manifest.json` timestamp, so a same-date rebuild of the artifact invalidates it) and `code_sha256` (over the bytes of `matcher/blocking.py`, `matcher/features.py`, `common/normalize.py` and `common/scoring.py`, so a code change to any of the four invalidates it). The header detects an artifact rebuild or a code change to those four modules; other changes that alter what `prepare` produces without moving any of the five -- a relabel of the case set that keeps its count, an edit to `harness.prepare` or `dataset.resolve_keys` -- still need a manual delete. (`decide.py` and `scorer.py` do not: they run on top of the cached candidates in `evaluate`, which is the whole point of the split.)

### Increment 3 is complete

All four of the increment's stated completion criteria hold: the harness
reports all six metrics (recall@5/10/50, precision@accept, false-merge,
false-reject, abstention, correct-no-match) plus the per-rule recall split
against the real 2026-07-31 artifact and the real 448-case labeled set (see
"Matcher, measured" above); `weights.json` says whether it is calibrated and
by which method (`calibrated: true`, `calibrated_at` timestamped,
`method: "random-search"`, `matcher_version: 2`); `thresholds.json` records
the measured numbers from the shipped v2 reading rather than aspirations,
each with a `measured` sibling recorded beside it; and the build fails its
evaluation gate if the matcher regresses past any of those thresholds (Task
28, `evaluation_gate` in `pipeline/gates.py`), always against the artifact
being built (R60) -- verified against the real artifact above, where it
reports `pass`.

## Service, measured

Task 34 built the image, brought it up against the real 2026-07-31 artifact,
and timed every endpoint. All numbers below are real-artifact wall clock on
this box: ~27 cores available to DuckDB, `OL_API_MEMORY_LIMIT` at its default
8GB, and every query an un-indexed Parquet scan (no table here carries an
index). A smaller container will be slower roughly in proportion to how many
cores it gets -- these numbers are not portable to a differently-sized box
without that adjustment.

| Endpoint | Wall clock | Source |
|---|---|---|
| `GET /works/{key}` | 0.63-0.89 s | Task 31 |
| `GET /works/{key}/editions` | 1.6-2.2 s (1.73 s re-measured after R84a) | Task 31 / Task 32 |
| `GET /authors/{key}` | 0.04 s | Task 31 |
| `GET /authors/{key}/works` (shelf) | 0.56-0.77 s | Task 31 |
| `GET /identifiers/{type}/{value}` | 0.17-0.19 s | Task 31 |
| `POST /works/batch` (100 keys) | 1.43 s | Task 32 |
| `POST /authors/batch` | 0.13 s | Task 32 |
| `POST /resolve` (labelled case) | 4.85-4.89 s | Task 33 |
| `POST /resolve` (Gatsby, title+author+year) | 5.0-5.03 s (Task 33); 5.4 s wall via `curl` through the Task 34 container | Task 33 / Task 34 |

**What this means for Increment 5's Rails client:**

- **Read timeouts:** at least 30 s for `/resolve` (it is consistently ~5 s
  against a fixture-sized query on a 27-core box; a colder or smaller box, or
  a query that blocks wider, has real room to run longer) and at least 10 s
  for any retrieval endpoint (`/works/{key}/editions` is the slowest single
  lookup at up to 2.2 s, and that number moves with cores, not with request
  size).
- **One `/resolve` at a time.** Each call is `harness.prepare`'s own
  un-indexed scan over `identifiers` (120M rows) plus four other blocking
  rules -- it saturates however many cores DuckDB is given. Firing two at
  once does not make either one faster; it makes both slower. The client
  should serialize `/resolve` calls, not pool them.
- **Retrieval goes through the batch endpoints.** 100 works in one
  `POST /works/batch` call costs ~1.4 s total versus ~0.7-0.9 s **per work**
  through the singular `GET /works/{key}` -- a ~50-60x reduction in wall
  clock for a 100-work page. Any Rails code fetching more than a couple of
  records should batch.

**The read-only mount proof.** `docker compose exec api sh -c 'touch
/data/versions/2026-07-31/works.parquet'` and `mkdir /data/tmp/probe` both
fail with "Read-only file system" (Task 34, Step 4). What enforces this is
the compose file's `:ro` bind mount on `/data` -- nothing in DuckDB itself
refuses a write, and there is no DuckDB flag that would. The one place the
service does write is `OL_API_TEMP_DIR` (DuckDB's spill directory), which
defaults to the container's own `/tmp` -- writable, and never under the
artifact mount.

**Version pinning.** The API always opens an explicit `OL_DATA_VERSION`
directory (`deps.open_artifact`), never a symlink: `deps.SymlinkedVersion` is
raised and the process refuses to boot if `versions/<date>` turns out to be a
symlink, because a symlink flip would not affect a process already holding
open file handles into the old target. Compose reads the version from the
environment (`OL_DATA_VERSION`, defaulting to `2026-07-31` for this box) so a
new build can be pinned without touching the compose file.

**The Gatsby example, as the shape of an abstain.** `POST /resolve` with
`{"title": "The Great Gatsby", "author_names": ["F. Scott Fitzgerald"],
"year": 1925}` against the real artifact returns `verdict: "abstain"`, top
candidate `OL468431W`, score ~0.986, margin ~0.028 -- a runner-up scores
~0.957, close enough that the calibrated matcher declines to call it rather
than guess. This is not a bug: `weights.json`'s `accept_threshold`/
`reject_threshold`/margin gap are the calibrated matcher's real, measured
behaviour on this title (see "Matcher, measured" above), and the accept
threshold is a deliberately deferred dial -- tightening or loosening it is a
calibration decision for whoever operates the service, not something this
task changes.
