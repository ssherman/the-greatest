# Recommendation engine: first measured tuning pass (2026-10-07)

Produced by `bin/rails recommendations:eval` (`app/lib/recommendations/evaluation.rb`,
`lib/tasks/recommendations.rake`) against the development database. Regenerate before acting on
any number here: it describes one database on one day.

**Verdict: the spec §9.2 gate is NOT met, and no single knob change or listed combination meets it.**
The initializer is unchanged. The tables and a reading follow; the decision on what to change in
spec §6 belongs to Shane.

## What was run

All from `web-app/`, read-only, against local OpenSearch. `USERS=300` means 100 sampled users per
segment; hold-out fraction 0.2, 50 recommendations per user, seed 42.

```bash
# 1. shipped defaults + the two baselines
bin/rails recommendations:eval USERS=300 SEED=42 > eval-defaults.txt

# 2. one knob at a time, same users
bin/rails recommendations:eval USERS=300 SEED=42 VARIANTS="rank_prior_weight=1.0; rank_prior_weight=2.0; max_subjects=10; subject_multiplier=0.5; calibrate_genres=false; candidate_size=100; min_score=2.0; pseudo_books=20; min_support=3" > eval-sweep.txt

# 3. the two combinations the hypotheses suggested
bin/rails recommendations:eval USERS=300 SEED=42 VARIANTS="rank_prior_weight=1.0,max_subjects=10; rank_prior_weight=2.0,max_subjects=10,subject_multiplier=0.5" > eval-combos.txt
```

Step 4 of the brief (confirm a winner on a fresh `USERS=500 SEED=7` sample) was not run: there is
no winner to confirm.

In the combos table the variant names are cut at 36 characters by the printer. The two rows are
`rank_prior_weight=1.0  max_subjects=10` and
`rank_prior_weight=2.0  max_subjects=10  subject_multiplier=0.5`.

## The database that day

| | |
|---|---|
| Books (catalog, non-provisional) | 160,292 (160,587 including provisional) |
| Ranked pool (`RankedItem`, default primary books config) | 21,392 |
| Eligible users (at least 5 hold-out candidates: favorites plus 4-star-or-better ratings) | 2,367 |
| Eligible by segment of positive list items | 5-19: 754, 20-99: 860, 100+: 736 |
| Sampled | 100 per segment (300 total) |
| Evaluated | 5-19: 96, 20-99: 100, 100+: 100 (four 5-19 users had no usable hold-out) |
| `recommendation_configs` rows | 0, so every user ran on default criteria (no filters) |

## Shipped defaults and baselines (`eval-defaults.txt`)

```
Recommendations evaluation  eligible users=2367  sampled=300  seed=42  hold-out=0.2  limit=50
variants: rank baseline | shipped defaults | lift=false

-- segment 5-19: 96 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.188     0.295    0.116        28    6.760   1.433     0.005      -
   shipped defaults                       0.125     0.099    0.052      5890    4.167   0.854     0.142    134
   lift=false                             0.094     0.130    0.050      1878    2.333   0.645     0.034    120

-- segment 20-99: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.380     0.266    0.154        40    6.490   1.270     0.008      -
   shipped defaults                       0.110     0.064    0.035      5758    4.570   0.766     0.120    189
   lift=false                             0.170     0.177    0.079       600    1.590   0.369     0.023    198

-- segment 100+: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.620     0.262    0.221        83    5.300   1.148     0.020      -
   shipped defaults                       0.250     0.054    0.050      5612    3.130   0.882     0.093    222
   lift=false                             0.350     0.136    0.080       436    1.430   0.298     0.034    273
```

## One knob at a time (`eval-sweep.txt`)

```
Recommendations evaluation  eligible users=2367  sampled=300  seed=42  hold-out=0.2  limit=50
variants: rank baseline | shipped defaults | rank_prior_weight=1.0 | rank_prior_weight=2.0 | max_subjects=10 | subject_multiplier=0.5 | calibrate_genres=false | candidate_size=100 | min_score=2.0 | pseudo_books=20 | min_support=3 | lift=false

-- segment 5-19: 96 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.188     0.295    0.116        28    6.760   1.433     0.005      -
   shipped defaults                       0.125     0.099    0.052      5890    4.167   0.854     0.142    137
   rank_prior_weight=1.0                  0.167     0.136    0.063      3253    4.594   0.832     0.115    136
   rank_prior_weight=2.0                  0.167     0.153    0.071      1831    4.594   0.856     0.093    135
   max_subjects=10                        0.094     0.069    0.035      5920    4.062   0.867     0.145    132
   subject_multiplier=0.5                 0.083     0.081    0.039      5935    4.146   0.931     0.138    133
   calibrate_genres=false                 0.094     0.099    0.046      5902    4.198   0.898     0.141     73
   candidate_size=100                     0.115     0.100    0.048      6047    4.073   0.859     0.143     79
   min_score=2.0                          0.104     0.095    0.047      5482    3.865   0.917     0.125    104
   pseudo_books=20                        0.115     0.099    0.048      5788    4.292   0.843     0.142    136
   min_support=3                          0.115     0.096    0.049      5468    3.562   0.939     0.141    131
   lift=false                             0.094     0.130    0.050      1878    2.333   0.645     0.034    125

-- segment 20-99: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.380     0.266    0.154        40    6.490   1.270     0.008      -
   shipped defaults                       0.110     0.064    0.035      5758    4.570   0.766     0.120    187
   rank_prior_weight=1.0                  0.140     0.119    0.056      3125    4.720   0.728     0.100    187
   rank_prior_weight=2.0                  0.190     0.121    0.061      1704    4.560   0.738     0.081    188
   max_subjects=10                        0.090     0.054    0.029      6012    4.200   0.799     0.123    179
   subject_multiplier=0.5                 0.120     0.074    0.040      5890    4.840   0.869     0.116    180
   calibrate_genres=false                 0.120     0.064    0.039      5768    4.640   0.804     0.120     74
   candidate_size=100                     0.100     0.064    0.037      5903    4.630   0.773     0.121     95
   min_score=2.0                          0.120     0.061    0.036      5864    3.990   0.917     0.108    114
   pseudo_books=20                        0.110     0.066    0.035      5789    4.640   0.767     0.120    186
   min_support=3                          0.100     0.083    0.046      5930    4.770   0.843     0.122    190
   lift=false                             0.170     0.177    0.079       600    1.590   0.369     0.023    197

-- segment 100+: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.620     0.262    0.221        83    5.300   1.148     0.020      -
   shipped defaults                       0.250     0.054    0.050      5612    3.130   0.882     0.093    223
   rank_prior_weight=1.0                  0.340     0.080    0.068      3557    3.540   0.850     0.079    223
   rank_prior_weight=2.0                  0.410     0.080    0.072      2434    3.660   0.850     0.070    222
   max_subjects=10                        0.220     0.045    0.037      5700    3.200   1.037     0.084    198
   subject_multiplier=0.5                 0.240     0.038    0.042      5695    3.210   1.127     0.086    201
   calibrate_genres=false                 0.230     0.053    0.047      5623    3.150   0.919     0.092     90
   candidate_size=100                     0.240     0.045    0.044      5716    3.120   0.884     0.093    122
   min_score=2.0                          0.210     0.034    0.039      5428    1.570   1.329     0.061    120
   pseudo_books=20                        0.250     0.053    0.050      5602    3.190   0.889     0.092    222
   min_support=3                          0.260     0.053    0.050      5670    3.540   0.863     0.097    237
   lift=false                             0.350     0.136    0.080       436    1.430   0.298     0.034    276
```

## Combinations (`eval-combos.txt`)

```
Recommendations evaluation  eligible users=2367  sampled=300  seed=42  hold-out=0.2  limit=50
variants: rank baseline | shipped defaults | rank_prior_weight=1.0  max_subjects=10 | rank_prior_weight=2.0  max_subjects=10  subject_multiplier=0.5 | lift=false

-- segment 5-19: 96 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.188     0.295    0.116        28    6.760   1.433     0.005      -
   shipped defaults                       0.125     0.099    0.052      5890    4.167   0.854     0.142    134
   rank_prior_weight=1.0  max_subjects=   0.146     0.155    0.067      3321    4.438   0.834     0.119    132
   rank_prior_weight=2.0  max_subjects=   0.198     0.174    0.077      2072    4.792   0.915     0.093    131
   lift=false                             0.094     0.130    0.050      1878    2.333   0.645     0.034    123

-- segment 20-99: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.380     0.266    0.154        40    6.490   1.270     0.008      -
   shipped defaults                       0.110     0.064    0.035      5758    4.570   0.766     0.120    190
   rank_prior_weight=1.0  max_subjects=   0.110     0.100    0.047      3347    4.630   0.754     0.103    183
   rank_prior_weight=2.0  max_subjects=   0.170     0.097    0.055      2243    4.640   0.826     0.084    178
   lift=false                             0.170     0.177    0.079       600    1.590   0.369     0.023    200

-- segment 100+: 100 of 100 sampled users evaluated
   variant                               hit@10 recall@50  ndcg@50 mean_rank   au_rep      kl  coverage     ms
   rank                                   0.620     0.262    0.221        83    5.300   1.148     0.020      -
   shipped defaults                       0.250     0.054    0.050      5612    3.130   0.882     0.093    226
   rank_prior_weight=1.0  max_subjects=   0.340     0.075    0.057      3912    3.520   0.982     0.078    204
   rank_prior_weight=2.0  max_subjects=   0.390     0.075    0.059      3490    3.650   1.152     0.073    191
   lift=false                             0.350     0.136    0.080       436    1.430   0.298     0.034    276
```

(Rows that appear in more than one run differ slightly in `ms` only; the metrics are identical
because the sample and the hold-out split are seeded.)

## The gate, on the 20-99 segment

Required: the engine beats BOTH baselines on hit@10 and recall@50, with `kl` at or below `lift=false`.

| | hit@10 | recall@50 | kl |
|---|---|---|---|
| `rank` baseline | 0.380 | 0.266 | 1.270 |
| `lift=false` baseline | 0.170 | 0.177 | 0.369 |
| shipped defaults | 0.110 | 0.064 | 0.766 |
| best single knob (`rank_prior_weight=2.0`) | 0.190 | 0.121 | 0.738 |
| best combination (`rank_prior_weight=2.0,max_subjects=10,subject_multiplier=0.5`) | 0.170 | 0.097 | 0.826 |

**Not met.** The shipped defaults trail `rank` and `lift=false` on hit@10, recall@50 and ndcg@50 in
every segment, and their `kl` (0.766) is about twice `lift=false`'s (0.369). The best variant,
`rank_prior_weight=2.0`, beats `lift=false` on hit@10 (0.190 against 0.170) but not on recall@50
(0.121 against 0.177), does not come near `rank` on either, and misses the `kl` condition. On
20-99 no variant clears even one baseline on both metrics. (On 5-19 the combination
`rank_prior_weight=2.0,max_subjects=10,subject_multiplier=0.5` beats `lift=false` on both, and
`rank` on hit@10 only; that is not the gate segment.) Per the decision rule the knobs were not turned
further and the initializer is unchanged.

## Reading

Plain language, and what was and was not tested.

- **The rank prior is the only knob that moves anything much.** Raising `rank_prior_weight` from 0.3
  to 1.0 to 2.0 lowers the mean global rank of the page from about 5,760 to 3,125 to 1,704 on the
  20-99 segment and lifts recall@50 from 0.064 to 0.119 to 0.121. That is the hold-out metric
  rewarding famous books, as expected, but the page is still nowhere near `lift=false` (mean rank
  600) or `rank` (40).
- **Subjects are not the cause on their own.** `max_subjects=10` made hit@10 slightly worse in all
  three segments; `subject_multiplier=0.5` was mixed (a little better on 20-99, worse on 5-19 and
  on recall@50 in 100+). Combining either with a heavier prior added nothing over the prior alone.
- **Query-shape knobs are noise at this sample size.** `candidate_size=100`, `min_score=2.0`,
  `pseudo_books=20` and `min_support=3` each moved a metric by 0.01 to 0.02, inside what 100 users
  can resolve (one user is 0.01 on hit@10). `min_score=2.0` cuts the 100+ segment's coverage and
  raises its `kl` by half (0.882 to 1.329), so it removes useful candidates.
- **Genre calibration is neutral to slightly helpful.** Turning it off raises `kl` on 20-99
  (0.766 to 0.804) and 5-19 (0.854 to 0.898), and costs nothing in hits within noise. It does not
  explain the `kl` gap to `lift=false`: that gap is the engine's pages carrying different genres
  than the user's history, not the re-ranker failing to pull them back.
- **Why the pages are deep.** Mean rank 5,800 in a ranked pool of 21,392 is roughly "half way down
  the pool". The taste query sums boosts over up to 38 category clauses (8 genres, 25 subjects, 5
  locations), and lift weights favour rare categories by construction (`ln(s/p)` grows as `p`
  shrinks), so books matching a handful of rare subjects outscore books matching common genres.
  The normalization by `sqrt(category count)` then favours thinly tagged books. A look at one
  20-99 user (`recommendations:show USER=5217`) found a coherent list (Steppenwolf, As I Lay Dying,
  Molloy, The Castle, Under the Volcano) with several rank-7,000-to-12,000 picks mixed among
  top-200 books, including a second edition of a book the user may already have under another
  record (Crime And Punishment at rank 9,302). I did not test any of these causes in isolation.
- **What the metric rewards.** A hidden favorite is a favorite the user had put on a list, and
  favorites skew heavily toward the canon, so global rank alone gets 0.38 hit@10 on 20-99. A
  deliberately personalized engine that avoids the canon is penalized by construction, which is why
  `mean_rank` has to be read beside hit rate. But `lift=false` shares the same pool and the same
  metric and gets recall@50 of 0.177 at mean rank 600, so the bias explains part of the gap, not all
  of it: an engine can be personalized and still shallow, and ours currently is not.
- **Sample size.** 100 users per segment: differences below about 0.03 on hit@10 or recall@50 are
  not resolvable. Everything said above rests on gaps larger than that, apart from the
  query-shape knobs, which I called noise.

### What the controller might take to Shane

Not run, because the decision rule says to stop. These are the experiments the tables point at,
in the order I would try them if allowed:

1. A cap on how far the lift weight can run for rare categories (for example a floor on `p_c`, or
   clipping `pos_c`), so a handful of rare subjects cannot outvote the genres.
2. A larger default `rank_prior_weight` (the one lever that clearly moved metrics), accepting that
   it makes the engine more canon-leaning; or a "deep cuts" setting that exposes the trade-off to
   the user (spec §9.4).
3. Ranked-only `p_c` (spec §9.4): the catalog share used in the lift counts all 160k books, while the
   candidate pool is the 21k ranked ones, so a category rare in the catalog may be common in the pool.
4. Re-examining whether the gate is the right bar: it compares a profile engine against a
   canon-only list on a metric that rewards the canon.
