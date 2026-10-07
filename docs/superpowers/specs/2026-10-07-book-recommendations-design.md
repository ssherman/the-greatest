# Book recommendations — design

**Status:** approved in conversation 2026-10-07, awaiting written review.
**Scope:** spec 1 of 2. Everything in Rails: the wizard, the results and settings pages,
membership gating, the preferences store, the legacy config migration, the recommendation
engine with its taste-profile signal, re-ranking, explanations, and the evaluation harness.
**Spec 2** (to be written once this is approved) covers the collaborative-filtering service on
the home server and the signal that reads it. Its interface is fixed here (§5.3, §6.6).

## 1. Why

The legacy site (`the-greatest-books/admin`) has a paid recommendations feature:
`app/lib/recommendations/engine.rb`, two strategies, a `recommendation_configs` table, a
four-step wizard, and `Search::Books.find_recommendations`. It is content-only: it tallies the
categories of the user's favorite, 5-star, 4-star, and read books, keeps the most frequent per
type, and runs one OpenSearch bool query over ranked books with a boosted `should` term per
category, filtered by the user's settings.

Two defects, both structural:

1. **Ubiquitous categories dominate.** Frequency is never discounted by how common a category
   is. Fiction sits on 55% of books (88,905 of 160,587 in the dev corpus), Identity on 39,744,
   Family on 28,263. Every reader's profile is "Fiction, Identity, Family" first. The category
   fields are OpenSearch keyword fields, so a `term` match scores a flat boost with no IDF
   ([[keyword-term-queries-have-no-idf]]); rarity never enters anywhere.
2. **Frequency rewards what was read most, not what was loved.** A 1-star book contributes
   exactly as much as a 5-star one to the read-list tally, and nothing ever pushes a category away.

It also never had the data for collaborative filtering. The new app does: 51,215 users with at
least one books list item, 22,927 with 20 or more, 24,731 books on 5 or more users' lists
(dev database, 2026-10-07). That is what spec 2 uses.

### Goals

- Port every user-facing capability of the legacy feature: wizard, results, preferences
  (excluded/included categories, book length, year range, max rank), membership gating,
  reset.
- Replace the frequency tally with a profile that measures how much a reader over-indexes on a
  category versus the catalog, with ratings as signed weights.
- Add what the old site lacked: author and series rules, a calibrated genre mix, a stated reason
  per recommendation, a measured tuning loop.
- Leave a fixed slot for the collaborative signal so spec 2 changes quality, not pages.
- Keep the engine domain-agnostic. Music and games come later as adapters.

### Non-goals

- The collaborative service itself (spec 2).
- Text embeddings and vector search (a possible spec 3, after the harness says where they help).
- The agentic / MCP flow. It will consume this engine's output as a data source.
- Storing half and quarter stars. Goodreads shipped them in October 2026; a separate bounded
  spec changes the two integer rating columns, the star widget, the review summary counts, the
  API shape, and the import parser. This engine reads a numeric rating and assumes nothing about
  its granularity (§6.1), so the two pieces of work are independent.
- Time decay and per-user rating centering. Both are recorded as harness experiments (§9.4).
- Recommending unranked books. The candidate pool is ranked, non-provisional books, as before.
- A public API endpoint. The reason value object (§8.3) is shaped so a later spec can serialize it.

## 2. Product surface

All pages are on the books host, served by the books layout, with `prevent_caching` (they vary
per user). The legacy path `/recommendations` is kept so inbound links keep working.

| Path | What |
|---|---|
| `/recommendations` | Results. Signed out: the pitch page. Signed in with no favorites and no read books: redirect to wizard step 1. |
| `/recommendations/wizard/:step` (1–4) | Favorites, History, Ratings, Preferences. Progress bar across the top, as before. |
| `/recommendations/settings` | Step 4 on its own, for returning users. Same controller action and form. |
| `POST /recommendations/settings` | Save preferences. Members only (§2.3). |
| `POST /recommendations/reset` | Destroy the user's config, with a confirm. |

### 2.1 The wizard

Kept on purpose: it is the one place that explains, in order, everything that feeds the
recommendations and lets a new user act without leaving. Steps 1–3 are not data-entry forms of
their own; each embeds the site's existing widgets.

- **Step 1, Favorites.** Why favorites matter. The user's favorites list. A search box whose
  results render the existing `Books::CardComponent` with its `UserLists::CardWidgetComponent`,
  inside a Turbo Frame (`target: "_top"` on the frame, per [[turbo-frame-trapped-links]]), so
  adding a favorite is one click. Link to the list page for reordering.
- **Step 2, History.** Why history matters (avoids re-recommending, reveals patterns). The read
  list (most recent 500) with the same search-and-add pattern, and a prominent link to the
  Goodreads import.
- **Step 3, Ratings.** Why ratings matter. Read books without a rating, each with the existing
  `Reviews::WidgetComponent` inline. Then the already-rated books (first 50). Reachable only when
  the user has at least one favorite or read book; otherwise redirect to step 2 with a flash
  rendered via turbo-stream ([[public-layouts-render-no-flash]]).
- **Step 4, Preferences.** The settings form (§2.3) and a "View my recommendations" button.

### 2.2 Results page

- Grid of `Books::CardComponent` in the shared grid container, each with its global rank and a
  one-line reason beneath (§8.3).
- Side panel: the user's current settings summarized by the criteria label code; a "your taste"
  block listing the top genres, subjects, and locations the engine used with a simple bar per
  weight; the counts of favorites, read, and rated books feeding the profile; links to the wizard
  and settings; reset.
- When the engine returns nothing (search outage, or a filter that matches nothing), a visible
  "recommendations are unavailable right now" / "no books match your settings" state. Never a 500.

### 2.3 Membership gating

Register `book_recommendations` in `MembershipGate::FEATURES`. Everything below reads it.

| Visitor | Results | Preferences form |
|---|---|---|
| Signed out | Pitch page | — |
| Free account | **10** results, side panel, member pitch after the grid | Rendered, every field disabled with a lock mark, submit replaced by "Become a member", form opens the same membership modal `CsvExports::DownloadButtonComponent` uses |
| Member | **50** results | Editable |

Counts live in `config/initializers/recommendations.rb` (`free_limit`, `member_limit`). The
settings POST rejects non-members server-side regardless of the disabled form.

### 2.4 Navigation and copy

"Recommendations" is added to the My Books menu in **both** variants of
`app/views/books/shared/_nav_links.html.erb`. The pitch page is linked from the books membership
story partial. Wizard and pitch copy is run through the `avoid-ai-writing` skill before merge.

### 2.5 Not ported

The `algorithm` and `max_category_count` URL parameters, and the `wtf_user_id` admin parameter.
The harness's `recommendations:show[user_id]` task (§9.5) replaces the last one.

## 3. Cross-domain shape

Music and games will want this. Cheap to allow now, expensive to retrofit.

- Routes are identical on every host. One `RecommendationsController` (with `DomainLayout`,
  as `SavedSearchesController` does) resolves the domain from `Current.domain` and looks it up in
  `Recommendations::Registry`. Books is the only entry in this spec. A domain without an entry
  404s.
- The registry maps a domain to an **adapter** (§5.2): list types that count as favorites,
  history, and intent; the review model; the scoring category types; the index and its filter
  fields; the candidate-pool definition; the criteria class; the wizard step partials.
- Engine, signals, fusion, re-ranker, explainer, and harness never name a domain.
- Per-domain partials: the pitch page, the wizard step copy, and the Ratings step (reviews are
  books-only today).
- Spec 2's export and model paths take a domain name from day one.

## 4. Data model

One new table. No existing table changes.

```
recommendation_configs
  id, user_id (FK users, not null), type (STI, not null), criteria (jsonb, default {}),
  created_at, updated_at
  unique index (user_id, type)
```

- `RecommendationConfig` base model, `Books::RecommendationConfig` subclass, mirroring
  `SavedSearch` / `Books::SavedSearch`. `User has_many :recommendation_configs, dependent:
  :destroy` ([[user-fk-needs-has-many]]). Nothing references a book, so the record merger is
  untouched.
- `Books::RecommendationCriteria` wraps the JSON: `excluded_category_ids`,
  `included_category_ids`, `genre_match_mode` (`any` / `all`), `book_length`
  (enum ints), `first_year_published_gt`, `first_year_published_lt`, `max_ranked_position`.
  Key names match `Books::SavedSearchCriteria` verbatim so the advanced query's clause
  builders apply unchanged; it composes a `SavedSearchCriteria` over those keys with `ranked`
  pinned to true, and reuses `SavedSearchCriteriaParams` / `SavedSearchFilterLabels` for
  writing and labels. The settings form reuses the saved-search category picker.
- The legacy `exclude_locations` flag has no equivalent and is dropped: the engine down-weights
  locations by design (§6.4) instead of switching them off.
- Nothing is precomputed. Signals are read live from `user_list_items` (joined to
  `Books::UserList`) and `reviews` with a rating. Spec 2 adds `recommendation_item_neighbors`
  and `recommendation_user_scores`; the engine reads them only through the collaborative signal.
- No `Rails.cache`: production configures none and the page is per-user anyway. One results
  render is: config read, signal read, one OpenSearch query, one hydration query.

### 4.1 Legacy config migration

`data_migration:recommendation_configs`, backed by
`Services::BooksMigration::RecommendationConfigMigrator`, added to `data_migration:all` after
users and categories. Modeled on the saved-searches migrator.

- Same user id (users preserve ids). Category ids remapped through `legacy_id_maps`
  (`model: "Category"`); unmapped ids dropped and counted in the report.
- `book_lengths` copied after the task asserts the legacy and new enum values agree (fail loudly
  if not). `published_year_start/end` → `first_year_published_gt/lt`. `ranked_limit` →
  `max_ranked_position`. `included_category_all` → `genre_match_mode: "all"`.
- Idempotent: upsert on `(user_id, type)`. It is a **repeating** launch step
  ([[books-launch-todo-doc]]): add it to `docs/launch-todo.md`.
- 33 legacy rows (9 belong to paid users). Sub-second.

## 5. Engine architecture

```
Recommendations::Engine.call(user:, domain:, limit:, overrides: {})
  1. Interactions   adapter → [(item_id, weight, kind)]                       §6.1
  2. Signals        each → ranked candidates with evidence
       TasteProfile   profile → one OpenSearch query                          §6, §7
       Collaborative  reads spec 2's tables; returns [] until then            §5.3
  3. Fusion         weighted reciprocal-rank fusion; rank prior re-orders      §5.4
  4. Reranker       author cap → series rule → genre calibration               §8.1
  5. Explainer      one reason per item                                        §8.3
  → Result(success?, data: {items: [{item, rank, reason}], profile:, signals_used:}, errors:)
```

### 5.1 Where it lives

- Generic: `app/lib/recommendations/` (`Engine`, `Registry`, `Interaction`, `Signal` interface,
  `Fusion`, `Reranker::{AuthorCap,SeriesRule,GenreCalibration}`, `Explainer`, `Reason`,
  `Profile`). New `app/lib` directory → run `CI=1 bin/rails zeitwerk:check`
  ([[eager-load-off-in-test]]).
- Books adapter: `app/lib/recommendations/books/` (`Adapter`, `Interactions`, `TasteQuery`
  under `Search::Books::Search::BookRecommendations` for the OpenSearch half). Root-anchor
  `::Books::Book` inside these namespaces ([[nested-namespace-constant-shadowing]]).
- Knobs: `config/initializers/recommendations.rb`, every key overridable per call via
  `overrides:`, as `book_similarity.rb` does ([[tune-via-rails-config-not-admin-ui]]).

### 5.2 Adapter contract

```ruby
interactions(user)            # → [Interaction(item_id:, weight:, kind:)]  (§6.1)
shelved_item_ids(user)        # every list item + every reviewed item: hard exclusion
candidate_filters(criteria)   # OpenSearch filter + must_not clauses from the user's criteria
category_types                # %w[genre subject location]
type_category_ids             # {"Fiction" => id, "Nonfiction" => id}, resolved by name, memoised
catalog_size                  # N for the lift computation
load_items(ids)               # hydrated records with the preloads the cards need
series_predecessor(item)      # item_id of the previous book in its series, or nil
```

### 5.3 Signal contract (fixed for spec 2)

```ruby
Signal#call(interactions:, criteria:, size:) → [Candidate(item_id:, score:, evidence: {})]
Signal#weight(positive_count)                 → Float   # fusion weight for this user
Signal#available?                             → Boolean # false → skipped, named in signals_used
```

Evidence shapes: `{categories: [id, ...]}` from TasteProfile; `{because_of: item_id, term:
Float}` from Collaborative. The collaborative signal applies the same hard constraints as the
taste signal by passing its candidate ids through a filtered `ids` query on the same index, so
both obey the user's settings identically.

### 5.4 Fusion

Weighted reciprocal-rank fusion, `k = 60`:

```
fused(item) = Σ_signal  w_signal / (k + rank_signal(item))
```

- Taste weight `1.0`. Collaborative weight `n⁺ / (n⁺ + 10)` where `n⁺` is the user's count of
  positively weighted interactions, so three books is nearly all profile and two hundred is
  mostly readers-like-you. (In this spec the collaborative list is empty and contributes 0.)
- The **rank prior** is a third list, the candidates ordered by global rank, with weight `0.3`
  and one rule: it may only re-order items that at least one personalized signal returned. It
  never introduces a book. The canon breaks ties; it does not fill the page.
- Signals each return `candidate_size` (300) candidates. The engine over-fetches so the
  re-ranker can discard and still fill `limit`.

### 5.5 Failure

Any exception from a signal is logged with class and a short backtrace (as `SimilarBooks` does)
and the signal is dropped from `signals_used`. If every signal fails the result is an empty
success and the page shows the unavailable state.

## 6. The taste profile

"Which categories appear in your books far more than they appear in the catalog", with ratings
as signed weights.

### 6.1 Interaction weights

| Signal | Weight |
|---|---|
| Favorite | `+2.0`, plus `+0.5` for the top 10 of a `manually_ordered` favorites list |
| Read or reading, no rating | `+0.4` |
| Want to read | `+0.2` |
| Rating `r` (any numeric granularity) | `rating_slope × (r − 3)` with `rating_slope = 0.75` → 5: +1.5, 4.5: +1.125, 4: +0.75, 3: 0, 2: −0.75, 1: −1.5 |

A book on several lists takes its highest list weight; its rating weight is added. A book only
reviewed in text contributes the read weight. Custom lists contribute nothing but exclusion.

### 6.2 Category lift

For category `c` with catalog share `p_c = item_count_c / catalog_size`, over the user's
positively weighted books:

```
W⁺   = Σ w_i                       (w_i > 0)
n_c  = Σ w_i · [c ∈ book_i]        (w_i > 0)
s_c  = (n_c + m · p_c) / (W⁺ + m)   m = 10 pseudo-books
pos_c = max(0, ln(s_c / p_c))
```

Fiction at 55%: a reader whose favorites are all fiction gets `ln(1/0.55) ≈ 0.6`. "Russian
literature" under 1%: three of twenty favorites carrying it gives `ln(0.15/0.006) ≈ 3.2`. The
`m` term shrinks small histories toward the catalog, so one favorite with sixty Open Library
subjects cannot become the whole profile.

**Support:** a category needs at least `min_support` distinct positive books (2 when the user
has 5 or more positive books, else 1).

### 6.3 Negative profile

The same computation over negatively weighted books (`|w_i|`, `W⁻`) gives `neg_c`.

```
net_c = pos_c − γ · neg_c            γ = 0.5
```

Categories with `pos_c = 0` and `neg_c ≥ demote_threshold` (1.0) go to the query's demotion
clause (§7.3). A disliked category scales matching books down; it never removes a genre over one
bad book.

### 6.4 Selection and scaling

Keep the top `8` genres, `25` subjects, `5` locations by `net_c > 0`. Query boost
`= net_c × type_multiplier` with multipliers genre `1.0`, subject `0.8`, location `0.4`.

### 6.5 Fiction and Nonfiction

Never scored — they are a book **type** ([[books-similar-books]]: resolved by name, memoised,
excluded from the lift computation entirely). The profile records `fiction_share` = positive
weight on Fiction-tagged books / positive weight on books tagged either. §7.4 and §8.1 use it.

### 6.6 Profile output

`Profile(genres: [[id, weight]...], subjects:, locations:, demoted: [id...], fiction_share:,
counts: {favorites:, read:, rated:, positive:, negative:})`. The side panel renders it; the
harness prints it; the explainer reads it.

## 7. Candidates and the query

One OpenSearch query against `Search::Books::BookIndex`, built by the adapter. **No mapping
change**: every field used already exists (`genre/subject/location_category_ids`,
`similarity_category_count`, `ranked`, `ranked_position`, `book_length`,
`first_published_year`, `provisional`, `author_ids`). No production reindex.

1. **Filter (unscored):** `ranked: true`; the criteria's book lengths, year range,
   `max_ranked_position`, included categories (`terms` for any, one `term` each for all).
   Reuse `BookAdvanced`'s clause builders — extract them to a shared module rather than copy.
2. **Must not:** `EXCLUDE_PROVISIONAL`; excluded categories; `ids` of every shelved and
   reviewed book.
3. **Should (scored):** one `term` per selected category with `boost = net_c ×
   type_multiplier`. Separate clauses so shared categories **add** (a `terms` clause would score
   once). `minimum_should_match: 1`.
4. **Fiction share as a soft preference:** if `fiction_share ≥ 0.9` demote Nonfiction-only
   books; if `≤ 0.1` demote Fiction-only books; otherwise nothing (§8.1 handles the middle).
   Same opposite-type clause shape as `BookSimilar.opposite_type_clause`.
5. **Demotion:** wrap in a `boosting` query: `negative` = should-of-terms over `demoted`
   category ids and the type clause from (4), `negative_boost: 0.3`.
6. **Normalization:** `function_score` + `script_score`, `boost_mode: replace`,
   `_score / sqrt(max(similarity_category_count, normalization_floor))`, floor `10`, same
   script and guards as `BookSimilar.wrap_in_normalization`
   ([[books-similarity-thin-book-bias]]).
7. `size: candidate_size` (300), `min_score` (initial `1.0`, tuned with the floor and
   multipliers together — they move the scale together), `_source: false`.

## 8. Re-ranking and explanations

### 8.1 Re-ranker passes, in order

1. **Author cap:** at most `max_per_author` (2) per page. Skipped, not demoted.
2. **Series rule:** a book with a series predecessor is kept only if the predecessor is on the
   user's read or favorites list; otherwise it is dropped and the series' first book is kept if
   it is itself a candidate. Uses `Books::SeriesBook`.
3. **Genre calibration:** greedy selection maximising
   `(1 − λ) · fused_score_norm − λ · KL(history_genre_dist ‖ page_genre_dist)`,
   `λ = 0.3`, where the history distribution spreads each positive book's weight evenly over its
   genres (Fiction/Nonfiction included here, which is how `fiction_share` is enforced on the
   page) and `page_genre_dist` is smoothed with `α = 0.01` of the history distribution. A flag
   (`calibrate_genres`) so the harness measures it on and off.

### 8.2 Order

Hard constraints are already in the query. Fusion → author cap → series rule → calibration →
take `limit`.

### 8.3 Explanations

`Reason` value object: `type` + ids. Chosen per item, first that applies:

1. `because_of(item_id)` — collaborative evidence whose largest term is a favorite or a book
   rated ≥ 4. Spec 2.
2. `interests(category_ids)` — the two highest-weight profile categories the book carries, each
   with `net_c ≥ explain_threshold` (1.0), so the page never says "because you like Fiction".
3. `ranked(position)` — "Ranked #37 of all time" when neither is strong.

Rendered by `Recommendations::ReasonComponent`. Structured so an API can return it later.

## 9. Measuring it

A read-only rake namespace `recommendations:` against the dev database, modeled on
`books:similar:compare`.

### 9.1 `recommendations:eval`

- Seeded sample of 500 users stratified by positive-interaction count: 5–19, 20–99, 100+.
- Per user: hide 20% of favorites and ≥4-rated books (seeded), build the profile from the rest,
  recommend 50 with the user's own criteria, check whether hidden books return.
- Metrics per segment: hit rate@10, recall@50, NDCG@50. Health: catalog coverage, mean global
  rank of recommended books (popularity check), author repeats per page, mean genre KL from
  history.
- Baselines every run: global rank with the user's exclusions; the profile with lift off
  (`lift: false` substitutes raw frequency share for `ln(s_c/p_c)`), which approximates the
  legacy engine closely enough to answer "better than what people pay for today?".
- Every knob is a per-call override; one process sweeps a range. Results and the exact command go
  in `docs/data-quality/recommendations-<date>.md`.

### 9.2 Acceptance before UI ships (increment 2 gate)

On the 20–99 segment the tuned engine must beat both baselines on hit rate@10 and recall@50, with
mean genre KL at or below the lift-off baseline. If it does not, tune or revisit §6 before
building pages on it.

### 9.3 Initial knob values

All in `config/initializers/recommendations.rb`, each a measured-later starting point:

| key | value |
|---|---|
| `free_limit` / `member_limit` | 10 / 50 |
| `candidate_size` | 300 |
| `favorite_weight`, `top_favorite_bonus`, `top_favorite_count` | 2.0, 0.5, 10 |
| `read_weight`, `want_to_read_weight` | 0.4, 0.2 |
| `rating_slope` | 0.75 |
| `pseudo_books` (m) | 10 |
| `min_support`, `min_support_history` | 2, 5 |
| `negative_gamma` | 0.5 |
| `demote_threshold`, `negative_boost` | 1.0, 0.3 |
| `max_genres`, `max_subjects`, `max_locations` | 8, 25, 5 |
| `genre_multiplier`, `subject_multiplier`, `location_multiplier` | 1.0, 0.8, 0.4 |
| `fiction_share_high`, `fiction_share_low` | 0.9, 0.1 |
| `normalization_floor`, `min_score` | 10, 1.0 |
| `rrf_k`, `taste_weight`, `collaborative_half_point`, `rank_prior_weight` | 60, 1.0, 10, 0.3 |
| `max_per_author` | 2 |
| `calibrate_genres`, `calibration_lambda`, `calibration_alpha` | true, 0.3, 0.01 |
| `explain_threshold` | 1.0 |

### 9.4 Recorded experiments (not in this spec)

- Rating centering on the user's own mean with shrinkage.
- Time decay (half-life 2–4 years, floor 0.3 for favorites) — unsafe until the Goodreads
  import's `completed_on` is confirmed to carry through to list items; otherwise every import
  looks read on import day.
- Ranked-only `p_c` (via `Books::BrowseQuery`'s subquery) instead of catalog `item_count`.
- Lowering `rank_prior_weight` or exposing a "deep cuts" setting.

### 9.5 `recommendations:show[user_id]`

Prints the profile, each signal's top 20 with evidence, the fused page, and the reasons.
Replaces the legacy `wtf_user_id` parameter.

## 10. Testing

- **Unit:** profile math (lift, support, negative, fiction share), fusion (weights, rank-prior
  rule), each re-ranker pass, explainer precedence, criteria parsing, the migrator. Fixtures
  include users who **dislike** things and books that must **not** be recommended, so negative
  paths are exercised ([[fixture-corpus-needs-a-negative-class]]). No `assert_empty` as the only
  assertion.
- **Query builder:** assert the OpenSearch JSON for filters, must-nots, per-term shoulds, the
  boosting wrapper, and normalization.
- **Controller:** signed-out → pitch; free → 10 and locked form; member → 50 and editable; empty
  history → wizard redirect; settings POST by a free account rejected. Status and behavior only.
- **Components:** reason component, side-panel profile, locked form.
- **Playwright:** wizard steps 1–4 (add a favorite, rate a book, save preferences), results page,
  locked settings for a free account. Port is checked before running (AGENTS.md).
- Gate: `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, no new
  warnings.

## 11. Delivery

Four increments, each reviewable alone:

1. Config model, criteria class, settings form backend, legacy migration task + launch-todo line.
2. Engine, taste signal, query, harness, first measured tuning pass (§9.2 gate). No UI.
3. Results page, gating, nav entry, pitch page, E2E.
4. Wizard and settings pages, E2E.

Then spec 2. Launch todo gains: the config migration (repeating) and the quarter-star
prerequisite for matching Goodreads.

Docs: `docs/features/recommendations.md` (pipeline, adapter contract, knobs, harness). This spec
stays as the design record.

## 12. Decisions log

- Wizard kept (Shane, 2026-10-07): it is the one page that walks a new user through everything.
- Free 10 / member 50.
- Python batch job for collaborative filtering approved, on the home server, nightly, Rails
  pushes the export and pulls the result — the home server never writes to Rails.
- Engine generic from day one for music and games.
- Legacy configs migrated via `data_migration:all`.
- Half/quarter stars: separate work, in progress by another agent; engine reads numeric ratings.
