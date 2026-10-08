# Books Legacy Sync — Design

Date: 2026-10-08. Status: approved section by section in brainstorming; awaiting review of this
written spec.

## 1. Why this exists

The plan until now was to truncate the books data before launch and run `data_migration:all` from
scratch. That makes any cleanup done in the new app throwaway: duplicate merges, name
normalization and hand fixes would all be lost to the truncate. Shane wants to start finding
duplicates and cleaning data now, in production, and launch in under a month.

This design drops the truncate. From a switch-over point on, **the new database's books catalog is
the master**. The weekly `data_migration:all` that Shane runs in production is replaced by
`data_migration:sync`, which brings over only what is new on legacy (new books and authors, and
the identifiers legacy imports add) and keeps legacy users' data matched to legacy. The cutover is
the sync's last run, with legacy offline.

### Measured facts (2026-10-07/08)

- **Re-running `:all` undoes cleanup.** `BookMigrator` and `AuthorMigrator` do
  `find_or_initialize_by(id:)` + `save!` with no guard (`book_migrator.rb:20-23`,
  `author_migrator.rb:19-21`): a merged-away book comes back, `EditionMigrator` moves its editions
  back onto it (`edition_migrator.rb:21-24`), and edited titles are overwritten.
- **A merge leaves no durable source→survivor record.** `Services::DuplicateCandidates::RecordMerge`
  only updates an existing pair row; a merge with no candidate row records nothing
  (`record_merge.rb:32-36`). No redirect, tombstone or slug history exists.
- **Books, authors, reviews and saved searches have no reserved id range.** `RESERVED_CEILINGS`
  covers only `users` (150,000), `user_lists` (1,000,000) and `lists` (10,000). The others get
  `reset_pk_sequence!` (max + 1), so the new app hands out the ids legacy is about to use. In dev,
  296 provisional books (Goodreads replay) already sit above legacy's max; the next `:all` that
  reaches those ids overwrites them with unrelated legacy books.
- **Production is clean today** (Shane's query, 2026-10-08): legacy books max 175,879 vs new
  175,877; 3 new-app-only books, all below legacy's max (books legacy's own merger deleted after a
  weekly run copied them); 0 provisional books; authors 80,329 / 80,328; reviews 153,446 / 153,444;
  saved searches 6,070 / 6,053; 0 recorded book merges. In dev, every review is a books review and
  every saved search is a `Books::SavedSearch`.
- **Legacy is still busy** (local restore, per month): ~1,500–2,000 books and ~500 authors (July
  2026 spike: 29,769 books, 12,246 authors), ~25–35k user list items, ~2k user lists, ~5k reviews,
  ~400 users. Almost all new books come from its Goodreads import, which also adds Goodreads/ISBN
  identifiers to existing books. A new legacy book is enriched by background AI jobs after creation
  (`Book#populate_external_data`, `Author#populate_data_from_chatgpt`).
- Legacy's scheduled `RefreshAmazonEditionsJob` is dead (the old Amazon API no longer works), so it
  changes nothing.

### Decisions (Shane, 2026-10-07/08)

- Cleanup happens **in production**. The sync replaces the weekly `:all` there.
- Approach: **convert the existing `:all` chain to a sync mode** (not a from-scratch sync chain, not
  replaying cleanup over full re-migrations).
- After the switch-over, legacy edits to **existing** catalog records are dropped. Shane stops
  editing books on legacy. The one exception: `book_identifiers` rows created on legacy after the
  switch-over are carried, on any book. Missing identifiers are never re-added in general, because
  that would bring back bad identifiers removed during cleanup.
- No new curated lists are added on legacy, so lists, rankings and penalties are not synced.
- Ceilings are kept modest because launch is under a month away (§3).
- A read-only production report of the legacy/new difference (§7).

## 2. Definitions

- **Ceiling:** the reserved id floor for new-app rows in a table (§3). Every row below it came
  from legacy.
- **Legacy-origin row:** a row whose id is below its table's ceiling. For tables with fresh ids
  (user list items), a row belonging to a legacy-origin parent (a `Books::UserList` below the
  `user_lists` ceiling). The sync may overwrite and delete legacy-origin rows only. Rows the new
  app creates (Goodreads imports, music/games data) are never touched.
- **Watermark:** the highest legacy id the sync has already processed for a legacy table (§5).
- **Redirect:** a recorded fate of a legacy-origin book or author: merged into another record, or
  deleted (§4).

## 3. Increment 1 — id reservation

Extend `RESERVED_CEILINGS` (`app/lib/services/books_migration.rb`):

| Table | Legacy max (2026-10-08) | Typical month / July spike | Ceiling |
|---|---|---|---|
| `books_books` | 175,879 | ~2k / 29.8k | 250,000 |
| `books_authors` | 80,329 | ~500 / 12.2k | 120,000 |
| `reviews` | 153,446 | ~5k / 12.5k | 250,000 |
| `saved_searches` | 6,070 | small | 20,000 |

No rows need relocating: all four tables hold only legacy-origin rows today. So this does **not**
use `IdRangeReservationService`'s relocation, which shifts every row below the ceiling and would
move the legacy rows themselves. A new step, run by a data migration on deploy, sets each sequence to
`max(ceiling, max id + 1)`, never moving it backward. It is idempotent. It does **not** refuse when
rows already sit above the ceiling (amended while planning increment 1): a raising migration
crash-loops the web container for all four sites, and the migrators' per-row ceiling guard is what
actually keeps legacy ids out of the reserved range.

Each migrator that preserves ids into these tables (`BookMigrator`, `AuthorMigrator`,
`ReviewMigrator`, `SavedSearchMigrator`) raises if a legacy id reaches its ceiling, like
`ReadingGoalMigrator`'s 10,000 guard. Their `reset_pk_sequence!` finalize calls must not pull a
sequence back below the ceiling: replace them with "set to max(ceiling, max id + 1)".

Ships first and alone. Until it does, the first book the Goodreads replay or a member import
creates in production gets overwritten by the next weekly `:all`.

## 4. The redirect record

New table `record_redirects`:

| Column | Notes |
|---|---|
| `item_type` | `Books::Book` or `Books::Author` |
| `from_id` | the legacy-origin id that no longer exists |
| `to_id` | the survivor's id; NULL means deleted |
| timestamps | |

Unique index on `(item_type, from_id)`. No foreign keys: `from_id` is gone by definition, and
`to_id` may itself be merged later.

**Writers:**

- `Books::Book::Merger` and `Books::Author::Merger` insert `from → survivor` inside their
  transaction, before destroying the source. The Goodreads replay's merges go through these mergers,
  so they are covered.
- An `after_destroy` on `Books::Book` and `Books::Author` (one line calling a service) inserts
  `from → NULL` with ON CONFLICT DO NOTHING. A merge has already written its row, so the merge
  wins; every other destroy path (admin destroy, console, jobs) is recorded as a delete.
- Only legacy-origin ids (below the ceiling) are recorded. Nothing else can be resurrected by the
  sync, so recording new-app rows would only add noise.

**Reader:** `Services::BooksMigration::Redirects` loads the table once per run and resolves an id
to itself, its final survivor (following chains A→B→C, with a cycle guard that raises), or
`:deleted`.

**Not in scope:** URL redirects for merged books (dead URLs after a merge stay accepted).
Categories need no redirects: they use fresh ids plus `LegacyIdMap`, so "has a map entry" already
means "seen before" (§5).

## 5. Increment 2 — redirects and the catalog sync

### Watermarks

New table `legacy_sync_watermarks` (`key` unique, `value` bigint, timestamps), with keys `books`,
`authors`, `book_identifiers`.

`data_migration:sync_init` is run once in production, right after a final `data_migration:all`:

- `books` and `authors`: the new DB's highest legacy-origin id (max id below the ceiling), which is
  exactly what `:all` just loaded.
- `book_identifiers`: legacy's current max `book_identifiers.id`.

It refuses if the watermarks already exist.

### The run's scope

Each `data_migration:sync` run computes, once, at the start:

- **New books:** legacy books with id above the `books` watermark and `created_at` older than 24
  hours. Legacy enriches a new book with background AI jobs after creating it, and the sync copies a
  book once, so it waits for that to finish. Legacy ids grow with `created_at`, so this is a prefix
  of the remaining ids. `FINAL=1` drops the delay.
- **New authors:** the same against the `authors` watermark.
- **New identifiers:** legacy `book_identifiers` above the `book_identifiers` watermark, same
  delay.

After a successful run, each watermark advances to the highest id the run processed. A run that
fails leaves the watermarks unchanged, and the next run retries the same scope (the migrators are
insert-only here, so a retry is safe).

### Per-migrator behavior in sync mode

| Treatment | Migrators |
|---|---|
| Insert the run's new books/authors only, preserved ids, refuse at the ceiling, skip ids that have a redirect | `BookMigrator`, `AuthorMigrator` |
| Insert rows **for the run's new books/authors only** | `BookAuthorMigrator`, `EditionMigrator` (and its identifiers), `BookWorkIdentifierMigrator`, `EditionIdentifierMigrator`, `EditionIsbnIdentifierMigrator`, `CategoryItemMigrator`, `BookTypeCategoryMigrator`, `BookCountryMigrator`, `BookAttributesMigrator`, `ExternalLinkMigrator`, `BookDescriptionMigrator`, `AuthorDescriptionMigrator`, `AuthorCountryMigrator`, `AuthorIdentifierMigrator`, `BookImageMigrator`, `EditionIdentifierBackfill` |
| Insert the run's new `book_identifiers` rows, on **any** book | `BookIdentifierMigrator` |
| Insert only if never seen; never overwrite | `CategoryMigrator` (skips any legacy id with a `LegacyIdMap` entry, so a category deleted or edited here stays that way), `LanguageMigrator`, `CountryMigrator`, `NewsPostMigrator` |
| Skipped | `ListMigrator`, `ListItemMigrator`, `RankingConfigurationMigrator`, `RankedListMigrator`, `PenaltyMigrator`, `PenaltyApplicationMigrator`, `ListPenaltyMigrator`, `NumYearsCoveredMigrator`, `penalties:reconcile` |
| Unchanged (already only fills gaps) | `description_safety_net`, which gives a `:manual` Description row to books and authors that have none, so it covers new books and touches nothing else |

Every book and author id a migrator writes is routed through `Redirects`: a merged id lands on the
survivor; a deleted id drops the row and counts it. This matters for new rows that point at old
records, e.g. a new book whose author already existed and has since been merged.

Two finalize steps currently recompute across all rows: `CategoryItemMigrator`'s `item_count`
and `BookCountryMigrator`'s `book_count`. They are cheap and correct in either mode, so they stay.
`EditionMigrator`'s `default_edition_id` recompute is scoped to the run's new books, so a default
edition chosen during cleanup is not reset.

### Search indexing

The migrators load with search indexing suppressed. In sync mode the run then creates
`SearchIndexRequest`s for the books and authors it inserted, so the weekly
`search:books:recreate_and_reindex_all` is no longer needed.

### The `:all` guard

`data_migration:all` aborts with "use data_migration:sync" when `legacy_sync_watermarks` has rows.
It stays usable on an empty database (dev rebuilds, the test suite).

### Books legacy deleted

Books (and authors) that exist here below the ceiling but no longer on legacy are **not**
deleted. They are reported by id (§7). Their user list items move off them anyway, because the
user-data sync follows legacy (§6). The duplicate sweep or Shane merges them.

## 6. Increment 3 — the user-data sync

Legacy stays the source of truth for legacy users' data. Each run makes the legacy-origin rows
match legacy, with every book id routed through `Redirects`.

| Data | On each run |
|---|---|
| **Users** | Overwrite by id, as today. **No deletes:** a user row also carries music and games data, so a legacy deletion is counted, not applied. |
| **User lists** | Overwrite by id, as today. **Delete** `Books::UserList` rows below the ceiling that legacy no longer has (their items go with them). |
| **User list items** | Route the book through redirects. When a merge leaves one list with two rows for the same book, keep one, at the lower position. Drop items whose book was deleted (counted). Overwrite as today. **Delete** items in legacy-origin lists that legacy no longer has. Renumber positions 1..N on legacy-origin lists only (today's finalize renumbers every `Books::UserList`). |
| **Reviews** | Change from insert-only to **overwrite**, so edits on legacy come through. **Delete** `Books::Book` reviews below the ceiling that legacy no longer has. When a merge gives one user two reviews of the same book (`index_reviews_on_user_and_reviewable`), keep the newer. Rebuild review summaries, as today. |
| **Reading goals** | No change: they already overwrite and delete, and do not reference books. |
| **Saved searches** | Overwrite by id. **Delete** rows below the ceiling that legacy no longer has. A category that no longer exists here is removed from the criteria and counted, instead of raising. |
| **Recommendation configs** | No change (overwrite by user). |
| **Corrections** | Insert-only, as today, routed through redirects. A correction on a deleted book is dropped and counted. |
| **Favorites lists** | `user_favorites_lists:rebuild` runs at the end, as today. |

### The Goodreads replay

The replay's contract is unchanged; the sync stands where the migration pass stood.

- Replay **merges** go through the mergers, so they are recorded as redirects and survive every
  sync. Nothing needs re-applying.
- Replay **relinks** move legacy users' list items and reviews. The sync puts those back to match
  legacy each run, and `books:goodreads_replay:apply` re-applies the approved ones afterwards, as it
  does after each migration pass today.
- **Mark provisional** is a catalog change, so it sticks.

**Still final-sync-only:** `books:goodreads_replay:finish_legacy`, and member Goodreads imports by
legacy users. They write into legacy-origin lists, which the next sync would rewrite. (The old
reason, reused book ids after a truncate, is gone with §3.)

## 7. The difference report

`data_migration:sync_report` is the sync's dry run. The sync first builds a plan (the run's scope
and, per table, what it would insert, update, delete and drop). `sync` applies it, and
`sync_report` only prints it, so the report cannot drift from the sync. It is read-only and safe to
run in production at any time. Before `sync_init`, it uses the new DB's highest legacy-origin ids in
place of the watermarks.

Illustrative output:

```
Catalog                         legacy    here   would insert   waiting (<24h)
  books (above watermark)       175,912  175,879        28            5
  authors                        80,341   80,329        12            0
  book_identifiers (new)                                41
  categories (unmapped)                                  3
  legacy deleted, still here                             3   ids: 41210, 98877, 130004
  redirects recorded                                   212   (merged 198, deleted 14)
  legacy edits to existing books, not synced           87   (updated after watermark)

User data                       legacy    here   insert  update  delete  (dropped)
  users                          69,602   69,590     12      40       —     2 deleted on legacy
  user_lists                    284,511  284,470     45     310      4
  user_list_items             3,231,004 3,229,880  1,540      —     416    9 on deleted books
  reviews                       153,446  153,444      2      18      0      1 collision
  saved_searches                  6,070    6,053     17       3      0      0 categories removed
  reading_goals / recommendation configs ...
```

How it stays cheap:

- Catalog numbers are id comparisons against the watermarks, `LegacyIdMap` and `record_redirects`.
- "Update" for users, user lists, reviews and saved searches compares `updated_at`. These
  migrators keep legacy's timestamps, so a newer legacy row means it changed.
- User list items are compared per list: item count plus a checksum of the routed book ids, on
  both sides. Only lists that differ are diffed item by item. Nothing loads all 3.2M pairs into
  memory.

The catalog half ships with increment 2, the user-data half with increment 3.

## 8. Rollout

### Increments

1. **Id reservation** (§3). Small; ships first.
2. **Redirects + catalog sync** (§4, §5, the catalog half of §7).
3. **User-data sync** (§6, the user-data half of §7), plus the `docs/launch-todo.md` rewrite.

### When cleanup can start

- **Now:** the duplicate sweep (`books:find_duplicates`). It only writes candidate pairs, which
  already survive the weekly `:all`, so pairs can be reviewed while increments 2 and 3 are built.
- **After increment 3 is deployed and `sync_init` has run:** merges, deletes,
  `books:normalize_names:apply` and hand edits.

### Switching production over

1. Run `data_migration:all` one last time to catch up.
2. Run `data_migration:sync_init`.
3. From then on, run `data_migration:sync` weekly (`sync_report` first, any time).

### After each sync (replaces section 2 of `docs/launch-todo.md`)

1. The V1 Firebase uid backfill (`firebase:backfill_v1_uids`), as today: the user overwrite still
   resets `auth_uid` from legacy.
2. `books:goodreads_replay:apply`.
3. `user_favorites_lists:rebuild` (part of the sync).
4. Rankings: list weights and book rankings; author rankings follow.
5. `data_migration:book_images`, which now covers only the new books.

### Cutover

1. Take legacy offline.
2. `FINAL=1 bin/rails data_migration:sync`.
3. The after-each-sync steps.
4. The final-pass-only steps: `finish_legacy`, and the Firebase bulk import (with its "stop
   re-running after launch" rule).

`docs/launch-todo.md` section 1 ("Before the truncate": the keep and truncate table lists, rejecting
and deleting finishing imports) is removed in increment 3.

## 9. Testing

Minitest; there are no new pages, so no Playwright spec.

- Id reservation: sequences set to the ceiling; refuses when a table's max is above it; idempotent;
  a migrator raises on a legacy id at the ceiling; finalize never pulls a sequence below it.
- Redirects: both mergers write `from → survivor`; a destroy writes `from → NULL`; a merge followed
  by the destroy keeps the merge row; chains resolve to the final survivor; a cycle raises; new-app
  ids are not recorded.
- Catalog sync: a merged or deleted book is not brought back; an edited title survives a run; a new
  legacy book arrives with its authors, editions, identifiers, categories, countries, descriptions
  and links; nothing is added to an existing book except `book_identifiers` above the watermark; a
  book under 24 hours old waits and `FINAL=1` takes it; a failed run leaves the watermarks; a new
  book's merged author lands on the survivor; `:all` refuses once watermarks exist; a mapped
  category is not overwritten.
- User-data sync: deletes stay below the ceiling, and music/games rows and new-app lists are left
  alone; list item merge collisions keep the lower position; review collisions keep the newer;
  items on deleted books are dropped; renumbering touches legacy-origin lists only; a saved search
  loses a deleted category instead of raising.
- Report: its numbers equal what the following sync does, on the same fixtures.

Fixtures need a negative class for every scoping rule: a non-legacy row next to each legacy one,
an existing book next to each new one.

**Dev rehearsal before switching production:** refresh the legacy restore (`--legacy-only`) so it
is ahead of dev, run `sync_init` with the watermarks below legacy's max, merge and edit a few books,
run `sync_report` then `sync`, and check the report's numbers against the result.

## 10. Out of scope

- Syncing legacy edits to existing catalog records (books, authors, editions, categories).
- Deleting books legacy deleted (reported only).
- Deleting users legacy deleted (counted only).
- URL redirects for merged books.
- Lists, list items, rankings and penalties (no new lists on legacy).
- Memberships and donations (separate tasks, not part of `:all`, unaffected).
