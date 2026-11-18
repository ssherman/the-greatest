# Publisher Intake: Collect — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weekly intake that reads three publishers' catalogs through the page fetcher and holds each title's facts in new tables, with a read-only admin screen; nothing in the catalog is created or changed.

**Architecture:** One strategy class per publisher says what to fetch and reads what came back; a small framework owns fetching, pacing, storage and state. Discovery finds listing URLs, a sweep reads pending listings one at a time through a per-publisher gate on a single-thread Sidekiq capsule, and each page read is stored gzipped and upserted into one `Books::PublisherTitle` per title. The Goodreads fetch pipeline is the model for pacing, outcomes, storage and re-parsing.

**Tech Stack:** Rails 8, Sidekiq + sidekiq-cron, Postgres (jsonb, array columns), Active Storage (`private_imports` service), Nokogiri, `PageFetcher::Client` (`fetch`, `fetch_file`), Minitest + Mocha + WebMock, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-publisher-intake-collect-design.md` ("the spec"). Read it first; section numbers below refer to it.

## Global Constraints

- Work on branch `worktree-publisher-intake-collect` in `.claude/worktrees/publisher-intake-collect`. Never commit to `main`. Do not push or open a PR without being asked.
- Rails commands run from `web-app/`. Every task ends with its focused tests and `bundle exec standardrb` passing; the last task runs the full `bin/rails test`. Do not run brakeman. If `yarn install` fails on the Node version, put the version in `web-app/.node-version` first on `PATH`.
- Models, jobs and controllers come from generators (`bin/rails generate model`, `bin/rails generate sidekiq:job`, `bin/rails generate controller`). Services and library classes under `app/lib` are written by hand.
- Every migration ships with its annotaterb update in the same commit. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. The development database is shared between worktrees: delete from the annotation diff only lines for columns this branch's `schema.rb` does not have.
- Rails 8 enum syntax (`enum :state, {...}`). All new code is namespaced `Books::`; tests mirror the namespace.
- **Nothing in this plan writes to** `Books::Book`, `Books::Edition`, `Books::Author`, `Identifier`, categories or descriptions.
- **Goodreads is untouched in behaviour:** `Books::Goodreads::FetchGate.new` with no arguments keeps its Redis key (`goodreads:fetch`), limits and log line; its queue and capsule are unchanged; its tests pass unedited.
- Intake uses its own circuit breaker, key `page_fetcher:publisher_intake`, threshold 5, cooldown 60. It never uses the client's default `page_fetcher` breaker.
- Page HTML and descriptions never reach a log line, an exception message, or a public view. Pages are stored gzipped on the `private_imports` Active Storage service with `identify: false, metadata: {analyzed: true}`.
- No test makes a network request. The fetcher client is stubbed (Mocha) or its HTTP is stubbed (WebMock).
- Sidekiq is inline in tests: stub `perform_in` wherever a job reschedules itself, as `test/sidekiq/books/goodreads/fetch_page_job_test.rb` does.
- Jobs never sleep. Jobs set `retry:` explicitly (2 or 3).
- Defaults: fetch interval 10 s, daily cap 2,000 per source, block cooldown 6 hours, fetch attempts 3, run every 7 days, re-read after 28 days, lookback 30 days, horizon 365 days, stuck run 3 days, sweep every 10 minutes.
- This repository is public. Fixtures are trimmed real pages with long copy cut to a sentence. Docs, comments, commit messages and reports describe what the code does; they do not discuss any site's access rules.
- A clean `bin/rails test` prints no new warning lines.

## Review Focus

Inputs the spec implies but does not list as tests. Each has a test in the task named.

1. **Two listings of one title read in the same sweep** (a hardcover URL and its ebook URL, both pending and both already queued). The second read must land on the same `PublisherTitle`, not create a second one. Task 5.
2. **Dates that are missing or absurd in a discovery source** (Penguin Random House has entries dated 1976 and 2079; a Hachette record with an empty `release_date`). They fall outside the window and are skipped; nothing raises. Tasks 8 and 9.
3. **ISBNs as people write them** ("978-0-8021-6999-0", an ISBN-10, a 13-digit number with a bad check digit). Hyphens are removed, an ISBN-10 is converted, an invalid one is dropped, and a page left with none is `unparseable`. Task 5.
4. **A source switched off with work in flight.** Jobs already queued for a source no longer in `PUBLISHER_INTAKE_SOURCES` do nothing: no gate turn, no fetch. Task 6.
5. **Rows whose source is no longer registered** (a strategy was renamed or removed). The admin screen still renders them under the raw key, and the sweep and daily job ignore them. Tasks 7 and 12.

## File Structure

| Path (under `web-app/`) | Responsibility |
|---|---|
| `app/lib/books/fetch_gate.rb` | The gate logic, keyed and configured by its caller (extracted from the Goodreads gate) |
| `app/lib/books/goodreads/fetch_gate.rb` | Becomes a thin subclass supplying the Goodreads key, config and label |
| `app/lib/books/publisher_intake.rb` | `settings`, `gate_for`, `client` |
| `app/lib/books/publisher_intake/{request,listing_ref,discovery,reading}.rb` | Value objects |
| `app/lib/books/publisher_intake/sources.rb`, `sources/base.rb` | Registry and the strategy interface |
| `app/lib/books/publisher_intake/sources/{hachette_us,penguin_random_house_us,macmillan_us}.rb` | The three strategies |
| `app/lib/books/publisher_intake/{sitemap_reader,json_ld,isbn,hold}.rb` | Shared readers and the hold classifier |
| `app/lib/services/books/publisher_intake/*.rb` | `RecordDiscovery`, `StoreReading`, `ReadListing`, `RunDiscoveryRequest`, `StartRun`, `QueueRereads`, `Reparse`, `Rehearse`, `Status` |
| `app/models/books/publisher_{listing,title,intake_run}.rb` | The three tables |
| `app/sidekiq/books/publisher_intake/{daily,sweep,discovery_request,read_listing}_job.rb` | Jobs |
| `app/controllers/admin/books/publisher_intake_controller.rb`, `publisher_titles_controller.rb` + views, `app/policies/books/publisher_title_policy.rb` | Admin screen |
| `config/initializers/publisher_intake.rb`, `config/initializers/sidekiq.rb`, `config/sidekiq.yml`, `config/schedule.yml` | Settings read from the environment (tolerant of bad values), the `publisher_fetch` capsule, two cron entries |
| `lib/tasks/books/publisher_intake.rake` | Operator and fixture-capture tasks |
| `test/fixtures/files/publisher_intake/<source>/` | Trimmed pages and small synthetic files |

---

### Task 1: Settings and the capsule

**Files:**
- Create: `config/initializers/publisher_intake.rb`
- Modify: `config/initializers/sidekiq.rb` (new capsule beside `goodreads_fetch`), `config/sidekiq.yml` (the comment listing capsules), `deployment/ENV.md` (three env vars; the capsule's one extra thread)
- Test: `test/config/publisher_intake_initializer_test.rb` (new), `test/config/sidekiq_config_test.rb` (add the capsule)

**Interfaces:**
- Produces `Rails.application.config.x.publisher_intake`, an `ActiveSupport::OrderedOptions` with keys `enabled_sources` (Array<String>), `fetch_interval`, `daily_fetch_cap`, `block_cooldown`, `fetch_attempts`, `run_every_days`, `reread_after_days`, `lookback_days`, `horizon_days`, `stuck_run_days`, `fetch_timeout_ms`.
- App constants cannot be referenced while Rails boots (see the comment in `config/initializers/doorkeeper.rb`), so there is no settings class under `app/lib`. The initializer is self-contained, like `config/initializers/goodreads.rb`: it uses `GoodreadsEnv.integer` (already loaded; `goodreads.rb` sorts first) for the two integers and defines `module PublisherIntakeEnv` with `def self.sources(raw) -> Array<String>` for the list.
- Env: `PUBLISHER_INTAKE_SOURCES` (comma-separated), `PUBLISHER_INTAKE_FETCH_INTERVAL`, `PUBLISHER_INTAKE_DAILY_FETCH_CAP`. Everything else is a literal: `block_cooldown: 21_600`, `fetch_attempts: 3`, `run_every_days: 7`, `reread_after_days: 28`, `lookback_days: 30`, `horizon_days: 365`, `stuck_run_days: 3`, `fetch_timeout_ms: 30_000`.
- Capsule: name `publisher_fetch`, `concurrency = 1`, `queues = %w[publisher_fetch]`.

- [ ] **Step 1: Write the failing tests.** Read `test/config/goodreads_initializers_test.rb` and `test/config/sidekiq_config_test.rb` first and test the same way they do.

```ruby
test "defaults when nothing is set" do
  s = Rails.application.config.x.publisher_intake
  assert_equal [[], 10, 2_000, 21_600, 3, 7, 28, 30, 365, 3, 30_000],
    [s.enabled_sources, s.fetch_interval, s.daily_fetch_cap, s.block_cooldown, s.fetch_attempts,
      s.run_every_days, s.reread_after_days, s.lookback_days, s.horizon_days, s.stuck_run_days, s.fetch_timeout_ms]
end
test "sources are split, stripped and de-duplicated" do
  assert_equal %w[hachette_us macmillan_us], PublisherIntakeEnv.sources(" hachette_us, macmillan_us ,,hachette_us ")
end
test "no sources for nil or blank" do
  assert_equal [[], []], [PublisherIntakeEnv.sources(nil), PublisherIntakeEnv.sources("  ")]
end
test "the two integers are read from the environment and a bad value falls back" do
  # the way goodreads_initializers_test.rb exercises GOODREADS_FETCH_INTERVAL
end
# sidekiq_config_test.rb: the publisher_fetch capsule exists with concurrency 1 and its one queue
```

- [ ] **Step 2: Run** `bin/rails test test/config/publisher_intake_initializer_test.rb test/config/sidekiq_config_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the initializer, the capsule, and the two comment/doc edits.
- [ ] **Step 4: Run** the tests and `bundle exec standardrb`. Expected: PASS, no offenses. Run `bin/rails runner 'puts Rails.application.config.x.publisher_intake.fetch_interval'` and expect `10`.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: settings and the publisher_fetch capsule"`.

---

### Task 2: A gate any caller can key

**Files:**
- Create: `app/lib/books/fetch_gate.rb`
- Modify: `app/lib/books/goodreads/fetch_gate.rb`
- Create: `app/lib/books/publisher_intake.rb`
- Test: `test/lib/books/fetch_gate_test.rb`, `test/lib/books/publisher_intake_test.rb`. `test/lib/books/goodreads/fetch_gate_test.rb` must pass **unedited**.

**Interfaces:**
- Produces:

```ruby
class Books::FetchGate
  def initialize(key:, config:, label:, redis: nil)   # config responds to fetch_interval, daily_fetch_cap, block_cooldown
  # reserve, blocked?, usage, blocked_until, spacing_wait, started!, block!  -- moved here unchanged
  def reopens_at   # Time a refused reservation could succeed: blocked_until if blocked;
                   # the start of the next UTC day if today's cap is spent; nil if neither
end

class Books::Goodreads::FetchGate < Books::FetchGate
  KEY = "goodreads:fetch"
  def initialize(redis: nil, config: nil)   # super(key: KEY, config: config || config.x.goodreads, label: "Goodreads", redis:)
end

module Books::PublisherIntake
  def self.settings                 # Rails.application.config.x.publisher_intake
  def self.gate_for(source_key)     # Books::FetchGate, key "publisher_intake:fetch:#{source_key}", config settings, label source_key
  def self.client                   # PageFetcher::Client with breaker Books::OpenLibrary::CircuitBreaker.new(
                                    #   key: "page_fetcher:publisher_intake", failure_threshold: 5, cooldown: 60)
end
```

- `Reservation`, `Usage` and `MEMORY` move to `Books::FetchGate`; the Goodreads class keeps resolving them (inherited constants).
- The log line in `block!` uses the label: `"#{self.class.name}: #{label} blocked a fetch; no fetches for #{block_cooldown}s"`. For Goodreads it reads exactly as it does today.

- [ ] **Step 1: Write the failing tests.** In `fetch_gate_test.rb`, using `Books::OpenLibrary::FakeRedis` and an `OrderedOptions` config as the Goodreads gate test does:

```ruby
test "two gates with different keys do not share a line, a cap or a block" do
  # a = gate("x"), b = gate("y"); a.block!  -> a.blocked? true, b.blocked? false
  # a second pair: reserving on one never advances the other's next start or day count
end
test "reopens_at is the block's end while blocked" do
  # travel_to t; gate.block! -> gate.reopens_at == t + block_cooldown
end
test "reopens_at is the next UTC midnight once the day's cap is spent" do
  # daily_fetch_cap: 1; reserve once at 2026-11-17 10:00 UTC -> reopens_at == 2026-11-18 00:00 UTC
end
test "reopens_at is nil when the gate is open"
```

In `publisher_intake_test.rb`:

```ruby
test "each source gets its own gate key" do
  # gate_for("hachette_us") and gate_for("macmillan_us") block independently (FakeRedis via stub of REDIS_POOL or redis: injection)
end
test "the client's breaker is not the default page_fetcher one" do
  # Books::PublisherIntake.client.breaker key is "page_fetcher:publisher_intake"
end
```

- [ ] **Step 2: Run** both new test files. Expected: FAIL, uninitialized constant `Books::FetchGate`.
- [ ] **Step 3: Extract.** Move the body of the Goodreads gate into `Books::FetchGate` with `KEY` replaced by the `key:` argument and the label interpolated; add `reopens_at`. Reduce the Goodreads file to the subclass above, keeping its class comment's substance.
- [ ] **Step 4: Run** `bin/rails test test/lib/books/fetch_gate_test.rb test/lib/books/publisher_intake_test.rb test/lib/books/goodreads test/sidekiq/books/goodreads test/lib/workflows/books` and `bundle exec standardrb`. Expected: PASS with the Goodreads files unedited (`git diff --stat` shows no change under `test/lib/books/goodreads/`).
- [ ] **Step 5: Commit** `git commit -m "Books::FetchGate: the Goodreads gate's logic, keyed by its caller"`.

---

### Task 3: The three tables

**Files:**
- Create (generators): `app/models/books/publisher_listing.rb`, `publisher_title.rb`, `publisher_intake_run.rb`, three migrations, three fixture files, three model tests
- Modify: `db/schema.rb` (by migrating)

**Interfaces:**
- Produces the models of spec §1 with these exact definitions:

```ruby
class Books::PublisherIntakeRun   # books_publisher_intake_runs
  # source:string!  kind:integer!(default 0)  status:integer!(default 0)  baseline:boolean!(default false)
  # started_at:datetime!  finished_at:datetime  error:text  counts:jsonb!(default {})
  enum :kind, {weekly: 0, manual: 1}, prefix: true
  enum :status, {running: 0, finished: 1, failed: 2}, prefix: true
  scope :for_source, ->(key) { where(source: key) }
  # counts keys (strings): "requests", "outstanding", "listings_seen", "listings_new", "listings_changed"
end

class Books::PublisherTitle        # books_publisher_titles
  # source:string!  source_key:string  isbn13s:string[]!(default [])  title:string  subtitle:string
  # contributors:jsonb!(default [])  on_sale_on:date  formats:jsonb!(default [])  imprint_name:string
  # publisher_name:string  language:string  genres:jsonb!(default [])  series_name:string
  # series_position:string  age_range:string  description:text  cover_url:string
  # status:integer!(default 0)  hold_reason:integer  first_read_at:datetime  last_read_at:datetime  parser_version:integer
  enum :status, {ready: 0, held: 1}, prefix: true
  enum :hold_reason, {incomplete: 0, placeholder: 1, non_english: 2, not_a_book: 3, set: 4}, prefix: true
  has_many :listings, class_name: "Books::PublisherListing", foreign_key: :publisher_title_id, dependent: :nullify
  scope :upcoming_first, -> { order(Arel.sql("on_sale_on IS NULL, on_sale_on ASC, id ASC")) }
end

class Books::PublisherListing      # books_publisher_listings
  # source:string!  url:string!  external_key:string  state:integer!(default 1)  signal:string
  # outcome:integer  http_status:integer  parser_version:integer
  # last_attempt_outcome:integer  last_attempt_at:datetime  attempts:integer!(default 0)  queued_at:datetime
  # first_seen_at:datetime!  last_seen_at:datetime!  read_at:datetime  publisher_title_id:bigint (FK, nullify)
  enum :state, {baseline: 0, pending: 1, read: 2, covered: 3, failed: 4}, prefix: true
  enum :outcome, {found: 0, not_found: 1, blocked: 2, unparseable: 3}, prefix: true
  enum :last_attempt_outcome, {found: 0, not_found: 1, blocked: 2, unparseable: 3, unavailable: 4, fetcher_down: 5}, prefix: :last_attempt
  belongs_to :publisher_title, class_name: "Books::PublisherTitle", optional: true
  has_one_attached :html, service: :private_imports
end
```

- Indexes: listings `[source, url]` unique, `[source, state]`, `[source, external_key]`, `publisher_title_id`; titles `[source, source_key]` unique `where source_key IS NOT NULL`, `isbn13s` GIN, `[source, status]`, `on_sale_on`; runs `[source, started_at]`.
- Validations: presence of `source` on all three; `url` present and unique within `source`; `started_at` present on runs. A held title has a `hold_reason`; a ready one has none.
- No `has_many` on `User`, and no association from `Books::Book`: these tables do not reference either.

- [ ] **Step 1: Generate** the three models with their columns, edit the migrations for defaults, null constraints and indexes, run `bin/rails db:migrate`, and check the annotation diff per Global Constraints.
- [ ] **Step 2: Write the model tests** (they fail on missing enums and validations):

```ruby
# PublisherListing
test "a url is unique within its source and reusable across sources"
test "a new listing is pending by default and has made no attempts"
test "state, outcome and last attempt outcome are separate enums with prefixed predicates" do
  # listing.state_read?, listing.outcome_found?, listing.last_attempt_unavailable?
end
test "the page attaches to the private imports service" do
  # Books::PublisherListing.reflect_on_attachment(:html).options[:service_name] == :private_imports
end
# PublisherTitle
test "held needs a reason and ready must not have one"
test "upcoming_first puts the soonest on-sale date first and undated titles last"
test "listings are kept, unlinked, when a title is destroyed"
# PublisherIntakeRun
test "a run needs a source and a start time"
test "counts default to an empty hash"
```

Fixtures: one listing per state, one ready title with two formats, one held title per hold reason, one finished and one failed run, all with `source: hachette_us` or `macmillan_us`.
- [ ] **Step 3: Implement** enums, associations, validations, scopes.
- [ ] **Step 4: Run** `bin/rails test test/models/books/publisher_listing_test.rb test/models/books/publisher_title_test.rb test/models/books/publisher_intake_run_test.rb`, `CI=1 bin/rails zeitwerk:check`, `bundle exec standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: listings, titles and runs"` (models, migrations, schema, annotations, fixtures, tests).

---

### Task 4: The strategy interface and shared readers

**Files:**
- Create: `app/lib/books/publisher_intake/{request,listing_ref,discovery,reading}.rb`, `sources.rb`, `sources/base.rb`, `sitemap_reader.rb`, `json_ld.rb`, `isbn.rb`, `hold.rb`
- Test: one test file per class under `test/lib/books/publisher_intake/`
- Fixtures: `test/fixtures/files/publisher_intake/shared/` (small synthetic sitemap and JSON-LD files, each with a comment saying it is synthetic)

**Interfaces:**
- Produces:

```ruby
module Books::PublisherIntake
  Request = Data.define(:kind, :url, :page_url, :wait_for_selector, :context) do
    # kind: "page" | "file".  context: Hash with string keys, JSON-serializable.
    def self.page(url, wait_for_selector: nil, context: {})
    def self.file(url, page_url: nil, context: {})
    def self.from_h(hash)        # accepts string keys, as Sidekiq delivers them
    def to_h                     # string keys
  end
  ListingRef = Data.define(:url, :external_key, :signal)
  Discovery  = Data.define(:outcome, :listings, :requests)   # outcome: :ok | :blocked | :unavailable | :unparseable
  Reading    = Data.define(:outcome, :facts, :sibling_keys)  # outcome: :found | :not_found | :blocked | :unparseable | :unavailable

  module Sources
    def self.registry            # {"hachette_us" => Sources::HachetteUs, ...}; empty until Tasks 8-10 add entries
    def self.fetch(key)          # a strategy instance, or nil for an unknown key
    def self.enabled             # instances for settings.enabled_sources that are registered; an unknown key is logged once and skipped
  end

  class Sources::Base
    def key; def name; def parser_version          # subclasses define
    def baseline_on_first_run? = false
    def discovery_requests(since:)                  # => [Request]
    def seed_requests = []
    def parse_discovery(request:, response:)        # => Discovery
    def listing_request(listing)                    # => Request
    def parse_listing(listing:, page:)              # => Reading
    # helpers for subclasses:
    def status_outcome(status)    # 404, 410 -> :not_found; 401, 403, 429 -> :blocked; >= 500 -> :unavailable; else nil
    def in_window?(date)          # date within today - lookback_days .. today + horizon_days; false for nil
  end

  SitemapReader.call(bytes) -> SitemapReader::Result(kind: :index | :urlset, entries: [Entry(loc:, lastmod:)])
    # bytes may be gzipped (magic bytes) or plain XML; lastmod is a Date or nil; raises SitemapReader::Unreadable otherwise
  JsonLd.nodes(html, types:) -> [Hash]
    # every JSON-LD node, at any depth and inside @graph, whose @type (string or array) includes one of types;
    # a script that is not valid JSON is skipped, not raised
  Isbn.normalize(value) -> String | nil
    # 13 digits with a valid check digit; hyphens and spaces removed; an ISBN-10 converted; anything else nil
  Hold.call(facts) -> [status, hold_reason]   # [:ready, nil] or [:held, :incomplete | :placeholder | :non_english | :not_a_book | :set]
end
```

- Before writing `Isbn`, search the app for an existing ISBN normaliser (`grep -rn "isbn" app/lib app/models | grep -i -E "normal|check_digit|isbn10"`). If one exists with these semantics, `Isbn.normalize` delegates to it.
- `Hold` implements spec §7 exactly, first match wins, in the order `incomplete`, `placeholder`, `non_english`, `not_a_book`, `set`. `facts` is a hash with symbol keys named after the `PublisherTitle` columns.
  - `placeholder`: `/\A\s*(untitled|to be confirmed|tbc|tbd|title to be announced)\b/i` on the title, or the only contributor's name matching `/\A(to be confirmed|tbc|tbd|author to be announced)\z/i`.
  - `non_english`: `language` present and not one of `en`, `eng`, `english`, or starting `en-` (case-insensitive).
  - `not_a_book`: at least one format, and every format's `format_label` matches `/\b(calendar|journal|notebook|planner|cards?|deck|puzzle|stationery|sticker|toy|kit|poster|game)\b/i`.
  - `set`: per spec §7, using `Services::Books::Verification::EditionCheck::SET_WORDS`, `Services::Books::AmazonBookCheck::SERIES_NAME_WORDS` and `Services::Books::AmazonBookCheck::NUMBER_RANGE`; a format label matching `/\b(box(ed)?[\s-]?set|bundle)\b/i` is a set on its own.

- [ ] **Step 1: Write the failing tests.** Name each for its behaviour. Required cases:

| Class | Cases |
|---|---|
| `Request` | `page` and `file` builders; `to_h` has string keys; `from_h(to_h)` round-trips; `from_h` of a JSON round trip (`JSON.parse(to_h.to_json)`) equals the original |
| `Sources` | unknown key → `fetch` nil; `enabled` returns only registered, enabled keys, in settings order; an unknown enabled key is skipped and logged |
| `Base` | `status_outcome` table above; `in_window?` true for today, today − 30, today + 365; false for today − 31, today + 366, nil (use `travel_to`) |
| `SitemapReader` | an index with three children; a URL set with `lastmod` as a date and as a full timestamp; the same URL set gzipped; an entry with no `lastmod` → nil; HTML in place of XML → `Unreadable`; empty bytes → `Unreadable` |
| `JsonLd` | a top-level `Book`; a `Book` inside `@graph`; `@type` as `["Product", "Book"]`; a nested `workExample` array is returned when `types:` includes `Book`; two scripts where the first is invalid JSON; no JSON-LD → `[]` |
| `Isbn` | "9780316564861" → itself; "978-0-8021-6999-0" → "9780802169990"; ISBN-10 "0802169996" → "9780802169990"; a 13-digit number with a wrong check digit → nil; "" and nil → nil (Review Focus 3) |
| `Hold` | one ready title; each hold reason; order (a placeholder that is also non-English is `incomplete` only when a required field is missing, else `placeholder`); "A Collection of Essays" ready; "The Tolstoy Trilogy" ready; "The Complete Series Box Set" set; "Books 1-3" set; title "#1-3" range set; a series name of "Omnibus Editions" with an ordinary title is ready; one calendar format plus one hardcover is ready; a language of "en-GB" is ready; "es" is non_english |

- [ ] **Step 2: Run** `bin/rails test test/lib/books/publisher_intake`. Expected: FAIL, uninitialized constants.
- [ ] **Step 3: Implement** the classes.
- [ ] **Step 4: Run** the same tests, `CI=1 bin/rails zeitwerk:check`, `bundle exec standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: strategy interface, readers and the hold rules"`.

---

### Task 5: Recording discovery and storing a reading

**Files:**
- Create: `app/lib/services/books/publisher_intake/record_discovery.rb`, `store_reading.rb`
- Test: `test/lib/services/books/publisher_intake/record_discovery_test.rb`, `store_reading_test.rb`

**Interfaces:**
- Consumes: Task 3 models; Task 4 `ListingRef`, `Reading`, `Hold`, `Isbn`.
- Produces (both use `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`):

```ruby
Services::Books::PublisherIntake::RecordDiscovery.call(run:, listings:, seed: false)
  # listings: [ListingRef].  data: {seen:, created:, changed:}.  Also adds those three to
  # run.counts "listings_seen" / "listings_new" / "listings_changed" under run.with_lock.

Services::Books::PublisherIntake::StoreReading.call(listing:, reading:, page:, parser_version:)
  # page: the PageFetcher::Page (html, status), or nil when nothing was fetched.
  # data: {outcome:, title:}
```

**`RecordDiscovery` rules** (spec §3 table and §5), for each ref, matched on `[run.source, ref.url]`:

| Existing row | `run.baseline` | `seed` | Result |
|---|---|---|---|
| none | false | either | create `pending` |
| none | true | false | create `baseline` |
| none | true | true | create `pending` |
| `baseline` | either | true | becomes `pending` |
| `read`, and `ref.signal` is present and differs from the stored one | either | either | becomes `pending`, `signal` updated, counted as changed |
| anything else | either | either | `last_seen_at` updated; `signal` stored if it was nil |

New rows get `first_seen_at` and `last_seen_at` = now, `external_key` and `signal` from the ref. A ref with a blank URL is skipped. The same URL twice in one call is handled once.

**`StoreReading` rules** (spec §4), where "was read" means `listing.read_at.present?`: its page was found at least once. (Not `state_read?`: a listing being fetched again has already been moved back to `pending`.)

| `reading.outcome` | Was read? | Listing after | Stored |
|---|---|---|---|
| `:found` | either | `read`; `outcome`, `http_status`, `parser_version`, `read_at` set; `attempts` 0 | page replaced; title upserted and classified; siblings covered |
| `:not_found` | either | `failed`, `outcome` not_found | page and title untouched |
| `:blocked`, `:unparseable` | no | stays `pending`; `outcome` set | page replaced |
| `:blocked`, `:unparseable` | yes | back to `read`; stored `outcome`, page, facts, title all unchanged | nothing |
| `:unavailable` | no | `attempts` + 1; `failed` when it reaches `settings.fetch_attempts`, else `pending` | nothing |
| `:unavailable` | yes | back to `read`, nothing else changed | nothing |

Every call sets `last_attempt_outcome` and `last_attempt_at`, and clears `queued_at`.

Upserting the title on `:found`:
- Normalise every ISBN in `facts[:formats]` with `Isbn.normalize`; drop a format whose ISBN is nil. If no ISBN-13 is left, or the title is blank, treat the reading as `:unparseable` (a page with no contributor is still found).
- Find the title by `[source, facts[:source_key]]` when a source key is given; otherwise the title of the same source whose `isbn13s` overlaps (`&&`) the page's ISBNs. Two overlap: take the one sharing the most ISBNs, the lower `id` on a tie, and `Rails.logger.warn` naming both ids.
- Assign the facts; `isbn13s` becomes the union of old and new; `on_sale_on` is the earliest `on_sale_on` among the formats (falling back to `facts[:on_sale_on]`); `status` and `hold_reason` from `Hold.call`; `first_read_at` once, `last_read_at` now; `parser_version`.
- Set `listing.publisher_title`. Every other listing of the same source whose `external_key` is in `reading.sibling_keys` (normalised) and whose state is `baseline` or `pending` becomes `covered` with the same title.
- Attach the page with `Zlib.gzip(page.html)`, filename `"#{listing.source}-#{listing.id}.html.gz"`, `content_type: "application/gzip"`, `identify: false`, `metadata: {analyzed: true}`.
- All of it in one transaction.

- [ ] **Step 1: Write the failing tests.** One test per row of both tables, plus:

```ruby
# RecordDiscovery
test "counts are added to the run and survive a second call" do   # two calls -> counts are sums
test "the same url twice in one call makes one listing"
# StoreReading
test "a found reading makes a title with its formats, earliest on-sale date and hold status"
test "a second listing of the same title lands on the same title by ISBN overlap" do   # Review Focus 1
  # A read first with formats [isbn_a, isbn_b]; B (external_key isbn_b) was already queued and is read:
  # PublisherTitle.count stays 1; B.publisher_title == A.publisher_title; isbn13s is the union
end
test "siblings that are baseline or pending become covered, a read sibling is left alone"
test "a source key beats ISBN overlap when both are present"
test "two overlapping titles: the one sharing more ISBNs wins and a warning names both"
test "ISBNs are normalised; an invalid one drops its format; none left is unparseable" do   # Review Focus 3
  # formats with "978-0-8021-6999-0", "0802169996" and a bad check digit
end
test "a blocked re-read of a read listing keeps the stored page, outcome, facts and title" do
  # compare listing.html.blob.checksum and title.attributes before and after
end
test "the third unavailable attempt fails the listing; any other outcome resets attempts"
test "the stored page is gzipped HTML on the private imports service"
test "nothing is written to books, editions, authors or identifiers" do
  # assert_no_difference ["Books::Book.count", "Books::Edition.count", "Books::Author.count", "Identifier.count"]
end
```

- [ ] **Step 2: Run** the two test files. Expected: FAIL, uninitialized constants.
- [ ] **Step 3: Implement** both services.
- [ ] **Step 4: Run** the tests and `bundle exec standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: record discovery, store a reading"`.

---

### Task 6: Fetching, one turn at a time

**Files:**
- Create: `app/lib/services/books/publisher_intake/read_listing.rb`, `run_discovery_request.rb`
- Create (generator): `app/sidekiq/books/publisher_intake/read_listing_job.rb`, `discovery_request_job.rb` and their tests
- Test: `test/lib/services/books/publisher_intake/read_listing_test.rb`, `run_discovery_request_test.rb`, `test/sidekiq/books/publisher_intake/*_test.rb`

**Interfaces:**
- Consumes: Task 2 `Books::PublisherIntake.gate_for`, `.client`, `Books::FetchGate#reopens_at`; `Books::Goodreads::GateTurn` (generic: `GateTurn.call(gate:, due:) -> Decision(action: :fetch | :wait | :refused, wait:, refusal:)`, `GateTurn.after_fetch(gate:, outcome:)`); Task 4 strategy interface; Task 5 services.
- Produces:

```ruby
Services::Books::PublisherIntake::ReadListing.call(listing:, due: false)
  # data: {action: :done | :wait | :refused | :skipped, wait:, outcome:}
Services::Books::PublisherIntake::RunDiscoveryRequest.call(run:, request:, due: false, attempt: 1)
  # data: {action: :done | :wait | :retry | :skipped, wait:, outcome:, requests: [Request]}

class Books::PublisherIntake::ReadListingJob        # sidekiq_options queue: :publisher_fetch, retry: 2
  def perform(listing_id, due = false)
class Books::PublisherIntake::DiscoveryRequestJob   # sidekiq_options queue: :publisher_fetch, retry: 2
  def perform(run_id, request_hash, due = false, attempt = 1)
```

**Fetching a `Request`** (shared private helper): `kind "page"` → `client.fetch(url, wait_for_selector:, timeout_ms: settings.fetch_timeout_ms)`; `kind "file"` → `client.fetch_file(url, page_url:, timeout_ms: settings.fetch_timeout_ms)`. Exceptions map as in `Services::Books::GoodreadsPages::FetchPage`: `CircuitOpenError`, `ConfigurationError`, `ClientError` → `:fetcher_down`; any other `PageFetcher::Exceptions::Error` → `:unavailable`. Neither stores anything nor logs the body.

**`ReadListing`:**
1. `:skipped` unless the listing is `pending` and its source is in `Sources.enabled`.
2. `GateTurn.call(gate: gate_for(source), due:)`. `:refused` → return `:refused` (the listing stays pending; clear `queued_at`). `:wait` → return `:wait` with the wait.
3. Fetch `strategy.listing_request(listing)`. `:fetcher_down` → record `last_attempt_outcome` fetcher_down, clear `queued_at`, return `:done`. `:unavailable` → `StoreReading` with an unavailable reading.
4. Otherwise `strategy.parse_listing(listing:, page:)` → `StoreReading`. A parser that raises is an `:unparseable` reading, logged by error class only.
5. `GateTurn.after_fetch(gate:, outcome:)` (blocks the gate on `:blocked` only).

**`RunDiscoveryRequest`**, per spec §3's discovery table:
1. `:skipped` unless the run is `running` and its source is enabled.
2. Gate turn. `:wait` → `:wait`. `:refused` → `:refused` with `gate.reopens_at - now` (at least 60 s). A refusal reserved nothing, so it is kept distinct from a wait: the job reschedules it with `due = false`.
3. Fetch. `:fetcher_down` or `:unavailable` → `:retry` while `attempt < settings.fetch_attempts`, else fail the run (`status` failed, `error` naming the request URL and the outcome, `finished_at`).
4. `strategy.parse_discovery(request:, response:)`:
   - `:ok` → `RecordDiscovery.call(run:, listings:, seed: request.context["seed"] == true)`; return the follow-up requests.
   - `:blocked` → `gate.block!`; `:refused` with `gate.reopens_at - now`.
   - `:unavailable` → as step 3.
   - `:unparseable`, or the parser raising → fail the run at once. A parser that raises is logged by error class only, never by message.
5. `GateTurn.after_fetch` is not used here; step 4 blocks explicitly.

**Jobs:**
- `ReadListingJob`: `:wait` → `self.class.perform_in(wait, listing_id, true)`; everything else ends.
- `DiscoveryRequestJob`: `:wait` → `perform_in(wait, run_id, request_hash, true, attempt)`; `:refused` → `perform_in(wait, run_id, request_hash, false, attempt)`; `:retry` → `perform_in(60, run_id, request_hash, false, attempt + 1)`; `:done` → under `run.with_lock`: add the follow-ups to `counts["requests"]` and `counts["outstanding"]`, enqueue one job each (carrying `"seed" => true` in the context when the parent had it), then decrement `outstanding`; when it reaches 0 the run is `finished` with `finished_at`.

- [ ] **Step 1: Write the failing tests.** Stub `Books::PublisherIntake.client` with a Mocha mock and register a small test strategy in the registry for the duration of a test (restore it in `teardown`). Stub `perform_in` in job tests. Required cases:

```ruby
# ReadListing
test "a pending listing is fetched, parsed and stored"
test "a page request and a file request call fetch and fetch_file with the settings timeout"
test "a refused turn fetches nothing and leaves the listing pending"
test "a wait is returned without fetching"
test "a blocked page blocks the gate for that source only"
test "an unparseable page does not block the gate"
test "a fetcher-down error stores nothing and does not count as an attempt"
test "a timeout counts as an unavailable attempt"
test "a listing whose source is switched off is skipped without a gate turn" do   # Review Focus 4
  # settings.enabled_sources = []; gate.usage.count unchanged; client never called
end
test "a listing that is no longer pending is skipped"
# RunDiscoveryRequest
test "an ok response records listings and returns the follow-up requests"
test "a seed request's listings are pending even in a baseline run"
test "a refused turn waits until the gate reopens"
test "a blocked response blocks the gate and waits for the cooldown; the run stays running"
test "unavailable retries until fetch_attempts, then fails the run with the url in the error"
test "an unparseable response fails the run at once"
test "a request for a run that is not running is skipped"
# Jobs
test "ReadListingJob reschedules itself with due true on a wait and never sleeps"
test "DiscoveryRequestJob enqueues each follow-up and finishes the run when none is outstanding" do
  # index request -> two children -> outstanding goes 1 -> 2 -> 1 -> 0; status finished
end
test "DiscoveryRequestJob keeps the seed flag on follow-ups"
test "a run with requests still outstanding stays running"
```

- [ ] **Step 2: Run** the new test files. Expected: FAIL.
- [ ] **Step 3: Implement** the two services and the two jobs.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/publisher_intake test/sidekiq/books/publisher_intake` and `bundle exec standardrb`. Expected: PASS, with no `sleep` in the new files (`grep -rn "sleep" app/lib/services/books/publisher_intake app/sidekiq/books/publisher_intake` prints nothing).
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: paced discovery and reading jobs"`.

---

### Task 7: Starting runs, sweeping, re-reading

**Files:**
- Create: `app/lib/services/books/publisher_intake/start_run.rb`, `queue_rereads.rb`
- Create (generator): `app/sidekiq/books/publisher_intake/daily_job.rb`, `sweep_job.rb` and tests
- Modify: `config/schedule.yml`
- Test: `test/lib/services/books/publisher_intake/start_run_test.rb`, `queue_rereads_test.rb`, job tests

**Interfaces:**
- Consumes: Tasks 3-6.
- Produces:

```ruby
Services::Books::PublisherIntake::StartRun.call(source:, kind: :weekly)   # source: a strategy instance
  # data: {run:} ; creates the run and enqueues its first DiscoveryRequestJobs
Services::Books::PublisherIntake::QueueRereads.call(source:)              # data: {queued:}

class Books::PublisherIntake::DailyJob   # queue: :low, retry: 2 ; def perform
class Books::PublisherIntake::SweepJob   # queue: :low, retry: 2 ; def perform
```

- `schedule.yml` entries: `publisher_intake_daily`, cron `"20 6 * * *"`; `publisher_intake_sweep`, cron `"*/10 * * * *"`. Each description says it does nothing unless `PUBLISHER_INTAKE_SOURCES` names a source.

**`StartRun`:** `since` = `started_at` of the source's latest `finished` run (nil if none). `baseline` = `strategy.baseline_on_first_run?` and the source has no finished run. Requests = `strategy.discovery_requests(since:)`, plus `strategy.seed_requests` with `"seed" => true` merged into each context when the source has no finished run. Create the run (`status` running, `started_at` now, `counts` with `"requests"` and `"outstanding"` = the number of requests), then enqueue one `DiscoveryRequestJob.perform_async(run.id, request.to_h)` each. A strategy that returns no requests makes a run that is `finished` at once.

**`DailyJob#perform`:** return unless `Sources.enabled.any?`. Then, in order:
1. Fail every `running` run whose `started_at` is more than `stuck_run_days` ago (`error: "no progress for 3 days"`), for any source.
2. For each enabled source: `QueueRereads.call(source:)`.
3. For each enabled source with no `running` run and no finished run that started within the last seven calendar days: `StartRun.call(source:)`.

**`QueueRereads`** (spec §6): listings of the source in state `read` with `read_at` older than `reread_after_days`, whose title either is held as `placeholder` or `incomplete`, or (only when the listing's `signal` is nil) has `on_sale_on` nil or after today. They become `pending`.

**`SweepJob#perform`:** return unless `Sources.enabled.any?`. For each enabled source whose gate is not blocked and whose `reopens_at` is nil: take up to `(600 / settings.fetch_interval).floor` listings in state `pending` with `queued_at` nil or more than an hour old, excluding those whose `last_attempt_outcome` is unparseable with `last_attempt_at` within the last day; order by `first_seen_at`, then `id`; stamp `queued_at` and enqueue `ReadListingJob.perform_async(id)` for each.

- [ ] **Step 1: Write the failing tests.**

```ruby
# StartRun
test "the first run of a baseline source is a baseline run and includes the seed requests, flagged"
test "a run after a finished run is not baseline, has no seed requests, and passes since"
test "a failed first run is followed by another baseline run with the seed requests" do
  # one failed run exists; StartRun -> run.baseline true, seed requests enqueued
end
test "a dated source's first run is not baseline"
test "counts start with requests and outstanding equal to the number of requests"
test "a source with nothing to request finishes at once"
# QueueRereads
test "a held placeholder older than 28 days is re-read whether or not the source has a signal"
test "a future-dated title is re-read only when its listing has no signal"
test "a title already on sale, or read within 28 days, is left alone"
# DailyJob
test "does nothing when no source is enabled" do   # no run created, no query for runs
test "starts a run for an enabled source with no finished run that started in the last seven calendar days"
test "does not start a run while one is running, or when a finished one started within the last seven calendar days"
test "a failed run yesterday does not stop today's run"
test "fails a run that has been running for more than 3 days"
test "ignores rows of a source that is no longer registered or enabled" do   # Review Focus 5
  # listings and a stale running run with source "removed_source": no error; the run is failed by rule 1 only if older than 3 days
end
# SweepJob
test "queues the oldest pending listings up to the batch size and stamps queued_at"
test "skips listings queued within the hour and unparseable ones attempted within a day"
test "skips a source whose gate is blocked or whose daily cap is spent"
test "the batch size follows the fetch interval" do   # interval 10 -> 60; interval 30 -> 20
```

- [ ] **Step 2: Run** the new tests. Expected: FAIL.
- [ ] **Step 3: Implement** the services, the jobs and the two schedule entries.
- [ ] **Step 4: Run** `bin/rails test test/lib/services/books/publisher_intake test/sidekiq/books/publisher_intake`, `bundle exec standardrb`, and `bin/rails runner 'YAML.load_file("config/schedule.yml").slice("publisher_intake_daily", "publisher_intake_sweep").each { |k, v| puts k, v["class"].constantize }'`. Expected: PASS; both classes print.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: daily runs, the sweep and re-reads"`.

---

### Task 8: Hachette Book Group (US)

**Files:**
- Create: `app/lib/books/publisher_intake/sources/hachette_us.rb`
- Modify: `app/lib/books/publisher_intake/sources.rb` (register `"hachette_us"`), `lib/tasks/books/publisher_intake.rake` (create it; the capture task below)
- Test: `test/lib/books/publisher_intake/sources/hachette_us_test.rb`
- Fixtures: `test/fixtures/files/publisher_intake/hachette_us/`

**Interfaces:**
- Consumes: Task 4.
- Produces: `Books::PublisherIntake::Sources::HachetteUs` (`key "hachette_us"`, `name "Hachette Book Group"`, `VERSION = 1`), and the rake task `books:publisher_intake:capture[source,url,name]`: fetches `url` through the configured fetcher (`Books::PublisherIntake.client.fetch`), removes `script` elements other than `application/ld+json`, `style`, `svg`, `noscript`, `iframe`, HTML comments and `img`/`source` `srcset` attributes, cuts every text node longer than 200 characters to its first sentence, and writes the gzipped result to `test/fixtures/files/publisher_intake/<source>/<name>.html.gz`. It refuses to run outside development.

**Behaviour** (spec, "Hachette Book Group (US)"):
- `discovery_requests(since:)`: one file request for `https://www.hachettebookgroup.com/wp-json/wp/v2/hbg-title?per_page=100&page=1&<filter>&_fields=id,date,modified,link,meta`, context `{"page" => 1, "filter" => <filter>}`. The filter is `modified_after=<since, ISO 8601>` when `since` is given and the API honours it (Step 1), else `after=<since or 14 months ago>`.
- `parse_discovery`: status 400 with a JSON body whose `code` is `rest_post_invalid_page_number` → `:ok` with no listings and no requests (the page after the last). Status from `status_outcome`. A body that is not a JSON array → `:unparseable`. Otherwise one `ListingRef(url: record["link"], external_key: <ISBN-13 at the end of the link>, signal: record["modified"])` for each record whose `meta.release_date` parses and is `in_window?`; and, when the page held 100 records, one follow-up request for the next page with the same filter.
- `listing_request`: a page request for the listing URL, `wait_for_selector: "h1"`.
- `parse_listing`: `status_outcome` first. A page whose `<title>` does not contain "Hachette Book Group" → `:blocked`. Facts from the JSON-LD node typed `Book` or `Product` (`name`, `isbn`, `bookFormat`, `datePublished`, `numberOfPages`, `author[]`, `brand.name` → `imprint_name`, `genre[]`, `description`, `image`) and from the page: every format with its ISBN, the series name, the subtitle if shown. `publisher_name` "Hachette Book Group". No usable title or ISBN → `:unparseable`. `sibling_keys`: the ISBNs of the other formats listed.

- [ ] **Step 1: Settle the filter.** With `curl -sI`, compare the `X-WP-Total` header for `...hbg-title?per_page=1&modified_after=<a week ago>` against `...?per_page=1` (all records). If the first is much smaller, `modified_after` is honoured: use it. Record both numbers in the report and in a comment above the constant that chooses the filter.
- [ ] **Step 2: Capture fixtures** with the capture task (start the fetcher: `docker compose up -d --wait fetcher` from `data-sources/`; stop it afterwards). At least: a novel with four formats (`/titles/andrea-stewart/the-legend-eternal/9780316564861/`), a title in a series, a children's board book, a box set or bundle, a non-book product if the catalog has one, a Spanish-language or other non-English title if it has one, and one backlist ebook. Save two API pages as hand-trimmed JSON (five records each: in window, out of window, empty `release_date`, an ebook, a board book) and the "page past the end" 400 body. Add a synthetic challenge page and a synthetic redesigned page (titled "… | Hachette Book Group", no JSON-LD), each with a comment saying it is synthetic.
- [ ] **Step 3: Write the failing tests.**

```ruby
test "discovery asks for the first page with the filter for a first run and for a later run"
test "a full page yields a next-page request; a short page ends discovery"
test "the page past the end is ok and empty, not an error"
test "only records on sale inside the window become listings" do   # travel_to a fixed date
test "a record with an empty or unparseable release date is skipped without raising" do   # Review Focus 2
test "each listing carries its ISBN and the record's modified time as its signal"
test "a 403 and a challenge page are blocked; a 500 is unavailable; a 404 is not found"
test "a page that is not JSON is unparseable"
test "the novel reads with title, authors, imprint, genres, pages, description and all four formats" do
  # exact values asserted against the fixture, each format's isbn13 and format
end
test "the series title carries its series name"
test "the box set, the non-book product and the non-English title read as facts the hold rules then hold" do
  # Hold.call(reading.facts) for each
end
test "siblings are the other formats' ISBNs, not the page's own"
test "a redesigned Hachette page is unparseable, not blocked"
```

- [ ] **Step 4: Run** the test. Expected: FAIL, uninitialized constant.
- [ ] **Step 5: Implement** the strategy and register it.
- [ ] **Step 6: Run** the test, `CI=1 bin/rails zeitwerk:check`, `bundle exec standardrb`. Expected: PASS. Confirm no fixture holds a long description: `for f in test/fixtures/files/publisher_intake/hachette_us/*.gz; do gunzip -c "$f" | wc -c; done` — each under 60,000 bytes.
- [ ] **Step 7: Commit** `git commit -m "Publisher intake: Hachette Book Group (US)"`.

---

### Task 9: Penguin Random House (US)

**Files:**
- Create: `app/lib/books/publisher_intake/sources/penguin_random_house_us.rb`
- Modify: `sources.rb` (register `"penguin_random_house_us"`)
- Test: `test/lib/books/publisher_intake/sources/penguin_random_house_us_test.rb`
- Fixtures: `test/fixtures/files/publisher_intake/penguin_random_house_us/`

**Interfaces:**
- Consumes: Task 4; the capture task from Task 8.
- Produces: `Sources::PenguinRandomHouseUs` (`key "penguin_random_house_us"`, `name "Penguin Random House"`, `VERSION = 1`).

**Behaviour** (spec, "Penguin Random House (US)"):
- `discovery_requests`: one file request for `https://www.penguinrandomhouse.com/sitemap.xml`, context `{"step" => "index"}`.
- `parse_discovery`, step `index`: follow-up file requests for each child matching `sitemap-works-(\d{4})\.xml` whose year is between this year and the year of today + `horizon_days`, context `{"step" => "works"}`. Step `works`: one `ListingRef(url: loc, external_key: <work id from /books/(\d+)/>, signal: lastmod.iso8601)` for each entry whose `lastmod` is `in_window?`. `SitemapReader::Unreadable` → `:unparseable`.
- `listing_request`: a page request, `wait_for_selector: "h1"`.
- `parse_listing`: `status_outcome`; a `<title>` without "PenguinRandomhouse.com" or "Penguin Random House" → `:blocked`. Facts from the JSON-LD `Book` node: `name`, `author`, `numberOfPages`, `inLanguage` → `language`, `image`, and one format per `workExample` entry (`isbn`, `bookFormat`, `datePublished`). From the page: the imprint, the genres, the subtitle and series if shown, the description (`og:description`). `source_key` is the work id; `publisher_name` "Penguin Random House". `sibling_keys` is empty (one listing per work).

- [ ] **Step 1: Capture fixtures:** a novel with four or five formats (`/books/743565/the-collateral-heart-by-jeffery-deaver/`), a manga or comics volume, a Spanish-language edition (e.g. `/books/855221/los-propios-dioses--the-gods-themselves-by-isaac-asimov/`), a children's picture book, a reissue of an old novel, and a work page whose `workExample` lists a single format. Save a hand-trimmed sitemap index (six children: two works years in range, one past year, three unrelated) and a works URL set of eight entries: three in window, one dated 1976, one dated 2079, one 31 days ago, one with no `lastmod`, one whose URL has no work id. Add synthetic challenge and redesigned pages.
- [ ] **Step 2: Write the failing tests.**

```ruby
test "discovery starts at the sitemap index"
test "the index yields only this year's and the horizon year's works files" do   # travel_to 2026-11-17 -> 2026 and 2027
test "only works whose date is inside the window become listings"
test "entries dated 1976 and 2079, with no date, or with no work id are skipped without raising" do   # Review Focus 2
test "the listing's key is the work id and its signal the lastmod"
test "an unreadable sitemap is unparseable"
test "the novel reads with every format from workExample, its imprint, genres, pages and language" do   # exact values
test "the earliest format date is what on-sale date will be" do
  # the hardcover and paperback dates differ in the fixture; assert both are in formats
end
test "the Spanish edition reads with its language and is held as non_english"
test "the manga volume and the picture book read as ready titles"
test "the title's source key is the work id"
test "a redesigned page is unparseable, a challenge page is blocked"
```

- [ ] **Step 3: Run** the test. Expected: FAIL.
- [ ] **Step 4: Implement** the strategy and register it.
- [ ] **Step 5: Run** the test, zeitwerk check, standardrb, and the fixture size check from Task 8. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "Publisher intake: Penguin Random House (US)"`.

---

### Task 10: Macmillan (US)

**Files:**
- Create: `app/lib/books/publisher_intake/sources/macmillan_us.rb`
- Modify: `sources.rb` (register `"macmillan_us"`)
- Test: `test/lib/books/publisher_intake/sources/macmillan_us_test.rb`
- Fixtures: `test/fixtures/files/publisher_intake/macmillan_us/`

**Interfaces:**
- Consumes: Task 4; the capture task.
- Produces: `Sources::MacmillanUs` (`key "macmillan_us"`, `name "Macmillan"`, `VERSION = 1`, `baseline_on_first_run?` true).

**Behaviour** (spec, "Macmillan (US)"):
- `discovery_requests`: one file request for `https://us.macmillan.com/sitemap_index.xml`, context `{"step" => "index"}`.
- `parse_discovery`, step `index`: a follow-up file request for each child matching `sitemaps/sitemap-products\.\d+\.xml\.gz`, context `{"step" => "products"}`. Step `products`: one `ListingRef(url: loc, external_key: <ISBN-13 from /books/(97[89]\d{10})/>, signal: nil)` per entry; entries without an ISBN in the URL are skipped. Step `collection` (seed): one ref per distinct `/books/<ISBN-13>/` link on the page, plus the next page when paging works (Step 1).
- `seed_requests`: page requests for the "Coming Soon" and "New Releases" collections, `https://us.macmillan.com/search?dFR[collections.list.name][0]=Coming%20Soon&searchType=products` and the same with `New%20Releases`, `wait_for_selector: "a[href*='/books/97']"`, context `{"step" => "collection", "page" => 1}`.
- `listing_request`: a page request, `wait_for_selector: "h1"`.
- `parse_listing`: `status_outcome`; a `<title>` without "Macmillan" → `:blocked`. Facts: `title` and `author` from the JSON-LD `Book` node; from the page text, page count, genre, on-sale date (`MM/DD/YYYY`), age range, imprint; one format per element carrying `data-format-isbn`, with its label; description; cover. `publisher_name` "Macmillan". `sibling_keys`: the other `data-format-isbn` values.

- [ ] **Step 1: Settle paging.** Through the local fetcher, fetch the "Coming Soon" collection and the same URL with `&page=2`. If the second page's book links differ from the first's, paging is by `page`: follow-ups continue while a page yields a link not seen on the previous one, to a limit of 20 pages. If they are the same, the seed is the first page of each collection only. Record what was found in the report and in a comment above `seed_requests`.
- [ ] **Step 2: Capture fixtures:** a young-adult novel with three formats (`/books/9781250369550/nightcurse/`), an adult literary novel, a picture book, a backlist ebook, a graphic novel, and a box set if the catalog has one; the first page of the "Coming Soon" collection, trimmed to five results. Save a hand-trimmed sitemap index (three product children, two contributor children, one page sitemap) and a gzipped product URL set of six entries, one without an ISBN. Add synthetic challenge and redesigned pages.
- [ ] **Step 3: Write the failing tests.**

```ruby
test "discovery starts at the sitemap index and follows only the product files"
test "every product entry with an ISBN in its url becomes a listing with no signal"
test "an entry without an ISBN is skipped"
test "the source baselines on its first run"
test "the seed asks for the Coming Soon and New Releases collections"
test "a collection page yields one listing per distinct book link" do   # five results, ten links -> five refs
test "collection paging follows what Step 1 found" do
  # by page: page 1 with new links -> a page 2 request; a page with nothing new -> none; never past page 20
  # first page only: no follow-up
end
test "the novel reads with title, author, imprint, genre, age range, pages, on-sale date and three formats" do   # exact values
test "the on-sale date parses from month/day/year" do   # "11/10/2026" -> Date.new(2026, 11, 10)
test "siblings are the other two formats' ISBNs"
test "a page with one format has no siblings"
test "a redesigned page is unparseable, a challenge page is blocked, a 404 is not found"
```

- [ ] **Step 4: Run** the test. Expected: FAIL.
- [ ] **Step 5: Implement** the strategy and register it.
- [ ] **Step 6: Run** the test, zeitwerk check, standardrb, the fixture size check. Expected: PASS.
- [ ] **Step 7: Commit** `git commit -m "Publisher intake: Macmillan (US)"`.

---

### Task 11: Operator tasks and re-parsing

**Files:**
- Create: `app/lib/services/books/publisher_intake/reparse.rb`, `rehearse.rb`, `status.rb`
- Modify: `lib/tasks/books/publisher_intake.rake`
- Test: `test/lib/services/books/publisher_intake/reparse_test.rb`, `rehearse_test.rb`, `status_test.rb`

**Interfaces:**
- Consumes: Tasks 3-7; `PageFetcher::Page` (`Data.define(:url, :final_url, :status, :title, :html, :selector_found, :elapsed_ms, :fetched_at)`).
- Produces:

```ruby
Services::Books::PublisherIntake::Reparse.call(listing:)
  # data: {changed: true | false}.  Re-reads the stored page with the current parser when
  # listing.parser_version is nil or below the strategy's parser_version; fetches nothing.
Services::Books::PublisherIntake::Rehearse.call(source:, limit:, max_discovery_requests: nil, out: $stdout)
  # data: {requests:, listings_seen:, read:, outcomes: {found: n, ...}, held: {reason: n}}
Services::Books::PublisherIntake::Status.call
  # data: {sources: [{key:, name:, enabled:, registered:, last_run:, listings: {state => n},
  #                   titles: {ready: n, held: {reason => n}}, fetches_today:, daily_cap:, blocked_until:}]}
```

- Rake tasks, all under `books:publisher_intake`: `run[source]` (`StartRun`, kind manual; refuses an unregistered key), `release_baseline[source,limit]` (moves up to `limit` `baseline` listings to `pending`, highest `external_key` first), `reparse[source]` (enqueue-free: calls `Reparse` for each listing of the source with a stored page and an older parser version, printing counts), `rehearse[source,limit,max_discovery_requests]`, `status`.

**`Reparse`:** returns unchanged when no page is attached or the version is current. Builds a `PageFetcher::Page` from the stored HTML (gunzipped, UTF-8) and the listing's `http_status` (200 if nil), calls `strategy.parse_listing`, and:
- `:found` → `StoreReading` semantics for a found reading, **without replacing the stored page** and without touching `last_attempt_*` or `read_at`; an `unparseable` listing becomes `read` with its title upserted and classified (spec §4, "promote").
- anything else → only `parser_version` is stamped, so the page is not re-read until the parser changes again.

**`Rehearse`** (development aid; synchronous, no Sidekiq, no gate): runs the source's discovery requests one after another (following follow-ups, stopping after `max_discovery_requests` when given), waiting `settings.fetch_interval` seconds between fetches, into a `manual` run; then reads up to `limit` pending listings the same way; prints one line per fetch (URL, outcome, elapsed) and a summary. It refuses to run in production. This is the one place a `sleep` is allowed.

**`Status`:** includes every registered source and every source key present in the tables (Review Focus 5), with `registered: false` for the latter.

- [ ] **Step 1: Write the failing tests.**

```ruby
# Reparse
test "an unparseable listing whose stored page now parses becomes read with a title"
test "a read listing's facts are refreshed and its stored page, read_at and last attempt are unchanged"
test "a page that still does not parse only gets the new parser version"
test "a current listing, and a listing with no stored page, are left alone"
test "nothing is fetched" do   # Books::PublisherIntake.expects(:client).never
# Rehearse
test "reads at most limit listings and reports outcomes and holds" do   # stub sleep and the client
test "stops discovery after max_discovery_requests"
test "refuses to run in production"
# Status
test "reports listings by state and titles by status and hold reason per source"
test "includes a source that has rows but is no longer registered" do   # Review Focus 5
test "reports today's fetch count, the cap and blocked_until from the source's gate"
```

- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement** the services and the rake tasks.
- [ ] **Step 4: Run** the tests, `bundle exec standardrb`, and `bin/rails books:publisher_intake:status`. Expected: PASS; the status prints three registered sources, none enabled.
- [ ] **Step 5: Commit** `git commit -m "Publisher intake: operator tasks, re-parse and rehearsal"`.

---

### Task 12: Admin screen

**Files:**
- Create (generator): `app/controllers/admin/books/publisher_intake_controller.rb` (`index`), `app/controllers/admin/books/publisher_titles_controller.rb` (`index`, `show`), their views and tests
- Create: `app/policies/books/publisher_title_policy.rb`, `e2e/tests/books/admin/publisher-intake.spec.ts`
- Modify: `config/routes.rb` (inside the books admin namespace), `app/lib/admin/domain_nav.rb` (books `items`)
- Test: `test/controllers/admin/books/publisher_intake_controller_test.rb`, `publisher_titles_controller_test.rb`

**Interfaces:**
- Consumes: Task 11 `Status`; Task 3 models.
- Produces routes `admin_books_publisher_intake_path` (`GET /admin/publisher_intake`), `admin_books_publisher_titles_path`, `admin_books_publisher_title_path(title)`; sidebar entry `{label: "Publisher Intake", icon: :list, path: -> { URL_HELPERS.admin_books_publisher_intake_path }}`.
- Both controllers inherit `Admin::Books::BaseController` and authorize with `Books::PublisherTitlePolicy` (modelled on `Books::RankingArchivePolicy`: `domain` returns `"books"`). Read-only: no create, update or destroy routes.
- Titles index: `pagy(scope, limit: 50)`; filters by query params `source`, `status`, `hold_reason` (each ignored when not a known value); default order `upcoming_first`. Links inside the table's Turbo Frame carry `data: {turbo_frame: "_top"}`.
- The description is shown on the title detail page only, inside the admin.

- [ ] **Step 1: Write the failing controller tests** (behaviour only: status codes, records present by `href`, no copy assertions):

```ruby
# publisher_intake#index
test "an admin sees the overview, with a row for every registered source and a link to its titles"
test "the overview renders when the tables are empty"
test "a source with rows but no registered strategy still appears" do   # Review Focus 5
test "a signed-out visitor and a regular user are redirected"
# publisher_titles
test "the list links to each title's detail page"
test "filters by source, status and hold reason narrow the list" do   # assert present and absent hrefs
test "an unknown filter value is ignored, not an error"
test "titles are paginated" do   # 51 titles -> a link to page 2
test "the detail page renders for a ready and for a held title, and 404s for an unknown id"
test "the index does not load listings per row" do   # assert_queries_count or a preload assertion, as other admin index tests do
test "there are no write routes" do   # assert_raises(ActionController::UrlGenerationError) for edit/destroy helpers, or routing assertions
```

- [ ] **Step 2: Run** the tests. Expected: FAIL, missing routes.
- [ ] **Step 3: Implement** routes, controllers, policy, views (daisyUI 5 classes only; see `docs/external-libraries/daisyui-llms.txt`), and the sidebar entry.
- [ ] **Step 4: Write the Playwright spec**, modelled on `e2e/tests/books/admin/ai-chats.spec.ts`: from `/admin`, click "Publisher Intake" in `getByTestId('admin-sidebar')`; expect the URL and the heading; follow the link to titles; if the table has a row, open it and expect the detail heading, otherwise expect the empty-state text.
- [ ] **Step 5: Run** `bin/rails test test/controllers/admin/books`, `bundle exec standardrb`. For the Playwright spec, confirm port 3000 belongs to this checkout (the command in `AGENTS.md`, "Running agents in parallel"); if another checkout holds it, do not run the spec and say so in the report. Otherwise `yarn build:all`, `bin/rails server`, and `yarn test:e2e e2e/tests/books/admin/publisher-intake.spec.ts`. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "Publisher intake: admin overview and titles"`.

---

### Task 13: Rehearsal and documentation

**Files:**
- Create: `docs/features/publisher-intake.md`
- Modify: `docs/launch-todo.md`, `deployment/ENV.md` (if Task 1 left anything out)

**Interfaces:**
- Consumes: everything.

- [ ] **Step 1: Rehearse each source in development.** Start the local fetcher (`docker compose up -d --wait fetcher` from `data-sources/`). For each of `hachette_us`, `penguin_random_house_us`, `macmillan_us`, run `bin/rails "books:publisher_intake:rehearse[<source>,10,3]"` (ten listings, at most three discovery requests). Then stop the fetcher. Keep the printed summaries.
- [ ] **Step 2: Judge the result.** Every source must have read at least eight of its ten listings as `found`, with a title, at least one contributor and at least one ISBN each. For anything else, look at the stored page (`listing.html.download`, gunzipped), fix the parser, bump its `VERSION`, add a fixture and a test for the case, and run `bin/rails "books:publisher_intake:reparse[<source>]"` to confirm the stored page now reads. If a source cannot be read at all (every fetch blocked or unavailable), stop and report it; do not change the service or its limits.
- [ ] **Step 3: Check the admin screen** against the rehearsed data: start the app, open `/admin/publisher_intake`, and confirm the three sources, their counts and a title's detail page render.
- [ ] **Step 4: Write `docs/features/publisher-intake.md`:** what it does and does not do; the tables; how a run, the sweep and re-reads work; outcomes and what blocked versus unparseable mean; how to add a source (the strategy interface, the capture task, the fixture rules, the registry line, a rehearsal); the settings and env vars; the rake tasks; the rehearsal's measurements per source (requests, listings seen, outcomes, holds, seconds per fetch, dated). No per-class documentation file.
- [ ] **Step 5: Add to `docs/launch-todo.md`** a section for switching intake on in production: confirm the production fetcher answers `POST /fetch_file`; set `PUBLISHER_INTAKE_SOURCES` to one source; watch its first run on the admin screen (Penguin Random House's is about 10,000 reads over roughly five days); add the next source.
- [ ] **Step 6: Run the full suites:** `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`. Expected: 0 failures, no offenses, no new warning lines. Confirm nothing touched the catalog: `git diff --stat main...HEAD -- web-app/app/models/books/book.rb web-app/app/models/books/edition.rb web-app/app/models/books/author.rb web-app/app/models/identifier.rb web-app/app/lib/data_importers` prints nothing.
- [ ] **Step 7: Commit** `git commit -m "Docs: publisher intake, with the rehearsal's measurements"`.
