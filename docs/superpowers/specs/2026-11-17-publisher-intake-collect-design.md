# Publisher intake: collect — design

Date: 2026-11-17

## Goal

Every week, read the largest publishers' own catalogs for titles we have not seen, and hold what
they say about each one (title, authors, every format with its ISBN, on-sale date, pages, imprint,
genres, series) in our database, with an admin screen showing what came in.

This design **collects**. It writes nothing to the catalog: no book, edition, author or identifier
is created or changed. Turning held titles into books is the next design ("create").

Success:

- With a publisher switched on, a run starts by itself once a week, finds that publisher's new
  and upcoming titles, reads each one's page through the page fetcher, and stores one
  `Books::PublisherTitle` per title with its facts.
- Adding a publisher is one strategy class, its parser fixtures, and one registry line. The
  first three publishers are built three different ways to prove it.
- An admin can see, per publisher: when it last ran, how many titles are held and why, and can
  browse upcoming titles by on-sale date.
- One publisher's site blocking us, or being redesigned, stops that publisher only. It never
  stops Goodreads fetching.

## Why

The catalog thins out for recent years. Books by `first_published_year` in the development
database (2026-11-11): 3,353 for 2019, 2,681 for 2023, 1,423 for 2024, 955 for 2025, 55 for 2026.
Books reach the catalog when a list names them, so a new book waits until a list does.

Research on 2026-11-11 found no free aggregate source of upcoming titles that we may store:
Open Library's importer rejects any record dated after the current year; Google Books' and
Amazon's API terms forbid building a database from their responses; the industry's own feeds
(ONIX from Bowker, Ingram, Nielsen) are quote-only. Publishers' own sites are the source, and
their pages carry facts we otherwise pay to derive: every format with its ISBN, page count,
on-sale date, imprint, genres, series, age range.

## The three designs

1. Page fetcher file fetch — shipped (`2026-11-16-page-fetcher-file-fetch-design.md`).
2. **Publisher intake**, in two parts:
   - **Collect** (this document).
   - **Create**: on-sale dates on books and editions, publisher and imprint records, editions
     written from publisher facts, books created through the importer, publisher facts used as
     source material for enrichment, and enrichment ordered by author rank under a daily budget.
3. A public "upcoming releases" page sorted by author rank.

Collect ships first on purpose: it shows real weekly volume and mix before a single book is
created.

## Decisions

Agreed with Shane:

- Go to publishers directly, one strategy per publisher, easy to add more.
- Every genre is in scope, including manga, comics and children's books. Only these stay held:
  untitled placeholders, box sets and bundles, products that are not books, non-English
  editions.
- Everything goes through the page fetcher (`/fetch` for pages, `/fetch_file` for JSON and
  sitemap files): one route, one egress address.
- An admin screen shows each publisher's intake.
- First build: the framework plus Hachette Book Group (US), Penguin Random House (US) and
  Macmillan (US). Simon & Schuster and HarperCollins follow, then UK houses and independents.
- The weekly job looks forward. Filling in already-published books from 2024 to 2026 is a later
  piece.

My calls, open to change at review:

- Splitting intake into collect and create.
- Two tables rather than one: a **listing** is a URL the publisher gave us; a **title** is what
  one or more listings turned out to describe (§1).
- Pacing per publisher, on one new single-thread Sidekiq capsule, with a circuit breaker of
  intake's own so its failures cannot touch Goodreads fetching (§3).
- The job is scheduled daily and starts a publisher's run when its last finished one is a week
  old, because sidekiq-cron does not catch up a missed run; a second job sweeps pending
  listings every 10 minutes (§3).
- Collecting titles up to 12 months ahead (§7).
- Re-reading: on a 28-day schedule only where the publisher gives no change signal, and for
  placeholders (§6).
- What counts as a set, erring toward letting a title through (§7).
- A rake task that releases held-back baseline listings for reading, as the hook the later
  backfill will use (§5).

## Sources in the first build

Measured 2026-11-11 to 2026-11-17 from the development machine. "Plain request" means `curl`;
everything in production goes through the fetcher regardless.

### Hachette Book Group (US) — an API

- **Discover:** the site's WordPress REST API,
  `https://www.hachettebookgroup.com/wp-json/wp/v2/hbg-title?per_page=100&page=N&after=<ISO time>`.
  Open, no key. One record per ISBN. Each has `date` (when the record was added), `link` (the
  product URL, ending in the ISBN-13), and `meta.release_date`, `meta.format` (an ONIX product
  form code: `BB` hardback, `BC` paperback, `ED` ebook, `AJ` audio download, `BH` board book),
  `meta.is_primary_isbn`. 57 records were added in one week, 4,608 in the month before, 66,965
  in all; about half of a 500-record sample were backlist ebooks dated 2009.
- **Which records become listings:** those with `meta.release_date` on or after today minus the
  lookback (§7).
- **Read:** the product page, e.g.
  `https://www.hachettebookgroup.com/titles/andrea-stewart/the-legend-eternal/9780316564861/`.
  It carries a JSON-LD node of type `["Product", "Book"]` with `name`, `isbn`, `bookFormat`,
  `datePublished`, `numberOfPages`, `author[]`, `brand.name` (the imprint), `genre[]`,
  `description`, `image`. The page text lists every format with its ISBN, and the series name.
- **Signal that a record changed:** the API's `modified` field.
- Not verified: `modified_after=` as a query filter (standard in WordPress 5.7 and later). If it
  works, discovery asks for records modified since the last run, which covers new and changed
  ones. If not, it asks for `after=` and relies on the re-read schedule for changes.

### Penguin Random House (US) — a dated sitemap

- **Discover:** `https://www.penguinrandomhouse.com/sitemap-works-<YYYY>.xml` for each year
  from the one the lookback window starts in (the previous year, during January) to the one the
  horizon ends in, as the index (`/sitemap.xml`) lists them; next year's file is requested even
  when the index does not list it. One `<url>` per work;
  `<lastmod>` is the work's front-list on-sale date, including future dates. The 2026 file is
  6,065,011 bytes with 24,713 works, about 17,200 of them dated in 2026; the 2027 file has
  7,507.
- **Which entries become listings:** those with `lastmod` on or after today minus the lookback.
- **Read:** the work page, e.g.
  `https://www.penguinrandomhouse.com/books/743565/the-collateral-heart-by-jeffery-deaver/`.
  JSON-LD `Book` with `name`, `author`, `numberOfPages`, `inLanguage`, `image`, and
  `workExample[]`, one per format, each with `isbn`, `bookFormat`, `datePublished`. The page
  text carries the imprint, "Related Genres", and dimensions.
- **Signal:** `lastmod`.
- The work id in the URL (`743565`) is the publisher's own stable key for the title.
- A random 30 of the 2,169 works dated November to December 2026: 13 manga or comics volumes
  (from publishers it distributes), 9 adult or young-adult trade books, 5 Spanish-language
  editions, 3 children's books.

### Macmillan (US) — list comparison

- **Discover:** `https://us.macmillan.com/sitemap_index.xml` lists 70 files
  `sitemaps/sitemap-products.N.xml.gz`, each with up to 1,000 URLs of the form
  `/books/<ISBN-13>/<slug>/`. Every entry carries the same `lastmod`, and the order is
  alphabetical by title, so the only way to find new titles is to compare the list with last
  week's. Plain requests get a challenge page; the fetcher gets through (a book page in 8 s, a
  sitemap file in 2 s).
- **Which entries become listings:** all of them. New ones are read; see §5 for the first run.
- **Read:** the book page, e.g. `https://us.macmillan.com/books/9781250369550/nightcurse/`. Its
  text carries page count, genre, on-sale date, age range, imprint and ISBN; each format is an
  element with a `data-format-isbn` attribute (three on that page: hardcover, ebook, audio). Its
  JSON-LD `Book` node has only `name`, `isbn`, `author`, `image`.
- **Signal:** none.
- **Seed (§5):** the site's "Coming Soon" and "New Releases" collections,
  `https://us.macmillan.com/search?dFR[collections.list.name][0]=Coming%20Soon&searchType=products`.
  "Coming Soon" shows 285 results, 22 to a page: a curated selection, not the full upcoming
  list. How its paging is driven was not established.

Later sources and what is known about them are in the appendix.

## 1. Data model

Three new tables, all namespaced `Books::`. Names are part of the design; the "create" design
and the admin screen refer to them.

### `Books::PublisherListing` (`books_publisher_listings`)

One URL a publisher's discovery source gave us.

| Column | Notes |
|---|---|
| `source` | string, not null. The strategy's key, e.g. `hachette_us`. |
| `url` | string, not null. Unique with `source`. |
| `external_key` | string. The ISBN-13 or the publisher's work id, when the URL carries one. |
| `state` | enum: `baseline`, `pending`, `read`, `covered`, `failed`. |
| `signal` | string. Whatever the source offers that changes when the record changes (`lastmod`, `modified`); null when it offers nothing. |
| `outcome` | enum, null until fetched: `found`, `not_found`, `blocked`, `unparseable`. The outcome of the stored page. |
| `http_status`, `parser_version` | as on `Books::GoodreadsPage`, for the stored page. |
| `last_attempt_outcome`, `last_attempt_at` | the most recent fetch attempt, whatever it came to; it can differ from `outcome` (§4). |
| `attempts` | integer, default 0. Consecutive `unavailable` attempts; reset by any other outcome. (Goodreads carries this in job arguments; here the sweep in §3 re-enqueues, so it lives on the row.) |
| `queued_at` | datetime. When a read job was last enqueued for it (§3). |
| `first_seen_at`, `last_seen_at`, `read_at` | datetimes. |
| `publisher_title_id` | the title this listing was read into, or is covered by. |

- `has_one_attached :html, service: :private_imports`: the page as fetched, gzipped. Same
  storage, same attach options and same never-served rule as `Books::GoodreadsPage`. Which
  attempts replace it is in §4.
- States: `baseline` = seen on a source's first run and deliberately not read (§5); `pending` =
  waiting to be read; `read` = read at least once; `covered` = another listing's page already
  described this format, so it is never fetched; `failed` = `not_found`, or still unavailable
  after the retry limit.

### `Books::PublisherTitle` (`books_publisher_titles`)

One title as one publisher describes it, with all its formats.

| Column | Notes |
|---|---|
| `source` | string, not null. |
| `source_key` | string. The publisher's own id for the title when it has one (the Penguin Random House work id); unique with `source` when present. |
| `isbn13s` | string array, GIN-indexed. Every ISBN-13 seen for this title. |
| `title`, `subtitle` | strings. |
| `contributors` | jsonb array of `{name, role}`; `role` is `author`, `illustrator`, `translator`, `editor`, `narrator` or `other`. |
| `on_sale_on` | date. The earliest on-sale date among the formats. |
| `formats` | jsonb array of `{isbn13, format, on_sale_on, pages, price_cents, currency}`. `format` is one of `hardcover`, `paperback`, `mass_market`, `ebook`, `audiobook`, `board_book`, `other`, plus `format_label`, the publisher's own wording. |
| `imprint_name`, `publisher_name` | strings, as the page gives them. |
| `language` | string, as the page gives it; null when it does not say. |
| `genres` | jsonb array of strings, in the publisher's wording. |
| `series_name`, `series_position`, `age_range` | strings. |
| `description` | text. Source material for our own summaries later. Never shown publicly. |
| `cover_url` | string. |
| `status` | enum: `ready`, `held`. |
| `hold_reason` | enum, null unless held: `incomplete`, `placeholder`, `non_english`, `not_a_book`, `set`. |
| `first_read_at`, `last_read_at`, `parser_version` | |

- **Finding the title for a page that was just read:** by `source_key` when the strategy gives
  one; otherwise the title of the same `source` whose `isbn13s` overlaps the page's ISBNs. None
  found means a new title. This is what makes three Macmillan listings (hardcover, ebook,
  audio) one title.
- If the page's ISBNs overlap two titles of the same source, take the one sharing the most
  ISBNs (the older on a tie) and log a warning naming both. Titles are never merged here.
- A re-read replaces the facts and unions `isbn13s`.

### `Books::PublisherIntakeRun` (`books_publisher_intake_runs`)

One discovery pass for one source: `source`, `kind` (`weekly`, `manual`), `status`
(`running`, `finished`, `failed`), `baseline` (whether this run stores new URLs as `baseline`,
§5), `started_at`, `finished_at`, `error`, and `counts` (jsonb: discovery requests made and
still outstanding, listings seen, listings new, listings changed). Seeding happens inside a
source's first runs (§5), so there is no separate kind for it. Reading progress is not stored on
the run; the admin screen derives it from listings and titles.

## 2. Strategy interface

One class per publisher under `Books::PublisherIntake::Sources`, registered by key in one
registry. A strategy never fetches, stores or enqueues; it says what to fetch and reads what
came back. The framework owns fetching, pacing, storage and state.

```ruby
# What to fetch. kind :file goes through PageFetcher::Client#fetch_file, :page through #fetch.
Request = Data.define(:kind, :url, :page_url, :wait_for_selector, :context)

# One URL found during discovery.
ListingRef = Data.define(:url, :external_key, :signal)

class Sources::Base
  def key = raise NotImplementedError            # "hachette_us"
  def name = raise NotImplementedError           # "Hachette Book Group"
  def baseline_on_first_run? = false             # true for list-comparison sources
  def discovery_requests(since:) = raise NotImplementedError   # => [Request]
  def seed_requests = []                         # => [Request], first run only
  # => Discovery(outcome:, listings: [ListingRef], requests: [Request])
  def parse_discovery(request:, response:) = raise NotImplementedError
  def listing_request(listing) = raise NotImplementedError     # => Request
  # => Reading(outcome:, facts:, sibling_keys:)
  def parse_listing(listing:, page:) = raise NotImplementedError
end
```

- `since` is the start time of the source's last finished run, or nil.
- `Request#context` is a small JSON-serializable hash the strategy gets back in
  `parse_discovery`, so it can tell a sitemap index from a child file or carry a page number.
- `parse_discovery` may return more requests: the children of a sitemap index, the next API
  page. Discovery ends when no request is outstanding.
- `Reading#facts` is a plain hash with the `Books::PublisherTitle` columns as keys.
  `sibling_keys` are the ISBNs of other formats the page listed; listings of the same source
  with those `external_key`s that are not yet read become `covered`.
- `outcome` uses the Goodreads vocabulary and rules (§4).

Shared helpers, so a new strategy is mostly selectors: a sitemap reader (index or URL set,
gzipped or not), a JSON-LD reader that finds `Book` and `Product` nodes, a WordPress REST pager,
and the hold classifier (§7). The WordPress family in the appendix should need little beyond a
post-type name and a page parser.

## 3. Runs, jobs and pacing

- **Starting runs.** One job is scheduled daily in `config/schedule.yml`. For each enabled
  source it starts a `weekly` run when the source has no `running` run and no
  finished run that started within the last seven calendar days. A failed run does not count, so a failure
  is retried the next day, not the next week. The job returns at once when no source is
  enabled.
- **Discovery.** One Sidekiq job per discovery request. It takes its turn at the gate, fetches,
  hands the response to `parse_discovery`, upserts the listings, and enqueues a job for each
  further request. When none is outstanding the run is `finished`. What ends or delays a run:

  | A discovery request… | Result |
  |---|---|
  | is told to wait by the gate | reschedules itself for its turn, as a read does |
  | is refused by the gate (daily cap spent, or the source is blocked) | reschedules itself for when the gate reopens: the next UTC day, or `blocked_until`. The run stays `running`. |
  | comes back blocked | the gate is blocked; the request reschedules itself for `blocked_until` |
  | is unavailable | retried up to `fetch_attempts`, then the run is `failed` |
  | cannot be parsed | the run is `failed` at once: the source's format changed and a person has to look |

  A failed run keeps the listings it already upserted, and the next run uses the same `since`.
  The daily job also fails any run that has been `running` for more than 3 days, so a run whose
  jobs were lost cannot hold its source forever.
- **Sweeping pending listings.** A second scheduled job runs every 10 minutes. For each enabled
  source whose gate is neither blocked nor at its daily cap, it enqueues a read job for the
  oldest pending listings that have no job queued (`queued_at` null or more than an hour old),
  up to as many as the fetch interval allows in 10 minutes, and stamps `queued_at`. This sweep
  is the only thing that enqueues reads, so a listing left `pending` for any reason (blocked,
  unparseable, refused, fetcher down) is picked up again without waiting for the next run.
- **What discovery does with a `ListingRef`:**

  | The URL is… | Result |
  |---|---|
  | new, and this is a baseline run (§5) | created as `baseline` |
  | new otherwise | created as `pending` |
  | known, `read`, and its `signal` differs from the stored one | `pending` again, signal updated |
  | known otherwise | `last_seen_at` updated |

- **Reading.** One job per pending listing: turn at the gate, fetch, `parse_listing`, store (§4).
  A read job the gate refuses simply ends; the listing is still `pending` and the sweep will
  queue it again once the gate reopens.
- **Pacing.** Copy the Goodreads design, which is what makes waiting safe: a job never sleeps;
  it asks the gate for a turn and, when told to wait, reschedules itself for that moment with a
  flag saying its turn is already reserved.
  - One gate **per source**, so a block on one publisher leaves the others running. Each has a
    fetch interval (default 10 s), a daily cap counted per UTC day (default 2,000) and a block
    cooldown (6 hours).
  - All intake jobs run on one new Sidekiq capsule, `publisher_fetch`, with concurrency 1. The
    gate's read-then-write is only correct with a single thread, as for Goodreads.
  - `Books::Goodreads::FetchGate` hardcodes its Redis key and config. The gate logic must be
    shared, not copied: give it a key, a config and a log label, and leave the Goodreads gate's
    key, limits and behaviour exactly as they are. `Books::Goodreads::FetchGate.new` with no
    arguments has several callers and must keep working unchanged.
    `Books::Goodreads::GateTurn` is already generic.
- **Sharing the fetcher.** The fetcher runs two browsers at once. Goodreads fetching holds at
  most one and intake at most one, so neither waits on the other for a slot.
- **Its own circuit breaker.** `PageFetcher::Client` has one breaker, keyed `page_fetcher`, for
  every caller, and a slow or odd page counts against it: `navigation_timeout` and
  `browser_error` both do. Goodreads does not wait out an open breaker; its job gives up and the
  import creates the book unverified. So intake must not share it. Intake builds its client with
  its own breaker (the client already takes one), keyed separately, with the same threshold and
  cooldown. An intake-caused trip then pauses intake only.

## 4. Reading a listing

Outcomes and what is stored, following `Services::Books::GoodreadsPages::FetchPage`:

| Outcome | Meaning | Stored | Then |
|---|---|---|---|
| `found` | The parser got a usable title | page, facts, title upserted | listing `read` |
| `not_found` | The site says the page does not exist | outcome | listing `failed` |
| `blocked` | Not the site's own page: 401, 403, 429, or a 200 that is a challenge page | page, outcome | gate blocked for the cooldown; listing stays `pending` |
| `unparseable` | The site's own page, but the parser cannot read it | page, outcome | listing stays `pending`; the sweep retries it no sooner than a day later; **no block** |
| `unavailable` | 5xx, timeout, network failure, upstream error | nothing | `attempts` + 1; stays `pending` until `fetch_attempts`, then `failed` |
| `fetcher_down` | Breaker open, bad configuration, or a 4xx from the fetcher service | nothing | the listing stays `pending` |

Every attempt writes `last_attempt_outcome` and `last_attempt_at`.

- "Usable" means a title and at least one ISBN-13. A page with no contributor is still `found`;
  the classifier holds it as `incomplete`.
- **A good page is never replaced by a bad one.** The table above is for a listing whose page
  has never been found. A listing is known to have been read by its `read_at`, which only a
  `found` reading sets; its state cannot say so, because a listing being fetched again (§6) is
  `pending` by then. When such a listing's attempt is `blocked`, `unparseable` or `unavailable`,
  its stored page, `outcome`, facts and title are left as they were and it returns to `read`;
  only the `last_attempt_*` columns change (and the gate is still blocked on `blocked`). This is
  the Goodreads rule that a conclusive page is not overwritten. A `fetcher_down` attempt never
  reached the site, so it changes nothing but `last_attempt_*`: the listing stays `pending` and
  the sweep tries it again.
- A re-read that comes back `not_found` sets the listing to `failed` with that outcome and
  leaves the title untouched. Acting on a withdrawn title is a non-goal here.
- Blocked versus unparseable is the distinction that matters. Each strategy states how to
  recognise its site's own page (a marker in `<title>`, as the Goodreads parser does). A
  redesign must show up as unparseable rows in the admin screen, never as a six-hour freeze.
- Each parser has a `VERSION`. It is stamped on the listing and the title. A stored page read
  by an older version can be re-parsed without fetching (§8). Unlike the Goodreads re-parse,
  which only refreshes columns on pages that already parsed, this one must also **promote**: an
  `unparseable` listing whose stored page the new parser can read becomes `read`, with its
  title upserted and classified. That is what makes a redesign cheap to recover from.
- The page HTML never reaches a log line or an exception.

## 5. The first run

"First run" below means **every run of a source until one finishes**. A first run that fails
partway is followed by another baseline run, not by a normal one; otherwise the URLs the failed
run never reached would all arrive as `pending`, which is tens of thousands of backlist reads.

- **Dated sources** (Hachette, Penguin Random House) need nothing special: their first run
  emits everything on sale between the lookback date and the horizon (§7). For Penguin Random
  House that is on the order of 10,000 works (about 2,200 for the rest of 2026 and 7,500 in the
  2027 file), roughly five days of reading at the default cap.
- **List-comparison sources** (`baseline_on_first_run?`) cannot tell an upcoming book from a
  1990s ebook on the first pass. Until one of their runs has finished, discovery stores every
  new URL as `baseline` and reads none of them. After that, a URL not seen before is `pending`.
- **Seed.** Until one of its runs has finished, a source's runs also fetch its `seed_requests`,
  and every listing URL they yield is `pending` even if it is also in the baseline. For
  Macmillan this is the "Coming Soon" and "New Releases" collections.
- **The gap this leaves.** A Macmillan title announced before our first run and not in those
  two collections stays `baseline` and is not read. The later backfill closes it.
- **The backfill hook.** A rake task moves up to N `baseline` listings of a source to
  `pending`, highest ISBN first. Nothing calls it automatically.

## 6. Re-reading

Publishers move dates, replace "Untitled" with a real title, and add formats. A `read` listing
returns to `pending` when:

- discovery sees a different `signal` for it (§3), or
- it was last read more than `reread_after_days` (28) ago and either
  - its title is `held` as `placeholder` or `incomplete` (a signal does not change when a
    publisher fills in a title), or
  - its source offers no signal and its title's `on_sale_on` is in the future or missing.

  The daily job does this, before starting runs.

So a source with a signal (Hachette, Penguin Random House) is re-read on a schedule only for
placeholders; everything else there is re-read when the publisher changes it. Titles whose
on-sale date has passed are not re-read. Section 4 says what a failed re-read leaves alone.

## 7. Holding

After each read, shared code sets `status` and `hold_reason`. First match wins:

1. `incomplete`: no title, no contributor, or no ISBN-13.
2. `placeholder`: the title or the only contributor is a stand-in ("Untitled…", "To Be
   Confirmed", "TBD", "Title to be announced").
3. `non_english`: the page states a language and it is not English.
4. `not_a_book`: every format is a non-book product (calendar, journal or notebook, card deck,
   puzzle, stationery, toy, kit), by the publisher's format label.
5. `set`: a box set or bundle. It is a set when any of these holds:
   - a format label names a box set, boxed set or bundle;
   - the title or subtitle (never the series name) matches
     `Services::Books::Verification::EditionCheck::SET_WORDS`, **not counting** a match that is
     only one of the series-name words in `Services::Books::AmazonBookCheck::SERIES_NAME_WORDS`
     (`trilogy`, `collection`, `volumes`, `complete series`), and not counting a match that is
     a number, a space and "book" or "books" ("1001 Books…"), since a title that counts books is
     a book; the hyphenated form ("3-Book") still counts;
   - the title matches `Services::Books::AmazonBookCheck::NUMBER_RANGE` ("#1-3").

   So "Box Set", "Omnibus", "3-Book", "Books 1-3" hold; "A Collection of Essays", "The Tolstoy
   Trilogy" and "1001 Books You Must Read Before You Die" do not. Those constants are the
   vocabulary; do not write a second list.
   A held title is skipped by "create", so a false hold loses a real book, while a false pass
   only lets a three-in-one volume through as a book.

Everything else is `ready`. Nothing is filtered by genre, imprint or audience. A reissue of a
book we already hold is `ready` too: telling a new book from a new edition is the "create"
design's job, through the import finder.

Two settings bound what a dated source emits. The lookback (`lookback_days`, 30) is how far
behind today, so a title that came out last week is still collected. The horizon
(`horizon_days`, 365) is how far ahead; a title further out is picked up by a later run once
it is inside the horizon. List-comparison sources have no dates to apply either to.

## 8. Configuration and operation

`config.x.publisher_intake`, read at boot the way `config/initializers/goodreads.rb` does (a
bad value logs and falls back; it never stops boot):

| Setting | Env | Default |
|---|---|---|
| enabled sources | `PUBLISHER_INTAKE_SOURCES` (comma-separated keys) | none: the feature is off |
| fetch interval, seconds | `PUBLISHER_INTAKE_FETCH_INTERVAL` | 10 |
| daily fetch cap, per source | `PUBLISHER_INTAKE_DAILY_FETCH_CAP` | 2000 |
| block cooldown | — | 6 hours |
| fetch attempts | — | 3 |
| run every, days | — | 7 |
| re-read after, days | — | 28 |
| lookback, days | — | 30 |
| horizon, days | — | 365 |

An unknown key in `PUBLISHER_INTAKE_SOURCES` is logged and ignored.

Rake tasks under `books:publisher_intake`: start a run for one source now, optionally reading
at most N listings (for a rehearsal); release baseline listings (§5); re-parse stored pages
older than the current parser version, promoting unparseable ones that now read (§4); print a
status summary.

Production needs the env var, and one check first: that the fetcher on the home server is
running an image with `/fetch_file` (it merged on 2026-11-18). The `private_imports` storage
and Redis are already there. Both the check and switching sources on, one at a time, are steps
for `docs/launch-todo.md`.

## 9. Admin screen

Books admin, read-only, one sidebar entry ("Publisher intake"):

- **Overview:** one row per registered source: enabled or not, last run and its status,
  listings by state, titles ready and held (by reason), today's fetch count against the cap,
  and "blocked until" when the gate is blocked.
- **Titles:** a paginated list, filterable by source, status and hold reason; default order is
  upcoming first by on-sale date. Columns: title, contributors, imprint, on-sale date, formats.
- **Title detail:** every stored fact, each format with its ISBN, the listings behind it with
  their outcome and last read time, and a link to the publisher's page.

It follows the existing books admin pattern (`Admin::Books::BaseController`, a policy, Pagy, an
entry in `Admin::DomainNav`) and gets a controller test and a Playwright spec under
`web-app/e2e/tests/books/admin/` that also passes when the tables are empty.

## 10. Testing

- **Parsers:** one test per strategy against fixture pages under
  `web-app/test/fixtures/files/publisher_intake/<source>/`. Fixtures are real pages trimmed to
  what the parser reads (scripts other than JSON-LD, styles and images out), gzipped, with the
  long copy (descriptions, reviews, author biographies) cut to a sentence. States we cannot
  capture (a challenge page, a redesigned page) are tiny synthetic files that say so in a
  comment, as the Goodreads fixtures do.
- **Each strategy's corpus needs its negative cases**, not only happy pages: a box set, a
  non-book product, an untitled placeholder, a non-English edition, a title with one format and
  one with four, and a page with no contributor.
- **Discovery:** small synthetic sitemap and JSON fixtures: an index with children, a gzipped
  URL set, an API page and its empty last page.
- **Framework:** state transitions from §3 and §4, title matching by `source_key` and by ISBN
  overlap, covered siblings, the baseline run, re-read selection, the hold order. The fetcher
  client is stubbed; nothing in the suite makes a network request.
- **Jobs:** rescheduling instead of sleeping, as `Books::Goodreads::FetchPageJob`'s test does.
- **Rehearsal:** before the feature doc is finished, each source is run once in development
  with a small limit, through the real fetcher, and the result is recorded in the doc: requests
  made, titles read, outcomes, anything unparseable.

## Documentation

`docs/features/publisher-intake.md` (what it does, how to add a source, the settings, the rake
tasks, the rehearsal's measurements); `deployment/ENV.md` (the three env vars and the new
capsule's thread); the capsule itself goes in `config/initializers/sidekiq.rb`, and the comment
listing the capsules in `config/sidekiq.yml` is updated; `docs/launch-todo.md` (the fetcher
check, then switching sources on one at a time).

## Non-goals

- Creating or changing any book, edition, author, identifier, category or description.
- A public page of any kind.
- On-sale date columns on books or editions, and publisher or imprint records ("create").
- Simon & Schuster, HarperCollins, UK houses and independents (later, one strategy each).
- Backfilling published titles.
- Detecting that a publisher withdrew a title. `last_seen_at` records when it was last listed;
  nothing acts on it yet.
- Matching the same book across two publishers' lists.
- Downloading cover images.

## Anti-goals

- Goodreads fetching slowed, frozen or degraded by intake: no change to its gate, key, limits
  or queue, and no shared circuit breaker.
- A publisher's description or page HTML shown on the site, logged, or stored anywhere public.
- A redesigned site reading as a block.
- A second copy of the gate logic or of the set-word list.

## Risks

- **Sites change.** Parsers will break. The design's answer is that breakage is visible
  (unparseable counts in the admin screen), cheap to fix (stored pages re-parse without
  refetching) and contained to one source.
- **Unverified details,** each to be settled by the builder's first rehearsal: Hachette's
  `modified_after` filter; how Macmillan's collection pages paginate; whether every Penguin
  Random House work page lists all formats in `workExample`.
- **The Penguin Random House sitemap is 6 MB against the fetcher's 10 MB file cap.** A year
  file that outgrows it fails as `file_too_large`; the remedy is the fetcher's
  `FETCHER_MAX_FILE_BYTES`.
- **Volume.** After the first runs, three sources mean a few thousand fetches a week through a
  service with two browsers. The daily cap bounds it. The first Penguin Random House run is
  about 10,000 reads, roughly five days at the default cap.
- **Macmillan's first weeks miss titles** announced before the first run (§5).
- **Storage.** A gzipped page is tens of kilobytes; tens of thousands of listings a year is a
  few gigabytes in the private bucket, with one page kept per listing.

## Left to the builder

- Class and file names beyond the three models and the strategy interface.
- Selectors, and how each parser combines JSON-LD with page text.
- Index details, and whether `counts` needs more keys.
- The admin screen's layout.
- Whether the env helpers are shared with `GoodreadsEnv` or given a neutral home.

## Appendix: later sources

What the research and the 2026-11-16 checks found, so each is one strategy away.

| Publisher | Discover | Read | Notes |
|---|---|---|---|
| Simon & Schuster (US) | `sitemaps/us/sitemapN.xml.gz`, 25,000 URLs each, `/books/<Title>/<Author>/<ISBN-13>`; dates bulk-stamped, so list comparison | Book page, JSON-LD `Book` with `isbn`, `bookFormat`, `numberOfPages`, `datePublished`, `publisherImprint`, `alternativeHeadline` | Sitemap files load with a plain request; book pages need the browser. Many "Untitled" placeholders. |
| HarperCollins (US) | Shopify: 73 files `sitemap_products_N.xml`, 1,000 products each, dates bulk-stamped; each entry includes a cover image URL containing the ISBN | Product page: ISBN, imprint, on-sale date, pages, trim size, three BISAC subjects; `/products/<handle>.js` returns JSON | Behind a challenge; the browser clears it. Product URLs have no ISBN. |
| Pan Macmillan (UK) | `sitemaps/products-N.xml`: ISBN in the URL, `lastmod` is the publication date, newest first, out to 2030 | JSON-LD `Book` with `isbn`, `datePublished`, `bookFormat`, `genre[]`, `inLanguage` | Dated source. |
| Penguin (UK) | `sitemap/books-N.xml`: ISBN in the URL, no dates | Page embeds its data (`__NEXT_DATA__`) with series, age range, genres, editions | List comparison. |
| Hachette (UK) | Same WordPress API as Hachette US, on `hachette.co.uk` | Same shape | Should reuse the US strategy. |
| Grove Atlantic, Canongate, Oneworld, Counterpoint | WordPress book post type: `/feed/?post_type=<type>` or the post-type sitemap with `lastmod` | Page text: per-format ISBN and date block; no Book JSON-LD on Grove | One discovery helper, one parser per theme. |
| W. W. Norton, Europa Editions | Sitemap with the ISBN in the URL and `lastmod` | Norton US pages need the browser | |
| New Directions, Graywolf | One listing page | Page text | |
