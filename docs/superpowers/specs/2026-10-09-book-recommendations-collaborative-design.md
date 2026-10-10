# Book Recommendations, Spec 2: Collaborative Filtering — Design

**Date:** 2026-10-09 · **Status:** approved in conversation, awaiting spec review
**Spec 1:** `docs/superpowers/specs/2026-10-07-book-recommendations-design.md` (the engine, pages,
signal contract §5.3, fusion §5.4, explanations §8.3, harness §9). This spec fills the slot that
spec 1 left fixed: the `Collaborative` signal, the model behind it, and the job that builds it.

## 1. Why

The engine shipped in #363/#364/#367 is content-only: it knows a reader through the categories of
the books they shelved. That works for readers with a few dozen books and stops working for the
readers who matter most. On the 100+ segment the taste profile is broad and 50 category-matched
books cannot cover it; recall@50 there trails the legacy-style frequency profile
(`docs/data-quality/recommendations-2026-10-08.md`). Categories cannot say that readers of *The
Dispossessed* also read *Stories of Your Life*; co-readership can.

The data exists. Measured on the development database on 2026-10-09 (list items on books
lists plus rated reviews, deduplicated to user–book pairs):

| What | Count |
|---|---|
| User–book pairs | 3,067,942 |
| Users with any pair | 51,300 |
| Users with 20 or more | 22,818 · with 100 or more: 7,392 |
| Books with 5 or more readers | 17,874 (94% of all pairs) |
| Books with 10 or more readers | 10,018 (92% of all pairs) |
| Ranked books with 5 or more readers | 11,687 |

### Goals

- A readers-like-you signal that lifts hit@10 and recall@50 on the 20–99 and 100+ segments
  without losing the 5–19 segment, measured by the existing harness.
- The first real "Because you loved X" reason.
- A model that is rebuilt from a nightly export on the home server and served entirely from
  Postgres, so no request ever waits on the home box and a reader's shelf changes count the
  same day.
- Domain-generic paths and jobs: books now, music and games by adding an adapter method.

### Non-goals

- "Readers also liked" on book pages. The table makes it a one-query follow-up; the page is
  not in this spec.
- User-to-user similarity, embeddings, GPUs, sequence models, time decay.
- Half and quarter stars (a separate bounded spec; this spec reads a numeric rating).
- Any change to the wizard, settings or results pages beyond the reason line.
- Exposing the model through the public API.

### Decisions already made (spec 1, do not re-litigate)

Python EASE job on the home server; Rails pushes the export and pulls the model; the home server
never writes to Rails. Signal contract §5.3; fusion weight `n⁺ / (n⁺ + 10)`; evidence shape
`{because_of: item_id, term: Float}`; reason precedence §8.3.

### Decisions made for this spec (2026-10-09)

1. **Transport is a private R2 bucket used as a mailbox**, not a third tunnelled service. No
   inbound connection to the house, no process that must stay up. If the Mini is off the model
   goes stale, never down.
2. **The model learns from positive shelf presence**: favorites, read, currently reading, and
   any rating of 3 or more. Want-to-read and ratings of 1–2 are left out. Weighted presence and
   "everything" are harness experiments (§8), not the default.
3. **Scoring is live, per request, from an item-neighbour table.** The
   `recommendation_user_scores` table pencilled into spec 1 §4 is dropped.

## 2. Architecture

```
Rails (prod)                          R2 bucket (private)                 Home server, `ol` VM
──────────────────────────────        ───────────────────────────         ─────────────────────────
ExportInteractionsJob  ──put──▶  recommendations/books/interactions/   ◀──get──  recommender-train.timer
  nightly 02:30                     <date>.csv.gz, latest                 daily 04:00
                                                                          EASE → top-50 neighbours
LoadModelJob           ◀──get──  recommendations/books/model/         ◀──put──  + manifest, eval gate
  hourly, idempotent                <date>.csv.gz, <date>.json, latest

recommendation_models + recommendation_item_neighbors (Postgres)
          ▲
Signals::Collaborative  ← engine → fusion → page   (one indexed read per request)
```

Three legs, each restartable on its own. Every leg reads and writes **files** through a
`Recommendations::Store` with two implementations, `Local` (a directory) and `R2`. Development
and the harness use `Local` end to end; production uses `R2`. The Python trainer takes input and
output paths the same way, with an R2 sync step around them. Nothing in the pipeline depends on
which transport is in use.

### 2.1 Sizing (why this fits the existing box)

EASE is one linear solve over the items that have enough readers, not a model that trains for
hours. At the 5-reader floor the gram matrix is 17,874², about 2.6 GB in float64; the solve
peaks around three times that and takes one to two minutes on the `ol` VM's 12 vCPUs. At the
10-reader floor it is under 1 GB and seconds. The export is roughly 10 MB gzipped; the model is
under a million rows. The `ol` VM (24 GB, idle outside dump builds) runs it as one more compose
service with a 14 GB memory limit; the fetcher VM is untouched. The box needs no uptime
guarantee: it is a batch job and nothing in Rails calls it.

## 3. Export (Rails)

**Positive pairs.** `Recommendations::Books::PositivePairs` is a query object the registry
exposes as `Registry.pairs_class_for(domain)`. It yields `(user_id, item_id)` in batches with
one SQL statement per batch, never through `Adapter#interactions` (51k users × 15 queries is not
an export):

```sql
SELECT DISTINCT ul.user_id, uli.listable_id
  FROM user_list_items uli JOIN user_lists ul ON ul.id = uli.user_list_id
 WHERE ul.type = 'Books::UserList' AND uli.listable_type = 'Books::Book'
   AND ul.list_type IN (favorites, read, reading)
UNION
SELECT user_id, reviewable_id FROM reviews
 WHERE reviewable_type = 'Books::Book' AND rating >= :min_rating
```

`min_rating` is the knob `collaborative_min_rating` (3); `list_type` values are the
`Books::UserList` enum's integers for those three names. The same predicate, expressed over
`Interaction`, is `Recommendations::Interaction#trainable?(min_rating:)`: kind in `favorite`,
`read`, `reading`, or `rating >= min_rating` (the struct holds no config, so the caller passes
the knob). The signal (§6) selects a user's shelf with `trainable?`
so serving and training agree on what a "positive" is. (The engine's signed `weight` is not
used here: want-to-read is positive-weighted but not trainable; a 2-star review on a read book
is negative-weighted and not trainable; both rules fall out of `trainable?`.)

**File.** `Recommendations::Export.call(domain:, store:, hold_out: nil)` writes
`recommendations/<domain>/interactions/<YYYY-MM-DD>.csv.gz` — header `user_id,item_id`, sorted
by user then item, gzipped — then writes `recommendations/<domain>/interactions/latest`
containing the date. About 3 million rows, around 10 MB. User ids are our own integers; the
bucket is private and the export never leaves our infrastructure, so no pseudonymisation.

**Hold-out.** `hold_out` is a `{user_id => Set[item_id]}` map; those pairs are omitted from
the file and the export is named `<date>-holdout-<seed>` instead of `<date>`, and does not
move `latest`. This is how the harness gets honest numbers (§8.2).

**Job.** `Recommendations::ExportInteractionsJob` (Sidekiq, `bin/rails generate sidekiq:job
recommendations/export_interactions`), argument `domain`, scheduled in `config/schedule.yml` at
`30 2 * * *` for `books`. Both boxes run on America/Chicago, so the 04:00 train sees that
night's export; if the zones ever differ the three-day age check (§4.3) is the only thing that
notices, so the plan asserts the zone in `provision --verify`. It uses `Store.default`,
which is `R2` when the `RECOMMENDATIONS_R2_*` variables are set (amended 2026-10-10: access key, secret key and bucket; the endpoint defaults to `STORAGE_ENDPOINT`) and otherwise refuses to
run (a production job silently writing to a local directory is the failure to prevent).

**Rake, for development:** `bin/rails recommendations:export [DIR=tmp/recommendations]
[HOLDOUT_SEED=42 HOLDOUT_USERS=300 HOLDOUT_FRACTION=0.2]`.

## 4. Train (Python, home server)

### 4.1 Package

`data-sources/src/recommender/`, a third package beside `openlibrary` and `fetcher`, with its
own optional extra so the Open Library and fetcher images never carry it:

```toml
[project.optional-dependencies]
recommender = ["numpy>=2.1,<3", "scipy>=1.14,<2", "boto3>=1.35,<2"]
```

Installed with `uv sync --locked --extra recommender`; CI adds the extra to its install. Its
own `recommender.Dockerfile` (same `python:3.12-slim` + uv layering as the others, unprivileged
user) and compose service `recommender` under `profiles: ["recommender"]` so `docker compose up`
never starts it; the timer runs it with `compose run --rm`.

Modules, each one responsibility:

| Module | Does |
|---|---|
| `recommender.pairs` | reads the export CSV into (user index, item index, item id map); applies `--min-readers` |
| `recommender.ease` | `fit(X, lam) -> B` and `top_neighbors(B, k) -> rows`; pure numpy/scipy, no I/O |
| `recommender.evaluate` | random one-held-out-per-user split (seeded), hit@10 / recall@50 of the model on it |
| `recommender.manifest` | the JSON manifest, and the publish gate against the previous manifest |
| `recommender.store` | `Local` and `R2` (boto3) with `get`, `put`, `read_pointer`; the same three verbs Rails uses |
| `recommender.cli` | typer: `train`, `pull`, `push`; `run` chains pull → train → push |

### 4.2 The model

Implicit-feedback EASE (Steck, 2019). With `X` the binary user×item matrix:

```
G = Xᵀ X + λ I                (dense float64, items × items)
P = G⁻¹                       (Cholesky solve; G is symmetric positive definite)
B = −P / diag(P),  diag(B) = 0
score(u, j) = Σ_i X[u, i] · B[i, j]
```

Rows of `B` are kept sparse for serving: for each item `i` the `k` largest **positive** entries
`B[i, j]`, written as `(item_id, neighbor_id, weight)`. Reading a row as "a reader who shelved
`i` is led to `j` with weight `B[i, j]`" is what makes the stored rows both the scoring input
and the explanation (§6). Flags with their defaults: `--lambda 500`, `--min-readers 5`,
`--top-k 50`. Users with fewer than 2 positives are dropped from `X` (a one-book row teaches
nothing and inflates the diagonal). Items below the reader floor are dropped before the gram
matrix is built; nothing else is filtered — the ranked-pool constraint is applied at serving
time (§6), so the model can later serve book pages for unranked books too.

### 4.3 Output and the gate

`recommendations/<domain>/model/<date>.csv.gz` (header `item_id,neighbor_id,weight`, sorted by
item then weight descending) and `recommendations/<domain>/model/<date>.json`:

```json
{"domain": "books", "export": "2026-10-09", "trained_at": "2026-10-09T04:03:11Z",
 "lambda": 500.0, "min_readers": 5, "top_k": 50,
 "users": 48112, "items": 17874, "rows": 893700,
 "eval": {"seed": 1, "users": 46950, "hit_at_10": 0.312, "recall_at_50": 0.401},
 "previous": "2026-10-08"}
```

`latest` moves to the new date only when the gate passes: there is no previous manifest, or
the new `hit_at_10` is at least `0.9 ×` the previous one (`--gate-ratio`). A failed gate leaves
the files in place for inspection, leaves `latest` alone, and exits non-zero so the timer's
healthcheck ping says why. The export must be newer than the model it would replace and no
older than three days, else the run fails the same way.

### 4.4 Deployment on the `ol` VM

- `deployment/home-server/guest/recommender-train.sh` + `systemd/recommender-train.{service,timer}`,
  installed by `install-units.sh` for role `ol` only. `OnCalendar=*-*-* 04:00`, `OnBootSec=20min`. (Amended 2026-10-10: the VM's clock is UTC and
  provision sets no time zone, so this is 04:00 UTC, 1.5 h after the 02:30 UTC export, not 04:00
  Chicago; `deploy.sh` builds the trainer image with the API's so merged trainer changes reach the
  VM; the `RECOMMENDATIONS_R2_*` pass-through lives in `data-sources/docker-compose.yml`, so
  `compose.ol.yml` adds only the limits.)
- Takes the same `BUILD_LOCK` as `ol-refresh.sh`, non-blocking: on a dump-build day it logs
  "deferred", pings the check with that message and exits 0. The check's grace (2 days) covers
  one deferral; a second day missed alerts. (Amended 2026-10-10: the deferral is sent to the
  check's `/log` endpoint, which records it without counting as a run; with period 1 day and
  grace 2 days, about three days without a completed run alerts.)
- `compose.ol.yml` sets the service's `mem_limit: 14g` and `cpus: 10`, the same share the dump
  build gets, and passes `RECOMMENDATIONS_R2_*` through. The trainer writes only to its own scratch
  volume; it never touches `/srv/ol-data`.
- Secrets: `RECOMMENDATIONS_R2_ENDPOINT/ACCESS_KEY/SECRET_KEY/BUCKET` (amended 2026-10-10: endpoint, not account id; and the same names as the Rails side, where the spec first said `RECOMMENDER_R2_*`, so one spelling serves both secrets files) and `HC_RECOMMENDER` in
  `secrets/home-server.env`, rendered by `provision` into `/etc/the-greatest/home-server.env`
  as the existing `HC_*` values are (`deployment/home-server/lib/vm.sh`). One healthchecks.io
  check, `recommender-train`, period 1 day, grace 2 days.
- Nothing listens. No tunnel, no Access rule, no port.

### 4.5 Tests (pytest, `tests/recommender/`)

`ease`: a hand-built 6×5 matrix with a known co-read structure yields the expected neighbour
order and a zero diagonal; `top_neighbors` keeps only positive weights and at most `k`.
`pairs`: the reader floor and the 2-positive user floor. `evaluate`: metrics on a toy model
where the answer is known. `manifest`: the gate passes, fails, and passes with no previous.
`store.Local` round trip; `store.R2` against an injected fake client (no network). `cli run`
end to end over `Local` directories in a tmp path, asserting `latest` moves only on a pass.

## 5. Load (Rails)

Two tables, one migration:

```
recommendation_models
  id, domain (string, not null), version (string, not null), manifest (jsonb, not null),
  state (integer enum: loading 0, active 1, retired 2), created_at, updated_at
  unique index (domain, version); index (domain, state)

recommendation_item_neighbors
  id (bigint), recommendation_model_id (FK, not null), item_id (bigint), neighbor_id (bigint),
  weight (float, not null)
  index (recommendation_model_id, item_id)
```

`Recommendations::LoadModel.call(domain:, store:)`:

1. Read `recommendations/<domain>/model/latest`; if a model row with that version exists in any
   state but `loading`, return success with `loaded: false` (the hourly job is idempotent).
2. Create the model row in `loading` (or reuse a stale `loading` row and delete its rows: a
   crashed load retries cleanly).
3. Stream the CSV and `insert_all` in batches of 10,000.
4. In one transaction: assert the row count equals the manifest's, mark the new row `active`,
   mark the previous active row `retired`.
5. Delete the retired model's rows in batches, then the row. A failure here leaves extra rows
   nobody reads; the next load finishes the cleanup.

`Recommendations::LoadModelJob` (Sidekiq, argument `domain`) runs hourly at `15 * * * *`. Dev:
`bin/rails recommendations:load [DIR=tmp/recommendations]`.

`Recommendations::Model` (`active_for(domain)`) and `Recommendations::ItemNeighbor` are the two
models; skinny, associations and the enum only. Every user FK rule in AGENTS.md is untouched:
neither table references users.

## 6. The signal (Rails)

`Recommendations::Signals::Collaborative` replaces the stub, same file, same contract.

- `available?` → `Model.active_for(adapter.domain)` is present (memoised per instance). The
  adapter gains `domain` (`:books`) so generic code can ask; `Registry` already keys on it.
- `weight(positive_count)` → unchanged ramp, `n / (n + collaborative_half_point)`.
- `call(profile:, interactions:, criteria:, excluded_ids:, size:)`:
  1. `shelf = interactions.select { |i| i.trainable?(min_rating: config[:collaborative_min_rating]) }
     .map(&:item_id)`; return `[]` if empty.
  2. One query, `collaborative_overfetch × size` rows (2 × 300):
     ```sql
     SELECT neighbor_id, SUM(weight) AS score,
            (ARRAY_AGG(item_id ORDER BY weight DESC))[1] AS because_of,
            MAX(weight) AS term
       FROM recommendation_item_neighbors
      WHERE recommendation_model_id = :model AND item_id IN (:shelf)
        AND neighbor_id NOT IN (:excluded)
      GROUP BY neighbor_id ORDER BY score DESC LIMIT :n
     ```
     A reader with 200 trainable books touches at most 10,000 rows through the
     `(model_id, item_id)` index; the largest shelves in the data (about 3,000 books) touch
     150,000, still one indexed read.
  3. `adapter.filter_candidate_ids(ids, criteria:, excluded_ids:)` → the ranked-pool query
     (`BookRecommendations.ranked_only`) with an added `ids` filter and `size: ids.size`,
     so length, year range, rank cap, included and excluded categories and the depth setting
     apply exactly as they do to the taste list. The quality prior is not applied here: this
     list's order is the collaborative score; the rank prior in fusion already supplies canon.

     > Amendment 2026-10-10: the depth setting does not reach this list. It acts only through the
     > taste query's quality prior, which `ranked_only(ids:)` does not carry. See "Known gaps" in
     > `docs/features/recommendations.md`.
  4. Return `Candidate(item_id:, score:, evidence: {because_of:, term:})` in score order, the
     first `size`.

The engine (`run_signals`, `guarded`) needs no change: an exception drops the signal from
`signals_used` and the page falls back to taste, as today. The explainer already returns
`because_of` when the contributing book is a favorite or rated ≥ 4; `ReasonComponent` renders
it as "Because you loved *Title*" with the book linked.

Readers below the trainable floor, and every reader on a domain with no active model, see
exactly today's behaviour.

## 7. Knobs

Rails (`config/initializers/recommendations.rb`): `collaborative_min_rating: 3`,
`collaborative_overfetch: 2`, and the existing `collaborative_half_point: 10`. Python flags:
`--lambda 500`, `--min-readers 5`, `--top-k 50`, `--gate-ratio 0.9`, `--eval-seed 1`.

## 8. Measuring it

### 8.1 In the trainer

`recommender.evaluate` holds one random positive out per user with ≥ 5 positives (seeded),
fits on the rest, scores each user with the sparse top-k model, and reports hit@10 and
recall@50 over the held-out items. This is the tool for λ, the reader floor and k, measured
where the model is built. The first pass sweeps λ ∈ {100, 300, 500, 1000, 3000} and
`min-readers` ∈ {5, 10} on the dev export and records the table.

### 8.2 In the Rails harness (the bar)

The harness holds items out of a user's history; a model trained on the full export has seen
them. For honest numbers `Evaluation.hold_out_plan(domain:, users:, seed:, fraction:)` is
extracted from `recommendations:eval` and returns `{user_id => held_out_ids}` for the sampled
users, deterministic for a seed. `recommendations:export HOLDOUT_SEED=… HOLDOUT_USERS=…
HOLDOUT_FRACTION=…` calls the same function and omits those pairs; the trainer runs on that
file; `recommendations:load` loads it; `recommendations:eval` with the same three values then
measures the fused page on users whose held-out books the model never saw.

`recommendations:eval` gains the variant knob `collaborative=false` (the stub's behaviour) so
one run prints taste-only beside taste+collaborative, and prints `signals_used` coverage per
segment (how many sampled users the signal fired for).

**The bar, recorded in `docs/data-quality/recommendations-collaborative-<date>.md`:** on the
20–99 and 100+ segments, taste+collaborative beats today's defaults (`collaborative=false`) on
hit@10 and recall@50 beyond the sample's noise band; the 5–19 segment does not lose beyond
noise; mean global rank within a factor of two of today's; genre KL no worse than today's. If
the 100+ segment does not move, the spec's reason to exist is unmet and the signal ships with
`available?` forced false until it does.

### 8.3 Recorded experiments (not in this spec)

Weighted presence (favorites 1.0, read 0.6, rated-3 0.5) as `X`'s values; including
want-to-read; a `collaborative_half_point` sweep; applying the quality prior to the
collaborative list; EASE on the ranked pool only.

## 9. Failure modes

| Failure | Effect | Recovery |
|---|---|---|
| Home box off, or train deferred by a dump build | model stale; `latest` unchanged | healthchecks alerts after the grace; nothing in Rails changes |
| Export job fails | trainer finds an old export; fails the age check | alert; previous model keeps serving |
| Trainer gate fails (worse model) | files written, `latest` unchanged | alert names the ratio; inspect the manifest |
| Load crashes mid-insert | row stays `loading`; old model stays `active` | next hourly run deletes and reloads |
| R2 unreachable from Rails | export/load job raises; Sidekiq retries | nothing user-facing |
| Signal raises at request time | dropped from `signals_used`, page falls back to taste | logged with class and backtrace, as the taste signal is |
| No model ever loaded (new domain, first deploy) | `available?` false | engine behaves as today |

## 10. Rollout

Production holds a rehearsal copy of the books data and the migration is re-run before
launch, so the model is a **repeating** step: every `data_migration:all` pass is followed by an
export, a train and a load. Add to `docs/launch-todo.md`:

1. Create the private R2 bucket and a token scoped to it; put `RECOMMENDATIONS_R2_*` in the
   production SOPS secrets and `RECOMMENDATIONS_R2_*` + `HC_RECOMMENDER` in `secrets/home-server.env`.
2. Create the `recommender-train` check on healthchecks.io (period 1 day, grace 2 days).
3. `deployment/home-server/provision` (Shane runs it) so the `ol` VM gets the units and env.
4. After each migration pass: run the export job, wait for (or `systemctl start`) the train,
   confirm the load; `recommendations:show USER_ID=…` shows `collaborative` in `signals_used`.
5. Remove nothing: the `LEGACY_R2_*` removal on the todo list is unrelated to this bucket.

Increments: **(1)** export, trainer, load, signal, harness hold-out, measured in development
against the bar (one plan; the whole leg runs locally with `Store::Local`); **(2)** the home
server units, compose, provision and secrets (a small plan on `deployment/`); the feature doc
section and launch-todo items land with whichever increment touches them.

## 11. Documentation

`docs/features/recommendations.md` gains a "Collaborative signal" section (what trains, where,
the tables, the knobs, how to run the loop locally) and the "Known gaps" entry about the 100+
segment is updated with the measured result. `docs/features/home-server.md` gains the
`recommender-train` timer in its unit table and the check in its healthchecks list.
`data-sources/README.md` lists the third package.
