# Books launch todo

The manual steps for moving thegreatestbooks.org onto this app, and for the weeks after. Nothing here
runs on deploy. When a merge leaves a step that someone has to run by hand at launch, add it here, with
a pointer to the doc that explains it.

Production's books data is a rehearsal copy. It is truncated and re-migrated before launch, possibly
more than once, so everything in sections 1 and 2 runs again after every pass, not only the last
one. Section 3 is the hostname switch. Section 4 is for after launch.

## 1. Before the truncate

- **Include `books_author_countries` in the truncate.** It has foreign keys to both `books_authors`
  and `books_countries`. A truncate that leaves it out fails on the constraint, and one run with
  `CASCADE` drops rows that were never meant to go. See `docs/features/books-author-enrichment.md`,
  "Launch sequence".
- **Keep these tables:**
  - `books_repair_verdicts`: the Goodreads replay re-applies its approved verdicts and skips the
    rejected ones (`docs/features/goodreads-import.md`, "Legacy replay").
  - `external_records` and `match_decisions`: the author chain gets its identifiers back from them
    (`docs/features/books-author-enrichment.md`).

## 2. The migration and what follows it

Run these in this order after each migration pass.

1. **`bin/rails data_migration:all`.** It already includes `penalties:reconcile`,
   `author_countries` and the favorites-list rebuild.
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
6. **Duplicate sweep.** Run `bin/rails "books:find_duplicates[100]"` first, then `[all]`. `[all]`
   covers about 21k ranked books on the `serial` queue and takes days. Pairs land in the Duplicates
   queue.
7. **The Goodreads replay.** Run the pass listed in `docs/features/goodreads-import.md`, "Legacy
   replay": load, fix_slugs, apply, resolve, duplicates, junk, apply, then report. Nothing changes
   the catalog until `config.x.goodreads_replay.auto_apply` is on. Turn it on only after the
   50-per-kind hand check (spec §12.9).
8. **Finish the failed and stuck legacy Goodreads imports, on the final pass only.** A rehearsal run is
   wiped by the next truncate. After the replay's `load`, `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy`
   lists what it would do. Then run `bin/rails "books:goodreads_replay:finish_legacy[5]"` until nothing starts. Each
   import fetches Goodreads pages on the line member uploads use, so batches keep it from crowding them out. Approve
   or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`, "Finishing legacy
   imports".

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
