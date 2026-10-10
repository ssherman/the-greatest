# Recommendation engine: the collaborative signal against the bar (2026-10-10)

Measured on 2026-10-10 against the development database and the local OpenSearch index (160,593
documents; ranked pool 21,391), with `bin/rails recommendations:export`, the Python trainer
(`data-sources/src/recommender/`), `bin/rails recommendations:load` and `bin/rails
recommendations:eval`. Regenerate before acting on any number here: it describes one database on
one day.

Follows `recommendations-2026-10-08.md`, which shipped the quality prior and left one gap open: on
the 100+ segment, recall@50 trailed the frequency profile (0.109 against 0.181 on seed 42), because
a broad profile cannot cover a long history with 50 category-matched books. Spec 2
(`docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md`) adds a
readers-like-you signal from an EASE item-neighbour model to answer that. This record measures it
against the spec's bar (§8.2).

**Verdict: the bar is met on every condition, on both samples, by margins well outside the noise
band. `collaborative: true` stays the default.** On the 100+ segment hit@10 goes from 0.320 to
0.740 (seed 42) and from 0.330 to 0.740 (seed 7); recall@50 from 0.105 to 0.381 and from 0.105 to
0.405.

## What was measured

The export (`Recommendations::Books::PositivePairs`: favorites, read and reading list items, and
reviews rated 3 or more), against the counts spec 2 §1 was written from. The spec counted every
list item and every rated review; the positive definition leaves out want-to-read and ratings of 1
and 2, which is why every count is lower.

| What | Spec §1 (2026-10-09, all pairs) | Export 2026-10-10 (positives) |
|---|---|---|
| User–book pairs | 3,067,942 | 1,601,299 |
| Users with any pair | 51,300 | 33,757 |
| Users with 20 or more · 100 or more | 22,818 · 7,392 | 16,366 · 4,034 |
| Books | – | 85,164 |
| Books with 5 or more readers | 17,874 (94% of pairs) | 10,013 (94% of pairs) |
| Books with 10 or more readers | 10,018 (92% of pairs) | 5,886 (92% of pairs) |

Two hold-out exports, each omitting exactly the pairs the harness hides for its sample
(`Evaluation.hold_out_plan` with `USERS=300 FRACTION=0.2`, shared by the export and eval):

| Export | Hold-out | Rows |
|---|---|---|
| `2026-10-10-holdout-42` | 291 users, 1,891 pairs omitted | 1,599,408 |
| `2026-10-10-holdout-7` | 295 users, 1,884 pairs omitted | 1,599,415 |
| `2026-10-10` (full, `latest`) | none | 1,601,299 |

A read-only check (`rails runner`, recomputing each plan and scanning its export) found 0 of the
1,891 and 0 of the 1,884 held pairs in the corresponding file, so the model the harness scored
had never seen the books it was asked to recover.

## What was run

```bash
# web-app/
bin/rails recommendations:export DIR=tmp/recommendations HOLDOUT_SEED=42 HOLDOUT_USERS=300 HOLDOUT_FRACTION=0.2
# data-sources/: the sweep, one run at a time, each under /usr/bin/time -v
uv run python -m recommender.cli train --input ../web-app/tmp/recommendations/recommendations/books/interactions/2026-10-10-holdout-42.csv.gz \
  --output-dir <scratch>/lam-$lam --name 2026-10-10-holdout-42 --lambda $lam --min-readers 5   # lam in 100 300 500 1000 3000
uv run python -m recommender.cli train ... --lambda 500 --min-readers 10
# the chosen model into the local store, loaded, measured
uv run python -m recommender.cli train --input .../2026-10-10-holdout-42.csv.gz \
  --output-dir ../web-app/tmp/recommendations/recommendations/books/model --name 2026-10-10-holdout-42 --lambda 500
bin/rails recommendations:load DIR=tmp/recommendations VERSION=2026-10-10-holdout-42      # loaded: 500000 rows
bin/rails recommendations:eval USERS=300 SEED=42 FRACTION=0.2 VARIANTS="collaborative=false"
# the second sample: the same three steps with HOLDOUT_SEED=7 / SEED=7       # loaded: 500300 rows
# leave development on a full model
bin/rails recommendations:export DIR=tmp/recommendations
uv run python -m recommender.cli run --store-dir ../web-app/tmp/recommendations --work-dir <scratch>/recommender-work --lambda 500
bin/rails recommendations:load DIR=tmp/recommendations                                    # loaded 2026-10-10: 500650 rows
bin/rails recommendations:show USER_ID=69652 LIMIT=20
```

The trainer's own evaluation (`--eval-seed 1`, the default) holds one random positive out per user
with 5 or more positives, fits on the rest, and scores every user over all model items. The
harness is the bar; the trainer's numbers pick λ and the floor and are not comparable to the
harness's (a different hold-out, no ranked-pool filter, no page).

## 1. The trainer sweep (seed-42 hold-out export)

Wall time is the whole `train` command: reading the CSV, two fits (the evaluation split, then
everything) and writing the model. Peak memory is the maximum resident set size.

| λ | min-readers | users | items | rows | hit@10 | recall@50 | seconds | peak GiB |
|---|---|---|---|---|---|---|---|---|
| 100 | 5 | 30,490 | 10,000 | 500,000 | 0.438 | 0.721 | 27.2 | 3.2 |
| 300 | 5 | 30,490 | 10,000 | 500,000 | 0.436 | 0.722 | 21.2 | 3.2 |
| **500** | 5 | 30,490 | 10,000 | 500,000 | 0.436 | 0.722 | 26.1 | 3.2 |
| 1000 | 5 | 30,490 | 10,000 | 500,000 | 0.431 | 0.719 | 24.0 | 3.2 |
| 3000 | 5 | 30,490 | 10,000 | 500,000 | 0.425 | 0.711 | 23.5 | 3.2 |
| 500 | 10 | 30,437 | 5,873 | 293,650 | 0.434 | 0.720 | 12.4 | 1.3 |

Evaluated over 26,362 users at the 5-reader floor and 26,300 at 10. The seed-7 model and the full
model, both λ 500 at floor 5, took 17.7 s and 20.3 s (the full one through `cli run`, gate
included: "published 2026-10-10 (no previous model)"), both at 3.2 GiB.

**λ stays at 500.** The curve is flat between 100 and 500: λ 100 is 0.002 ahead on hit@10 and
0.001 behind on recall@50. With 26k evaluated users the standard error on hit@10 is about 0.003,
so that is not a difference, and keeping the default means the model that was measured is the
model production trains. Above 500 both metrics fall steadily (0.011 on hit@10 by λ 3000). The
10-reader floor is not better: 0.434 against 0.436, with 41% fewer items for the signal to reach.
It halves time and memory, which nothing here needs.

**The fit is much faster than the spec estimated.** The spec sized "one to two minutes" and a
2.6 GB gram matrix at 17,874 items. With positives only, the 5-reader floor keeps 10,013 items, the
gram matrix is 0.8 GB, and the whole command, two fits included, runs in 18-27 s on this machine
(32 cores) at 3.2 GiB peak. The model is 500k rows against the spec's ~900k for the same reason
(every item keeps the full top 50).

## 2. The harness, seed 42 (100 sampled users per segment)

`shipped defaults` is taste + collaborative; `collaborative=false` is the engine as it was before
this spec (taste only, with the quality prior); the last row is the frequency baseline, which pins
`collaborative: false`. `cf` counts the evaluated users whose run used the collaborative signal.

```
Recommendations evaluation  eligible users=2207  ranked pool=21391  sampled=300  seed=42  hold-out=0.2  limit=50
variants: rank baseline | shipped defaults | collaborative=false | lift=false  quality_scale=0  collaborative=false

-- segment 5-19: 91 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.209     0.319    0.119        28    6.560   1.313     0.005      -      -
   shipped defaults                                   0.286     0.282    0.134       548    6.099   0.722     0.050    184     91
   collaborative=false                                0.198     0.197    0.096       605    5.725   0.807     0.052    119      0
   lift=false  quality_scale=0  collaborative=false   0.066     0.139    0.056      1924    2.121   0.615     0.032    132      0

-- segment 20-99: 100 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.340     0.300    0.148        40    6.340   1.096     0.010      -      -
   shipped defaults                                   0.480     0.397    0.216       500    5.300   0.594     0.042    262    100
   collaborative=false                                0.230     0.147    0.073       821    4.790   0.793     0.053    126      0
   lift=false  quality_scale=0  collaborative=false   0.150     0.202    0.082       837    1.680   0.277     0.027    209      0

-- segment 100+: 100 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.550     0.271    0.223        77    5.630   1.123     0.018      -      -
   shipped defaults                                   0.740     0.381    0.289       595    4.110   0.669     0.038    335    100
   collaborative=false                                0.320     0.105    0.081      1030    2.890   1.080     0.045    128      0
   lift=false  quality_scale=0  collaborative=false   0.280     0.152    0.083       295    1.620   0.275     0.033    293      0
```

## 3. The harness, seed 7 (a second sample, 100 users per segment)

A different hold-out export and model (`2026-10-10-holdout-7`) and different users, so this is a
second sample, not a repeat.

```
Recommendations evaluation  eligible users=2207  ranked pool=21391  sampled=300  seed=7  hold-out=0.2  limit=50
variants: rank baseline | shipped defaults | collaborative=false | lift=false  quality_scale=0  collaborative=false

-- segment 5-19: 96 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.156     0.270    0.087        30    6.708   1.301     0.007      -      -
   shipped defaults                                   0.229     0.311    0.143       577    5.750   0.671     0.050    176     96
   collaborative=false                                0.104     0.188    0.068       645    5.125   0.804     0.051    115      0
   lift=false  quality_scale=0  collaborative=false   0.104     0.123    0.059      3210    2.052   0.636     0.039    129      0

-- segment 20-99: 99 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.384     0.261    0.164        45    6.343   1.189     0.011      -      -
   shipped defaults                                   0.455     0.432    0.224       561    4.818   0.598     0.044    264     99
   collaborative=false                                0.182     0.160    0.085      1040    3.990   0.814     0.056    120      0
   lift=false  quality_scale=0  collaborative=false   0.162     0.204    0.079      1019    1.616   0.330     0.026    214      0

-- segment 100+: 100 of 100 sampled users evaluated
   variant                                           hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms     cf
   rank                                               0.590     0.259    0.220        72    5.940   1.226     0.016      -      -
   shipped defaults                                   0.740     0.405    0.296       551    4.140   0.721     0.037    331    100
   collaborative=false                                0.330     0.105    0.069       892    2.090   1.230     0.039    115      0
   lift=false  quality_scale=0  collaborative=false   0.340     0.210    0.107       255    1.090   0.315     0.030    300      0
```

## Verdict against the bar

Spec 2 §8.2: on 20-99 and 100+, taste + collaborative beats today's engine (`collaborative=false`)
on hit@10 and recall@50 beyond the sample's noise band; 5-19 does not lose beyond noise; mean
global rank within a factor of two of today's; genre KL no worse than today's. The noise band at
100 users per segment is about 0.03-0.05 on hit@10 and recall@50 (the earlier records). Each
comparison below is on the same users and the same hold-out.

| Condition | Seed 42 (defaults vs `collaborative=false`) | Seed 7 | Met |
|---|---|---|---|
| 20-99 hit@10 higher | 0.480 vs 0.230 (+0.250) | 0.455 vs 0.182 (+0.273) | yes |
| 20-99 recall@50 higher | 0.397 vs 0.147 (+0.250) | 0.432 vs 0.160 (+0.272) | yes |
| 100+ hit@10 higher | 0.740 vs 0.320 (+0.420) | 0.740 vs 0.330 (+0.410) | yes |
| 100+ recall@50 higher | 0.381 vs 0.105 (+0.276) | 0.405 vs 0.105 (+0.300) | yes |
| 5-19 not worse | hit@10 0.286 vs 0.198 (+0.088); recall@50 0.282 vs 0.197 (+0.085) | 0.229 vs 0.104 (+0.125); 0.311 vs 0.188 (+0.123) | yes (better) |
| Mean rank within 2× | 548 / 605 (0.91×), 500 / 821 (0.61×), 595 / 1030 (0.58×) | 577 / 645 (0.89×), 561 / 1040 (0.54×), 551 / 892 (0.62×) | yes |
| KL no worse | 0.722 vs 0.807, 0.594 vs 0.793, 0.669 vs 1.080 | 0.671 vs 0.804, 0.598 vs 0.814, 0.721 vs 1.230 | yes (lower) |

The smallest margin on a hit metric is +0.085 (5-19 recall@50, seed 42), roughly twice the top of
the noise band. Every other margin is larger, most of them by five to ten times.

Two notes on what that footing is. First, the setting is weak generalisation: every sampled user
is in the training data and only their hidden pairs are missing, which is the production case
(the model knows the reader's other books). Second, a binomial standard error at n ≈ 100 and
p ≈ 0.5 is about 0.05 per proportion, about 0.07 for an unpaired difference; every margin on the
20-99 and 100+ conditions (smallest +0.250) clears that 0.07 by more than 3.5×, and the 5-19
condition only asks for no loss, where the margins are gains of 0.085-0.125. The comparisons are
paired, on the same users, so the real band is narrower. A review check found at most 2 of the 100 sampled 100+ users with a
near-duplicate account whose shelf contains their held books; that bounds any leak through a
second account at 0.02 on hit@10 and recall@50, inside every margin.

The gap the previous record left open is closed as well: on 100+ the defaults now beat the
frequency baseline on recall@50 (0.381 vs 0.152; 0.405 vs 0.210), and on 20-99 too (0.397 vs
0.202; 0.432 vs 0.204). On that comparison the 2026-10-08 engine lost on both segments.

## Reading

- **The lift is large and it is not just popularity.** The pages got shallower (mean rank about
  0.55-0.6× today's on 20-99 and 100+), and the hold-out rewards famous books, so some of the gain
  is the hold-out's canon bias. But the `rank` baseline, which is the canon in order at mean rank
  28-77, scores 0.55-0.59 on 100+ hit@10 and 0.26-0.27 on recall@50; the collaborative page scores
  0.74 and 0.38-0.41 at mean rank 550-600. It recovers more hidden favorites than the canon does,
  from a page whose mean rank is about 8 times deeper on 100+ (595 against 77, 551 against 72).
  On 5-19 the ratio is about 20 (548 against 28, 577 against 30).
- **KL fell, it did not rise.** The co-read neighbours of a reader's books sit in that reader's
  genres more than the category query's long tail does, so the calibrated page matches the history
  better (100+: 0.67-0.72 against 1.08-1.23).
- **The signal fired for every evaluated user** (`cf` equals the evaluated count in all six
  segments). A 5-19 reader has at least five ranked favorites or 4-plus ratings, so at least four
  trainable books after the hold-out, and the 5-reader floor keeps 94% of pairs; nobody in the sample fell outside
  the model.
- **Author repeats rose and coverage fell a little.** `au_rep` (books on the page whose author is
  already on it, at most two per author) went from 2.1-2.9 to 4.1 on 100+ and from 4.0-4.8 to
  4.8-5.3 on 20-99; coverage from 0.039-0.056 to 0.037-0.044. Neither is in the bar. Co-readers of
  an author tend to read more of that author; the cap still holds the page at two each.
- **The page costs more time.** The `ms` column is the whole engine call: 331-335 ms on 100+ with
  the signal against 115-128 ms without, 262-264 against 120-126 on 20-99. The signal's own two
  reads are a small part of it: for seven sampled users with 5-882 trainable books the neighbour SQL
  took 1-22 ms and the ranked-pool filter 8-18 ms (`rails runner`, model loaded). The rest comes
  after the signal (fusion, item facts and the re-rankers over a larger candidate union) and was
  not profiled. The two largest shelves in the data are slow in the SQL itself: 5,794 trainable
  books took 406 ms and 18,534 took 1,140 ms (spec §6 expected the largest shelf near 3,000).
- **"Because you loved" appears, but only where the strongest contributor is loved.** The
  evidence carries `because_of` only when the shelf book that contributed most is a favorite or
  rated 4 or more, so a reader whose shelf is mostly "read" sees few of them: 0 to 28 of 50 lines
  for the seven users timed above. The reason line names the book on the results page
  (`ReasonComponent`, names keyed by `[kind, id]`); the `recommendations:show` harness prints the
  book id instead, because its name lookup covers categories only.
- **What one page looks like** (`recommendations:show USER_ID=69652 LIMIT=20`, a 100+ reader in the
  seed-42 sample, 8 favorites and 99 read, almost all fiction, on the full model). With the signal:
  The Idiot, Huckleberry Finn, Where the Wild Things Are, Lolita, Wuthering Heights, Oedipus the
  King, A Wrinkle in Time, The Grapes of Wrath, Gulliver's Travels, David Copperfield, A Farewell to
  Arms ("because you loved" For Whom the Bell Tolls), To the Lighthouse, Paradise Lost, As I Lay
  Dying (because of Tender Is the Night), Through the Looking Glass, Journey to the End of the
  Night, Candide, The Hunchback of Notre-Dame, Under the Volcano and The Good Soldier (both because
  of Henderson the Rain King). `signals: [:taste_profile, :collaborative]`. Taste only: the same
  kind of list with Kim, Buddenbrooks, Silas Marner, Gravity's Rainbow, Bleak House, Howl and Wings
  of the Dove in place of the Steinbeck, Hemingway, Swift, Dickens, Carroll, Voltaire and Hugo. On
  one page the difference is a reshuffle of plausible books; it shows in the averages, not in a
  single list.
- **Sample size.** 100 users per segment on each seed, 91-100 evaluated. Two samples; the
  margins hold on both.

## What to try next

The spec's recorded experiments (§8.3), none run here:

- Weighted presence as `X`'s values (favorites 1.0, read 0.6, rated-3 0.5) instead of binary.
- Including want-to-read as a positive.
- A `collaborative_half_point` sweep (the fusion weight ramp, 10 today).
- The quality prior applied to the collaborative list (it is not, by design: the rank prior in
  fusion supplies canon).
- EASE on the ranked pool only.

Seen while measuring:

- λ below 100. The trainer curve is flat from 100 to 500 and rises slightly towards the low end; a
  sweep at 10-50 would say whether it keeps rising.
- A 3-reader floor. Only 10,013 of 85,164 books have 5 readers; the fit is fast enough to try a
  lower floor and see whether the extra reach helps the harness or only adds noise.
- Profile the extra 140-215 ms per request on 20-99 and 100+, and cap the shelf the neighbour SQL
  reads (for example the user's most recent or highest-weighted 2,000 trainable books) so the few
  very large shelves do not pay a second.
- `recommendations:show` should name the `because_of` book, as the results page does.
- The trainer's recall@50 can count zero-score ties as hits (a Task 9 review note), which inflates
  it for thin shelves. It does not touch the harness numbers above.
