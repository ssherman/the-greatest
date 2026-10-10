# Books launch todo

The manual steps for moving thegreatestbooks.org onto this app, and for the weeks after. Nothing here
runs on deploy. When a merge leaves a step that someone has to run by hand at launch, add it here, with
a pointer to the doc that explains it.

Production's books data is not truncated before launch any more. Until the switch-over (section 2) the
weekly `data_migration:all` keeps it in step with legacy. From the switch-over on, this database's
books catalog is the master: merges, deletes and fixes made here stay, and the weekly
`data_migration:sync` brings over only what is new on legacy while keeping legacy users' lists,
reviews and saved searches matched to legacy. Details: `docs/features/books-legacy-sync.md`.

## 1. Until the switch-over: the weekly full migration

Run these in this order after each `data_migration:all`.

1. **`bin/rails data_migration:all`.** It includes `penalties:reconcile`, `author_countries`,
   `recommendation_configs` and the favorites-list rebuild.
2. **Search and rankings.** The migrators load with search indexing off, so run
   `bin/rails search:books:recreate_and_reindex_all`.
   Then use the admin **Refresh Rankings** action on the books primary. That one run reweighs,
   ranks and requests the author rankings when it lands. The 04:00 UTC author cron is the safety
   net. **The release after this one ships deletes the transitional `CalculateRankingsJob` shim**
   (see `docs/superpowers/specs/2026-10-10-coalesced-ranking-recalculation-design.md` §4).
   Before deleting it, check Sidekiq's scheduled and retry sets for `CalculateRankingsJob`
   entries. Any still waiting would die with `NameError`.
3. **Cover images.** Make sure Sidekiq is up, because this queues about 148k jobs. Then run
   `bin/rails data_migration:book_images`. It is idempotent, and the primary-image count should
   come out close to 37,296.
4. **V1 Firebase accounts.** Follow the four steps in `docs/features/v1-user-migration.md`,
   "Running it": export, import, `firebase:backfill_v1_uids`, then shred the file. The import comes
   before the backfill. The user overwrite resets `users.auth_uid`, so the backfill runs every time.

The duplicate sweep can already run: `bin/rails "books:find_duplicates[100]"` first, then `[all]`
(about 21k ranked books on the `serial` queue, days). It only writes candidate pairs, and those
survive the weekly run. Do not merge, delete or edit books yet: the next `:all` would undo it.

## 2. Switching over (once)

1. **Before** starting the final `:all`, read legacy's highest `book_identifiers` id:
   `bin/rails runner 'puts LegacyBooks::BookIdentifier.maximum(:id)'`.
2. Run the final `data_migration:all` and the section 1 steps after it.
3. `BOOK_IDENTIFIERS_FROM=<that id> bin/rails data_migration:sync_init`.

From then on `data_migration:all`, the catalog tasks and the user-data tasks the sync replaces refuse
to run. Cleanup can start (section 5).

## 3. The collaborative-filtering model (once, after spec 2 increment 2 merges)

Depends only on spec 2's increment 2 (the home-server timer) being merged, not on the switch-over.
Until the store is configured, the nightly export and hourly load jobs log "recommendations store
not configured; skipping" and do nothing; if only some of the `RECOMMENDATIONS_R2_*` variables are
set, they raise. Details: `docs/features/recommendations.md`, "Collaborative signal".

1. **The bucket.** Create the private R2 bucket and a token scoped to it. Put
   `RECOMMENDATIONS_R2_ACCESS_KEY/SECRET_KEY/BUCKET` in the production SOPS secrets (the endpoint defaults to `STORAGE_ENDPOINT`), and `RECOMMENDER_R2_*` +
   `HC_RECOMMENDER` in `secrets/home-server.env`.
2. **The check.** Create the healthchecks.io check `recommender-train` (period 1 day, grace 2 days).
3. **The home server.** Run `deployment/home-server/provision` so the `ol` VM gets the units and env.
4. **The first model.** `Recommendations::ExportInteractionsJob.perform_async("books")` from a
   console (or wait for the 02:30 UTC run), let the home server's `recommender-train` timer run (04:00 Chicago;
   or `systemctl start recommender-train` on the `ol` VM), then confirm `Recommendations::LoadModelJob`
   loaded it (`RecommendationModel.active_for(:books)`) and that
   `bin/rails recommendations:show USER_ID=…` lists `collaborative`.

After that the nightly export, daily train and hourly load keep it current through every weekly
`data_migration:sync`; after a sync, step 4's `perform_async` and `systemctl start` bring the model
up to date the same day instead of the next.

5. **Before books goes live.**
   - Cap the shelf the signal scores (an 18,534-book shelf takes 1.1 s in the neighbour SQL today),
     and profile the +140-215 ms the signal adds on the 20-99 and 100+ segments (the harness `ms` column is confounded by variant order; see the data-quality record).
   - Close the depth gap: the collaborative list ignores the depth setting (see "Known gaps" in
     `docs/features/recommendations.md`).

## 4. Every week after the switch-over

1. **`bin/rails data_migration:sync_report`.** Read-only, safe any time. A `MISSING` line means the
   sync will fail on rows whose book was removed without callbacks. A large delete count means
   legacy looks wrong: check it before syncing.
2. **`bin/rails data_migration:sync`.** It brings over new books and authors (with their cover
   images and search indexing), new book identifiers, users, user lists and list items, reading
   goals, saved searches, recommendation settings, reviews and corrections, then rebuilds the
   favorites lists. A step that would delete more than 5% of a table (and over 500 rows) refuses;
   if the deletions are real, re-run with `SYNC_ALLOW_DELETES=1`.
3. **`bin/rails firebase:backfill_v1_uids`.** The user overwrite still resets `auth_uid` from legacy.
4. **`bin/rails books:goodreads_replay:apply`.** The sync puts legacy users' list items and reviews
   back the way legacy has them, which undoes the replay's approved relinks until this re-applies
   them.
5. **Rankings.** The books list weights and book rankings. Author rankings follow.

## 5. Cleanup, after the switch-over

These change the catalog, so they wait for section 2. Each runs once, not after every sync, because
the sync never undoes them.

1. **Stored-name normalization.** `ANALYZE` the tables that have `lower()` expression indexes. Then
   run `bin/rails books:normalize_names:report`, and after reading its output,
   `books:normalize_names:apply`.
2. **Open Library key backfill.** Run `bin/rails "books:ol_backfill[100]"`, read
   `bin/rails books:ol_backfill_report`, then `bin/rails "books:ol_backfill[all]"`. It checks or adds an
   Open Library key on every book, ranked first. Top-ranked books ran at about 4 books a minute before
   the fast pass was sped up, so the full run is likely 2-4 weeks and the top few thousand ranked books
   finish in the first days. It shares Open Library's one `/resolve` slot with the wizard and the
   Goodreads replay, so all of them slow down while it runs. It pauses 4 seconds after each
   `/resolve` so the others can get the slot, but do not run the Goodreads replay or the
   legacy-import finishing steps while it runs: when they cannot get the slot they decide rows
   without Open Library. A deploy puts a running backfill back on the queue and it carries on
   under the same run id; logged books are skipped. If the worker crashes instead, the run is lost:
   run the task again. Details: `docs/features/open-library-backfill.md`.
3. **Duplicates.** Review the pairs the sweep found in the Duplicates queue and merge them. Every
   merge is recorded as a redirect, so the sync never brings the merged book back.
4. **The Goodreads replay.** Run these in order. Sidekiq must be running for `resolve`.

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

   - `seed_legacy_pages` only needs to run once. It never overwrites a cached page, so running it
     again is harmless.
   - Nothing changes the catalog until `config.x.goodreads_replay.auto_apply` is on. Until then the
     replay only records proposed fixes, under Books → Repair Verdicts. Turn it on only after the
     50-per-kind hand check (spec §12.9).
   - Its merges and provisional marks are catalog changes and stick. Its relinks of legacy users'
     list items and reviews are undone by each sync and re-applied by `apply` (section 4).
   - Details: `docs/features/goodreads-import.md`, "Legacy seed" and "Legacy replay".
5. **Open Library `/resolve` under parallel load: done in #358.** On 2026-10-06 four Goodreads imports
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
  authors only. About 58k authors have no ranked book. After the switch-over.
- **Book AI enrichment:** `bin/rails "books:enrich_missing[<limit>]"`. Nothing queues it
  automatically.
- **Amazon enrichment of ranked books:** `bin/rails books:amazon_enrich_ranked`. It has never been
  run.

## 6. Cutover

1. Take legacy offline.
2. `FINAL=1 bin/rails data_migration:sync`. `FINAL=1` drops the 24-hour delay, so the last day's
   books come over too. Run `sync_report` with `FINAL=1` first.
3. Section 4, steps 3-5.
4. **Finish the failed and stuck legacy Goodreads imports.** Only now: they write into legacy users'
   lists, which every sync rewrites to match legacy, so a finishing import run earlier is undone by
   the next sync.
   - `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy` lists what it would do. Then run
     `bin/rails "books:goodreads_replay:finish_legacy[1]"`, one import at a time, and wait until it is
     no longer in progress before running the next. Running imports are skipped, not counted, so
     starting them back to back queues them all at once. Four at once overloaded the Open Library VM
     on 2026-10-06 (section 5, item 5). Each import also fetches Goodreads pages on the line member
     uploads use.
   - Approve or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`,
     "Finishing legacy imports".
5. **The Firebase bulk import, one last time** (`docs/features/v1-user-migration.md`, "Running it"),
   then never again (section 8).

## 7. Pointing thegreatestbooks.org at this app

- **Issue the TLS certificate on the server before merging the hostname change.** Merging deploys.
  If nginx references a certificate that doesn't exist, it crash-loops, and one nginx container
  fronts every site. The deploy job still shows green.
- **Firebase authorized domains** must list every books hostname that sign-in and the reset emails
  use. A missing domain fails silently on password reset.
- **Stripe, in this order** (`docs/guides/stripe-account-setup.md`, sections 7 and 11):
  1. Re-check the legacy guard just before launch (section 8).
  2. Delete legacy's webhook endpoint by hand in the Stripe Dashboard. Never run
     `rake stripe:delete_webhooks` once the hostname points here: it would delete this app's
     endpoint.
  3. Retire legacy's `/support`.
  4. Run `bin/rails billing:backfill_email_stamps`.
  5. Set `MEMBERSHIP_EMAIL_SCOPE=all`.

  If you reverse steps 4 and 5, or skip step 4, every legacy member gets a welcome email at the
  next 05:00 UTC sweep.
- After the deploy, check Admin → Webhook Events for `ignored` rows.

## 8. After launch

- **Stop re-running the Firebase bulk import.** An import replaces the whole account, so once real
  people use these accounts it would reset changed passwords and verified emails. The export and
  `firebase:backfill_v1_uids` stay safe to re-run.
- **The Open Library key and duplicate-key backfill** (books list wizard) waits until after the
  switch. It is not specced yet.
- **Remove the `LEGACY_R2_*` credentials from production secrets** after the last replay load and
  the last cover-image run.
- **Remove the stale `FIREBASE_PROJECT_ID`** from production secrets. The project id is hardcoded
  now, so the variable does nothing and could mislead someone later.
