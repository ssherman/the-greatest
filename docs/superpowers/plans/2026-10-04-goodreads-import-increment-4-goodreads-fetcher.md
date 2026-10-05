# Goodreads Import Increment 4: Goodreads Fetcher — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Before an import creates a book for an edition the finder could not match, check the
edition against its real Goodreads page. A page that backs it gives the new book its title and
authors. A page that says the id does not exist, or names another book, parks the edition. When no
page can be had, the book is created unverified and a sweep checks it later. Pages are cached
once per Goodreads id and stored gzipped in a private bucket. Fetches go one at a time, at least
15 s apart, at most 1,500 a day, and a block stops them for 6 hours. The legacy app's ~39k
scraped Goodreads rows seed the cache.

**Architecture:**
- **Parsing:** a pure parser (`Books::Goodreads::BookPage`) and an agreement rule
  (`Books::Goodreads::Agreement`) in `app/lib/books/goodreads/`.
- **Storage and pacing:** a new cache table (`books_goodreads_pages`) with an ActiveStorage
  attachment on a new private service, and a Redis gate (`Books::Goodreads::FetchGate`) that hands
  out fetch start times.
- **Fetching:** `Services::Books::GoodreadsPages::FetchPage` fetches and stores one page.
  `Books::Goodreads::FetchPageJob` runs on a dedicated capsule with concurrency 1, and
  `SettleEditionsJob` and `VerifyUnverifiedJob` run around it.
- **Settling:** `Services::Books::GoodreadsImports::SettleEdition` turns a page into
  create, park or unverified.
- **Waiting:** `ResolveEdition` stops creating books itself. An unmatched edition with no cached
  page waits in `verification: pending`, and a fetch is queued once that commits.
- **Legacy seed:** `Services::Books::GoodreadsPages::SeedLegacyPages` loads the legacy app's
  scraped Goodreads rows into the cache.

**Tech Stack:** Rails 8.1, Postgres, ActiveStorage (S3/R2 + Disk), Sidekiq 8 capsules, Redis hashes, Nokogiri,
Minitest 6 + fixtures + Mocha + WebMock.

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md`. The relevant parts are
§3 (`books_goodreads_pages`, Storage), §5 (Outcome, Creating a book), §6 (all of it), §13 and §14.
Increment 4 is listed in §15.

## Measurement (spec §15: "measure ~20 real pages first")

Done before this plan was written, on 2026-10-04: 22 fetches through the deployed page fetcher,
covering 20 real ids and one invented one, fetched 15 s apart. The pages were chosen from the dev
DB's Goodreads ids: classics, translations, multi-author books, a series, a comic, and Chinese and
Czech titles. Six of the pages are committed as fixtures in `web-app/test/fixtures/files/goodreads/pages/`. Their
`apiKey` value, which Goodreads ships to every visitor, is redacted.

- **Source:** 19 of 20 book pages carry Next.js `__NEXT_DATA__`. Its Apollo state names the book
  through the `ROOT_QUERY` entry `getBookByLegacyId({"legacyId":"<id>"})`. One page
  (129650, *Mastering the Art of French Cooking*) came with no `__NEXT_DATA__` at all. The rendered
  markup (`h1[data-testid=bookTitle]`, `.ContributorLink`, `[data-testid=publicationInfo]`, the
  series `h3`) and the schema.org `ld+json` block carry the same facts. Roles are given only for
  the contributors the markup shows.
- **Not found:** an invented id gets **status 200** with `<title>Page not found</title>`, and its
  `__NEXT_DATA__` has no `getBookByLegacyId` entry. A 404 never came.
- **Transient error:** one fetch got status 503 with Goodreads' own "page unavailable" page. The
  same id was a normal page on retry.
- **Selector:** waiting on the book-title `h1` cost 43 s (the full timeout) on the not-found and
  error pages. A bare `h1` matches all three page kinds; with it the invented id took 5.3 s.
- **Time and size:** 4.4–7.5 s per fetch. Raw HTML is 128–802 KB, and 25–179 KB gzipped (median
  about 80 KB). The spec's estimate was 50–150 KB.
- **Roles seen:** Author, Writer (comics), Translator, Illustrator, Editor, Introduction, Preface.
- **Data quirks:**
  - Goodreads' own title data has an unclosed series suffix: `The Corpse in Oozak's Pond (Peter Shandy #6`.
  - A series position can be blank or a range (`1-2`). Every series carries a stable Goodreads
    series id in its URL (`/series/130291-batman-2011`), on both parsing paths.
  - Names can carry double spaces (`Lei  Xu`).
  - `publicationTime` can be missing.
  - Kindle editions have an ASIN and no ISBN.
- **Agreement:** the rule in Task 3 agreed with the dev DB's title and author on all 19 real
  pages. That includes "Miguel de Cervantes" against "Miguel de Cervantes Saavedra", subtitles on
  either side, full-width colons and the unclosed suffix.
- **Legacy `goodreads_books`** (read-only queries against the legacy DB):
  - 223,532 rows in all.
  - 12,088 rows have `last_looked_up_at` set (full page lookups, with series, ISBN, ASIN and
    year).
  - 27,345 more have only `last_refreshed_at` (Goodreads search results: title, authors and year).
  - All other rows came from exports.
  - 608 rows have a non-numeric `goodreads_id`.
  - The legacy writers merge new authors into the existing array (`(authors + new_authors).uniq`).
    So translators and illustrators are in it (Brett Helquist, Thomas Teal), and so is an
    export-created row's original author.

## Global Constraints

- Run every Rails, test and lint command from `web-app/`. Docs live in the root `docs/`.
- Lint is `bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.
- Models are made with `bin/rails generate model …` and jobs with
  `bin/rails generate sidekiq:job …`, then edited. Pass `--skip` to the books model generator so
  `app/models/books.rb` is never touched.
- Inside `module Books`, `module Services` or `module LegacyBooks`, reference other namespaces
  root-anchored: `::Books::GoodreadsPage`, `::PageFetcher::Client`, `::Services::Text::NameNormalizer`.
- The services live in `Services::Books::GoodreadsPages`, **not** `Services::Books::Goodreads`.
  A `Goodreads` constant inside `Services::Books` would shadow `::Books::Goodreads` for any
  unanchored reference there.
- Minitest 6: use `assert_nil`, never `assert_equal nil, …`.
- A clean `bin/rails test` emits no new warnings.
- **CI has no Redis.** Every test of Redis-backed code uses `::Books::OpenLibrary::FakeRedis`, so
  that code may use only `hgetall`, `hset`, `hincrby`, `expire` and `del`.
- **Sidekiq runs inline in tests.** Any test whose code path enqueues a job either stubs that job's
  `perform_async`/`perform_in` or asserts on it with Mocha.
- The development database is shared and not disposable. Migrate with
  `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`; then `git diff db/schema.rb` must show only
  this plan's table and column plus the version line.
- After a new directory under `app/lib` or `app/sidekiq`, `CI=1 bin/rails zeitwerk:check` passes.
- Spec rules every task honors:
  - **Only editions about to create a book are fetched.** Matched editions never touch Goodreads.
  - **One fetch per id, ever.** A `found` or `not_found` page is the answer from then on.
    Blocked and unparseable pages are kept (HTML included) and fetched again.
  - The page is read for **identity facts only**: title, series, contributors with roles, original
    publication year, ISBN-13/10, ASIN. **Descriptions, genres and ratings are never read.**
  - HTML is stored **gzipped, unstripped, on the private `private_imports` service, never served**.
  - Fetches go one at a time on capsule `goodreads_fetch` (concurrency 1). Each start is at least
    `fetch_interval` (15 s) after the last. There are at most `daily_fetch_cap` (1,500) a day. A
    403, a challenge page or an unrecognizable page stops fetching for `block_cooldown` (6 h).
    Pacing comes from a Redis timestamp, **not from sleeping in a thread**.
  - **Never in the critical path:** if the fetcher is down, the gate is closed or the cap is spent,
    the edition is created `unverified`. The sweep verifies it later.
  - Translators, illustrators and editors never become authors.
  - An AI "none of these" still **never falls back to the top search hit**.
  - The legacy seed's facts about an id are trusted. Its link to a legacy Book is not carried over.
  - Postgres errors re-raise.
- Nothing in production calls the resolver yet; the dry-run rake is still the only entry point.
  This increment adds two rakes (`verify_unverified`, `seed_legacy_pages`) and one capsule.

## Decisions this plan makes (carried as rulings)

1. **The legacy seed takes both kinds of scraped row**, about 39.4k: page lookups and search
   results. This is Shane's decision of 2026-10-04. The spec's rule (looked-up rows only) gives
   12,088 rows, while its count (~35.7k) matches the broader set. Cost if wrong: a search-result id
   never gets fetched with full facts.
2. **The parser reads `__NEXT_DATA__` first, then the markup and `ld+json`.** One of 20 pages
   lacked `__NEXT_DATA__`. Cost: a second extraction path to keep working.
3. **Not-found is read from the page, not the status.** A 404 or 410 also counts. Goodreads' own
   5xx error page is **`unavailable`**: nothing is stored, the breaker stays shut, and the fetch is
   retried through the line up to `fetch_attempts` (3) before the edition goes unverified. Cost if
   wrong: one extra fetch per transient error.
4. **`wait_for_selector: "h1"`.** It matches book, not-found and error pages, so no fetch waits out
   its timeout.
5. **Creators are contributors with role Author or Writer.** A different rule applies to agreement,
   which accepts any of:
   - the **primary contributor**, whatever the role (an export's Author column is the primary
     contributor, and for an anthology that is the editor);
   - a creator;
   - a contributor with **no role** (the legacy seed, and names only in `ld+json`).

   But a contributor with no role never becomes an author of a created book. Cost: a book created
   from a markup-only page can miss a co-author, until enrichment.
6. **Agreement.**
   - **Titles** agree when their main titles are equal. A main title is the title normalized,
     with any series suffix (closed or not) removed, cut at the first colon, and with punctuation
     dropped.
   - **Authors** agree when one name's tokens are a subset of the other's.
   - The asymmetry is deliberate. A false mismatch parks a real book from a member's library. A
     false agreement creates a provisional book that an admin reviews anyway.
7. **A verified creation:**
   - takes the page's title (`titleComplete` minus its series suffix, so "(I Mean Noel)" stays);
   - takes the page's creators as authors, with the name that agreed first;
   - prefers the edition's year and ISBNs, falling back to the page's.

   **Series are not linked.** `Books::Series` has no `provisional` flag, so an import-made series
   would show on public pages. Instead the page row keeps **every** series the page names, as a
   `series` jsonb list of `{goodreads_series_id, title, position}`, rather than the spec's single
   `series_name`/`series_number`. A later series backfill (Shane, 2026-10-04) then gets Goodreads'
   own series ids for deduplication without re-parsing stored HTML. Legacy rows carry the name and
   position with no id. Cost: imported books carry no series until that feature exists.
8. **A waiting edition keeps what the settle step needs:**
   - `verification: pending`;
   - its `match_decision`;
   - a new `pending_import_id` (FK, nullify on delete).

   The settle step rebuilds the finder's match from the decision: the books it considered, so a
   turned-down book is still never adopted, plus the decision itself. The finder never runs twice.
   Open Library is asked again, because the finder's in-memory answer is gone. For a verified
   creation it would be asked anyway, since the page's title replaces the edition's. Cost: one
   extra call to the local Open Library service per waiting edition.
9. **Marking an edition pending happens under the signature lock that `CreateBook` takes.** This
   way an edition that another import resolved, or sent to Goodreads, while this one ran the finder
   is left as that import left it.
10. **Parking:**
    - sets the edition `resolution: parked` with `verification: not_found | mismatch`;
    - parks every still-`pending` row of the edition, with detail "not found on Goodreads" or
      "does not match its Goodreads page";
    - takes the decision out of the review queue, because nothing was created to review.
11. **The fetch gate is one Redis hash, written with `FakeRedis`-compatible commands only.** It
    holds a line of start times, a per-UTC-day reservation count, and a block-until time.
    Reservations happen only on the concurrency-1 capsule, so they are serial without Lua.
    Sidekiq's scheduled-job poller can start a job a few seconds late, so two starts can
    occasionally be closer than 15 s. The cap counts reservations, not fetches. Cost if wrong: a
    rare gap of 10 s.
12. **Two jobs for one id can each reserve a turn.** The second finds the page cached and fetches
    nothing, so the cost is one wasted turn, never a second fetch.
13. **Out of scope until increment 6:**
    - moving import status through `verifying` and recounting an import after a late settle;
    - the admin page that shows a later `not_found` or `mismatch` (this increment records it on the
      edition);
    - an admin "refresh this page".
14. **Storage placeholder:** `private_imports` names a placeholder bucket when its variable is
    unset. `has_one_attached` builds its service when the model class loads, and production eager-
    loads, so an unset variable would otherwise crash the boot. Measured:
    `Aws::S3::Resource#bucket(nil)` raises `ArgumentError: missing required option :name`.
    ActiveStorage analysis is skipped for page HTML (`identify: false`,
    `metadata: {analyzed: true}`).
15. **Dry run:** an unmatched edition with no cached page reports "waiting for Goodreads
    verification". A dry run fetches nothing: its savepoint rolls back the pending mark, and the
    fetch is queued only after commit (measured: an `after_all_transactions_commit` block inside a
    rolled-back `requires_new` transaction never runs, in tests too).
16. **Carried to increment 5:** member imports and the replay share one fetch line, with no
    priority between them. The replay must not queue tens of thousands of fetches ahead of members.

## Review Focus

1. **Booting production with `PRIVATE_IMPORTS_STORAGE_*` unset** must succeed. A missing variable
   fails an upload, never the app (Task 1, `PrivateImportsStorageTest`).
2. **A rolled-back dry run queues no fetch and stores no page** (Task 8: the ResolveEdition rollback
   test and DryRun "saves nothing").
3. **An edition another import resolved, or marked pending, while this one ran the finder** keeps
   what that import wrote. There is no second fetch and no overwritten decision (Task 8: the two
   racing-finder tests).
4. **A Goodreads 503 page or a fetcher timeout** caches no verdict, never opens the 6-hour block,
   and never parks a row. After `fetch_attempts`, the edition is created unverified (Task 5: the 503
   test; Task 7: the unavailable test asserts the gate stays open).
5. **A waiting edition whose import is gone, or whose job was lost,** does not wait forever. A
   missing import hands the edition to the latest import with rows, or releases it. The sweep
   re-queues editions pending for more than an hour (Task 6: release tests; Task 7: sweep "stuck").

## File Structure

```
web-app/
  config/storage.yml                                        # + private_imports service
  config/initializers/goodreads.rb                          # new: config.x.goodreads
  config/initializers/sidekiq.rb                            # + goodreads_fetch capsule
  db/migrate/*_create_books_goodreads_pages.rb              # new table
  db/migrate/*_add_pending_import_to_books_goodreads_editions.rb
  app/models/books/goodreads_page.rb                        # new
  app/models/books/goodreads_edition.rb                     # + pending_import, awaiting_goodreads
  app/models/books/goodreads_import.rb                      # + pending_editions
  app/models/legacy_books/goodreads_book.rb                 # new, read-only
  app/lib/books/goodreads/book_page.rb                      # new: parser
  app/lib/books/goodreads/agreement.rb                      # new: verdict
  app/lib/books/goodreads/fetch_gate.rb                     # new: Redis line, cap, block
  app/lib/services/books/goodreads_pages/fetch_page.rb      # new
  app/lib/services/books/goodreads_pages/seed_legacy_pages.rb  # new
  app/lib/services/books/goodreads_imports/settle_edition.rb   # new
  app/lib/services/books/goodreads_imports/create_book.rb      # + page facts, public lock
  app/lib/services/books/goodreads_imports/resolve_edition.rb  # unmatched -> verification
  app/lib/services/books/goodreads_imports/dry_run.rb          # waiting / parked lines
  app/sidekiq/books/goodreads/fetch_page_job.rb             # new
  app/sidekiq/books/goodreads/settle_editions_job.rb        # new
  app/sidekiq/books/goodreads/verify_unverified_job.rb      # new
  lib/tasks/books/goodreads.rake                            # + verify_unverified, seed_legacy_pages
  test/... mirrors each of the above
  test/fixtures/files/goodreads/pages/*                     # committed with this plan
  test/support/goodreads_import_helper.rb                   # + goodreads_page, job stub
docs/features/goodreads-import.md                           # verification + seed sections
docs/features/page-fetcher-service.md                       # HTML-storage exception
deployment/ENV.md                                           # PRIVATE_IMPORTS_STORAGE_*
```

---

### Task 1: Page cache table, pending import, private storage

**Files:**
- Create: `web-app/db/migrate/*_create_books_goodreads_pages.rb`, `web-app/db/migrate/*_add_pending_import_to_books_goodreads_editions.rb`
- Create: `web-app/app/models/books/goodreads_page.rb`, `web-app/test/models/books/goodreads_page_test.rb`, `web-app/test/fixtures/books/goodreads_pages.yml`
- Create: `web-app/test/config/private_imports_storage_test.rb`
- Modify: `web-app/config/storage.yml`, `web-app/app/models/books/goodreads_edition.rb`, `web-app/app/models/books/goodreads_import.rb`, `web-app/test/models/books/goodreads_edition_test.rb`, `web-app/test/models/books/goodreads_import_test.rb`, `deployment/ENV.md`

**Interfaces:**
- Produces:
  - `Books::GoodreadsPage`:
    - enum `source` (`fetched`, `legacy`); enum `outcome` (`found`, `not_found`, `blocked`, `unparseable`) with `prefix: true`, so `outcome_found?`;
    - `scope :conclusive`, `#conclusive?`, `has_one_attached :html` (service `private_imports`);
    - columns `goodreads_book_id`, `fetched_at`, `http_status`, `parser_version`, `title`, `series` (jsonb `[{"goodreads_series_id","title","position"}]`), `authors` (jsonb `[{"name","role","primary"}]`), `original_publication_year`, `isbn13`, `isbn10`, `asin`.
  - `Books::GoodreadsEdition`: `belongs_to :pending_import` and `scope :awaiting_goodreads`.
  - `Books::GoodreadsImport#pending_editions`.
  - Fixtures `books_goodreads_pages(:war_and_peace_page)` (656, found) and `(:invented_page)` (99999999999, not found).

- [ ] **Step 1: Generate the model and the migration**

```bash
cd web-app
bin/rails generate model Books::GoodreadsPage --skip
bin/rails generate migration AddPendingImportToBooksGoodreadsEditions
```

Replace the body of `db/migrate/*_create_books_goodreads_pages.rb`:

```ruby
class CreateBooksGoodreadsPages < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_pages do |t|
      t.bigint :goodreads_book_id, null: false
      t.integer :source, null: false, default: 0
      t.integer :outcome, null: false
      t.datetime :fetched_at, null: false
      t.integer :http_status
      t.integer :parser_version
      t.string :title
      t.jsonb :series, null: false, default: []
      t.jsonb :authors, null: false, default: []
      t.integer :original_publication_year
      t.string :isbn13
      t.string :isbn10
      t.string :asin

      t.timestamps
    end
    add_index :books_goodreads_pages, :goodreads_book_id, unique: true
  end
end
```

Replace the body of `db/migrate/*_add_pending_import_to_books_goodreads_editions.rb`:

```ruby
class AddPendingImportToBooksGoodreadsEditions < ActiveRecord::Migration[8.1]
  def change
    add_reference :books_goodreads_editions, :pending_import, index: true,
      foreign_key: {to_table: :books_goodreads_imports, on_delete: :nullify}
  end
end
```

- [ ] **Step 2: Write the failing tests**

`test/fixtures/books/goodreads_pages.yml` (replace the generated content; annotaterb adds the
header later):

```yaml
war_and_peace_page:
  goodreads_book_id: 656
  source: fetched
  outcome: found
  fetched_at: 2026-10-04 12:00:00
  http_status: 200
  parser_version: 1
  title: War and Peace
  authors: [{"name": "Leo Tolstoy", "role": "Author", "primary": true}, {"name": "Aylmer Maude", "role": "Translator", "primary": false}, {"name": "Louise Maude", "role": "Translator", "primary": false}]
  original_publication_year: 1868
  isbn13: "9780192833983"
  isbn10: "0192833987"

invented_page:
  goodreads_book_id: 99999999999
  source: fetched
  outcome: not_found
  fetched_at: 2026-10-04 12:00:00
  http_status: 200
  parser_version: 1
```

`test/models/books/goodreads_page_test.rb` (keep the generated `require "test_helper"`; replace the class):

```ruby
require "test_helper"

module Books
  class GoodreadsPageTest < ActiveSupport::TestCase
    test "found and not-found pages are conclusive; blocked and unparseable ones are fetched again" do
      blocked = GoodreadsPage.create!(goodreads_book_id: 1, outcome: :blocked, fetched_at: Time.current)
      unparseable = GoodreadsPage.create!(goodreads_book_id: 2, outcome: :unparseable, fetched_at: Time.current)

      assert_equal [books_goodreads_pages(:war_and_peace_page), books_goodreads_pages(:invented_page)].sort_by(&:id),
        GoodreadsPage.conclusive.order(:id).to_a
      assert_equal [true, true, false, false],
        [books_goodreads_pages(:war_and_peace_page), books_goodreads_pages(:invented_page), blocked, unparseable].map(&:conclusive?)
    end

    test "one page per Goodreads id" do
      duplicate = GoodreadsPage.new(goodreads_book_id: 656, outcome: :found, fetched_at: Time.current)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:goodreads_book_id], "has already been taken"
    end

    test "the HTML is kept gzipped on the private imports service" do
      page = books_goodreads_pages(:war_and_peace_page)

      page.html.attach(io: StringIO.new(Zlib.gzip("<html>656</html>")), filename: "goodreads-656.html.gz",
        content_type: "application/gzip", identify: false)

      assert_equal "private_imports", page.html.blob.service_name
      assert_equal "<html>656</html>", Zlib.gunzip(page.html.download)
    end
  end
end
```

Append to `test/models/books/goodreads_edition_test.rb`, inside its class:

```ruby
    test "awaiting_goodreads: editions waiting for their page, and those created before it could be read" do
      waiting = GoodreadsEdition.create!(goodreads_book_id: 1, signature: "a", title: "A", primary_author: "X", verification: :pending)
      unverified = GoodreadsEdition.create!(goodreads_book_id: 2, signature: "b", title: "B", primary_author: "X",
        resolution: :created, verification: :unverified, book: books_books(:war_and_peace), resolved_at: Time.current)
      GoodreadsEdition.create!(goodreads_book_id: 3, signature: "c", title: "C", primary_author: "X",
        resolution: :created, verification: :verified, book: books_books(:war_and_peace), resolved_at: Time.current)
      GoodreadsEdition.create!(goodreads_book_id: 4, signature: "d", title: "D", primary_author: "X",
        resolution: :matched, verification: :not_needed, book: books_books(:war_and_peace), resolved_at: Time.current)

      assert_equal [waiting, unverified].sort_by(&:id), GoodreadsEdition.awaiting_goodreads.order(:id).to_a
    end
```

Append to `test/models/books/goodreads_import_test.rb`, inside its class:

```ruby
    test "deleting an import leaves the editions it was waiting on, with nobody waiting" do
      import = GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
      edition = books_goodreads_editions(:unresolved_edition)
      edition.update!(verification: :pending, pending_import: import)

      import.destroy!

      assert_nil edition.reload.pending_import_id
      assert edition.verification_pending?
    end
```

`test/config/private_imports_storage_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# config/storage.yml's private_imports service (Goodreads import spec §3,
# "Storage"). has_one_attached builds its service when the model class loads,
# and production eager-loads, so the service must build even before its
# bucket is configured: an unset variable must fail an upload, never a boot.
class PrivateImportsStorageTest < ActiveSupport::TestCase
  VARIABLES = %w[PRIVATE_IMPORTS_STORAGE_BUCKET PRIVATE_IMPORTS_STORAGE_ENDPOINT
    PRIVATE_IMPORTS_STORAGE_ACCESS_KEY_ID PRIVATE_IMPORTS_STORAGE_SECRET_ACCESS_KEY].freeze

  setup { @saved = VARIABLES.to_h { |name| [name, ENV[name]] } }
  teardown { @saved.each { |name, value| ENV[name] = value } }

  def service_for(environment, **variables)
    VARIABLES.each { |name| ENV[name] = nil }
    variables.each { |name, value| ENV[name.to_s] = value }
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new(environment))
    configurations = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    ActiveStorage::Service.configure(:private_imports, configurations)
  end

  test "production builds a private S3 service before its bucket is configured" do
    service = service_for("production")

    assert_kind_of ActiveStorage::Service::S3Service, service
    assert_equal ["private-imports-unconfigured", false], [service.bucket.name, service.public?]
  end

  test "production uses the configured bucket, and it is never public" do
    service = service_for("production", PRIVATE_IMPORTS_STORAGE_BUCKET: "tgb-private-imports")

    assert_equal ["tgb-private-imports", false], [service.bucket.name, service.public?]
  end

  test "test, and development without a bucket, keep pages on disk" do
    assert_kind_of ActiveStorage::Service::DiskService, service_for("test")
    assert_kind_of ActiveStorage::Service::DiskService, service_for("development")
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/models/books/goodreads_page_test.rb test/config/private_imports_storage_test.rb`
Expected: errors. The migrations have not run (`PG::UndefinedTable` / pending migration), and
`private_imports` is missing from `storage.yml` (`KeyError: Missing configuration for the
private_imports`).

- [ ] **Step 4: Migrate, write the models and the storage service**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate
git diff db/schema.rb
```

Expected: the diff shows only `books_goodreads_pages`, the `pending_import_id` column, its index
and FK on `books_goodreads_editions`, and the version line.

`app/models/books/goodreads_page.rb` (keep the annotation block the generator left; replace the
class):

```ruby
module Books
  # One Goodreads book page by Goodreads id: the verification cache every
  # import shares (Goodreads import spec §3, §6). One fetch per id: a found or
  # not-found page is the answer from then on. A blocked or unparseable page
  # is kept, with its HTML, for a later look, and is fetched again. Legacy
  # rows (source: legacy) carry the legacy app's scraped facts and no HTML.
  #
  # The HTML is gzipped on the private_imports service, so a parser fix can
  # re-read it without fetching again. It is never served.
  class GoodreadsPage < ApplicationRecord
    enum :source, {fetched: 0, legacy: 1}
    enum :outcome, {found: 0, not_found: 1, blocked: 2, unparseable: 3}, prefix: true

    has_one_attached :html, service: :private_imports

    scope :conclusive, -> { where(outcome: [:found, :not_found]) }

    validates :goodreads_book_id, presence: true, uniqueness: true
    validates :fetched_at, presence: true

    def conclusive?
      outcome_found? || outcome_not_found?
    end
  end
end
```

In `app/models/books/goodreads_edition.rb`, after `belongs_to :match_decision, optional: true`:

```ruby
    # The import whose resolution waits on this edition's Goodreads page; it
    # owns what the page's answer creates.
    belongs_to :pending_import, class_name: "Books::GoodreadsImport", optional: true, inverse_of: :pending_editions
```

and after the enums:

```ruby
    # Editions a Goodreads page settles: waiting to be created or parked, or
    # created before their page could be read.
    scope :awaiting_goodreads, -> { verification_pending.or(created.verification_unverified) }
```

In `app/models/books/goodreads_import.rb`, after `has_many :editions …`:

```ruby
    has_many :pending_editions, class_name: "Books::GoodreadsEdition", foreign_key: :pending_import_id,
      inverse_of: :pending_import, dependent: :nullify
```

In `config/storage.yml`, after the `cloudflare:` block:

```yaml
# Private: Goodreads page HTML, and later uploaded Goodreads exports
# (Goodreads import spec §3, "Storage"). Its own R2 bucket, never public. The
# bucket falls back to a placeholder because has_one_attached builds this
# service when a model loads: an unset variable must fail an upload, not a
# production boot. Test, and a development checkout without the variables,
# use the disk.
private_imports:
<% if Rails.env.test? || (Rails.env.development? && ENV["PRIVATE_IMPORTS_STORAGE_BUCKET"].blank?) %>
  service: Disk
  root: <%= Rails.root.join(Rails.env.test? ? "tmp/storage/private_imports" : "storage/private_imports") %>
<% else %>
  service: S3
  endpoint: <%= ENV.fetch("PRIVATE_IMPORTS_STORAGE_ENDPOINT", ENV["STORAGE_ENDPOINT"]) %>
  access_key_id: <%= ENV["PRIVATE_IMPORTS_STORAGE_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["PRIVATE_IMPORTS_STORAGE_SECRET_ACCESS_KEY"] %>
  region: auto
  bucket: <%= ENV["PRIVATE_IMPORTS_STORAGE_BUCKET"].presence || "private-imports-unconfigured" %>
  request_checksum_calculation: "when_required"
  response_checksum_validation: "when_required"
  public: false
<% end %>
```

In `deployment/ENV.md`, add after the `CLOUDFLARE_ACCESS_CLIENT_ID / CLOUDFLARE_ACCESS_CLIENT_SECRET`
entry (before `### SSL Certificate Configuration`):

```markdown
### Private import storage

#### PRIVATE_IMPORTS_STORAGE_BUCKET / PRIVATE_IMPORTS_STORAGE_ACCESS_KEY_ID / PRIVATE_IMPORTS_STORAGE_SECRET_ACCESS_KEY
- **Description**: The private R2 bucket behind the `private_imports` service in `config/storage.yml`: Goodreads page HTML now, uploaded Goodreads exports from import increment 6. Never the public `cloudflare` bucket, because exports carry members' reviews. Use an R2 token scoped to this bucket only.
- **Required**: Yes, before anything fetches Goodreads pages in production. Unset, the app still boots, but every page store fails.
- **Used By**: web, worker
- **Security**: Never commit; lives in `secrets/.env.production`

#### PRIVATE_IMPORTS_STORAGE_ENDPOINT
- **Description**: The bucket's S3 endpoint
- **Required**: No; defaults to `STORAGE_ENDPOINT` (the same R2 account)
- **Used By**: web, worker
```

Annotate, then check that only this task's files changed:

```bash
bundle exec annotaterb models
git status --short
```

Expected: only the files of `books_goodreads_pages` (model, test, fixture) and
`books_goodreads_editions` (model, test, fixture) gain annotation changes. Revert any other file
annotaterb touched with `git restore <file>`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/ test/config/private_imports_storage_test.rb`
Expected: PASS, 0 failures, 0 errors.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/models/books test/models/books test/config
git add db/migrate db/schema.rb config/storage.yml app/models/books test/models/books test/fixtures/books test/config ../deployment/ENV.md
git commit -m "Goodreads pages: cache table, pending import, private storage service"
```

---

### Task 2: Books::Goodreads::BookPage parser

**Files:**
- Create: `web-app/app/lib/books/goodreads/book_page.rb`
- Test: `web-app/test/lib/books/goodreads/book_page_test.rb`
- Uses fixtures (already committed): `web-app/test/fixtures/files/goodreads/pages/{war_and_peace_656,batman_writers_26067585,series_unclosed_18912323,no_next_data_129650,not_found_99999999999}.html.gz`, `unexpected_error_503.html`, `synthetic_challenge.html`

**Interfaces:**
- Produces:
  - `Books::Goodreads::BookPage.parse(html:, status:)` returns
    `BookPage::Parsed(outcome:, facts:)`, with `#found?`. `outcome` is one of `:found`,
    `:not_found`, `:blocked`, `:unparseable`, `:unavailable`.
  - `BookPage::Facts(goodreads_book_id:, title:, series:, contributors:, original_publication_year:, isbn13:, isbn10:, asin:)`.
  - `BookPage::Series(goodreads_series_id:, title:, position:)`. `series` lists every series the
    page names; `goodreads_series_id` is read from the series URL; `position` is Goodreads' text
    (`"6"`, `"1-2"`) or nil.
  - `BookPage::Contributor(name:, role:, primary:)` with `#creator?`.
  - `BookPage::VERSION` (1), `BookPage::CREATOR_ROLES`, `BookPage::SERIES_SUFFIX`.

- [ ] **Step 1: Write the failing test**

`test/lib/books/goodreads/book_page_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    # The fixtures are real Goodreads pages fetched 2026-10-04 (apiKey
    # redacted), except synthetic_challenge.html: no fetch was ever blocked.
    class BookPageTest < ActiveSupport::TestCase
      def page_html(name)
        path = file_fixture("goodreads/pages/#{name}")
        html = name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread
        html.force_encoding(Encoding::UTF_8)
      end

      def contributors(facts)
        facts.contributors.map { |contributor| [contributor.name, contributor.role, contributor.primary] }
      end

      test "War and Peace from __NEXT_DATA__: translators are contributors, never creators" do
        parsed = BookPage.parse(html: page_html("war_and_peace_656.html.gz"), status: 200)

        facts = parsed.facts
        assert parsed.found?
        assert_equal [656, "War and Peace", [], 1868], [facts.goodreads_book_id, facts.title,
          facts.series, facts.original_publication_year]
        assert_equal ["9780192833983", "0192833987", nil], [facts.isbn13, facts.isbn10, facts.asin]
        assert_equal [["Leo Tolstoy", "Author", true], ["Aylmer Maude", "Translator", false],
          ["Louise Maude", "Translator", false]], contributors(facts)
        assert_equal ["Leo Tolstoy"], facts.contributors.select(&:creator?).map(&:name)
      end

      test "a comic's writers are its creators, its illustrators are not, and the subtitle stays" do
        facts = BookPage.parse(html: page_html("batman_writers_26067585.html.gz"), status: 200).facts

        assert_equal "Batman, Volume 8: Superheavy", facts.title
        assert_equal [BookPage::Series.new(goodreads_series_id: 130291, title: "Batman (2011)", position: nil)], facts.series
        assert_equal ["Scott Snyder", "Brian Azzarello"], facts.contributors.select(&:creator?).map(&:name)
        assert_equal %w[Illustrator Illustrator Illustrator], facts.contributors.reject(&:creator?).map(&:role)
      end

      test "an unclosed series suffix comes off the title and the series is read" do
        facts = BookPage.parse(html: page_html("series_unclosed_18912323.html.gz"), status: 200).facts

        assert_equal ["The Corpse in Oozak's Pond", 1987], [facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 45305, title: "Peter Shandy", position: "6")], facts.series
        assert_equal ["9781453278772", "145327877X", "B009S33K70"], [facts.isbn13, facts.isbn10, facts.asin]
      end

      test "a page without __NEXT_DATA__ is read from its markup and linked data" do
        facts = BookPage.parse(html: page_html("no_next_data_129650.html.gz"), status: 200).facts

        assert_equal [129650, "Mastering the Art of French Cooking", 1961],
          [facts.goodreads_book_id, facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 77378, title: "Mastering the Art of French Cooking", position: "1")],
          facts.series
        assert_equal ["9780375413407", "0375413405"], [facts.isbn13, facts.isbn10]
        assert_equal [["Julia Child", "Author", true], ["Sidonie Coryn", "Illustrator", false],
          ["Louisette Bertholle", "Author", false], ["Simone Beck", nil, false]], contributors(facts)
        assert_equal ["Julia Child", "Louisette Bertholle"], facts.contributors.select(&:creator?).map(&:name)
      end

      test "the markup path reads what __NEXT_DATA__ reads" do
        html = page_html("war_and_peace_656.html.gz").sub(%r{<script id="__NEXT_DATA__".*?</script>}m, "")

        facts = BookPage.parse(html: html, status: 200).facts

        assert_equal [656, "War and Peace", 1868, "9780192833983"],
          [facts.goodreads_book_id, facts.title, facts.original_publication_year, facts.isbn13]
        assert_equal [["Leo Tolstoy", "Author", true], ["Aylmer Maude", "Translator", false],
          ["Louise Maude", "Translator", false]], contributors(facts)
      end

      test "an unknown id is not found even though Goodreads answers 200" do
        parsed = BookPage.parse(html: page_html("not_found_99999999999.html.gz"), status: 200)

        assert_equal [:not_found, nil], [parsed.outcome, parsed.facts]
      end

      test "a 404 or 410 is not found" do
        assert_equal [:not_found, :not_found], [404, 410].map { |status| BookPage.parse(html: "", status: status).outcome }
      end

      test "Goodreads' own error page is unavailable, not an answer, whatever its status" do
        html = page_html("unexpected_error_503.html")

        assert_equal [:unavailable, :unavailable], [503, 200].map { |status| BookPage.parse(html: html, status: status).outcome }
      end

      test "a 401, 403 or 429 is blocked" do
        html = page_html("synthetic_challenge.html")

        assert_equal [:blocked] * 3, [401, 403, 429].map { |status| BookPage.parse(html: html, status: status).outcome }
      end

      test "a page it cannot recognize is unparseable" do
        pages = [page_html("synthetic_challenge.html"), "", %(<script id="__NEXT_DATA__">{not json</script>)]

        assert_equal [:unparseable] * 3, pages.map { |html| BookPage.parse(html: html, status: 200).outcome }
      end

      test "a contributor with no role is unknown, every series is kept, and Goodreads' spacing is folded" do
        apollo = {
          "ROOT_QUERY" => {%(getBookByLegacyId({"legacyId":"7"})) => {"__ref" => "Book:1"}},
          "Book:1" => {"legacyId" => 7, "title" => "Quiet", "titleComplete" => "Quiet (Calm, #2)",
                       "primaryContributorEdge" => {"node" => {"__ref" => "Contributor:1"}, "role" => "Author"},
                       "secondaryContributorEdges" => [{"node" => {"__ref" => "Contributor:2"}, "role" => nil}],
                       "bookSeries" => [{"userPosition" => "2", "series" => {"__ref" => "Series:1"}},
                         {"userPosition" => "", "series" => {"__ref" => "Series:2"}}],
                       "details" => {}, "work" => {"__ref" => "Work:1"}},
          "Contributor:1" => {"name" => "Lei  Xu"},
          "Contributor:2" => {"name" => " Ana Ruiz "},
          "Series:1" => {"title" => "Calm", "webUrl" => "https://www.goodreads.com/series/41-calm"},
          "Series:2" => {"title" => "Quiet Books"},
          "Work:1" => {"details" => {"publicationTime" => nil}}
        }
        html = %(<script id="__NEXT_DATA__" type="application/json">#{{props: {pageProps: {apolloState: apollo}}}.to_json}</script>)

        facts = BookPage.parse(html: html, status: 200).facts

        assert_equal ["Quiet", nil], [facts.title, facts.original_publication_year]
        assert_equal [BookPage::Series.new(goodreads_series_id: 41, title: "Calm", position: "2"),
          BookPage::Series.new(goodreads_series_id: nil, title: "Quiet Books", position: nil)], facts.series
        assert_equal [["Lei Xu", "Author", true], ["Ana Ruiz", nil, false]], contributors(facts)
        assert_equal ["Lei Xu"], facts.contributors.select(&:creator?).map(&:name)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/books/goodreads/book_page_test.rb`
Expected: errors with `NameError: uninitialized constant Books::Goodreads::BookPage`.

- [ ] **Step 3: Write the parser**

`app/lib/books/goodreads/book_page.rb`:

```ruby
# frozen_string_literal: true

require "json"

module Books
  module Goodreads
    # Reads the identity facts from one fetched Goodreads book page (Goodreads
    # import spec §6): canonical title, series, contributors with their roles,
    # original publication year, ISBN-13/10 and ASIN. Descriptions, genres and
    # ratings are never read.
    #
    # Measured on 22 real fetches (2026-10-04):
    # - 19 of 20 book pages carry Next.js __NEXT_DATA__, whose Apollo state
    #   names the book through ROOT_QUERY's getBookByLegacyId entry. One page
    #   came without it; its markup and schema.org ld+json carry the same
    #   facts, with roles only for the contributors the markup shows.
    # - An unknown id is a 200 titled "Page not found", not a 404.
    # - Goodreads' own error page ("page unavailable") came as a 503 and was
    #   gone on retry: it says nothing about the book.
    class BookPage
      VERSION = 1
      # Roles that make a contributor a creator. Translators, illustrators,
      # editors and writers of an introduction or preface never are.
      CREATOR_ROLES = %w[Author Writer].freeze
      # A trailing "(Series, #N)", closed or not: Goodreads' own data has
      # "The Corpse in Oozak's Pond (Peter Shandy #6".
      SERIES_SUFFIX = /\s*\([^()]*#[^()]*\)?\s*\z/
      NOT_FOUND_TITLE = "Page not found"
      ERROR_HEADING = "page unavailable"

      # primary: the contributor Goodreads shows the book "by", which is what
      # an export's Author column holds, whatever the role (an anthology's
      # editor). role nil: unknown.
      Contributor = Data.define(:name, :role, :primary) do
        def creator? = CREATOR_ROLES.include?(role)
      end
      # goodreads_series_id: from the series URL (/series/130291-batman-2011),
      # Goodreads' own key for the series. position: as Goodreads writes it
      # ("6", "1-2"), nil when blank.
      Series = Data.define(:goodreads_series_id, :title, :position)
      Facts = Data.define(:goodreads_book_id, :title, :series, :contributors,
        :original_publication_year, :isbn13, :isbn10, :asin)
      # outcome: :found (facts set), :not_found, :blocked, :unparseable, or
      # :unavailable (Goodreads' error page or a 5xx: try again later).
      Parsed = Data.define(:outcome, :facts) do
        def found? = outcome == :found
      end

      def self.parse(html:, status:)
        new(html: html, status: status).parse
      end

      def initialize(html:, status:)
        @html = html.to_s
        @status = status.to_i
      end

      def parse
        return verdict(:not_found) if [404, 410].include?(@status)
        return verdict(:blocked) if [401, 403, 429].include?(@status)
        return verdict(:unavailable) if @status >= 500

        facts = from_next_data || from_markup
        return Parsed.new(outcome: :found, facts: facts) if facts
        return verdict(:not_found) if doc.at_css("title")&.text.to_s.strip == NOT_FOUND_TITLE
        return verdict(:unavailable) if doc.at_css("h1")&.text.to_s.strip == ERROR_HEADING

        verdict(:unparseable)
      end

      private

      def verdict(outcome) = Parsed.new(outcome: outcome, facts: nil)

      def doc = (@doc ||= Nokogiri::HTML(@html))

      def from_next_data
        script = doc.at_css("script#__NEXT_DATA__") or return nil
        apollo = JSON.parse(script.text).dig("props", "pageProps", "apolloState")
        return nil unless apollo.is_a?(Hash) && apollo["ROOT_QUERY"].is_a?(Hash)

        root_key = apollo["ROOT_QUERY"].keys.find { |key| key.start_with?("getBookByLegacyId") }
        book = root_key && apollo[apollo["ROOT_QUERY"][root_key].to_h["__ref"]]
        return nil unless book.is_a?(Hash) && book["legacyId"]

        details = book["details"].to_h
        isbn13, isbn10 = isbns(details["isbn13"], details["isbn"])
        Facts.new(
          goodreads_book_id: book["legacyId"].to_i,
          title: clean_title(book["titleComplete"].presence || book["title"]),
          series: next_data_series(apollo, book),
          contributors: next_data_contributors(apollo, book),
          original_publication_year: year_from_ms(apollo[book.dig("work", "__ref")].to_h.dig("details", "publicationTime")),
          isbn13: isbn13,
          isbn10: isbn10,
          asin: (details["asin"].presence unless details["asin"] == isbn10)
        )
      rescue JSON::ParserError
        nil
      end

      def next_data_series(apollo, book)
        Array(book["bookSeries"]).filter_map { |entry|
          record = apollo[entry.to_h.dig("series", "__ref")]
          next unless record.is_a?(Hash) && record["title"].present?

          Series.new(goodreads_series_id: series_id(record["webUrl"]), title: record["title"].strip,
            position: entry["userPosition"].presence)
        }.uniq
      end

      def next_data_contributors(apollo, book)
        edges = [book["primaryContributorEdge"], *book["secondaryContributorEdges"]]
        edges.each_with_index.filter_map { |edge, index|
          name = normalize_name(apollo.dig(edge.to_h.dig("node", "__ref"), "name"))
          next if name.nil?

          Contributor.new(name: name, role: edge["role"].presence, primary: index.zero? && !book["primaryContributorEdge"].nil?)
        }.uniq(&:name)
      end

      def from_markup
        heading = doc.at_css('h1[data-testid="bookTitle"]') or return nil
        linked = linked_data
        isbn13, isbn10 = isbns(linked["isbn"])
        Facts.new(
          goodreads_book_id: doc.at_css('link[rel="canonical"]')&.[]("href").to_s[%r{/book/show/(\d+)}, 1]&.to_i,
          title: clean_title(heading.text),
          series: markup_series,
          contributors: markup_contributors(linked),
          original_publication_year: doc.at_css('[data-testid="publicationInfo"]')&.text.to_s[/First published.*?(\d{3,4})\s*\z/, 1]&.to_i,
          isbn13: isbn13,
          isbn10: isbn10,
          asin: nil
        )
      end

      # "Mastering the Art of French Cooking #1": the position follows the last #.
      def markup_series
        doc.css('h3 a[href*="/series/"]').filter_map { |link|
          title, position = link.text.strip.split(/\s+#(?=[^#]*\z)/, 2)
          Series.new(goodreads_series_id: series_id(link["href"]), title: title.strip, position: position.presence) if title.present?
        }.uniq
      end

      # Roles come from the contributors the markup shows (an author has no
      # role label); the rest of the ld+json author list has none (unknown).
      # The markup renders the list twice (desktop and mobile): the first is
      # read.
      def markup_contributors(linked)
        shown = Array(doc.at_css(".ContributorLinksList")&.css(".ContributorLink")).each_with_index.filter_map do |link, index|
          name = normalize_name(link.at_css('[data-testid="name"]')&.text)
          next if name.nil?

          role = link.at_css('[data-testid="role"]')&.text.to_s[/\((.+)\)/, 1]&.strip || "Author"
          Contributor.new(name: name, role: role, primary: index.zero?)
        end
        listed = Array(linked["author"]).filter_map { |person| normalize_name(person["name"]) if person.is_a?(Hash) }
        (shown + listed.map { |name| Contributor.new(name: name, role: nil, primary: false) }).uniq(&:name)
      end

      def linked_data
        doc.css('script[type="application/ld+json"]').each do |script|
          data = JSON.parse(script.text)
          return data if data.is_a?(Hash) && data["@type"] == "Book"
        rescue JSON::ParserError
          next
        end
        {}
      end

      def normalize_name(name)
        ::Services::Text::NameNormalizer.call(name.to_s).presence
      end

      def series_id(url) = url.to_s[%r{/series/(\d+)}, 1]&.to_i

      def clean_title(title) = title.to_s.sub(SERIES_SUFFIX, "").strip.presence

      def isbns(*values)
        normalized = values.filter_map { |value| ::Books::Isbn.normalize(value) }.first
        [normalized&.isbn13, normalized&.isbn10]
      end

      def year_from_ms(milliseconds)
        Time.at(milliseconds / 1000).utc.year if milliseconds.is_a?(Numeric)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/books/goodreads/book_page_test.rb`
Expected: PASS, 11 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/goodreads/book_page.rb test/lib/books/goodreads/book_page_test.rb
git add app/lib/books/goodreads/book_page.rb test/lib/books/goodreads/book_page_test.rb
git commit -m "Goodreads pages: BookPage parser (__NEXT_DATA__, then markup and ld+json)"
```

---

### Task 3: Books::Goodreads::Agreement

**Files:**
- Create: `web-app/app/lib/books/goodreads/agreement.rb`
- Modify: `web-app/app/models/books/goodreads_page.rb`
- Test: `web-app/test/lib/books/goodreads/agreement_test.rb`, `web-app/test/models/books/goodreads_page_test.rb`

**Interfaces:**
- Consumes: `BookPage::Contributor`, `BookPage::SERIES_SUFFIX` (Task 2); `Books::GoodreadsPage#conclusive?`, `#outcome_not_found?` (Task 1); `Books::Goodreads::ExportRow.normalize` (increment 3).
- Produces:
  - `Books::GoodreadsPage#contributors`, which returns `[BookPage::Contributor]`.
  - `Books::Goodreads::Agreement.call(edition:, page:)` returns
    `Agreement::Verdict(outcome:, author_names:)`. `outcome` is `:verified`, `:not_found` or
    `:mismatch`, and `author_names` is empty unless the outcome is verified. It raises
    `ArgumentError` for a page that is not conclusive.

- [ ] **Step 1: Write the failing tests**

Append to `test/models/books/goodreads_page_test.rb`, inside the class:

```ruby
    test "contributors read the authors column; a missing role is unknown" do
      page = GoodreadsPage.new(authors: [{"name" => "Leo Tolstoy", "role" => "Author", "primary" => true},
        {"name" => "Brett Helquist", "role" => nil, "primary" => false}])

      assert_equal [["Leo Tolstoy", "Author", true], ["Brett Helquist", nil, false]],
        page.contributors.map { |contributor| [contributor.name, contributor.role, contributor.primary] }
    end
```

`test/lib/books/goodreads/agreement_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class AgreementTest < ActiveSupport::TestCase
      # authors: [name, role] pairs, the first credited as primary.
      def page(title: "War and Peace", authors: [["Leo Tolstoy", "Author"], ["Aylmer Maude", "Translator"]], outcome: :found)
        ::Books::GoodreadsPage.new(goodreads_book_id: 656, outcome: outcome, fetched_at: Time.current, title: title,
          authors: authors.each_with_index.map { |(name, role), index| {"name" => name, "role" => role, "primary" => index.zero?} })
      end

      def verdict(title: "War and Peace", primary_author: "Leo Tolstoy", page: self.page)
        result = Agreement.call(edition: ::Books::GoodreadsEdition.new(title: title, primary_author: primary_author), page: page)
        [result.outcome, result.author_names]
      end

      test "the same book agrees, and only its creators become authors" do
        assert_equal [:verified, ["Leo Tolstoy"]], verdict
      end

      test "a fuller name on Goodreads still agrees, and the page's spelling is used" do
        quixote = page(title: "Don Quixote", authors: [["Miguel de Cervantes Saavedra", "Author"]])

        assert_equal [:verified, ["Miguel de Cervantes Saavedra"]],
          verdict(title: "Don Quixote", primary_author: "Miguel de Cervantes", page: quixote)
      end

      test "a subtitle, a series suffix, case, punctuation and a full-width colon are no difference" do
        pairs = [
          ["The Great Wall", "The Great Wall: China Against the World, 1000 BC - AD 2000"],
          ["The Corpse In Oozak's Pond", "The Corpse in Oozak's Pond (Peter Shandy #6"],
          ["沙海:荒沙诡影", "沙海：荒沙诡影"],
          ["The Mysterious Disappearance Of Leon", "The Mysterious Disappearance of Leon"]
        ]

        pairs.each do |mine, theirs|
          assert_equal :verified, verdict(title: mine, page: page(title: theirs)).first, "#{mine} vs #{theirs}"
        end
      end

      test "a real Goodreads id under an invented title is a mismatch" do
        assert_equal [:mismatch, []], verdict(title: "War and Peace and Zombies")
      end

      test "the right title under another author is a mismatch" do
        assert_equal [:mismatch, []], verdict(primary_author: "Fyodor Dostoevsky")
      end

      test "a translator's name does not back the edition" do
        assert_equal [:mismatch, []], verdict(primary_author: "Aylmer Maude")
      end

      test "a page with no roles agrees on any name it lists, and only that name becomes the author" do
        legacy = ::Books::GoodreadsPage.new(goodreads_book_id: 335131, outcome: :found, fetched_at: Time.current, title: "The Vile Village",
          authors: [{"name" => "Brett Helquist", "role" => nil, "primary" => false}, {"name" => "Lemony Snicket", "role" => nil, "primary" => false}])

        assert_equal [:verified, ["Lemony Snicket"]], verdict(title: "The Vile Village", primary_author: "Lemony Snicket", page: legacy)
      end

      test "an anthology's editor, credited first, agrees; a contributor inside it does not" do
        anthology = page(title: "The Best American Short Stories 2010", authors: [["Richard Russo", "Editor"], ["Alice Munro", "Contributor"]])

        assert_equal [:verified, ["Richard Russo"]], verdict(title: "The Best American Short Stories 2010", primary_author: "Richard Russo", page: anthology)
        assert_equal :mismatch, verdict(title: "The Best American Short Stories 2010", primary_author: "Alice Munro", page: anthology).first
      end

      test "a comic's writers are its authors" do
        comic = page(title: "Batman, Volume 8: Superheavy",
          authors: [["Scott Snyder", "Writer"], ["Brian Azzarello", "Writer"], ["Greg Capullo", "Illustrator"]])

        assert_equal [:verified, ["Scott Snyder", "Brian Azzarello"]],
          verdict(title: "Batman, Volume 8: Superheavy", primary_author: "Scott Snyder", page: comic)
      end

      test "a not-found page says so" do
        assert_equal [:not_found, []], verdict(page: page(outcome: :not_found, title: nil, authors: []))
      end

      test "a blocked page is no answer" do
        assert_raises(ArgumentError) { verdict(page: page(outcome: :blocked)) }
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/books/goodreads/agreement_test.rb test/models/books/goodreads_page_test.rb`
Expected: errors, with `NameError: uninitialized constant Books::Goodreads::Agreement` and
`NoMethodError: undefined method 'contributors'`.

- [ ] **Step 3: Write the agreement and `contributors`**

In `app/models/books/goodreads_page.rb`, after `conclusive?`:

```ruby
    # authors: [{"name", "role", "primary"}]. role nil is unknown: legacy
    # rows, and names a page lists without one.
    def contributors
      authors.map do |author|
        ::Books::Goodreads::BookPage::Contributor.new(name: author["name"].to_s, role: author["role"].presence,
          primary: author["primary"] == true)
      end
    end
```

`app/lib/books/goodreads/agreement.rb`:

```ruby
# frozen_string_literal: true

module Books
  module Goodreads
    # Whether a Goodreads page backs an edition (Goodreads import spec §6,
    # "Agreement"): its main title is the edition's, and a contributor who may
    # be its author has the edition's primary author's name.
    #
    # Lenient on purpose. A false mismatch parks a real book from a member's
    # library; a false agreement creates a provisional book an admin reviews
    # anyway. Measured 2026-10-04: it agreed with the catalog's title and
    # author on all 19 real pages, "Miguel de Cervantes" against "Miguel de
    # Cervantes Saavedra" included.
    #
    # On a verified page the authors of a new book are the name that agreed
    # and the page's creators; a name with no role never becomes an author.
    class Agreement
      Verdict = Data.define(:outcome, :author_names)

      def self.call(edition:, page:)
        new(edition: edition, page: page).call
      end

      def initialize(edition:, page:)
        raise ArgumentError, "Goodreads page #{page.goodreads_book_id} is not an answer (#{page.outcome})" unless page.conclusive?

        @edition = edition
        @page = page
      end

      def call
        return verdict(:not_found) if @page.outcome_not_found?
        return verdict(:mismatch) unless same_title?(@edition.title, @page.title)

        named = @page.contributors.find { |contributor| credited?(contributor) && same_person?(@edition.primary_author, contributor.name) }
        return verdict(:mismatch) if named.nil?

        creators = @page.contributors.select(&:creator?).map(&:name)
        Verdict.new(outcome: :verified, author_names: [named.name, *creators].uniq)
      end

      private

      # The primary contributor is whom an export names as Author, whatever the
      # role (an anthology's editor); a contributor with no role may be one.
      def credited?(contributor)
        contributor.primary || contributor.role.nil? || contributor.creator?
      end

      def same_title?(mine, theirs)
        mine = main_title(mine)
        mine.present? && mine == main_title(theirs)
      end

      # Normalized, without a series suffix or a subtitle, punctuation dropped.
      def main_title(title)
        ExportRow.normalize(title).sub(BookPage::SERIES_SUFFIX, "").split(":").first.to_s
          .gsub(/[^\p{L}\p{N}]+/, " ").strip
      end

      # One name's words are all in the other: a fuller or shorter form of the
      # same name.
      def same_person?(mine, theirs)
        mine = tokens(mine)
        theirs = tokens(theirs)
        return false if mine.empty? || theirs.empty?

        shorter, longer = [mine, theirs].sort_by(&:size)
        (shorter - longer).empty?
      end

      def tokens(name) = ExportRow.normalize(name).gsub(/[^\p{L}\p{N}]+/, " ").split.uniq

      def verdict(outcome) = Verdict.new(outcome: outcome, author_names: [])
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/books/goodreads/agreement_test.rb test/models/books/goodreads_page_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/books/goodreads app/models/books/goodreads_page.rb test/lib/books/goodreads test/models/books
git add app/lib/books/goodreads/agreement.rb app/models/books/goodreads_page.rb test/lib/books/goodreads/agreement_test.rb test/models/books/goodreads_page_test.rb
git commit -m "Goodreads pages: agreement between an edition and its page"
```

---

### Task 4: Fetch gate and Goodreads config

**Files:**
- Create: `web-app/config/initializers/goodreads.rb`, `web-app/app/lib/books/goodreads/fetch_gate.rb`
- Test: `web-app/test/lib/books/goodreads/fetch_gate_test.rb`

**Interfaces:**
- Produces:
  - `Rails.application.config.x.goodreads`, with `fetch_interval` (15), `daily_fetch_cap`
    (1500), `block_cooldown` (21600), `fetch_attempts` (3), `wait_for_selector` ("h1") and
    `fetch_timeout_ms` (30000).
  - `Books::Goodreads::FetchGate.new(redis: nil, config: nil)`, with:
    - `#reserve`, which returns `FetchGate::Reservation(wait:, refusal:)`. `#granted?` is true
      when `refusal` is nil; `wait` is integer seconds when granted; `refusal` is `:blocked` or
      `:daily_cap`.
    - `#blocked?` and `#block!`.

- [ ] **Step 1: Write the failing test**

`test/lib/books/goodreads/fetch_gate_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class FetchGateTest < ActiveSupport::TestCase
      # CI has no Redis; FakeRedis models the hash commands and expiry. The
      # clock is frozen so a second passing mid-test cannot shift a wait.
      setup do
        freeze_time
        @config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 3, block_cooldown: 6.hours.to_i)
        @gate = FetchGate.new(redis: ::Books::OpenLibrary::FakeRedis.new, config: @config)
      end

      test "the first fetch starts now, and each next one an interval after the one before" do
        assert_equal [0, 15, 30], 3.times.map { @gate.reserve.wait }
      end

      test "once the line has run, the next fetch starts now" do
        2.times { @gate.reserve }
        travel 1.minute

        assert_equal 0, @gate.reserve.wait
      end

      test "the day's cap refuses further fetches until the next UTC day" do
        assert 3.times.map { @gate.reserve }.all?(&:granted?)
        assert_equal :daily_cap, @gate.reserve.refusal

        travel_to(Time.current.utc.tomorrow.beginning_of_day + 1.second)

        assert @gate.reserve.granted?
      end

      test "a block stops every fetch for the cooldown" do
        @gate.block!

        assert_equal [:blocked, true], [@gate.reserve.refusal, @gate.blocked?]

        travel 6.hours

        assert_equal [true, false], [@gate.reserve.granted?, @gate.blocked?]
      end

      test "the defaults are the spec's" do
        config = Rails.application.config.x.goodreads

        assert_equal [15, 1_500, 21_600, 3, "h1", 30_000], [config.fetch_interval, config.daily_fetch_cap,
          config.block_cooldown, config.fetch_attempts, config.wait_for_selector, config.fetch_timeout_ms]
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/books/goodreads/fetch_gate_test.rb`
Expected: errors with `NameError: uninitialized constant Books::Goodreads::FetchGate`.

- [ ] **Step 3: Write the config and the gate**

`config/initializers/goodreads.rb`:

```ruby
# frozen_string_literal: true

# Goodreads page fetching (Goodreads import spec §6, "Politeness"). Rails
# config, not an admin UI. Measured 2026-10-04 on 22 fetches: 4-8 s each,
# 25-180 KB gzipped.
Rails.application.config.x.goodreads = ActiveSupport::OrderedOptions.new.merge(
  # Seconds from one fetch start to the next: at most 240 an hour.
  fetch_interval: 15,
  # Fetches reserved per UTC day.
  daily_fetch_cap: 1_500,
  # How long a 403, a challenge page or a page the parser cannot recognize
  # stops every fetch.
  block_cooldown: 6.hours.to_i,
  # Tries for a fetch that got no answer (Goodreads' 503 page, a timeout)
  # before the edition is created unverified for the sweep.
  fetch_attempts: 3,
  # Matches a book page, the not-found page and Goodreads' error page alike,
  # so no fetch waits out its timeout (the book-title selector cost 43 s on
  # the other two).
  wait_for_selector: "h1",
  fetch_timeout_ms: 30_000
)
```

`app/lib/books/goodreads/fetch_gate.rb`:

```ruby
# frozen_string_literal: true

module Books
  module Goodreads
    # When the next Goodreads page fetch may start (Goodreads import spec §6,
    # "Politeness"). Held in Redis so every worker sees one line. Each
    # reservation takes the next start time, fetch_interval after the last one
    # handed out, and counts against the UTC day's cap; a block refuses every
    # reservation until it ends. The caller waits for its start time by
    # rescheduling itself, never by sleeping.
    #
    # Hash commands only, so CI's FakeRedis can stand in. Read-then-write is
    # not atomic; it needs no lock because only the goodreads_fetch capsule,
    # one job at a time, reserves.
    class FetchGate
      KEY = "goodreads:fetch"
      # Outlives the cooldown and a full day's line.
      MEMORY = 2 * 86_400

      Reservation = Data.define(:wait, :refusal) do
        def granted? = refusal.nil?
      end

      def initialize(redis: nil, config: nil)
        @redis = redis || REDIS_POOL
        @config = config || Rails.application.config.x.goodreads
      end

      def reserve
        state = read
        return refuse(:blocked) if state["blocked_until"].to_i > now

        today = Time.current.utc.strftime("%Y%m%d")
        count = (state["day"] == today) ? state["day_count"].to_i : 0
        return refuse(:daily_cap) if count >= @config.daily_fetch_cap

        start = [now, state["next_start"].to_i].max
        write("next_start" => start + @config.fetch_interval, "day" => today, "day_count" => count + 1)
        Reservation.new(wait: start - now, refusal: nil)
      end

      def blocked?
        read["blocked_until"].to_i > now
      end

      def block!
        Rails.logger.warn("#{self.class.name}: Goodreads blocked a fetch or served an unrecognizable page; " \
          "no fetches for #{@config.block_cooldown}s")
        write("blocked_until" => now + @config.block_cooldown)
      end

      private

      def refuse(reason) = Reservation.new(wait: nil, refusal: reason)

      def read = with_redis { |redis| redis.hgetall(KEY) }

      def write(fields)
        with_redis do |redis|
          fields.each { |field, value| redis.hset(KEY, field, value.to_s) }
          redis.expire(KEY, MEMORY)
        end
      end

      def now = Time.current.to_i

      def with_redis(&block)
        @redis.respond_to?(:with) ? @redis.with(&block) : yield(@redis)
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/books/goodreads/fetch_gate_test.rb`
Expected: PASS, 5 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb config/initializers/goodreads.rb app/lib/books/goodreads/fetch_gate.rb test/lib/books/goodreads/fetch_gate_test.rb
git add config/initializers/goodreads.rb app/lib/books/goodreads/fetch_gate.rb test/lib/books/goodreads/fetch_gate_test.rb
git commit -m "Goodreads pages: fetch gate (line, daily cap, block) and config"
```

---

### Task 5: FetchPage service

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_pages/fetch_page.rb`
- Test: `web-app/test/lib/services/books/goodreads_pages/fetch_page_test.rb`

**Interfaces:**
- Consumes: `PageFetcher::Client#fetch(url, wait_for_selector:, timeout_ms:)` returning a
  `PageFetcher::Page`; `BookPage.parse` (Task 2); `Books::GoodreadsPage` (Task 1);
  `config.x.goodreads` (Task 4).
- Produces: `Services::Books::GoodreadsPages::FetchPage.call(goodreads_book_id:, client: nil)`,
  which returns `Result(success?: true, data: {outcome:, page:})`.
  - `outcome` is one of `:found`, `:not_found`, `:blocked`, `:unparseable`, `:unavailable` or
    `:fetcher_down`.
  - `page` is the stored `Books::GoodreadsPage`, or nil for `:unavailable` and `:fetcher_down`.

- [ ] **Step 1: Write the failing test**

`test/lib/services/books/goodreads_pages/fetch_page_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class FetchPageTest < ActiveSupport::TestCase
        FETCHED_AT = Time.utc(2026, 10, 4, 12)

        def page_html(name)
          path = file_fixture("goodreads/pages/#{name}")
          html = name.end_with?(".gz") ? Zlib.gunzip(path.binread) : path.binread
          html.force_encoding(Encoding::UTF_8)
        end

        def fetched(html, status: 200)
          ::PageFetcher::Page.new(url: "u", final_url: "u", status: status, title: "t", html: html,
            selector_found: true, elapsed_ms: 5_000, fetched_at: FETCHED_AT)
        end

        def client_returning(page)
          stub("page_fetcher").tap { |client| client.stubs(:fetch).returns(page) }
        end

        def client_raising(error)
          stub("page_fetcher").tap { |client| client.stubs(:fetch).raises(error) }
        end

        test "a found page is stored with its facts and its gzipped HTML on the private service" do
          html = page_html("batman_writers_26067585.html.gz")
          client = mock("page_fetcher")
          client.expects(:fetch).with("https://www.goodreads.com/book/show/26067585", wait_for_selector: "h1", timeout_ms: 30_000)
            .returns(fetched(html))

          result = FetchPage.call(goodreads_book_id: 26067585, client: client)

          page = result.data[:page]
          assert_equal :found, result.data[:outcome]
          assert_equal ["fetched", "found", 200, 1, FETCHED_AT], [page.source, page.outcome, page.http_status, page.parser_version, page.fetched_at]
          assert_equal ["Batman, Volume 8: Superheavy", "9781401259693"], [page.title, page.isbn13]
          assert_equal [{"goodreads_series_id" => 130291, "title" => "Batman (2011)", "position" => nil}], page.series
          assert_equal({"name" => "Scott Snyder", "role" => "Writer", "primary" => true}, page.authors.first)
          assert_equal ["private_imports", "application/gzip"], [page.html.blob.service_name, page.html.blob.content_type]
          assert_equal html, Zlib.gunzip(page.html.download).force_encoding(Encoding::UTF_8)
        end

        test "an unknown id is stored as not found" do
          result = FetchPage.call(goodreads_book_id: 99_999_999_998, client: client_returning(fetched(page_html("not_found_99999999999.html.gz"))))

          page = result.data[:page]
          assert_equal [:not_found, true, nil, []], [result.data[:outcome], page.outcome_not_found?, page.title, page.authors]
        end

        test "Goodreads' error page stores nothing and is worth another try" do
          client = client_returning(fetched(page_html("unexpected_error_503.html"), status: 503))

          assert_no_difference("::Books::GoodreadsPage.count") do
            assert_equal [:unavailable, nil], FetchPage.call(goodreads_book_id: 327847, client: client).data.values_at(:outcome, :page)
          end
        end

        test "a challenge page is kept, HTML and all, and the next fetch replaces it" do
          blocked = FetchPage.call(goodreads_book_id: 26067585,
            client: client_returning(fetched(page_html("synthetic_challenge.html"), status: 403))).data[:page]
          html = page_html("batman_writers_26067585.html.gz")

          found = FetchPage.call(goodreads_book_id: 26067585, client: client_returning(fetched(html))).data[:page]

          assert_equal [blocked.id, "found"], [found.id, found.reload.outcome]
          assert_equal html, Zlib.gunzip(found.html.download).force_encoding(Encoding::UTF_8)
        end

        test "a page already answered is never overwritten" do
          client = client_returning(fetched(page_html("not_found_99999999999.html.gz")))

          result = FetchPage.call(goodreads_book_id: 656, client: client)

          assert_equal [:found, "War and Peace"], [result.data[:outcome], books_goodreads_pages(:war_and_peace_page).reload.title]
        end

        test "a fetcher that cannot fetch stores nothing and says so; a timeout is worth another try" do
          cases = {
            ::PageFetcher::Exceptions::CircuitOpenError.new("open") => :fetcher_down,
            ::PageFetcher::Exceptions::ConfigurationError.new("no url") => :fetcher_down,
            ::PageFetcher::Exceptions::ClientError.new("invalid_url", 400) => :fetcher_down,
            ::PageFetcher::Exceptions::TimeoutError.new("slow") => :unavailable,
            ::PageFetcher::Exceptions::UpstreamError.new("upstream_unreachable", 502) => :unavailable
          }

          assert_no_difference("::Books::GoodreadsPage.count") do
            cases.each do |error, outcome|
              assert_equal outcome, FetchPage.call(goodreads_book_id: 1, client: client_raising(error)).data[:outcome], error.class.name
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/books/goodreads_pages/fetch_page_test.rb`
Expected: errors with `NameError: uninitialized constant Services::Books::GoodreadsPages`.

- [ ] **Step 3: Write the service**

`app/lib/services/books/goodreads_pages/fetch_page.rb`:

```ruby
# frozen_string_literal: true

require "zlib"

module Services
  module Books
    module GoodreadsPages
      # Fetches one Goodreads book page through the page fetcher, reads it
      # with Books::Goodreads::BookPage, and stores the answer (Goodreads
      # import spec §6). Pacing is Books::Goodreads::FetchPageJob's: this
      # fetches when called.
      #
      # data[:outcome]:
      # - :found, :not_found: stored, and the answer from now on;
      # - :blocked, :unparseable: stored with the HTML for a later look, and
      #   fetched again later; the caller stops all fetches for a while;
      # - :unavailable: Goodreads' error page, a timeout or a network failure;
      #   nothing stored, worth another try;
      # - :fetcher_down: the page fetcher cannot fetch at all (its breaker is
      #   open, it is not configured, or it refused the request); nothing
      #   stored.
      #
      # The HTML is gzipped whole onto the private service (spec §6, "HTML
      # storage"): stripping it would be a parser decision of its own.
      class FetchPage
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        URL = "https://www.goodreads.com/book/show/%d"
        FETCHER_DOWN = [::PageFetcher::Exceptions::CircuitOpenError, ::PageFetcher::Exceptions::ConfigurationError,
          ::PageFetcher::Exceptions::ClientError].freeze

        def self.call(goodreads_book_id:, client: nil)
          new(goodreads_book_id: goodreads_book_id, client: client).call
        end

        def initialize(goodreads_book_id:, client:)
          @goodreads_book_id = goodreads_book_id.to_i
          @client = client
        end

        def call
          fetched = client.fetch(format(URL, @goodreads_book_id), wait_for_selector: config.wait_for_selector,
            timeout_ms: config.fetch_timeout_ms)
          parsed = ::Books::Goodreads::BookPage.parse(html: fetched.html, status: fetched.status)
          return done(:unavailable) if parsed.outcome == :unavailable

          page = store(parsed, fetched)
          done(page.outcome.to_sym, page)
        rescue *FETCHER_DOWN => e
          Rails.logger.error("#{self.class.name}: Goodreads #{@goodreads_book_id}: #{e.class}: #{e.message}")
          done(:fetcher_down)
        rescue ::PageFetcher::Exceptions::Error => e
          Rails.logger.warn("#{self.class.name}: Goodreads #{@goodreads_book_id}: #{e.class}: #{e.message}")
          done(:unavailable)
        end

        private

        def client = (@client ||= ::PageFetcher::Client.new)

        def config = Rails.application.config.x.goodreads

        # A page another job answered first stands; a blocked or unparseable
        # one is replaced, HTML included.
        def store(parsed, fetched)
          page = ::Books::GoodreadsPage.find_or_initialize_by(goodreads_book_id: @goodreads_book_id)
          return page if page.persisted? && page.conclusive?

          facts = parsed.facts
          page.assign_attributes(
            source: :fetched, outcome: parsed.outcome, fetched_at: fetched.fetched_at, http_status: fetched.status,
            parser_version: ::Books::Goodreads::BookPage::VERSION,
            title: facts&.title,
            series: Array(facts&.series).map { |s| {"goodreads_series_id" => s.goodreads_series_id, "title" => s.title, "position" => s.position} },
            authors: Array(facts&.contributors).map { |c| {"name" => c.name, "role" => c.role, "primary" => c.primary} },
            original_publication_year: facts&.original_publication_year,
            isbn13: facts&.isbn13, isbn10: facts&.isbn10, asin: facts&.asin
          )
          page.html.attach(io: StringIO.new(Zlib.gzip(fetched.html)), filename: "goodreads-#{@goodreads_book_id}.html.gz",
            content_type: "application/gzip", identify: false, metadata: {analyzed: true})
          page.save!
          page
        end

        def done(outcome, page = nil)
          Result.new(success?: true, data: {outcome: outcome, page: page}, errors: [])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/books/goodreads_pages/fetch_page_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS, 6 runs, 0 failures; `All is good!`.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/goodreads_pages test/lib/services/books/goodreads_pages
git add app/lib/services/books/goodreads_pages test/lib/services/books/goodreads_pages
git commit -m "Goodreads pages: FetchPage fetches, reads and stores one page"
```

---

### Task 6: SettleEdition, and CreateBook from a page

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/settle_edition.rb`
- Modify: `web-app/app/lib/services/books/goodreads_imports/create_book.rb`, `web-app/test/support/goodreads_import_helper.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/settle_edition_test.rb`, `web-app/test/lib/services/books/goodreads_imports/create_book_test.rb`

**Interfaces:**
- Consumes: `Agreement.call` (Task 3); `GoodreadsEdition#pending_import`, `GoodreadsImport` (Task 1); increment 3's `CreateBook.call(edition:, import:, match:, importer:)`, `GoodreadsImportHelper#goodreads_edition`, `#unmatched_match`.
- Produces:
  - `CreateBook.call(..., page: nil, author_names: nil)`. With a page, the book takes the page's
    title and the given author names, and the edition becomes `verification: verified`. Without
    one, the book takes the edition's facts and the edition becomes `unverified`. Either way
    `pending_import` is cleared.
  - `CreateBook.lock(edition)`, a public class method.
  - `SettleEdition.call(edition:, page:, match: nil, import: nil, importer: Importer)`, which
    returns `Result(data: {edition:, outcome:})`. `outcome` is one of `:created`, `:matched`
    (adopted), `:parked`, `:cached`, `:released`, `:rechecked` or `:unchanged`.
  - `SettleEdition::PARKED_DETAIL`.
  - Test helper `goodreads_page(goodreads_book_id:, title: "The Quiet Year", authors: [["Anna Brenner", "Author"]], outcome: :found, **attributes)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/support/goodreads_import_helper.rb`, after `goodreads_edition`:

```ruby
  # A cached Goodreads page. authors: [name, role] pairs, the first credited
  # as primary. The defaults back goodreads_edition's defaults.
  def goodreads_page(goodreads_book_id:, title: "The Quiet Year", authors: [["Anna Brenner", "Author"]], outcome: :found, **attributes)
    found = outcome.to_sym == :found
    ::Books::GoodreadsPage.create!({
      goodreads_book_id: goodreads_book_id, source: :fetched, outcome: outcome, fetched_at: Time.current,
      title: (title if found),
      authors: found ? authors.each_with_index.map { |(name, role), index| {"name" => name, "role" => role, "primary" => index.zero?} } : []
    }.merge(attributes))
  end
```

Append to `test/lib/services/books/goodreads_imports/create_book_test.rb`, inside the class:

```ruby
        test "with its Goodreads page, the book takes the page's title and authors, and the edition is verified" do
          edition = goodreads_edition(goodreads_book_id: 90_000_001, original_publication_year: 1977, pending_import: @import,
            verification: :pending)
          page = goodreads_page(goodreads_book_id: 90_000_001, title: "The Quiet Year: A Novel", isbn13: "9780441013593")

          CreateBook.call(edition: edition, import: @import, match: unmatched_match(subject: edition), page: page,
            author_names: ["Anna Brenner", "Jo Ray"])

          edition.reload
          book = edition.book
          assert_equal ["The Quiet Year: A Novel", 1977, true], [book.title, book.first_published_year, book.provisional?]
          assert_equal ["Anna Brenner", "Jo Ray"], book.authors.map(&:name).sort
          assert_includes book.identifiers.map { |identifier| [identifier.identifier_type, identifier.value] },
            ["books_work_isbn13", "9780441013593"]
          assert_equal [true, true, nil], [edition.created?, edition.verification_verified?, edition.pending_import_id]
        end
```

`test/lib/services/books/goodreads_imports/settle_edition_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class SettleEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          stub_resolution_services
          @import = ::Books::GoodreadsImport.create!(user: users(:editor_user), status: :verifying)
        end

        # An edition the finder left unmatched, waiting for its page, with
        # one row in the given import.
        def waiting_edition(import: @import, needs_review: false, candidates: [], **attributes)
          edition = goodreads_edition(**attributes)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
            confidence: :high, decided_by: :rule, needs_review: needs_review, candidates: candidates)
          edition.update!(verification: :pending, match_decision: decision, pending_import: import)
          add_row(import, edition)
          edition
        end

        def add_row(import, edition)
          import.rows.create!(row_number: import.rows.count + 1, goodreads_edition: edition)
        end

        test "a page that backs the edition creates a provisional book from the page's facts, verified" do
          edition = waiting_edition(goodreads_book_id: 90_000_001)
          page = goodreads_page(goodreads_book_id: 90_000_001, title: "The Quiet Year: A Novel",
            authors: [["Anna Brenner", "Author"], ["Kit Ober", "Translator"], ["Jo Ray", "Author"]])

          result = SettleEdition.call(edition: edition, page: page)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_equal ["The Quiet Year: A Novel", true], [edition.book.title, edition.book.provisional?]
          assert_equal ["Anna Brenner", "Jo Ray"], edition.book.authors.map(&:name).sort
          assert_equal [true, nil], [edition.verification_verified?, edition.pending_import_id]
          assert_includes @import.records.map(&:record), edition.book
        end

        test "a page that says the id does not exist parks the edition and its waiting rows; nothing is created" do
          edition = waiting_edition(needs_review: true)
          page = goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)

          assert_no_difference("::Books::Book.count") do
            assert_equal :parked, SettleEdition.call(edition: edition, page: page).data[:outcome]
          end

          edition.reload
          row = edition.import_rows.sole
          assert_equal [true, true, nil], [edition.parked?, edition.verification_not_found?, edition.pending_import_id]
          assert edition.resolved_at.present?
          assert_equal ["parked", "not found on Goodreads"], [row.outcome, row.outcome_detail]
          assert_not edition.match_decision.needs_review
        end

        test "a page about another book parks it as a mismatch" do
          edition = waiting_edition
          page = goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "Something Else Entirely")

          SettleEdition.call(edition: edition, page: page)

          assert_equal [true, "does not match its Goodreads page"],
            [edition.reload.verification_mismatch?, edition.import_rows.sole.outcome_detail]
        end

        test "with no page the book is created unverified, for the sweep" do
          edition = waiting_edition

          assert_equal :created, SettleEdition.call(edition: edition, page: nil).data[:outcome]

          assert_equal [true, true], [edition.reload.created?, edition.verification_unverified?]
        end

        test "the finder never runs again, and a book it turned down is still not adopted" do
          turned_down = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          goodreads_edition(goodreads_book_id: 90_000_010, book: turned_down, resolution: :created, resolved_at: Time.current)
          edition = waiting_edition(candidates: [{"record_type" => "Books::Book", "record_id" => turned_down.id}])
          ::DataImporters::Books::Book::Finder.any_instance.expects(:call).never

          assert_equal :created, SettleEdition.call(edition: edition, page: nil).data[:outcome]

          edition.reload
          assert_not_equal turned_down, edition.book
          assert_equal edition.book, edition.match_decision.record
        end

        test "the import that waited owns what is created, not a later one" do
          edition = waiting_edition
          later = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          add_row(later, edition)

          SettleEdition.call(edition: edition, page: nil)

          assert_includes @import.records.map(&:record), edition.reload.book
          assert_empty later.records
        end

        test "with the waiting import gone, the latest import with rows on the edition owns it" do
          edition = waiting_edition
          later = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          add_row(later, edition)
          edition.update!(pending_import: nil)

          SettleEdition.call(edition: edition, page: nil)

          assert_includes later.records.map(&:record), edition.reload.book
        end

        test "with no import left the edition is released, and nothing is created" do
          edition = goodreads_edition(verification: :pending)

          assert_no_difference("::Books::Book.count") do
            assert_equal :released, SettleEdition.call(edition: edition, page: nil).data[:outcome]
          end
          assert edition.reload.verification_not_needed?
        end

        test "settling twice makes one book, and parking twice parks once" do
          created = waiting_edition(goodreads_book_id: 90_000_001)
          parked = waiting_edition(goodreads_book_id: 90_000_002)
          missing = goodreads_page(goodreads_book_id: 90_000_002, outcome: :not_found)

          assert_difference("::Books::Book.count", 1) do
            2.times { SettleEdition.call(edition: ::Books::GoodreadsEdition.find(created.id), page: nil) }
          end
          outcomes = 2.times.map { SettleEdition.call(edition: ::Books::GoodreadsEdition.find(parked.id), page: missing).data[:outcome] }

          assert_equal [:parked, :cached], outcomes
        end

        test "an edition created unverified is checked later, and its book is left alone" do
          book = ::Books::Book.create!(title: "The Quiet Year", provisional: true)
          edition = goodreads_edition(book: book, resolution: :created, verification: :unverified, resolved_at: 1.day.ago)

          assert_equal :unchanged, SettleEdition.call(edition: edition, page: nil).data[:outcome]
          assert_equal :rechecked,
            SettleEdition.call(edition: edition, page: goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)).data[:outcome]

          edition.reload
          assert_equal [true, book, true], [edition.verification_not_found?, edition.book, book.reload.provisional?]
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/settle_edition_test.rb test/lib/services/books/goodreads_imports/create_book_test.rb`
Expected: errors, with `NameError: uninitialized constant …SettleEdition` and
`ArgumentError: unknown keywords: :page, :author_names`.

- [ ] **Step 3: Extend CreateBook, write SettleEdition**

Replace `app/lib/services/books/goodreads_imports/create_book.rb` with:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Creates the provisional book for an edition the finder could not
      # match, and records what it made (Goodreads import spec §5, "Creating a
      # book" and "Locking").
      #
      # The advisory lock is keyed by the edition's signature (normalized
      # title plus primary author), so two imports racing to create one book,
      # through the same Goodreads id or two editions of the same title and
      # author, take turns here. Under the lock the edition is re-read (the
      # other import may have resolved it), then editions with the same
      # signature are checked for a book created since the finder looked.
      # Only then is a book created. Books the finder already considered are
      # left out of that check: a book it saw and turned down, an AI "none"
      # included, stays turned down.
      #
      # The book goes through the book importer with the finder's match (no
      # second finder run), provisional, with the edition's identifiers
      # stamped and no enrichment; enrichment runs on admin approval. A book
      # backed by its Goodreads page (SettleEdition) takes the page's title and
      # the authors the page agreed on, and is verified; any other is
      # unverified.
      class CreateBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        CreateFailed = Class.new(StandardError)

        # The subquery gives the result a type the adapter knows:
        # pg_advisory_xact_lock returns void (see Services::Billing::ReconcileCustomer).
        LOCK_SQL = "SELECT 1 AS locked FROM (SELECT pg_advisory_xact_lock(hashtext($1)::bigint)) AS lock_taken"

        def self.call(edition:, import:, match:, importer: ::DataImporters::Books::Book::Importer, page: nil, author_names: nil)
          new(edition: edition, import: import, match: match, importer: importer, page: page, author_names: author_names).call
        end

        # Held until the caller's transaction ends. SettleEdition parks and
        # ResolveEdition marks an edition pending under the same lock.
        def self.lock(edition)
          ActiveRecord::Base.connection.exec_query(LOCK_SQL, "goodreads-create-lock", ["goodreads-edition:#{edition.signature}"])
        end

        def initialize(edition:, import:, match:, importer:, page:, author_names:)
          @edition = edition
          @import = import
          @match = match
          @importer = importer
          @page = page
          @author_names = author_names
        end

        # requires_new: inside a caller's transaction (the dry run, a test, a
        # job) a CreateFailed must still roll back what the providers already
        # saved -- a book with no author, a new author -- rather than leave it
        # for the next edition to find.
        def call
          ActiveRecord::Base.transaction(requires_new: true) do
            self.class.lock(@edition)
            @edition.reload
            next done(:cached) if settled?

            racer = book_created_since_the_finder_looked
            next adopt(racer) if racer

            create
          end
        end

        private

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def book_created_since_the_finder_looked
          considered = @match.candidates.select(&:local?).map { |candidate| candidate.record.id }
          ::Books::GoodreadsEdition.created
            .where(signature: @edition.signature)
            .where.not(id: @edition.id)
            .where.not(book_id: [nil, *considered])
            .order(:resolved_at, :id)
            .first&.book
        end

        def adopt(book)
          @match.decision&.update!(record: book)
          resolve!(book, :matched, :not_needed)
          done(:matched)
        end

        def create
          result = @importer.call(
            title: @page&.title.presence || @edition.title,
            author_names: @author_names.presence || [@edition.primary_author],
            year: @edition.original_publication_year || @page&.original_publication_year || @edition.year_published,
            isbn13: [@edition.isbn13 || @page&.isbn13].compact,
            isbn10: [@edition.isbn10 || @page&.isbn10].compact,
            goodreads_id: [@edition.goodreads_book_id.to_s],
            subject: @edition,
            match: @match,
            provisional: true,
            stamp_identifiers: true,
            enrich: false
          )
          book = result.item
          unless result.created? && book&.persisted?
            raise CreateFailed, "no book created for Goodreads edition #{@edition.id}: #{result.all_errors.join("; ")}"
          end
          # An authorless book is legacy root cause 5: no later author-required
          # search can find it. The importer saves one when the author step
          # fails and a later provider succeeds.
          unless ::Books::BookAuthor.exists?(book: book)
            raise CreateFailed, "the book for Goodreads edition #{@edition.id} got no author: #{result.all_errors.join("; ")}"
          end

          record_provenance(book, result.created_author_ids)
          resolve!(book, :created, @page ? :verified : :unverified)
          done(:created)
        end

        def record_provenance(book, created_author_ids)
          records = [book] +
            ::Books::BookAuthor.where(book: book).to_a +
            ::Identifier.where(identifiable: book).to_a +
            ::Books::Author.where(id: created_author_ids).to_a
          records.each { |record| @import.records.create!(record: record, action: :created) }
        end

        def resolve!(book, resolution, verification)
          @edition.update!(book: book, resolution: resolution, verification: verification,
            match_decision: @match.decision, resolved_at: Time.current, pending_import: nil)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

`app/lib/services/books/goodreads_imports/settle_edition.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Settles an edition the finder could not match, by its Goodreads page
      # (Goodreads import spec §5 "Outcome", §6):
      #
      # - a page that backs the edition: a provisional book is created with
      #   the page's title and authors, verified;
      # - a page that says the id does not exist, or names another book: the
      #   edition is parked, with its waiting rows, and nothing is created;
      # - no page (the fetcher is down, Goodreads blocked us, the day's cap is
      #   spent): the book is created unverified, for the sweep to check.
      #
      # An edition already created unverified is checked instead: the page
      # sets its verification and the book is left alone. A not-found or
      # mismatched provisional book is the admin page's to act on.
      #
      # ResolveEdition calls this at once when the page is cached, with the
      # finder's live match. Books::Goodreads::SettleEditionsJob calls it after
      # a fetch, and the match is rebuilt from the decision the edition kept:
      # the finder never runs twice. The import that waited owns what is
      # created; if it is gone, the latest import with rows on the edition
      # does; with none, nothing waits for the edition and it is released.
      class SettleEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        PARKED_DETAIL = {not_found: "not found on Goodreads", mismatch: "does not match its Goodreads page"}.freeze

        def self.call(edition:, page:, match: nil, import: nil, importer: ::DataImporters::Books::Book::Importer)
          new(edition: edition, page: page, match: match, import: import, importer: importer).call
        end

        def initialize(edition:, page:, match:, import:, importer:)
          @edition = edition
          @page = page
          @match = match
          @import = import
          @importer = importer
        end

        def call
          return recheck if @edition.created? && @edition.verification_unverified? && @edition.book_id.present?
          return done(:cached) if settled?

          import = @import || owning_import
          return release if import.nil?

          verdict = @page && ::Books::Goodreads::Agreement.call(edition: @edition, page: @page)
          case verdict&.outcome
          when :verified then create(import, page: @page, author_names: verdict.author_names)
          when :not_found, :mismatch then park(verdict.outcome)
          else create(import)
          end
        end

        private

        def recheck
          return done(:unchanged) if @page.nil?

          @edition.update!(verification: ::Books::Goodreads::Agreement.call(edition: @edition, page: @page).outcome)
          done(:rechecked)
        end

        def create(import, page: nil, author_names: nil)
          CreateBook.call(edition: @edition, import: import, match: @match || match_from_decision, importer: @importer,
            page: page, author_names: author_names)
        end

        # Under CreateBook's signature lock, so a racing settle or creation of
        # the same edition sees one or the other.
        def park(verification)
          ActiveRecord::Base.transaction(requires_new: true) do
            CreateBook.lock(@edition)
            @edition.reload
            next done(:cached) if settled?

            decision = @match&.decision || @edition.match_decision
            @edition.update!(book: nil, resolution: :parked, verification: verification, match_decision: decision,
              resolved_at: Time.current, pending_import: nil)
            # Nothing was created, so there is nothing to review.
            decision.update!(needs_review: false) if decision&.needs_review?
            @edition.import_rows.pending.update_all(outcome: ::Books::GoodreadsImportRow.outcomes[:parked],
              outcome_detail: PARKED_DETAIL.fetch(verification), updated_at: Time.current)
            done(:parked)
          end
        end

        # The finder's answer as the edition kept it: the books it considered
        # (so CreateBook still never adopts one it turned down) and the
        # decision. The external answer is not kept, so Open Library is asked
        # again; for a verified creation it would be anyway, because the
        # page's title replaces the edition's.
        def match_from_decision
          decision = @edition.match_decision
          considered = Array(decision&.candidates).filter_map do |snapshot|
            next unless snapshot["record_type"] == "Books::Book"

            book = ::Books::Book.find_by(id: snapshot["record_id"])
            ::DataImporters::Candidate.new(record: book) if book
          end
          ::DataImporters::Match.new(outcome: :unmatched, record: nil, confidence: decision&.confidence&.to_sym,
            decided_by: decision&.decided_by&.to_sym, reason: decision&.reason, candidates: considered, decision: decision)
        end

        def owning_import
          @edition.pending_import ||
            ::Books::GoodreadsImport.where(id: @edition.import_rows.select(:import_id)).order(:id).last
        end

        def release
          @edition.update!(verification: :not_needed, pending_import: nil)
          done(:released)
        end

        def settled?
          @edition.resolved_at.present? && (@edition.book_id.present? || @edition.parked?)
        end

        def done(outcome)
          Result.new(success?: true, data: {edition: @edition, outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/`
Expected: PASS for everything in the directory, including the unchanged increment 3 tests
(`create_book_concurrency_test.rb` included). 0 failures.

- [ ] **Step 5: Mutation check**

Delete `candidates: considered,` from `match_from_decision` (leaving `candidates` defaulted).
Run `bin/rails test test/lib/services/books/goodreads_imports/settle_edition_test.rb -n "/turned it down|turned down/"`.
Expected: FAIL, because the turned-down book is adopted. Restore the line, then run it again.
Expected: PASS.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/goodreads_imports test/lib/services/books/goodreads_imports test/support/goodreads_import_helper.rb
git add app/lib/services/books/goodreads_imports test/lib/services/books/goodreads_imports test/support/goodreads_import_helper.rb
git commit -m "Goodreads import: SettleEdition creates, parks or leaves unverified by the page"
```

---

### Task 7: Fetch, settle and sweep jobs; the capsule; the verify rake

**Files:**
- Create: `web-app/app/sidekiq/books/goodreads/fetch_page_job.rb`, `settle_editions_job.rb`, `verify_unverified_job.rb` (and their generated tests under `web-app/test/sidekiq/books/goodreads/`)
- Modify: `web-app/config/initializers/sidekiq.rb`, `web-app/lib/tasks/books/goodreads.rake`, `web-app/test/lib/tasks/books_goodreads_rake_test.rb`

**Interfaces:**
- Consumes: `FetchGate` (Task 4); `FetchPage.call` (Task 5); `SettleEdition.call` (Task 6);
  `GoodreadsEdition.awaiting_goodreads`, `GoodreadsPage.conclusive` (Task 1).
- Produces:
  - `Books::Goodreads::FetchPageJob.perform_async(goodreads_book_id)` on queue
    `goodreads_fetch`; internal arguments `(goodreads_book_id, due = false, attempt = 1)`.
  - `Books::Goodreads::SettleEditionsJob.perform_async(goodreads_book_id)` on queue `default`.
  - `Books::Goodreads::VerifyUnverifiedJob.perform_async(limit = nil)` on queue `low`.
  - `bin/rails "books:goodreads:verify_unverified[limit]"`.

- [ ] **Step 1: Generate the jobs**

```bash
bin/rails generate sidekiq:job books/goodreads/fetch_page
bin/rails generate sidekiq:job books/goodreads/settle_editions
bin/rails generate sidekiq:job books/goodreads/verify_unverified
```

- [ ] **Step 2: Write the failing tests**

`test/sidekiq/books/goodreads/fetch_page_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::FetchPageJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  FETCH = Services::Books::GoodreadsPages::FetchPage

  # CI has no Redis: the gate runs on FakeRedis, with the clock frozen.
  # Sidekiq runs inline in tests, so the jobs this one queues are stubbed.
  setup do
    freeze_time
    config = ActiveSupport::OrderedOptions.new.merge(fetch_interval: 15, daily_fetch_cap: 1_500, block_cooldown: 6.hours.to_i)
    @gate = Books::Goodreads::FetchGate.new(redis: Books::OpenLibrary::FakeRedis.new, config: config)
    Books::Goodreads::FetchGate.stubs(:new).returns(@gate)
    Books::Goodreads::SettleEditionsJob.stubs(:perform_async)
    @edition = goodreads_edition(verification: :pending)
    @id = @edition.goodreads_book_id
  end

  def fetched(outcome)
    FETCH::Result.new(success?: true, data: {outcome: outcome, page: nil}, errors: [])
  end

  test "runs on the goodreads_fetch queue with three retries" do
    options = Books::Goodreads::FetchPageJob.get_sidekiq_options

    assert_equal ["goodreads_fetch", 3], [options["queue"].to_s, options["retry"]]
  end

  test "fetches at once when the line is free, then settles the id's editions" do
    FETCH.expects(:call).with(goodreads_book_id: @id).returns(fetched(:found))
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a busy line reschedules the job for its turn instead of waiting in a thread" do
    @gate.reserve
    FETCH.expects(:call).never
    Books::Goodreads::FetchPageJob.expects(:perform_in).with(15, @id, true, 1)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a job on its turn fetches without reserving another" do
    2.times { @gate.reserve }
    FETCH.expects(:call).returns(fetched(:found))
    Books::Goodreads::FetchPageJob.expects(:perform_in).never

    Books::Goodreads::FetchPageJob.new.perform(@id, true)
  end

  test "an id already answered is settled without a fetch" do
    goodreads_page(goodreads_book_id: @id)
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "an id nothing waits on is not fetched" do
    @edition.update!(verification: :not_needed)
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).never

    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a spent daily cap or a block settles the editions, unverified, without fetching" do
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id).twice

    @gate.stubs(:reserve).returns(Books::Goodreads::FetchGate::Reservation.new(wait: nil, refusal: :daily_cap))
    Books::Goodreads::FetchPageJob.new.perform(@id)
    @gate.unstub(:reserve)
    @gate.block!
    Books::Goodreads::FetchPageJob.new.perform(@id)
  end

  test "a block that began while the job waited for its turn stops it" do
    @gate.block!
    FETCH.expects(:call).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)

    Books::Goodreads::FetchPageJob.new.perform(@id, true)
  end

  test "a challenge or an unrecognizable page stops all fetching for the cooldown" do
    [:blocked, :unparseable].each do |outcome|
      @gate.stubs(:blocked?).returns(false)
      FETCH.stubs(:call).returns(fetched(outcome))
      @gate.expects(:block!)

      Books::Goodreads::FetchPageJob.new.perform(@id, true)
    end
  end

  test "no answer tries again through the line, then leaves the edition to be created unverified" do
    FETCH.stubs(:call).returns(fetched(:unavailable))
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(@id, false, 2)
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).never

    Books::Goodreads::FetchPageJob.new.perform(@id, true, 1)

    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(@id)
    Books::Goodreads::FetchPageJob.new.perform(@id, true, 3)
    assert_not @gate.blocked?
  end
end
```

`test/sidekiq/books/goodreads/settle_editions_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::SettleEditionsJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  SETTLE = Services::Books::GoodreadsImports::SettleEdition

  setup do
    stub_resolution_services
    @import = Books::GoodreadsImport.create!(user: users(:editor_user), status: :verifying)
  end

  def waiting_edition(**attributes)
    edition = goodreads_edition(goodreads_book_id: 90_000_001, **attributes)
    decision = MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :unmatched,
      confidence: :high, decided_by: :rule)
    edition.update!(verification: :pending, match_decision: decision, pending_import: @import)
    @import.rows.create!(row_number: @import.rows.count + 1, goodreads_edition: edition)
    edition
  end

  test "runs on the default queue" do
    assert_equal "default", Books::Goodreads::SettleEditionsJob.get_sidekiq_options["queue"].to_s
  end

  test "settles every waiting edition of the id against its page" do
    honest = waiting_edition
    hostile = waiting_edition(title: "A Book Nobody Wrote", signature: Books::Goodreads::ExportRow.signature("A Book Nobody Wrote", "Anna Brenner"))
    goodreads_page(goodreads_book_id: 90_000_001)

    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)

    assert_equal [true, true], [honest.reload.verification_verified?, honest.book.provisional?]
    assert_equal [true, true], [hostile.reload.parked?, hostile.verification_mismatch?]
  end

  test "an edition that fails records why on its waiting rows, and the rest still settle" do
    first = waiting_edition
    second = waiting_edition(title: "The Loud Year", signature: Books::Goodreads::ExportRow.signature("The Loud Year", "Anna Brenner"))
    SETTLE.expects(:call).twice.raises(RuntimeError, "boom").then.returns(nil)

    Books::Goodreads::SettleEditionsJob.new.perform(90_000_001)

    assert_equal ["verification failed: RuntimeError: boom", nil], [first.import_rows.sole.error, second.import_rows.sole.error]
  end

  test "a Postgres error re-raises" do
    waiting_edition
    SETTLE.stubs(:call).raises(ActiveRecord::StatementInvalid, "connection lost")

    assert_raises(ActiveRecord::StatementInvalid) { Books::Goodreads::SettleEditionsJob.new.perform(90_000_001) }
  end
end
```

`test/sidekiq/books/goodreads/verify_unverified_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class Books::Goodreads::VerifyUnverifiedJobTest < ActiveSupport::TestCase
  include GoodreadsImportHelper

  # FetchPageJob is not stubbed here: each test names exactly the fetches it
  # expects, so a stray one (a non-provisional book, an edition waiting only
  # minutes) fails as an unexpected invocation.
  setup do
    Books::Goodreads::SettleEditionsJob.stubs(:perform_async)
  end

  def created_unverified(goodreads_book_id, provisional: true)
    book = Books::Book.create!(title: "Book #{goodreads_book_id}", provisional: provisional)
    goodreads_edition(goodreads_book_id: goodreads_book_id, book: book, resolution: :created, verification: :unverified,
      resolved_at: 1.day.ago)
  end

  test "runs on the low queue" do
    assert_equal "low", Books::Goodreads::VerifyUnverifiedJob.get_sidekiq_options["queue"].to_s
  end

  test "queues a fetch for each provisional book created unverified, and for editions stuck waiting" do
    created_unverified(91_000_001)
    created_unverified(91_000_002, provisional: false)
    goodreads_edition(goodreads_book_id: 91_000_003, verification: :pending).update_column(:updated_at, 2.hours.ago)
    goodreads_edition(goodreads_book_id: 91_000_004, verification: :pending)
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(91_000_001)
    Books::Goodreads::FetchPageJob.expects(:perform_async).with(91_000_003)

    Books::Goodreads::VerifyUnverifiedJob.new.perform
  end

  test "an id whose page is already cached is settled without a fetch" do
    created_unverified(91_000_001)
    goodreads_page(goodreads_book_id: 91_000_001)
    Books::Goodreads::FetchPageJob.expects(:perform_async).never
    Books::Goodreads::SettleEditionsJob.expects(:perform_async).with(91_000_001)

    Books::Goodreads::VerifyUnverifiedJob.new.perform
  end

  test "takes at most limit ids" do
    created_unverified(91_000_001)
    created_unverified(91_000_002)
    Books::Goodreads::FetchPageJob.expects(:perform_async).once

    Books::Goodreads::VerifyUnverifiedJob.new.perform(1)
  end
end
```

Append to `test/lib/tasks/books_goodreads_rake_test.rb`, inside the class:

```ruby
  test "verify_unverified queues the sweep, with a limit when one is given" do
    task = Rake::Task["books:goodreads:verify_unverified"]
    Books::Goodreads::VerifyUnverifiedJob.expects(:perform_async).with
    Books::Goodreads::VerifyUnverifiedJob.expects(:perform_async).with(50)

    assert_output(/queued Books::Goodreads::VerifyUnverifiedJob/) { task.invoke }
    task.reenable
    assert_output(/limit 50/) { task.invoke("50") }
  ensure
    task&.reenable
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/sidekiq/books/goodreads/ test/lib/tasks/books_goodreads_rake_test.rb`
Expected: failures, because the generated jobs do nothing and
`Don't know how to build task 'books:goodreads:verify_unverified'`.

- [ ] **Step 4: Write the jobs, the capsule and the rake task**

`app/sidekiq/books/goodreads/fetch_page_job.rb`:

```ruby
# frozen_string_literal: true

# Fetches one Goodreads page, when Books::Goodreads::FetchGate allows, and
# hands the id's waiting editions to SettleEditionsJob (Goodreads import spec
# §6). On the goodreads_fetch capsule: one job at a time, and the only
# caller of FetchPage.
#
# A job first takes a turn in the gate's line and reschedules itself for it;
# it never sleeps. A cached answer, nothing left waiting, a spent daily cap
# or a block means no fetch: the editions settle with what there is, which
# without a page is a book created unverified for the sweep. A challenge or
# an unrecognizable page blocks every fetch for the cooldown. No answer at
# all (Goodreads' 503 page, a timeout) is tried again through the line, up to
# fetch_attempts.
class Books::Goodreads::FetchPageJob
  include Sidekiq::Job

  sidekiq_options queue: :goodreads_fetch, retry: 3

  def perform(goodreads_book_id, due = false, attempt = 1)
    return settle(goodreads_book_id) if ::Books::GoodreadsPage.conclusive.exists?(goodreads_book_id: goodreads_book_id)
    return unless ::Books::GoodreadsEdition.awaiting_goodreads.exists?(goodreads_book_id: goodreads_book_id)

    unless due
      reservation = gate.reserve
      return settle(goodreads_book_id) unless reservation.granted?
      return self.class.perform_in(reservation.wait, goodreads_book_id, true, attempt) if reservation.wait.positive?
    end
    return settle(goodreads_book_id) if gate.blocked?

    outcome = ::Services::Books::GoodreadsPages::FetchPage.call(goodreads_book_id: goodreads_book_id).data[:outcome]
    gate.block! if %i[blocked unparseable].include?(outcome)
    if outcome == :unavailable && attempt < Rails.application.config.x.goodreads.fetch_attempts
      return self.class.perform_async(goodreads_book_id, false, attempt + 1)
    end

    settle(goodreads_book_id)
  end

  private

  def gate = (@gate ||= ::Books::Goodreads::FetchGate.new)

  def settle(goodreads_book_id)
    ::Books::Goodreads::SettleEditionsJob.perform_async(goodreads_book_id)
  end
end
```

`app/sidekiq/books/goodreads/settle_editions_job.rb`:

```ruby
# frozen_string_literal: true

# Settles every edition of one Goodreads id that a page could settle, against
# the cached page or none (Goodreads import spec §6). Kept off the fetch
# capsule, so creating books never holds up the next fetch.
#
# One failing edition never stops the rest: its waiting rows carry the error,
# and it keeps waiting until the sweep queues it again. Postgres errors
# re-raise.
class Books::Goodreads::SettleEditionsJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

  def perform(goodreads_book_id)
    page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: goodreads_book_id)
    ::Books::GoodreadsEdition.awaiting_goodreads.where(goodreads_book_id: goodreads_book_id).order(:id).each do |edition|
      ::Services::Books::GoodreadsImports::SettleEdition.call(edition: edition, page: page)
    rescue *POSTGRES_ERRORS
      raise
    rescue => e
      Rails.logger.error("#{self.class.name}: Goodreads edition #{edition.id} failed: #{e.class}: #{e.message}")
      edition.import_rows.pending.update_all(error: "verification failed: #{e.class}: #{e.message}", updated_at: Time.current)
    end
  end
end
```

`app/sidekiq/books/goodreads/verify_unverified_job.rb`:

```ruby
# frozen_string_literal: true

# The rake-driven sweep (Goodreads import spec §6, "Never in the critical
# path"): queues a Goodreads check for each provisional book created
# unverified, and again for editions stuck waiting (their fetch job was lost
# to a crash or a Redis flush). An id whose page is already cached is settled
# without a fetch. At most `limit` ids, by default the day's fetch cap; the
# fetch line spaces them out.
class Books::Goodreads::VerifyUnverifiedJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  STUCK_AFTER = 1.hour

  def perform(limit = nil)
    limit ||= Rails.application.config.x.goodreads.daily_fetch_cap
    ids = ::Books::GoodreadsEdition.where(id: unverified.select(:id)).or(::Books::GoodreadsEdition.where(id: stuck.select(:id)))
      .distinct.order(:goodreads_book_id).limit(limit).pluck(:goodreads_book_id)
    answered = ::Books::GoodreadsPage.conclusive.where(goodreads_book_id: ids).pluck(:goodreads_book_id).to_set
    ids.each do |goodreads_book_id|
      if answered.include?(goodreads_book_id)
        ::Books::Goodreads::SettleEditionsJob.perform_async(goodreads_book_id)
      else
        ::Books::Goodreads::FetchPageJob.perform_async(goodreads_book_id)
      end
    end
  end

  private

  def unverified
    ::Books::GoodreadsEdition.created.verification_unverified.joins(:book).where(books_books: {provisional: true})
  end

  def stuck
    ::Books::GoodreadsEdition.verification_pending.where(updated_at: ...STUCK_AFTER.ago)
  end
end
```

In `config/initializers/sidekiq.rb`, after the `serial` capsule block:

```ruby
  # Goodreads page fetches, one at a time across the app (production runs one
  # Sidekiq process), paced by Books::Goodreads::FetchGate.
  config.capsule("goodreads_fetch") do |cap|
    cap.concurrency = 1
    cap.queues = %w[goodreads_fetch]
  end
```

In `lib/tasks/books/goodreads.rake`, inside `namespace :goodreads`, after `resolve_file`:

```ruby
    desc "Queue Goodreads checks for provisional books created unverified, and for editions stuck " \
      "waiting on a page. Usage: books:goodreads:verify_unverified[limit] (default: the daily fetch cap)"
    task :verify_unverified, [:limit] => :environment do |_task, args|
      limit = args[:limit].presence&.to_i
      Books::Goodreads::VerifyUnverifiedJob.perform_async(*[limit].compact)
      puts "queued Books::Goodreads::VerifyUnverifiedJob#{" (limit #{limit})" if limit}"
    end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/sidekiq/books/goodreads/ test/lib/tasks/books_goodreads_rake_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS, 0 failures; `All is good!`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/sidekiq/books/goodreads test/sidekiq/books/goodreads config/initializers/sidekiq.rb lib/tasks/books/goodreads.rake test/lib/tasks/books_goodreads_rake_test.rb
git add app/sidekiq/books/goodreads test/sidekiq/books/goodreads config/initializers/sidekiq.rb lib/tasks/books/goodreads.rake test/lib/tasks/books_goodreads_rake_test.rb
git commit -m "Goodreads pages: fetch, settle and sweep jobs on a goodreads_fetch capsule"
```

---

### Task 8: Resolution waits for Goodreads; dry run; docs

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_imports/resolve_edition.rb`, `web-app/app/lib/services/books/goodreads_imports/dry_run.rb`, `web-app/test/support/goodreads_import_helper.rb`
- Modify tests: `web-app/test/lib/services/books/goodreads_imports/resolve_edition_test.rb`, `resolve_import_test.rb`, `dry_run_test.rb`
- Modify docs: `docs/features/goodreads-import.md`, `docs/features/page-fetcher-service.md`

**Interfaces:**
- Consumes: `SettleEdition.call` and `CreateBook.lock` (Task 6); `FetchPageJob.perform_async` (Task 7); `GoodreadsPage.conclusive` (Task 1).
- Produces:
  - `ResolveEdition` outcomes now include `:pending` and `:parked`.
  - An unmatched edition with a cached page settles at once. One without a cached page becomes
    `verification: pending` with `pending_import` set, and a `FetchPageJob` is queued after commit.
  - A pending edition is never resolved again.

- [ ] **Step 1: Update the helper and write the failing tests**

In `test/support/goodreads_import_helper.rb`, add to the end of `stub_resolution_services`:

```ruby
    # Sidekiq runs inline in tests; a test that cares asserts on this.
    ::Books::Goodreads::FetchPageJob.stubs(:perform_async)
```

In `test/lib/services/books/goodreads_imports/resolve_edition_test.rb`:

Replace the test `"nothing found creates a provisional book, unflagged"` with:

```ruby
        test "nothing found and no page yet: the edition waits for Goodreads, unflagged, and a fetch is queued" do
          edition = goodreads_edition
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).with(edition.goodreads_book_id)

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :pending, result.data[:outcome]
          assert_equal [true, @import, nil], [edition.verification_pending?, edition.pending_import, edition.book]
          assert_equal false, edition.match_decision.needs_review
        end

        test "nothing found with its page cached creates a provisional, verified book at once" do
          edition = goodreads_edition
          goodreads_page(goodreads_book_id: edition.goodreads_book_id)
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          result = ResolveEdition.call(edition: edition, import: @import)

          edition.reload
          assert_equal :created, result.data[:outcome]
          assert_equal [true, true], [edition.book.provisional?, edition.verification_verified?]
        end

        test "nothing found with a not-found page cached parks the edition" do
          edition = goodreads_edition
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, outcome: :not_found)

          assert_no_difference("::Books::Book.count") do
            assert_equal :parked, ResolveEdition.call(edition: edition, import: @import).data[:outcome]
          end
        end

        test "a waiting edition is not resolved again" do
          edition = goodreads_edition(verification: :pending)
          finder = mock("finder")
          finder.expects(:call).never

          assert_equal :pending, ResolveEdition.call(edition: edition, import: @import, finder: finder).data[:outcome]
        end

        test "a rolled-back resolution queues no fetch" do
          edition = goodreads_edition
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          ActiveRecord::Base.transaction(requires_new: true) do
            ResolveEdition.call(edition: edition, import: @import)
            raise ActiveRecord::Rollback
          end

          assert edition.reload.verification_not_needed?
        end

        test "an edition another import sent to Goodreads while this one ran the finder keeps that import's decision" do
          ::Search::Books::Search::BookByTitleAndAuthors.stubs(:call).returns([search_hit(@war_and_peace)])
          stub_matching_ai(selected_index: 0)
          edition = goodreads_edition(title: "War and Peace in the Garden", primary_author: "Leo Tolstoy")
          other_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :resolving)
          other_decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition,
            outcome: :unmatched, confidence: :high, decided_by: :rule)
          real = ::DataImporters::Books::Book::Finder.new
          racing = Object.new
          racing.define_singleton_method(:call) do |**options|
            real.call(**options).tap do
              ::Books::GoodreadsEdition.where(id: edition.id).update_all(verification: 1, match_decision_id: other_decision.id,
                pending_import_id: other_import.id)
            end
          end
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never

          result = ResolveEdition.call(edition: edition, import: @import, finder: racing)

          edition.reload
          assert_equal :pending, result.data[:outcome]
          assert_equal [other_decision, other_import], [edition.match_decision, edition.pending_import]
          assert_equal 0, ::MatchDecision.needing_review.where(subject: edition).count
        end
```

In the test `"an AI 'none of these' creates a book and flags it; it never takes the top search hit"`,
add this after the `edition = …` line:

```ruby
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "War and Peace in the Garden",
            authors: [["Leo Tolstoy", "Author"]])
```

In the test `"a failed creation, retried, leaves only the decision that was used in the review queue"`,
add this after the `edition = …` line:

```ruby
          goodreads_page(goodreads_book_id: edition.goodreads_book_id, title: "War and Peace in the Garden",
            authors: [["Leo Tolstoy", "Author"]])
```

In the test `"an edition whose book was deleted is resolved again"`, add this before `gone.destroy!`:

```ruby
          goodreads_page(goodreads_book_id: edition.goodreads_book_id)
```

In the test `"a later import finds the provisional book an earlier one created instead of making another"`,
add this after `first = …`:

```ruby
          goodreads_page(goodreads_book_id: 90_000_001)
```

In `test/lib/services/books/goodreads_imports/resolve_import_test.rb`, add this at the end of
`setup`:

```ruby
          # QUIET_YEAR's page is cached, so its book is created at once.
          goodreads_page(goodreads_book_id: 90_000_001)
```

and append, inside the class:

```ruby
        test "an edition waiting on Goodreads is neither matched nor created yet" do
          parse({"Book Id" => "90000002", "Title" => "The Loud Year", "Author" => "Anna Brenner"})

          result = ResolveImport.call(import: @import)

          assert_equal 1, result.data[:outcomes][:pending]
          assert_equal [0, 0, 0, 0, 0], counters
        end
```

In `test/lib/services/books/goodreads_imports/dry_run_test.rb`, replace the test
`"reports each decision"` with:

```ruby
        test "reports each decision" do
          report = DryRun.call(bytes: @bytes, user: users(:regular_user)).data[:report]

          assert_match "Goodreads dry run: 3 rows, 2 editions. Nothing was saved.", report
          assert_match "matched 1 | created 0 | waiting 1 | parked 0 | flagged 0 | failed rows 1 | AI calls 0", report
          assert_match %(row 1: gr 12345678 "War and Peace" by Leo Tolstoy -> matched Books::Book##{books_books(:war_and_peace).id}), report
          assert_match %(row 2: gr 90000001 "The Quiet Year" by Anna Brenner -> waiting for Goodreads verification), report
          assert_match "row 3: failed: no Goodreads book id", report
        end

        test "a cached page settles the edition in the report" do
          goodreads_page(goodreads_book_id: 90_000_001)

          report = DryRun.call(bytes: @bytes, user: users(:regular_user)).data[:report]

          assert_match %r{row 2: gr 90000001 "The Quiet Year" by Anna Brenner -> created provisional Books::Book#\d+ "The Quiet Year" \(verified\)}, report
        end

        test "a cached not-found page parks the edition in the report" do
          goodreads_page(goodreads_book_id: 90_000_001, outcome: :not_found)

          report = DryRun.call(bytes: @bytes, user: users(:regular_user)).data[:report]

          assert_match %(row 2: gr 90000001 "The Quiet Year" by Anna Brenner -> parked: not found on Goodreads), report
          assert_match "matched 1 | created 0 | waiting 0 | parked 1 |", report
        end
```

and in `"saves nothing"` add `"::Books::GoodreadsPage.count"` to `counted`, and this line before
the assertion:

```ruby
          ::Books::Goodreads::FetchPageJob.expects(:perform_async).never
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/resolve_edition_test.rb test/lib/services/books/goodreads_imports/resolve_import_test.rb test/lib/services/books/goodreads_imports/dry_run_test.rb`
Expected: failures. The new pending tests get `:created` instead of `:pending`, and the dry-run
report has no "waiting" column.

- [ ] **Step 3: Send unmatched editions to verification; report it**

In `app/lib/services/books/goodreads_imports/resolve_edition.rb`:

Replace the class comment's points 1 and 3 with:

```ruby
      # 1. Cache: an edition already resolved to a book that still exists (or
      #    parked) is reused, and one waiting for its Goodreads page is left to
      #    wait. The merger moves editions, so merges are followed; a deleted
      #    book nullifies book_id and the edition is resolved again.
```

```ruby
      # 3. Outcome: a match links (the finder flags medium, low and fallback
      #    decisions). No match goes to Goodreads verification (spec §6): with
      #    the edition's page already cached, SettleEdition creates or parks
      #    at once; otherwise the edition waits (verification: pending) and a
      #    fetch is queued once that commits, so a rolled-back dry run queues
      #    nothing. An AI "none of these" is flagged here and goes the same
      #    way; nothing ever falls back to the top search hit. A failed AI call
      #    (the finder's fallback decision) is not an answer: it raises, and
      #    the edition waits for the next run instead of creating a duplicate
      #    of a book the AI never got to judge.
```

In `call`, after `return done(:cached) if settled?`, add:

```ruby
          return done(:pending) if @edition.verification_pending?
```

Replace the last line of `resolve`
(`CreateBook.call(edition: @edition, import: @import, match: match, importer: @importer).data[:outcome]`) with:

```ruby
          page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: @edition.goodreads_book_id)
          if page
            return SettleEdition.call(edition: @edition, page: page, match: match, import: @import, importer: @importer).data[:outcome]
          end

          await_verification(match)
        end

        # Under the signature lock CreateBook takes, so an edition another
        # import resolved or sent to Goodreads while this one ran the finder
        # is left as that import left it.
        def await_verification(match)
          ActiveRecord::Base.transaction(requires_new: true) do
            CreateBook.lock(@edition)
            @edition.reload
            next :pending if @edition.verification_pending?
            next :cached if settled?

            @edition.update!(verification: :pending, match_decision: match.decision, pending_import: @import)
            goodreads_book_id = @edition.goodreads_book_id
            ActiveRecord.after_all_transactions_commit { ::Books::Goodreads::FetchPageJob.perform_async(goodreads_book_id) }
            :pending
          end
```

(The `end` that closed `resolve` now closes `await_verification`. Check that the file still parses
with `ruby -c`.)

In `app/lib/services/books/goodreads_imports/dry_run.rb`, `build_report`:
- Replace the summary line's string with:

```ruby
            "matched #{import.matched_count} | created #{import.created_count} | " \
              "waiting #{editions.values.count(&:verification_pending?)} | parked #{import.parked_count} | " \
              "flagged #{import.flagged_count} | failed rows #{rows.count(&:failed?)} | AI calls #{import.ai_calls_count}",
```

- In `describe`, replace the first two `return` lines with:

```ruby
          return "#{source} -> waiting for Goodreads verification" if edition.verification_pending?
          return "#{source} -> failed: #{group.filter_map(&:error).first}" if edition.resolved_at.nil?
          if edition.parked?
            return "#{source} -> parked: #{SettleEdition::PARKED_DETAIL.fetch(edition.verification.to_sym, edition.verification)}"
          end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/ test/lib/tasks/books_goodreads_rake_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 5: Mutation checks**

1. In `await_verification`, delete the lines `CreateBook.lock(@edition)` and `@edition.reload`.
   Run `bin/rails test test/lib/services/books/goodreads_imports/resolve_edition_test.rb -n "/sent to Goodreads/"`.
   Expected: FAIL, because this import's decision overwrites the other import's. Restore both
   lines.
2. Replace the `ActiveRecord.after_all_transactions_commit { … }` wrapper with a direct
   `::Books::Goodreads::FetchPageJob.perform_async(goodreads_book_id)`. Run
   `… -n "/rolled-back/"`. Expected: FAIL (unexpected invocation). Restore it.

Run the directory again. Expected: PASS.

- [ ] **Step 6: Docs**

In `docs/features/goodreads-import.md`:
- In the Status table, set row 3 to `shipped` and row 4 to `this doc`.
- In "Resolution", step 3, replace the sentence "No match creates a provisional book through
  `CreateBook`. An AI "none of these" creates too, and is flagged." with: "No match goes to
  Goodreads verification (below). An AI "none of these" goes there too, and is flagged."
- Delete the paragraph "Every creation is `verification: unverified` until increment 4 adds the
  Goodreads fetch."
- Insert this section before "## Dry run":

```markdown
## Goodreads verification

An edition the finder cannot match is checked against its Goodreads page before a book is made
for it. Matched editions never touch Goodreads.

- **Cache.** `books_goodreads_pages` holds one row per Goodreads id. A `found` or `not_found` page
  is the answer for good. A `blocked` or `unparseable` page keeps its HTML for a later look and is
  fetched again. HTML is gzipped on the private `private_imports` storage service
  (`PRIVATE_IMPORTS_STORAGE_*`, `deployment/ENV.md`) and never served; nothing generates a URL
  for it.
- **Waiting.** With the page cached, `SettleEdition` decides at once. Otherwise the edition waits
  (`verification: pending`, with the waiting import in `pending_import_id`), and
  `Books::Goodreads::FetchPageJob` is queued once that commits.
- **Fetching.** `FetchPageJob` runs on the `goodreads_fetch` capsule, one at a time, through
  `PageFetcher::Client` with `wait_for_selector: "h1"`. `Books::Goodreads::FetchGate` (Redis)
  hands out start times at least `fetch_interval` apart (15 s) and caps a UTC day at
  `daily_fetch_cap` (1,500). A job waits for its turn by rescheduling itself. A 403, a challenge or
  an unrecognizable page blocks all fetching for `block_cooldown` (6 h). Goodreads' own 503 page
  and timeouts are retried through the line up to `fetch_attempts` (3). Settings:
  `config/initializers/goodreads.rb`.
- **Reading.** `Books::Goodreads::BookPage` reads `__NEXT_DATA__`, or the markup and `ld+json`
  when a page has none (1 page in 20, measured). It reads title, series, contributors with roles,
  original year, ISBNs and ASIN, and never descriptions. An unknown id is a 200 titled "Page not
  found".
- **Agreement** (`Books::Goodreads::Agreement`):
  - Main titles must match. A main title is normalized, with no series suffix, no subtitle and no
    punctuation.
  - The edition's primary author must be one of these, as a fuller or shorter form of the same
    name:
    - the page's primary contributor;
    - an Author or Writer;
    - a contributor with no role.
- **Outcome** (`SettleEdition`):
  - **Agrees:** a provisional book with the page's title and its Author and Writer contributors
    (never translators, illustrators or editors), verified. Series are not linked, because
    `Books::Series` has no provisional flag. The page row keeps every series it names, with
    Goodreads' series id, for a later series backfill.
  - **Not found or mismatch:** the edition is parked, its waiting rows read "not found on
    Goodreads" or "does not match its Goodreads page", and nothing is created.
  - **No page** (fetcher down, blocked, cap spent): the book is created unverified.
- **Sweep.** `bin/rails "books:goodreads:verify_unverified[limit]"` queues a check for every
  provisional book created unverified, and for editions stuck waiting over an hour. A later
  `not_found` or `mismatch` is recorded on the edition and left for the admin page
  (increment 6). The book is not touched.

Moving an import through `verifying` and recounting it after a late settle belong to the import
job (increment 6).
```

- In "Dry run", add this sentence after "…rolls everything back.": "A dry run fetches no Goodreads
  page: an unmatched edition whose page is not cached reports "waiting for Goodreads verification"."

In `docs/features/page-fetcher-service.md`, replace the line
`page.html            # never logged, and never stored -- store what you parse` with
`page.html            # never logged; store what you parse (one exception below)`. After that code
block, add:

```markdown
The one exception is Goodreads book pages. The Goodreads import keeps each page's HTML gzipped in
private storage, so a parser fix can re-read it without fetching again. These are public pages,
stored for internal parsing and never served (`docs/features/goodreads-import.md`, "Goodreads
verification").
```

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/lib/services/books/goodreads_imports test/lib/services/books/goodreads_imports test/support/goodreads_import_helper.rb
git add app/lib/services/books/goodreads_imports test/lib/services/books/goodreads_imports test/support/goodreads_import_helper.rb ../docs/features/goodreads-import.md ../docs/features/page-fetcher-service.md
git commit -m "Goodreads import: unmatched editions wait for their Goodreads page"
```

---

### Task 9: Legacy seed

**Files:**
- Create: `web-app/app/models/legacy_books/goodreads_book.rb`, `web-app/test/models/legacy_books/goodreads_book_test.rb`
- Create: `web-app/app/lib/services/books/goodreads_pages/seed_legacy_pages.rb`, `web-app/test/lib/services/books/goodreads_pages/seed_legacy_pages_test.rb`
- Modify: `web-app/lib/tasks/books/goodreads.rake`, `web-app/test/lib/tasks/books_goodreads_rake_test.rb`, `docs/features/goodreads-import.md`

**Interfaces:**
- Consumes: `Books::GoodreadsPage` (Task 1); `Books::GoodreadsId.normalize`, `Books::Isbn.normalize`, `Books::Goodreads::ExportRow::SERIES_SUFFIX` (increment 3).
- Produces:
  - `LegacyBooks::GoodreadsBook` (read-only), with `.scraped`.
  - `Services::Books::GoodreadsPages::SeedLegacyPages.call(records: nil)`, which returns
    `Result(data: {inserted:, already_present:, skipped:})`.
  - `bin/rails books:goodreads:seed_legacy_pages`.

- [ ] **Step 1: Generate the legacy model**

```bash
bin/rails generate model LegacyBooks::GoodreadsBook --skip-migration --no-fixture --parent=LegacyBooks::Record
rm -f app/models/legacy_books.rb
git status --short
```

Expected: `app/models/legacy_books/goodreads_book.rb` and
`test/models/legacy_books/goodreads_book_test.rb` exist. Every legacy model sets its own
`table_name`, so the generated `app/models/legacy_books.rb` (a `table_name_prefix` module) is
removed and must not reappear.

- [ ] **Step 2: Write the failing tests**

`test/models/legacy_books/goodreads_book_test.rb`:

```ruby
require "test_helper"

module LegacyBooks
  class GoodreadsBookTest < ActiveSupport::TestCase
    test "reads from the legacy goodreads_books table" do
      assert_equal "goodreads_books", GoodreadsBook.table_name
    end

    # .allocate, not .new: in test LegacyBooks::Record falls back to the app's
    # own connection, which has no goodreads_books table (see blog_post_test.rb).
    test "is read only" do
      assert_predicate GoodreadsBook.allocate, :readonly?
    end
  end
end
```

`test/lib/services/books/goodreads_pages/seed_legacy_pages_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsPages
      class SeedLegacyPagesTest < ActiveSupport::TestCase
        LOOKED_UP = Time.utc(2025, 1, 2, 3, 4, 5)

        def legacy(goodreads_id:, title:, authors:, series: nil, isbn13: nil, isbn: nil, asin: nil,
          original_publication_year: nil, last_looked_up_at: nil, last_refreshed_at: LOOKED_UP)
          stub(goodreads_id: goodreads_id, title: title, authors: authors, series: series, isbn13: isbn13, isbn: isbn,
            asin: asin, original_publication_year: original_publication_year, last_looked_up_at: last_looked_up_at,
            last_refreshed_at: last_refreshed_at)
        end

        def seed(*records) = SeedLegacyPages.call(records: records).data

        test "a page-lookup row becomes a found legacy page, every name without a role" do
          seed(legacy(goodreads_id: "335131", title: "The Vile Village", authors: ["Lemony Snicket", "Brett Helquist"],
            series: "A Series of Unfortunate Events #7", isbn13: "9780192833983", asin: "B0001", original_publication_year: 2001,
            last_looked_up_at: LOOKED_UP + 1.day))

          page = ::Books::GoodreadsPage.find_by!(goodreads_book_id: 335131)
          assert_equal ["legacy", "found", LOOKED_UP + 1.day, nil, nil], [page.source, page.outcome, page.fetched_at, page.http_status, page.parser_version]
          assert_equal ["The Vile Village", 2001], [page.title, page.original_publication_year]
          assert_equal [{"goodreads_series_id" => nil, "title" => "A Series of Unfortunate Events", "position" => "7"}], page.series
          assert_equal ["9780192833983", "0192833987", "B0001"], [page.isbn13, page.isbn10, page.asin]
          assert_equal [{"name" => "Lemony Snicket", "role" => nil, "primary" => false},
            {"name" => "Brett Helquist", "role" => nil, "primary" => false}], page.authors
          assert_not page.html.attached?
        end

        test "a search-result row's series comes off its title" do
          seed(legacy(goodreads_id: "28854", title: "The Book of Lost Tales, Part Two (The History of Middle-earth, #2)",
            authors: ["J.R.R. Tolkien"]))

          page = ::Books::GoodreadsPage.find_by!(goodreads_book_id: 28854)
          assert_equal "The Book of Lost Tales, Part Two", page.title
          assert_equal [{"goodreads_series_id" => nil, "title" => "The History of Middle-earth", "position" => "2"}], page.series
        end

        test "names are folded and duplicates dropped" do
          seed(legacy(goodreads_id: "54976984", title: "The Coldest Case", authors: ["Martin  Walker", "Martin Walker"]))

          assert_equal ["Martin Walker"], ::Books::GoodreadsPage.find_by!(goodreads_book_id: 54976984).authors.map { |author| author["name"] }
        end

        test "rows it cannot use are skipped and counted" do
          counts = seed(legacy(goodreads_id: "not-an-id", title: "X", authors: ["A"]),
            legacy(goodreads_id: "1001", title: " ", authors: ["A"]),
            legacy(goodreads_id: "1002", title: "Y", authors: []))

          assert_equal({inserted: 0, already_present: 0, skipped: 3}, counts)
        end

        test "an id already cached is never overwritten, and a second run inserts nothing" do
          rows = [legacy(goodreads_id: "656", title: "Something Else", authors: ["Nobody"]),
            legacy(goodreads_id: "28854", title: "The Book of Lost Tales", authors: ["J.R.R. Tolkien"])]

          assert_equal({inserted: 1, already_present: 1, skipped: 0}, seed(*rows))
          assert_equal({inserted: 0, already_present: 2, skipped: 0}, seed(*rows))
          assert_equal "War and Peace", books_goodreads_pages(:war_and_peace_page).reload.title
        end

        test "two legacy rows for one id insert one page" do
          counts = seed(legacy(goodreads_id: "12345", title: "One", authors: ["A"]),
            legacy(goodreads_id: "12345.One_Title", title: "One", authors: ["A"]))

          assert_equal({inserted: 1, already_present: 1, skipped: 0}, counts)
        end
      end
    end
  end
end
```

Append to `test/lib/tasks/books_goodreads_rake_test.rb`, inside the class:

```ruby
  test "seed_legacy_pages prints what it loaded" do
    seed = Services::Books::GoodreadsPages::SeedLegacyPages
    seed.expects(:call).returns(seed::Result.new(success?: true, data: {inserted: 3, already_present: 1, skipped: 2}, errors: []))

    assert_output(/inserted 3, already present 1, skipped 2/) { Rake::Task["books:goodreads:seed_legacy_pages"].invoke }
  ensure
    Rake::Task["books:goodreads:seed_legacy_pages"].reenable
  end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/models/legacy_books/goodreads_book_test.rb test/lib/services/books/goodreads_pages/seed_legacy_pages_test.rb test/lib/tasks/books_goodreads_rake_test.rb`
Expected: failures and errors. `GoodreadsBook.table_name` is not `goodreads_books`,
`SeedLegacyPages` is undefined, and the rake task does not exist.

- [ ] **Step 4: Write the model, the service and the rake task**

`app/models/legacy_books/goodreads_book.rb`:

```ruby
module LegacyBooks
  # The legacy app's Goodreads cache. Only its scraped rows are read, by the
  # page-cache seed (Goodreads import spec §6, "Legacy seed").
  class GoodreadsBook < Record
    self.table_name = "goodreads_books"

    # Rows a Goodreads lookup wrote: a page lookup sets last_looked_up_at
    # (and last_refreshed_at), a search result only last_refreshed_at. Rows
    # built from export rows carry neither.
    scope :scraped, -> { where.not(last_looked_up_at: nil).or(where.not(last_refreshed_at: nil)) }
  end
end
```

`app/lib/services/books/goodreads_pages/seed_legacy_pages.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsPages
      # Loads the legacy app's scraped Goodreads rows into the page cache
      # (Goodreads import spec §6, "Legacy seed"): about 12k page lookups and
      # 27k search results, all as found pages with source: legacy and no
      # HTML. Their facts about the id are trusted; their legacy link to a
      # Book is not carried over.
      #
      # Every name is role-less: the legacy writers merged translators,
      # illustrators and an export row's own author into one array, so any of
      # them backs an edition, and only the one that agreed becomes an author.
      #
      # Idempotent: an id already cached, fetched or seeded, is never
      # overwritten. Rows with no usable id, title or author are skipped.
      class SeedLegacyPages
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        BATCH = 1_000

        def self.call(records: nil)
          new(records: records).call
        end

        def initialize(records:)
          @records = records || ::LegacyBooks::GoodreadsBook.scraped.find_each(batch_size: BATCH)
        end

        def call
          counts = {inserted: 0, already_present: 0, skipped: 0}
          @records.each_slice(BATCH) do |batch|
            rows = batch.filter_map { |record| attributes_for(record) }
            counts[:skipped] += batch.size - rows.size
            unique = rows.uniq { |row| row[:goodreads_book_id] }
            inserted = unique.any? ? ::Books::GoodreadsPage.insert_all(unique, unique_by: :goodreads_book_id, returning: [:id]).length : 0
            counts[:inserted] += inserted
            counts[:already_present] += rows.size - inserted
          end
          Result.new(success?: true, data: counts, errors: [])
        end

        private

        def attributes_for(record)
          goodreads_book_id = ::Books::GoodreadsId.normalize(record.goodreads_id)&.to_i
          title, series_name, series_number = split_title(record.title, record.series)
          names = Array(record.authors).filter_map { |name| ::Services::Text::NameNormalizer.call(name.to_s).presence }.uniq
          return nil if goodreads_book_id.nil? || title.nil? || names.empty?

          isbn = ::Books::Isbn.normalize(record.isbn13) || ::Books::Isbn.normalize(record.isbn)
          {
            goodreads_book_id: goodreads_book_id,
            source: ::Books::GoodreadsPage.sources[:legacy],
            outcome: ::Books::GoodreadsPage.outcomes[:found],
            fetched_at: record.last_looked_up_at || record.last_refreshed_at,
            title: title,
            # The legacy scraper kept the series name and position, never its id.
            series: series_name ? [{"goodreads_series_id" => nil, "title" => series_name, "position" => series_number}] : [],
            authors: names.map { |name| {"name" => name, "role" => nil, "primary" => false} },
            original_publication_year: record.original_publication_year,
            isbn13: isbn&.isbn13, isbn10: isbn&.isbn10, asin: record.asin.presence
          }
        end

        # A page lookup stored the series apart ("Name #7"); a search result
        # left it on the title ("Title (Name, #7)").
        def split_title(raw_title, raw_series)
          title = ::Services::Text::NameNormalizer.call(raw_title.to_s)
          suffix = ::Books::Goodreads::ExportRow::SERIES_SUFFIX.match(title)
          return [suffix[:title].strip, suffix[:series].strip, suffix[:number].strip] if suffix

          series_name, series_number = raw_series.to_s.strip.split(/\s+#(?=[^#]*\z)/, 2)
          [title.presence, series_name.presence, series_number&.strip.presence]
        end
      end
    end
  end
end
```

In `lib/tasks/books/goodreads.rake`, inside `namespace :goodreads`:

```ruby
    desc "Load the legacy app's scraped Goodreads rows (page lookups and search results) into the page " \
      "cache. Idempotent; never overwrites a cached page. Reads the legacy_books database."
    task seed_legacy_pages: :environment do
      counts = Services::Books::GoodreadsPages::SeedLegacyPages.call.data
      puts "legacy Goodreads pages: inserted #{counts[:inserted]}, already present #{counts[:already_present]}, " \
        "skipped #{counts[:skipped]}"
    end
```

Add to `docs/features/goodreads-import.md`, at the end of "Goodreads verification":

```markdown
### Legacy seed

    bin/rails books:goodreads:seed_legacy_pages

Loads the legacy app's scraped `goodreads_books` rows into the cache as found pages with
`source: legacy` and no HTML. There are about 12k page lookups and 27k search results; the
export-derived rows are skipped. The legacy writers merged translators, illustrators and an export
row's own author into one `authors` array, so every legacy name has no role: any of them backs an
edition, and only the one that agreed becomes an author. A cached id is never overwritten, so the
task can run again after each migration pass.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/models/legacy_books/goodreads_book_test.rb test/lib/services/books/goodreads_pages/ test/lib/tasks/books_goodreads_rake_test.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Run the seed once against the dev legacy DB (read-only on legacy)**

Run: `bin/rails books:goodreads:seed_legacy_pages`
Expected: `inserted` near 39,400 and `skipped` in the hundreds (the non-numeric ids, plus
titleless or authorless rows). `already present` is 0 on the first run. Run it again. Expected:
`inserted 0`.

This writes only to the dev DB's new `books_goodreads_pages` table, so it is additive and not
destructive. If the legacy DB is not running, skip this step and say so in the ledger.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test > tmp/increment4_suite.log 2>&1; tail -5 tmp/increment4_suite.log
grep -i "warn" tmp/increment4_suite.log | grep -v -e weighted_list_rank -e yarn -e npm | head
bundle exec standardrb
git add app/models/legacy_books test/models/legacy_books app/lib/services/books/goodreads_pages test/lib/services/books/goodreads_pages lib/tasks/books/goodreads.rake test/lib/tasks/books_goodreads_rake_test.rb ../docs/features/goodreads-import.md
git commit -m "Goodreads pages: seed the cache from the legacy app's scraped rows"
```

Expected: 0 failures and 0 errors; no warning lines beyond the two known sources; standardrb
clean.
