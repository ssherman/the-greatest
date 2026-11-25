# User-added books: design

Status: approved by Shane 2026-11-24 ("yes sounds good"). Branch `worktree-user-added-books`.
Built on this branch; see docs/features/user-added-books.md for what differs from this document.
"(Call)" marks a choice Claude made; Shane approved the document with them in it, without discussing
each one.

## 1. Intent

A reader wants to put a book on one of their lists, and the book is not on the site. The legacy site
had a modal for this (Goodreads URL, Amazon URL, or title and authors); the new site's "Add to this
list" box only searches the catalog and dead-ends. This is one of the last legacy features to replace
(`docs/todo.md`, "port the legacy add-book modal"). Shane asked for a rethink, not a port.

Why now: the old site has it, the new one does not, and books is approaching launch.

### Goals
- A signed-in reader can ask for a book by exactly one of: a Goodreads link, an Amazon link, an
  ISBN/EAN, or title and authors. Searching the catalog comes first and is unchanged.
- The request remembers the list. The book goes on that list as soon as a book record exists, even
  when it is unenriched and unapproved.
- It is quick: not behind bulk backfills.
- Every book created this way is marked user-added, permanently, and must be approved eventually.
- Agents can work the approvals through admin API/MCP endpoints, with a copy-and-paste prompt.

### Non-goals
- Adding books from the recommendation wizard (the legacy modal also appeared there), the member
  library API or the member MCP endpoint. (Call)
- Music, games, movies.
- Emailing the reader. (Call) The list page says what happened.
- Following Amazon short links (`a.co`, `amzn.to`). (Call)
- Changing the Goodreads member import's approval flow.

### Anti-goals
- A public book created without review.
- Outside services called while the reader waits on a page.
- A wrong merge or a duplicate author made to save a few seconds.
- An AI bill set off by junk (a joke import file once caused 10,000+ AI jobs).

## 2. Decisions Shane made

| Question | Decision |
|---|---|
| Inputs | **One at a time**, never combined: the existing autocomplete, or a Goodreads URL, or an Amazon URL, or title + authors, or an ISBN/EAN. |
| Instant check | Check our own database for the Goodreads id, Amazon id or ISBN first, skipping `legacy` identifiers, and tell the reader at once. No match starts the import on a higher queue. |
| Who | Any signed-in user, 20 a day. |
| Expectation | Tell the reader it may take a while. |
| Priority | User adds run on a higher queue; it should not take days. |
| List | Remember it; add the book when it is saved, enriched or approved or not. |
| Approval | Flag as user-added; needs approval eventually. Claude reads this as no automatic promotion. |
| Structure | A submission record (approach A below). |
| Review | Admin-only API and MCP endpoints so agents can monitor the queue; copy-and-paste prompt. |

Promotion follows the Goodreads import spec ("Only an admin. No automatic promotion"). An agent
holding an admin token acts for that admin. (Call)

## 3. Approaches considered

- **A. A submission record (chosen).** One table holds what the reader gave, the list, what lookups
  found and the review. Costs a table, an admin page and endpoints. Keeps the original input, gives
  the in-progress row on the list page, the daily cap, and the permanent user-added mark.
- **B. A one-row Goodreads import.** Reuses pending and approve, but that pipeline is built around
  CSV uploads and approves a whole import at a time.
- **C. Just create a provisional book.** Cheapest; loses the input and who asked, and cannot tell
  these books from imported ones.

For the review queue, a new type in `EnrichmentRequest` was rejected (Call). That queue collects
answers that fill blanks; this one approves, merges and rejects. The leasing idea is copied, not the
table.

## 4. Constraints found in the code

- The Open Library, WorldCat and Wikidata services are never on a public request path. The book
  `Finder` (its default mode) and `Importer` call Open Library and can call AI, so **both run in a
  job**, and no book exists when the request returns.
- The pasted URL is never fetched. Only an extracted id is used, in URLs we build.
- `FetchGate` hands out Goodreads turns in order, 15 s apart, 1,500 a UTC day. A Sidekiq queue alone
  cannot jump turns already handed out.
- `Workflows::Books::BookEnrichment.start` returns an active run untouched.
- `mark_user_state_changed` sets a cookie, so a job cannot call it.
- Provisional books already behave as needed: hidden from public search, rankings, sitemaps and other
  people's view of a list; the owner sees them. They load by URL with `noindex` and a notice.

## 5. Data

`Books::BookSubmission`, table `books_book_submissions` (Rails generator, annotaterb in the same commit).

- `user_id` nullable, `User has_many ... dependent: :nullify` (the mark outlives the account).
- `user_list_id` nullable, nullified when the list is deleted. If the list is gone before a book
  exists, the submission closes as `cancelled`.
- `method`: `goodreads`, `amazon`, `isbn` or `title_authors`. Only that method's input is set:
  `typed_title` and `typed_author_names` (jsonb array), or `raw_input` (as pasted) with the parsed
  `goodreads_book_id`, `asin`, or `isbn13`/`isbn10`. The model validates it.
- `status`: `queued`, `looking_up`, `needs_details`, `added`, `failed`, `cancelled`.
- `book_id` nullable (`Books::Book has_many :submissions, dependent: :nullify`), `created_book`
  boolean, `user_list_item_id`, `match_decision_id`, `lookup` jsonb (what each source answered).
- `review_status`: `not_needed`, `pending`, `approved`, `merged`, `rejected`, plus `needs_human`.
  Only a submission that created a book becomes `pending`; one matched to an existing book is
  `not_needed`.
- `reviewed_by_id`, `reviewed_via`, `reviewed_at`, `review_note`, `review_sources`.
- Lease: `lease_token`, `lease_expires_at`, `claimed_by_id`, `attempts`.
- `dismissed_at`: the reader hid a finished row on the list page. A row with no book yet offers
  **Cancel** instead, which sets `cancelled`; the job and the agent tools refuse a cancelled row. (Call)

The book merger gains a step that moves submissions to the surviving book. The `reviewed_by` and
`claimed_by` foreign keys need `has_many` on `User` too.

**Closing from elsewhere.** A pending book can also be promoted, merged or deleted outside this
feature (a Goodreads import approval, `merge_book`, a duplicate merge, an admin). Its open
submissions close with it, via `system`: promoted is `approved`, merged into a catalog book is
`merged`, deleted is `rejected`. Hooks go in `PromoteRecords`, the book merger and the book's destroy,
so no route is missed. A merge into another provisional book leaves them pending on the survivor. (Call)

**Identifiers.** An identifier goes to the finder and onto the book only when a source returned a
record for it, together with that record's title and authors. The finder is never called with an
identifier alone: with nothing to compare it accepts any holder, and legacy stamped wrong ids on
books. An identifier no source answered stays on the submission. Stamped ones use a new `Identifier`
source, `user_submission: 9`, trust rank 1 (as `legacy`). Identifiers an enrichment step finds keep
that step's own source.

## 6. The reader's side

On a `Books::UserList` page the owner's "Add to this list" dropdown always ends with **"Can't find
it? Add a book"**, results or not, so a wrong near-match does not hide it. It opens a dialog where
the reader picks one way, and only that way's fields show:

```
Add a book that isn't on the site
  How do you want to add it?
   (o) Goodreads link   ( ) Amazon link   ( ) ISBN   ( ) Title and author
  Goodreads link  [ https://www.goodreads.com/book/show/13651      ]
  It can take a while to add a new book. We'll put it on
  "Want to Read" when it's ready.              [Cancel] [Add book]

  with "Title and author" picked:
  Title      [ The Dispossessed   ]   (from the search text)
  Author(s)  [ Ursula K. Le Guin  ] [+ another]
```

- Radio buttons, with Goodreads link first and selected. (Call) Only the chosen way's fields are sent,
  and the server refuses a request carrying more than one.
- Limits: title 255, 1 to 10 authors of 255, link 2,048.
- Goodreads: book URLs on any goodreads.com host and locale path. Amazon: product URLs (`/dp/`,
  `/gp/product/`, `/gp/aw/d/`) on any Amazon store. ISBN: ISBN-10 or 13 with a checked digit
  (`Books::Isbn`). An EAN that is not an ISBN (not 978 or 979), a short link, or a link of the other
  kind is a form error saying what that field accepts.
- An ASIN that is a valid ISBN-10 is stored as the ISBN as well.
**The instant check.** On submit the server looks in Postgres only, and nothing outside:

- Goodreads, Amazon, ISBN: book-level and edition-level identifiers whose `source` is set and is not
  `legacy`. An ISBN is checked in both forms, and an ASIN that is an ISBN-10 as an ISBN too. Edition
  hits answer with the edition's book.
- Title and authors: the finder's exact title-and-author lookup. (Call)
- **Hits are shown, not added**: "We already have this. Is it the one?" with title, author and year for
  up to three books, and **Add to list** or **None of these**. (Call) Reading the title is what catches
  a wrong id, and a few dozen values are held by more than one book. Add uses the existing add-item
  endpoint. No submission is made and the daily cap is not touched.
- No hits, or "None of these", creates the submission and queues the job.

Measured on the dev copy (newest book 2026-11-13): non-legacy book-level identifiers reach 40,974 of
161,304 books, and 18,815 of the 21,260 ranked ones (88%). Values held by more than one book: 9
Goodreads ids, 27 ISBN-13s, 42 ISBN-10s, 14 ASINs. A miss costs only a background lookup.

- Submitting again for the same list and same normalized input while one is open returns the open one.
- 20 submissions in a rolling 24 hours, counted under the user's lock, whatever their outcome, plus
  the usual burst `rate_limit`.

The list page shows the owner a strip above the items, in its own Turbo Frame, one line per
submission that is not dismissed: "Adding: The Dispossessed" (the link or ISBN until a title is
known), "We couldn't find a book from that link. Try another way" (which reopens the dialog and
replaces the request), "Added The Dispossessed", "Already on the site: added The Dispossessed", "Could not
add ...", and, after a rejection, "We couldn't verify ..., so it was removed." While any is in
progress the frame polls every 10 seconds, stopping after 10 minutes. When one becomes `added`, the
poll response reloads the `list_items` frame, and **that response** calls `mark_user_state_changed`
so the add-to-list widgets are not stale.

A provisional item shows the owner a quiet "Not yet reviewed". The show-page notice is reworded for
both sources, because the page is edge-cached and identical for everyone: "Recently added; not yet
reviewed or enriched." (Call)

## 7. Processing

A Sidekiq job on `critical`, idempotent and retryable. Services live in
`Services::Books::BookSubmissions`.

1. **Resolve the input** to title, authors and identifiers:
   - **Goodreads link:** `GoodreadsPages::FetchPage` through the priority lane (section 8).
   - **Amazon link:** a new `Services::Amazon::Client.get_items` (the vacuum gem has the call). Title
     through `AmazonBookCheck.split_title`, authors through `author_names`. Only amazon.com is
     queried, so an ASIN it does not know falls through.
   - **ISBN:** WorldCat by ISBN, then Open Library, then an Amazon search by ISBN. First usable wins.
     (WorldCat's creator format must be checked against real records before it is split into names.)
   - **Title and authors:** used as typed, with no lookup at this step.
   - For a link or ISBN, a service being down is retried with backoff for an hour, and a Goodreads
     block or spent daily cap is waited out. A definite "no such record", or the hour running out, is
     `needs_details`: the reader can try another way, or an agent can supply the details.
2. **Find.** `DataImporters::Books::Book::Finder` with the confirmed query and `subject:` the
   submission, so a `MatchDecision` is kept, and `identifier_sources:` every source but `legacy`. A book
   another reader already submitted resolves to that provisional book, not a second one.
   - A `fallback` decision (the AI failed) or a failed local source is **not** "unmatched": it is
     retried with backoff and never creates. After an hour it is `failed`, which agents are handed.
   - A failed Open Library source alone is retried for the hour, then the book is created: the local
     checks ran, and review catches what is left. (Call)
3. **Create** when unmatched, with `Importer.call(match:, provisional: true, stamp_identifiers: true,
   enrich: false, query_identifier_source: :user_submission)`, under an advisory lock on normalized
   title plus primary author, re-checking for a book made since the finder looked (the shape of
   `GoodreadsImports::CreateBook`). An authorless result is rolled back and becomes `needs_details`.
4. **Add to the list** through `Services::UserLists::AddItem` inside `OwnerMutation`, whether the book
   was found or created. Already on the list is success.
5. **Start lookups** for a created book (section 9).

Other errors end as `failed` with the reason stored, retryable from the admin page.

## 8. Priority

- The processing job runs on `critical`, the first of the strict-priority queues.
- **Goodreads:** `FetchGate` gets a priority reservation. It starts as soon as the interval since the
  last real fetch allows, does not wait behind turns already handed out, and may use the last 100 of
  the 1,500 daily fetches, which ordinary reservations may not (`GOODREADS_PRIORITY_RESERVED`, default
  100). A block still refuses everyone. Jobs run on a `goodreads_fetch_priority` queue placed first in
  the existing one-thread capsule. The gate keeps one day's count, that of the newest reservation,
  which during a backlog can be tomorrow's, so this needs a count per day, not a threshold check.
  Reservations stay on the one-thread capsule, which is what makes the gate safe without a lock.
- **Amazon:** a `serial_priority` queue placed first in the existing one-thread `serial` capsule, so a
  sweep cannot hold these for days. Concurrency stays 1. (Call: Shane deferred reworking `serial`;
  this only orders it.)
- Workflow steps take their queue from the definition; a run started for a user add plans its steps
  on the priority queues.
- A Goodreads block (6 hours), a spent cap or an outage can still delay a Goodreads-link add.

## 9. Enrichment

**Before approval** (Call, approved with the document): a run limited to the
`goodreads` and `amazon` steps (`only:`), no author runs. It can supply a cover, year, page count and
identifiers. The Amazon step makes an AI call. The Goodreads step makes one when it has to search;
a Goodreads-link add already holds its id and page, so it skips the search and that call.

A site-wide ceiling (100 limited runs a day, ENV) and an off switch (ENV) bound it, because the
20-a-day cap is per account. Past the ceiling a book is still created and listed, without lookups. (Call)

**On approval:** `PromoteRecords` starts the normal full run. A limited run still active is
superseded, because `start` would otherwise return it and the full run would never happen. This needs
`PromoteRecords` to take `initiated_by:` (it hard-codes `goodreads_promote`) and
`BookEnrichment.start` to pass `supersede` and queue choices through to the planner. The supersede
lives in `PromoteRecords`, because a Goodreads import approval can promote the same book. The Amazon
step simply runs again: `amazon_enriched_at` is stamped even on failure, and the title may have been
corrected since. The Goodreads step reuses the stored page, so it normally costs no fetch. With
`AI_RESEARCH_VIA=queue`, web-search research goes to the existing agent queues as it does today.

The enrichment queue's `BookScope` does not exclude provisional books, so a Fill with scope "all"
could offer one to an agent before approval. `BookScope` and `AuthorScope` both get that filter.

## 10. Review queue

### API and MCP (admin only)

Operations in `admin_openapi.yaml`, each with `x-mcp`. Controllers follow `RepairVerdictsController`
and `EnrichmentItemsController`; all rules live in `Services::Books::BookSubmissions`, shared with the
admin page.

| Tool | Scope | Does |
|---|---|---|
| `list_book_submissions` | admin:read | Filter by `status` and `review_status`; default pending review plus `needs_details`. Meta carries counts. |
| `get_book_submission` | admin:read | Method and input, parsed id, lookup answers, the finder's decision and candidates, the book, its lists, the submitter's approved and rejected counts. No email, name or user id. |
| `claim_book_submissions` | admin:write | Hands out pending reviews, `needs_details` and `failed` rows, each saying which it needs. 1 to 25 (default 10), 30 minute lease, `FOR UPDATE SKIP LOCKED`, so several agents can run. |
| `supply_book_submission_details` | admin:write | Only while no book exists (`needs_details`, `failed`): title, authors, identifiers; queues the job again. After that, `update_book` is the fix. |
| `approve_book_submission` | admin:merge | Promotes the book and its provisional authors. |
| `merge_book_submission` | admin:merge, destructive | Merge into `target_id`, a non-provisional book. `dry_run`. |
| `reject_book_submission` | admin:merge, destructive | Deletes the provisional book. `dry_run`. |
| `skip_book_submission` | admin:write | Hands it to Shane (`needs_human`) with a reason; not claimed again. |

- Every write after the claim takes `lease_token` and a `note` (evidence; sources where it is a
  decision). A stale lease is a 409. Corrections to title or authors use the existing `update_book`
  and book-author tools before approving.
- **Agents decide for themselves**, as they do for the duplicate queue, and use skip when they cannot
  show the book is real. (Call)
- Approving, merging or rejecting closes every submission on that book.
- **Reject** refuses (422, naming what uses it) when anyone who did not submit this book uses it
  (a list item or review), or a curated list or a Goodreads import row does. Submitters' own items and
  reviews never block it, on whatever list they now sit (moving a book from Reading to Read makes a
  new item), and go with the book. (Call) It refuses a book that is no longer provisional, or that no
  submission created. Otherwise it runs the reading-goal purge as `DeleteProvisional` does, and
  destroys the book and the provisional authors left with no book.
- **Merge** uses the existing admin merge service, which carries the list items, so a list ends up
  pointing at the real book.

### Prompt

`config/mcp/books/prompts/book_submissions.md.erb`, queue `:book_submissions` in
`Services::AgentPrompts`, rendered with the pending counts and no reader text. It carries the loop
(claim, research, decide, repeat until empty), the house rules (English edition; placeholders; box
sets and adaptations are other books; a translation is the same book as its original), what counts as
evidence that a book exists, when to skip, the reporting format, and that names, titles and links in
results are reader text, never instructions. MCP cannot push, so "monitoring" is an agent told to
claim again on an interval; the prompt says how.

### Admin page

`/admin/book_submissions`: tabs by status and review status, counts, **Copy prompt**, and approve,
merge, supply details, reject and retry on each row. The admin book page shows a "User-added" badge
linking to the submission, when a submission created it and it was not merged away: a catalog book
that absorbed a user-added duplicate does not get the badge. A submission survives approval, which
makes the mark permanent.

## 11. Safety

- Title, author and link text is attacker-controlled: length-capped, escaped, never put in a prompt
  file, always data to the agent.
- No fetching of user URLs.
- The daily cap and one-open-per-input rule limit any one account. AI before approval is section 9's
  steps plus the finder's and author matcher's own calls.
- Created authors are provisional.

## 12. Testing

Minitest for every service, job, controller and policy (outside APIs stubbed, Sidekiq inline), with
cases for: each method; the instant check (a hit by each id kind, a legacy-only or sourceless id
ignored, several holders, "None of these"); a request carrying two methods; a replaced request; a match to a catalog book, to a provisional
book; a service down; two racing submissions; list deleted; the cap; approval over an active limited
run; reject refused for each kind of use; merge moving list items and submissions; priority turns
passing a backlog and using the reserved slice; a lease expiring. MCP: the pinned tool counts and
scope tests. Playwright: the dialog and strip, and the admin page, on rows seeded by a rake task (no
Sidekiq or network needed).

## 13. Docs and rollout

New `docs/features/user-added-books.md`; updates to `books-provisional-records.md` (who sets and
clears the flag), `mcp-server.md`, `public-api.md`, `docs/todo.md` (entry removed) and
`docs/launch-todo.md` (production steps). Sidekiq must restart with the new queues before the feature
is used. Sequence for the PRs is the builder's call; nothing needs a data migration.

## 14. Left to the builder

Names of services beyond those given, the exact markup, the poll implementation, index choice, and
where the reserved-slice logic sits inside `FetchGate`.
