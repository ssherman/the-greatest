# Books legacy sync

From the switch-over on, the books catalog in this database is the master. Legacy
(thegreatestbooks.org) keeps running until launch, and `data_migration:sync` brings
over only what is new there. Design: `docs/superpowers/specs/2026-10-08-books-legacy-sync-design.md`.

## Tasks

| Task | What it does |
|---|---|
| `data_migration:sync_report` | Read-only. Prints what a sync would do now. Safe in production at any time, before or after `sync_init`. |
| `data_migration:sync_init` | Once, right after the final `data_migration:all`. Records the watermarks. Refuses if they exist. |
| `data_migration:sync` | Weekly. New legacy books, authors and their rows, new `book_identifiers` on any book, new categories/languages/countries/news posts, and users. `FINAL=1` drops the 24h delay (the cutover run). |

After `sync_init`, `data_migration:all` and every catalog task abort with "use data_migration:sync".

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
- A successful run advances each watermark to the last id it processed. A failed run moves nothing, and the next run retries; every step is insert-only.
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

## Not synced

Legacy edits to existing catalog records; books legacy deleted (reported as "legacy
deleted, still here"); lists, rankings and penalties. User lists, list items,
reviews, saved searches and corrections are increment 3.
