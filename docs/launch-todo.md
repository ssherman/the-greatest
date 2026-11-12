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
   net.
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
   `RECOMMENDATIONS_R2_ACCESS_KEY/SECRET_KEY/BUCKET` in the production SOPS secrets (the endpoint defaults to `STORAGE_ENDPOINT`), and `RECOMMENDATIONS_R2_*` +
   `HC_RECOMMENDER` in `secrets/home-server.env`.
2. **The check.** Create the healthchecks.io check `recommender-train` (period 1 day, grace 2 days).
3. **The home server.** Run `deployment/home-server/provision` (`SOPS_AGE_KEY_FILE` set) so the `ol` VM gets the new env. A VM tracking `main` installs `recommender-train.timer` and builds the trainer image within 15 minutes of the merge, before anyone provisions; `provision` then pushes the env file and forces an immediate deploy. `provision --verify` then reports `ol: recommender-train.timer is enabled`. If the VMs were pointed at a branch to test this, `provision --ref main` goes **before** the merge: GitHub deletes the merged branch and a VM tracking it fails its next deploy. Until the first export exists in the bucket, each 04:00 run pings `fail` with `no export published for books`; that is expected, and step 4 the same day ends it.
4. **The first model.** `Recommendations::ExportInteractionsJob.perform_async("books")` from a
   console (or wait for the 02:30 UTC run), let the home server's `recommender-train` timer run (04:00 UTC;
   or `sudo systemctl start recommender-train` on the `ol` VM, then `journalctl -u recommender-train` for the trainer's output), then confirm `Recommendations::LoadModelJob`
   loaded it (`RecommendationModel.active_for(:books)`) and that
   `bin/rails recommendations:show USER_ID=…` lists `collaborative`.

After that the nightly export, daily train and hourly load keep it current through every weekly
`data_migration:sync`; after a sync, the next 02:30 export and 04:00 train pick it up by themselves; running step 4's
`perform_async` and `systemctl start` by hand only helps before that day's 04:00 run, because a
second export on the same day reuses the day's file name and the trainer reports it already trained.

5. **Before books goes live.**
   - Cap the shelf the signal scores (an 18,534-book shelf takes 1.1 s in the neighbour SQL today),
     and profile the +140-215 ms the signal adds on the 20-99 and 100+ segments (the harness `ms` column is confounded by variant order; see the data-quality record).
   - Depth: the three settings now build three different pages (2026-10-10); the collaborative
     list still ignores the quality prior, which at its 0.25 weight is two picks in twenty (see
     "Known gaps" in `docs/features/recommendations.md`).

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
5. **`bin/rails books:goodreads_replay:repair_ratings`.** Run it after `apply`. The sync overwrites
   legacy-origin reviews with legacy's truncated integer rating (3 for a 3.75), and this puts the
   fractional rating back.
6. **Rankings.** The books list weights and book rankings. Author rankings follow.
7. **`bin/rails "books:verify[all,recheck]"`** after the sync, once the pass has run. The sync keeps
   adding legacy identifiers; this re-verifies the books that got new ones. Once the `post_import`
   books have been verified, the recheck needs `post_import` too
   (`books:verify[all,recheck,post_import]`).
8. **`bin/rails "worldcat:backfill[verified]"`** (once section 9 is live), after the recheck above. The
   sync brings over new books without WorldCat-derived categories, and the backfill reads verified
   ISBN-13s only, which the new books do not have until the recheck verifies them. It is additive and
   idempotent, so a full run only adds links for books that have none yet; links are recorded as
   source `worldcat`. It is a repeating step, not a one-off. `books:verify` covers ranked books by default,
   so unranked books added by the sync get no WorldCat links; that is by design.
9. **`bin/rails books:authors:merge_unknown`, then again with `APPLY=1`.** The sync brings legacy
   authors over directly, so a new "Anonymous" or "Unknown Author" from legacy skips the import finder
   that maps those names onto the one Unknown author. The dry run lists what it would merge; `APPLY=1`
   queues `Books::MergeUnknownAuthorsJob`, which merges them through the author merger and asks for one
   author ranking refresh. Idempotent: with nothing left it prints "Nothing to merge." The first run
   after the deploy that adds it merges the backlog (in dev, 35 authors into "Unknown").
10. **Optional, manual: `bin/rails "books:categorize:backfill[all,all,weekly]" APPLY=1`**. It covers origin and
   categories; under `all` each book is planned with only the judgment it still lacks. Run it only after
   section 14 step 2 (the definitions), step 3 (the categories judge switch) and step 4 (the origin backfill and the categories backfill, or one `[all,...]`
   run) have been done once: `all` weekly before the categories backfill would plan the whole catalog for
   categories. It needs `APPLY=1` like those steps. Re-running it
   after the sync picks up the books the sync added; it plans only the books the sync added and the books a deferred
   research or a failure left undone (deferred books only while `categorize_backfill_research_daily_cap` is above 0: at 0 they wait until you raise it). Books with a running import are left to their import. While the
   section 14 backfill is still running, the weekly run reports almost every book as reused, and new books
   start after the backfill's last slot.

## 5. Cleanup, after the switch-over

These change the catalog, so they wait for section 2. Each runs once, not after every sync, because
the sync never undoes them.

1. **Stored-name normalization.** `ANALYZE` the tables that have `lower()` expression indexes. Then
   run `bin/rails books:normalize_names:report`, and after reading its output,
   `books:normalize_names:apply`.
2. **Identifier provenance, once.** After the deploy that adds `identifiers.source`, run
   `bin/rails identifiers:mark_legacy`. It marks every books identifier with no source `legacy` and
   prints how many; a second run prints 0. Details: `docs/features/identifier-provenance.md`.
3. **Book verification pass.** Run `bin/rails "books:verify[200]"`, read `bin/rails books:verify_report`
   (hand-check the risky list and the samples), then `bin/rails "books:verify[all]"`. It settles each
   ranked book's Open Library work, takes identifiers from the work's editions, confirms held ISBNs
   against WorldCat and records signals. Next run
   `bin/rails "books:verify[all,post_import,trusted]"`: the post-import books on a real list, which you
   added by hand, so they don't wait for the rebuild. After the Goodreads rebuild, run
   `bin/rails "books:verify[all,post_import]"`; `unranked` is optional and takes the rest of the
   catalogue. The ranked `pre_import` books are estimated at 3-4 days. It shares Open Library's one
   `/resolve` slot with the wizard and the Goodreads replay, so all of them slow down while it
   runs. It pauses 4 seconds after each `/resolve` so the others can get the slot, but do not run
   the Goodreads replay or the legacy-import finishing steps while it runs: when they cannot get
   the slot they decide rows without Open Library. A deploy puts a running pass back on the queue
   and it carries on under the same run id; logged books resume at their stage. If the worker
   crashes instead, the run is lost: run the task again. Details:
   `docs/features/book-verification.md`.
   **Unsure books second chance, once, after the deploy that carries it:** first wait for the
   running `books:verify[all]` pass to finish (only one run works at a time, and the second chance
   should see every book that pass leaves unsure). Then check with a count that every done unsure or
   removed row is ranked `pre_import`, because the default scope covers only those:
   ```bash
   bin/rails runner 'ranked = RankedItem.where(ranking_configuration_id: Books::RankingConfiguration.default_primary.id, item_type: "Books::Book").where.not(rank: nil).select(:item_id); rows = Books::Verification.stage_done.where(work_outcome: %i[unsure removed]); puts "all #{rows.count}, ranked pre_import #{rows.where(book_id: ranked).where.not(book_id: Services::Books::Verification::Cohort.post_import_range).count}"'
   ```
   (2026-10-24: both 4,137.) Run the alternate-titles `undo_findings[apply]` (section 10) first,
   so the second chance compares against the cleaned titles. Start with a batch of 50:
   `bin/rails "books:verify[50,second_chance]"`, then `bin/rails books:verify_report`, and check the
   books that settled (the dev rehearsal of 2026-10-24 settled 22 of 50, about 30 seconds a book).
   Then, if the two numbers are equal, run `bin/rails "books:verify[all,second_chance]"` (about a
   day and a half for 4,137 books); if not, add
   `unranked` and/or `post_import` to cover the rest. Settled books go on through stages 2-4, so the
   run makes more Open Library calls and writes than the lookups alone. Then
   `bin/rails books:verify_report`. Spot-check per route: read the "via <route>" samples for
   `resolve_candidate`, `exact_title`, `held_key` and `worldcat_isbns`, the `second_chance_matcher`
   count, and the top books by Goodreads rows. If a route is wrong, undo it with
   `bin/rails "books:verify_revert_route[<route>]"` (`second_chance_matcher` undoes the books the
   run settled through Open Library's own matcher); undo one book with
   `bin/rails "books:verify_revert[<book id>]"`, which undoes only its second chance. Leave the flag
   off routine runs: a rerun repeats the same lookups.
   (2026-10-26: second chance done in production, unsure 4,011 to 2,482.)
   **Keep the bigger held work, once, after the deploy that carries it:** `bin/rails
   books:verify_keep_bigger` (dry run: about 278 books on the 2026-10-26 copy, with samples), then
   `bin/rails "books:verify_keep_bigger[apply]"`. It reverts those books and queues a redo run over
   them (about 30 seconds a book, so roughly 2½ hours); nothing else may run verification meanwhile.
   Then `books:verify_report`, and the dry run again: it should list almost none. Details:
   `docs/features/book-verification.md`, "Keeping the bigger held work".
4. **Duplicates.** Review the pairs the sweep found in the Duplicates queue and merge them. Every
   merge is recorded as a redirect, so the sync never brings the merged book back.
5. **The Goodreads replay.** Run these in order. Sidekiq must be running for `resolve`.
   Deploy the quarter-star ratings branch before the first production `books:goodreads_replay:load`.
   `ParseRows` skips rows it already wrote, and pre-branch code drops fractional and `4.0` ratings
   as unreadable. After that, `repair_ratings` finds no candidates and `finish_legacy` writes
   unrated reviews.

   ```bash
   bin/rails books:goodreads:seed_legacy_pages   # legacy scraped Goodreads pages into the page cache (~39k)
   bin/rails books:goodreads_replay:load         # the legacy imports: uploads (legacy R2) and rows
   bin/rails books:goodreads_replay:fix_slugs
   bin/rails books:goodreads_replay:apply
   bin/rails books:goodreads_replay:resolve      # queues jobs; re-run until both counts are 0
   bin/rails books:goodreads_replay:duplicates
   bin/rails books:goodreads_replay:junk
   bin/rails books:goodreads_replay:apply
   bin/rails books:goodreads_replay:repair_ratings   # quarter-star ratings the legacy importer truncated
   bin/rails "books:goodreads_replay:report[../docs/data-quality/goodreads-replay.md]"
   ```

   - `seed_legacy_pages` only needs to run once. It never overwrites a cached page, so running it
     again is harmless.
   - `apply` changes the catalog only through approved verdicts, under Books → Repair Verdicts.
     `config.x.goodreads_replay.auto_apply` gates it and has been on since 2026-10-14, after the
     first production replay's 50-per-kind hand check (spec §12.9).
   - Its merges and provisional marks are catalog changes and stick. Its relinks of legacy users'
     list items and reviews are undone by each sync and re-applied by `apply` (section 4).
     `repair_ratings` repeats every pass for the same reason: each sync puts
     legacy's truncated integer rating (3 for a 3.75) back.
   - Details: `docs/features/goodreads-import.md`, "Legacy seed" and "Legacy replay".
6. **Books categories cleanup.** Run the runbook in `docs/features/books-categories.md` in production
   from a fresh backup: propose every stage, report, owner review and reject, apply, then trim
   (dry run first). It can run before or after cutover, because the post-sync step keeps new legacy
   categories in line once a cleanup has been applied. Re-run `propose` occasionally for what that
   step leaves undecided.
7. **Open Library `/resolve` under parallel load: done in #358.** On 2026-10-06 four Goodreads imports
   resolving at once left `/resolve` timing out at 60 s for 25 minutes, until the API container was
   restarted. Queries the Rails client had abandoned kept running and piled up in one 6 GB DuckDB pool.
   #358 runs one `/resolve` at a time, answers the rest with an instant 503 busy, and stops a query at
   a server-side deadline. The Rails client waits out a busy reply within its 60 s budget, and busy
   never counts toward the breaker.
   - What remains is capacity. A `/resolve` takes about 13 s, and every caller shares the one slot.
     A client that cannot get the slot within its budget gives up, and the finder decides that row
     without Open Library. Watch the flag rate when many members upload at once after launch.

### Decide at launch

- **Author enrichment:** `bin/rails "books:authors:enrich[all]"`, or `[13333]` for the ranked
  authors only (the 2026-11-09 count; section 15 step 11 runs it). About 58k authors have no ranked book. After the switch-over.
- **Book AI enrichment:** `bin/rails "books:enrich_missing[<limit>]"`. Nothing queues it
  automatically.
- **Amazon enrichment of ranked books:** `bin/rails books:amazon_enrich_ranked`. It has never been
  run. It now also writes book-level `books_work_*` identifiers (source amazon) and raises
  `identifier_collision` duplicate candidates. Run it AFTER the verification pass and WorldCat stamping, so
  the verified-collision guard has verified values to compare against.

## 6. Cutover

1. Take legacy offline.
2. `FINAL=1 bin/rails data_migration:sync`. `FINAL=1` drops the 24-hour delay, so the last day's
   books come over too. Run `sync_report` with `FINAL=1` first.
3. Section 4, steps 3-10.
4. **Finish the failed and stuck legacy Goodreads imports.** Only now: they write into legacy users'
   lists, which every sync rewrites to match legacy, so a finishing import run earlier is undone by
   the next sync.
   - `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy` lists what it would do. Then run
     `bin/rails "books:goodreads_replay:finish_legacy[1]"`, one import at a time, and wait until it is
     no longer in progress before running the next. Running imports are skipped, not counted, so
     starting them back to back queues them all at once. Four at once overloaded the Open Library VM
     on 2026-10-06 (section 5, item 7). Each import also fetches Goodreads pages on the line member
     uploads use.
   - Approve or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`,
     "Finishing legacy imports".
5. **The Firebase bulk import, one last time** (`docs/features/v1-user-migration.md`, "Running it"),
   then never again (section 8).
6. **Let the new worker server reach search.** When web and worker move to separate servers, add the
   worker server's IPv4 to `OPENSEARCH_ALLOWED_IPS` (`sops secrets/.env.opensearch`), merge, and run
   the "Deploy OpenSearch" workflow before the worker starts using search. See
   `docs/features/opensearch-server.md`, "Add or remove an app server".

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
- **Remove the old site's server from the search allowlist.** When the old site's web/worker server
  is shut down, remove its IP from `OPENSEARCH_ALLOWED_IPS` and run the "Deploy OpenSearch"
  workflow. Removing an IP does not cut connections it already has open; the runbook's "Add or remove
  an app server" says how.
- **Remove the stale `FIREBASE_PROJECT_ID`** from production secrets. The project id is hardcoded
  now, so the variable does nothing and could mislead someone later.

## 9. WorldCat genre data (the service once; the backfill repeats)

Adds the WorldCat exact-lookup service on the home server and backfills genre categories from it.
Independent of section 2: the switch-over ran on 2026-10-10 (`data_migration:sync_init`), so the
category links the backfill writes in production are kept across the weekly `data_migration:sync`.
The sync does add new books, though, so the backfill (step 15) is also section 4 step 8: it re-runs
after every sync and again at cutover (section 6, step 3).
Details: `docs/features/worldcat-data-service.md`; the VM runbook is
`docs/features/home-server.md`, "Loading the WorldCat artifact (once)".

Steps marked "Shane runs with `!`" change DNS, Cloudflare or production, so an agent does not run them.

1. **Build the artifact on the dev machine.** Export our ISBNs for the coverage gate, then build with
   them (the `--catalogue-isbns` file is what the gate checks against; the command is in
   `data-sources/README.md`, "Running the WorldCat API"):
   `bin/rails "worldcat:export_isbns[/home/shane/wc-data/our_isbns.txt]"`, then
   `uv run python -m worldcat.pipeline.build ... --catalogue-isbns /home/shane/wc-data/our_isbns.txt`
   from `data-sources/`. The result will be `/home/shane/wc-data/versions/2025-09-04/`, and the build
   fails unless every gate passes. If it dies after extract (an hour), rerun with `--resume` to
   distill the shards it left rather than extracting again.
2. **Cloudflare, before anything touches the home server. Shane runs with `!`. DONE 2026-10-14.**
   Nothing here is done in the dashboard: `bin/cfzerotrust apply --secrets-root <this checkout>` in
   `the-greatest-cloudflare` reads `zerotrust/home-server.yml`, which now names the `worldcat-api`
   Access app (the `prod-rails` service token), the `home-worldcat` tunnel with ingress
   `http://worldcat:8082`, and its CNAME. The same apply writes `WORLDCAT_TUNNEL_TOKEN` into
   `secrets/home-server.env` and `WORLDCAT_SERVICE_URL` into `secrets/.env.production`, so there is
   no token to copy. The bot skip is the `skip_edge_for_home_server` rule in
   `zones/thegreatestbooks.org.yml`, applied with `bin/cfrules apply thegreatestbooks.org`.
3. **healthchecks.io. DONE 2026-10-14.** Create `worldcat-heartbeat` (period 5 min, grace 15 min) and `worldcat-deploy`
   (period 15 min, grace 1 h), and copy their ping URLs.
4. **Secrets, before the first `provision`. Shane runs with `!`. DONE 2026-10-14.** Step 2's apply
   already wrote `WORLDCAT_TUNNEL_TOKEN`; add only `HC_WORLDCAT_HEARTBEAT` and `HC_WORLDCAT_DEPLOY` to
   `secrets/home-server.env` (`sops secrets/home-server.env`). The host already has tunnels enabled,
   so the VM that `provision` creates starts `cloudflared` at once. With the token missing it starts
   with an empty one and nothing alerts.
5. **Confirm VMID 130 is unused, immediately before step 6.** It was free on 2026-10-14, but that
   does not carry over to a later day. `ssh pve-mini qm list` must not list 130. `provision` adopts
   a VM it finds at that id instead of creating one.
6. **Create the VM. Shane runs with `!`.** `deployment/home-server/provision` (`SOPS_AGE_KEY_FILE`
   set) creates VM 130 `worldcat` and installs its env and units. Tunnels are already enabled on the
   host, so `provision --enable-tunnels` is not needed again; it dies unless all three tunnel tokens
   are set. The API will not start until step 7 puts an artifact on the VM.
7. **Load the artifact.** (Deploy order: the service image must be rebuilt and deployed before, or
   together with, the Rails deploy that uses `POST /records`. Until then evidence rows list `worldcat`
   in `sources_failed`; that is safe and a later run re-gathers them.) Follow "Loading the WorldCat artifact (once)" in `docs/features/home-server.md`:
   find the VM's address (`ssh pve-mini qm guest cmd 130 network-get-interfaces`; DHCP on the LAN),
   rsync the version directory as `debian@<vm-address>` with `--mkpath --rsync-path="sudo rsync"` (the
   only SSH user is `debian`, `/srv/wc-data` is root-owned and has no `versions/` yet),
   `sudo chmod -R a+rX /srv/wc-data/versions/2025-09-04` (the container runs as uid 10001), write
   `/srv/wc-data/current-version`, touch
   `/var/lib/the-greatest/force-deploy` and start `the-greatest-deploy.service`. Then curl
   `https://worldcat-api.thegreatestbooks.org/version` with the service token. `worldcat-heartbeat`
   should go green within a few minutes.
8. **Time a full batch on the VM. Shane runs with `!`.** The service has a 5 s per-request deadline
   and a 500-ISBN batch is the largest `/lookup` accepts (the backfill sends 100). Time one from the
   dev machine through the VM's loopback, twice (cold, then warm):
   `test "$(wc -l < /home/shane/wc-data/our_isbns.txt)" -ge 500 || { echo "export has fewer than 500 ISBNs"; exit 1; }; head -500 /home/shane/wc-data/our_isbns.txt | jq -R . | jq -sc '{isbn13s: .}' | ssh debian@<vm-address> "curl -s -o /dev/null -w '%{time_total}\n' -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8082/lookup"`
   (`/home/shane/wc-data/our_isbns.txt` is the export step 1 writes; the guard stops the step on a
   missing or short file, which would otherwise "pass" in milliseconds on an empty batch). On the
   development machine at the container's two threads the same batch took 3.3 s and a 100-ISBN
   one 1.2 s, so expect the VM to be slower than that. Both times should be well under the 25 s deadline before the
   backfill; a `504` or a time near the deadline means stop and lower the backfill's batch size
   or raise `WC_API_DEADLINE_S`.
9. **Production setting. Shane runs with `!`.** Step 2's apply added
   `WORLDCAT_SERVICE_URL=https://worldcat-api.thegreatestbooks.org` to the production SOPS secrets
   (2026-10-14); what remains is getting it onto the app server and deploying.
10. **The genre map, in development.** `worldcat:vocabulary` and `worldcat:map` need the local WorldCat
   API running: `docker compose --profile worldcat up -d worldcat` in `data-sources/`. Run
   `bin/rails worldcat:vocabulary`, `worldcat:map` and `worldcat:report`. Review and edit
   `config/worldcat/genre_map.yml` by hand, then commit it. The reviewed map must be merged and
   deployed before steps 14 and 15 run in production.
11. **Rehearse the backfill in development.** The dev database is not disposable, so snapshot it
    first: `bin/snapshot-dev-db.sh --label pre-worldcat` (from the repo root). Then, with the local WorldCat API running,
    `bin/rails "worldcat:backfill[2000]"`. Read the worker log's line for the run (grep the Sidekiq
    log for "WorldCat backfill") and its counts ("genre links", "unresolved subject phrases",
    "type conflicts"), then spot-check ten of those books in the admin: each
    genre should be one you would have chosen, and none should carry both Fiction and Nonfiction.
    Fix the map and rerun if not. Restore with `bin/snapshot-dev-db.sh --restore` if the links look
    wrong.
12. **Old site: stop the Goodreads import creating genres. Shane merges and deploys. DONE 2026-10-18.** The change is
    `the-greatest-books` PR #10 (branch `stop-goodreads-genre-creation`): the Goodreads genre loop in
    `admin/app/models/book.rb` skips a genre it cannot find instead of creating it. Merging there
    deploys. Deploy it before the genre apply.
13. **Genre cleanup, in production. Shane runs with `!`.** Needs the plan files merged and deployed
    (`config/books/genre_plan.yml`, `genre_split_assignments.csv`, the retargeted
    `config/worldcat/genre_map.yml`). Dump the four tables first (the command in the category cleanup
    runbook, `docs/features/books-categories.md`) and add `-t saved_searches -t recommendation_configs`,
    because the apply also rewrites `criteria` on those, so a restore brings back a consistent state, then `bin/rails categories:genres:apply`. If it
    exits non-zero, read its remedy lines before re-running. If it stops on a genre missing from the
    plan, run `categories:genres:map` in development for it, review, and ship the updated file. The
    `/categories` Audiences tab appears only as edge-cached `/categories` pages expire after
    audiences are created. Details: "Genre cleanup and audiences" in
    `docs/features/books-categories.md`. Steps 14 and 15 wait for this step.
    After a clean apply, set the parent of **Noir** and **Hardboiled** to **Crime Fiction** in the admin
    category form (the plan file cannot set parents).
14. **Aliases, in production. Shane runs with `!`.** `bin/rails worldcat:apply_aliases`.
15. **The backfill, in production. Shane runs with `!`.** `bin/rails "worldcat:backfill[verified]"`. It
    reads verified ISBN-13s only (`[all]` is retired), so it no longer waits on the ISBN cleanup; it
    needs the branch that makes it verified-only deployed.
16. **The report, if the map changed.** After the backfill, if the map was edited during review, re-run
    `bin/rails worldcat:report` in development and commit the regenerated
    `docs/data-quality/worldcat-genre-mapping.md`. It depends only on the map file, not on the backfill.

## 10. Alternate titles cleanup (the review and the undo repeat)

Spec: `docs/superpowers/specs/2026-10-23-alternate-titles-cleanup-design.md`; explained in
`docs/features/books-alternate-titles.md`. Do the dev rehearsal and its hand checks first (the doc's
"Proving it"). Needs Sidekiq running for the review.

1. **Deploy.** The migration creates `alternate_titles`; the code writes through it from then on.
2. **`bin/rails books:alternate_titles:backfill`.** Idempotent; creates a `legacy` row per existing
   alternate title. Run once.
3. **`bin/rails "books:alternate_titles:review[ranked]"`.** Queues one AI call per ranked book on the
   `low` queue. Wait for the queue to empty, then `bin/rails books:alternate_titles:report` and check
   by hand: the known cases, 50 random removals, 50 random keeps, every non-Latin removal. Work the
   `review` rows on the admin review page.
4. **`bin/rails "books:alternate_titles:review[all]"`.** The rest of the catalogue.
5. **`bin/rails books:alternate_titles:undo_findings`** (dry run). Read the counts, the wrong-work list
   and the samples. Then **`bin/rails "books:alternate_titles:undo_findings[apply]"`**.
   `redo_finding[id]` reverses one.

**Repeating steps: `review` and `undo_findings`.** Run `review[all]` and then `undo_findings` (dry run,
then `[apply]`) again after merges, after each weekly `data_migration:sync`, after working the review
page or accepting corrections, and in the final launch sequence. Each only handles rows it has not
handled before, so repeating is safe. A finding `undo_findings` leaves alone ("held with another
source") is not retried by re-running: the apply run stamps the book's removed rows, so it is
re-judged only when another title on that book is later removed. `undone_findings[book_id]` lists a
book's undone findings for `redo_finding`.

The unsure-books second-chance verification run follows this cleanup.

## 11. Goodreads rebuild (repeats until cutover)

Repairs the books legacy's Goodreads imports made, from the export rows. Design:
`docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md`; how it works: `docs/features/goodreads-rebuild.md`.
The Goodreads replay (`books:goodreads_replay:*`) stays paused: do not approve or apply its proposals.

1. **See which books are trusted.** `bin/rails books:goodreads_rebuild:cohorts` is read-only. It prints how
   many post-import books are trusted (on a real list, so you added them by hand) and how many are
   derived (import-made, to be rebuilt). Expect about 9,400 trusted and 138,000 derived.
2. **Retire the replay's old proposals, once.** They were judged on legacy's stripped titles, so approving
   any of them would apply a guess. `bin/rails books:goodreads_rebuild:retire_replay_proposals` is a dry run:
   expect about 2,691 relinks and 2,091 strips. Then run
   `bin/rails "books:goodreads_rebuild:retire_replay_proposals[apply]"`. They disappear from the admin
   repair-verdict page. A second run prints 0s.
3. **Survey the import-made books.** This is read-only: it changes no book. It only reads our own
   database, so it's safe to run while a verification run is going.
   - Run `bin/rails "books:goodreads_rebuild:survey[all]"`, then wait for the Sidekiq job to finish.
   - Run `bin/rails books:goodreads_rebuild:survey_report`. It counts the lumps, the books whose
     title or authors disagree with the Goodreads export, and the books that are the wrong book
     altogether, with samples of each. Read the samples: they are what the next step will fix.
   - If the job stops, run the same command again. It carries on from the books not yet surveyed.
4. **Bring in survey pass 2's evidence.** This is read-only for books. The WorldCat and Open Library
   lookups for every import-made edition run on Shane's PC, not in production. That's the recipe in
   `docs/features/goodreads-rebuild.md`, "Survey pass 2", and it takes about 22 hours. It ends with a
   file, `tmp/rebuild_edition_evidence.jsonl.gz`. Copy that file into the production container, then:
   - `bin/rails "books:goodreads_rebuild:import_evidence[<path to the file>]"`. It prints how many
     rows it imported. A second run is safe.
   - `bin/rails "books:goodreads_rebuild:survey[all,redo]"`, and wait for the job.
   - `bin/rails books:goodreads_rebuild:survey_report`. The lump count should drop: translations on
     one Open Library work no longer count as lumps. The report now shows how often WorldCat agreed.
5. **The fixes.** About 47,400 books on dev; see `docs/features/goodreads-rebuild.md`, "Fixes (increment 2b)".
   All of these runs are yours; do them in this order.
   1. `bin/rails "books:goodreads_rebuild:decide_fixes[200]"`, wait for the Sidekiq jobs, then
      `bin/rails books:goodreads_rebuild:fixes_report`. Hand-check the samples against the export.
      No book is changed yet. Some verdicts are approved automatically and the next `apply` carries
      them out; the rest are proposals that wait for you.
   2. `bin/rails "books:goodreads_rebuild:decide_fixes[all]"`. It calls the AI on undecided books, about
      47,000 of them, on Sidekiq `low`, so it takes a while. Run it again for any books reported as
      `retry`, then `fixes_report` again.
      Lump records (Goodreads rows of several different books) are skipped; they wait for a later
      split step. The first runs recorded some lump verdicts, so once, before approving anything:
      `bin/rails books:goodreads_rebuild:retire_lump_verdicts` (a dry run; check the counts and
      samples, and that "already applied" and "applied, survey gone" are both 0; if either is not, stop and look at those books before going on), then `bin/rails "books:goodreads_rebuild:retire_lump_verdicts[apply]"`.
   3. In Admin, Repair verdicts: review and bulk-approve the `fix_identity` proposals, then the
      `merge_books` ones.
   3b. Before `apply`, retire the fixes whose book is already right (only Goodreads series/edition noise
      differs): `bin/rails books:goodreads_rebuild:retire_unneeded_fixes` (a dry run; check the counts and
      samples), then `bin/rails "books:goodreads_rebuild:retire_unneeded_fixes[apply]"`. Of the fixes that
      remain, those whose only difference is a missing subtitle change just the title and subtitle on apply.
   4. `bin/rails books:goodreads_replay:apply`, then `bin/rails books:goodreads_replay:repair_ratings`.
      `apply` re-runs every pass but applies each fix only once, and leaves alone any book put on a real
      list since. Each reset saves what it removed (Amazon ASINs and links too) on the verdict.
      Afterwards run `bin/rails "books:goodreads_rebuild:survey[all,redo]"` before any later
      `decide_fixes`: a fixed book's old survey still says it disagrees with its export, so it cannot be
      found as a merge target until it is surveyed again.
   5. From then on the 10-minute job enriches the fixed books nonstop, at the Goodreads fetch cap
      (300 waiting at once).
   6. After a day or two, read `fixes_report`'s enrichment section. If nothing failed and the gate never
      blocked, raise `GOODREADS_DAILY_FETCH_CAP` in the production env (SOPS) and restart the worker.
      Above 5,760 a day, lower `GOODREADS_FETCH_INTERVAL` too.

## 12. Goodreads re-import (one run, then repeats only if the sync is changed)

Matches every legacy CSV row to the exact book it names and moves each reader's entries there. Design:
`docs/superpowers/specs/2026-11-02-goodreads-reimport-design.md`; how it works, and where each output lands:
`docs/features/goodreads-reimport.md`. It replaces stage two of section 11.

**Do not run `data_migration:sync` until it has been checked against this run and changed so it cannot revert
it** (spec section 3.9). As it stands it rewrites legacy users' lists and would undo moved rows.

Do not start until the new enrichment steps (categories, origin) and the Goodreads search page fix are deployed.
Every step below only queues a Sidekiq job; wait for the jobs to finish before the next step.

1. **Gate on, enrichment off.** Set `GOODREADS_REIMPORT_ENABLED=true` in the production env (SOPS) and restart
   the worker. Leave `GOODREADS_REIMPORT_ENRICHMENT` unset.
2. **Refresh the survey.** `bin/rails "books:goodreads_rebuild:survey[all,redo]"`. The mixed books are read
   from it.
3. **Archive the mixed books.** `bin/rails books:goodreads_reimport:archive_mixed`. It records verdicts and
   deletes nothing.
4. **Match every edition.** `bin/rails "books:goodreads_reimport:match[200]"` first, then
   `bin/rails "books:goodreads_reimport:match[all]"`. Run `[all]` again for any editions left.
5. **Report and review.** `bin/rails books:goodreads_reimport:report`; find the file at
   `storage/goodreads_reimport/report-<UTC time>.md` (the path is in the Sidekiq log). The worker writes it
   into the shared storage volume, mounted in both web and worker, so read it from either container. The
   snapshot's `counts.json` lands in the same folder. Then in Admin, Repair
   verdicts, review the proposed `reimport_match` ones: approve the right ones, reject the wrong ones. Rejected
   matches leave their rows waiting; the report lists them.
6. **Apply the matches.** `bin/rails books:goodreads_reimport:apply`. This writes approved matches and creates
   the new books.
7. **Decide.** `bin/rails "books:goodreads_reimport:decide[200]"`, then `decide[all]`. Run `decide[all]` a
   second time once the first has finished: the second pass decides the guesses for mixed books, which wait
   until their rows are decided.
8. **Snapshot.** `bin/rails books:goodreads_reimport:snapshot`, before the first apply that moves rows. It
   refuses to replace an existing snapshot; `snapshot[redo]` does, but never use it after a row has moved.
   A `counts.json` taken before the by-id check holds counts but no ids, and the report then prints "NOT CHECKED. The
   snapshot predates id tracking". Run `bin/rails "books:goodreads_reimport:snapshot[redo]"` once, before any row
   has been applied, to replace it.
9. **Apply.** `bin/rails books:goodreads_reimport:apply`. Re-running is safe.
10. **Check the authors, then apply.** `bin/rails "books:goodreads_reimport:check_authors[200]"`, then
    `check_authors[all]`, then `bin/rails books:goodreads_reimport:apply` again.
11. **Report.** `bin/rails books:goodreads_reimport:report` again. The acceptance lines at the bottom should
    each print 0. Conflicts and verdicts closed because there was nothing left to do are listed in it; read them.
12. **Sample.** `bin/rails books:goodreads_reimport:sample`. The result is in the Sidekiq log (search
    "Goodreads re-import sample check"), not in a file. If a deploy interrupted it, enqueue it again. **Any
    "no" stops the run** until its cause is fixed.
13. **Enrichment on.** Only after the new enrichment steps have landed: set
    `GOODREADS_REIMPORT_ENRICHMENT=true` and restart the worker. The new books then enrich.

Each job can be stopped and run again safely. If a deploy interrupts a long job, run the same task again.

## 13. MCP sign-in (OAuth)

Lets members connect claude.ai, Claude Desktop and mobile to `/api/mcp` by signing in, with no token to paste.
How it works: `docs/features/mcp-server.md`, "Signing in with OAuth". Design:
`docs/superpowers/specs/2026-11-02-mcp-oauth-design.md` (D15, D17). Nothing here runs on deploy, but step 1 depends on one.

1. **Deploy, then apply the edge change for the `/.well-known/oauth-*` paths, then make the first claude.ai connection.**
   Deploy this branch first. Apply the edge change only after the two `/.well-known/oauth-*` documents answer
   200 from the origin. The edge change is a rule in the private Cloudflare repo, prepared as a PR there. Merge
   it, then apply it by hand with that repo's own process. claude.ai's backend cannot solve a challenge, so until the rule is live its
   discovery request fails and the connector never reaches the sign-in page. No detail of the rule belongs
   in this repo. To check it, fetch `https://<books host>/.well-known/oauth-authorization-server` from
   outside, with no browser cookies, and expect JSON.
2. **Confirm the production books hostname is admitted.** Both lists come from `BOOKS_DOMAIN` through
   `config.domains`: `config.hosts` (`config/initializers/host_authorization.rb`) and the MCP transport's
   `allowed_hosts` (`Api::McpController#transport`). Check that the production env's `BOOKS_DOMAIN` holds the
   hostname members will type, and that its first entry is the one that should appear in the metadata:
   `Api::Host.base_url` uses the first entry as the issuer and in every endpoint URL. A mismatch fails
   with a Host-header refusal or a protected-resource `resource` that differs from the URL the client typed.
3. **At the thegreatestbooks.org switch (section 7), members re-add the connector with the new URL.**
   A connection records its resource as a key, not a URL, so existing connections keep working under the new
   host. But claude.ai drops `Authorization` across redirects, so a connector still pointed at the old
   hostname is redirected, arrives with no token, and cannot get in. Tell members who connected before the switch to
   remove the connector and add `https://thegreatestbooks.org/api/mcp`. Books is not live yet, so few
   connections will exist by then.
4. **Acceptance for the admin endpoint.** As an admin, add `https://<books host>/api/mcp/admin` as a second
   claude.ai connector (it is a separate resource from `/api/mcp`), sign in, approve, and ask for a dry-run
   merge of two duplicate books. Admin approvals need renewing every 30 days.
5. **Acceptance from the docs alone.** Following only `/developers`, connect claude.ai, Claude Code and Codex to
   `https://<books host>/api/mcp` by signing in, and ask each one question. Then Revoke each on
   `/developers/tokens` and confirm each asks to sign in again. Record the result in the PR or on the
   acceptance line of `docs/features/mcp-server.md`.

## 14. Book origins and categories (the backfill once, then weekly)

Fills in each book's country of origin, genres, audience, subjects and locations through the
`books.book_categorize` workflow. Only you start the
backfill, by hand, with `APPLY=1`; nothing schedules it or starts it automatically. Run it after the
Goodreads re-import (section 12) is done, since that removes crufty books and finds duplicates, and
the books and authors it creates already go through the full import workflow, origin and categories steps included. The
backfill runs once here; the weekly run is section 4, step 10, and is optional.

1. Run the author Wikidata enrichment first (section 15, step 11): the work match depends on author QIDs.
   The dev rehearsal is done and you have signed off on the review (stage 2 plan, Task 10). It needs a local
   Wikidata copy first (section 15): remote Wikidata refuses requests whenever its lag passes 5 seconds, which in November
   2026 was most of the day, so it cannot carry a bulk run (Wikimedia asks bulk readers to use the dumps).
2. Before any categories run, write the genre and audience definitions the categories judge reads.
   `bin/rails books:categories:write_definitions` is a dry run; run it again with `APPLY=1` to write them (the plan
   overwrites any description that differs; those print as `replaced`). Fill in the description in the admin for any genre or audience it prints as `missing`.
3. **Turn the categories judge on (after the rehearsal sign-off and the definitions in step 2).** The judge is off
   everywhere until `BOOKS_CATEGORIES_JUDGE_ENABLED=1` is set (`config.x.ai.categories_judge_enabled`, default off).
   Until then every import and every Goodreads-rebuild book gets a skipped `disabled` row in place of a judgment,
   and those books stay candidates for the backfill. Set it in the production env (SOPS secrets) and restart the
   web and worker processes. Do it before any categories run below; the origin backfill does not need it.
4. In production (you run it by hand with `!`; this is the only way it starts), `bin/rails "books:categorize:backfill[origin_only,all,origin-v1]"`
   to see the count, then again with `APPLY=1`. It paces itself at one book every 8 seconds, so the whole
   catalog (about 159,000 books) takes about 15 days; the dry run prints the hours. The ranked books go first. The research cap for the backfill is
   `config.x.ai.categorize_backfill_research_daily_cap`, which is 0 until raised; books whose
   judgment deferred research wait until you raise it, and the backfill leaves them alone meanwhile. Until
   WorldCat is reachable from production, evidence rows list `worldcat` in `sources_failed`; the origin
   judge works without it.
   Run the categories after the origins with `bin/rails "books:categorize:backfill[categories_only,all,categories-v1]"`
   (dry run, then `APPLY=1`). Or, preferably, run `[all,all,<label>]` once in place of both: one evidence gather
   serves both judgments, and each book is planned with only the judgment it still needs. The categories judge
   spends the same backfill research cap (`categorize_backfill_research_daily_cap`), which counts origin and
   categories research together.
5. `bin/rails "books:origin:report[<label>]"` and `bin/rails "books:categories:report[<label>]"`, with the
   label you ran under (`origin-v1` and `categories-v1` if you ran them separately). The
   categories report lists type conflicts, unmatched subject and location names, and genre names the evidence
   used that we do not list, each with the genre the judge said it means; add them as alternative names on existing
   genres, never as new genres.
   Then the alias step: `bin/rails "books:categories:add_aliases[<label>]"` is a dry run that lists each name and the genre it
   would join (and skips a name an active genre already matches). Run it again with `APPLY=1`, and `NAMES=a,b` to add
   only the names you checked. `MIN=n` sets a minimum count. Aliases take effect for books judged after them; the next
   backfill pass uses them.
6. Accept or skip the origin disagreements: `bin/rails "books:origin:accept_disagreements[<label>]"`, with
   `IDS=` and `APPLY=1`.
7. **Undo, if a run removed links it should not have.** A re-judge removes legacy links the evidence does not
   support. `bin/rails "books:categories:restore_removals[<label>]"` prints how many links on how many books it would
   put back (it does not list them); with `APPLY=1` it restores them.
8. **Rankings.** Refresh the books list weights and the book rankings, then the author rankings. Filling
   origins changes `percentage_western` and so the western-canon penalty.

## 15. Local Wikidata (the service once; the re-check repeats after each refresh)

Replaces remote Wikidata for bulk reads with a copy built from the weekly dump, served from the home
server through a Cloudflare tunnel behind Cloudflare Access. Details:
`docs/features/wikidata-data-service.md`; spec: `docs/superpowers/specs/2026-11-08-wikidata-data-service-design.md`.
The work ships as two PRs: the Wikidata service and home-server tooling first, the Rails switch second.

Steps marked "Shane runs with `!`" change the home server, Cloudflare or production, so an agent does not run them.
The order matters: the Cloudflare step writes the tunnel token that `provision` hands the new VM. The host
already has tunnels enabled, so a VM created before the token exists starts `cloudflared` with an empty one.

1. **Free the old MusicBrainz VM. Shane runs with `!`. DONE 2026-11-09.** On pve-mini: `qm set 101 --onboot 0`,
   so VM 101 stops competing with VM 150 for memory after a reboot. Then check production's `MUSICBRAINZ_URL`:
   if it points at VM 101, point it at `https://musicbrainz.org` before VM 101 is ever stopped.
2. **Prove the build on the dev machine. DONE 2026-11-09.** The dev build passes every gate (81 min, peak
   9.5 GiB of 10 GiB; numbers in the feature doc's "Measured build").
3. **Merge PR 1** (#473, the Wikidata service and the home-server tooling). **DONE 2026-11-09.** Nothing in
   production calls the service yet.
4. **Cloudflare, before anything touches the home server. Shane runs with `!`. DONE 2026-11-09** (both
   applies in sync; the SOPS files committed with this section). Nothing is done in the
   dashboard. In `the-greatest-cloudflare`, merge the branch `wikidata-tunnel`: it adds the `wikidata-api`
   Access app (the existing `prod-rails` service token, nothing new), the `home-wikidata` tunnel with ingress
   `http://wikidata:8083`, `WIKIDATA_SERVICE_URL` to the production values, and
   `wikidata-api.thegreatestbooks.org` to the `skip_edge_for_home_server` bot-skip rule. Then, from an
   up-to-date checkout of that repo (`CLOUDFLARE_ZT_API_TOKEN` and `CLOUDFLARE_API_TOKEN` in its `.env`,
   `SOPS_AGE_KEY_FILE` set):
   - `bin/cfzerotrust diff --secrets-root /home/shane/dev/the-greatest` lists one app, one tunnel, one
     CNAME and two secret writes to create, and nothing to change for the other three services.
   - `bin/cfzerotrust apply --secrets-root /home/shane/dev/the-greatest` creates them, writes
     `WIKIDATA_TUNNEL_TOKEN` into `secrets/home-server.env` and `WIKIDATA_SERVICE_URL` into
     `secrets/.env.production`. There is no token to copy.
   - `bin/cfrules diff thegreatestbooks.org` shows only the skip rule's host list gaining the new hostname
     (if it reports dashboard drift, `pull` and merge first, per that repo's AGENTS.md), then
     `bin/cfrules apply thegreatestbooks.org`.
   - Commit the two changed SOPS files in this repo on a branch and merge it. Production picks up
     `WIKIDATA_SERVICE_URL` the way section 9 step 9 did; nothing reads it until PR 2 merges.
5. **healthchecks.io (optional).** Create `wikidata-heartbeat` (period 5 min, grace 15 min),
   `wikidata-deploy` (15 min, 1 h) and `wikidata-refresh` (1 day, 12 h), then add their ping URLs as
   `HC_WIKIDATA_HEARTBEAT`, `HC_WIKIDATA_DEPLOY` and `HC_WIKIDATA_REFRESH` with
   `sops secrets/home-server.env`. Blank means no ping, so this can wait, but do it before step 7 or
   re-run `provision` afterwards.
6. **Confirm VMID 150 is unused, immediately before step 7.** `ssh pve-mini qm list` must not list 150.
   `provision` adopts a VM it finds at that id instead of creating one.
7. **Create the VM. Shane runs with `!`.** From this repo's main checkout, up to date with `main` and with
   step 4's secrets: `SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt deployment/home-server/provision`.
   It creates VM 150 `wikidata` (8 vCPU, 12 GB, a 400 GB data disk on `rpool2`), installs its env and
   timers, and leaves the other VMs alone. `cloudflared` starts at once; the API does not, because there is
   no built version yet. Check: `ssh pve-mini qm list` shows 150 running, and
   `deployment/home-server/provision --verify` passes, with the wikidata `/version` check reported as SKIP.
8. **The first build runs by itself.** `wikidata-refresh.timer` fires 15 minutes after the VM boots: about
   4.5 h to download the dump, then about 1.5 h to build, gate and promote. Nothing to do but wait.
   To watch it, find the VM's address (`ssh pve-mini qm guest cmd 150 network-get-interfaces`), then
   `ssh debian@<vm-address> journalctl -fu wikidata-refresh`. It is done when
   `ssh debian@<vm-address> curl -s 127.0.0.1:8083/version` prints `"gates_passed":true` with a dump
   date, and `wikidata-heartbeat` goes green. A failed gate leaves nothing served and pings
   `wikidata-refresh` with the gate names; the dump is kept, so a retry does not download it again.
9. **Confirm production reaches the service. Shane runs with `!`.** From a production host:
   `curl -s -H "CF-Access-Client-Id: $CLOUDFLARE_ACCESS_CLIENT_ID" -H "CF-Access-Client-Secret: $CLOUDFLARE_ACCESS_CLIENT_SECRET" https://wikidata-api.thegreatestbooks.org/version`
   answers with the same dump date. A 403 means the Access app or token; a challenge page means the
   bot-skip rule from step 4 is not applied.
10. **Only then merge PR 2** (#474, the Rails switch): mark it ready for review, let CI and Codex finish,
    merge. It deploys the client. Merging it before step 9 passes leaves production imports with no
    Wikidata at all.
11. **Enrich the authors from the local Wikidata, ranked authors first. Shane runs with `!`.**
   `bin/rails "books:authors:enrich[13333]"`. The limit is how many authors to queue, ranked authors first:
   13,333 authors had a ranked book on dev on 2026-11-09, and a few hundred more only reaches unranked
   authors with the most books. Authors already processed are skipped, and its first line prints how many
   it planned. It queues the Wikidata step, then VIAF on a miss, then AI with research off, one author every
   2 seconds (`Backfill::SPACING`), so about 7.5 hours for the ranked authors. Check it with
   `bin/rails "books:authors:enrich_report[<ISO time it printed>]"`. Do this BEFORE the section 14 origin
   backfill, because the work match rate depends on author QIDs. Measured on dev 2026-11-09: only 714 of
   76,006 authors have a Wikidata QID. On a 40-book sample the local copy matched 5 of 10 top-ranked books,
   1 of 10 mid-ranked and 1 of 20 unranked, all through identifiers. When the author was found by name,
   the author-works route matched 8 of the 14 ranked books that were still unmatched.
12. **Re-run the stage 2 rehearsal** (section 14, step 1); it now covers the categories judgment too (stage 3, Task 11).
   The dev rehearsal needs `BOOKS_CATEGORIES_JUDGE_ENABLED=1` in the environment of the dev Sidekiq process; without it every
   book gets a skipped `disabled` row. That is a dev setting only and does not touch production.
13. **After launch, optionally turn on the re-check.** Set `config.x.wikidata.recheck_after_refresh = true`
   (`config/initializers/wikidata.rb`; it is off everywhere until you do) and deploy. The 06:00 UTC cron
   (`wikidata_recheck_after_refresh`) then reads `/version` daily and, when the dump date is new, re-checks
   books and authors created in the last 90 days (`config.x.wikidata.recheck_window`) that found no QID,
   one start every 8 seconds. To see the counts first, `bin/rails wikidata:recheck` is a dry run;
   `APPLY=1` queues the work. It selects no book while their evidence rows list `worldcat` in
   `sources_failed` (until WorldCat is reachable from production), because those books are left to a normal re-gather.

## 16. Ranking archives (the migration once; the monthly job needs nothing)

Frozen copies of the books ranking, shown at `/rankings/archive`. The monthly job is scheduled and
needs no action; the one manual step is copying the archived legacy rankings in. Details:
`docs/features/ranking-archives.md`.

Steps marked "Shane runs with `!`" change production, so an agent does not run them.

1. **After deploy, check the first automatic archive.** The next 05:15 UTC run creates an archive named
   for the month it is deployed in. Check `/admin/ranking_archives`. If it should not be public, hide it;
   do not delete it, because the next run would create it again.
2. **Copy the legacy archives. Shane runs with `!`.** In production,
   `bin/rails data_migration:ranking_archives`. Expect `unknown: 0` and a `count` of about 43 (43 on the
   2026-11-10 development run); `skipped_empty` lists any archived ranking with no ranked rows. An unknown
   id is a book id that is neither a live book nor a `record_redirects` row. If the task aborts with
   unknown ids there are two causes. The books sync may be behind legacy: run the read-only
   `bin/rails data_migration:sync_report` to see, then `data_migration:sync` (a plain sync holds back the
   last 24 hours of legacy changes unless `FINAL=1`), and retry. Or a book was removed here without
   callbacks: stop and investigate the listed ids before retrying, and do not force the migration.
3. **Re-running it at cutover is harmless.** It creates only archives that do not exist yet, so it
   reports `count: 0` if legacy archived nothing new.
4. **Spot-check.** Open `/rankings/archive` and one old archive.
