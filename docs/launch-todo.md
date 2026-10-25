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
7. **`bin/rails worldcat:backfill[all]`** (once section 9 is live). The sync brings over new books
   without WorldCat-derived categories; the backfill is additive and idempotent, so a full run only
   adds links for books that have none yet. It is a repeating step, not a one-off.
8. **`bin/rails "books:verify[all,recheck]"`** after the sync, once the pass has run. The sync keeps
   adding legacy identifiers; this re-verifies the books that got new ones. Once the `post_import`
   books have been verified, the recheck needs `post_import` too
   (`books:verify[all,recheck,post_import]`).

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
   against WorldCat and records signals. After the Goodreads rebuild, run
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

- **Author enrichment:** `bin/rails "books:authors:enrich[all]"`, or `[13654]` for the ranked
  authors only. About 58k authors have no ranked book. After the switch-over.
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
3. Section 4, steps 3-7.
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

## 9. WorldCat genre data (the service once; the backfill repeats)

Adds the WorldCat exact-lookup service on the home server and backfills genre categories from it.
Independent of section 2: the switch-over ran on 2026-10-10 (`data_migration:sync_init`), so the
category links the backfill writes in production are kept across the weekly `data_migration:sync`.
The sync does add new books, though, so the backfill (step 15) is also section 4 step 7: it re-runs
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
7. **Load the artifact.** Follow "Loading the WorldCat artifact (once)" in `docs/features/home-server.md`:
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
15. **The backfill, in production. Shane runs with `!`.** `bin/rails "worldcat:backfill[all]"`.
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
