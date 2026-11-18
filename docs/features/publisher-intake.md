# Publisher intake

Every week, read the largest publishers' own catalogs for titles we have not seen, and hold what
each publisher says about every one of them (title, contributors, every format with its ISBN,
on-sale date, pages, imprint, genres, series) in the database, with a read-only admin screen showing
what came in. Design: `docs/superpowers/specs/2026-11-17-publisher-intake-collect-design.md`. Pages
are fetched through the page fetcher (`docs/features/page-fetcher-service.md`).

## What it does and does not do

It **collects**. It reads publisher pages and stores facts in three tables of its own. It writes
nothing to the catalog: no book, edition, author, identifier, category or description is created or
changed. Turning stored titles into books is a later design ("create"). There is no public page, and
a publisher's page HTML is never shown on the site or written to a log, and a description is never
shown publicly (the admin detail page does show it).

Every genre is in scope, manga, comics and children's books included. Four kinds of title are
stored but held back (`status: held`): untitled placeholders, box sets and bundles, products that
are not books, and non-English editions. Everything else is `ready`. Nothing is filtered by genre,
imprint or audience.

The feature is off until `PUBLISHER_INTAKE_SOURCES` names a source.

Sources built so far, each a different way of discovering titles:

| Key | Publisher | Discovery | Reads |
|---|---|---|---|
| `hachette_us` | Hachette Book Group (US) | the site's WordPress REST API, one record per ISBN, filtered to records modified since the last run | the product page's JSON-LD and format list |
| `penguin_random_house_us` | Penguin Random House (US) | dated sitemaps, one per year, each entry's `lastmod` being the work's on-sale date | the work page's JSON-LD and page text |
| `macmillan_us` | Macmillan (US) | a sitemap index of undated product files, so new titles are found by comparing with what is already known | the book page's visible markup |

## The tables

All three are namespaced `Books::`.

- **`Books::PublisherListing`** (`books_publisher_listings`): one URL a source's discovery gave us.
  Unique on `source` and `url`. `state` is `baseline` (seen on a first run and deliberately not
  read), `pending` (waiting to be read), `read`, `covered` (another listing's page already
  described this format, so it is never fetched) or `failed`. `outcome` is the outcome of the
  stored page; `last_attempt_outcome` and `last_attempt_at` describe the latest attempt, whatever
  it came to. `attempts` counts consecutive unavailable attempts. `signal` is whatever the source
  offers that changes when the record changes (`lastmod`, `modified`). The page as fetched is
  attached gzipped as `html` on the private imports storage service, with the same never-served
  rule as `Books::GoodreadsPage`.
- **`Books::PublisherTitle`** (`books_publisher_titles`): one title as one publisher describes it,
  with all its formats. `contributors` and `formats` are JSON arrays; `isbn13s` is an indexed array
  of every ISBN-13 seen for the title; `on_sale_on` is the earliest format date and each format
  keeps its own. `status` is `ready` or `held`, and `hold_reason` is one of `incomplete`,
  `placeholder`, `non_english`, `not_a_book`, `set`.
- **`Books::PublisherIntakeRun`** (`books_publisher_intake_runs`): one discovery pass for one
  source, with `kind` (`weekly` or `manual`), `status` (`running`, `finished`, `failed`),
  `baseline`, and `counts` (discovery requests made and outstanding, listings seen).

A page that was just read finds its title by the publisher's own key when the source has one (the
Penguin Random House work id), otherwise by an overlap between the page's ISBNs and a title of the
same source. Hachette and Macmillan have no id for the work, so their titles match by shared ISBN:
that is what makes three Macmillan listings (hardcover, ebook, audio) one title, and a format page
read on its own a week later lands on the title that already holds its ISBNs. Titles
are never merged: when a page overlaps two titles, the one sharing the most ISBNs (the older on a
tie) is used and a warning names both. A re-read replaces the facts and unions the ISBNs.

## How a run works

- **Starting runs.** `Books::PublisherIntake::DailyJob` runs daily. For each enabled source it
  starts a `weekly` run when the source has no `running` run and no finished run that started
  within the last seven calendar days. The comparison is by calendar day on the run's start, so runs
  come every seven days however long a run took. A failed run does not count, so a failure is
  retried the next day. A manual run (`run[source]`) is refused while the source has a `running`
  run. A run still `running` after three days is failed, on a day when at least one source is
  enabled, so a run whose jobs were lost cannot hold its source.
- **Discovery.** One Sidekiq job per discovery request (`DiscoveryRequestJob`). It takes its turn at
  the source's gate, fetches, hands the response to the strategy's `parse_discovery`, records the
  listings, and enqueues a job for each further request (the children of a sitemap index, the next
  API page). When none is outstanding the run is `finished`. A gate that asks it to wait, or is
  closed (daily cap spent, source blocked), reschedules it; an unavailable fetch is retried up to
  `fetch_attempts` times, a minute apart, and then fails the run; a response the strategy cannot parse fails the run at
  once, because the source's format changed and a person has to look. A failed run keeps the
  listings it recorded, and the next run uses the same `since`.
- **What discovery does with a listing.** A new URL on a baseline run is stored as `baseline`. A new
  URL otherwise is `pending`. A known `read` listing whose `signal` changed goes back to `pending`.
  Anything else only has `last_seen_at` updated.
- **The sweep.** `SweepJob` runs every ten minutes. For each enabled source whose gate is open it
  enqueues read jobs for the oldest `pending` listings that have no job queued, as many as the
  fetch interval allows in ten minutes, and stamps `queued_at`. It is the only thing that enqueues
  reads, so a listing left pending for any reason (blocked, unparseable, refused, fetcher down) is
  picked up again. A listing whose last attempt was unparseable waits a day.
- **Reading.** `ReadListingJob` takes its turn at the gate, fetches, calls `parse_listing`, and
  stores the result. A job the gate refuses ends; the sweep queues the listing again later. A
  listing that was never read and fails `fetch_attempts` unavailable attempts in a row is `failed`;
  the daily job returns it to `pending` once that attempt is more than seven days old, so a short
  publisher outage does not lose the listings tried during it. A `not_found` listing is never
  revived.
- **Pacing.** A job never sleeps. It asks the gate for a turn and, when told to wait, reschedules
  itself for that moment with a flag saying its turn is reserved. There is one gate per source, so
  a block on one publisher leaves the others running, built on the same gate logic as Goodreads
  fetching, with its own Redis key and limits. The two fetch jobs
  (`DiscoveryRequestJob` and `ReadListingJob`) run on one Sidekiq capsule, `publisher_fetch`, with
  concurrency 1, because the gate's read-then-write is only correct with a single thread;
  `DailyJob` and `SweepJob` run on the `low` queue. Intake builds its page fetcher client with its own circuit breaker, so an intake
  failure cannot pause Goodreads fetching.
- **The first run.** "First run" means every run of a source until one finishes, so a first run
  that fails partway is followed by another baseline run, not a normal one. Dated sources
  (Hachette, Penguin Random House) need nothing special: their first run emits everything on sale
  between the lookback date and the horizon. For Penguin Random House that is on the order of
  10,000 reads, roughly five days at the default cap. A list-comparison source (Macmillan) cannot
  tell an upcoming book from an old ebook on the first pass, so until one of its runs has finished,
  discovery stores every new URL as `baseline` and reads none of them, except the listings from the
  source's seed requests, which are `pending`. For Macmillan the seeds are its "Coming Soon" and
  "New Releases" collection pages.
- **Releasing baseline listings.** `books:publisher_intake:release_baseline` moves up to N baseline
  listings of a source to `pending`, highest key first. Nothing calls it automatically.

## Re-reading

A `read` listing returns to `pending` when discovery sees a different `signal` for it, or when it
was last read more than 28 days ago and either its title is held as `placeholder` or `incomplete`
(a signal does not change when a publisher fills in a title), or its source offers no signal and its
title's on-sale date is in the future or missing. The daily job does this before starting runs.
Held `placeholder` and `incomplete` titles are re-read whatever their on-sale date; other titles
whose on-sale date has passed are not re-read. A failed re-read of a listing that was read before
(blocked, unparseable, unavailable) returns it to `read` with its facts as they were: that re-read
is dropped until it is next due, not retried.

## Outcomes

| Outcome | Meaning | Stored | Then |
|---|---|---|---|
| `found` | The parser got a title and at least one ISBN-13 | page, facts, title | listing `read` |
| `not_found` | The site says the page does not exist | outcome | listing `failed` |
| `blocked` | Not the site's own page: 401, 403, 429, or a 200 that is a challenge page | page, outcome | the source's gate is blocked for six hours; listing stays `pending` |
| `unparseable` | The site's own page, but the parser cannot read it | page, outcome | stays `pending`, retried no sooner than a day later; no block |
| `unavailable` | 5xx, timeout, network failure, upstream error | nothing | `attempts` + 1; `pending` until `fetch_attempts`, then `failed` |
| `fetcher_down` | Breaker open, bad configuration, or a 4xx from the fetcher service | nothing | stays `pending` |

Every attempt writes `last_attempt_outcome` and `last_attempt_at`.

**Blocked versus unparseable is the distinction that matters.** Each strategy states how to recognise
its site's own page. A page that is the site's own but unreadable (a redesign, a parser bug) shows
as `unparseable` rows on the admin screen and never blocks the source. A page that is not the
site's own freezes the source for the cooldown.

**A good page is never replaced by a bad one.** When a listing that was read before gets a
`blocked`, `unparseable` or `unavailable` attempt, its stored page, outcome, facts and title are left
as they were and only the `last_attempt_*` columns change. A `not_found` re-read sets the listing to
`failed` and leaves the title alone.

Every parser has a `VERSION`, stamped on the listing and the title. After a parser fix, bump it and
run `books:publisher_intake:reparse[source]`: stored pages are read again with the new parser
without a fetch, and an `unparseable` listing whose page now reads is promoted to `read` with its
title stored and classified.

## Holds

After each read, shared code (`Books::PublisherIntake::Hold`) sets `status` and `hold_reason`. First
match wins:

1. `incomplete`: no title, no contributor, or no ISBN-13.
2. `placeholder`: the title or the only contributor is a stand-in ("Untitled...", "To Be
   Confirmed", "TBD").
3. `non_english`: the page states a language and it is not English.
4. `not_a_book`: every format is a non-book product (calendar, journal, card deck, puzzle,
   stationery, toy, kit), by the publisher's format label.
5. `set`: a box set or bundle, by a format label, by the set words the verification code already
   uses (not counting a series-name word, and not a title that counts books, as "1001 Books..."
   does), or by a number range in the title ("#1-3").

A false hold loses a real book and a false pass only lets a three-in-one volume through, so every
rule leans toward `ready`. The set vocabulary is
`Services::Books::Verification::EditionCheck::SET_WORDS` and
`Services::Books::AmazonBookCheck`'s constants; there is no second list.

Two settings bound what a dated source emits: the lookback (30 days behind today, so a title that
came out last week is still collected) and the horizon (365 days ahead; a title further out is
picked up by a later run once it is inside).

## Adding a source

1. **Write the strategy** under `app/lib/books/publisher_intake/sources/`, subclassing
   `Sources::Base`. A strategy never fetches, stores or enqueues. It defines `key`, `name`,
   `VERSION`, and:
   - `discovery_requests(since:)`: the `Request`s to start with, built with `Request.file(url,
     context:)` (the fetcher's file route) or `Request.page(url, ...)` (the page route); do not
     write a `kind:` symbol. `context` is a small JSON-serializable hash returned to
     `parse_discovery`, so it can tell a sitemap index from a child file or carry a page number.
   - `parse_discovery(request:, response:)`: returns a `Discovery` with an outcome, the
     `ListingRef`s found (`url`, `external_key`, `signal`) and any further requests.
   - `listing_request(listing)` and `parse_listing(listing:, page:)`: the request for a listing and a
     `Reading` of what came back: an outcome, `facts` (a hash keyed by the `Books::PublisherTitle`
     columns) and `sibling_keys`, the ISBNs of other formats the page listed, whose pending
     listings become `covered`. Start `parse_listing` with `status_outcome(page.status)` and return
     `:blocked` when the page is not the site's own (check its `<title>`). Each entry of `formats`
     is a hash with symbol keys `:isbn13, :format, :format_label, :on_sale_on, :pages,
     :price_cents, :currency`. Set `source_key` in the facts only when the site has an id for the
     work (Penguin Random House); without one, titles match by shared ISBN.
   - `baseline_on_first_run?` (true for list-comparison sources) and `seed_requests` (first run
     only), when the source needs them.
   Shared helpers cover the common parts: a sitemap reader (index or URL set, gzipped or not), a
   JSON-LD reader for `Book` and `Product` nodes, an ISBN helper and the hold classifier.
2. **Capture fixtures.** In development, with a fetcher running, run
   `books:publisher_intake:capture[source,url,name]`. It fetches one page and writes it trimmed and
   gzipped under `test/fixtures/files/publisher_intake/<source>/`. A fixture is a real page cut to
   what the parser reads, with long copy (descriptions, reviews, biographies) cut to one sentence,
   no review quotes, and under 60,000 bytes unzipped. States that cannot be captured (a challenge
   page, a redesigned page) are tiny synthetic files that say so in a comment.
3. **Test it** in `test/lib/books/publisher_intake/sources/<source>_test.rb`. The corpus needs its
   negative cases, not only happy pages: a box set, a non-book product, an untitled placeholder, a
   non-English edition, a title with one format and one with four, a page with no contributor, a
   challenge page and a page whose shape changed. Nothing in the suite makes a network request.
4. **Register it**: one line in `Books::PublisherIntake::Sources::REGISTRY`.
5. **Rehearse it** (below), read the stored pages that came out wrong, fix the parser, bump
   `VERSION`, and `reparse`.

## Settings and environment

Read at boot into `config.x.publisher_intake` (`config/initializers/publisher_intake.rb`); a bad
value logs and falls back, and never stops boot.

| Setting | Env var | Default |
|---|---|---|
| enabled sources | `PUBLISHER_INTAKE_SOURCES` (comma-separated keys) | none: the feature is off |
| fetch interval, seconds | `PUBLISHER_INTAKE_FETCH_INTERVAL` | 10 |
| daily fetch cap per source, per UTC day | `PUBLISHER_INTAKE_DAILY_FETCH_CAP` | 2000 |
| block cooldown | | 6 hours |
| fetch attempts | | 3 |
| run every, days | | 7 |
| re-read after, days | | 28 |
| lookback, days | | 30 |
| horizon, days | | 365 |
| stuck run after, days | | 3 |

An unknown key in `PUBLISHER_INTAKE_SOURCES` is logged and ignored. The env vars are read in
both the web process (the admin screen) and the Sidekiq process; `deployment/ENV.md` lists them.
Enabling a source in production is that one variable. The page fetcher must be running an image
that answers `POST /fetch_file`, and the sitemap files must stay under the fetcher's file size cap.

## Rake tasks

All under `books:publisher_intake`. A task that can fetch needs the page fetcher reachable.

| Task | What it does |
|---|---|
| `run[source]` | Starts a manual run for one source now. The source must be enabled, and the task refuses while that source has a `running` run |
| `release_baseline[source,limit]` | Moves up to `limit` baseline listings to `pending`, highest key first |
| `reparse[source]` | Reads stored pages older than the current parser version again, fetching nothing, and promotes unparseable ones that now read |
| `rehearse[source,limit,max_discovery_requests]` | Development only. Runs discovery into a manual run, then reads up to `limit` pending listings, synchronously, one line per fetch, no page content printed. It waits the fetch interval between fetches, uses no gate and counts nothing against the cap |
| `status` | One block per source: enabled, last run, listings by state, titles ready and held, fetches today |
| `capture[source,url,name]` | Development only. Saves a trimmed gzipped fixture of one page |

A rehearsal stopped by `max_discovery_requests` is saved as `failed` on purpose: a cut-short run must
never count as a source's finished first run. A rehearsal writes additive rows to the three intake
tables and stores pages on local disk in development; in development, point `PAGE_FETCHER_SERVICE_URL`
at a local fetcher and blank `PRIVATE_IMPORTS_STORAGE_BUCKET` first, because a development environment
file may point at shared services.

## Admin screen

`/admin/publisher_intake` in the books admin, read-only, one sidebar entry. The overview has one row
per registered source: enabled or not, last run and its status, listings by state, titles ready and
held by reason, today's fetch count against the cap, and "blocked until" when the gate is blocked.
`/admin/publisher_titles` is a paginated list filterable by source, status and hold reason, upcoming
titles first. A title's page shows every stored fact, each format with its ISBN, the listings behind
it with their outcome and last read time, and a link to the publisher's page. A Playwright spec
(`e2e/tests/books/admin/publisher-intake.spec.ts`) covers it and also passes with empty tables.

## Rehearsal measurements, 2026-11-18

Each source was run once with `rehearse[<source>,10,3]` (ten reads, at most three discovery
requests) through a local page fetcher, from the development machine, with the default ten-second
interval: 13 requests per source.

| Source | Discovery requests | Listings seen | Listings read | Outcomes | Holds | Median seconds per fetch | Run |
|---|---|---|---|---|---|---|---|
| `hachette_us` | 3 (API pages 1 to 3) | 277 | 10 | 10 `found` | 1 `placeholder` | 10.0 | `failed` (stopped at the cap, as designed) |
| `penguin_random_house_us` | 3 (index, 2026 file, 2027 file) | 16,800 | 10 | 10 `found` | none | 9.6 | `finished` |
| `macmillan_us` | 3 (index, two seed collections) | 40 | 10 | 10 `found` | none | 9.4 | `failed` (stopped at the cap, as designed) |

In every source all ten titles read with a title, at least one contributor and at least one ISBN-13.
Penguin Random House's 16,800 entries are 9,785 listings because the next year's file repeats
entries the current year's file already has, with the same dates (checked 2026-11-18: 7,015 of
7,015 repeated, none with a different date). Medians cover the sitemap, API and page fetches together; a discovery request took 4 to 10 seconds
and a page 7 to 13. No page was blocked or unparseable. Counts that hold only for that day: Hachette's
277 listings are the records in its lookback window after three API pages, and ten of them were
marked `covered` by siblings of the ten read; Macmillan's 40 are the first 20 listings of each seed
collection (see Known gaps).

## Known gaps

- **Hachette** takes an edition's language from a "(<Language> Edition)" qualifier on the page's
  format label. That has not been seen on a real page, so a non-English Hachette edition may read as
  `ready`.
- **Penguin Random House** detects only Spanish editions as non-English (from the genre link or the
  Spanish-language division). The page's own language field says English on Spanish editions, so
  other languages are not detected.
- **Macmillan** shows no edition language on any page, so language is never recorded for this
  source.
- **Hachette** labels some non-book products with a book format, so the `not_a_book` hold cannot
  catch those.
- **Macmillan's first run** seeds only the first 20 titles of each of its two collection pages. The
  other already-listed upcoming titles stay `baseline` until released with
  `release_baseline[macmillan_us,<limit>]` or read by a later backfill. Titles that appear after the
  first run are all read.
- **A Penguin Random House work page** can list an older edition beside the new one. A title's
  on-sale date is the earliest format date, and each format keeps its own date.
- **A parser that raises, or a page whose shape changed,** shows as `unparseable` rows on the admin
  screen. It never blocks the source. Re-parsing stored pages after a parser fix needs no new fetch.
- **Hachette's first run** asks for records added in the last 14 months, so an upcoming title added
  earlier and not modified since is missed.
- **Hachette** has no check for a "not found" page served with status 200; it reads as `unparseable`.
- **One fetch thread serves all sources,** so with three sources enabled each gets about a third of
  it. When a source's queue falls more than an hour behind, the sweep queues a listing a second
  time, which spends a daily-cap turn without a second fetch.
- **Nothing here writes to the catalog** (books, editions, authors, identifiers). Creating catalog
  records from stored titles is a later design.
- A publisher withdrawing a title is not detected: `last_seen_at` records when a listing was last
  seen and nothing acts on it.
