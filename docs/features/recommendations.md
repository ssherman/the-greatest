# Book Recommendations

## Overview

Personalized book recommendations for a signed-in user, ported from the legacy site's paid
feature and rebuilt around a **taste profile**: which categories appear in the books a reader
loves far more often than they appear in the catalog, with ratings as signed weights. The engine
is domain-agnostic; books is the only adapter. Design records:
`docs/superpowers/specs/2026-10-07-book-recommendations-design.md` (spec 1: the engine and the
pages) and `docs/superpowers/specs/2026-10-09-book-recommendations-collaborative-design.md`
(spec 2: the collaborative signal).

State of delivery: spec 1 is done (preferences store, engine, harness, tuning, the results,
wizard and settings pages). Spec 2's first increment (export, trainer, load, signal, measured in
development) is done; its second, the home-server timer that trains in production, is built
(`deployment/home-server/guest/recommender-train.sh`); the one-time setup that gives production its
first model is `docs/launch-todo.md`, section 3.

Where it lives:

- `app/lib/recommendations/` is the generic engine; `app/lib/recommendations/books/adapter.rb`
  is the only place that names a books model.
- `Search::Books::Search::BookRecommendations` is the one OpenSearch query (the adapter calls it);
  `CategoryCountNormalization` is the shared score-normalization wrapper it and `BookSimilar` use.
- `config/initializers/recommendations.rb` holds every knob (`config.x.recommendations`).
- `lib/tasks/recommendations.rake` is the harness (and the local collaborative loop);
  `data_migration:recommendation_configs` is the legacy migration.
- The collaborative signal: `Recommendations::Export`, `Store`, `LoadModel`, `NeighborScores`,
  `Signals::Collaborative`, `Books::PositivePairs`, the two Sidekiq jobs under
  `app/sidekiq/recommendations/`, and the Python trainer in `data-sources/src/recommender/`.

## Pipeline

```
Recommendations::Engine.call(user:, domain:, limit:, overrides: {})
  adapter (Registry.adapter_class_for(domain))
  1. interactions     Adapter#interactions            -> [Interaction(item_id, weight, kind, rating)]
  2. profile          ProfileBuilder                  -> Profile (genres/subjects/locations, demoted, ...)
  3. signals          Signals::TasteProfile           -> ranked Candidates (one OpenSearch query)
                      Signals::Collaborative          -> ranked Candidates (one SQL read + one OpenSearch filter)
  4. fusion           Fusion                          weighted reciprocal-rank fusion + rank prior
  5. re-ranking       Reranker::SeriesRule -> AuthorCap -> GenreCalibration
  6. explanations     Explainer                       -> Reason(type, ids) per item
  -> Result(success?, data: {items: [{item, item_id, rank, score, reason}], profile:, signals_used:, fallback:}, errors:)
```

`overrides:` replaces any knob for one call (`Recommendations::Config.resolve`; an unknown key
raises). `interactions:` and `excluded_ids:` can be passed in, which is how the harness trains on
a subset of a user's history.

**Failure.** A signal that raises is logged (class plus a short backtrace) and dropped from
`signals_used`. If no personalized signal returns anything (empty profile, outage), the engine falls
back to `Signals::RankOnly` (the filtered pool in global-rank order, `fallback: true`). If that fails
too the result is an empty success, so a page can show "unavailable" and never a 500. The engine
also skips any signal whose weight is not positive, before calling it.

## Adapter contract

A domain adapter (`Registry::DOMAIN_ADAPTERS`) answers, for the engine:

| Method | Returns |
|---|---|
| `interactions(user)` | `[Interaction]`, already signed-weighted (profile math below) |
| `shelved_item_ids(user)` | every list item (custom lists included) and every reviewed item: a hard exclusion |
| `criteria_for(user)` | the user's `RecommendationCriteria` (unsaved defaults when they have no config) |
| `categories_for(item_ids)` | `{item_id => [CategoryFact(id, category_type, item_count)]}` for scoring types only |
| `catalog_size` | N for the lift computation: non-provisional books, or the ranked pool when `lift_population` is `"ranked"` (then `categories_for` counts over the same pool) |
| `type_category_ids` | `{"Fiction" => id, "Nonfiction" => id}`, resolved by name, memoised |
| `item_facts(item_ids)` | `{item_id => ItemFact(author_ids, genre_ids, series_predecessor_id, rank_position)}` |
| `load_items(item_ids)` | hydrated records with the card preloads, indexed by id |
| `search_candidates(profile:, criteria:, excluded_ids:, size:)` | taste-query `[Candidate]` |
| `rank_ordered_candidates(criteria:, excluded_ids:, size:)` | the same pool in global-rank order |

## Signal contract

```ruby
Signal#call(profile:, interactions:, criteria:, excluded_ids:, size:) -> [Candidate(item_id:, score:, rank_position:, evidence: {})]
Signal#weight(positive_count)  -> Float    # fusion weight for this user; <= 0 means "skip"
Signal#available?              -> Boolean  # false -> skipped
```

Evidence: `{taste: true}` from `TasteProfile`; `{term: Float}` from `Collaborative`, plus
`because_of: item_id` when the shelf book that contributed most is loved (see "Collaborative
signal"). The collaborative fusion weight is `collaborative_weight × n / (n + collaborative_half_point)`,
`n` the user's positive count, so it grows with the shelf toward `collaborative_weight` (0.25 against
taste's 1.0: at 1.0 the model's neighbours of famous books, which are more famous books, took most of
a large reader's page; see "Known gaps").

## Profile math

**Interaction weights** (`Adapter#interactions`):

| Signal | Weight |
|---|---|
| Favorite | `+2.0`, plus `+0.5` for the top 10 of a `manually_ordered` favorites list |
| Read or reading | `+0.4` |
| Want to read | `+0.2` |
| Rating `r` (any numeric granularity) | `0.75 × (r − 3)`, so 5 is +1.5, 4 is +0.75, 3 is 0, 2 is −0.75, 1 is −1.5 |

A book on several lists takes its highest list weight, and its rating weight is added. **A review
(rated or text-only) on a book that is on no list implies the read weight (0.4) as its base**, plus
the rating weight if there is one. Custom lists contribute nothing but exclusion.

**Category lift** (`ProfileBuilder`). For category `c` with catalog share
`p_c = item_count_c / catalog_size`, over the positively weighted books:

```
W⁺    = Σ w_i                     (w_i > 0)
n_c   = Σ w_i · [c ∈ book_i]      (w_i > 0)
s_c   = (n_c + m · p_c) / (W⁺ + m)      m = pseudo_books = 10
pos_c = min(lift_cap, max(0, ln(s_c / p_c)))      (no min when lift_cap is 0)
```

The `m` term shrinks short histories toward the catalog so one favorite with many subjects cannot
become the whole profile. `lift_cap` bounds how far a rare category can run (positives only; the
negative profile is never capped, so demotion keeps working at any cap): without it a subject on
0.01% of the catalog scores `ln(s/p)` several times a common genre's, so a handful of rare subjects
can outvote every genre. `lift_population` picks the population `p_c` is measured over: `"catalog"`
(every non-provisional book, the default) or `"ranked"` (the ranked pool the query draws from, so a
category rare in the catalog but common among ranked books is not over-lifted). **Support:** a category needs `min_support` (2) distinct positive books
once the user has `min_support_history` (5) or more positive books, else 1. With `lift: false` the
weight is the raw share `n_c / W⁺` instead (the harness baseline that approximates the legacy
engine).

**Negative profile.** The same computation over negatively weighted books (`|w_i|`) gives `neg_c`;
`net_c = pos_c − γ · neg_c` with `γ = negative_gamma = 0.5`. A category with `pos_c = 0` and
`neg_c ≥ demote_threshold` (1.0) goes to `profile.demoted`: the query scales matching books down, it
never removes a genre over one bad book.

**Selection and scaling.** Keep the top 8 genres, 25 subjects, 5 locations by `net_c > 0`. Query
boost is `net_c × type_multiplier` (genre 1.0, subject 0.8, location 0.4).

**Fiction and Nonfiction are never scored.** They are a book type: resolved by name and excluded
from the lift computation. The profile records `fiction_share` (positive weight on Fiction-tagged
books over books tagged either), which the query and the genre calibration use. `Profile` also
carries `genre_distribution` (each positive book spreads its weight evenly over its genres, type
genres included) and `counts`.

## The query

One OpenSearch query against `Search::Books::BookIndex`; no mapping change.

1. **Filter (unscored):** `ranked: true` plus the criteria's book lengths, year range,
   `max_ranked_position`, included categories (`CriteriaClauses`, shared with the advanced search).
2. **Must not:** provisional books, excluded categories, and the ids of every shelved and
   reviewed book.
3. **Should (scored):** one `term` per selected category with `boost = net_c × multiplier`, as
   separate clauses so shared categories add. `minimum_should_match: 1`.
4. **Fiction share as a soft preference:** at `fiction_share ≥ 0.9` demote Nonfiction-only books; at
   `≤ 0.1` demote Fiction-only books.
5. **Demotion:** a `boosting` query whose negative half is the demoted categories plus the type
   clause from (4), `negative_boost: 0.3`.
6. **Normalization:** `function_score` dividing by `sqrt(max(similarity_category_count, floor))`,
   floor `normalization_floor` (10), so a heavily tagged book cannot win on volume.
7. **Quality prior** (when `quality_scale` > 0; off by default since 2026-10-10, on under the
   Safer bets depth): a second `function_score` multiplying by
   `quality_floor + (1 − quality_floor) · quality_scale / (quality_scale + ranked_position)`: 1 at
   the top of the ranking, half way to the floor at rank `quality_scale`, the floor far down. This
   puts the global ranking inside the score that builds the pool; the fusion rank prior below can
   only re-order what the pool already holds. `min_score` is enforced inside this script on the
   taste score, before the multiplier (the body's `min_score` becomes an epsilon that drops the
   zeros the script returns), so the prior re-orders the pool and never empties it. Until
   2026-10-10 the threshold came after the multiplier, and a reader whose criteria left only deep
   books (published after 2000, say) had no taste list at all.
8. `size: candidate_size` (300), `min_score` (1.0), `_source: false`.

## Fusion, re-ranking, explanations

**Fusion** is weighted reciprocal-rank fusion, `Σ w / (rrf_k + rank)` with `rrf_k = 60`. Taste
weight 1.0. The **rank prior** is one more list of the fused items ordered by global rank, weight
`rank_prior_weight` (0.3); it can only re-order items a personalized signal returned and never
introduces a book. The quality prior inside the query (step 7 above) is what decides which books
reach fusion at all; this prior is the smaller, second lever.

**Re-ranker passes, in order:**

1. `SeriesRule`: a book with a numbered series predecessor is kept only if the predecessor is a
   favorite, read, reading or rated book (want-to-read does not unlock it). The series' first book
   stays if it is itself a candidate. It runs before the cap so the cap never spends an author's
   slots on sequels this rule then drops (which could lose the series opener too).
2. `AuthorCap`: at most `max_per_author` (2) per page; extras are skipped, not demoted.
3. `GenreCalibration`: greedy selection maximising `(1 − λ)·relevance − λ·KL(history ‖ page)`, with
   `λ = 0.3`, relevance the fused score over the best fused score, and the page distribution
   smoothed with `α = 0.01` of the history. A candidate with no genres scores `KL = −ln α` on an
   empty page (q = 0, so q̃ = αp) and the current page's KL afterwards. Switch off with
   `calibrate_genres: false`. Then `limit` is taken.

**Explanation precedence** (`Explainer`, one `Reason(type, ids)` per item, first that applies):

1. `because_of(item_id)`: collaborative evidence naming a favorite or a book rated at least
   `because_of_rating` (4). Rendered as "Because you loved *Title*"; reason names are keyed by
   `[kind, id]` (`[:item, id]` here, `[:category, id]` for interests) because a book id and a
   category id can be the same integer.
2. `interests(category_ids)`: the two highest-weight profile categories the book carries, each with
   weight at or above `explain_threshold` (1.0), so the page never says "because you like Fiction".
3. `ranked(position)`: "Ranked #N of all time" when neither is strong.

## Collaborative signal

Readers-like-you, from an item-neighbour model (EASE) trained on who shelved what. Spec 2; measured
in `docs/data-quality/recommendations-collaborative-2026-10-10.md`.

**What a positive is.** A favorite, read or reading list item, or a review rated at least
`collaborative_min_rating` (3). Want-to-read and ratings of 1-2 are never positives. A favorite, read
or reading entry stays a positive even when the same book is rated 1 or 2: the rating floor
applies to reviews of books on none of those lists. The definition lives
in two places that tests hold equal: the export's SQL (`Recommendations::Books::PositivePairs`) and
the serving side's Ruby (`Interaction#trainable?(min_rating:)`).

**Three legs and a store.** Each leg reads and writes files through `Recommendations::Store`
(`Local`, a directory, for development; `R2`, a private bucket, in production). The Python side
has the same two stores, read from the same variable names (`RECOMMENDATIONS_R2_*` in `secrets/home-server.env`; there the endpoint is required, since the VM has no `STORAGE_ENDPOINT`). The two Rails jobs build the store from the three
`RECOMMENDATIONS_R2_*` variables (access key, secret key, bucket; the endpoint defaults to `STORAGE_ENDPOINT`): with none set they log "recommendations store not configured;
skipping" and return, so a deploy before the bucket exists is quiet; with only some set they raise
`Store::NotConfigured`. The rake tasks without `DIR` use `Store.default`, which raises in both cases.

1. **Export** (Rails, `Recommendations::ExportInteractionsJob`, nightly 02:30 UTC): every positive pair,
   streamed through a server-side cursor, written as
   `recommendations/books/interactions/<date>.csv.gz` (`user_id,item_id`, sorted, gzipped); then
   `interactions/latest` is pointed at it. About 1.6M rows in development.
2. **Train** (Python, `recommender.cli run`, on the home server): pull `latest`, drop books with
   fewer than `--min-readers` readers and users with fewer than 2 positives, fit EASE, keep each
   book's top `--top-k` positive neighbours, write `model/<version>.csv.gz`
   (`item_id,neighbor_id,weight`) and `model/<version>.json` (the manifest, with the trainer's own
   hit@10 / recall@50). The version is the export name. `model/latest` moves only when the gate
   passes: no previous model, or hit@10 at least `--gate-ratio` × the previous one; an export older
   than `--max-export-age-days` or not newer than the published model is refused.
3. **Load** (Rails, `Recommendations::LoadModelJob`, hourly at :15): read `model/latest`; if that
   version is new, insert it and swap it in.

**The two tables and the swap.** `recommendation_models` (`RecommendationModel`: domain, version,
manifest, state `loading`/`active`/`retired`; spec 2 called it `Recommendations::Model`) and
`recommendation_item_neighbors` (`RecommendationItemNeighbor`: model, item, neighbour, weight;
indexed on model and item). `LoadModel` takes a per-domain advisory lock, inserts the rows under a
`loading` row in batches of 10,000, then in one transaction checks the table's row count against
the manifest, marks the new model `active` and the previous one `retired`, and afterwards deletes
the retired rows. A short file never replaces a good model, a crashed load is retried from scratch,
and a version already loaded is skipped, so the hourly job is idempotent.

**Per request.** `available?` is true when `collaborative` is on and the domain has an active model.
`call` takes the user's trainable shelf (the interactions passing `trainable?`) and runs one
grouped read: for every neighbour of a shelf book, not itself excluded, sum the stored weights,
keep the shelf book with the largest weight as the candidate "because of" book, order by the sum,
and take `collaborative_overfetch × candidate_size` rows (`NeighborScores`). Those ids go through
the ranked-pool query with an `ids` filter (`Adapter#filter_candidate_ids`), so length, year range,
rank cap and included and excluded categories apply to the collaborative list exactly as they do to the taste list. The depth setting (Safer bets / Deep cuts) does not: it shapes the taste list only, through the quality prior (`wrap_in_quality_prior`), and `ranked_only(ids:)` carries no prior. The collaborative list is ordered by co-readership score and gets its canon only through the rank prior in fusion.
The survivors, in collaborative-score order, are the signal's candidates; fusion weights them
`n / (n + collaborative_half_point)`. The evidence carries `because_of` only when that book is a
favorite or rated at least `because_of_rating` (4), so the page never says "Because you loved" a
book the reader merely read. No active model, or `collaborative: false`, means the page is exactly
the taste-only engine.

**The local loop**, from `web-app/` (Python from `data-sources/`, after
`uv sync --locked --extra fetcher --extra recommender`):

```bash
bin/rails recommendations:export DIR=tmp/recommendations HOLDOUT_SEED=42 HOLDOUT_USERS=300 HOLDOUT_FRACTION=0.2
uv run python -m recommender.cli train --input ../web-app/tmp/recommendations/recommendations/books/interactions/<name>.csv.gz \
  --output-dir ../web-app/tmp/recommendations/recommendations/books/model --name <name>
bin/rails recommendations:load DIR=tmp/recommendations VERSION=<name>
bin/rails recommendations:eval USERS=300 SEED=42 FRACTION=0.2 VARIANTS="collaborative=false"
bin/rails recommendations:show USER_ID=<id> LIMIT=20
```

`<name>` is what the export prints (`<date>-holdout-<seed>-u<users>-f<fraction>`, e.g. `2026-10-10-holdout-42-u300-f0.2`). For a model trained on everything, export
without the `HOLDOUT_*` variables, run `uv run python -m recommender.cli run --store-dir
../web-app/tmp/recommendations --work-dir <scratch dir>` (which moves `model/latest`), and load
without `VERSION`. In development the train takes about 20 s and 3.2 GiB; the load about 14 s.
`recommendations:load` is the one harness task that writes: it replaces the development database's
active model (and deletes the previous one), so leave a full model loaded when you are done.

**Production** runs the same three legs with `Store::R2`: the two Rails jobs on the Sidekiq cron,
and the trainer as the `recommender` compose service under `recommender-train.timer` (04:00 UTC, and
20 minutes after boot) on the home server's `ol` VM, pinging the healthchecks.io check
`recommender-train` (`docs/features/home-server.md`). Nothing on the home server listens, and nothing
in Rails calls it; if it is off, the model goes stale, never down. Until the bucket's values are in
both secrets files, the Rails jobs log a skip, the timer logs `RECOMMENDATIONS_R2_* not set` and exits,
and the signal stays unavailable. The launch steps are `docs/launch-todo.md`, section 3.

**Time zones.** The Sidekiq crons run in the Rails server's zone, which is UTC (the app sets no
`config.time_zone`), so "02:30" is 02:30 UTC. The `ol` VM's clock is UTC too, so the 04:00 train runs
1.5 h after the export, an hour after the 03:00 dump refresh (a refresh that starts a build holds
the lock, and the train defers to the next day). The export's file name and the age check
use UTC dates.

## Preferences store

`recommendation_configs` (`user_id`, STI `type`, `criteria` jsonb; unique on `(user_id, type)`).
`RecommendationConfig` is the base; `Books::RecommendationConfig` the books subclass, looked up by
`RecommendationConfig.subclass_for(domain)`. `for_user` is find-or-initialize, never create, so a
read does not write. `Books::RecommendationCriteria` wraps the JSON. Its keys are a subset of
`Books::SavedSearchCriteria` with the same names: `included_category_ids`, `excluded_category_ids`,
`genre_match_mode`, `book_length`, `first_year_published_gt`, `first_year_published_lt`,
`max_ranked_position`. `ranked` is pinned true; an unparseable value matches nothing rather than
everything.

`data_migration:recommendation_configs` (in `data_migration:all`) copies the legacy table through
`Services::BooksMigration::RecommendationConfigMigrator`: category ids are remapped through
`legacy_id_maps`, unmapped ids are dropped and counted, `exclude_locations` is dropped, and the
write is an upsert on `(user_id, type)`. It is a **repeating** launch step (`docs/launch-todo.md`).
The development database holds no rows, so the harness runs everyone on default criteria.

## Pages

Routes are global (`/recommendations`, `/recommendations/wizard/1..4`, `/recommendations/search`,
`/recommendations/settings`, `/recommendations/reset`); `RecommendationsController` resolves the
domain from `Current.domain`, 404s on a host with no `Registry` entry, and never caches. Books data
for the pages comes from `Recommendations::Books::Pages` (shelves for the wizard, the search box,
names behind ids, the settings summary); books markup lives in `app/views/recommendations/books/`.

| Visitor | `/recommendations` | Settings form |
|---|---|---|
| Signed out | pitch | — |
| Free account | `free_limit` results, side panel, member pitch | rendered, every field disabled, "Become a member" replaces Save; the POST is refused server-side (`require_membership!(:book_recommendations)`) |
| Member | `member_limit` results | editable |

Stored settings, depth included, apply to free accounts as well as members; a free account can
reset them but not edit them. The step-3 unrated list and the already-rated list are each capped
at 50 (`Recommendations::Books::Pages::UNRATED_LIMIT`, `RATED_LIMIT`).

A signed-in user with no favorite, read or reading item and no rating is sent to wizard step 1; steps 3 and 4 bounce
to step 2 until one exists. Steps 1 and 2 search through `GET /recommendations/search`, a Turbo
frame (`target: "_top"`) of `Books::CardComponent` cards whose list widget adds the book. Step 3
rates through `Reviews::WidgetComponent`. The results page shows `rank_position` on each card and
one `Recommendations::ReasonComponent` line beneath; `@state` is `:ok`, `:no_matches` (engine
succeeded, nothing matched) or `:unavailable` (a signal raised: `data[:degraded]`).

**Depth** is the one setting the spec did not list: stored as `criteria["depth"]` (`safe` or
`deep`; balanced stores nothing) and mapped by `RecommendationCriteria#engine_overrides` to engine
overrides through the `depth_overrides` knob: Safer bets turns the quality prior on
(`quality_scale: 1000, quality_floor: 0.3`), Deep cuts drops the fusion rank prior
(`rank_prior_weight: 0`), Balanced follows the initializer (both priors as shipped: quality off,
rank 0.3). Until 2026-10-10 depth moved only `quality_floor` under a prior that was always on, and
the three pages were the same books (`docs/data-quality/recommendations-canon-2026-10-10.md`).

## Harness

Read-only against the development database, except `recommendations:load`; needs the local
OpenSearch. Every knob is a per-call
override, and `eval` rebuilds each variant's training interactions under that variant's config (the
weight knobs act when interactions are built), so one process sweeps a range.

```bash
bin/rails recommendations:show USER_ID=123 [LIMIT=50] [VARIANTS="lift=false; calibrate_genres=false"]
bin/rails recommendations:eval [USERS=500] [SEED=42] [LIMIT=50] [FRACTION=0.2] [VARIANTS="..."]
bin/rails recommendations:export [DIR=tmp/recommendations] [HOLDOUT_SEED=42 HOLDOUT_USERS=500 HOLDOUT_FRACTION=0.2]
bin/rails recommendations:load [DIR=tmp/recommendations] [VERSION=<name>]
```

`export` and `load` are the collaborative signal's first and last legs (see "Collaborative
signal"); without `DIR` they use R2 and refuse to run unless it is configured. `load` writes the
two model tables; everything else here is read-only.

`VARIANTS` is a `;`-separated list of variants, each a `,`-separated list of `knob=value`. `show`
prints the profile, the page and the reasons for one user. `eval` samples `USERS / 3` users per
segment (5-19, 20-99, 100+ positive list items; only users with at least five hold-out candidates,
i.e. favorites plus 4-star-or-better ratings, counted only on books in the ranked pool), hides `FRACTION` of each user's favorites and
4-plus-rated books, recommends `LIMIT` from the rest, and checks whether the hidden books return.
Columns: hit@10, recall@50, ndcg@50, `mean_rank` (mean global rank of the recommended books, the
popularity check), `au_rep` (author repeats per page), `kl` (mean genre KL from history, averaged
over pages that carry genres), `coverage` (share of the ranked pool ever recommended), `ms`, and
`cf` (how many evaluated users the collaborative signal fired for). Two baselines print on every
run: `rank` (the filtered pool in global-rank order) and
`lift=false  quality_scale=0  collaborative=false` (raw frequency share with the quality prior and
the collaborative signal off, the legacy engine's behaviour; the records before 2026-10-08 print it
as `lift=false`, when the prior did not exist, and the 2026-10-08 record as `lift=false
quality_scale=0`). The baseline pins every knob the legacy engine lacked, so a default change or a
loaded model never changes what it measures. That row is always present even when a variant combines `lift=false` with other knobs.

Hold-outs are drawn only from the ranked pool, since that is all the engine can return: an unranked
favorite can never come back, so holding it out would only deflate recall and NDCG.

**Measuring the collaborative signal needs a hold-out model.** A model trained on the full export
has already seen the books eval hides, so it would recover them for free. The hold-out plan
(`Evaluation.hold_out_plan`) is deterministic for `(USERS, SEED, FRACTION)` and shared by `eval`
and `export`: `export HOLDOUT_SEED=s HOLDOUT_USERS=u HOLDOUT_FRACTION=f` omits exactly the pairs
`eval SEED=s USERS=u FRACTION=f` will hide, names the file `<date>-holdout-<seed>-u<users>-f<fraction>`
(every value the plan depends on, so two runs on one day can never share a file), and leaves
`interactions/latest` alone. Train on that file, `load VERSION=<that name>`, then run `eval` with the
same three values; `eval` prints the active model's version and warns when it does not end in the
suffix for those values. A version is loaded once: to re-train the same name (same day, same plan)
and load the new file, pass `FORCE=1` to `load`. `VARIANTS="collaborative=false"` adds the taste-only engine to
the same run, which is the comparison the bar is written against. Load a full model afterwards.

The hold-out metric rewards famous books: hidden favorites are mostly canon, so the `rank` baseline
is hard to beat on hit@10 and a deeper-cutting engine is penalised by construction. Read it next
to `mean_rank`, never alone.

## Knobs

All in `config/initializers/recommendations.rb`, each overridable per call.

| key | value |
|---|---|
| `free_limit` / `member_limit` | 10 / 50 (for increment 3) |
| `candidate_size` | 300 |
| `favorite_weight`, `top_favorite_bonus`, `top_favorite_count` | 2.0, 0.5, 10 |
| `read_weight`, `want_to_read_weight` | 0.4, 0.2 |
| `rating_slope` | 0.75 |
| `lift` | true |
| `lift_cap` | 0 (uncapped) |
| `lift_population` | `"catalog"` (or `"ranked"`) |
| `pseudo_books` (m) | 10 |
| `min_support`, `min_support_history` | 2, 5 |
| `negative_gamma` | 0.5 |
| `demote_threshold`, `negative_boost` | 1.0, 0.3 |
| `max_genres`, `max_subjects`, `max_locations` | 8, 25, 5 |
| `genre_multiplier`, `subject_multiplier`, `location_multiplier` | 1.0, 0.8, 0.4 |
| `fiction_share_high`, `fiction_share_low` | 0.9, 0.1 |
| `normalization_floor`, `min_score` | 10, 1.0 |
| `quality_scale`, `quality_floor` | 0 (prior off), 0.3; Safer bets sets 1000, 0.3 |
| `depth_overrides` | `safe` → `{quality_scale: 1000, quality_floor: 0.3}`, `deep` → `{rank_prior_weight: 0}` |
| `rrf_k`, `taste_weight`, `collaborative_weight`, `collaborative_half_point`, `rank_prior_weight` | 60, 1.0, 0.25, 10, 0.3 |
| `collaborative` | true (false: the signal reports itself unavailable; the harness's taste-only variant) |
| `collaborative_min_rating` | 3 (a rating at or above this is a positive, for training and for the shelf scored per request) |
| `collaborative_overfetch` | 2 (neighbour rows read = this × `candidate_size`, so the ranked-pool filter can drop some and still fill) |
| `because_of_rating` | 4 ("Because you loved X" names only a favorite or a book rated at least this) |
| `max_per_author` | 2 |
| `calibrate_genres`, `calibration_lambda`, `calibration_alpha` | true, 0.3, 0.01 |
| `explain_threshold` | 1.0 |

The trainer's flags (`recommender.cli train` / `run`), with their defaults: `--lambda 500`,
`--min-readers 5`, `--top-k 50`, `--eval-seed 1`, and for `run` only `--gate-ratio 0.9` and
`--max-export-age-days 3`.

Measured values are in `docs/data-quality/recommendations-2026-10-07.md` (the first pass, which
found the pages too deep), `docs/data-quality/recommendations-2026-10-08.md` (the quality prior,
the revised bar, and why `quality_scale=1000` is the default) and
`docs/data-quality/recommendations-collaborative-2026-10-10.md` (the λ sweep and the collaborative
signal against spec 2's bar). Regenerate before acting on them;
the numbers describe the dev database on those days.

## Known gaps

- **The offline harness rewards the canon, and the first live page proved it.** With the quality
  prior on and the collaborative list at full weight, the owner's production page (312 positives,
  top 15,000, no year filter) was the all-time top 100 minus his shelf, identical under all three
  depths, with Tolstoy and Dostoevsky as the model's answer to The Brothers Karamazov. The harness
  had called both a win because held-out favourites are mostly famous books. Fixed 2026-10-10 by
  shipping the prior off (Safer bets turns it on), the collaborative weight at 0.25, and the
  threshold before the prior; `docs/data-quality/recommendations-canon-2026-10-10.md` has the pages
  before and after and the harness cost. The page the owner looks at is the acceptance test; a
  harness metric that scores recovered favourites by rank percentile (so a rank-3,000 favourite
  counts for more than a rank-30 one) is still not built.
- **Depth does not reach the collaborative list.** The collaborative list ignores the quality prior,
  so under Safer bets its picks are not pulled toward the canon the way the taste list's are. At
  weight 0.25 that is two picks in twenty; the spec's section 8.3 experiment, "apply the quality
  prior to the collaborative list", remains the fix if it matters.
- **The revised bar (spec §9.2, amended 2026-10-08) is met on hit@10 and page depth, and NOT met
  on recall@50 or KL.** With the quality prior the engine beats the frequency profile on hit@10 by
  about 1.6x on the 20-99 segment on both samples and returns pages at mean rank 750-800 instead
  of 5,500; on recall@50 it trails that profile by 0.02-0.06 (a tie on the fresh sample, a loss on
  the other), and its KL sits 0.02-0.07 above the previous defaults. Shipping it as the default is
  a judgement, argued in the data-quality record. `lift_cap` and `lift_population` exist, measured,
  and off.
- **The collaborative signal meets spec 2's bar on every condition, on two samples**: on 100+
  hit@10 goes from 0.32-0.33 to 0.74 and recall@50 from 0.105 to 0.38-0.41 against the taste-only
  engine, with lower KL and shallower pages
  (`docs/data-quality/recommendations-collaborative-2026-10-10.md`). With it, the engine also beats
  the frequency profile on recall@50 on 20-99 and 100+, the gap the bullet above records for the
  taste-only engine. It costs about 140-215 ms more per page on the 20-99
  and 100+ segments, mostly downstream of the signal's own two reads (not yet profiled), and the
  neighbour read for the two largest shelves (5,794 and 18,534 trainable books) takes 0.4-1.1 s.
  Production has no model until spec 2's increment 2 (the home-server timer) ships.
- The wizard's "add" is the list widget's modal (pick a list), not a one-click add; the spec's
  "one click" is two.
- Results run the engine on every request (~15 queries + the OpenSearch call + ~110 ms
  calibration, and with a model loaded one neighbour read and a second OpenSearch call); no
  caching, by design, since the page is per-user.
- The rank prior at 0.3 can re-order roughly 20 places among the taste candidates at a 300-item
  pool (reciprocal-rank terms at `k = 60` are close together).
- Fiction and Nonfiction are never scored; they only steer through `fiction_share` and the genre
  calibration.
- Not attempted: rating centering per user, and time decay (spec §9.4).
  Ranked-only `p_c` was built and measured (`lift_population`), and left off.
- `categories.item_count` is a polymorphic counter cache shared with `Books::Author`; the profile
  divides it by the book catalog size, which is exact only while no category is attached to an
  author (0 author rows today against 2,269,792 book rows). If authors ever gain categories, switch
  the profile to a book-only count (a cached one; a per-request GROUP BY over 2.3M rows is too slow).
