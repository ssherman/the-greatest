# Greatest Authors — Design

**Date:** 2026-08-02
**Status:** Approved, ready for planning

## Summary

Add a Greatest Authors section to the books site. Author scores are **derived** from
their ranked books — authors are never ranked from lists. The calculation becomes a
scheduled Sidekiq job instead of a manual `rails console` invocation, and the section
ships with two public pages: a ranked author index at `/authors` and an author show
page at `/author/:slug`.

## Motivation

The old site (`/home/shane/dev/the-greatest-books/admin`) computed author scores in
`Author#set_calculated_score!`, driven by `Author.set_calculated_score` — a `find_each`
over every author, issuing roughly four queries each. Against dev-sized data that is
~58,000 iterations and 200,000+ queries. It was slow enough that it only ever ran
manually from a console, every couple of months.

The work is not actually large. Only **14,945** of 58,223 authors have any ranked book,
and the entire aggregation is a single `GROUP BY` over the 24,242 ranked books —
measured at **34ms** on dev data.

## Measurements (dev database, RC 8 "May 2026")

| Quantity | Value |
| --- | --- |
| `Books::Author` rows | 58,223 |
| `Books::BookAuthor` rows | 126,890 (100% `role: :author`) |
| `Books::Book` rows | 126,275 |
| Ranked books in the primary RC | 24,242 |
| Authors with ≥1 ranked book | 14,945 |
| Authors with ≥2 ranked books | 3,716 |
| Authors with ≥6 ranked books | 557 |
| Authors zeroed by the old formula | 11,229 |
| Authors with a `Description` | 38,195 (66%) |
| Authors with `birth_year` | 23,486 (40%) |
| Authors with `death_year` | 11,990 |
| Authors with an `Image` | **0** |
| Most books for one author | 243 (9 authors >100, 307 >25, p95 = 6) |
| Full aggregation, one query | 34ms |

## What the old formula did, and what is wrong with it

```ruby
return 0 if ranked_books_count == 1
total     = sum of ranked book scores (default RC, score > 0)
book_pen  = {2 => 0.75, 3 => 0.50, 4 => 0.25, 5 => 0.10}.fetch(n, 0.0)
first_year = MIN(first_year_published) across those books
age       = current_year - first_year
age_pen   = age >= 100 ? 0 : 0.01 + 0.79 * (1 - age / 100.0)
score     = total * (1 - book_pen) * (1 - age_pen)
```

Both penalties are inert for the elite — every top-20 author has ≥6 books and a
pre-1926 first book, so ranks 1–20 are nearly identical with or without them. The
damage is concentrated below that:

1. **The age penalty double-counts recency.** `ItemRankings::DatePenalty` already
   discounts a book relative to the publication year of the list that ranked it, and it
   applies to books (`Books::Book#release_year` aliases `first_published_year`, so the
   penalty is live, not a silent no-op). The author-level penalty then subtracts up to a
   further 80%. It is also keyed to the author's **earliest** ranked book, so it rewards
   merely having started publishing long ago: an author active 1990–2020 is penalised as
   though it were 1990. Measured effect — Ishiguro 156→96, Franzen 496→262,
   Donna Tartt 533→271, Achebe 105→86.

2. **Single-book authors are erased.** `return 0 if count == 1` deletes 11,229 authors,
   among them Murasaki Shikibu (*The Tale of Genji*), Boccaccio, Rabelais, Anne Frank,
   Margaret Mitchell, Tocqueville, and John Kennedy Toole.

3. **The count ladder is a cliff.** A worthless sixth book moves an author from ×0.90 to
   ×1.00 — an 11% jump for no real signal. J. D. Salinger (5 books) drops from rank 26 to
   33 purely on the threshold.

4. **Editors would be credited as authors.** The old schema had no role distinction. The
   new `Books::BookAuthor` has `role` (`author`/`editor`); nothing filtered on it.

5. **A hardcoded magic id.** `next if author.id == 10452  # unknown author`. That row
   survived the migration with its id intact: `Books::Author#10452`, name `"Unknown"`,
   71 ranked books, and it currently sorts **first**.

## Decisions

| Decision | Choice |
| --- | --- |
| Score derivation | Sum of ranked book scores × smooth count multiplier |
| Age penalty | **Removed** |
| Single-book authors | Floored, not zeroed |
| Storage | `RankedItem` rows, `item_type: "Books::Author"` |
| RC scoping | One author RC derived from the primary books RC |
| Author lists | Out of scope — authors are derived only |
| Trigger | Daily cron, plus chained off books ranking recalculation |
| Pages | `/authors` index and `/author/:slug` show, both edge-cached |

## Scoring

```
score = SUM(ranked book scores) × count_multiplier(n)

count_multiplier(n) = 1 - (1 - min(n, 6) / 6)²
```

| n | old | new |
| --- | --- | --- |
| 1 | ×0.0000 | ×0.3056 |
| 2 | ×0.2500 | ×0.5556 |
| 3 | ×0.5000 | ×0.7500 |
| 4 | ×0.7500 | ×0.8889 |
| 5 | ×0.9000 | ×0.9722 |
| 6+ | ×1.0000 | ×1.0000 |

Breadth is still rewarded, but continuously: the 5→6 discontinuity shrinks from 11% to
2.9%, and a single-book author keeps 30.6% of their score rather than none. No age
penalty is applied at the author level; book-level recency is already handled by
`ItemRankings::DatePenalty` upstream.

## Architecture

### `ItemRankings::Books::Authors::ScoreFormula`

Pure, no database access.

```ruby
ScoreFormula.call(book_count:, total_score:) # => BigDecimal
```

Isolated so the multiplier ladder and the `n = 1` floor are unit-testable without
fixtures or a ranking configuration.

### `ItemRankings::Books::Authors::Calculator < ItemRankings::Calculator`

Overrides `call` and `item_type` (`"Books::Author"`). `list_type` continues to raise
`NotImplementedError` — authors are derived, never list-ranked.

`call` does three things: run the aggregation query, map rows through `ScoreFormula`
and sort descending, then **delegate to the inherited `update_ranked_items`**. That
parent method already accepts `[{id:, total_score:}]` in rank order, assigns
`rank = index + 1`, upserts on the
`index_ranked_items_on_item_and_ranking_config_unique` constraint, and deletes rows that
dropped out of the ranking — all inside one transaction.

> `ItemRankings::Music::Artists::Calculator` reimplements that upsert (~30 lines).
> This calculator must not copy it; reuse the parent.

Returns the standard `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.

### The aggregation query

```sql
SELECT ba.author_id, COUNT(*) AS n, SUM(ri.score) AS total
FROM ranked_items ri
JOIN books_book_authors ba ON ba.book_id = ri.item_id
JOIN books_authors a       ON a.id = ba.author_id
WHERE ri.item_type = 'Books::Book'
  AND ri.ranking_configuration_id = :books_primary_rc_id
  AND ri.score > 0
  AND ba.role = 0
  AND a.exclude_from_rankings = FALSE
GROUP BY ba.author_id
```

The source configuration is `Books::RankingConfiguration.default_primary`. If it is
absent, the calculator returns a failed `Result` rather than writing an empty ranking.

Co-authors each receive full credit for a shared book. Splitting credit is a larger
editorial change and is deliberately not part of this work.

## Data model changes

1. **`books_authors.exclude_from_rankings`** — `boolean, null: false, default: false`.
   Replaces the hardcoded id check. A data migration sets it `true` where
   `name = 'Unknown'` (exact match; exactly one record today). Exposed as a checkbox on
   the existing books admin author form.

2. **`Books::Authors::RankingConfiguration < ::RankingConfiguration`** — a new STI
   subclass, no new table:

   ```bash
   bin/rails generate model Books::Authors::RankingConfiguration \
     --parent=RankingConfiguration --no-migration --no-fixture
   ```

   `--no-fixture` is mandatory. A generated fixture file for an STI subclass of an
   existing table takes down the entire suite — this cost a debugging cycle during the
   `Books::UserList` work.

   A single global primary row is created in `db/seeds.rb` alongside the other ranking
   configurations, so a fresh setup has one without manual admin work.

3. **`RankingConfiguration#calculator_service`** — add
   `when "Books::Authors::RankingConfiguration"` returning
   `ItemRankings::Books::Authors::Calculator.new(self)`, so `calculate_rankings` and
   `calculate_rankings_async` work generically.

4. **`RankedItem#item_type_matches_ranking_configuration`** — add
   `when "Books::Authors::RankingConfiguration"` asserting the item is a `Books::Author`.
   (`Music::Artists::RankingConfiguration` currently falls through this `case`
   unvalidated; the books branch will not.)

5. **`Books::Author`** — already has `has_many :ranked_items, as: :item`, friendly_id
   slugs, `Describable`, images, and `birth_year`/`death_year`. No association changes
   needed.

## Job and scheduling

`Books::CalculateAuthorRankingsJob`, generated with
`bin/rails generate sidekiq:job books/calculate_author_rankings`. It takes no arguments,
looks up `Books::Authors::RankingConfiguration.default_primary`, and calls
`calculate_rankings`. It logs and re-raises on failure, matching
`Music::CalculateAllArtistsRankingsJob`.

Two triggers:

- **Daily** at `0 4 * * *` (04:00 UTC, off-peak), via a new entry in
  `config/schedule.yml`. sidekiq-cron is already installed and running
  `Search::IndexerJob`.
- **Chained** off the books ranking calculation: in `CalculateRankingsJob`, after a
  successful `calculate_rankings`, enqueue `Books::CalculateAuthorRankingsJob` when the
  configuration is a `Books::RankingConfiguration`. When book ranks change every author
  score is stale by definition; without the chain they stay wrong until the next daily
  run.

The job is idempotent — it recomputes from scratch every run and the upsert plus the
stale-row delete share a transaction, so a failed run needs no recovery and simply waits
for the next trigger.

## Routes

Inside the books `DomainConstraint` block. Order matters: specific paths precede generic
ones, and every numeric segment is constrained.

```ruby
# Ranked authors index. Legacy /authors and /authors/page/N have the same
# shape, so those URLs carry over without a redirect.
get "authors", to: "books/authors/ranked_items#index", as: :books_authors
get "authors/page/1", to: redirect("/authors", status: 301)
get "authors/page/:page", to: "books/authors/ranked_items#index",
  as: :books_authors_page, constraints: {page: /\d+/}

# Show. The rc segment scopes the author's BOOK list, not the author's own rank.
scope "(/rc/:ranking_configuration_id)" do
  get "author/:slug", to: "books/authors#show", as: :author
  get "author/:slug/all-books", to: "books/authors#all_books", as: :author_all_books
  get "author/:slug/all-books/page/:page", to: "books/authors#all_books",
    as: :author_all_books_page, constraints: {page: /\d+/}
end

# Legacy 301s. Author ids were preserved by the migration.
get "authors/view/:view(/page/:page)", to: redirect("/authors", status: 301)
get "authors/:id/all_books", to: "books/legacy_authors#show", constraints: {id: /\d+/}
get "authors/:id", to: "books/legacy_authors#show", constraints: {id: /\d+/}
```

Never place a `constraints:` option on a route nested inside `scope "(/rc/...)"` — it
disables the optimized URL helper and the positional argument binds to the rc segment.

## Controllers, queries, views

| Component | Responsibility |
| --- | --- |
| `Books::Authors::RankedItemsController` | `/authors` index; `Pagy::Method`, `PathBasedPagination`, `Cacheable` |
| `Books::AuthorsController` | `show` and `all_books`; `Cacheable` |
| `Books::LegacyAuthorsController` | 301 from `/authors/:id` to `/author/:slug` |
| `Books::RankedAuthorsQuery` | The single place the ranked-author relation is built |

`Books::LegacyAuthorsController` must use `find_by!(id: params[:id])`, **never** `find`.
`Books::Author` enables friendly_id `:finders`, which resolves slugs before primary keys —
the same landmine that produced the comment in `Books::LegacyBooksController`.

### Index page (`/authors`, 100 per page)

Each row shows rank, author name, birth–death years, score, a truncated description, and
the author's **top 5 ranked book covers**.

**N+1 avoidance.** Rendering top books per author naively is one query per author, 100
per page. Instead the controller issues a single additional query that fetches the
top-ranked books for all 100 authors on the page at once and groups them into a hash
keyed by author id, which the view reads directly. Two queries total for the page, pinned
in a controller test with `assert_queries_count`.

The introductory copy must be rewritten. The old page promised that "older books receive
a small bonus" — that behaviour is being removed, and the text would be false.

### Show page (`/author/:slug`)

- Header: name, birth–death years, primary image.
- Rank and score from the author ranking.
- Primary description.
- Ranked books, unpaginated (p95 is 6 ranked books; the maximum is 71).
- An "All books" link to `/author/:slug/all-books`.

Two states are live in the data today and both must render correctly:

- **No image.** Zero `Books::Author` records have an `Image`. The header degrades to a
  text-only block. Populating author images is separate future work.
- **No rank.** The excluded `"Unknown"` author still resolves at `/author/unknown` and
  has no `RankedItem`. Rank and score are omitted and the page is not marked indexable.

### All-books page (`/author/:slug/all-books`)

The author's full bibliography including unranked books, path-paginated because one
author has 243. Marked `@indexable = false` — it is a thin duplicate view and must not
mint indexable pages behind the edge cache. Bounds are enforced by `pagy_path`, which
raises `ActiveRecord::RecordNotFound` past the last page.

### Navigation

Add an "Authors" entry to the books nav.

## Caching

All three public actions use the existing `Cacheable` concern, which sets Cloudflare
`Cache-Control` headers and calls `skip_session_for_caching` (Cloudflare bypasses the
cache when `Set-Cookie` is present).

| Action | Directive | TTL |
| --- | --- | --- |
| `Books::Authors::RankedItemsController#index` | `cache_for_index_page` | 6h, `stale-while-revalidate=1h` |
| `Books::AuthorsController#show` | `cache_for_show_page` | 24h, `stale-while-revalidate=1h` |
| `Books::AuthorsController#all_books` | `cache_for_show_page` | 24h, `stale-while-revalidate=1h` |

`Books::LegacyAuthorsController#show` issues a 301 and is not given a cache directive.

With a daily recalculation and a 24-hour show TTL, a rank change can be stale at the edge
for up to a day. That is the correct trade for a once-daily ranking, and it matches how
the books and lists pages already behave. No Rails-side fragment caching is introduced;
edge caching via headers is the established pattern in this codebase.

## Error handling

- Missing `Books::RankingConfiguration.default_primary` → the calculator returns a failed
  `Result`; the job logs and raises, and **no** `RankedItem` rows are written. An empty
  ranking must never overwrite a good one.
- Missing `Books::Authors::RankingConfiguration.default_primary` → the job logs and
  raises without doing work.
- The upsert and the stale-row delete share one transaction, so the ranking is never
  partially written.
- Unknown slug on the show page → `ActiveRecord::RecordNotFound` → 404.
- Unknown id on a legacy route → `find_by!` raises → 404.
- Page number past the last page → `pagy_path` raises → 404.

## Testing

Minitest with fixtures and Mocha, mirroring the app namespace under `web-app/test/`.

- **`ScoreFormula`** — the full multiplier ladder (n = 1..7), the `n = 1` floor, and a
  zero total. Pure, no fixtures.
- **`Calculator`** — that `role: :editor` rows are excluded; that
  `exclude_from_rankings` authors are excluded; that books with `score <= 0` are
  excluded; that ranks are contiguous and score-ordered; that `RankedItem`s from a prior
  run which no longer qualify are deleted; and that a missing source RC produces a failed
  `Result` with no writes.
- **`Books::CalculateAuthorRankingsJob`** — success path and the raise-on-failure path.
- **Controllers** — status codes, 301 targets for each legacy route, the 404 paths above,
  and `assert_queries_count` pins on the index preloads. No assertions on HTML, CSS, or
  copy.
- **E2E (Playwright, `web-app/e2e/tests/`)** — `/authors` renders ranked authors,
  `/author/:slug` renders an author with their books, and the "All books" toggle
  navigates. Add `data-testid` attributes only where role, text, or label cannot target
  an element.

Before the work is called done: `bin/rails test` and `bundle exec standardrb`. Do not run
brakeman.

## Suggested build order

Each step leaves the app working and testable on its own.

1. **Data model** — `exclude_from_rankings` column and backfill, the
   `Books::Authors::RankingConfiguration` STI subclass and seed, the
   `calculator_service` branch, and the `RankedItem` validation branch.
2. **Calculation** — `ScoreFormula`, `Calculator`, and their unit tests. Verifiable from
   a console against real data before any UI exists.
3. **Job and scheduling** — `Books::CalculateAuthorRankingsJob`, the `schedule.yml`
   entry, and the `CalculateRankingsJob` chain.
4. **Index page** — `Books::RankedAuthorsQuery`,
   `Books::Authors::RankedItemsController`, the view, routes, nav entry, and the
   `assert_queries_count` pin.
5. **Show and all-books pages** — `Books::AuthorsController`,
   `Books::LegacyAuthorsController`, views, and the legacy 301 routes.
6. **E2E** — Playwright specs for all three pages.

## Out of scope

- **Author lists.** Authors are derived from books only. Adding greatest-author lists is
  possible later — the RC already has `ranked_lists` — but nothing here builds toward it.
- **Per-RC author rankings.** One author RC derived from the primary books RC. Adding a
  pairing column later is a migration, not a rewrite.
- **Author images.** None exist; backfilling them is separate work.
- **Splitting credit between co-authors.** Each co-author receives full book credit.
- **Nationality and category filtered author pages** (the old site's
  `/the-greatest/:category/books/written-by/:country/authors` family).
- **Movies.** Not applicable.

## Landmines

- Reuse `ItemRankings::Calculator#update_ranked_items`; do not copy the music artists
  implementation.
- `find_by!(id:)` in the legacy controller — friendly_id `:finders` resolves slugs first.
- No route `constraints:` inside `scope "(/rc/...)"`.
- `bin/rails generate sidekiq:job`, never `generate job`.
- Rails 8 enum syntax if any enum is touched: `enum :name, {...}`.
- CI eager-loads with `CI=true` and has no `.env`, so it is stricter than a local run.
- The development database is not disposable. Snapshot with `bin/snapshot-dev-db.sh`
  before running any migration or backfill against it.
