# Books legacy sync

From the switch-over on, the books catalog in this database is the master. Legacy
(thegreatestbooks.org) keeps running until launch, and `data_migration:sync` brings
over only what is new there. Design: `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md`.

## Tasks

| Task | What it does |
|---|---|
| `data_migration:sync_report` | Read-only. Prints what a sync would do now. Safe in production at any time, before or after `sync_init`. |
| `data_migration:sync_init` | Once, right after the final `data_migration:all`. Records the watermarks. Refuses if they exist. |
| `data_migration:sync` | Weekly. New legacy books, authors and their rows, new `book_identifiers` on any book, new categories/languages/countries/news posts; users, user lists and items, reading goals, saved searches, recommendation settings, reviews and corrections matched to legacy; then the favorites rebuild. `FINAL=1` drops the 24h delay (the cutover run). |

After `sync_init`, `data_migration:all`, every catalog task and the user-data tasks the sync replaces (`user_lists`, `user_list_items`, `saved_searches`, `reviews`, `corrections`) abort with "use data_migration:sync".

### Switching over

1. Before starting the final `data_migration:all`, read legacy's highest `book_identifiers` id
   (`bin/rails runner 'puts LegacyBooks::BookIdentifier.maximum(:id)'`).
2. Run the final `data_migration:all`.
3. `BOOK_IDENTIFIERS_FROM=<that id> bin/rails data_migration:sync_init`. Without it, identifiers
   legacy adds to existing books while the hours-long `:all` runs are never copied.
   `sync_init` also removes redirect rows for books and authors that exist again (the weekly
   `:all` ignores redirects, so it restores what was deleted or merged before the switch).

## How it decides what is new

- `legacy_sync_watermarks` holds the last legacy id processed for `books`, `authors`, `book_identifiers`.
- A legacy row above its watermark is copied once it is more than 24 hours old, because legacy enriches new books with background jobs first. A row inside the delay holds back every id after it.
- A successful run advances each watermark to the last id it processed. A failed run moves nothing, and the next run retries; catalog steps are insert-only and user-data steps converge on legacy.
- Rows of a new book or author come with it: editions, identifiers, categories, countries, attributes, links, descriptions, cover image. Existing books get nothing from legacy except new `book_identifiers` rows.

## Redirects

`record_redirects` records what became of a legacy-origin book or author (id below
its ceiling) that no longer exists: merged into `to_id`, or deleted (`to_id` NULL).
The mergers write it before destroying the source; an `after_destroy` on
`Books::Book`/`Books::Author` records every other delete. A merge or delete also
repoints rows that named the departing record, so chains through new-app books
resolve. The sync never re-inserts a redirected id, and routes a new book's author
or a new identifier's book through `Services::BooksMigration::Redirects`.

A book removed without callbacks (`delete_all`, raw SQL) leaves no redirect. A later
sync that meets its id fails and names the legacy row.

## Users' data

Legacy stays the source of truth for legacy users' data until the cutover. Each run makes the
legacy-origin rows (ids below their table's ceiling) match legacy, and never touches new-app rows
or other domains' lists.

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
sync. Its merges are redirects and stick.

**Report.** `sync_report` prints, per table, legacy and here counts and what the sync would insert,
update, delete, drop and leave waiting. List items are compared by a digest per list, and only lists
that differ are planned item by item, through the same plan the sync applies. `update` (legacy
`updated_at` newer than here) is a report number only: the sync overwrites every legacy-origin row.

## Not synced

Legacy edits to existing catalog records; books legacy deleted (reported as "legacy
deleted, still here"); lists, rankings and penalties.
