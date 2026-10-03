# Goodreads Import — Design

Date: 2026-10-03. Status: approved section by section in brainstorming; awaiting review of this
written spec.

## 1. Why this exists, and what went wrong last time

Members upload their Goodreads library export (CSV) and get their shelves, read dates, ratings and
reviews on the books site. The legacy app (`../the-greatest-books/admin`) had this feature, and it
is the main source of the legacy catalog's bad data. This design rebuilds it so that it does not
create bad data, and uses the legacy import history to find and repair the bad data that is already
there.

### Measured legacy facts (read-only queries, 2026-10-03)

- 803 imports by 659 users, 2024-09-09 to 2026-10-02: 757 complete, 23 failed (`invalid byte
  sequence in UTF-8`, `CSV::MalformedCSVError`), 23 stuck in `pending` (the worker died 5–40 minutes
  in).
- **Every import kept its raw upload** as an ActiveStorage blob in the legacy R2 bucket (~140 MB in
  all; 795 `text/csv`, plus junk uploads: 2 xlsx, a pdf, a numbers file, a zip, a jpeg, an html, an
  mp4).
- About **135k of 160k legacy books (84%) were created by imports**; 103k of those are on exactly one
  user's lists and only 3.2k are on any curated list.
- Duplicate titles are rare (~265 excess rows). **Duplicate authors are the large problem**: 2,934
  normalized-name groups, 4,295 excess rows, 3,339 of them created in 2026, ~83% inside import
  windows. Worst groups: "James Tynion IV" ×74, "D.K. Publishing" ×67, "Osho" ×64.
- Imports produced ~388k user list items and ~117k of the 151k reviews. All of it was migrated into
  the new app with preserved book, author and user ids.
- 543 Goodreads ids are stored as slugs or URLs (`32076670-ball-lightning`,
  `49122921-konosuba?from_search=true&…`) and were carried into the new app as is.
- Legacy `goodreads_books` (223,532 rows) is a shared cache keyed by Goodreads id: ~188k rows were
  built from export rows; ~35.7k came from the scraper's lookups and carry scraped facts.

### Legacy root causes, ranked

1. **The AI's "no" was ignored.** After the AI rejected every candidate, `BookFinder.find_or_create`
   and `AuthorFinder.find_or_create` re-ran the search and took the top hit anyway (book score ≥ 75,
   author ≥ 25).
2. **Identifier links were trusted forever and shared across users.** The row's Goodreads id and
   ISBNs were attached to whichever book was chosen, so one wrong match sent every later importer of
   that edition to the same wrong book, with no title or author check.
3. **Title cleaning removed the evidence**: every parenthetical and everything after the first colon.
   All "Mistborn: …" volumes became "Mistborn".
4. **Goodreads ids and ISBNs are per edition; the catalog is per work.** Other editions and
   translations missed and became new books.
5. **Any exception created a bare, authorless book**, which no later author-required search can find.
6. **No locking and no unique constraints**, four Sidekiq threads, no server-side guard against a
   double upload.
7. **Unvalidated enrichment on every created book**: Wikipedia lookup by title alone, `titleize`,
   Goodreads genre categories, six AI jobs per book. A tester's joke file of invented books spawned
   10,000+ AI jobs.
8. **No record of how a row was resolved**, so nothing could be audited or reversed.

## 2. Decisions

| Question | Decision |
|---|---|
| May an import create books and authors? | **Yes, always, when nothing matches, and always flagged.** Exception: a row Goodreads proves fake is parked, not created (§6). |
| How visible are created records? | **Provisional** until an admin approves the import (§9). |
| What may promote a provisional record? | **Only an admin.** No automatic promotion (a second account defeats it). |
| Cost control on matching AI? | **None.** Enrichment is behind approval; matching AI is one `fast` call per ambiguous edition, bounded by upload limits. A counter is shown, not enforced. |
| Verify against Goodreads? | **Yes**, via the page fetcher, only for rows about to create a book (§6). |
| Store fetched HTML? | **Yes, gzipped, in private object storage**, unstripped (§6). |
| Reviews with text but no rating? | **Make the rating optional on reviews** (§8). |
| Legacy replay findings | **Auto-fix when rule-certain; queue the rest.** Verdicts are saved by preserved ids and re-applied after every migration pass (§12). |
| Mark existing legacy books provisional? | **Only clear junk** (§12.6). |
| Failed legacy imports | **Finish them** through the member pipeline, unless the user has a later completed import (§12.8). |
| Where the replay runs | **Production**, after the Open Library service and page fetcher are deployed on the Proxmox home server. |
| Admin notification | One email per import to contact@thegreatestbooks.org. |

## 3. Data model

### New tables

**`books_goodreads_imports`** (`Books::GoodreadsImport`): one row per upload.

- `user_id` (FK, not null), `source` enum `member | legacy_replay`, `legacy_import_id` (integer,
  unique where not null).
- `status` enum `queued | parsing | resolving | verifying | writing | complete | failed`, `error`
  (text), `started_at`, `finished_at`.
- `review_status` enum `pending | approved | rejected`, `reviewed_by_id`, `reviewed_at`.
- Counters: `rows_count`, `editions_count`, `matched_count`, `created_count`, `flagged_count`,
  `parked_count`, `skipped_count`, `ai_calls_count`.
- `has_one_attached :file` on the new private service (§3.3).
- Partial unique index on `user_id` where `status` is in progress: **one import in progress per
  user**, enforced by the database.

**`books_goodreads_editions`** (`Books::GoodreadsEdition`): the unit that is resolved.

- `goodreads_book_id` (bigint, not null), `signature` (string, not null). Unique on both.
- `signature` = digest of the normalized title plus the normalized primary author. Honest exports
  give identical title and author for the same id, so they share a key; a hostile row that claims a
  real id under a different title gets its own resolution and cannot overwrite the honest one.
- Parsed bibliographic fields: `title`, `series_name`, `series_number`, `primary_author`,
  `additional_authors` (string array), `isbn13`, `isbn10`, `original_publication_year`,
  `year_published`, `publisher`, `binding`, `pages`.
- `book_id` (nullable FK), `match_decision_id`, `resolved_at`, `resolution` enum
  `matched | created | parked`, `verification` enum
  `not_needed | pending | verified | not_found | mismatch | unverified`.

**`books_goodreads_import_rows`** (`Books::GoodreadsImportRow`): one row per CSV line.

- `import_id`, `row_number`, `goodreads_edition_id` (nullable: a row that fails to parse has none).
- `raw` jsonb: the CSV row as header → value, **with `Private Notes` removed**. We never use that
  column, so we never store it.
- Parsed user fields: `exclusive_shelf`, `shelves` (array), `shelf_positions` jsonb, `rating`
  (0–5), `review_body`, `date_read`, `date_added`, `read_count`.
- `outcome` enum `pending | applied | parked | skipped | failed`, `outcome_detail` (string),
  `error`.
- `applied` jsonb: ids of the list items and review this row wrote. A revert removes exactly these.

**`books_goodreads_import_records`**: provenance.

- `import_id`, polymorphic `record`, `action` enum `created | stamped`.
- Every book, author, book_author and identifier an import creates or stamps gets a row. Approval
  uses it to find what to promote; rejection uses it to find what to remove.

**`books_goodreads_pages`** (`Books::GoodreadsPage`): Goodreads verification cache (§6).

- `goodreads_book_id` (bigint, unique), `source` enum `fetched | legacy`, `fetched_at`,
  `http_status`, `outcome` enum `found | not_found | blocked | unparseable`.
- Parsed facts: `title`, `series_name`, `series_number`, `authors` jsonb (`[{name, role}]`;
  `role: null` means unknown), `original_publication_year`, `isbn13`, `isbn10`, `asin`,
  `parser_version`.
- `has_one_attached :html` (gzipped, private service). Legacy-seeded rows have none.

**`books_repair_verdicts`** (`Books::RepairVerdict`): the replay's decisions (§12.7).

- `kind` enum `relink | merge_books | merge_authors | strip_identifier | mark_provisional`.
- `subject_key` (string, unique per kind), built only from **preserved ids**: legacy import id and
  row number, book ids, author ids, user ids.
- `payload` jsonb, `decided_by` enum `rule | ai | admin`, `status` enum
  `proposed | approved | rejected`, `reason`, `ai_chat_id`, `decided_by_user_id`, `applied_at`.
- **No foreign keys to books, authors or users**, so it survives the launch truncation. The launch
  sequence must not truncate this table.

### Changes to existing tables and models

- `books_books.provisional` and `books_authors.provisional`: boolean, default false, not null,
  indexed.
- `reviews.rating` becomes nullable (§8).
- `Books::Book has_many :goodreads_editions`; `Books::Book::Merger` moves them (every new book
  association needs the merger). `Books::Author::Merger` needs no change for editions.
- `User has_many :goodreads_imports, dependent: :destroy` (files and rows go with the account).
- The finder's `MatchDecision` subject for an import is the `Books::GoodreadsEdition`.

### Storage

A new ActiveStorage service `private_imports` (S3-compatible, its own R2 bucket, **not public**).
The existing `cloudflare` service is `public: true` and must not hold user exports, which contain
reviews. Credentials are ENV vars via SOPS, like every other secret. Both import files and Goodreads
page HTML use it. Development uses the same service against a development bucket.

### Identifiers

Goodreads ids and ISBNs stay at work level (`books_work_goodreads_id`, `books_work_isbn13`,
`books_work_isbn10`). That is the existing convention (197k Goodreads id rows) and what the finder
looks up. No `Books::Edition` rows are created.

## 4. Parsing and normalization

**Upload validation** (`Services::Books::GoodreadsImports::ValidateUpload`):

- Max 10 MB (the largest legacy upload was 8.1 MB). Content must parse as CSV and carry the export
  headers `Book Id`, `Title`, `Author`, `Exclusive Shelf`; anything else is refused at upload, before
  an import row exists.
- Encoding: strip a BOM; if the bytes are not valid UTF-8, try Windows-1252, then scrub invalid
  bytes. Never `force_encoding` alone.
- Limits: one import in progress per user (database), and at most 3 imports per user per day
  (`config.x.goodreads_imports.daily_limit`).

**Row parsing** (`Books::Goodreads::ExportRow`, a plain value object):

- Columns are read **by header name**, never by position.
- **ISBNs**: unwrap `="…"`, strip hyphens and spaces, validate the checksum, convert ISBN-10 to 13
  (`Books::Isbn` normalizer, new in Rails; mirrors `data-sources/src/common/normalize.py`). An
  invalid ISBN is dropped, not stored.
- **Goodreads id**: leading digits only (`Books::GoodreadsId.normalize`), so a slug or URL form
  becomes the bare id.
- **Title**: kept whole, subtitle included. A trailing `(Series Name, #N)` is split into
  `series_name` and `series_number` and kept as evidence; the title sent to the finder has it
  removed, and the series goes in the query as context. Nothing after a colon is ever dropped.
- **Year**: `Original Publication Year`, else `Year Published`.
- **Authors**: only the primary `Author` is trusted as an author. `Additional Authors` mixes
  co-authors with translators and illustrators and has no roles, so those names are AI context only.
  Real co-authors arrive from a verified Goodreads page (§6).
- **User fields**: `Exclusive Shelf`, `Bookshelves`, `Bookshelves with positions`, `My Rating`,
  `My Review`, `Date Read`, `Date Added`, `Read Count`. Dates parse `%Y/%m/%d`; a bad date is
  dropped and noted on the row.
- `Private Notes` is removed from `raw` before it is saved.

## 5. Resolution

Rows are grouped into editions by `(goodreads_book_id, signature)`. Each edition is resolved once.

1. **Cache.** If a `Books::GoodreadsEdition` with that key is already resolved by any import and its
   book still exists, reuse it. Merges are followed (the merger moves editions).
2. **Finder.** Otherwise run the `Books::Book` finder (`DataImporters::Books::Book::Finder`) with an
   `ImportQuery` of title, primary author, year, ISBN-13s, ISBN-10s, Goodreads id, and the series
   and additional authors as AI context, with `subject:` the edition. The full finder runs:
   identifiers (corroborated), exact, OpenSearch, Open Library where available, and AI selection
   when the rules cannot decide. `ai_calls_count` counts the AI calls; nothing caps them.
3. **Outcome.**
   - Matched, `certain` or `high`: link.
   - Matched, `medium` or `low`, or `decided_by: fallback`: link and flag (`needs_review` on the
     decision; counted in `flagged_count`).
   - Unmatched: go to verification (§6), then:
     - page found and agreeing → create a provisional book using the page's facts;
     - `not_found` or `mismatch` → park the edition (`resolution: parked`); its rows become
       `parked` with detail "not found on Goodreads";
     - fetcher unavailable or blocked → create a provisional book marked `unverified`.
   - An AI "none of these" ends in create-and-flag (subject to verification). **It never falls back
     to the top search hit.**

### Creating a book

Through `DataImporters::Books::Book::Importer` with three new options:

- `provisional: true` — the book, and any author the Authors provider creates, are saved
  provisional.
- **Stamp the query's identifiers whether or not Open Library accepts.** Today the query's ISBNs and
  Goodreads id are persisted only on an OL accept, so a book created while OL is down could never be
  found again by identifier.
- **No enrichment providers** (`AiEnrichment`, `AuthorEnrichment` are skipped). Enrichment runs on
  approval (§10).

When a verified page supplies facts, the book takes the page's title and series, and the page's
authors with role `author` (translators, illustrators, editors are excluded) become the
`author_names`.

Every record created or stamped writes a `books_goodreads_import_records` row.

### Locking

`pg_advisory_xact_lock` on a hash of the normalized title plus normalized primary author is held
around a second finder check and the create. Two imports racing to create the same new book end
with one book; the second sees the first's book on its re-check.

## 6. Goodreads verification

Only editions about to create a book are fetched. Matched rows never touch Goodreads.

- **Cache first.** `Books::GoodreadsPage` by Goodreads id. One fetch per id, ever, unless an admin
  requests a refresh. Shared across users and imports.
- **Fetch.** `PageFetcher::Client#fetch("https://www.goodreads.com/book/show/<id>",
  wait_for_selector:)`, with the selector chosen from increment 4's measurement of real pages.
- **Parse.** `Books::Goodreads::BookPage` reads identity facts only: canonical title, series,
  authors with roles, original publication year, ISBN-13/10, ASIN. Goodreads pages are Next.js, so
  the embedded `__NEXT_DATA__` JSON is the expected source; increment 4's first task confirms this
  on ~20 real pages before the parser is designed. Descriptions are never taken.
- **Agreement.** The page agrees with the edition when the normalized titles match (allowing the
  series suffix and subtitle) and the primary author is among the page's authors with role
  `author`. A 404 is `not_found`; a found page that disagrees is a `mismatch`.
- **HTML storage.** The full HTML is gzipped and attached to the page row on the `private_imports`
  service. It is not stripped: its value is re-parsing after a parser bug or a markup change without
  fetching again, and stripping is itself a parser decision. Increment 4 measures real sizes (the
  estimate is 50–150 KB gzipped per page). The fetcher doc's "html is never stored" rule is amended
  for Goodreads pages: public book pages, stored for internal parsing, never served.
- **Politeness.**
  - A dedicated Sidekiq capsule `goodreads_fetch` with concurrency 1.
  - A minimum gap between fetches, `config.x.goodreads.fetch_interval` (default 15 s, at most 240
    an hour), enforced with a Redis timestamp, not by sleeping in a thread.
  - A daily cap, `config.x.goodreads.daily_fetch_cap` (default 1,500).
  - A 403, a challenge page, or a page the parser cannot recognize opens a Goodreads breaker for
    `config.x.goodreads.block_cooldown` (default 6 hours). While it is open nothing is fetched.
- **Never in the critical path.** Editions waiting on a fetch sit in `verification: pending`; the
  import moves to `verifying` and completes when every pending edition is settled. If the fetcher is
  down, the breaker is open, or the daily cap is reached, pending editions are created `unverified`
  so the import completes; `Books::Goodreads::VerifyUnverifiedJob` (rake-driven sweep) verifies them
  later, and a later `not_found` or `mismatch` on a still-provisional book flags it on the admin
  page.
- **Legacy seed.** The ~35.7k scraped legacy `goodreads_books` rows (those with `last_looked_up_at`
  or a scraped description) load into `books_goodreads_pages` with `source: legacy`, no HTML, and
  `role: null` on every author (the legacy scraper included translators). Their facts about the id
  are trusted; their legacy link to a Book is not carried over. The ~188k export-derived rows are
  skipped: the replay rebuilds them from the original CSVs.

## 7. Writing the user's library

`Services::Books::GoodreadsImports::WriteLibrary` makes one pass per import after resolution. It
does not call `Services::UserLists::AddItem` per row (that stamps today's date and fires per-item
side effects), but it honors the same list rules.

### Shelves

- `read` → the user's **read** list, `completed_on` from `Date Read`. A blank `Date Read` leaves it
  blank; it is never set to today. Legacy's `Read Count > 0` condition is dropped.
- `to-read` → **want to read**; `currently-reading` → **reading**.
- A book written to read is removed from the user's reading list, as `AddItem` does.
- Every other shelf, exclusive or not, becomes a **custom** list named after the shelf with hyphens
  turned into spaces, matched case-insensitively against the user's existing custom lists. The three
  default shelf names are skipped in `Bookshelves` (they are already handled).
- A shelf called "favorites" becomes a custom list, **never** the favorites list type, which feeds
  the generated "Users' Favorite Books" list.
- New items follow `Bookshelves with positions` order and are appended after existing items.
- `created_at` of a new item is `Date Added`, else the import time.

### Re-import is additive

- Items are inserted with skip-on-conflict on `(user_list_id, listable_type, listable_id)`.
- An existing item is never moved or reordered; its `completed_on` is filled only when blank.
- Nothing is deleted. Running the same file twice changes nothing.

### Reviews

- `My Rating` 1–5 → a `Review` with that rating and `My Review` (Goodreads `<br/>` markup converted,
  then the existing sanitizer).
- `My Rating` 0 with review text → an unrated review (§8). Rating 0 and no text → nothing.
- An existing review by the user for that book is left untouched.
- Two rows resolving to the same book: one deterministic winner — the row with a rating, then the
  latest `Date Read`, then the lowest row number.
- The bulk path bypasses the per-review `after_commit` and calls
  `Services::Reviews::SummaryRecalculator.recalculate` once per touched book.

### After the write

- Each row's `applied` records the ids it wrote.
- `Services::Books::ReadingGoals::CompletionChangeInvalidator` runs once for the user, purging
  affected public goal pages.
- Provisional books are shown to the owner normally. **Other viewers of the user's lists do not see
  them** until they are approved.

## 8. Optional ratings on reviews

Only `Books::Book` includes `Reviewable`, so music and games are unaffected.

- **Schema.** `reviews.rating` nullable. New check constraint: `rating IS NOT NULL OR body IS NOT
  NULL`. The existing `reviews_body_not_blank` constraint still forbids an empty-string body.
- **Model.** Rating optional; when present, an integer 1–5. A rating or a body is required.
- **Summary math.** `SummaryRecalculator::AGGREGATES` changes `COUNT(*)` to `COUNT(rating)` for
  `ratings_count`. Without this, every unrated review would lower the book's average. Run
  `backfill_all!` once after deploy (no current row changes: all 151k reviews have ratings).
- **Display.** An unrated review shows no stars (not zero stars). `by_rating` orders
  `rating DESC NULLS LAST, id DESC`. "My reviews" stats average rated reviews only. The rating filter
  handles unrated reviews.
- **Form.** Stars become optional and can be cleared in the review modal; submitting requires stars
  or text, and the server validation enforces the same rule.
- **Structured data.** An unrated review emits no `reviewRating` in the book page's JSON-LD;
  `AggregateRating` uses the corrected `ratings_count`.

## 9. Provisional records

A provisional book or author is a real row, created by an import and not yet approved.

**Hidden from:**

- public site search and autocomplete;
- browse and category pages;
- rankings and ranked lists;
- generated lists (a provisional book a user later moves onto favorites by hand is excluded from the
  generated list until approved);
- similar books;
- an author's book list, and the greatest-authors ranking;
- the public API;
- sitemaps, once they exist;
- other people's views of a user's lists.

Each surface uses a `catalog` scope (`where(provisional: false)`) on `Books::Book` and
`Books::Author`. Each gets a regression test that a provisional record is hidden **and** a normal
one is shown.

**Search stays complete for matching.** Provisional books and authors are still indexed, with a
`provisional` field. Public search queries filter it out; the finder's OpenSearch source does not.
Otherwise a second user importing the same book under another edition could not find the
provisional copy, and we would get two.

**Show pages** for provisional books and authors load by URL, render `noindex`, and show a small
alert: "Added from a Goodreads import; not yet reviewed or enriched."

## 10. Admin: approval, rejection, notification

**Books → Goodreads Imports** (`Admin::Books::GoodreadsImportsController`, admin-only policy;
legacy admin controllers were public by default, so the policy is tested).

- **Index**: user, date, source, status, review status, and the counters including AI calls. Imports
  in progress for more than 2 hours are flagged as stuck. Checkboxes and **Approve selected**.
- **Show**, in tabs: created books and authors with verification state and a link to each match
  decision; flagged decisions, linked into the existing match-decision audit UI; parked rows; raw
  rows. **Retry** re-runs a failed or stuck import.

**Approve** (`Services::Books::GoodreadsImports::Approve`):

1. The admin may untick individual created records before approving; those are deleted (only if
   still provisional and unreferenced, as in Reject).
2. Every remaining provisional record in the import's provenance becomes non-provisional and is
   reindexed.
3. Enrichment is queued: `Books::EnrichBookJob` for each book and the author chain
   (`Books::Authors::WikidataJob` …) for each new author, with books deferred to their authors'
   chains exactly as `Services::Books::DeferredEnrichment` does today.

A provisional book referenced by several imports is promoted by whichever of them is approved first.

**Reject** (`Services::Books::GoodreadsImports::Revert`):

- deletes the list items and reviews in each row's `applied`;
- deletes provisional records in the import's provenance that nothing else references (another
  import's rows, another user's list item, a curated list item);
- removes identifiers the import stamped onto existing books;
- recalculates review summaries and purges goal pages it touched.

**Per record**: promote, or delete while provisional.

**Email.** `AdminMailer#goodreads_import_finished` once per member import, sent when it completes or
fails, to `config.x.goodreads_imports.notify_to` (`contact@thegreatestbooks.org`), with the user, the
counters and a link to the admin page. Replay imports send nothing.

## 11. The member's side

- **Import from Goodreads** page in the member's account on the books site: how to export from
  Goodreads, the upload form, and the history of their imports. Signed-in members only.
- **Summary page** per import: polls while running, then shows counts and each row's result
  (matched, new and pending review, flagged, not found on Goodreads, skipped, failed), with a "wrong
  book?" link into the existing corrections flow for that book.
- Copy for these pages goes through the `avoid-ai-writing` skill.

## 12. The legacy replay

The legacy imports are a record of every way the old matcher went wrong. The replay uses them to
repair the data and, before members use the importer, to measure the new resolver on ~188k real
editions.

It runs in **production**, after the Open Library service and page fetcher are live on the Proxmox
home server. It is a **repeatable post-migration step**: books are truncated and re-migrated before
launch, and the replay must be run again after each migration pass and in the final launch sequence.

### 12.1 Loader

- `books:goodreads_replay:load` lists legacy imports from the legacy DB (`LegacyBooks::` models,
  new: `LegacyBooks::GoodreadsImport` and the ActiveStorage attachment/blob rows) and, for each,
  find-or-creates a `Books::GoodreadsImport(source: legacy_replay, legacy_import_id:)` owned by the
  preserved user id, downloading the blob from the legacy R2 bucket only if no file is attached.
- The new app gets read-only credentials for the legacy bucket (`LEGACY_STORAGE_*` ENV via SOPS).
- Non-CSV uploads are marked failed with the reason.

### 12.2 Fix-ups

Strip the slug from the 543 slug-form `books_work_goodreads_id` values, then remove the duplicates
that leaves on the same book. Rule-certain; recorded as `strip_identifier` verdicts.

### 12.3 Resolve

Each distinct edition is resolved with the finder in **`verify: true`** (no early exit on an
identifier hit), because legacy's own wrong identifiers are on the books, and corroboration (title
or author must agree) is what rejects them. The compare-and-repair pass **never creates books or
list items**; only §12.8 does, through the member pipeline.

- Pass one runs the fast sources (identifiers, exact, OpenSearch, Open Library identifier lookup).
- Pass two adds Open Library `/resolve` (5–6 s, one at a time on `serial`) for disagreements and
  unmatched editions only. On all ~188k editions it would take about 13 days.
- Results fill `books_goodreads_editions`, which warms the cache for members' future imports.

### 12.4 Compare

Legacy's choice for a row is the book holding the row's Goodreads id that also has that user's list
item.

| Finding | Action |
|---|---|
| Resolver agrees | none |
| Disagrees; decided by rule with `certain`/`high` confidence | **auto** `relink`: move this user's list items and review from A to B (on conflict keep B's, fill blank dates from A); if A's title and author contradict the row, `strip_identifier` the row's Goodreads id and ISBNs from A and stamp them on B |
| Disagrees; decided by AI | queued |
| No match found | queued, with Goodreads page facts attached where cached or fetched |

### 12.5 Duplicates

- **Books.** Pairs the finder flags go into the existing `DuplicateCandidate` queue. Auto
  `merge_books` only when the normalized titles are equal, the author id sets are identical, and the
  two books share a corroborated identifier.
- **Authors.** The author finder runs in `verify: true` over **every author in a normalized-name
  group** (2,934 groups, 7,229 authors), not only import-created ones: the legacy add-book modal
  created authors with `Author.find_or_create_by!(name:)`, and those never appear in a CSV. Auto
  `merge_authors` only when the normalized
  names are equal, there is no birth/death year conflict, there is no conflicting external
  identifier (OL key, Wikidata QID, VIAF), **and** a `fast` AI check given both authors' book lists
  says they are the same person. Everything else is queued.
- Order: author merges, then book merges (the book merger moves book_authors only when the target has
  none), then relinks.

### 12.6 Junk goes provisional

Auto `mark_provisional` (reversible) for:

- authorless fallback books;
- books left with no supporting replay row after relinks, no curated-list item, and no other user's
  list item.

### 12.7 Verdict ledger

- Each finding produces a `Books::RepairVerdict`: rule-certain ones `approved` with `decided_by:
  rule` (or `ai` for the author check), the rest `proposed` for the admin queue.
- Each pass loads verdicts first: `approved` ones re-apply, `rejected` ones suppress their finding,
  so nothing is reviewed twice across migration passes.
- Applying is idempotent: a relink whose items have already moved, or a merge whose source no longer
  exists, does nothing.
- Admin queue: **Books → Repair Verdicts**, filter by kind and status, approve or reject, with links
  to both records and to the source row.

### 12.8 Failed and stuck legacy imports

The 23 failed and 23 stuck imports run through the **member pipeline** (increment 6): books created
provisional, list items, reviews, approval through the admin page. The write step skips on conflict,
so rows a half-finished import already wrote are not duplicated. **An import is skipped if the same
user has a later completed import**, since its file could bring back books the user has since
removed.

### 12.9 Safety gate

`config.x.goodreads_replay.auto_apply` defaults to **false**. The first full replay is a dry run: it
writes verdicts but applies nothing, and produces `docs/data-quality/goodreads-replay.md` (agreement
rate; findings by kind, confidence and decider; unmatched counts; AI calls; the script that produced
it). A sample of 50 auto verdicts per kind is hand-checked; auto-apply is switched on only after that
check passes.

## 13. Failure handling

- The import job keeps its state on its own row (like `CsvExports::GenerateJob`, `retry: false`).
  Every phase can run again: rows are parsed once (unique `(import_id, row_number)`), an edition is
  resolved once, writes skip on conflict. Retry continues where the import stopped.
- One bad row never stops an import; its error is recorded on the row. Only an unreadable file fails
  the import.
- Open Library down: the finder records `sources_failed` and caps confidence at `medium`, so the
  decision is flagged.
- Fetcher down or Goodreads blocking: creations are `unverified`; the sweep verifies later.
- Postgres errors re-raise, as the finder already does.

## 14. Testing

- **Hostile fixtures, not only friendly ones** (a corpus with no negative class tests nothing): invented
  books, a real Goodreads id under the wrong title, `="…"` ISBNs, slug ids, a BOM, invalid UTF-8, an
  xlsx renamed to `.csv`, missing headers, a Windows-1252 file.
- **Normalizers**: ISBN checksum and 10→13, Goodreads id forms, series suffix parsing.
- **Resolver**: AI and fetcher stubbed (Mocha); every outcome branch; mutation evidence on the
  create-vs-park and flag rules.
- **Locking**: a concurrency test with transactional fixtures off, two threads, one book.
- **Visibility**: every surface in §9 asserts a provisional record hidden and a normal one shown.
- **WriteLibrary**: shelf mapping, dates, re-import changes nothing, read removes from reading,
  favorites never becomes the favorites type, unrated reviews, the deterministic winner.
- **Ratings**: the summary average ignores unrated reviews; the constraint rejects an empty review.
- **Replay**: agree, rule-certain relink, AI disagreement queued, author pair, applying the same
  verdicts twice leaves the same state, a rejected verdict suppresses its finding, the skip rule for
  failed imports.
- **BookPage parser**: a few saved Goodreads pages as fixtures, including a 404 and a challenge page.
- **E2E (Playwright)**: upload a small CSV and see the summary; approve as an admin.
- **Admin policy**: non-admins get 403/redirect on every new admin action.

## 15. Increments

Each has its own plan and PR.

1. **Optional review ratings** (§8). Independent; ships first.
2. **Provisional records** (§9): flags, `catalog` scope on every surface, index field and filter,
   `noindex` and alert. Nothing creates provisional records yet.
3. **Resolver core** (§3–5): parser, normalizers, the import/edition/row/provenance tables, edition
   resolution, importer options, advisory lock, and `books:goodreads:resolve_file[path]`, a dry-run
   rake that prints decisions for a local CSV.
4. **Goodreads fetcher** (§6): measure ~20 real pages first; then `BookPage`, the page cache, HTML
   storage, the throttled capsule and breaker, the legacy seed.
5. **Legacy replay** (§12.1–12.7, 12.9): loader, fix-ups, compare, duplicates, junk, verdict ledger and
   admin queue, report. Auto-apply off. Runs in production after the Proxmox deployment.
6. **Member import** (§7, §10, §11): upload and job, WriteLibrary, summary page, admin approve /
   reject / bulk, email, E2E.
7. **Finishing failed legacy imports** (§12.8).

## 16. Non-goals and dependencies

**Non-goals**: scraping users' Goodreads shelves (the CSV export is the only input); creating
`Books::Edition` rows; Goodreads descriptions or genres; other services (StoryGraph, LibraryThing);
the Proxmox deployment itself; porting the legacy add-book modal (Goodreads URL, Amazon URL, title
and author), which is a separate, later project.

**Dependencies**: the replay (increment 5) and production verification need the Open Library
service and page fetcher deployed (Proxmox, Cloudflare Access, the fetcher's egress block). The
member import works without them: Open Library sources fail and flag, and creations are
`unverified`.

**Launch sequence additions**: after each books migration pass, run `books:goodreads_replay:load`
and the replay; never truncate `books_repair_verdicts`.
