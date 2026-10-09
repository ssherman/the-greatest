# Books launch todo

The manual steps for moving thegreatestbooks.org onto this app, and for the weeks after. Nothing here
runs on deploy. When a merge leaves a step that someone has to run by hand at launch, add it here, with
a pointer to the doc that explains it.

Production's books data is a rehearsal copy. It is truncated and re-migrated before launch, possibly
more than once, so sections 1 and 2 run again after every pass, not only the last one, except where
an item says otherwise. Section 3 is the hostname switch. Section 4 is for after launch.

## 1. Before the truncate

- **Include `books_author_countries` in the truncate.** It has foreign keys to both `books_authors`
  and `books_countries`. A truncate that leaves it out fails on the constraint, and one run with
  `CASCADE` drops rows that were never meant to go. See `docs/features/books-author-enrichment.md`,
  "Launch sequence".
- **Put `books_open_library_backfills` in the truncate list.** It has foreign keys to `books_books`
  (`book_id` and `pair_book_id`). A truncate that leaves it out fails on the constraint, and `CASCADE`
  is not the answer. Stale log rows would also make the next backfill skip re-migrated books whose
  old keys are back. See `docs/features/open-library-backfill.md`.
- **Keep these tables:**
  - `books_repair_verdicts`: the Goodreads replay re-applies its approved verdicts and skips the
    rejected ones (`docs/features/goodreads-import.md`, "Legacy replay").
  - `external_records` and `match_decisions`: the author chain gets its identifiers back from them
    (`docs/features/books-author-enrichment.md`).
  - `books_goodreads_imports` (with their ActiveStorage attachments) and `books_goodreads_pages`: the
    replay's `load` reuses the uploads instead of downloading them again, admin rejections of
    finishing imports stick, and the Goodreads page cache is not fetched again.
- **Put `books_goodreads_editions` and `books_goodreads_import_rows` in the truncate list.** The
  replay rebuilds them.
- **Before any truncate, reject and then delete every import that finishes a legacy one** (section 2,
  item 9). Finished or approved is not enough. Its rows hold the only ids of the list items and
  reviews it wrote, and those outlive the truncate while the rows do not. Rejecting first removes
  them while the ids are still there. Deleting it afterwards lets the final pass create it fresh.
  One left in place is reported `stale` from then on and never runs again. Its items and reviews
  can no longer be found by the import.

## 2. The migration and what follows it

Run these in this order after each migration pass.

1. **`bin/rails data_migration:all`.** It already includes `penalties:reconcile`,
   `author_countries` and the favorites-list rebuild.
   It now also includes `recommendation_configs` (the 33 legacy recommendation settings, 9 of
   them paid users'). It re-runs safely on every rehearsal pass; `exclude_locations` is dropped
   on purpose.
2. **Search and rankings.** The migrators load with search indexing off, so new records are not in
   OpenSearch until you run `bin/rails search:books:recreate_and_reindex_all`. Then recalculate the
   books list weights and rankings. Author rankings follow from the book rankings:
   `Books::CalculateAuthorRankingsJob` runs on the 04:00 UTC cron, or by hand.
3. **Cover images.** Make sure Sidekiq is up, because this queues about 148k jobs. Then run
   `bin/rails data_migration:book_images`. It is idempotent, and the primary-image count should
   come out close to 37,296.
4. **V1 Firebase accounts.** Follow the four steps in `docs/features/v1-user-migration.md`,
   "Running it": export, import, `firebase:backfill_v1_uids`, then shred the file. The import comes
   before the backfill. Truncating resets `users.auth_uid`, so the backfill runs on every pass.
5. **Stored-name normalization.** `ANALYZE` the tables that have `lower()` expression indexes. Then
   run `bin/rails books:normalize_names:report`, and after reading its output,
   `books:normalize_names:apply`.
6. **Open Library key backfill.** Run `bin/rails "books:ol_backfill[100]"`, read
   `bin/rails books:ol_backfill_report`, then `bin/rails "books:ol_backfill[all]"`. It checks or adds an
   Open Library key on every book, ranked first. Top-ranked books ran at about 4 books a minute before
   the fast pass was sped up, so the full run is likely 2-4 weeks and the top few thousand ranked books
   finish in the first days. It shares Open Library's one
   `/resolve` slot with the wizard and the Goodreads replay, so all of them slow down while it runs.
   It pauses 4 seconds after each `/resolve` so the others can get the slot, but
   do not run the Goodreads replay or the legacy-import finishing steps while it runs: when they
   cannot get the slot they decide rows without Open Library. Every merge deploys, and a deploy stops
   a running backfill (it is not requeued), so expect to run the task again during the weeks it runs;
   it carries on, because logged books are skipped. Its log is keyed to book ids, so every
   migration pass starts it from scratch.
   Details: `docs/features/open-library-backfill.md`.
7. **Duplicate sweep.** Run `bin/rails "books:find_duplicates[100]"` first, then `[all]`. `[all]`
   covers about 21k ranked books on the `serial` queue and takes days. Pairs land in the Duplicates
   queue.
8. **The Goodreads replay.** Run these in order. Sidekiq must be running for `resolve`.

   ```bash
   bin/rails books:goodreads:seed_legacy_pages   # legacy scraped Goodreads pages into the page cache (~39k)
   bin/rails books:goodreads_replay:load         # the legacy imports: uploads (legacy R2) and rows
   bin/rails books:goodreads_replay:fix_slugs
   bin/rails books:goodreads_replay:apply
   bin/rails books:goodreads_replay:resolve      # queues jobs; re-run until both counts are 0
   bin/rails books:goodreads_replay:duplicates
   bin/rails books:goodreads_replay:junk
   bin/rails books:goodreads_replay:apply
   bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
   ```

   - `seed_legacy_pages` only needs to run once, because the page cache is kept across truncates
     (section 1). It never overwrites a cached page, so running it again is harmless.
   - Nothing changes the catalog until `config.x.goodreads_replay.auto_apply` is on. Until then the
     replay only records proposed fixes, under Books → Repair Verdicts. Turn it on only after the
     50-per-kind hand check (spec §12.9).
   - Details: `docs/features/goodreads-import.md`, "Legacy seed" and "Legacy replay".
9. **Finish the failed and stuck legacy Goodreads imports, on the final pass only.** Never run it on a
   rehearsal pass in production. It writes list items and reviews for real users, and a truncate does
   not remove them: those tables have no foreign key to books. The truncate deletes the provisional
   books they point at, the re-migration resets the books id sequence, and new books then take those
   ids, so the users' lists and reviews end up on unrelated books.
   - If it was run on a rehearsal anyway: before the truncate, let any that is still running finish,
     reject each finishing import under Books → Goodreads Imports (that removes what it wrote), then
     delete those finishing imports, or the rejection keeps them from running on the final pass.
   - On the final pass, after the replay's `load`: `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy`
     lists what it would do. Then run `bin/rails "books:goodreads_replay:finish_legacy[1]"`, one import at
     a time, and wait until it is no longer in progress before running the next. Running imports are
     skipped, not counted, so starting them back to back queues them all at once. Four at once
     overloaded the Open Library VM on 2026-10-06 (see the next item). Each import also fetches
     Goodreads pages on the line member uploads use.
   - Approve or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`,
     "Finishing legacy imports".

10. **Open Library `/resolve` under parallel load: done in #358.** On 2026-10-06 four Goodreads imports
   resolving at once left `/resolve` timing out at 60 s for 25 minutes, until the API container was
   restarted. Queries the Rails client had abandoned kept running and piled up in one 6 GB DuckDB pool.
   #358 runs one `/resolve` at a time, answers the rest with an instant 503 busy, and stops a query at
   a server-side deadline. The Rails client waits out a busy reply within its 60 s budget, and busy
   never counts toward the breaker.
   - What remains is capacity. A `/resolve` takes about 13 s, and every caller shares the one slot.
     A client that cannot get the slot within its budget gives up, and the finder decides that row
     without Open Library. Watch the flag rate when many members upload at once after launch.

### Decide at launch

- **Author enrichment:** `bin/rails "books:authors:enrich[all]"`, or `[13654]` for the ranked
  authors only. About 58k authors have no ranked book. Only after the final migration.
- **Book AI enrichment:** `bin/rails "books:enrich_missing[<limit>]"`. Nothing queues it
  automatically.
- **Amazon enrichment of ranked books:** `bin/rails books:amazon_enrich_ranked`. It has never been
  run.

## 3. Cutover: pointing thegreatestbooks.org at this app

- **Issue the TLS certificate on the server before merging the hostname change.** Merging deploys.
  If nginx references a certificate that doesn't exist, it crash-loops, and one nginx container
  fronts every site. The deploy job still shows green.
- **Firebase authorized domains** must list every books hostname that sign-in and the reset emails
  use. A missing domain fails silently on password reset.
- **Stripe, in this order** (`docs/guides/stripe-account-setup.md`, sections 7 and 11):
  1. Re-check the legacy guard just before launch (section 7).
  2. Delete legacy's webhook endpoint by hand in the Stripe Dashboard. Never run
     `rake stripe:delete_webhooks` once the hostname points here: it would delete this app's
     endpoint.
  3. Retire legacy's `/support`.
  4. Run `bin/rails billing:backfill_email_stamps`.
  5. Set `MEMBERSHIP_EMAIL_SCOPE=all`.

  If you reverse steps 4 and 5, or skip step 4, every legacy member gets a welcome email at the
  next 05:00 UTC sweep.
- After the deploy, check Admin → Webhook Events for `ignored` rows.

## 4. After launch

- **Stop re-running the Firebase bulk import** from section 2. An import replaces the whole account,
  so once real people use these accounts it would reset changed passwords and verified emails.
  The export and `firebase:backfill_v1_uids` stay safe to re-run.
- **The Open Library key and duplicate-key backfill** (books list wizard) waits until after the
  switch. It is not specced yet.
- **Remove the `LEGACY_R2_*` credentials from production secrets** after the last replay load and
  the last cover-image run.
- **Remove the stale `FIREBASE_PROJECT_ID`** from production secrets. The project id is hardcoded
  now, so the variable does nothing and could mislead someone later.
