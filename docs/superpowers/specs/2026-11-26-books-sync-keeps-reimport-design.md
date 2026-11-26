# The weekly sync keeps the Goodreads re-import, and the launch todo is rewritten

Date: 2026-11-26. Status: APPROVED by Shane 2026-11-26 (approach 1, identifiers option A).

## 1. Why

Shane wants the weekly legacy sync (`data_migration:sync`) running again, so that by cutover the new database is
close to legacy and the cutover itself is small. He also wants every Goodreads import accurate: each reader's rows on
the book the row names, with none of the duplicates and junk the old site's importer makes.

Two things stand in the way, both found on 2026-11-26 (read-only checks against production):

- **A sync now would undo the Goodreads re-import.** The last sync ran 2026-11-13 00:43 UTC. The re-import
  (`docs/launch-todo.md` section 12) applied from 2026-11-17 to 11-20: 4,559 moves, 8,090 copies, 14,758 adds,
  1,668 mixed books archived, ratings set from the CSV on 510 reviews. The sync code has not changed since
  2026-11-12. In sync mode `UserListItemMigrator` makes every legacy-origin list match legacy
  (`UserListItemPlan`: any row here that legacy's routed rows do not explain is stale and deleted, legacy's rows are
  re-inserted), and `ReviewMigrator` upserts each legacy review by id onto its legacy book with legacy's rating.
  Re-import spec section 3.9 already said the sync must be changed before it runs again; it never was.
- **`docs/launch-todo.md` is no longer trustworthy.** Many runs edited it. It calls `sync_init` "the switch-over",
  which ran on 2026-10-10, while Shane means the cutover (legacy goes offline); several steps still say they wait for
  the switch-over; sections 1 and 2 are history; statuses are mostly unrecorded.

Legacy since the last sync (2026-11-12 to 11-26): 10 Goodreads imports, 10,551 list items, 2,163 reviews, 114 users,
580 books, 588 user lists. Most of the new list items come from those imports, which the old importer puts on wrong
or junk books.

## 2. Goals

1. `data_migration:sync`, `sync_report` and `FINAL=1 data_migration:sync` never revert an applied re-import verdict.
2. Everything else the sync does is unchanged: new books, authors, users, user lists, list items, reviews, reading
   goals, saved searches and the rest. One deliberate change: identifiers (section 5.6).
3. The old site stops accepting Goodreads uploads and says the new site launches soon with a better import.
4. The legacy imports made since the re-import (10 on 2026-11-26, plus any made before the old-site change deploys)
   go through the re-import, so they end up as accurate as the rest.
5. `docs/launch-todo.md` is rewritten so every step is correct against the code and every status is checked against
   production.

## 3. Non-goals

- A reader's edits on legacy to a book the re-import changed for them do not come over (section 5.1). Accepted.
- Deleting the empty books the old importer made (1,700 import-made books with no reader items and no reviews on
  2026-11-26). It goes in the launch todo as a cutover-time cleanup; no design here.
- Telling adaptations apart from the original on the page (the re-import created about 75 books, approved by Shane,
  such as an audio drama of *The Last Battle*, with the same title and author as the original). Launch-todo item only.
- Turning off the old site's add-a-book-by-Goodreads-URL feature (`BooksController`, `GoodreadsImporterFromUrl`).
  It creates one book a reader asked for, not a library of guesses.

## 4. Anti-goals

- Any sync that deletes, moves or re-rates a row the re-import placed. One exception, by design: a reader who deletes
  a whole list on legacy has it deleted here too, re-import items included (section 5.2).
- A weekly "sync reverts, then re-apply" cycle (approach 3 below).
- A migration or lock that could stall music or games, which share the database.

## 5. Approaches

1. **Leave the re-import's reader/book pairs alone (chosen by Shane, 2026-11-26).** The sync skips every reader and
   book pair the re-import changed, on both sides (the book a row moved from, the book it moved to), for list items
   and reviews. Everything else syncs as today. Cost: a reader's later legacy edits to those books do not come over.
2. **Add only, never delete or rewrite user data.** Smallest change, but a shelf move on legacy (reading → read) leaves
   the book on both shelves here, and the drift grows weekly for every active reader.
3. **Let the sync revert, then re-run the re-import's apply.** The apply runs each verdict once and sweeps leftovers;
   making it repeatable is more work than approach 1, and the site shows reverted data between the two steps weekly.

Paired with approach 1, Shane chose to turn off Goodreads import on the old site (his offer), so new legacy rows are
hand-picked books the sync can copy as they are.

### 5.1 The re-import pairs

The set the sync leaves alone, computed once at the start of each sync (and of `sync_report`) from the database:

- For every current `reimport_row` and `reimport_guess` verdict that recorded a change (its payload has `moved` or
  `leftovers_removed`), whether or not `applied_at` is set: `(user_id, from_book_id)` and `(user_id, to_book_id)`.
  A change can be recorded before `applied_at` is (a lost mark; `DecideRow#applied?` already reads `moved` as applied).
- For every `reimport_mixed` verdict with `deleted` items, applied or not (a kept mixed book still waiting on a copy has
  already destroyed some originals): `(item user_id, mixed book_id)` for each item.
- Each book id is also taken through later **merges** (record redirects a merge left), so the pair matches both the
  legacy book id a row names and the book it routes to here. The redirect a deleted mixed book leaves (to its
  most-read destination) is **not** followed: the re-import did not touch that destination for every reader of the
  mixed book, and following it would hold pairs nobody changed. Those redirects are told apart by the mixed verdict's
  `book_id`. A legacy row naming the mixed book itself is still held through the legacy-book-id check.

Measured 2026-11-26: 20,090 changed verdicts, 26,648 distinct pairs, 640 readers, 725 items deleted with mixed books.
Keeps that changed nothing (about 442,000) are not in the set: legacy agrees with them, so syncing them is harmless and
their readers' other edits keep flowing.

### 5.2 What the sync does with a pair

- **List items** (`UserListItemPlan`, shared with `UserDataDiff`): a legacy row whose `(user, legacy book)` or
  `(user, routed book)` is a pair is neither kept nor inserted. A row here whose `(user, book)` is a pair is neither
  stale nor rewritten: it is left exactly as it is (no delete, no upsert of position, dates or `completed_on`). The
  user comes from the list (`user_lists.user_id`).
- **Reviews** (`ReviewMigrator` in sync mode): a legacy review whose pair is held is not written, and its id counts as
  kept, so `delete_reviews_legacy_lacks` does not delete it. A review here on a held pair is never deleted.
- **Counts**: `sync` and `sync_report` print "held for the Goodreads re-import" for items and reviews, so the report
  and the run still agree and a second report converges to 0 changes.
- `finalize`'s position renumbering of legacy-origin lists is unchanged (it reorders; it does not move a book).
- **Whole lists**: `UserListMigrator` still deletes a legacy-origin list the reader deleted on legacy, with every item
  in it, held or not. Deleting a list is the reader's own decision.

### 5.6 Identifiers on books we already have (Shane, 2026-11-26: option A)

The old importer stamps each CSV row's Goodreads id and ISBNs onto whatever book it guessed. Since 2026-11-12 legacy
added 2,608 book identifiers, 1,155 of them on books that already existed. The sync copies them onto our books
(`BookIdentifierMigrator#in_sync_scope?`: a new identifier id, or an identifier of a new book), and the re-import
cannot strip them for editions it already matched in its first pass. A wrong ISBN or Goodreads id then pulls later
imports onto the wrong book.

From this change on, the sync copies a legacy identifier only when its book is new in this sync
(`sync.book_ids`); a new identifier on a book we already have is skipped and counted ("skipped: legacy identifier on
an existing book"). New books still arrive whole, with their identifiers. Shane does not add identifiers, lists or
merges on legacy any more (2026-11-26), so the only identifiers this skips are the old importer's. This narrows his
2026-10-08 ruling that new legacy identifiers always come over.

The builder applies the same rule to every identifier step of the sync that can attach to an existing book
(book work identifiers, edition and edition-ISBN identifiers, the edition Amazon backfill), checking each, and
`sync_report` counts the same way. The identifier watermark keeps advancing. With fewer legacy identifiers arriving,
the launch todo's weekly `books:verify[all,recheck]` step is re-explained (it re-verified books that got new legacy
identifiers).

### 5.3 Old site

In `the-greatest-books` (merging deploys; no tests, per Shane's standing rule for that repo):

- `GoodreadsImportsController#upload` refuses with the message instead of saving an import.
- `GoodreadsImportComponent` (rendered on `/goodreads_imports` and `/user_lists`) shows the message instead of the
  upload button and modal; the latest-import status stays visible.
- `recommendations/step_2.html.erb`'s Goodreads card points at the message instead of the upload.
- Imports already queued or running finish normally; the next re-import pass picks them up.
- Message (Shane may reword): "Goodreads import is paused while we move to our new site, which launches soon with a
  new and improved Goodreads import."
- Its own branch off `main` in that repo, not the `front-page-new-site-banner` checkout (which has an uncommitted
  `.gitignore` change).

### 5.4 The legacy imports made since the re-import

After the fixed sync has run, the existing section 12 steps, which are incremental, take only the new work:
`books:goodreads_replay:load` reuses loaded imports and loads new ones; `survey[all,redo]` so the new legacy books are
classified; `archive_mixed`; `match[all]` (editions without a match); `decide[all]` (users with undecided rows);
review; `apply`; `check_authors[all]`; `apply`; `report`; `sample`.

The loss check: `snapshot` refuses to replace the first pass's snapshot, and `snapshot[redo]` would hide that pass's
history. **My call:** the snapshot gains a per-pass file (the report compares against the newest one); the builder
may instead show that the existing file can be extended for new users only, if that is simpler and keeps the first
pass's check intact.

### 5.5 Proof

- A test that builds re-import verdicts on fixtures (a move, a copy, an add, a rating change, a mixed delete), runs
  the sync's list-item and review steps against stubbed legacy rows that still show the old state, and checks that
  nothing the verdicts placed changed, while an unrelated legacy edit for the same reader (a shelf move on another
  book, a deleted item, a new review) does come over.
- The same for `sync_report`: its counts equal what the run does.
- A dev rehearsal on fresh copies of production and legacy (`bin/refresh-dev-db.sh --legacy`, which replaces the dev
  database wholesale, so Shane says go first): `sync_report`, `sync`, `sync_report` again (0 changes, held counts
  printed). Acceptance: every list item and review the verdicts placed (`list_item_ids_after`, `review_id_after`, the
  guesses' moved ids) still exists on the same book, except items in a list the reader deleted on legacy.
- The re-import report's loss check ("users whose list item or review count dropped") is meant for right after a
  re-import apply. A later sync's legitimate deletions (a reader removing a book on legacy) show up in it as
  unexplained, so it is not an acceptance line for the sync. The launch todo says so.

## 6. The launch todo rewrite

Rewrite `docs/launch-todo.md` in place (same file, so every pointer to it still works). It stays the one list of
manual steps.

Structure:

1. **Words used here**: "switch-over" = `sync_init`, done 2026-10-10; "cutover" = legacy offline and the final
   sync; "hostname switch" = thegreatestbooks.org pointing here.
2. **Where things stand**, as of a stated date: one line per section with DONE (date), PARTIAL or NOT RUN, checked
   read-only against production.
3. **Every week until cutover**: the sync cycle as it is after this work (report, sync, report, merge_unknown,
   replay load, a re-import pass when there are new imports, rankings, the repeating steps of sections 9, 10 and 14).
4. **Before cutover, once, not yet done**, ordered, each marked safe-now or waits-for-X, with which ones share a
   bottleneck (Open Library's one `/resolve` slot; Sidekiq concurrency; AI spend) and so must not overlap.
5. **Cutover day**, **hostname switch**, **after launch**: the current sections 6, 7 and 8, corrected.
6. **Done**: finished one-off steps collapsed to a line each with the date and the result, keeping only what someone
   would need to re-run them.

Rules: every command is checked against the code (task name, arguments, environment variables, guards such as tasks
that refuse after `sync_init`); every status is checked read-only against production; nothing is marked DONE without
evidence. New entries this work found: lower `SIDEKIQ_CONCURRENCY` to 10 and switch `GOODREADS_REIMPORT_ENABLED` off
between passes (or say why it stays on); the re-import sample check (its result was not found: the worker log was reset
by the 2026-11-26 deploy); the empty import-made books at cutover; adaptation title notes; the two duplicate pairs
merged 2026-11-26 (Cosmicomics 251937 → 250177, Why We Eat 253586 → 253135).

## 7. Order in production

1. Old site change deployed (5.3).
2. Sync fix deployed; dev rehearsal passed first (5.5).
3. `sync_report` → `sync` → `sync_report` (held counts printed, 0 changes on the second).
4. The re-import pass over the new imports (5.4), then rankings.
5. Weekly from then on, per the rewritten launch todo.

The launch-todo rewrite can merge before the sync fix; until the fix deploys it must say plainly: do not run
`data_migration:sync`.

## 8. Left to the builder

- Where the pair set is built and how it is passed (one object shared by `UserListItemPlan`, `ReviewMigrator` and
  `UserDataDiff`), and how it follows redirects.
- The snapshot-per-pass mechanics (5.4).
- Exact wording of the report lines.
