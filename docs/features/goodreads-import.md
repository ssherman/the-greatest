# Goodreads import

Members will upload their Goodreads library export and get their shelves, dates, ratings and
reviews on the books site. The legacy app had this feature and it produced most of the legacy
catalog's bad data; this one is built so that it cannot. Spec:
`docs/superpowers/specs/2026-10-03-goodreads-import-design.md`.

## Status

| Increment | What | State |
|---|---|---|
| 1 | Optional review ratings | shipped |
| 2 | Provisional books and authors (`docs/features/books-provisional-records.md`) | shipped |
| 3 | Resolver core: parsing, tables, edition resolution, dry run | shipped |
| 4 | Goodreads page fetcher and verification | shipped |
| 5 | Legacy replay | shipped |
| 6 | Member upload, library write, admin approval | shipped |
| 7 | Finishing failed legacy imports | this doc |

Members import at `/my/goodreads-import` ("Member import" below). The dry-run rake and the legacy replay's rakes are
the other entry points.

## Parsing

`Books::Goodreads::ExportFile.parse(bytes)` decodes the file, parses it with liberal quoting, and
refuses it unless the `Book Id`, `Title`, `Author` and `Exclusive Shelf` headers are present. It
never refuses a row.

- Decoding: the BOM is stripped. A file that is UTF-8 apart from stray bytes stays UTF-8, with the
  stray bytes scrubbed. Anything else is read as Windows-1252, its undefined bytes dropped. NUL
  bytes are removed.
- A row whose field count differs from the header's (a stray quote split a field) is failed with
  "columns do not line up with the header". Nothing in it is read or stored, not even `raw`,
  because any value, Private Notes included, may sit under the wrong header.

`Books::Goodreads::ExportRow` reads one row by header name:

- The Goodreads id is the leading digits of whatever form it arrives in (`Books::GoodreadsId`).
- ISBNs are checksum-validated and converted both ways (`Books::Isbn`, the Rails twin of
  `data-sources/src/common/normalize.py`). An invalid ISBN is dropped.
- The title is kept whole. Only a trailing `(Series Name, #N)` is split off into
  `series_name`/`series_number`.
- Only the primary `Author` is an author. `Additional Authors` is passed to the matching AI as
  context, because Goodreads mixes translators and illustrators into it.
- A value that does not parse is dropped and recorded in the row's `notes`.
- `Private Notes` is never stored.

## Data model

- `books_goodreads_imports`: one per upload. A partial unique index allows one import in progress
  per user.
- `books_goodreads_editions`: the unit that is resolved, keyed by Goodreads id plus signature
  (digest of the normalized, series-stripped title and primary author). An edition is shared by
  every import that names it. A row claiming a real id under another title gets its own edition.
  `book_id` is nullified if the book is deleted; the book merger moves editions. Goodreads'
  "Binding" is stored as `book_format` (`binding` collides with `Kernel#binding`).
- `books_goodreads_import_rows`: one per CSV row, with the user's fields, `notes`, and later the
  ids it wrote.
- `books_goodreads_import_records`: provenance. Every book, author, book_author and identifier an
  import created.

Editions reference `books_books`, so truncating books for a migration pass empties them too. That
is intended: the replay rebuilds them.

## Resolution

`Services::Books::GoodreadsImports::ResolveImport` resolves each distinct edition once, through
`ResolveEdition`:

1. **Cache.** An edition already resolved to a book that exists is reused.
2. **Finder.** The full books finder (identifiers, exact, OpenSearch, Open Library, AI), with the
   edition as the match decision's subject. The finder does not filter provisional books, so a
   later import links to an earlier import's provisional book instead of making another.
3. **Outcome.** A match links. The finder flags medium, low and fallback decisions. No match
   goes to Goodreads verification (below). An AI "none of these" goes there too, and is flagged. Nothing falls back to the top search hit. A failed AI call (the finder's `fallback`
   decision) is not an answer: the edition is left unresolved for the next run, so an AI outage
   cannot fill the catalog with duplicates. A decision that does not end up as the edition's
   (the run failed, or another import resolved the edition first) is taken out of the review
   queue.

`CreateBook` holds `pg_advisory_xact_lock` on the edition's signature, re-reads the edition, adopts
a book that a same-signature edition created since the finder looked (never one the finder already
considered), and otherwise creates through `DataImporters::Books::Book::Importer` with:

- `match:` the finder's match, so the finder and the AI run once;
- `provisional: true`, for the book and any author it creates;
- `stamp_identifiers: true`, so the edition's Goodreads id and ISBNs are on the book even when Open
  Library is down;
- `enrich: false`, because enrichment runs on admin approval ("Member import" below).

A book that comes out of the importer with no author is rolled back (`CreateFailed`) and the
edition retried later: an authorless book cannot be found by any later author-aware search.

Counters (`matched`, `created`, `flagged`, `parked`) are recomputed from state after each run, so a
retry is safe. `ai_calls_count` counts calls as they happen. Matching AI is not capped. A failing
edition records its error on its rows and stays unresolved for the next run; Postgres errors
re-raise.

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
  `daily_fetch_cap` (1,500), each fetch counted against the day it starts on, so a line that runs
  past midnight fills the next day's cap. A job waits for its turn by rescheduling itself, and a turn that came
  due late (after a deploy or a slow fetch) still waits out `fetch_interval` since the last fetch
  actually began. A page with no title or no contributors is unparseable, never found. A 403, a challenge or
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
  provisional book created unverified, and for editions stuck waiting longer than a full day's
  fetch line (cap × interval, about 6.25 h) plus an hour. An edition whose created book was since
  deleted is left alone: the next resolution sends it back to the finder. A later
  `not_found` or `mismatch` is recorded on the edition and shown on the import's admin page
  (Created tab, verification column). The book is not touched.

An import waiting on pages sits in `verifying` until they settle ("Member import" below).

## Member import

Spec §7, §10, §11. A signed-in user (any account, not only paying members) uploads their export at
`/my/goodreads-import`, linked from the My Books menu.

**Upload.** `ValidateUpload` refuses, before any import row exists:
- a missing file, or one over 10 MB;
- anything that is not a Goodreads export with rows (an xlsx renamed `.csv` included);
- an upload while the user has an import in progress (also a database index);
- a fourth member import in 24 hours.

Settings are in `config/initializers/goodreads_imports.rb`. `StartImport` stores the file on `private_imports` and
queues `Books::Goodreads::RunImportJob`.

**The run** (`Services::Books::GoodreadsImports::RunImport`) goes parse → resolve → verify → write → complete.
- Every phase can run again. The run claims the import with a conditional `UPDATE` from `queued` or `verifying`, so
  however many triggers ask for a run, only one does it.
- An import with editions waiting on Goodreads stops in `verifying`. `SettleEditionsJob` resumes it once nothing it
  names is pending, and the verify sweep resumes any whose resume was lost.
- A failure fails the import with its error. The admin page's Rerun puts the unwritten failed rows back to pending
  and runs it again.
- Each member import, complete or failed, sends `AdminMailer#goodreads_import_finished` to `notify_to`
  (contact@thegreatestbooks.org).

**WriteLibrary** writes in bulk under the user's row lock, the lock the list-item controller takes.
- Shelves:
  - `read`, `to-read` and `currently-reading` go to the default lists.
  - Every other shelf goes to a custom list, matched case-insensitively with hyphens read as spaces. A `favorites`
    shelf is a custom list, never the favorites list type.
  - A read book leaves the reading list, and Date Read is never replaced with today.
- Items are appended in shelf-position order, with `created_at` set to Date Added.
- An existing item only has a blank `completed_on` filled. The same file twice writes nothing, and its rows come
  back `skipped` ("already on your lists").
- One review per book is written: rated row first, then the latest read, then the lowest row number. Goodreads
  `<br/>` becomes newlines, and the user's existing review is left alone. Summaries are recalculated once per book.
- The user's public goal pages are purged once, when a completion date changed.
- Each row's `applied` holds the list item ids and the review id it wrote.

**Admin: Books → Goodreads Imports.**
- The index filters by source (member by default), status and review status. It marks imports in progress past
  2 hours as stuck, and has Approve selected.
- The show page has four tabs:
  - Created: books and authors, with each edition's verification and its match decision;
  - Flagged decisions;
  - Parked rows;
  - Raw rows.
- Gates, as Repair Verdicts: approve, promote and rerun need write access; reject, delete and an approve that
  unticks records need delete access.
- **Approve** (`Approve`, `PromoteRecords`):
  - It deletes unticked records the import created, when nothing else uses them.
  - It promotes every provisional book the import created or its rows point at, with the book's provisional authors,
    then queues enrichment. A book credited to a newly promoted author waits for that author's chain, as the importer
    does.
  - Promotion also purges the records' cached show pages (which carried `noindex` and the notice) and the public goal
    pages of the book's readers. It regenerates the users' favorites list when a promoted book is on anyone's
    favorites.
- **Reject** (`Revert`):
  - It deletes the list items and reviews in `applied`, plus the provisional books and authors the import created
    that no other import, list, review or curated list uses.
  - It removes stamped identifiers, recalculates summaries and purges goal pages.
  - It does not restore a reading item a read row replaced, or clear a date it filled.
  - A stuck import is failed as it is rejected, freeing the member to upload again.
- Per record: promote, or delete while provisional (`DeleteProvisional`). It acts only on records the import created.
- Replay imports are listed but never approved, rejected or rerun here. A legacy import that failed or never
  finished is finished as a member import (below, "Finishing legacy imports"), and that one is approved here like an
  upload. Its page says which legacy import it finishes.

Provisional books show normally to their importer and are hidden from everyone else's view of the user's lists (spec
§9, `Books::UserList.catalog_items`).

E2E: `e2e/tests/books/account/goodreads-import.spec.ts` and `e2e/tests/books/admin/goodreads-imports.spec.ts`, with
`e2e:goodreads_import_seed` / `e2e:goodreads_import_cleanup`.

### Legacy seed

    bin/rails books:goodreads:seed_legacy_pages

Loads the legacy app's scraped `goodreads_books` rows into the cache as found pages with
`source: legacy` and no HTML. There are about 12k page lookups and 27k search results; the
export-derived rows are skipped. The legacy writers merged translators, illustrators and an export
row's own author into one `authors` array, so every legacy name has no role: any of them backs an
edition, and only the one that agreed becomes an author. A cached id is never overwritten, so the
task can run again after each migration pass.

## Legacy replay

Spec §12. The legacy app's 803 imports are replayed against the new resolver to measure it and to find the bad data
legacy left behind. Every finding is a `Books::RepairVerdict` (`books_repair_verdicts`, no foreign keys, keyed by
preserved ids): **never truncate that table**, the launch sequence relies on it. Nothing changes the catalog except
`books:goodreads_replay:apply`, which refuses to run while `config.x.goodreads_replay.auto_apply` is false (the default).

A pass, after every books migration pass and in the launch sequence:

```bash
bin/rails books:goodreads_replay:load        # legacy imports, uploads (legacy R2, LEGACY_R2_*), rows
bin/rails books:goodreads_replay:fix_slugs   # 543 slug-form Goodreads ids -> strip_identifier (rule, approved)
bin/rails books:goodreads_replay:apply       # re-applies every approved verdict from earlier passes (gated)
bin/rails books:goodreads_replay:resolve     # queues pass one (low) and pass two (serial); re-run until both are 0
bin/rails books:goodreads_replay:duplicates  # one AI check per author name group, then the book-pair rule
bin/rails books:goodreads_replay:junk        # authorless books, books relinks leave unsupported
bin/rails books:goodreads_replay:apply
bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
```

- **Load** is slow the first time: about 2.5 hours on development for ~388k rows, because rows are written one at a
  time. Each upload is downloaded once and kept on the private bucket. A blob the legacy bucket no longer holds fails
  that import only.
- **Resolve** runs the books finder in `verify: true`. Pass one uses the fast sources, with Open Library's identifier
  lookup in place of `/resolve`. Pass two adds `/resolve`, only for editions pass one disagreed on or could not match.
  Each replay row gets a `replay_finding` (agrees, duplicate, disagrees, unmatched, no legacy choice). Legacy's
  choice is the book holding the row's Goodreads id that is on that user's lists. Matches that agree with legacy warm
  the edition cache; a disagreement does not, because it is a relink an admin may reject.
  The replay never creates books and never fetches Goodreads pages; it only reads cached ones.
- **Relinks are all AI-decided.** Measured 2026-10-05: under `verify: true`, legacy's book always holds the row's
  Goodreads id, and that hit blocks the exact-match rule for any other book. So no rule ever decides a disagreement.
  Relinks are proposed, and the admin queue approves them in bulk. A relink also moves the row's identifiers when
  legacy's book contradicts the row on title and author.
- **Authors** are grouped by name with punctuation and spaces removed, and each group gets one `fast` AI call that
  clusters it into people (`Services::Ai::Tasks::Books::GroupSameAuthorsTask`). A merge is auto-approved only when the
  AI is highly confident and there is no year or external-identifier conflict.
- **Books** in a pending duplicate pair are auto-merged only with an equal title, identical authors and a shared
  identifier. Every other pair stays in the Duplicates queue.
- **Junk:** an authorless book is auto-flagged provisional unless it is on a curated list, in which case it is only
  proposed: curated list pages are not filtered. Flagging uses `update!`, so the book is reindexed, and apply queues a
  ranking recalculation for every configuration that ranked it, plus the default one, which cascades to authors.
- **Admin:** Books → Repair Verdicts filters by kind, status, decider and confidence, approves or rejects, and approves in
  bulk. Approval never applies; the next `apply` does. Rejecting an applied `mark_provisional` reverts it. Rejecting an
  applied merge or relink undoes nothing now, but stops it being applied again after the next books re-migration.
- **A relink copies instead of moving** when another of the user's replay rows still names legacy's book: the right book
  is added beside it, and the legacy book keeps the item and the review. Junk detection treats such a book as supported.
- **Apply batches the follow-ups.** Merges run with `defer_rankings: true`, and one run queues each ranking
  recalculation, the favorites rebuild and the author rankings once, not once per merge.
- **Before auto-apply:** hand-check 50 auto verdicts per kind with `books:goodreads_replay:sample[kind]`, then set
  `auto_apply: true` in `config/initializers/goodreads_replay.rb`.

### Finishing legacy imports

Spec §12.8. `bin/rails "books:goodreads_replay:finish_legacy[limit]"` (`FinishLegacyImports`) runs each legacy import
that failed or never finished through the member pipeline. It makes a member import of the same user, linked by
`finishes_legacy_import_id`, from the upload `load` kept. Admins approve or reject it under Goodreads Imports, and the
user sees it in their import history. Run it after `load`. `DRY_RUN=1` lists what it would do; `IDS="73 285"` picks
imports.

- Legacy statuses are read live. An import is skipped when the user later completed a legacy import, or completed any
  upload here, since its file could bring back books they removed. Only the user's newest unfinished import with a
  readable file is finished.
- Rows the stalled legacy import already wrote came over with the data migration, and are skipped as already on the
  user's lists.
- **In production, run it on the final books migration pass only.** The list items and reviews it writes have no
  foreign key to books, so a truncate leaves them pointing at deleted provisional books. The re-migration resets
  the books id sequence, and later books take those ids. `docs/launch-todo.md` (section 2, item 8) says how to undo a
  rehearsal run before the truncate.
- A truncate that lists `books_goodreads_editions` and `books_goodreads_import_rows` empties an import's rows but keeps
  the import and its file. The next run restarts it, pending review again. One with rows has already run and is left
  alone. One an admin rejected stays rejected.
- `IDS=` only narrows what is started: a picked import still defers to a newer unfinished import of the same user.
- Each import fetches Goodreads pages for the books it would create, on the fetch line member uploads use. Run it in
  batches (`[5]`), and let each batch finish before the next: running imports are skipped, not counted.
- Measured on the 2026-10-05 development load (a dry run): 46 unfinished legacy imports. 10 have a later completed
  import, 12 have no file (missing from the legacy bucket, or not a CSV), and 1 has no Goodreads header. That leaves
  23, all stuck in `pending`, with 40,345 rows between them.

## Dry run

    bin/rails "books:goodreads:resolve_file[/path/to/goodreads_library_export.csv]"
    bin/rails "books:goodreads:resolve_file[/path/to/export.csv,USER_ID]"

Parses and resolves the file exactly as an import would, prints one line per edition (matched book,
created book, flagged reason, failed sources) and rolls everything back. A dry run fetches no Goodreads page: an unmatched edition whose page is
not cached reports "waiting for Goodreads verification". Open Library requests and
matching AI calls are real and are paid for. To reach the deployed Open Library service,
`web-app/.env` needs `OPEN_LIBRARY_SERVICE_URL` and the Cloudflare Access pair
(`CLOUDFLARE_ACCESS_CLIENT_ID`, `CLOUDFLARE_ACCESS_CLIENT_SECRET`); without them every decision
carries "sources failed: open_library" and is capped at medium confidence.
