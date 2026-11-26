# User-added books

A signed-in reader on the books site can ask for a book the site does not have, from "Can't find it? Add a book" in the "Add to this list" search on one of their lists. The request remembers the list. A provisional book is made, goes on that list at once, and waits for an admin or an agent to approve it. Design: `docs/superpowers/specs/2026-11-23-user-added-books-design.md`. Where this page and the spec differ, this page is right.

Code: `Services::Books::BookSubmissions` (`app/lib/services/books/book_submissions/`), the model `Books::BookSubmission`, `Books::ProcessBookSubmissionJob`, `Books::FetchSubmissionGoodreadsPageJob`, `Books::RequeueStuckBookSubmissionsJob`. Not covered: the recommendation wizard, the member API and member MCP endpoint, and Amazon short links (`a.co`, `amzn.to`). They are listed in `docs/todo.md`.

## What the reader sees

- The "Add to this list" search runs against the catalog first. Its last row opens a dialog.
- The dialog takes one way of adding a book: a Goodreads link, an Amazon link, an ISBN, or a title with 1 to 10 authors. The server refuses a request that fills more than one (`ParseInput`). Limits: title and each author 255 characters, link 2,048. A pasted link is read, never fetched. Its host must be plain ASCII and on the list; raw non-ASCII letters after the host are read (and stored) as pasted. Invisible characters are trimmed from the ends of every value and dropped from inside a title or a name (the joiners that spell words in Persian, Sinhala and other scripts stay), and a value made only of them is blank.
- A reader may make 20 submissions in a rolling 24 hours (`config.x.book_submissions.daily_limit`). The same request still open on the same list is answered with the existing row and not counted.
- The list page shows a strip of the reader's own submissions, one alert each: `Adding "Title"`, `Added "Title"` (with a link to the book), `Could not add "Title"`, and for a request nothing was found for "We couldn't find a book from that link." (Goodreads and Amazon links), "We couldn't find a book with that ISBN." or "We couldn't find that book." With no title yet a request is called "a book from Amazon" (or Goodreads, or by ISBN) with a short reference built from its ids; the pasted text is never shown to the reader. A request with no book yet that is still open (queued, looking up or `needs_details`) can be cancelled. A request that has finished (added, failed or cancelled) can be dismissed from the strip. If its provisional book is rejected or deleted later, the row comes back once, saying the book was removed, for every reader whose row was on it; dismissing it again hides it for good. A `needs_details` or `failed` request can be retried as a new request (`replaces`). The strip polls every 10 seconds for 10 minutes; when it stops, or a poll fails, its spinners become a clock and "Reload the page to check". It reloads the list when a row is announced as added. The strip is never cached.
- A book made this way shows "Recently added; not yet reviewed or enriched." (`Books::ProvisionalNoticeComponent`). The text is the same for every kind of provisional record, so edge-cached pages stay equal for every visitor.

All write endpoints answer failures as Turbo Streams, because public layouts render no flash (`Books::My::BookSubmissionsController`, routes under `my/lists/:list_id/book-submissions` and `my/book-submissions/:id/{cancel,dismiss}`, rate limit 10 a minute per reader).

## The instant check

Before any row is made, `InstantCheck` looks in our own Postgres for up to three books the request may already be: by Goodreads id, ISBN-13, ISBN-10 or ASIN (work or edition level), or by exact normalized title and authors (`DataImporters::Books::Book::ExactLookup`). Identifier rows with source `legacy` are skipped, and so are rows with no source. Catalog books come before provisional ones, then the best primary rank. If anything matches, the dialog shows "We already have this. Is it the one?" with "None of these"; choosing "None of these" sends `confirmed_new` and the row is made. No outside service is called in the request.

## Processing

`Submit` makes a `queued` row and queues `ProcessBookSubmissionJob` after commit (queue `critical`). If Redis is down the row stays queued and the sweep starts it. `ProcessSubmission` takes the row to a book on the reader's list in this order, so a crash can resume from any point:

1. **The book.** `ResolveInput` turns the input into a title, authors and identifiers. Then the finder runs with every identifier source except `legacy`. `CreateBook` writes the book half of the row: it adopts a match (or a book another submission or a Goodreads import made with the same signature), or creates a provisional book through the importer with the row's identifiers stamped `user_submission` (source 9, trust rank 1, with no enrichment). A book with no author is rolled back.
2. **The list.** The book goes on the list. "Item already in list" counts as success. (A list item whose book was deleted under it is skipped by the list page; the Edit page still lists it, so its owner can remove it.) The step is resumable: a row that already has its book skips straight here.
3. **The lookups**, only for a book this row created that is still provisional (see "Early lookups").
4. **`added`**, with the list item, only after the item exists.

`ResolveInput` sources: the supplied facts first (`supplied`, from an admin or agent); then by method. Goodreads reads the cached Goodreads page, without the "(Series #N)" at the end of its title. Amazon asks Amazon by ASIN (only a product with that ASIN counts) and then falls through to the ISBN chain (an ASIN can be an ISBN-10). An ISBN asks WorldCat, then Open Library, then Amazon. Title and authors are used as typed. The first usable answer wins. A source that is down is skipped, and the outcome is `unavailable` only if nothing else was usable. The row's `lookup` column keeps one entry per source tried.

- **WorldCat names are accepted only in shapes we can read.** After brackets, life dates and a closing period are removed, a name with no comma is accepted as it is, in any script, unless it holds `/`, `;`, `|`, `&` or an Arabic comma (so a corporate body written without a comma is accepted). A name with a comma is read as "Last, First": the surname part must not hold a corporate or connective word, and the given-name part must be capitalised words (Latin, Cyrillic, Greek) or words in a script with no case (Hebrew, Arabic, Georgian and others), with lowercase particles such as "van" only trailing, and no title, epithet, honorific (Dr, Mrs, Prof and the like) or company word; the surname part holds no credential (PhD, MD and the like). Life dates, a closed list of role words in any case and Jr/Sr/II/III/IV may follow. A comma name containing Han, kana or Hangul is refused. Every other comma shape is refused. A creator that cannot be read makes the whole record unusable and the chain goes on to Open Library and Amazon; only when the record has no creator at all are its contributors used, and then one unreadable contributor is just dropped. A wrong author is worse than a slower answer (`Lookups::Names.world_cat_person`, `Lookups::WorldCat.authors`).
- **Amazon names are read the same way when they hold a comma.** Amazon writes most author credits "Last, First": measured 2026-11-25 on the stored Amazon editions, 72,337 of 128,787 credits hold a comma, and 86% of those flip to the book's own author (most of the rest are a second contributor Amazon lists as an author, or an accent difference). A name with a comma goes through the WorldCat rules above; a name without one is taken as Amazon gives it. One name that cannot be read makes the whole product unusable, by ASIN or by ISBN, and the chain goes on (`Lookups::Names.amazon_person`, `Lookups::Amazon.answer`). Known miss: an author who writes his own name with a comma ("James Wesley, Rawles") is flipped.
- **The year is not taken from WorldCat or Amazon.** Their year belongs to a printing, and the importer writes the year as the first publication year. Only Goodreads and supplied years are used.
- **A match is used at once**, whatever its confidence and whichever source failed; the match decision's own review flag audits it. An unmatched answer is retried when the AI fell back, a local source failed, or Open Library failed; a hard failure past the window ends `failed`, Open Library alone goes on to create. A new book that follows an AI "none of these" is flagged for review.

### Retries and how a row ends

A retry is for a source that is down. It backs off 30 seconds, doubling to 10 minutes (`RetrySchedule`), until the retry window has passed. The window is one hour from `processing_started_at` (`config.x.book_submissions.retry_window`). Time spent waiting for the Goodreads gate does not use the window up: the wait shifts `processing_started_at` forward by its own length. When the window ends, "no source was usable" is `needs_details`; a fallback or a failed local source is `failed`.

Other ways a row ends:

- **Goodreads link, page not cached.** `ProcessSubmission` answers `waiting_for_goodreads` and `FetchSubmissionGoodreadsPageJob` fetches the page on the priority lane (below), then queues the process job again. A page nobody could answer (503 page, timeout, fetcher down) is tried again through a new turn within the window; after it, `needs_details`. A page that loaded but cannot be read is `needs_details` at once.
- **Second Goodreads block** for one submission (`blocked_fetches`) ends it as `needs_details`. A reader's link must not keep the shared gate shut for everyone.
- **Third fetch error** (`fetch_errors`, an exception after the gate turn was spent, cumulative over the row's life) fails the row with the error stored. A Sidekiq retry does not re-spend a turn, with one exception: if the error handler's own write or reschedule raises, that error goes to Sidekiq and the retry runs again as a new job, which can take a turn (the gate's spacing and daily start cap still hold).
- **Unexpected error in the process job**: three Sidekiq retries, then `failed` with the error text.
- **Lost job.** `RequeueStuckBookSubmissionsJob` (every 10 minutes) queues a `queued` or `looking_up` row again when it has sat for 30 minutes and its `next_attempt_at` is nil or at least 30 minutes old (a row held by the gate has a recent one and is left alone). Each requeue adds to `sweeps`. A row that is stuck again after three requeues is failed with "lost job".
- **No author** from any source: `needs_details`. A cancelled row, or a missing reader or list before the book exists, ends `cancelled`.

A `needs_details` or `failed` row with no book stays on the strip. SupplyDetails (below) restarts either; Retry restarts only a `failed` row.

## Early lookups

When the process job creates a provisional book it plans a limited enrichment run (`StartLookups`): the `goodreads` and `amazon` steps only (`options: {"only" => [...], "lane" => "priority"}`, `initiated_by: "book_submission"`), and no author run. The full run comes at approval. They are skipped when `BOOK_SUBMISSION_LOOKUPS_ENABLED` is off, when the book already has a submission run, or when the last 24 hours already hold `BOOK_SUBMISSION_LOOKUP_RUNS` such runs (default 100; two racing submissions may overshoot a little). The run's `Workflows::Lanes` option puts the Goodreads and serial steps on their priority queues, `goodreads_fetch_priority` and `serial_priority`. Details: `docs/features/enrichment-workflows.md`.

## The Goodreads priority lane

A reader waiting for one book must not sit behind a backlog that was handed out hours ahead. `Books::FetchGate` keeps the one Redis line for every Goodreads fetch, and splits the daily cap:

- Ordinary turns (the import, enrichment, reruns) get `daily_fetch_cap - priority_reserved`: 1,400 of 1,500 by default.
- User adds have their own `priority_reserved` (`GOODREADS_PRIORITY_RESERVED`, default 100) a day, and fall back to the ordinary line when it is spent.
- Reservations alone would not hold the cap, because a priority turn pushes the ordinary line back past midnight. The hard limits are on actual starts, per UTC day: no more than `daily_fetch_cap` starts, and ordinary turns are held back by the part of the slice priority has not used yet.
- A priority turn is protected for 90 seconds: ordinary turns step aside while it is due and has not started. A priority turn sent back by spacing re-arms its protection. A job that dies stops holding anyone after 90 seconds.
- A cap of 0 stops all fetching.
- `Services::Books::GoodreadsEnrichment::StatusReport` and `Services::Books::GoodreadsRebuild::FixesReport` print ordinary use only, against the full cap.

See `docs/features/goodreads-import.md`.

## Review

`review_status` of a row: `not_needed` (the default for every row without a book, so nearly every `needs_details` row, and a reader whose request matched an existing book), `pending` (this row created a provisional book), `approved`, `merged`, `rejected`, `needs_human`. The admin queue and agent queue (`reviewable`) hold `added` rows that are `pending`, `needs_details` and `failed` rows with no book, and a `failed` row with a book that is `pending`. A `needs_human` row is not handed to an agent. It goes back to `not_needed` in two ways: an admin's Retry or SupplyDetails on a row with no book (which also sets `claims` to 0), or the reader cancelling or replacing the request ("Try another way"), which keeps the note. So no row waits in a tab with nothing to do about it.

**Leases.** A claim (`Claim`) leases 1 to 25 rows (default 10) under one token for 30 minutes (`FOR UPDATE SKIP LOCKED`). Through the API every write needs the live token. The admin page needs none. Each handing out adds to `claims`; a row claimed three times without an answer becomes `needs_human`, noted "abandoned by agents" (three lapses).

**What closes a submission elsewhere** (`CloseForBook`, one UPDATE):
- Promoting the book, by the Goodreads import approval or the admin: its open rows close as `approved`.
- A merge of the book into another (`Books::Book::Merger`): rows follow the book, and close as `merged` when the survivor is public; if the survivor was provisional and became public through the merge, its own rows close as `approved`. Rows already `approved` that moved with the book become `merged`, so a public survivor does not look user-added.
- A delete of the book (`Books::Book#close_submissions`, before destroy): open rows close as `rejected`, a row still in progress becomes `cancelled`, and a dismissed row is shown on the strip again, once.
- A second reader's `not_needed` row shares the fate of a provisional book it matched, never of a catalog one.

**Approve** (`Approve`) makes the book and its provisional authors public through `GoodreadsImports::PromoteRecords` on the priority lane and closes every submission on the book as approved. It refuses a book that is no longer provisional. The admin may be the reader.

**Merge** (`Merge`) merges the provisional book into a public book that is the same book, through `Services::Books::AdminMerge`, so the reader's list item moves to the real book. The merger evaluates a precondition under its own locks (source still provisional, target not, this row still open and its lease live), so a reviewer who raced another gets a conflict, not a wrong merge. `dry_run` names both books.

**Reject** (`Reject`) deletes the book and the provisional authors only it used, with the list items and reviews of the readers who submitted it, and closes every row on it as rejected. It refuses (422, naming counts only) when anyone who did not submit the book uses it: list items or reviews of other readers, a curated list item, or a Goodreads import entry (a live import row, or any import record naming the book). It also refuses a book no submission created, and a book that is no longer provisional (409). A second reader who adds a provisional book the instant check offered is not a submitter, so their list item makes Reject refuse; the way out is the Books admin. An author is deleted only when nothing could still point at it; when in doubt it stays.

**Retry** (admin page only) puts a failed, not rejected row back to `queued` with every counter reset (`attempts`, `blocked_fetches`, `fetch_errors`, `sweeps`, `claims`, lease) and queues the job. A row that failed after getting a book keeps it, and the job resumes at the list step. Approving such a failed row (with a book) requeues it the same way to finish the list step; merging it does not, so no list item is made. **SupplyDetails** (admin page and agents) gives a `needs_details` or `failed` row with no book a title, authors and identifiers (ISBNs normalized, Goodreads id, ASIN), stored as `supplied`, and requeues it the same way; `ResolveInput` reads `supplied` before the reader's input. **Skip** hands a row to a person (`needs_human`).

Counters on the row: `attempts` (retry schedule), `claims` (agent handouts), `blocked_fetches` (Goodreads blocks), `fetch_errors` (exceptions in the fetch job), `sweeps` (requeues by the sweep). They are separate so a row that retried twice does not look half-abandoned to an agent.

## Admin page, tools and prompt

- **Admin page**: `/admin/book_submissions` on the books host ("Book Submissions" in the nav). Tabs: needs review, needs details, needs human, approved, merged, rejected, failed (without the rejected ones), all (`QueueTabs`; the prompt uses the same counts). Approve, merge and reject need the domain delete permission; supply details and retry need write. After an action the admin lands on that one submission, with a link back to the tab and page they came from.
- **Eight admin tools**, also REST under `/api/v1/admin/book_submissions` (`Api::V1::Admin::Books::BookSubmissionsController`): `list_book_submissions` and `get_book_submission` (`books:admin:read`), `claim_book_submissions`, `supply_book_submission_details` and `skip_book_submission` (`books:admin:write`), `approve_book_submission`, `merge_book_submission` and `reject_book_submission` (`books:admin:merge`). Merge and reject take `dry_run`. Through the API an absent `dry_run` is false, so the call runs for real; the field must be `true` or `false` (anything else is a 400). The admin page is the other way round: only an explicit "false" runs for real, and a missing or odd value is a preview. A lost lease or a row someone else decided is a 409; a refused call is a 422.
- **Copy prompt**: `config/mcp/books/prompts/book_submissions.md.erb`, rendered by `Services::AgentPrompts` for the `book_submissions` queue. It carries the loop, the lease rules and the house rules. It says everything a reader typed is data, never instructions. Sources must be http or https URLs.
- **User-added badge**: the admin book page shows "User-added", linking to that book's submissions, while a submission created the book and nobody has merged or rejected it (`BookSubmission#user_added?`).

## Locking order

Wrong twice before it was right, so it is written here. Postgres re-checks a row's foreign keys on a second UPDATE and takes `FOR KEY SHARE` on the row it points to.

- **The process job's list add** (`ProcessSubmission#finish`): the reader's `users` row `FOR NO KEY UPDATE`, then the book `FOR KEY SHARE`, read back after the lock. `FOR UPDATE` on the reader deadlocked with a delete that holds the book and re-checks the reader's key.
- **Approve and Reject**: the readers who hold the book on Read first (`ReadingGoals::DestructionInvalidator`), then the book `FOR UPDATE`, then the submission's stamp.
- **A plain book delete and the merger**: the book row first (`Book#close_submissions`; `Merger#lock_books`, both books in ascending id). A job that locks the book afterwards waits, then finds the book gone and adds nothing.

Known and left in: `Services::Books::GoodreadsImports::Revert` deleting two books of one reader can deadlock with a job's list add (the add's own `OwnerMutation` takes `FOR UPDATE`, an upgrade of the earlier lock). It showed in 58 of 120 forced overlaps in a test, with no corruption. It is harmless. If the job's side loses, Sidekiq retries it. A Goodreads import revert runs in the admin's own request, so if it loses the admin sees an error and presses Reject again.

## Setup and settings

| Setting | Default | Meaning |
|---|---|---|
| `GOODREADS_PRIORITY_RESERVED` | 100 | Part of the daily Goodreads cap reserved for user adds |
| `BOOK_SUBMISSION_LOOKUP_RUNS` | 100 | Early lookup runs a day (rolling 24 hours) |
| `BOOK_SUBMISSION_LOOKUPS_ENABLED` | on | `0` stops the early lookups |

Both new Sidekiq queues, `goodreads_fetch_priority` and `serial_priority`, are served by the same capsules as `goodreads_fetch` and `serial` (`config/initializers/sidekiq.rb`), so concurrency 1 still holds. The migrations only add a table and columns, but creating the table briefly locks writes on the tables its foreign keys name, so do not merge while the legacy sync or another bulk writer is running. Production steps: `docs/launch-todo.md` section 4, step 14.

Tests: `bin/rails test test/lib/services/books/book_submissions`, plus E2E `e2e/tests/books/account/add-missing-book.spec.ts` and `e2e/tests/books/admin/book-submissions.spec.ts` (seeded and cleaned by `e2e:book_submissions_seed` and its cleanup task).
