# Books alternate titles

Every alternate title of a book is a row with a source, a status and, once the AI has looked at it, a
verdict. Titles that are not the same work are removed (marked, never deleted), and verification
findings that agreed only through a removed title are undone. Spec:
`docs/superpowers/specs/2026-10-23-alternate-titles-cleanup-design.md`.

## The table

`alternate_titles` is shared across domains: the model is the global `AlternateTitle`, with a
polymorphic `titleable`. Only books write to it today. Rows go with their record
(`dependent: :delete_all`; a polymorphic link cannot carry a foreign key). The AI review, the admin
card and the undo are books only. A domain that adopts the table must add
`has_many :alternate_title_records, as: :titleable, dependent: :delete_all` to its model, since the
polymorphic link has no foreign key to cascade.

- **Source:** `legacy`, `merge`, `ai_enrichment`, `admin`, `correction`. Where the title came from.
- **Status:** `kept`, `removed`, `review` (waiting for an admin). A new row is `kept`.
- **Review fields:** `verdict` (`same_work` / `not_same_work`), `category` (`translation`, `variant`,
  `fuller_title`, `short_title`, `other_work`, `volume_or_part`, `combined_edition`, `junk`),
  `confidence`, `reason`, `ai_chat` (the AI call it came from), `decided_by` (`ai`, `admin`,
  `correction`), `decided_by_user`, `decided_at`, `judged_at`, `undo_checked_at`.
- **Uniqueness:** one row per record and normalized title. `AlternateTitle.normalize` applies the
  name and quote normalizers, then lowercases; it is the same rule as
  `Services::Books::Verification::Check.normalize`, and a test keeps them in agreement. Two spellings
  that collapse to one are one row. A title equal to the book's own main title is never a row through the writer; the backfill keeps a legacy array element equal to the main title as it finds it.

`unjudged` rows are `kept` rows with no verdict that no admin or correction has decided (an admin's
keep or restore is a decision, and the AI never sees that row again). A removed row is never deleted: it is the record that
stops the title coming back.

## The array copy

`books_books.alternate_titles` stays, as a copy of the book's `kept` and `review` rows ordered by id.
Search indexing, the book page, the API, verification, the import finder, the author profile, the eval
export and the AI prompts still read it. A `review` title stays in the copy because it is not yet
judged wrong. The copy exists so none of those readers had to change; a later part of the spec (Part 4)
moves them to the table and drops the column. That waits for the unsure-books second-chance branch,
which touches the same verification readers.

The copy is rewritten explicitly by the writer after each change, not by a callback.

## Writers and the no-come-back rule

Everything changes titles through `Services::AlternateTitles::Writer`:

- `add(record:, titles:, source:)`: adds new titles. A title matching a `removed` row is skipped,
  unless the source is `admin` or `correction`, which reinstate it.
- `replace(record:, titles:, source:, user:)`: for `admin` and `correction` only. Titles left out of
  the list become `removed` ("removed by admin" / "removed by correction"); a removed title typed back
  becomes `kept`.
- `decide(row:, status:, user:)`: an admin keeps or removes one row; the AI verdict stays on it.
- `move(source:, target:)`: the merger. Rows move with their source, status and verdicts. Where both
  books hold a title, the target's row wins and `removed` on either side wins. The losing book's main
  title becomes a `merge` row unless the target has it removed.

Callers: the legacy migrator and weekly sync (`legacy`), the book merger (`merge`), AI enrichment
(`ai_enrichment`), the admin book form (`admin`, one input per title, so a comma inside a title is
safe), accepted corrections (`correction`), and `NormalizeStoredNames`, which rewrites a row's title in
place. A `removed` title is never added back by `legacy`, `merge` or `ai_enrichment`. Only `admin`
and `correction` may reinstate one.

`Services::AlternateTitles::Backfill` creates one `legacy` row per array element (idempotent, the array
is unchanged; blank and normalized-duplicate array elements are skipped). The writer calls it for a record first, so a book never backfilled is handled.

## The AI review

`Services::Books::AlternateTitles::Review` makes one AI call per book
(`AlternateTitlesReviewTask`, `fast` role). The call sees the book's title, subtitle, authors and first
published year, and the numbered titles. Long lists go in chunks of 40, always with the book's
details; titles already accepted are given as context. Results are keyed by number; a title the call
left out is asked once more, and any still missing stay unjudged for the next run. Every call runs
before anything is written, so a failed call leaves the book untouched.

Verdict handling, in one transaction with the array copy:

- `same_work`: stays `kept`, verdict recorded.
- `not_same_work` at or above `config.x.books_alternate_titles.auto_remove_confidence` (0.8, set in
  `config/initializers/books_alternate_titles.rb`): `removed`.
- `not_same_work` below it: `review`, waiting for an admin.
- Rows whose source is `admin` or `correction` are never removed automatically: `not_same_work` sends them to `review` whatever the confidence. (An admin accepted every correction; later decision, 2026-10-22, final review.)

Only unjudged rows get a verdict, so a recorded decision never flips. Titles added later by a merge,
enrichment or the sync arrive unjudged and are picked up when the review runs again.

`Books::AlternateTitles::ReviewJob` (Sidekiq, `low` queue, one per book, retries 3) runs a book. The
rake task queues it for a scope: ranked books first, by rank in the default primary configuration,
then the rest by id. A book whose rows all carry a verdict is not sent again, so the task is resumable.

## Admin: the card and the review page

- **Alternate titles card** on the admin book page (lazy, `Admin::Books::AlternateTitlesController#index`):
  every row with source, status, verdict, category, confidence, reason and a link to the AI chat.
  Review rows have keep and remove buttons, and kept rows a remove button; removed rows a restore button. Each records the admin and
  rewrites the array copy.
- **Review page** (`admin/books/alternate_titles/review`): every row in `review` across books, with an
  optional source filter, and the same keep and remove buttons.

Restoring a removed title sets it `kept` and leaves the AI verdict on the row, so the review never
sends it again.

## Undoing verification findings

The verification pass trusted identifiers when an edition's title agreed with the book's title or one
of its alternate titles. `Services::Books::AlternateTitles::UndoFindings` undoes stage 2 and 3
findings (`added` / `confirmed`, source `open_library` or `worldcat`) that agree only through a
removed title:

- Per book with a removed row not yet checked (`undo_checked_at` empty), a finding is undone when it
  agrees with the book's title plus all alternate titles but no longer with title plus `kept` and
  `review` titles. A finding that still agrees through anything else stays.
- An `added` identifier is destroyed, if the book still holds it with the same source; a `confirmed`
  one goes back to its `previous_source`. A finding whose identifier is held with another source is
  left alone (counted as "held with another source"). An apply run stamps every removed row of the book it judged, so a left-alone finding is re-judged only when another title on that book is later removed (which is exactly when the vouching finding can lose its agreement). "Left alone: N" is not retried by simply re-running.
- When the settled Open Library work agrees with the book only through a removed title (City of
  Ladies settled on the *Treasure* work), the book is listed under "wrong work" and its work key is
  not changed. The work's own title does not count as agreement for those books.
- Each undone finding keeps its row, marked `undone_at` and `undo_action`, and can be reversed.
- Only the rows judged are stamped `undo_checked_at`, so the step is idempotent and picks up newly
  removed titles when run again.

## Rake tasks

All in `web-app/lib/tasks/books/alternate_titles.rake`.

| Task | What it does |
| --- | --- |
| `books:alternate_titles:backfill` | Creates `legacy` rows for every array element. Idempotent. Prints `alternate titles: N rows created`. |
| `books:alternate_titles:review[scope]` | Queues the AI review. `scope` is `ranked` (default), `all` or a count. Prints the number of books queued. Writes (through the jobs). |
| `books:alternate_titles:report` | Read-only. Counts by verdict, category and source, with samples per category. |
| `books:alternate_titles:undo_findings` | Dry run: prints counts of books and findings checked, what would be undone, findings left alone, the wrong-work list and samples. Writes nothing. |
| `books:alternate_titles:undo_findings[apply]` | The same run, writing the undo and the `undo_checked_at` stamps. |
| `books:alternate_titles:undone_findings[book_id]` | Lists that book's undone findings (id, kind, type, value, source, undo_action, undone_at, evidence title), so each can be passed to `redo_finding`. |
| `books:alternate_titles:redo_finding[finding_id]` | Reverses one undone finding (recreates the identifier or resets its source). Aborts with the reason if it cannot, for example another book now holds the identifier as verified. |
| `books:alternate_titles:restore[row_id]` | Sets a removed row back to `kept`, AI verdict preserved. |

## Order, and what repeats

1. Deploy. 2. `backfill`. 3. `review[ranked]`, wait for the queue, `report`, hand checks. 4. `review[all]`.
5. `undo_findings` dry run, read by hand, then `undo_findings[apply]`.

`review` and `undo_findings` **repeat**: run both again after merges, the weekly sync, work on the
review page, accepted corrections, and in the final launch sequence. `backfill` is a one-off in
production (the writer backfills any record it touches). The production steps are in
`docs/launch-todo.md`, section 10. The unsure-books second-chance verification run follows this
cleanup.

## Proving it (dev rehearsal)

Snapshot dev first (`bin/snapshot-dev-db.sh --label pre-alternate-titles`), then review the ranked
books and hand-check:

- the known cases: City of Ladies, Catch-22, A Season in Hell, My Struggle, Don Camillo, and War and
  Peace's 66 titles;
- 50 random removals and 50 random keeps;
- every removal of a title in a non-Latin script.

Success is no real translation or variant auto-removed in the sample. If one is, raise the threshold
or send that category to review. Then run the `undo_findings` dry run and check its counts and samples
by hand before applying.
