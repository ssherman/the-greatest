# Legacy sync: duplicate-key provider data, and the runbook after a sync

Small change. Approved by Shane 2026-11-12.

## Why

Shane wants to run `data_migration:sync` in production before the Goodreads re-import (launch-todo §12), so the
re-import starts from data that matches legacy. Production has never completed a sync since `sync_init`
(2026-10-10): the watermarks' `updated_at` is still the `sync_init` time.

A dev rehearsal on 2026-11-12, on copies of production and legacy from 2026-11-11, found why. The json gem went to
3.x on 2026-10-10 (ae3047d35), and json 3 raises on duplicate object keys where 2.x kept the last value. 2,797
legacy users have a duplicate key in `provider_data`, so `UserMigrator#parse_provider_data` raises on legacy
user 5 and the `users` step fails. The run stops at the second step, so nothing is lost, but no sync can
succeed.

With the parse patched in-process, the rehearsal passed in 539 s. Before/after comparison: 0 changes to
existing books, authors, author links, categories or descriptions; 0 identifiers removed; 0 changes to new-app
lists or reviews; a second `sync_report` converged to 0.

## Goals

- `data_migration:sync` succeeds on today's legacy data.
- The launch doc tells Shane exactly what to run after a sync, as things stand now.

## Non-goals

- Changing what the sync overwrites. In particular, making it keep the Goodreads re-import's moved rows is the
  separate task that re-import spec §3.9 requires before any sync after the re-import.
- Loosening the other legacy `JSON.parse` calls (saved searches, list items): they parse today's data without
  error (the rehearsal's `sync_report` parsed every saved search).

## Approaches

1. **Parse with `allow_duplicate_key: true` (chosen).** It restores json 2.x behaviour exactly (the last value
   wins), which every earlier `data_migration:all` used. One line, no data change.
2. Pin json below 3. Rejected: it holds back a dependency for one call site, and json 3 came with the Ruby
   upgrade.
3. Rescue and store `nil`. Rejected: it silently drops the provider identity of 2,797 users.

## Design

- `Services::BooksMigration::UserMigrator#parse_provider_data` calls `JSON.parse(value, allow_duplicate_key:
  true)`. A malformed string still raises, as now.
- A regression test in `user_migrator_test.rb`: a legacy user whose `provider_data` repeats a key migrates, and
  the last value wins.
- Docs, from the rehearsal:
  - `docs/launch-todo.md` §4: `firebase:backfill_v1_uids` only once the V1 Firebase import has run (the
    backfill's own contract); `goodreads_replay:apply` applies every approved verdict of any kind, not only
    relinks; `books:verify[all,recheck]` waits while the Goodreads re-import runs (one Open Library slot);
    `books:goodreads_replay:load` after the sync while the re-import is pending.
  - `docs/launch-todo.md` §12: a sync before the re-import moves any rows is fine; the steps to run first.
  - `docs/features/books-legacy-sync.md`: list items added in this app to a legacy-origin list are deleted
    when legacy lacks them (the doc said new-app rows are never touched).

## Left to the builder

Wording of the docs.
