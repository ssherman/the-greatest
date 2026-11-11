# Ranking archives

Design: `docs/superpowers/specs/2026-11-10-ranking-archives-design.md`.

A ranking archive is a frozen copy of a ranking as it stood on one day, kept as a single row. The
books site shows them at `/rankings/archive` as "Past rankings". Books is the only domain that has
them; the shape is built so music and games can add theirs (see the last section).

## What an archive is, and why it is not a ranking configuration

The legacy site kept each past ranking as an archived `ranking_configuration` with its own
`ranked_books` rows. This app does not copy that, for two reasons:

- The book merger recalculates every ranking configuration it finds. An archived configuration
  would be rewritten the first time two books merged, and the point of an archive is that it never
  changes.
- Each ranking is about 15,000 rows. A monthly archive as `ranked_items` rows adds that every month.

An archive is one `ranking_archives` row instead. It has no `ranked_items`, so nothing in the
ranking pipeline sees it.

## The record

Table `ranking_archives`, single-table inheritance. `Books::RankingArchive` is the only subclass;
it names its item class with `item_type`.

| Field | Meaning |
|---|---|
| `name`, `slug`, `description` | Presentation. Name is capped at 255 characters. |
| `item_ids`, `positions`, `scores` | Three parallel arrays, one entry per ranked book, in rank order. |
| `items_count` | Set from `item_ids.size` on create. |
| `captured_at` | When the ranking was frozen. For a migrated legacy archive, the legacy `published_at`, else `created_at`. |
| `period` | First day of the month, for the automatic monthly archive. Null for manual and legacy archives. |
| `ranking_configuration_id` | The configuration captured. Nullified if that configuration is deleted. |
| `legacy_ranking_configuration_id` | Set only by the legacy migration; makes it re-runnable. |
| `hidden` | Hidden archives are not served publicly. |

`origin` (legacy, monthly or manual) is derived from those two columns, not stored.

Rules the model enforces:

- The arrays and `items_count` are written once. An update that changes any of them fails. Only
  name, slug, description and `hidden` can be edited.
- The three arrays must be the same length, and `item_ids` must not be empty.
- `period`, when set, is the first of a month.
- Slugs are generated from the name on create. A collision gets `-2`, `-3` and so on, and a name that
  slugs to nothing becomes `archive`. A slug is unique per type.
- One archive per configuration per month is guaranteed by a partial unique index on
  (`ranking_configuration_id`, `period`) where `period` is not null. There is no model validation
  for it. `Services::RankingArchives::Capture` catches the index violation and returns "An archive
  already exists for this month."

`RankingArchive.summaries` selects every column except the three arrays. Listings use it so they
never load thousands of ids.

I did not put this data model under `docs/object_models/`: that directory holds only music diagrams
and no rule for other domains, so the model is described here.

## Capture

`Services::RankingArchives::Capture` freezes a global ranking configuration's current ranked rows.
It fails with a message, and writes nothing, when the configuration has no archive class, is not
global, or has no ranked items. It reads the ranking in one query, which is what makes the snapshot
consistent while a refresh rewrites `ranked_items`. It never changes the configuration and never
requests a refresh.

Two callers use it: the monthly job and the admin "Archive now" action.

## Resolving ids at read time

The arrays are never rewritten, so a book merged or deleted after capture has a stale id in them.
`Services::RankingArchives::Entries` resolves ids when a page is read:

- A live id is shown.
- A merged id is shown as its surviving book, at the archived position.
- A book that would appear twice (a survivor and one it absorbed) is shown once, at its best slot.
- A deleted or unknown id is skipped, so a page can come back short or empty.

It looks them up in `record_redirects`. That table used to hold only legacy-origin rows. A book
created in this app and merged later would have had no row, and an archive naming it could not be
resolved. `Services::BooksMigration::RedirectRecorder` now records every book merge and every book
delete, whatever the id. Authors are still recorded only when legacy-origin, since nothing else reads
author rows. The recorder is described under "Redirects" in `docs/features/books-legacy-sync.md`.

A book removed without callbacks (`delete_all`, raw SQL) leaves no redirect, so it reads as unknown
and is skipped.

## The monthly job

`Books::ArchiveMonthlyRankingJob` runs from `config/schedule.yml` as `books_monthly_ranking_archive`,
daily at 05:15 UTC, on the `low` queue. It archives `Books::RankingConfiguration.default_primary`
under the name of the current UTC month ("November 2026") with `period` set to the first of that
month. If the month already has an archive it does nothing.

It runs daily, not monthly, because sidekiq-cron does not catch up on a run it missed. Asking every
day whether the month has its archive heals a skipped run within 24 hours. It raises, so the failure
is visible, when there is no primary configuration or the capture fails.

The archive is a snapshot of the ranking on the day it runs, not of the 1st. The first run after
deploy archives the month it is deployed in.

To keep the current month's archive off the site, hide it. Deleting it is pointless: the next run
creates it again. The admin delete confirmation says so.

## Public pages

All routes are books-only and html-only, defined in `config/routes.rb` next to `/rankings`.

| Route | Page |
|---|---|
| `GET /rankings/archive` | Visible archives, newest first |
| `GET /rankings/archive/:slug` | One archive, 100 books per page |
| `GET /rankings/archive/:slug/page/:page` | Page N of it |
| `GET /rankings/archive/:slug/export.csv` | CSV download |

- Hidden archives 404.
- Pages are noindex and carry no canonical tag: the books layout noindexes anything that does not
  set `@indexable`.
- There are no filters on an archive; the page says so.
- Pages are cached publicly: the index for 6 hours, a show page for 24 hours, plus one hour of
  stale-while-revalidate. Hiding, deleting or re-slugging an archive therefore does not take it off
  the edge at once: pages already cached can stay reachable for up to 24 hours. The admin screens say
  this beside hide, delete and the slug field.
- Links in: the books rankings explainer has a books-only "browse past rankings" paragraph, and the
  live ranking page has a "Past rankings" link, hidden on `/rc/` pages.

## CSV

`CsvExports::ArchivedRanking` writes an archive with the same columns as the live books ranking
(`CsvExports::Books::RankedBookRow`). It is generated on demand, never stored, and goes through
`Entries`, so merged and deleted books are resolved the same way as on the page. The sign-in
requirement, per-user rate limit and the 500-row cap for non-members are those of every other export
(`docs/features/csv-exports.md`). Members get the whole archive.

## Admin

Books admin, `Admin::Books::RankingArchivesController`: index, show (first 25 entries), edit and
update, destroy. There is no new or create: archives are made only by the job and "Archive now".
The edit form changes name, slug, description and `hidden`. The Pundit policy is
`Books::RankingArchivePolicy`.

"Archive now" is `Actions::Admin::ArchiveRanking`, a form on the shared ranking-configuration admin
page (`/admin/ranking_configurations/:id`), shown only for a global configuration that has an
archive class (books). The admin types a name, and the archive is captured with no `period`, so a
manual archive never blocks the monthly one. Use it before an algorithm change.

## Legacy migration

`bin/rails data_migration:ranking_archives` runs
`Services::BooksMigration::RankingArchiveMigrator`. It copies each archived, global legacy
`ranking_configurations` row into one `Books::RankingArchive`. Legacy book ids were preserved, so
ids are stored as they are. A legacy configuration with no `published_at` arrives hidden.

It works in two passes, so ~600,000 rows are never held at once:

1. Read every legacy configuration that has no archive yet and classify each distinct book id as
   live, redirected, deleted or unknown. Any unknown id aborts the run before anything is written;
   the report lists up to 50 of them. That means the books sync is behind legacy: run
   `data_migration:sync` and retry.
2. In one transaction, create the archives.

The task pretty-prints a report. Keys to read: `count` (archives created), `skipped_existing`,
`skipped_empty` (configuration ids with no ranked rows), and `books` (`live`, `redirected`,
`deleted`, `unknown`). An archive that already exists, matched on `legacy_ranking_configuration_id`,
is never touched, so the task is re-runnable and safe after `sync_init`; a second run reports
`count: 0`.

Measured 2026-11-10 on the development database, regenerate by running the task and reading its
report:

| | |
|---|---|
| Archives created | 43 |
| Ranked entries | 616,728 |
| Distinct books | 24,078 (23,919 live, 159 redirected to a survivor, 0 deleted, 0 unknown) |
| Arrived hidden | 2 ("List Dates V7", "No Recency Bias") |
| `ranking_archives` table afterwards | 4.6 MB |
| Legacy `ranked_books` these rows came from | 325 MB |

## Music and games

Nothing here is books-specific except the subclass, the job and the pages. To add another domain:

1. Add its item type to `RecordRedirect::ITEM_TYPES` and make its merger and delete paths record
   redirects (the books recorder is the model). Without this, ids in its archives cannot resolve.
2. Add a `RankingArchive` subclass with `item_type`, and an override of `ranking_archive_class` on
   its ranking configuration. That override is what lets `Capture` and the "Archive now" form
   accept the configuration.
3. Add a monthly job and a `config/schedule.yml` entry.
4. Add the public pages, controller, routes and CSV row class, and an admin screen.

## Tests

Model, `Capture`, `Entries`, the redirect recorder, the migrator, the job and the two controllers
have Minitest coverage. The Playwright spec is
`web-app/e2e/tests/books/admin/ranking-archives.spec.ts`: it archives the primary configuration,
checks the admin and public pages, hides the archive and deletes it.

## Related

- `docs/features/books-legacy-sync.md` (Redirects)
- `docs/features/csv-exports.md`
- `docs/features/rankings.md`
