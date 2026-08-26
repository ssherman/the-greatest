# Similar Books — Design

Date: 2026-08-25
Status: Approved, ready for implementation planning
Scope: Books only. Music and games are explicitly deferred.

## Summary

Port the legacy site's "Similar Books" feature to the new app, with four accuracy
improvements over the original. A card on the book show page lists five similar books;
a "Show more" link leads to a dedicated page showing up to 25 in the standard cover grid.

Similarity is computed live in OpenSearch at render time from the book's genre, subject
and location categories, with genre weighted highest.

## Background: the legacy implementation

`the-greatest-books/admin/app/lib/search/books.rb:416`, `find_similar_books`. One
OpenSearch query against the book index:

- One `term` clause **per category id**, boosted by type: genre 5.0, subject 3.0, location 1.0
- Small nudges: same original language 0.5, same era (±50 years) 0.3, same author 0.1
- `filter` on `ranked: true`, `must_not` the book itself, `min_score: 5`, `minimum_should_match: 1`
- Show page renders 5 results as plain title links in a sidebar

### Why the per-term clauses matter (corrected 2026-08-26)

An earlier draft of this spec claimed these per-term clauses earn **IDF** weighting, so that
sharing a rare category would outscore sharing a common one. **That is false, and it was
measured false.** A `term` query on a `keyword` field scores as a flat `ConstantScore` equal to
its boost, with no rarity component at all:

```
index: "common" on 10 of 10 docs, "rare" on 1 of 10, both boost 1.0
explain: 1.0  ConstantScore(tags:common)
         1.0  ConstantScore(tags:rare)
```

Identical. The legacy site never got rarity weighting either -- same keyword mapping, same
behaviour.

So a candidate's score is `sum of (boost of each shared category)` -- genre matches worth 5
apiece, subject 3, location 1. It counts matches by type; it does not weigh them by how
meaningful they are.

**The per-term clauses are still load-bearing, for a different reason.** N separate `term`
clauses contribute N x boost, so a book sharing four genres outscores one sharing a single
genre. A single `terms` query contributes its boost **once** regardless of how many values
matched, collapsing "shared four genres" and "shared one genre" into the same score. Do not
"simplify" the per-term clauses into a `terms` query.

**Consequence for tuning:** `max_category_item_count` is the **only** mechanism in this design
that acts on category rarity. Rarity decides which categories enter the query; it has no effect
on the score once one is in. That makes the ceiling the highest-leverage knob in the tuning
pass, not a refinement.

## Goals

- Feature parity with the legacy similar-books panel on the book show page
- Four accuracy improvements, each independently switchable via Rails config
- A full similar-books page (25 results) reachable from the card
- Groundwork that a later music/games port can follow, without building for it now

## Non-goals

- Music and games. Their indexes have no category-type split either, and games use
  category types books never do (`theme`, `game_mode`, `player_perspective`). A later
  port adds a sibling search class in the same pattern; no shared base class is built now.
- Suppressing duplicate books from the results. Duplicates scoring near-identical is a
  known and **deliberately retained** property — it surfaces data-quality problems for free.
- An admin similarity-tuning UI. Tuning happens in the initializer, in development.
- Pagination on the full page. The cap is a hard 25.

## Data as of 2026-08-25 (development)

| Fact | Value |
|---|---|
| Books | 126,324 (all `standalone`) |
| Books with ≥1 active category | 126,218 |
| Genre links | 532,182 across 126,218 books (avg 4.22) |
| Subject links | 884,186 across 110,690 books (avg 7.99) |
| Location links | 418,187 across 78,285 books (avg 5.34) |
| Books with list items (`ranked: true`) | 24,362 |
| `Books::Series` / `Books::SeriesBook` | 48 / **17** |
| Books carrying a `theme` category | **0** |

Most common book categories by `item_count`:

| Category | Books | Type |
|---|---|---|
| Fiction | 68,333 | genre |
| Nonfiction | 56,222 | genre |
| Fictional Location | 36,656 | location |
| Identity | 31,658 | subject |
| United States | 29,274 | location |

`Fiction` alone covers 54% of the corpus. Matching on it is close to meaningless.

## A. Index changes

`Search::Books::BookIndex#index_definition` and `Books::Book#as_indexed_json` gain four fields:

| Field | Type | Purpose |
|---|---|---|
| `genre_category_ids` | keyword | tiered boost + required-match filter |
| `subject_category_ids` | keyword | tiered boost |
| `location_category_ids` | keyword | tiered boost |
| `similarity_category_count` | integer | divisor for length normalization |

`similarity_category_count` counts only **active genre + subject + location** categories —
the three types that participate in scoring. Books carry zero `theme` categories, so
nothing else is in play today; counting only the scoring types keeps the divisor honest
if that changes.

`model_includes` already preloads `:categories`, so building these adds no queries.

### LANDMINE: `category_ids` must stay

`CategoryItem#item_supports_category_indexing?` (`app/models/category_item.rb:49`) decides
whether a category change should reindex its item by testing:

```ruby
indexed_data.is_a?(Hash) && indexed_data.key?(:category_ids)
```

Remove or rename `category_ids` and **category edits silently stop reindexing books**.
No exception, no failing test — just a slowly rotting index. The three split fields are
added *alongside* `category_ids`, which also stays because `Books::FilterParams` and saved
searches read it.

### Reindex

Requires `bin/rails search:books:recreate_books`. `Search::Base::Index.reindex_all`
(`app/lib/search/base/index.rb:200`) calls `delete_index` before `create_index`, so
**book search on the live site is down for the duration of the rebuild** — 126,324 books
in batches of 1,000. This is a deliberate, scheduled deploy step, not a casual one.

## B. The query — `Search::Books::Search::BookSimilar`

New class under `app/lib/search/books/search/`, following `BookGeneral`'s shape:
`self.call(book, options = {})` and `self.build_query_definition(...)`, returning
`extract_hits_with_scores(response)`.

```json
{
  "size": "<limit * over_fetch>",
  "min_score": "<config.min_score>",
  "_source": false,
  "query": {
    "function_score": {
      "query": {
        "bool": {
          "filter": [
            {"term": {"ranked": true}},
            {"bool": {"should": ["<genre term clauses, unboosted>"], "minimum_should_match": 1}}
          ],
          "must_not": [
            {"ids": {"values": ["<book.id>", "<same-series sibling ids>"]}}
          ],
          "should": ["<all boosted clauses, genre included>"],
          "minimum_should_match": 1
        }
      },
      "script_score": {
        "script": {
          "source": "_score / Math.sqrt(similarity_category_count, or 1 when absent)"
        }
      },
      "boost_mode": "replace"
    }
  }
}
```

The `should` array, all carried over from legacy and all boost-configurable:

| Clause | Field | Default boost |
|---|---|---|
| one `term` per genre id | `genre_category_ids` | 5.0 |
| one `term` per subject id | `subject_category_ids` | 3.0 |
| one `term` per location id | `location_category_ids` | 1.0 |
| same original language | `original_language_id` | 0.5 |
| same era, `range` ±`era_years` | `first_published_year` | 0.3 |
| one `term` per author id | `author_ids` | 0.1 |

Every one of these is one clause **per id**, never a `terms` query — see "Why the per-term
clauses matter" above. A `terms` query would score a candidate the same whether it shared one
genre or four.

Notes on the structure:

- **Genre clauses appear twice on purpose.** `filter` clauses do not contribute score, so
  requiring a genre match needs its own unscored `bool` in `filter`, while the scored
  genre clauses stay in `should` with their 5.0 boost. This is intentional; do not
  "deduplicate" it.
- `minimum_should_match: 1` is explicit because a `bool` carrying a `filter` defaults its
  should-minimum to 0.
- `_source: false` — only ids and scores are needed. `extract_hits_with_scores` will
  return `source: nil`, which the service ignores.
- The script guards an absent `similarity_category_count` (documents indexed before the
  reindex) by dividing by 1 -- no normalization, rather than erroring.
- `boost_mode: "replace"` because `function_score` otherwise multiplies the script's result
  back into `_score`, squaring the numerator.

### Returns nothing when the source book has no categories

Guard early: if the book has no active genre, subject or location categories, return `[]`
without querying OpenSearch.

## C. The four accuracy improvements

Each is an independent flag. All four default **on**.

### 1. Require a genre match (`require_genre_match`)

Legacy's `minimum_should_match: 1` spans every clause, so a book sharing nothing but a
location — or nothing but a publication era — can appear as "similar". Since genre is the
most important signal, at least one shared genre becomes mandatory whenever the source
book has genres. Subject, location, language, era and author then only re-rank *within*
that set.

If the source book has no genres at all, the filter is omitted and behavior falls back to
legacy's "any match".

### 2. Normalize by category count (`normalize_by_category_count`)

The score is a raw sum over shared categories, so a book tagged with 40 categories has 40
chances to score and a book tagged with 6 has 6. Bloated records outrank tight ones. This
matters more than the original draft assumed: with no rarity weighting in the score, raw match
count is nearly the whole signal, so nothing else pushes back on a bloated record.

Worked example, viewing *Dune*:

| Candidate | Own tags | Shared with Dune | Legacy score | Normalized |
|---|---|---|---|---|
| A | 6 | 5 | 5 | 5 / √6 = **2.04** |
| B | 40 | 8 | **8** | 8 / √40 = 1.26 |

Legacy ranks B first because 8 > 5, but A shares 83% of what it is with Dune while B
shares 20% and its other 32 tags are unrelated. Normalizing picks A.

Square root rather than plain division: plain division over-corrects, making a 2-tag book
sharing 1 tag look like a 50% match and beat everything. Square root still penalizes bloat
while not punishing a thoroughly-catalogued book with 12 good categories. This is the same
adjustment that makes cosine similarity cosine rather than a raw dot product.

### 3. Drop uninformative categories (`drop_common_categories`)

Two knobs, one idea — prefer specific tags:

- `max_categories_per_type` — keep only the N rarest categories of each type
- `max_category_item_count` — drop any category on more books than this

Rarity comes from `Category#item_count`, which is populated (50,639 of 52,772 book
categories have a non-zero count). At a ceiling of 25,000 this cuts `Fiction`,
`Nonfiction`, `Fictional Location`, `Identity` and `United States`.

Selection, per type:

```ruby
by_rarity = scoped.sort_by { |c| [c.item_count.to_i, c.id] }
kept = by_rarity.reject { |c| c.item_count.to_i > max_category_item_count }
kept = by_rarity.first(1) if kept.empty? && by_rarity.any?   # guard
kept.first(max_categories_per_type)
```

**The guard is load-bearing.** A book tagged only `Fiction` would otherwise end up with
zero genres, and with `require_genre_match` on that produces an empty result set. Keeping
the single rarest category when the ceiling would remove them all prevents that.

The `c.id` tie-break is explicit so ordering is deterministic. See the testing section —
tie-breaks that coincide with fixture id order have produced vacuous passing tests in this
codebase before.

### 4. Exclude same-series books (`exclude_same_series`)

Books in the same series are sequels, not similar books, and they share every category so
they dominate. Sibling book ids come from one SQL query through `Books::SeriesBook` and go
into `must_not`.

**This changes almost nothing today** — there are 48 series and 17 `series_books` rows.
It is ~6 lines and it becomes correct the moment series data is populated, which is why it
is included rather than deferred.

## D. Config — `config/initializers/book_similarity.rb`

```ruby
Rails.application.config.x.book_similarity = ActiveSupport::OrderedOptions.new.merge(
  limit: 5,
  page_limit: 25,
  over_fetch: 3,
  min_score: 0,
  require_genre_match: true,
  normalize_by_category_count: true,
  drop_common_categories: true,
  exclude_same_series: true,
  max_categories_per_type: 8,
  max_category_item_count: 25_000,
  max_per_author: 2,
  genre_boost: 5.0,
  subject_boost: 3.0,
  location_boost: 1.0,
  language_boost: 0.5,
  era_boost: 0.3,
  era_years: 50,
  author_boost: 0.1
)
```

The service reads these as **defaults**, each overridable by keyword per call. Tests pin
flags explicitly through keywords rather than mutating global config; development tuning
happens by editing the initializer and restarting.

Changing production behavior requires a code change and a deploy. That is the intended
trade — tuning is a development activity.

### `min_score` cannot be carried over from legacy

Legacy used `min_score: 5`, tuned against its own boost scale. Normalization divides every
score by √(tag count), so the entire scale shifts. It defaults to `0` (disabled). Finding
a useful value is a development tuning step once real results are visible, not a number to
guess in advance.

## E. Service — `Services::Books::SimilarBooks`

`Services::Books` already exists (`app/lib/services/books/amazon_product_service.rb` and
siblings), so no new namespace is created and there is no sibling-shadowing risk.

Returns the standard `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.

Sequence:

1. Return an empty success if the book has no active genre/subject/location categories.
2. Call `Search::Books::Search::BookSimilar` for `limit * over_fetch` hits.
3. Load the candidate books in one query with the preloads below.
4. Apply the per-author cap over hits in score order.
5. Reorder to hit order, take `limit`.
6. Return `data: {books:, more_available:}`.

`more_available` is true when more candidates survived the author cap than `limit` asked
for. The show-page card uses it to decide whether to render the "Show more" link, so a book
with three similar results shows no dead link.

### Per-author cap

```ruby
counts = Hash.new(0)
qualified = []
hits.each do |hit|
  book = books_by_id[hit[:id].to_i]
  next unless book                                   # index drift: row is gone
  author_ids = book.book_authors.map(&:author_id)
  next if author_ids.any? { |id| counts[id] >= max_per_author }
  author_ids.each { |id| counts[id] += 1 }
  qualified << book
end

more_available = qualified.size > limit
books = qualified.first(limit)
```

The loop deliberately does **not** break at `limit`. It runs the cap across every
over-fetched hit, so `more_available` is a fact about the candidate set rather than a
guess. Over-fetch is `limit * over_fetch`, so this is at most 15 iterations for the card
and 75 for the page, over records already loaded.

A book with no authors always passes the cap. A hit whose database row no longer exists is
skipped rather than raising.

Rationale for capping rather than excluding: the legacy 0.1 same-author boost is far too
small to be what causes same-author domination. An author's other books genuinely share
nearly all the same genres and subjects, so they win on merit. Only a cap changes that,
and same-author results are legitimately useful — they just should not fill the panel.

### Preloads — LANDMINE

The full page renders 25 `Books::CardComponent`s, each calling `book.book_authors` **and**
`book.primary_image`. The service must load candidates with the same image chain
`Books::BooksController#show` already preloads:

```ruby
Books::Book
  .where(id: ids)
  .includes(book_authors: :author)
  .includes(primary_image: {file_attachment: {blob: {variant_records: {image_attachment: :blob}}}})
```

Without this, 25 cards produce a large N+1. Pinned by an `assert_queries_count` test.

### Failure handling

An OpenSearch error is rescued into an **empty success**, logged. A search outage costs
the card, not the page. The card and the grid both render nothing rather than erroring.

## F. Show page card

`Books::BooksController#show` sets `@similar_books` and `@more_similar_available`.

A `card bg-base-100 shadow-md` in the right-hand column (`lg:col-span-2`), placed after
Categories, headed "Similar Books". Five `Title by Author` links. The card is omitted
entirely when there are no results — no empty shell.

"Show more" renders below the list only when `more_available` is true, linking to the
similar page and preserving the current ranking configuration prefix.

No flash involvement: public layouts render no flash, and the page is edge-cached.

## G. Full similar-books page

### Route

Mirrors the existing `author/:slug/all-books` precedent:

```ruby
scope "(/rc/:ranking_configuration_id)" do
  get "book/:slug", to: "books/books#show", as: :book
  get "book/:slug/similar", to: "books/books#similar", as: :book_similar,
    constraints: {format: /html/}
end
```

`constraints: {format: /html/}` closes the `(.:format)` axis — `.json`, `.rss` and
arbitrary extensions — the same way the corrections routes had to.

### Why the `/rc/` scope is safe here

The corrections DDoS incident was caused by a route inheriting
`scope "(/rc/:ranking_configuration_id)"` while its controller never read the segment: any
value returned 200 with `public, max-age=86400`, making every distinct value a fresh cache
key and a full render.

`Books::BooksController#similar` **does** call `load_ranking_configuration`, which runs
`RankingConfiguration.find(params[:ranking_configuration_id])`
(`app/controllers/application_controller.rb:99`) and raises `RecordNotFound` on anything
unrecognized. Garbage 404s and is not cached as a success.

**This is a hard requirement, not an incidental detail.** A regression test must pin that
an unknown rc id in the similar URL returns 404.

### Controller

```ruby
before_action :load_ranking_configuration, only: [:show, :similar]
before_action :cache_for_show_page, only: [:show, :similar]
```

Loads the book with `find_by!(slug:)`, never `friendly.find` — 137 books have purely
numeric slugs and friendly_id resolves slugs before primary keys.

Sets `@indexable = @ranked_item.present?`, matching `show`.

### Rendering

`Books::CardComponent` inside `Books::CardComponent::GRID_CONTAINER_CLASS`, with `index:`
passed so the first six covers load eagerly and the rest lazily.

No pagination. The hard cap of 25 keeps this clear of the pagy path-based-paging defects
and the Turbo frame trapped-link guard entirely, and means one OpenSearch query with no
offset handling.

Expect short pages: with `ranked: true` narrowing the pool to 24,362 and a required genre
match, a book with an obscure genre may return well under 25. The grid simply renders short.

### Indexability

Indexable — "books similar to X" is a real search, each page has distinct content, and the
25 internal links help crawling overall.

The mechanism already exists. `books_robots_content` (`app/helpers/books/default_helper.rb:2`)
returns `noindex, follow` when `Books::PublicIndexing` is disabled **or** when
`params[:ranking_configuration_id]` is present, so every `/rc/`-scoped variant is already
excluded and creates no duplicate-content problem. Setting `@indexable` is all the action
needs to do.

## Testing

Search classes in this codebase test against a **real** per-process OpenSearch index
(`test/lib/search/books/search/book_general_test.rb` calls `cleanup_test_index` and
`BookIndex.create_index` in setup). The similarity tests do the same — it is the only way
the `function_score` gets genuinely verified.

| Layer | Coverage |
|---|---|
| `Books::Book#as_indexed_json` | the four new fields; **`category_ids` still present** |
| `Search::Books::BookIndex` | mapping contains the four new fields |
| `Search::Books::Search::BookSimilar` | ordering under each flag, against a real index |
| `Services::Books::SimilarBooks` | author cap, score ordering, no-categories → empty, OpenSearch raising → empty success, `more_available` |
| `Books::BooksController` | `similar` behavior: 200, 404 on unknown slug, **404 on unknown rc id**, `@indexable` both ways |
| N+1 | `assert_queries_count` on the similar page with 25 results |
| Playwright E2E | the card on a book page, and the "Show more" link reaching the grid |

Controller tests assert behavior only — status codes, params, no errors — never markup.

### Test-writing hazards specific to this feature

- **Fixtures are the bulk of the work.** Meaningful ordering tests need fixture books with
  deliberately-designed category spreads: a tight match, a bloated match, a genre-only
  match, a location-only match, two books by one author.
- **Delete the line under test and watch it go red.** `assert_empty` and sort assertions
  have both produced vacuously-passing tests in this codebase — sort tests that coincided
  with fixture id order passed against a deleted branch. Every ordering assertion here
  must be proven to fail when its flag is disabled.
- **Do not assert on absolute scores.** They shift with corpus content. Assert on relative
  order.
- `Sidekiq.testing!(:inline)` is set globally; indexing goes through `SearchIndexRequest`.

## Deploy sequence

1. Merge. Merging to `main` deploys to production.
2. Run `bin/rails search:books:recreate_books` in production, deliberately, at low traffic.
   **Book search is down while the index rebuilds.**
3. The card and page start appearing.

Between step 1 and step 2 the new fields are absent, `require_genre_match` matches nothing,
the service returns empty, and the card is simply not rendered. The similar page renders an
empty grid. Fails quiet, not broken.

## Suggested increments

1. Index fields + `as_indexed_json` + tests (includes proving `category_ids` survives)
2. `Search::Books::Search::BookSimilar` + config initializer + tests against a real index
3. `Services::Books::SimilarBooks` + author cap + preloads + tests
4. Show page card + controller wiring + tests
5. Full similar page: route, action, grid, robots, 404-on-bad-rc regression test, N+1 test
6. Playwright E2E
7. Development tuning pass: settle `min_score`, `max_category_item_count`,
   `max_categories_per_type`, `max_per_author` against real results; record chosen values

## Deferred / open

- **Music and games.** A sibling search class per domain in the same pattern.
- **`min_score` and the ceiling values** are placeholders until the tuning pass.
- **`max_per_author: 2` across 25 slots** forces at least 13 distinct authors, which may be
  tighter than wanted on the full page. Same config value as the card; a tuning question.
- **Duplicate books remain in results**, deliberately. If a books duplicate-merge effort
  starts, this query is the obvious engine for finding candidates.
- **Zero-downtime reindexing** (index aliases) is not built. Every reindex in this codebase
  currently takes search down; that is a pre-existing, site-wide gap.
