# Books Amazon Product Service — Design

**Date:** 2026-08-24
**Branch:** `worktree-books-amazon-product-service`
**Status:** approved design, not yet implemented

## Goal

Bring Amazon product enrichment to the books domain, and collapse the duplication between the
existing music and games services into a shared base class while doing it.

Unlike music and games — where a validated Amazon match becomes an `ExternalLink` and nothing more —
a books match becomes a **`Books::Edition`**. That is what an Amazon book product *is*: a specific
printing with its own ISBN, binding, publisher, page count and price. The legacy application
modelled it that way and every one of the 148,326 editions in the database today came from Amazon
via that path.

Amazon is the site's largest affiliate source (~$1,000/month), so the `ExternalLink` carrying the
partner-tagged `detailPageURL` is a revenue-bearing artifact, not a convenience.

## Current state

### What already exists

`Services::Amazon::Client` (auth, marketplace, fail-loud status check) and
`Services::Amazon::Product` (derived reads such as `lowest_price_cents`) are already the shared
cross-domain layer. `Services::Ai::Tasks::AmazonProductMatchTask` is already a template-method base
class with `domain_name` / `item_description` / `match_criteria` / `non_match_criteria` hooks, and
music and games each subclass it.

What is duplicated is the **orchestrator**. `Services::Music::AmazonProductService` (226 lines) and
`Services::Games::AmazonProductService` (169 lines) run the same `search → AI validate → create
external links` pipeline with near-identical private methods.

### What the books domain looks like

Measured in the development database on 2026-08-24:

| Fact | Count |
| --- | --- |
| `Books::Book` | 126,310 |
| Books with no primary image | 89,199 |
| Books ranked in the primary configuration | 24,242 |
| `Books::Edition` | 148,326 |
| Editions carrying `metadata.amazon` | 148,296 |
| Editions with `page_count` | **0** |
| Amazon `ExternalLink`s on books | **0** |
| Edition-level `Identifier` rows | **18** (openlibrary only) |
| Work-level `books_work_asin` | 79,105 |
| Work-level `books_work_isbn13` | 133,915 |
| `identifiers` table, all domains | 927,466 |

Two consequences drive most of this design:

1. **Every existing edition is a legacy Amazon product**, stored as `metadata: {amazon: {...}}` in
   the old PA-API 5.0 **PascalCase** shape (`"ASIN"`, `"ItemInfo"`). The Creators API returns
   **lowerCamelCase** (`"asin"`, `"itemInfo"`).
2. **There is no edition-level key to match on.** `Services::BooksMigration::EditionIsbnIdentifierMigrator`
   deliberately folded every edition's ISBN/ASIN *up to the work level*. Enrichment that dedupes on
   an edition identifier would therefore create a duplicate for all 148,296 rows unless the
   identifiers are backfilled first.

There is also no `DataImporters::Books` namespace at all, so — unlike music and games — there is no
importer provider to hang the job off.

### What legacy actually did

From `/home/shane/dev/the-greatest-books/admin`, `Book#import_book_editions_and_sales`:

1. `editions.destroy_all`
2. `import_via_title_and_author_search` — `keywords: "<title> <authors>"`, `search_index: "Books"`
3. `sleep(2)`
4. `import_audible_editions` — same keywords plus `browse_node_id: "18145289011"`
5. `sleep(2)`
6. `set_primary_image` — book cover from the most popular *physical* edition, Wikipedia as fallback
7. `set_primary_amazon_url` — book-level affiliate URL from the most popular physical edition

The bulk driver `Book.import_book_editions_directly` walked books in rank order and skipped any whose
editions were refreshed within 7 days.

## Verified against the live API

All confirmed against the real Creators API on 2026-08-24 using the credentials in `web-app/.env`.

A single `searchItems` call returns everything an edition needs:

| `Books::Edition` field | Creators API path |
| --- | --- |
| ASIN | `asin` |
| ISBN-10 / ISBN-13 | `itemInfo.externalIds.isbns.displayValues` |
| EAN-13 | `itemInfo.externalIds.eans.displayValues` |
| `book_binding` | `itemInfo.classifications.binding.displayValue` |
| `publisher_name` | `itemInfo.byLineInfo.manufacturer.displayValue` |
| `publication_year` | `itemInfo.contentInfo.publicationDate.displayValue` |
| `page_count` | `itemInfo.contentInfo.pagesCount.displayValue` |
| `language` | `itemInfo.contentInfo.languages.displayValues` |
| `popularity` | `browseNodeInfo.websiteSalesRank.salesRank` |
| price | `offersV2.listings[].price.money.amount` |
| cover | `images.primary.large.url` |
| affiliate URL | `detailPageURL` |

Two findings worth calling out:

- **`pagesCount` is a genuine unlock.** `page_count` is populated on 0 of 148,326 editions today, and
  `Books::Book` carries a comment saying its work-level `page_range` / `word_count` columns are
  "transitional… should go away when a real per-edition source arrives." This is that source.
- **ISBNs are not universal.** Of the first four Gatsby results, one had ISBNs, two had only EANs,
  and the Kindle edition had neither. **ASIN is the only reliable key.**

The Audible browse node still works on the Creators API: `browse_node_id: "18145289011"` returned 10
Audible editions for Gatsby, **none** of which the plain search returned. Legacy's second pass is
both replicable and genuinely additive.

The full valid resource enum can be recovered at any time by sending a bogus resource name — the 400
response lists every accepted value. (`Services::Amazon::Client` truncates the message to 500 chars,
so read `response.body` directly from a raw `Vacuum` client to see all of it.)

## Design

### 1. Shared base class

New `Services::Amazon::BaseProductService`, alongside `Client` and `Product`.

```
call:  validation_errors → search → AI match → persist_matches → after_persist → result

ABSTRACT (each domain supplies)     SHARED (inherited, private)
  validation_errors                   upsert_external_link(parent:, product:, metadata:)
  search_params                       attach_primary_image(parent:, image_url:)
  match_task_class                    best_product(validated, results)
  persist_match(match, product)       product_for(match, results)
  after_persist(validated, results)   extract_price_cents
    (default: no-op)                  success(message) / failure(error)
```

Each subclass keeps its own one-line `self.call(album:)` / `(game:)` / `(book:)` so existing tests
and both importer providers are untouched.

**The result stays a Hash** — `{success:, data:, error:, errors:}` — not the `Result` struct
CLAUDE.md describes for services generally. 359 lines of existing tests and both existing jobs read
`result[:success]` and `result[:error]`. Changing the shape is a separate, unrelated refactor.

Expected sizes: music 226 → ~55 lines, games 169 → ~45 lines, books ~55 lines.

**One behaviour change while refactoring:** music currently calls the AI task even when the search
returns zero results; it gains games' early return. This is safe — music's
`"No matching products found"` assertion covers the *empty AI validation* path (it mocks a non-empty
search), and games' `"No products found"` assertion covers the *empty search* path. Both stay green.

Music's existing "download the cover from the best-ranked product, unless the album already has a
primary image" step becomes its `after_persist` implementation, using the inherited
`best_product` and `attach_primary_image`. Games leaves `after_persist` as the inherited no-op.

`AMAZON_RESOURCES` moves to the base class as a default; the books subclass overrides it to add
`itemInfo.externalIds` and `itemInfo.contentInfo`.

### 2. Books service and the edition upsert

`Services::Books::AmazonProductService` (~55 lines). Its `persist_match` delegates to
`Services::Books::AmazonEditionUpserter` (~110 lines) so the service stays thin.

**Identity.** `find_or_initialize_by` against the `Identifier` table, **scoped to the book**:

1. Match on `books_edition_asin`.
2. Failing that, match on `books_edition_isbn13` or `books_edition_ean13`.
3. Failing that, build a new edition.

Scoping to the book is what handles the 2,149 ASINs that legacy attached to more than one book. The
ISBN fallback is what stops an Amazon reissue under a fresh ASIN from creating a duplicate edition —
legacy got this free from `find_by_flat_identifiers`, which matched on any identifier.

Where more than one edition in a book matches (2,747 such groups exist in the legacy data), take the
lowest `id` deterministically. Do **not** attempt to merge them; the books record-merge tooling does
not exist yet.

**Field write rules.**

| Field | Rule |
| --- | --- |
| `popularity` | always refresh |
| `metadata` | always overwrite with the new product hash under `amazon` |
| `ExternalLink` `price_cents`, `url` | always refresh |
| `title`, `subtitle` | write only if blank |
| `book_binding` | write only if blank |
| `publisher_name` | write only if blank |
| `publication_year` | write only if blank |
| `page_count` | write only if blank — fills all 148,296 on first pass |
| `language_id` | write only if blank |

The fill-if-blank rule exists because `Admin::Books::EditionsController` permits admins to edit
`title`, `subtitle`, `edition_type`, `book_binding`, `publication_year`, `publisher_name`,
`page_count`, `volume_number`, `language_id` and `popularity`. A blind refresh would silently revert
curated corrections across 148,296 rows. `popularity` is exempt because a stale sales rank actively
breaks "best edition" ordering.

Title handling follows legacy's `AmazonImporterFromUrl#process_title`: strip parenthesised and
bracketed content, then split on the first colon into title and subtitle.

`book_binding` maps Amazon's binding string onto the `Books::Edition` enum
(`hardcover`/`paperback`/`mass_market`/`ebook`/`audiobook`/`library_binding`/`leather_bound`/`other`).
An unrecognised string maps to `other` and logs — it must never raise mid-sweep.

`language_id` comes from the `displayValues` entry whose `type` is `"Published"` — the API returns
several entries per product (`"Published"`, `"Original Language"`, `"Unknown"`), and only the first
describes the printing. Resolve it with an exact `Language.find_by(name:)` against the indexed `name`
column. Leave `language_id` nil when there is no match; **never create a `Language` row** from Amazon
data.

`edition_type` is never written. The model default (`:standard`) applies to new editions, and
existing ones keep whatever they have — Amazon carries no equivalent field.

An AI-returned ASIN that is absent from the merged search results is skipped with a log line. This is
the base class's `product_for` returning nil, and it is the same guard music and games already have.

**Identifiers written per edition:** `books_edition_asin` always; `books_edition_isbn13` /
`books_edition_isbn10` split by length from `externalIds.isbns`; `books_edition_ean13` from
`externalIds.eans`. Always `find_or_initialize_by`, never `build`.

**Per edition** the service also creates an `ExternalLink` (`source: :amazon`,
`link_category: :product_link`, `public: true`, `price_cents`, `detailPageURL`) and attaches the
Amazon cover as that edition's primary image.

**`after_persist` does the two book-level writes**, each guarded on "only if absent":

- **Book cover**, when the book has no primary image. Sourced from the best *physical* edition —
  legacy's `most_popular_normal_edition` is `paperback`/`hardcover`/`mass_market` ordered
  `popularity ASC NULLS LAST`, deliberately excluding ebook and audiobook. 89,199 books stand to gain
  one.
- **Book-level affiliate `ExternalLink`**, the equivalent of legacy's `set_primary_amazon_url`, using
  the same physical-bindings-only rule. The new schema has no `primary_amazon_url` column, so this is
  an `ExternalLink` on the `Books::Book`.

### 3. Search strategy

Two passes, mirroring legacy, merged and de-duplicated by ASIN before a **single** AI call:

1. `keywords: "<book title> <author names>"`, `search_index: "Books"`
2. same keywords, `search_index: "Books"`, `browse_node_id: "18145289011"` (Audible)

`Services::Ai::Tasks::Books::AmazonBookMatchTask` subclasses the existing
`AmazonProductMatchTask`, porting legacy's `AmazonMatchConfirmation` criteria verbatim — study
guides, SparkNotes/CliffsNotes, companions and books *about* the book are non-matches; different
printings, bindings, and formats of the same work are matches. It overrides `format_search_result` to
show Author / Publisher / Publication Date, and its `MatchResult` schema is
`asin`, `title`, `author`, `explanation`.

**Deliberate departure from legacy:** legacy ran `editions.destroy_all` before every re-import, which
is why it never needed edition dedup. We upsert instead. Destroying is incompatible with the
fill-if-blank rule and would wipe the 38,687 `default_edition_id` pointers.

### 4. Identifier backfill (prerequisite)

`rake books:backfill_edition_asins` — one-time, batched, idempotent, resumable. Reads the legacy
PascalCase blob and writes edition-level identifiers:

| identifier_type | source in `metadata.amazon` | rows |
| --- | --- | --- |
| `books_edition_asin` | `ASIN` | 148,296 |
| `books_edition_isbn13` / `books_edition_isbn10` | `ItemInfo.ExternalIds.ISBNs.DisplayValues`, split by length | 78,387 |
| `books_edition_ean13` | `ItemInfo.ExternalIds.EANs.DisplayValues` | 80,397 |

~307,000 new rows against 927,466 existing. Use `insert_all` in batches with `unique_by:` the
existing `index_identifiers_on_lookup_unique`, which makes re-running a no-op and already permits one
ASIN across many editions (10,227 rows need that).

**This must run before the first enrichment sweep**, or every legacy edition gets a duplicate.

Snapshot the development database first: `bin/snapshot-dev-db.sh --label pre-amazon-backfill`.

### 5. Job and triggers

`Books::AmazonProductEnrichmentJob(book_id)`, `sidekiq_options queue: :serial`, raising on failure the
way `Music::AmazonProductEnrichmentJob` does. (`Games::AmazonProductEnrichmentJob` swallows and logs
instead; that inconsistency is left alone rather than widening scope.)

Generate it with `bin/rails generate sidekiq:job books/amazon_product_enrichment`.

**New column:** `books_books.amazon_enriched_at`, nullable datetime, no default (so no table
rewrite). It is required because "did we already try this book?" is not derivable — a book with no
matches creates no edition, so any `MAX(editions.updated_at)` heuristic would re-attempt it forever.

**`lib/tasks/books/amazon.rake`:**

- `books:amazon_enrich[book_id]` — a single book, for development
- `books:amazon_enrich_ranked` — the 24,242 ranked books in rank order, skipping
  `amazon_enriched_at > 7.days.ago`

**No importer this round.** `DataImporters::Books::Book::Providers::Amazon` is deliberately deferred
until there are other books data sources worth importing from. The job takes a `book_id` and the
service takes a book, exactly matching music and games, so that provider is a one-line
`perform_async` when the time comes.

**No admin button this round**, so no new user-facing page and no Playwright test.

### 6. Known limitation: throughput

The `serial` Sidekiq capsule runs one job at a time and is shared by every external-API job across
all domains. Each book costs two Amazon calls, one AI call, and several image downloads.

At roughly 5–15 seconds per book:

- 24,242 ranked books ≈ **1.5–4 days**
- all 126,310 books ≈ **1–3 weeks**

A sweep starves both cover-art jobs and the music recording-ids job for its whole duration.

This is **accepted, not solved, in this work.** The owner's position (2026-08-24) is that the serial
capsule only ever existed to sidestep API errors, that the providers plainly allow concurrent calls,
and that it should eventually be removed or parallelised — but explicitly not as part of this. Do not
add a capsule, a parallel queue, or a concurrency bump here.

**Prerequisite before that removal.** `find_edition` takes no lock, and the
`identifiers` unique index is `(identifiable_type, identifier_type, value,
identifiable_id)` -- scoped per identifiable, so it can never dedupe editions
against each other. The serial capsule is currently the only thing preventing two
concurrent sweeps over the same book from each creating an edition. Un-serialising
the queue therefore turns this into a duplicate-edition bug unless a lock or a
uniqueness constraint is added first.

Ranked-first scoping is therefore the only lever on sweep duration, and it also bounds the two costs
that scale with book count: gpt-5-mini calls and R2 objects for edition covers.

## Testing

**Refactor safety net.** The Amazon-touching suite is green at baseline on this branch: **72 runs,
196 assertions, 0 failures** across `test/lib/services/{music,games}/amazon_product_service_test.rb`,
both job tests, all three AI match-task tests, and `test/lib/services/amazon`. Re-run exactly that
set after the base-class extraction; unchanged results are the proof it is behaviour-preserving.

**New tests:** books service, edition upserter, `AmazonBookMatchTask`, the job, and the backfill task.

**Stubbing.** Mocha on `Services::Amazon::Client.search_items`; never hit the network.
`WebMock::NetConnectNotAllowedError` descends from `Exception`, not `StandardError`, so a missed stub
blows straight past `rescue => e` in a service — that is precisely how the last Amazon breakage hid.

**Fill-if-blank needs paired assertions.** Every such rule gets two tests: the blank field *is*
written, and the populated field *is* preserved. A preserve-test passes trivially against deleted
code, so delete each guard and confirm the test goes red before trusting it.

**Fixtures.** `test/fixtures/books/editions.yml` gains a row carrying legacy PascalCase
`metadata.amazon.ASIN` plus `ItemInfo.ExternalIds`, for the backfill task test.

Full gate before calling anything done: `bin/rails test` and `bundle exec standardrb`.

## Risks

- ~~**Production is still dead.**~~ **Resolved 2026-08-24** — the owner added
  `AMAZON_PRODUCT_API_CRED_ID`, `_SECRET` and `_PARTNER_KEY` to SOPS `secrets/.env.production`
  (file `lastmodified` 2026-08-24T03:20:08Z). This was the loose end from PR #258; music and games
  enrichment go live in production with it, independently of this work.
- **Nested namespace shadowing.** Inside `Services::Books::`, a bare `Books::Book` resolves to the
  nested module. Root-anchor `::Books::Book` in implementation *and* test files. This has bitten this
  codebase at least three times and presents as a confusing `NameError`.
- **Development database is not disposable.** The books data exists only in development and takes
  hours to rebuild. Snapshot before the backfill. Never run a destructive command against it.
- **Worktree and shared test database.** The test database is not isolated per worktree, and this
  worktree's new tables vanish from `the_greatest_test` when anything runs from the main checkout.
  Check `ps aux | grep "[r]ails test"` before running the suite — concurrent runs manufacture phantom
  failures.
- **Migration safety.** `add_column :books_books, :amazon_enriched_at, :datetime` does not rewrite the
  table, but `docker-entrypoint` is `bash -e` and migrates *before* exec'ing the server, so any
  raising migration crash-loops web and 502s all four sites.
- **Image volume.** Per-edition covers could add on the order of 150,000 R2 objects over a full
  sweep. Ranked-first scoping bounds the first run; revisit before going wider.

## Increment order

1. `Services::Amazon::BaseProductService`; refactor music and games onto it. Green suite is the proof.
2. `books:backfill_edition_asins` task; snapshot, then run it in development.
3. `Services::Ai::Tasks::Books::AmazonBookMatchTask`.
4. `Services::Books::AmazonEditionUpserter`.
5. `Services::Books::AmazonProductService`, `Books::AmazonProductEnrichmentJob`, rake tasks.
6. `amazon_enriched_at` migration and sweep scoping.

## Out of scope

- `DataImporters::Books` and its Amazon provider
- An admin "enrich from Amazon" button
- Removing or parallelising the `serial` queue
- Merging the 2,747 duplicate-ASIN edition groups
- Backfilling `Games::AmazonProductEnrichmentJob` to raise like music's
- Any change to the `{success:, data:, error:, errors:}` result Hash
