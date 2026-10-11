# Recommendations: the first live page was the canon (2026-10-10)

The day the collaborative model went live in production, the owner opened his recommendations
page and saw the all-time top 100 minus the books on his shelf, the same twenty books under
Safer bets, Balanced and Deep cuts. This record reproduces that page, names the three causes,
shows the page after the fix, and records what the fix costs on the offline harness.

Reproduced in development (a restore of production's books data, with a full model loaded) for
user 1141 with production's criteria: top 15,000, poetry, children's books and young adult
excluded, no year or length filter. 312 positives (51 favorites, 83 read, 101 rated). Script:
`Recommendations::Engine.call` with the adapter's `criteria_for` replaced in memory, the
controller's `criteria.engine_overrides` merge applied by hand.

## Before: the shipped defaults as of PR #376

Quality prior on (`quality_scale: 1000, quality_floor: 0.3`), fusion rank prior 0.3, the
collaborative list at weight `n / (n + 10)` = 0.97 for this shelf. All three depths, byte for byte:

```
 1. A Clockwork Orange              rank 156   because you loved Slaughterhouse-Five
 2. To the Lighthouse               rank 25    matches stream of consciousness + Death
 3. All Quiet on the Western Front  rank 89    because you loved The Master and Margarita
 4. A Passage to India              rank 77    because you loved Rebecca
 5. Naked Lunch                     rank 258   matches Banned books + Postmodern
 6. Solaris                         rank 306   because you loved Flowers for Algernon
 7. To Kill a Mockingbird           rank 16    ranked
 8. Lady Chatterley's Lover         rank 184   because you loved Rebecca
 9. V                               rank 448   matches Encyclopedic + Postmodern
10. Crime and Punishment            rank 12    because you loved The Brothers Karamazov
11. Wuthering Heights               rank 14    because you loved Great Expectations
12. War and Peace                   rank 13    because you loved The Brothers Karamazov
13. On the Road                     rank 43    because you loved Slaughterhouse-Five
14. Anna Karenina                   rank 10    because you loved The Brothers Karamazov
15. The Scarlet Letter              rank 70    matches New England
16. Pride and Prejudice             rank 15    ranked
17. The Diary of a Young Girl       rank 116   because you loved In Cold Blood
18. Of Mice and Men                 rank 170   ranked
19. Life, a User's Manual           rank 267   matches Encyclopedic + Postmodern
20. Dr. Jekyll and Mr. Hyde         rank 229   because you loved Dracula
```

The taste list alone (`collaborative=false`) was 13 books, not 20: `min_score` (1.0) was applied
after the quality prior's multiplier, so every candidate below rank ~2,000 had already lost two
thirds of its score and fell under the threshold. With the same user's development criteria
(published after 2000 as well), the taste list was empty and the page was rank-ordered filler.

## Why

1. **The quality prior.** `taste × (0.3 + 0.7 × 1000 / (1000 + rank))`: a rank-20 book keeps 99% of
   its taste score, a rank-5,000 book keeps 42%, a rank-12,000 book 35%. With no year filter the
   pool is the canon, and the canon wins every comparison it is in. The depth setting moved only
   the floor (0.1 / 0.3 / 0.5), which re-orders nothing among top-ranked books.
2. **The collaborative list at near-full weight.** EASE's neighbours of The Brothers Karamazov are
   Anna Karenina, War and Peace and Crime and Punishment; of Rebecca, A Passage to India and
   Lady Chatterley's Lover. Correct, and useless to someone who has read widely: for a shelf of
   312 positives the list carried weight 0.97 against taste's 1.0 and took eleven of the twenty
   slots.
3. **The threshold after the prior**, which thinned or emptied the taste list and left the page to
   the other two.

The harness had scored the prior a win (`recommendations-2026-10-08.md`: hit@10 up 1.6x on the
20-99 segment) and the collaborative list a large win (`recommendations-collaborative-2026-10-10.md`:
hit@10 0.32 → 0.74 on 100+). Both are true and both are the same fact: the held-out favourites a
hold-out can test against are mostly famous books, so anything that pushes famous books up scores
well. The 2026-10-08 record said so ("the hold-out itself still rewards the canon") and listed the
rank-percentile metric that would separate personalisation from popularity as not built. It is
still not built. The page the owner looks at is the acceptance test the harness is not.

## After: the defaults shipped 2026-10-10

Quality prior off (`quality_scale: 0`), rank prior 0.3, `collaborative_weight: 0.25` (0.24 for this
shelf), `min_score` judged on the taste score inside the prior's script.

Balanced:

```
 1. The Alteration                        rank 5921   matches Totalitarianism + Alternate History
 2. Toward The End Of Time                rank 12204  matches nuclear war + Apocalyptic
 3. Naked Lunch                           rank 258    matches Banned books + Postmodern
 4. White Shroud                          rank 2729   matches Immigrants + Death
 5. The Carnival Of Destruction           rank 8693   matches Apocalyptic + Dystopian
 6. All Quiet on the Western Front        rank 89     because you loved The Master and Margarita
 7. Dealing With Dragons                  rank 10777  matches Wizards + Magic
 8. Alas, Babylon                         rank 14816  matches nuclear war + Apocalyptic
 9. Shah Of Shahs                         rank 7501   matches Reportage + Middle East History
10. Memoirs of Martinus Scriblerus        rank 2233   matches Parody + Postmodern
11. When The Wind Blows                   rank 5037   matches nuclear war + Death
12. Stranger Things Happen                rank 5925   matches Magic + Death
13. A Clockwork Orange                    rank 156    because you loved Slaughterhouse-Five
14. A Fairy Tale Of New York              rank 4331   matches Death + Postmodern
15. At Last                               rank 5569   matches Great Britain + Death
16. Giles Goat-Boy                        rank 2814   matches Parody + Encyclopedic
17. At Twilight They Return               rank 5345   matches Magic + Death
18. The Island Of The Day Before          rank 12164  matches shipwreck + Postmodern
19. The Hearing Trumpet                   rank 1800   matches Magic + Postmodern
20. When We Cease To Understand The World rank 4664   matches Physics + Encyclopedic
```

Safer bets (quality prior on, 1000 / 0.3) begins A Clockwork Orange, All Quiet on the Western
Front, To the Lighthouse, A Passage to India, Naked Lunch, Solaris, Lady Chatterley's Lover, V,
Life a User's Manual, Ada or Ardor: the canon that fits the profile, with the model's picks on top,
and a full twenty because the threshold no longer sees the multiplier. Deep cuts (quality prior
off, rank prior off) begins The Alteration, Toward the End of Time, White Shroud, The Carnival of
Destruction, Dealing With Dragons, Alas Babylon: the Balanced list with the three canon books
pushed down. Three settings, three pages.

The profile behind this: genres Banned books, Apocalyptic, Hard Science Fiction, Westerns,
Encyclopedic, Dystopian, Postmodern; subjects nuclear war, post-apocalypse, reportage,
totalitarianism, alternate history, alien contact. Every Balanced pick but the two model picks
names two of those.

## What it costs on the harness

`bin/rails recommendations:eval USERS=300 SEED=42 VARIANTS="collaborative=false;
collaborative=false,quality_scale=1000; quality_scale=1000,collaborative_weight=1.0"` on the
development model, which saw the held pairs, so every row with the model is inflated the same way
and only the differences between rows mean anything. "shipped defaults" is this change; the fourth
variant is the defaults it replaces.

```
segment 5-19 (91 users)                              hit@10 recall@50 ndcg@50 mean_rank coverage
   rank (the top of the ranking, no taste)            0.209     0.319   0.119        28    0.005
   shipped defaults                                   0.099     0.092   0.041      5708    0.129
   collaborative=false                                0.055     0.087   0.034      5347    0.127
   collaborative=false  quality_scale=1000            0.198     0.201   0.095       896    0.060
   quality_scale=1000  collaborative_weight=1.0       0.286     0.271   0.134       789    0.058
   frequency baseline                                 0.066     0.139   0.056      1924    0.032
segment 20-99 (100 users)
   rank                                               0.340     0.300   0.148        40    0.010
   shipped defaults                                   0.110     0.077   0.040      6086    0.113
   collaborative=false                                0.080     0.048   0.025      5566    0.110
   collaborative=false  quality_scale=1000            0.230     0.158   0.078       897    0.059
   quality_scale=1000  collaborative_weight=1.0       0.510     0.412   0.228       543    0.043
   frequency baseline                                 0.150     0.202   0.082       837    0.027
segment 100+ (100 users)
   rank                                               0.550     0.271   0.223        77    0.018
   shipped defaults                                   0.240     0.115   0.084      5391    0.095
   collaborative=false                                0.210     0.054   0.050      5631    0.089
   collaborative=false  quality_scale=1000            0.350     0.118   0.091      2669    0.070
   quality_scale=1000  collaborative_weight=1.0       0.690     0.401   0.299      1035    0.048
   frequency baseline                                 0.280     0.152   0.083       295    0.033
```

Three readings.

- **The bare ranking beats every personalised variant on hit@10 in every segment** (0.55 on 100+
  against 0.69 only for the old defaults, which lean on the ranking). The metric is measuring how
  famous our picks are. A metric on which "recommend the top 50 of all time to everyone" is the
  strongest taste-free baseline cannot judge personalisation.
- **The trade is real and large on that metric.** Against the defaults it replaces, this change
  gives up more than half of hit@10 and recall@50 in every segment, and the pages move from a mean
  rank around 500-1,000 to around 5,500-6,000. Coverage (the share of the pool that reaches any
  page) doubles. Against the frequency baseline the shipped defaults are below on hit@10 in the
  two larger segments; spec 1's §9.2 bar is not met on this harness any more, and this record
  overrides it: the bar was written before anyone had looked at a live page.
- **Mean rank near 6,000 is a choice, not an accident.** With the prior off, a book that matches
  the profile well outranks a famous one that matches it a little, wherever it sits in the
  ranking. Readers who want the famous end have Safer bets, which is the old default; the owner's
  Safer bets page is in the previous section. Whether Balanced should sit somewhere between (a
  small `quality_scale`, say 100 with floor 0.5) is a question for the next look at a live page,
  not for this harness.

## Still open

- A harness metric that scores a recovered favourite by its rank percentile, so recovering
  Alas, Babylon counts for more than recovering Anna Karenina. Until it exists, the harness cannot
  judge a change like this one and the owner's page has to.
- The collaborative list still ignores the quality prior (spec 2 §8.3); at weight 0.25 that is two
  picks in twenty.
- Subject "Juvenile" sits in this profile (All Quiet on the Western Front matched "Reportage +
  Juvenile") although the reader excludes children's books; the profile is built from what was
  read, the exclusion applies to what is recommended, and the two are not reconciled.
