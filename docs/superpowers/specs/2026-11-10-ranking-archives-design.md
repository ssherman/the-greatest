# Ranking archives

**Date:** 2026-11-10
**Status:** design approved by the owner 2026-11-10; no plan yet
**Scope:** books. The storage is shared so music and games can use it later; nothing is built for
them now.

## Why

Readers set goals against the ranking: "read the top 100". When they come back and the ranking
has moved, some of them are annoyed. On the legacy books site the owner handled this by cloning
the primary ranking configuration about once a month, making the clone the new primary and
archiving the old one. Readers could open an old version at `/rc/:id`. The owner stopped doing it
because it is manual work: the last one is "May 2026", and it has been recalculating ever since.

Those 43 archived legacy configurations were deliberately left out of the books data migration
(`docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`, "archived RCs: future
sub-project"). This is that sub-project, plus a replacement for the monthly routine that needs no
manual work and no new ranking configuration.

## What was measured (2026-11-10, local legacy restore and dev database)

Numbers describe that day. Re-measure before relying on them.

- Legacy `ranked_books`: 2.0M rows, 325 MB (140 MB heap, 184 MB indexes). 69% of the rows have no
  position at all. Only 616,728 rows in the 43 archived configurations carry a rank, covering
  24,078 distinct books.
- The same 616,728 rows stored as new-app `ranked_items` would be about 160 MB (87,213 rows are
  23 MB today, six indexes). Stored as one row per ranking with the book ids in an array they are
  2.4 MB for all 43; the current primary (21,260 books) is 83 KB as an `integer[]`.
- Disk is not the reason to avoid `ranked_items`. The reason is that
  `Books::Book::Merger#collect_affected_ranking_configurations` collects every configuration that
  ranks either book and requests a recalculation of each, with no `archived` check. Archived
  rankings stored as configurations would be recalculated, and so destroyed, by the first merge
  that touched them.
- Legacy data is consistent: the `ranked_books.book_id` foreign key is validated and there are 0
  orphan rows. It is not complete: when a book was merged or deleted on the legacy site after a
  ranking was archived, its row went with it, leaving a gap (for example "List Dates V5" has no
  #57). About 7 gaps across all 43 top-100s.
- Against the dev database, 23,919 of the 24,078 books exist under the same id (legacy book ids
  were preserved). The other 159 were merged in the new app and every one has a
  `record_redirects` row with a surviving target. None unaccounted for, no redirect chains.
- Month to month, 97 to 100 of the top 100 books stay in the top 100, but usually only 20 to 50
  keep the same position.
- Filtering a ranking straight from an id array took 170 to 450 ms per page uncached. Possible
  later, without changing the storage.

## Decisions the owner made

1. **An archived ranking is a flat record, not a ranking configuration.** One row per archive, the
   whole ordered list of book ids in a field. No `ranked_items`, `ranked_lists` or penalty rows.
2. **No filters on an archived ranking.** The page shows a message instead. The owner expects
   almost nobody to want them.
3. **Archives are created automatically every month from the primary ranking**, named for the
   month: "January 2027", "February 2027". The owner must not have to create a ranking
   configuration to get one.
4. **An admin can also archive a ranking by hand.**
5. **CSV export of an archive is wanted.**
6. **The design must not shut out music and games**, but nothing is implemented for them now.
7. **The legacy archived rankings are migrated** into this shape.
8. The live primary ranking keeps recalculating exactly as it does today. Nothing in this design
   changes how or when it moves.

## Goals

- A reader can open the ranking as it stood in a given month, at a URL that never changes, and
  page through it.
- A new archive appears every month with nobody doing anything.
- The 43 legacy archives are available on the new site.
- An archive, once written, is never recalculated and never rewritten by a merge, a delete, a
  refresh or a sync.
- Adding an archive costs kilobytes, not megabytes.

## Non-goals

- Filters, search, category or country views of an archive.
- API and MCP access to archives.
- Jobs, admin screens or public pages for music and games.
- Per-book history ("this book was #12 in March"). The storage does not rule it out; nothing here
  builds it.
- Redirecting legacy `/rc/:id` URLs for archived ids. Ranking configurations were migrated with
  fresh ids, so a legacy id in that URL already means a different, or no, configuration in this
  app, and the legacy ids (3 to 68) overlap the range new configurations and members' rankings
  occupy. The archive keeps its legacy id for provenance only. (The 2026-07-03 design already
  recorded `/rc/:id` as low traffic.)
- Freezing the public ranking between archives.
- Archiving the legacy site's still-active configurations (ids 48, 52, 63, 68). They were migrated
  as live configurations.

## Anti-goals

These would make it a failure even if it worked:

- An archive that changes after it is written.
- Any path by which a merge, a refresh or `RequestRefresh` reaches an archive.
- The monthly routine needing the owner to remember anything.
- An archive page that errors or shows a blank slot because a book was later merged or deleted.

## Design

### The record

One row per archive. Names are the builder's; this is what it has to hold.

| Holds | Notes |
|---|---|
| Name | "January 2027"; legacy names kept as they are ("V2", "List Dates v1", "October 2025"). |
| Slug | For the URL. Unique within a domain. |
| Description | Optional. Legacy descriptions carried over. |
| Which domain and item type | Books and `Books::Book` today. Stored, not assumed, so a music or games archive is a row and not a schema change. Follow the convention the app already uses for shared models that vary by domain. |
| Ordered item ids | One array, best first. |
| Positions | One array, parallel to the ids. Legacy rankings have ties and gaps, and array order alone would lose both. |
| Scores | One array, parallel to the ids. The CSV has a Score column. |
| Item count | So lists and paging never have to open the arrays. |
| Captured-at time | When the ranking stood this way. For a legacy archive, its `published_at`, falling back to `created_at`. |
| Month | Set only on automatic archives; unique per source configuration, which is what makes the monthly job safe to run twice. |
| Source ranking configuration | Nullable. Set for archives taken in this app. Removing the configuration must not remove the archive. |
| Legacy ranking configuration id | Nullable, unique. Set for migrated archives; the migration's idempotency key. |
| Hidden flag | A hidden archive is admin-only. |

The three arrays are written once, at creation, and nothing ever updates them. The model should
make that hard to do by accident (my call; for example, refuse to save a changed array on an
existing record).

Storing positions and scores next to the ids roughly triples the size, to about 250 KB for a
21,000-book ranking. Still about 3 MB a year. (My call. The owner asked for "a blob of the entire
list of book ids in one field"; the extra two arrays keep ties, gaps and the CSV's Score column
honest.)

The full ranking is stored, not a top N.

### Reading an archive: merged and deleted books

The arrays hold the book ids as they were. They are resolved when read:

- An id that is still a book: shown.
- An id with a `record_redirects` row pointing at a surviving book: the survivor is shown at that
  position.
- If that survivor already appears in the same archive at a better position, the lower slot is
  dropped. A page can therefore show 99 books. (My call.)
- An id with a redirect to nothing (deleted), or with no book and no redirect: skipped. The page
  never errors.
- Original positions are displayed, so a skipped slot reads as a gap (…56, 58…), the same way the
  legacy gaps do.
- **Every redirect with a target is followed, including the guessed ones.** (My call.)
  `Services::Books::GoodreadsReimport::Apply::Mixed` deletes a mixed book and records a redirect
  to its most-read book, which is a guess; `Leftovers#resolve` refuses to follow it when moving
  data. An archive follows it anyway: the site already sends that book's URL to the same guess,
  a stand-in beats a gap, and telling the two kinds of redirect apart would need a schema change.
  None of the 159 redirected books in the legacy archives is inside any top 1,000.

**`record_redirects` only covers legacy-origin ids today.**
`Services::BooksMigration::RedirectRecorder.legacy_origin?` skips any book whose id is above the
reserved ceiling, because the legacy sync has no use for those rows. A book created in this app,
captured in an archive and merged afterwards would then leave no trail, and would vanish from the
archive even when its survivor is a perfectly good stand-in.

So: record a redirect for every book merge and every book delete, whatever the id's origin. (My
call.) A first read of the three readers (2026-11-10) found nothing that breaks: `Redirects` only
resolves ids the sync hands it, `SyncInit` deletes rows whose `from_id` is live and a merged-away
id never is, and `Leftovers#book_ids` is deliberately over-inclusive. That was a read, not a test.
The builder must still confirm that the three existing readers tolerate rows for
non-legacy ids, and say so in the plan: `Services::BooksMigration::Redirects` (loads every row for
the sync), `SyncInit` (deletes rows whose `from_id` is a live record), and
`Services::Books::GoodreadsReimport::Apply::Leftovers`. If one of them cannot, stop and bring it
back to the owner; do not work around it by rewriting archives at merge time.

### Paging

A page is a slice of the arrays: page 3 is entries 201 to 300. The page count comes from the item
count. Each page view reads one archive row, resolves at most 100 ids and loads those books. 100
per page and path-based paging (`…/page/3`), the same as the live ranking.

Dropping a duplicate survivor needs to know whether the survivor appears elsewhere in the archive,
which is a lookup against the whole id array, not just the page. That is cheap; it just should not
turn into loading 21,000 books.

### Public pages (books)

- **Past rankings**: a list of visible archives, newest first by captured-at, with name, date and
  book count.
- **One archive**: title, a banner saying this is an archived ranking and when it is from, a link
  to the current ranking, and the books. Where the live ranking has its filter bar, a line of text
  says filters are not available on archived rankings.
- Book cards are the same `Books::CardComponent` the live ranking uses, given the book and its
  archived position, with no ranking configuration. A signed-in reader's read marks then appear on
  an archive exactly as they do on the live ranking. That is the point of the feature: "I am
  reading the January 2027 top 100" has to work.
- Links to Past rankings: from the rankings explainer page (`/rankings`) and a quiet text link on
  the main ranking page. Not a header navigation item. (My call.)
- URLs: under `/rankings`, for example `/rankings/archive` and `/rankings/archive/january-2027`.
  (My call; the builder may choose another shape if this one collides with the books route
  grammar. Whatever is chosen is permanent.)
- `noindex`, like `/rc/` pages. (My call: an archive is near-duplicate content of the main
  ranking.) No canonical tag, for the reason `Books::RankedItemsController` already documents.
- Edge-cached like other public pages. A hidden or deleted archive is a 404 at origin.
- **Hiding, deleting or re-slugging an archive does not purge the edge cache.** (My call.) Pages
  already cached stay reachable until they expire (`Cacheable`: up to 24 hours). An archive has
  around 200 paged URLs, hiding one is rare, and nothing in an archive is sensitive. The admin
  screen says so next to those actions. Archives that arrive hidden were never cached.
- An unknown or malformed page number behaves as it does on the live ranking.

### CSV export (books)

A Download CSV button on the archive page, using the existing export machinery: the same columns
(`CsvExports::Books::RankedBookRow`), the same sign-in requirement, per-user rate limit, `no-store`
and `noindex`, and the same membership cap (500 rows for non-members, everything for members).

Rank and Score come from the archive. Every other column is the book's current data. Merged and
deleted ids are resolved the same way the page resolves them.

Generated on demand, never stored. The full live books export builds in 2.5 to 5 seconds on
demand, so an archive needs no pre-built file. (My call.)

### The monthly archive

A scheduled job (`config/schedule.yml`, Sidekiq, like every other scheduled job here) that makes
sure the books primary ranking has an archive for the current month, and creates it if it does
not.

- It runs **daily**, not monthly. (My call.) sidekiq-cron does not catch up on a run it missed, so
  a job scheduled only for the 1st would skip a whole month if Sidekiq was down that morning. A
  daily "is this month's archive there yet?" check heals itself; on a normal month the archive is
  created on the 1st and the other runs do nothing.
- The archive is named for the month it is created in, in UTC: "January 2027".
- It captures every ranked book of the primary configuration, with rank and score, in rank order.
- If the primary has no ranked books it creates nothing and fails loudly. An empty archive must
  never be written.
- It reads the ranking in one consistent snapshot. A refresh running at that moment must not
  produce half of one ranking and half of another.
- It never touches the configuration: no clone, no rename, no change of primary, no refresh.
- **The first run after deploy archives the month it is deployed in**, whatever the day. (My
  call.) No "first eligible month" setting. Legacy archives were taken mid-month too ("March 2026"
  on the 15th), and it shortens the empty stretch after "May 2026". If the owner does not want
  that first archive public, the remedy is to hide it, not delete it: a deleted monthly archive
  frees its month and the next daily run recreates it. The admin delete confirmation should say
  so for an archive of the current month.

### Admin (books)

- A list of archives: name, captured-at, book count, where it came from (monthly, manual,
  legacy), hidden or visible.
- **Archive now**: on a books ranking configuration's admin page, an action that archives that
  configuration's current ranking under a name the admin types. Available for any global books
  configuration, not only the primary. (My call.) It does not set a month, so it never blocks or
  replaces the automatic archive.
- Edit name, slug and description. Hide and unhide. Delete, with a confirmation.
- The ranked list itself cannot be edited.
- Follow the existing books admin controllers, policies and layout.

### Migrating the legacy archives

A new, separate, re-runnable task alongside the other `data_migration:*` tasks, reading the
legacy database through `LegacyBooks::` models. It is not part of `data_migration:all` or
`data_migration:sync` and must stay runnable after `sync_init` (which has already run in
production).

- Source: every legacy `ranking_configurations` row with `archived = true` and `global = true`
  (43 on 2026-11-10), and its `ranked_books` rows where `combined_position` is not null, ordered
  by position. All 47 legacy configurations are `global = true` (checked 2026-11-10); every one
  also has a `user_id`, which is the owner's and means nothing here. The `global` filter is a
  guard, not a selection: no member's ranking exists on the legacy side to leak.
- Position comes from `combined_position` and score from `score` (the `numeric(10,2)` column).
  `calculated_score` is empty on every row; ignore it.
- Book ids are copied as they are. They are not resolved or rewritten at migration time.
- Name, description and dates carried over. The two archives with no `published_at`
  ("List Dates V7", "No Recency Bias") arrive hidden. (My call.)
- Keyed on the legacy configuration id: a second run updates nothing and creates nothing.
- Before writing, it reports how many distinct book ids are (a) live books, (b) redirected to a
  survivor, (c) redirected to nothing, (d) neither. Any id in (d) means the books migration is
  behind the legacy database: abort and list them.
- No `ranked_lists`, penalties or `LegacyIdMap` rows are written for archived configurations.
- Production's numbers will differ from dev's (it has had more merges). The task's report is the
  check.

It is a manual step, so it goes in `docs/launch-todo.md`. It can run any time after deploy and
again at cutover.

The months between the last legacy archive and the first automatic one stay empty. Nothing
back-fills them.

### Music and games

Not built. What keeps the door open: the record stores its domain and item type; the capture
code takes a ranking configuration and does not assume books; `record_redirects` is the one
books-only piece (`RecordRedirect::ITEM_TYPES`), and extending it is the work a future music or
games archive would start with.

## Constraints

- `AGENTS.md` conventions apply: generators for models, jobs and components; annotaterb with the
  migration; services under `app/lib/services/` with the Result pattern; standardrb; a Playwright
  E2E test for the new public pages and the admin flow; no destructive commands against the
  development database.
- Merging to main deploys to production, and a failing migration is an outage. The new table is
  additive.
- Rails cannot join across the two databases. The migration reads legacy rows and writes new ones.
- Tests must cover: the immutability of the arrays; every branch of id resolution, including a
  redirect to a survivor already in the archive; a month with an existing archive; a primary with
  no ranked books; a merge of an archived book leaving the archive untouched and not requesting
  any refresh on its account.
- Feature documentation goes in `docs/features/`, the data model in `docs/object_models/`.

## Left to the builder

- Table, model, column and route names; array element types; whether domains are STI subclasses
  or a column.
- How id resolution is structured and where it lives.
- The cron time of day.
- Exact copy for the banner, the no-filters line and the admin screens.
- Whether the capture service is one object used by the job and the admin action (it should be).
- Whether the abort in the migration report has an override flag.
