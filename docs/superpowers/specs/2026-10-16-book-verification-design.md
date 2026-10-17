# Identifier provenance and the book verification pass

**Status:** design, approved in conversation 2026-10-16 · **Branch:** `worktree-identifier-provenance-backfill`

## Why

The Goodreads legacy replay was paused on 2026-10-14 after wrong merges, and a rebuild is being
designed (`docs/todos/goodreads-import-accuracy.md`). Its matcher has to ignore every identifier
legacy attached and trust only identifiers a verified source tied to the book. Today identifiers
carry no provenance at all. On the development database the books hold 197,106 Goodreads ids,
218,243 ISBN-10s, 169,412 ISBN-13s, 79,123 ASINs and 80,793 EAN-13s, all from legacy, and none of
them can be told apart from a checked one.

Shane does not trust any of them: the early Open Library links were never AI-checked, legacy later
stopped populating identifiers, and data from after the Goodreads imports feature (2024-09-09) is
trusted even less.

This spec does two things:

1. **Provenance.** A `source` on every identifier. Everything that exists today is `legacy`.
2. **One verification pass per book.** It settles the book's Open Library work, takes the identifiers
   that work's editions tie to the book, confirms held legacy ISBNs against WorldCat, and records
   signals (lumps, omnibuses, wrong identifiers, duplicates) for later specs to act on.

The pass absorbs the Open Library key backfill (`books:ol_backfill`, spec
`2026-10-07-ol-key-backfill-design.md`, PR #366). That tool was built and never run in production;
its logic becomes stage 1, and its tasks are retired. Looping over the catalogue once, with one log,
one report and one revert, is the point: this runs for days on the ranking and weeks on the rest.

## Decisions (from Shane)

- One `legacy` value for every existing books-domain identifier. No `legacy_import` /
  `legacy_amazon` / `legacy_other` split.
- **Identifiers only, at work level.** `books_editions` is not populated; a later task can build
  editions from the identifiers.
- Trusted identifiers come only from Open Library editions whose **title agrees** with the book.
  Translations and other non-agreeing editions are kept as **candidates**, outside `identifiers`,
  for a later AI spec that promotes them to identifiers and `alternate_titles`.
- A held legacy identifier that Open Library or WorldCat confirms has its source **changed in
  place**; the old source is logged for revert.
- **Goodreads ids** from agreeing Open Library editions are written too.
- **Ranked books first**: every book in the default primary `Books::RankingConfiguration`, in rank
  order (21,390 on dev). The rest of the catalogue is optional, later.
- Books created by legacy **after the Goodreads imports feature** are held back behind a flag until
  the Goodreads rebuild has repaired them.
- **One process**, not an Open Library backfill plus an identifier backfill.
- Lumps, omnibuses, wrong identifiers and duplicates are **detected and recorded only**. Acting on
  them is later specs.

## Measured (development database, 2026-10-15)

- **Legacy timing cannot recover provenance.** Legacy `goodreads_imports.updated_at` keeps moving
  for up to 664 days, so 99.7% of legacy `book_identifiers` fall inside some import's
  created-to-updated window. The new app cannot use time either: the migrators give every row a
  fresh id and `created_at` (`IdentifierMigrator#upsert_identifier`), and a value present in both
  `book_identifiers` and an edition's Amazon jsonb collapses to one row.
- Legacy `book_identifiers` are almost all Goodreads-import stamps: Goodreads id, ISBN-10 and
  ISBN-13 written together in the same bulk days. The work-level ASINs and EAN-13s came from legacy
  `editions.identifiers` (Amazon).
- **Ranked books by legacy creation date** (all 21,390):

  | Legacy `books.created_at` | Books |
  |---|---|
  | before 2024-09-09 03:22:31 UTC (the first import) | 12,145 |
  | after it, no Goodreads import row on the book | 5,356 |
  | after it, before the earliest import holding a row for it | 2,489 |
  | after it, after that import started | ~1,400 |

- 15,137 ranked books hold an Open Library work key (unverified). The OL key backfill has never run
  on dev (0 log rows).
- **Open Library editions** (`GET /works/{key}/editions`, 4-5 s per work over the tunnel), random
  sample of 60 keyed ranked works: editions per work median 7, mean 67, p90 164, max 1,105;
  ISBN-13s mean 49, ISBN-10s 39, OCLC numbers 11, Goodreads ids 8. About 950,000 editions across the
  keyed ranked works; **36%** have a title starting with the work's title. Tail works carry fewer
  ISBNs in Open Library than we hold (rank 10,000: 1 against 4).
- **WorldCat single-ISBN route** (`GET /isbns/{isbn}`, home-server instance): about 2.7 s per ISBN.
  Records carry title, creator and year. Seen in the sample: " : a novel" subtitles, mojibake
  ("M©Øairt©Øin ©ØO Cadhain"), pre-publication placeholders ("Untitled ian rankin rebus novel"). The
  batch `/lookup` route returns no title or creator, so it cannot check identity.
- `books_editions` holds 148,296 rows, all legacy Amazon blobs migrated 2026-07-31; only admin pages
  and the Amazon enrichment read them.

## 1. Provenance

### The column

`identifiers.source`: a nullable integer enum with no default, `enum :source, {...}, prefix: true`.
Music and games rows stay `null`; their writers are not touched.

| Value | Written by |
|---|---|
| `legacy` | every legacy migrator (`BookIdentifierMigrator`, `BookWorkIdentifierMigrator`, `AuthorIdentifierMigrator`, `EditionIdentifierMigrator`, `EditionIsbnIdentifierMigrator`, all through `IdentifierMigrator#upsert_identifier`), the weekly `data_migration:sync`, and `Services::Books::EditionIdentifierBackfill` (legacy's stored Amazon blobs) |
| `open_library` | the verification pass; the book importer's Open Library provider (`apply_trusted`, `apply_candidate`); the author importer's Open Library provider |
| `worldcat` | the verification pass |
| `goodreads_import` | values copied from a Goodreads export row or page and attached by our own matcher: `QueryIdentifiers#populate`, `OpenLibrary#persist_query_identifiers`, `GoodreadsImports::CreateBook`, and the replay's `StripIdentifier` stamps |
| `amazon` | `AmazonEditionUpserter` (the live product API) |
| `wikidata`, `viaf` | author enrichment: `FactSheet#stamp` from `ApplyWikidata` / `ApplyViaf`, and `RestoreIdentifier` |

There is no `admin` value: no admin form writes identifiers today. It is added with the first one.
The e2e seed task sets `wikidata`.

### Trust

`Identifier.verified` is the scope `source: [:open_library, :worldcat]`. It is what the Goodreads
rebuild's matcher reads. The existing finders are unchanged and keep reading every identifier;
moving them onto `verified` is the rebuild's decision.

### Merges

`Books::Book::Merger#merge_identifiers` and `Books::Author::Merger` move rows as today. When both
records hold the same value, the row kept is the more trusted one: a `verified` source beats any
other, any non-null source beats `legacy`, and `legacy` beats `null`. A verified row is never lost
to a legacy duplicate.

### The one-time marking

A rake task, `identifiers:mark_legacy`, not part of the deploy migration (about 1.1M rows; a
failing deploy migration is an outage). In batches of 10,000 by id:

1. Every identifier with `identifiable_type` in `Books::Book`, `Books::Edition`, `Books::Author`
   (and `Books::Series`) and a `null` source becomes `legacy`.
2. If the OL key backfill's log has rows (it may have been started before this ships), the keys it
   wrote or confirmed become `open_library`: `new_key` and `duplicate_keys` on the book, the work key
   of a `confirmed` row, and the author keys in `author_changes`.

It prints counts per type and is safe to re-run. Between deploy and the task, a books-domain `null`
means `legacy`; `verified` never includes `null`, so nothing reads one as trusted.

## 2. One book

Every check compares against the book's `title`, `alternate_titles` and authors (names and
alternate names). These are the stage 1 checks of the OL key backfill (`OlBackfill::Check`):

- **Title agrees:** equal after the finder's normalization, or equal once a subtitle (text after the
  first ":") is dropped from one side, never both.
- **Author agrees:** a normalized name equal to one of ours; or equal once reduced to letters only
  (diacritics stripped, under four letters ignored); or, for Open Library, an author key one of our
  authors holds, or a name on the work's author records.

A book is processed only when its cohort is included in the run (section 4).

### Stage 1: the work

The OL key backfill's logic, unchanged and already measured on about 270 top books: the fast pass
(at most five held identifiers looked up concurrently, every hit on one work, the check agreeing),
then `/resolve` with the stored key as a hint, acted on only for an `accept` the check agrees with.
The outcomes are the same (`confirmed`, including `confirmed_on_abstain`, `updated`, `replaced`,
`keyed`, `removed`, `duplicate_pair`, `unsure`, `failed`, `reverted`), and so are the author keys,
the duplicate keys and the `Services::DuplicateCandidates::Flag` pairs. What changes:

- The work keys, duplicate keys and author keys it writes or confirms get `source: open_library`.
- Held legacy identifiers only find candidate works. They never decide.

### Stage 2: identifiers from editions

Runs when stage 1 settled a work: `confirmed` (including `confirmed_on_abstain`), `updated`,
`replaced` or `keyed`. Fetch `Client#editions(work_key)`. An edition **agrees** when:

- its title (with its subtitle) agrees with one of our titles or Open Library's work title, by the
  title rule above; and if agreement needed a subtitle dropped, the dropped text names no set
  (`SET_WORDS`: "box set", "boxed set", "collection", "omnibus", "trilogy", "volumes", "books 1";
  matched as whole words, case-folded). The list is deliberately narrow: "complete" or "series"
  would reject every "Complete and Unabridged" edition; and
- its `publish_year` is absent, or at least the book's `first_published_year` minus one (an edition
  cannot predate the work; one year of slack for date noise). A book with no
  `first_published_year` skips the year rule.

From agreeing editions, every value is normalized (`Books::Isbn.normalize` for ISBNs; invalid ones
dropped) and written at work level:

| Edition field | Identifier type |
|---|---|
| `isbn13` | `books_work_isbn13` |
| `isbn10` | `books_work_isbn10` |
| `oclc` | `books_work_oclc_id` |
| `goodreads` | `books_work_goodreads_id` |

For each value:

- **This book holds it as `legacy`** (or `null`, or `goodreads_import`): its source becomes
  `open_library`. Finding `confirmed`, with `previous_source`.
- **This book holds it as `open_library` or `worldcat`:** nothing.
- **Another book holds it as verified:** not written. Finding `conflict` with `other_book_id`.
- **Another book holds it, not verified:** written here as `open_library` (finding `added`), plus a
  finding `also_held` with `other_book_id`. The other book is not touched.
- **Nobody holds it:** written as `open_library`. Finding `added`.

Every non-agreeing edition becomes a row in `books_edition_candidates` (section 3): translations,
box sets, alternate and odd titles alike. The later AI spec sorts them.

Held ASINs and EAN-13s are never confirmed by this pass; they stay `legacy`.

*Amended 2026-10-17 (production 500)*: stage 2 also harvests up to 5 of the book's Open Library
duplicate work keys through the same edition rule, each only when its full title is the book's own
title (a leading article aside), an author agrees, and no other book holds it as its work key. The settled work can be a translation's (Cuckoo's Nest settled on the Spanish work),
and harvesting only it missed the main work's editions. A `reharvest` flag re-runs stages 2-4 for
done books that hold such a key; it is run once (`books:verify[500,reharvest]`), not routinely.

### Stage 3: WorldCat

Runs for every processed book whatever stage 1 decided, `unsure` included (our own title and
authors are what WorldCat is checked against). Take the book's ISBN-13s and ISBN-10s still not
verified after stage 2, normalize to ISBN-13, drop invalid ones, deduplicate, and look up at most
`MAX_WORLDCAT_ISBNS = 50` with `Client#record_by_isbn`. A record **agrees** when all three hold:

- **Title:** its title agrees with ours by the title rule, after lowercasing and dropping WorldCat's
  " : " subtitle form. *Amended 2026-10-17 (final review)*: the rule is stage 2's edition rule (a
  subtitle dropped from one side only, never both; a subtitle dropped from the record must not name
  a set), so "War and peace : boxed set" does not agree.
- **Creator:** its `creator` or one of its `contributors` agrees with one of our authors by the
  letters-only author rule, also accepting "Last, First" order.
- **Year:** its `year` is absent or at least our `first_published_year` minus one.

Outcomes for one ISBN:

- **At least one record agrees:** every held row of that ISBN (its ISBN-13 and its ISBN-10 form)
  becomes `worldcat` (finding `confirmed`), and the agreeing records' OCLC numbers are added as
  `books_work_oclc_id` with `source: worldcat` (finding `added`), unless already held as verified.
- **Records exist and every one disagrees on both title and creator:** finding `wrong_identifier`,
  with the records' OCLC numbers, titles, creators and years in `evidence`. Nothing is removed.
- **Anything else** (no record, or records agreeing on only one of title and creator): nothing.

Garbled records (mojibake) fail the check and so never confirm. Records disagreeing on only one
side are not evidence of a wrong identifier.

*Amended 2026-10-17 (rehearsal)*: `wrong_identifier` is not recorded for an ISBN Open Library lists
on any one of the book's non-set edition candidates, and a title does not count as disagreeing when
the record's full title contains one of ours on word boundaries and every other word is an edition
word or a number (complete and collected editions). Our titles are also tried without a
leading article (production 500: "Brothers Karamazov"). Recorded signal only; trust is unchanged.

### Stage 4: signals

*Amended 2026-10-17 (rehearsal)*: a foreign work titled like one of the book's edition candidates is
a known translation and is ignored, and a leading "the/a/an" is dropped from both sides of the title
comparison. Lump suspects are a candidate list for a later AI check, not a verdict.

Recorded, never acted on. The book's held identifiers that are still not verified, ISBNs and
Goodreads ids only, are looked up with `Client#identifier` (at most `MAX_SIGNAL_LOOKUPS = 20`, five
at a time). *Amended 2026-10-16 (planning):* the fast pass's answers are not reused, because a
resumed book runs stage 4 in a later run with no fast pass; a few repeated 0.2-0.6 s lookups cost
less than carrying them across runs. For each hit on a work that
is not the stage 1 work, not one of its duplicate keys and not a redirect of it, the work is fetched
in one `works_batch`:

- its title disagrees with ours: finding `foreign_work`, with the work key and title in `evidence`;
- its title agrees: nothing (an unmerged Open Library duplicate of the same book).

A book with `foreign_work` findings on **two or more distinct works** is a **lump suspect**
(`lump_suspect = true`). This covers both shapes seen so far: "X Men" holding several volumes'
identifiers, and the Lagerlöf omnibus holding its novellas' ISBNs. Telling a lump from an omnibus
is the later spec's job.

When stage 1 did not settle a work, there is no work to exclude: every hit is judged by the same
title rule alone.

`duplicate_pair` stays as stage 1 flags it, through the Duplicates queue.

## 3. The log

### `books_verifications`

The OL key backfill's table, renamed: `books_open_library_backfills` → `books_verifications`,
model `Books::OpenLibraryBackfill` → `Books::Verification`, code `Services::Books::OlBackfill` →
`Services::Books::Verification`, job `Books::OpenLibraryBackfillJob` → `Books::VerificationJob`.
The rename keeps any rows. `outcome` is renamed `work_outcome`; every other column keeps its
meaning. New columns:

| Column | Notes |
|---|---|
| `cohort` | enum `pre_import`, `post_import` (section 4), set when the row is created |
| `stage` | enum `work`, `identifiers`, `worldcat`, `signals`, `done`: the next stage to run |
| `stage_error` | text: why the stage stopped |
| `added_count`, `confirmed_count`, `candidate_count`, `wrong_count` | integers, for the report |
| `lump_suspect` | boolean, default false, indexed |
| `worldcat_dump_date` | string, from the WorldCat `/version` |
| `checked_at` | when stages 2-4 last ran (for `recheck`) |

`book_id` stays unique. One run at a time stays (the session advisory lock). The row is written when
stage 1 ends, as today; `stage` then becomes `identifiers` when stage 1 settled a work and
`worldcat` otherwise. Each later stage commits on its own: its writes and its findings in one
transaction, then `stage` advances. A stage stopped by
a service failure leaves `stage` where it was and records `stage_error`; the next run resumes at
that stage and never repeats the earlier ones. Stage 1 failing behaves as today (`work_outcome:
failed`, retried).

### `books_verification_findings`

One row per identifier the pass wrote, changed or flagged.

| Column | Notes |
|---|---|
| `verification_id`, `book_id` | foreign keys |
| `kind` | enum `added`, `confirmed`, `conflict`, `also_held`, `wrong_identifier`, `foreign_work` |
| `identifier_type`, `value` | the identifier |
| `identifier_id` | the row written or changed (`added`, `confirmed`); nullable |
| `source`, `previous_source` | what the pass set, and what it was (`confirmed`) |
| `other_book_id` | `conflict`, `also_held` |
| `work_key` | `foreign_work` |
| `evidence` | jsonb: the Open Library edition key and title, or the WorldCat records (OCLC, title, creator, year), or the foreign work's title |

Unique on (`verification_id`, `kind`, `identifier_type`, `value`), so a re-run upserts instead of
duplicating. Indexed on `kind` and `book_id`. About 500k rows for the pre-import ranked books.

### `books_edition_candidates`

One row per non-agreeing Open Library edition, for the later AI spec.

| Column | Notes |
|---|---|
| `book_id` | foreign key |
| `edition_key` | Open Library edition key |
| `work_key` | the work it came from |
| `title`, `subtitle`, `language_code`, `publish_year` | from the edition |
| `identifiers` | jsonb: `isbn13`, `isbn10`, `oclc`, `goodreads` lists |

Unique on (`book_id`, `edition_key`). About 500k rows for the pre-import ranked books. No status
column: the AI spec adds the one it needs.

### Revert

`books:verify_revert[<book id>]` does what `books:ol_backfill_revert` did for keys, then deletes
every identifier with an `added` finding, sets every `confirmed` one back to its
`previous_source`, deletes the book's findings and candidates, and marks the row `reverted`
(`work_outcome`). A reverted book is never redone. Identifiers changed since by something else (a
merge moved one, an admin deleted one) are skipped and counted.

### Merges

`Books::Book` gains `has_one :verification` and `has_many` for findings and candidates,
`dependent: :delete_all`, and `Books::Book::Merger` deletes the merged-away book's rows. Findings
whose `other_book_id` is the merged book are deleted too. The identifiers the merge moves keep
their source.

## 4. Running it

### Cohorts

A book's cohort comes from its id:

- `post_import`: legacy `books.created_at` on or after `2024-09-09 03:22:31 UTC`.
- `pre_import`: everything else, including books not in legacy at all (created in the new app).

*Amended 2026-10-16 (planning).* Legacy book ids are strictly monotonic with `created_at`: the first
book created at or after the cutoff is id 16,572, no book below it was created after the cutoff, and
none above it before. Book ids are preserved by the migration, and new-app books start at the reserved
ceiling (`Services::BooksMigration::RESERVED_CEILINGS["books_books"]`, 250,000). So
`post_import` is exactly `16_572 <= id < 250_000`, a constant, and the run needs no legacy query.

The default run takes `pre_import` books only. The 9,245 `post_import` ranked books run only with
the `post_import` flag, after the Goodreads rebuild has repaired their titles and authors (or
earlier, if Shane decides spot checks look fine).

### Rake tasks

These replace `books:ol_backfill`, `books:ol_backfill_report` and `books:ol_backfill_revert`.

- `bin/rails "books:verify[<count>|all]"` queues one `Books::VerificationJob` (queue `low`,
  `retry: false`) and prints its run id. Optional flags after the count, in any order:
  - `post_import`: include `post_import` books.
  - `unranked`: continue past the ranking into the rest of the catalogue.
  - `retry_unsure`: as before, retry `unsure` rows whose Open Library `dump_date` or
    `matcher_version` is older than the service's `/version`.
  - `recheck`: re-run stages 2-4 for `done` books holding a `legacy` identifier created after the
    row's `checked_at` (the weekly sync keeps adding them until cutover).
- `bin/rails books:verify_report`
- `bin/rails "books:verify_revert[<book id>]"`

### Order

Ranked books (the default primary `Books::RankingConfiguration`) by rank, then, with `unranked`, the
rest by number of lists (descending), then id. A book is taken when it has no row, when its row
stopped at a stage (`stage` not `done`) or failed, or under `retry_unsure` / `recheck` as above. The
limit counts books, and rows carrying the run id count toward it, so a requeued run carries on.

### Errors and sharing

The OL key backfill's rules, extended to WorldCat:

- An error about one book (HTTP 400 or 422, an unparseable response) stops that book at its stage
  with `stage_error`, and the run continues.
- Any other service error (network, timeout, 5xx, busy, 401/403/429, breaker open) retries in place
  after 15, 30, 60, 120, 240 and 300 s. If it still fails, the book stops at its stage and the run
  stops.
- After a book that went through `/resolve`, the run waits 4 s (`RESOLVE_PAUSE`) so other callers
  get the single slot. Stages 2-4 never call `/resolve`.
- A WorldCat 504 (the service's 25 s deadline) on one ISBN counts as no answer for that ISBN; the
  book completes stage 3. *Amended 2026-10-17:* deadline raised to 25 s (was 5 s), and the Rails
  client timeouts to 30 s.
- WorldCat gets no pause: nothing else uses its single-ISBN route. The genre backfill uses the batch
  route.

### Speed (estimated; the before-merge measurement replaces it)

Per book: stage 1 about 4-12 s, editions 4-5 s, WorldCat about 7 s (two or three unconfirmed ISBNs at
2.7 s), signals about 2 s, so 20-28 s. Ranked `pre_import` books: 3-4 days. The whole ranking with
`post_import`: about a week. The unranked catalogue: 6-7 weeks.

### The report

`books:verify_report` prints:

- counts by cohort and stage, and by `work_outcome`;
- identifiers on ranked books by type and source, verified against `legacy` (the coverage the
  Goodreads rebuild cares about);
- findings by kind, lump suspects, candidates;
- the latest run's progress and its last stage error;
- the OL backfill's existing lists of the 20 most recent `replaced`, `removed` and `duplicate_pair`
  books;
- **a random sample** of 10 books per `work_outcome`, 10 WorldCat confirmations and 10
  `wrong_identifier` findings, each with our title and authors beside Open Library's or WorldCat's.
  This is how the quiet outcomes get checked, not only the risky ones.

## 5. Increments

1. **Provenance** (section 1). The column, every books writer setting it, `Identifier.verified`,
   the merger rule and `identifiers:mark_legacy`. Useful on its own; the Goodreads rebuild can build
   against it.
2. **The verification pass** (sections 2-4). The rename, stages 2-4, the two new tables, the
   report, revert, merger cleanup and the job's flags. If the plan finds it too large, stage 4 splits
   off as a third increment.

## 6. Testing

Minitest, with the Open Library and WorldCat clients stubbed.

- **Increment 1:** each writer sets its source; `mark_legacy` marks only books-domain `null` rows,
  labels the OL backfill's keys `open_library`, and is safe to re-run; `Identifier.verified`; a merge
  keeps the more trusted duplicate for books and authors.
- **Stage 2:** edition agreement, including a set-naming subtitle that fails and the year rule;
  confirm, add, `conflict`, `also_held`; candidates for non-agreeing editions; only settled work
  outcomes trigger it; invalid ISBNs dropped.
- **Stage 3:** title, creator (including "Last, First") and year agreement; WorldCat's " : a novel"
  form; a mojibake record never confirms; no record changes nothing; one-sided disagreement is not
  `wrong_identifier`; the 50-ISBN cap; an ISBN-10 row confirmed through its ISBN-13.
- **Stage 4:** `foreign_work`, an agreeing-title other work ignored, the lump threshold, the
  20-lookup cap, reuse of fast-pass answers.
- **Running it:** resuming at a failed stage without repeating earlier ones; revert, including a
  moved identifier skipped; job order with cohorts and each flag; `recheck`; the report's sections;
  rake argument parsing; merger cleanup.
- **Fixtures** carry a negative class for every check: a box set, a translation, the same title by
  another author, an edition dated before the work.

No E2E: there is no new page.

**Before merging increment 2,** on a snapshot of the dev database
(`bin/snapshot-dev-db.sh --label pre-verification`):

1. Run `books:verify[200]` against the live Open Library service and the home-server WorldCat
   (`WORLDCAT_SERVICE_URL=https://worldcat-api.thegreatestbooks.org`, Access pair from `.env`).
2. Run the report, and hand-check the risky lists and every sample.
3. Put the outcome mix, real per-stage timings and the hand-check in the PR. If confirmations are
   wrong more than rarely, stop and revisit the checks before merging.

## 7. Docs

- `docs/features/book-verification.md` replaces `docs/features/open-library-backfill.md`.
- `docs/features/worldcat-data-service.md`, "What this does not do": the identifiers increment now
  exists here, and box sets are kept out by the edition check, not by WorldCat fan-out.
- `docs/launch-todo.md`, replacing the `books:ol_backfill` item:
  1. deploy increment 1, then `identifiers:mark_legacy`;
  2. deploy increment 2, then `books:verify[200]` and the report, hand-checked;
  3. `books:verify[all]`;
  4. `books:verify[all,recheck]` after weekly syncs, and once more at cutover;
  5. `books:verify[all,post_import]` after the Goodreads rebuild has repaired those books;
  6. `unranked` when wanted.
- `docs/todos/goodreads-import-accuracy.md`: a short note on what the rebuild can read
  (`Identifier.verified`, findings, lump suspects, candidates).

## Out of scope

- Populating `books_editions`.
- The AI check of edition candidates, and adding translated titles to `alternate_titles`.
- Acting on any signal: marking omnibuses, splitting lumps, stripping wrong identifiers, merging
  duplicates.
- Moving the existing finders onto `Identifier.verified`.
- Confirming ASINs and EAN-13s.
- A WorldCat identity batch route (title and creator in `/lookup`); the single-ISBN route is enough
  for the ranking.
- An admin page for the pass; the report covers it.
