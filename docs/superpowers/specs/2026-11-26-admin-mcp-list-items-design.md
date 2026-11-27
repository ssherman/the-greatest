# Admin MCP: list items, and one front door for new books

Date: 2026-11-26. Books only.

## Why

List audits (`docs/features/list-audits.md`) keep finding rows that are wrong: the wrong book of a
series (Parable of the Talents where the source says Parable of the Sower), books the source names
that the list lacks, rows the source does not have. All the agent can do today is set
`items_need_revision` and leave the fix for a person. Shane wants the agent to fix the rows itself.

Some of the books a source names are not in the catalogue. Adding those needs a way for an admin
agent to bring a new book in. Shane's ideal is **one entry point for new books**. The book importer
(`DataImporters::Books::Book::Importer`) is still the only code that creates a `Books::Book`, apart from
the admin UI's hand-entry form, but several front doors have grown around it (reader submissions,
Goodreads imports, the list wizard, the Goodreads replay), each wrapping it in input parsing, a check of
our own catalogue, a background job with retries, a create lock and a review status. Rather than
add another front door, this work makes **book submissions** (`docs/features/user-added-books.md`) the
general one: a submission records who asked, and the reader-only rules apply only to readers.

## Goals

- Admin API endpoints and admin MCP tools to add, edit and remove the rows of a books list. Reading
  them already exists (`GET /api/v1/admin/lists/:id/items`, `list_admin_list_items`).
- An admin API endpoint and MCP tool that asks for a book by Amazon link, Goodreads link, ISBN, or title
  and authors, through the book-submission pipeline, optionally landing it on a books list at a position.
  With no list it is a general "import this book" tool.
- Row changes made during a list audit show up in that audit's before/after record.

## Non-goals

- Music and games lists. The endpoints refuse any list that is not a `Books::List`.
- Ranking refresh. Row changes move no ranking until someone refreshes in admin, as with every other
  list edit (list-audits ruling: no refresh tool or endpoint).
- Clearing `items_need_revision` through the API. It stays admin-only (existing rule in
  `Services::Lists::AdminUpdate`).
- Bulk edit or reorder endpoints. One row per call.
- Changing how reader submissions behave. Every reader-facing rule, message and limit stays as it is.

## Anti-goals

- A second place that creates books. Admin requests go through the same `CreateBook` step and the same
  signature lock as reader submissions and Goodreads imports, so two front doors racing still make one book.
- Unlinked rows (title and author text, no book). Books has none today and the public list page
  assumes every row has a book. A row is added only once its book exists.
- Running an import in a web request. The importer calls Amazon, Goodreads (through the page fetcher),
  Open Library and an AI step; the web process also serves live music and games. Imports stay on Sidekiq.

## Approaches considered

1. **Admin requests through book submissions (chosen).** Submissions gain an origin (reader or admin) and
   a second kind of target (a books list plus a position). Reuses parsing, the instant catalogue check,
   the job, retries, the create lock and the status polling that already exist.
2. **A separate import endpoint.** Queue the importer directly, track it with a new record, then add the
   row in a second call. Rejected: a third front door that rebuilds the duplicate check, retries and
   review hookup, and an agent that stops between the two steps leaves a book with no row.
3. **Import inside the request.** Rejected: too slow for the shared web process (see Anti-goals).

Shane picked 1 on 2026-11-26, framed as "submissions become the one front door for new books".

## Design

### Row endpoints

All under the books admin API, scope `books:admin:write`, authorized by `Books::ListPolicy#update?` the way
`update_admin_list` is. Each refuses a list that is not a `Books::List` (404, as the read endpoint does)
and relies on the model to refuse an auto-generated list (422 with the model's message).

| Endpoint | MCP tool | Body |
|---|---|---|
| `POST /api/v1/admin/lists/:id/items` | `create_admin_list_item` | `book_id` (required), `position` (optional) |
| `PATCH /api/v1/admin/list_items/:id` | `update_admin_list_item` | any of `book_id`, `position` (null clears it) |
| `DELETE /api/v1/admin/list_items/:id` | `delete_admin_list_item` | none |

- Responses use the existing `ListItemResource` shape.
- Unknown body keys are a 422 naming the accepted ones, as in `ListAuditsController#body_for`.
- A `book_id` that is not a book is a 422. A book already on the list is a 422 ("is already in this list",
  the model's uniqueness rule). A `position` that is not a positive integer is a 422.
- **Positions are set exactly as given, never renumbered.** Source lists have ties, gaps and unranked
  rows, so other rows never move. *My call; the admin UI behaves the same way.*
- Relinking a row to another book sets `verified: true`, as the admin UI's update does. Rows the agent
  adds are `verified: true`. *My call.*
- Delete removes the row only. The book stays.
- Every write is logged like the other admin writes (`log(...)` in the audit controller).

### Admin book requests (submissions with an origin)

`POST /api/v1/admin/book_submissions`, MCP tool `request_book` (name is the builder's to settle), scope
`books:admin:write`. Body: exactly one input method, the same fields and rules `ParseInput` takes from the
reader form (Goodreads link, Amazon link, ISBN, or title + authors), plus optional `list_id`, `position`
and `confirmed_new`.

- **Catalogue check first.** `InstantCheck` runs as for readers. If it finds books, the response returns
  them (id, title, authors) and creates nothing. The agent then adds the right one with
  `create_admin_list_item`, or repeats the request with `confirmed_new: true`.
- **Otherwise** a submission is created and the existing `ProcessBookSubmissionJob` is queued. The response
  returns the submission (the `get_book_submission` shape). The agent polls `get_book_submission` until it
  is `added`, `needs_details` or `failed`.
- **Origin.** A new `origin` column on `books_book_submissions` (`reader`, `admin`; existing rows are
  `reader`). The admin row's `user` is the API principal's user. `user_list` is null.
- **Target.** New nullable `list_id` (a `Books::List`) and `list_position` columns. A row has at most one of
  `user_list_id` and `list_id`. An admin row may have neither (plain import). A reader row always has a
  `user_list`, as today.
- **Reader-only rules stay reader-only:** the daily cap (`book_submissions.daily_limit`), the
  "open request on this list" duplicate check keyed on `user_list_id`, the reader strip, cancel, dismiss
  and replace. An admin request is not capped. *My call: the API's own rate limits already bound an agent.*
  An admin request with the same fingerprint and list as an open admin row returns that row instead of
  making another, the same way the reader check does.
- **The book.** `CreateBook` keeps its matching, adoption and signature lock unchanged. When it has to
  create a book for an admin row it calls the importer with `provisional: false, enrich: true`, the
  same settings the list wizard uses (`Services::Lists::Wizard::Books::Adapter#create`), instead of
  `provisional: true, enrich: false`. `review_status` is `not_needed`. The admin request is the review: the
  agent checked the book against its source. Uncertain finder decisions still go to the match-decision
  review queue through the decision's own flag, as today. `StartLookups` does not run (it is the provisional
  book's early, limited run; a non-provisional book gets the importer's full enrichment).
- **The row.** `ProcessSubmission`'s list step branches on the target: a reader row adds to the user list
  as today; an admin row with a `list_id` creates the `ListItem` at `list_position` (`verified: true`). A book
  already on the list counts as success and its row is recorded. A list deleted in the meantime leaves no row
  and the submission still ends `added`. The submission records the row it made (new nullable
  `list_item_id`, beside `user_list_item_id`).
- **The current "no owner" cancel.** `ProcessSubmission#run` cancels a row with no `user` or no `user_list`.
  For an admin row that becomes: cancel only when the user is gone.
- **Unresolved admin requests stay with the agent that asked (Shane, 2026-11-26).** Admin rows that end
  `needs_details` or `failed` are kept out of the `reviewable` queue, so no other agent or admin supplies
  details or retries them. The requesting agent sees the state when it polls and makes a new request with
  better input (an ISBN or a link from the source page). If it cannot, it leaves `items_need_revision` set
  and says so in the audit note. Why: only that agent has read the source, and an admin row's book skips
  review; details supplied by someone who never saw the source would create an unreviewed public book.
  `SupplyDetails`, `Retry` and the claim lease refuse admin rows. The admin submissions page shows each row's
  origin.

### Provisional books (Shane, 2026-11-26: promote)

An admin path can reach a provisional book (one a reader submission or a Goodreads import made, not yet
reviewed): the finder matches it, `CreateBook` adopts it from a request that raced this one, or the
catalogue check offers it and the agent adds it with `create_admin_list_item` or relinks a row to it with
`update_admin_list_item`. A curated row on a provisional book would sit unranked
(`ItemRankings::Books::Calculator` excludes provisional books) and would block `Reject` (`BookUses` counts
curated rows).

So every admin path that puts a provisional book on a list **promotes it first**, with the same effect as
`BookSubmissions::Approve`: the book and its provisional authors become public through
`GoodreadsImports::PromoteRecords`, and every open submission on the book closes as approved
(`reviewed_via: api`). The agent has just checked the book against a real source, which is the review.
`Approve` today requires a claim lease; the builder adds a lease-free entry point for this path rather than
faking a claim. Promotion and the row write happen in that order, so a failed promotion adds no row. The
catalogue-check hits returned by the request endpoint say which books are provisional, so the agent knows.

### Audit record

`Services::Lists::Audits::Snapshot` gains `"items"`: every row as `{"id", "book_id", "position"}`, ordered by id.
`Diff` gains `items_added`, `items_removed` and `items_changed` (per row: `book_id` and/or `position`
from/to), and `empty?` considers them. The admin Audits card shows them. Lists run to a few thousand rows,
which is fine for a jsonb snapshot.

A request still running when an audit finishes lands its row afterwards, outside the diff. *My call:*
`finish` records the ids of admin submissions still open on the list in the audit (`pending_submissions`)
so the card can show them. It does not refuse to finish, because a stuck job would otherwise block the audit.

### Agent guidance

The list-audit prompt and the MCP server instructions gain the row rules: fix rows only where the source
contradicts them; check the catalogue (`search_admin_books`, `find_by_identifier`) before requesting a
book; never add a row the source does not name; keep `items_need_revision` set when anything is left
unfixed. The tool descriptions say positions are never renumbered.

### Docs and counts

Admin OpenAPI gains four operations (tool count grows by four). Update `docs/features/list-audits.md`,
`docs/features/user-added-books.md` (origin, admin target, non-provisional admin books) and the admin API
docs. No new user-facing page, so no new Playwright test. The admin submissions page change is a column.

## Left to the builder

- Tool and operation names, within the existing `*_admin_*` pattern.
- Whether origin is an enum column or derived from the target (an enum is clearer and survives a list being
  deleted).
- How `ProcessSubmission`'s list step is split between the two targets.
- Exact problem-detail wording.

## Constraints

- Migrations add nullable columns and one defaulted enum column; existing rows need no backfill beyond the
  default. A failing migration is an outage (music and games share the database).
- Run annotaterb with the migration.
- Tests: every endpoint (auth, scope, books-only, auto-generated list, validation), the submission origin
  and target branches in `Submit`, `CreateBook` and `ProcessSubmission`, promotion of a provisional book on
  each admin path, admin rows refused by the queue, `SupplyDetails` and `Retry`, the snapshot and diff, and
  that reader submissions behave exactly as before.
