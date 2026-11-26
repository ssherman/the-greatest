# Books legacy sync

From the switch-over on, the books catalog in this database is the master. Legacy
(thegreatestbooks.org) keeps running until launch, and `data_migration:sync` brings
over only what is new there. Design: `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md`.

## Tasks

| Task | What it does |
|---|---|
| `data_migration:sync_report` | Read-only. Prints what a sync would do now. Safe in production at any time, before or after `sync_init`. |
| `data_migration:sync_init` | Once, right after the final `data_migration:all`. Records the watermarks. Refuses if they exist. |
| `data_migration:sync` | Weekly. New legacy books, authors and their rows (identifiers included), new categories/languages/countries/news posts; users, user lists and items, reading goals, saved searches, recommendation settings, reviews and corrections matched to legacy, except the reader/book pairs the Goodreads re-import changed ("The Goodreads re-import hold" below); then the favorites rebuild. `FINAL=1` drops the 24h delay (the cutover run). |

After `sync_init`, `data_migration:all`, every catalog task and the user-data tasks the sync replaces (`user_lists`, `user_list_items`, `saved_searches`, `reviews`, `corrections`) abort with "use data_migration:sync".

### Switching over

1. Before starting the final `data_migration:all`, read legacy's highest `book_identifiers` id
   (`bin/rails runner 'puts LegacyBooks::BookIdentifier.maximum(:id)'`).
2. Run the final `data_migration:all`.
3. `BOOK_IDENTIFIERS_FROM=<that id> bin/rails data_migration:sync_init`. Without it, identifiers
   legacy adds to existing books while the hours-long `:all` runs are never copied.
   `sync_init` also removes redirect rows for books and authors that exist again (the weekly
   `:all` ignores redirects, so it restores what was deleted or merged before the switch).

### Categories during the sync

- A link to a category that was merged in this app lands on the merge target. A link to a category deleted without a merge is still dropped.
- The `category_cleanup` step runs only after a category cleanup has been applied. It runs the rules pass on new legacy categories and applies those rule decisions; AI decisions wait for the owner. Categories whose only decisions failed or went stale are retried each week.
- A new legacy category normally keeps its legacy slug. If that slug is already held (by another books category, or by a rename's friendly_id history), the sync does not pin it and the category gets a fresh suffixed slug instead; pinning would raise a unique violation and fail the step every week. The rules pass merges the new category only when it is a case or punctuation twin of an existing one. A legacy name that a rename moved away from (a new `Calcutta` after `Calcutta` became `Kolkata`) stays a separate category until the next AI `propose`, because legacy and alternative names never drive a rules merge.
- The `location_ancestors` step reconciles inherited location links for the synced books.

Details: `docs/features/books-categories.md`.

## How it decides what is new

- `legacy_sync_watermarks` holds the last legacy id processed for `books`, `authors`, `book_identifiers`.
- A legacy row above its watermark is copied once it is more than 24 hours old, because legacy enriches new books with background jobs first. A row inside the delay holds back every id after it.
- A successful run advances each watermark to the last id it processed. A failed run moves nothing, and the next run retries; catalog steps are insert-only and user-data steps converge on legacy.
- Rows of a new book or author come with it: editions, identifiers, categories, countries, attributes, links, descriptions, cover image. Existing books get nothing from legacy, not even new identifiers ("Identifiers" below).

## Redirects

`record_redirects` records what became of a book or author that no longer exists:
merged into `to_id`, or deleted (`to_id` NULL). Every book is recorded, whatever its
id, because ranking archives store book ids and resolve a merged or deleted one
through this table. An author is recorded only when legacy-origin (id below its
ceiling). The mergers write it before destroying the source; an `after_destroy` on
`Books::Book`/`Books::Author` records every other delete. A merge or delete also
repoints rows that named the departing record, so chains through new-app books
resolve. The sync never re-inserts a redirected id, and routes a new book's author
or a new identifier's book through `Services::BooksMigration::Redirects`. It only
ever asks about legacy ids, so rows for new-app books are never looked up by it; the
sync report's "redirects recorded" figure counts them.

A book removed without callbacks (`delete_all`, raw SQL) leaves no redirect. A later
sync that meets its id fails and names the legacy row.

## Users' data

Legacy stays the source of truth for legacy users' data until the cutover. Each run makes the
legacy-origin rows (ids below their table's ceiling) match legacy. It never touches lists created
in this app or other domains' lists. A legacy-origin list is matched as a whole, though: an item
added to one in this app is deleted when legacy does not have it (18 such items on 2026-11-12).

| Data | Each run |
|---|---|
| Users | Overwritten by id. A user legacy deleted is counted, never deleted (the row carries music and games data). |
| User lists | Overwritten. Books lists legacy deleted are deleted, with their items. |
| List items | Synced list by list. Each book goes through redirects: a merged book lands on the survivor, two items that land on one book keep the lower position, an item on a deleted book is dropped. Items legacy removed are deleted. Positions are renumbered 1..N on legacy-origin lists only. |
| Reviews | Overwritten. Two reviews a merge puts on one book keep the newer (higher legacy id). A new-app review of the same book by the same user wins. Reviews legacy deleted are deleted. Review summaries are rebuilt. |
| Saved searches | Overwritten; ones legacy deleted are deleted. A category deleted here is removed from the criteria. |
| Reading goals, recommendation settings | As in the full migration. |
| Corrections | Insert-only, routed through redirects. |

A row on a legacy book that is not here yet (above the books watermark, inside the 24h delay) is
skipped and counted as `waiting`; a later run picks it up. A list item or review on a book that is
neither here, redirected nor waiting fails the run and names the legacy rows: the book was removed
without callbacks (`delete_all`, raw SQL). Merging while a sync runs is safe: each write locks the
books it points at, so a merge waits for it, or the write is re-planned onto the survivor.

**Deletion guard.** An empty or half-restored legacy database looks like mass deletion. A step that
would delete more than `max(500, 5%)` of a table's legacy-origin rows refuses, unless
`SYNC_ALLOW_DELETES=1`. It covers user lists, reviews and saved searches, and list items by
comparing legacy's total with the total here before any batch runs (a restore can have the lists in
and the items not yet). Reading goals, a table of a few hundred rows, refuse when legacy has none.

**The Goodreads replay's relinks** move legacy users' list items and reviews. Each sync puts them
back to match legacy, and `books:goodreads_replay:apply` re-applies the approved ones after every
sync. Its merges are redirects and stick. (In production every replay relink was retired unapplied,
so in practice there are none to put back. The Goodreads re-import, which replaced the replay, is
kept by the hold below instead.)

**Report.** `sync_report` prints, per table, legacy and here counts and what the sync would insert,
update, delete, drop and leave waiting, and what it would hold for the Goodreads re-import. List items are compared by a digest per list, and only lists
that differ are planned item by item, through the same plan the sync applies. `update` (legacy
`updated_at` newer than here) is a report number only: the sync overwrites every legacy-origin row.

## The Goodreads re-import hold

The Goodreads re-import (`docs/features/goodreads-reimport.md`) moved legacy readers' list items and
reviews off the books the old importer guessed and onto the books their CSV rows name. Legacy still
holds the guesses. Without a hold, each sync would make those readers' lists and reviews match legacy
again and undo the re-import. So the sync leaves alone every reader/book pair the re-import changed
(`Services::BooksMigration::ReimportHold`; design
`docs/superpowers/specs/2026-11-26-books-sync-keeps-reimport-design.md`, sections 5.1 and 5.2).

**What is held.** The set is built from the re-import's verdicts at the start of every `sync` and
every `sync_report`:

- every `reimport_row` and `reimport_guess` verdict that recorded a change (its payload has `moved` or
  `leftovers_removed`), of any status, current or superseded, applied or not: the reader with the book
  the row left and the reader with the book it went to. A change can be recorded before `applied_at`
  is set, and a superseded guess can already carry `moved`, so neither status nor `applied_at` is
  trusted;
- every `reimport_mixed` verdict's `deleted` items, applied or not: each item's reader with the mixed
  book. A kept mixed book still waiting on a copy has already destroyed some originals.

Keeps that changed nothing (about 442,000 rows) are not held: legacy agrees with them, so syncing them
is harmless and those readers' other edits keep coming over. Measured on a copy of production on
2026-11-26: 26,648 held pairs.

**Merges.** Each book id is followed through the merges recorded since (`record_redirects`), so a
pair matches both the legacy book id a legacy row names and the book it lands on here. The redirects
not followed are the ones a deleted mixed book left: its own, and those of books merged into it before
it was deleted, which point at the same place. That place is the mixed book's most-read destination,
which the re-import did not touch for every reader of the mixed book, and following it would hold
pairs nobody changed. The mixed book itself stays held, and so do the books merged into it earlier,
so a legacy row naming either is held by its legacy id. A mixed book the re-import kept is an
ordinary book: if it is merged later, the hold follows that merge.

The hold is built when the run starts. A merge that commits while the run goes on (`record_redirects`
changed) is picked up before each batch of list items and reviews: the redirects are read again and the
hold is expanded through them, so a held item a merge moved stays held. Avoid merging books while the
sync runs all the same.

**What the sync does with a held pair.**

- List items: a legacy row whose reader and legacy book, or reader and routed book, is held is
  neither kept nor inserted. A row here on a held pair is neither deleted nor rewritten (no change to
  position, dates or `completed_on`). The reader is the list's owner, and a pair is held across all of
  that reader's lists.
- Reviews: a legacy review is not written when its reader and book (legacy or routed) is held, or when
  its id is a review here that sits on a held pair (legacy's own book merges move reviews and keep
  their ids). A review here on a held pair is never deleted.
- Positions on legacy-origin lists are still renumbered 1..N after the run; that reorders, it never
  moves a book.
- **A list the reader deleted on legacy is still deleted here, with every item in it, held or not.**
  Deleting a whole list is the reader's own decision.

The cost: a reader's later edits on legacy to a held pair (a shelf move, a new rating) do not come
over. Shane accepted this (2026-11-26); the old site's Goodreads upload is paused before the first
sync that holds, so new legacy rows on those pairs are hand edits, not imports.

**Counts.** `sync` prints each step's result: `user_list_items` carries `held_legacy` (legacy rows
not written) and `held_here` (rows here left alone), and `reviews` carries `held` (review ids neither
written nor deleted). `sync_report` prints the same numbers on the `user_list_items` and `reviews`
lines ("held for the Goodreads re-import"), computed the way the run applies them, so a report right
after a sync shows 0 inserts, updates and deletes with the held counts still printed. The report plans
only the lists whose digest differs from legacy, while the run plans every legacy-origin list, so the
report's held list-item counts can be lower than the run's; its insert and delete counts agree.

The re-import report's loss check ("users whose list item or review count dropped") is for right
after a re-import apply. A later sync's real deletions (a reader removing a book on legacy) show up in
it as drops, so it is not a check on the sync.

## Identifiers

From 2026-11-26 the sync copies a legacy book identifier only when its book is new in that run
(`BookIdentifierMigrator#in_sync_scope?`). A new legacy identifier on a book we already have is skipped.
The old site's Goodreads importer stamps each CSV row's Goodreads id and ISBNs onto whatever book it
guessed, and a wrong ISBN or Goodreads id on our book pulls later imports onto it. Shane no longer adds
identifiers, lists or merges on legacy, so the only identifiers this skips are the old importer's. This
narrows the 2026-10-08 rule that every new legacy identifier comes over (Shane, 2026-11-26).

New books still arrive whole, with every identifier legacy holds for them, below the identifier
watermark or not. The other identifier steps (book work, edition, edition ISBN, the edition Amazon
backfill) only ever touched the run's new books. The `book_identifiers` watermark still advances over
every new legacy row. The skipped identifiers are counted in `sync_report`, not in the run's output:
it prints "book_identifiers (on new books only)" and a line "skipped: legacy identifier on an existing
book".

## Not synced

Legacy edits to existing catalog records, new legacy identifiers on existing books included; books
legacy deleted (reported as "legacy deleted, still here"); lists, rankings and penalties; a legacy
reader's edits to a pair the Goodreads re-import changed.
