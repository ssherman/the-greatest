# Books launch todo

The manual steps for moving thegreatestbooks.org onto this app, in the order to run them. Nothing here
runs on deploy. When a merge leaves a step someone has to run by hand, add it here with a pointer to
the doc that explains it. Keep this the one list: details belong in the feature docs it points to.

Every command was checked against the code, and every status against production (read-only), on
2026-11-26. Re-check a status before acting on it.

> **Do not run `data_migration:sync` until the sync fix is deployed.** The sync fix is the branch
> `worktree-sync-keeps-reimport` (spec `docs/superpowers/specs/2026-11-26-books-sync-keeps-reimport-design.md`).
> Without it, a sync puts legacy readers' lists and reviews back the way the old importer left them,
> which undoes the Goodreads re-import applied on 2026-11-17 to 11-21. The order is:
>
> 1. The old site's Goodreads upload pause is deployed (section 4, step 1).
> 2. The sync fix is deployed (section 4, step 2).
> 3. `bin/rails data_migration:sync_report`, then `bin/rails data_migration:sync`, then
>    `bin/rails data_migration:sync_report` again (section 4, step 3).
>
> To see whether the fix is in production: `sync_report` (read-only) prints "held for the Goodreads
> re-import" on its `user_list_items` and `reviews` lines only when it is.

## 1. Words used here

- **Legacy**: the old site (thegreatestbooks.org, repo `the-greatest-books`) and its database.
- **Switch-over**: `data_migration:sync_init`. It ran in production on 2026-10-10. From then on this
  database's books catalog is the master, and the weekly sync brings over only what is new on legacy.
- **Cutover**: legacy goes offline and the last sync runs with `FINAL=1`. Not yet scheduled.
- **Hostname switch**: thegreatestbooks.org starts pointing at this app. Books runs at
  `new.thegreatestbooks.org` until then.
- **Re-import pass**: one run of the Goodreads re-import steps over the legacy imports not yet covered
  (section 3.2). The first, full pass applied 2026-11-17 to 11-21.
- **Shane runs with `!`**: the step changes production, DNS or the home server, so an agent does not run it.

## 2. Where things stand (2026-11-26)

Checked read-only in production on 2026-11-26 at about 03:50 UTC. DONE means the evidence shows it ran.

| Area | Status | Evidence |
|---|---|---|
| Switch-over (`sync_init`) | DONE 2026-10-10 | Sync watermarks created 2026-10-10 04:44 UTC. |
| Weekly sync | PAUSED since 2026-11-13 | Last successful sync 2026-11-13 00:43 UTC (watermarks: books 178,056, authors 80,892, book_identifiers 553,842). Legacy has 580 books above the watermark and 10 Goodreads imports since. Waits for section 4, steps 1-3. |
| Goodreads re-import, first pass | DONE 2026-11-17 to 11-21 | All verdicts applied: 462,166 rows (434,759 keep, 14,758 add, 8,090 copy, 4,559 move), 188,321 matches, 1,668 mixed books, 14,949 strips, 129 guesses, 135 author fixes. 11 `reimport_author` proposals still wait for review. Report `report-20261121T053123Z.md`; snapshot `counts.json` of 2026-11-20 04:28. |
| Re-import sample check | UNKNOWN | No record found; the result is only in the Sidekiq log, which the 2026-11-26 01:25 deploy reset. Settled by running it (section 4, step 4). |
| Re-import enrichment (`GOODREADS_REIMPORT_ENRICHMENT`) | NOT RUN | Unset in production. |
| Re-import gate (`GOODREADS_REIMPORT_ENABLED`) | ON | `true` in production. |
| Legacy Goodreads imports since the last load | NOT LOADED | 10 legacy imports (ids above 835) are not loaded here. They load after the first fixed sync. |
| Old site: Goodreads upload paused | NOT DEPLOYED | Branch `goodreads-import-paused` in `the-greatest-books`, not merged. The newest legacy import is from 2026-11-23. |
| Recommendations model | DONE | Active books model 42, from the 2026-11-25 export. The before-go-live work (section 4, step 17) is open. |
| Identifier provenance (`identifiers:mark_legacy`) | DONE | 0 books identifiers without a source. |
| Stored-name normalization | DONE | The read-only report finds 0 books and 0 authors to change. |
| Verification pass | PARTIAL | Ranked pre-import books and the trusted post-import books are done (21,241 rows; the last on 2026-10-29). Second chance and keep-bigger are done. The post-import pass (`books:verify[all,post_import]`) has not run, and 226 verified books have legacy identifiers newer than their check. |
| Duplicate queue | ONGOING | 14 pending, 3,533 merged, 786 not duplicates. |
| Category cleanup | DONE | 64,296 decisions applied. |
| WorldCat genre data | PARTIAL | Genre cleanup and aliases done (3 audiences; Noir and Hardboiled under Crime Fiction; `apply_aliases` would add 0). The backfill has not run: no category link has source `worldcat`. |
| Alternate titles cleanup | DONE 2026-10-25, repeating step due | 2,033 findings undone on 2026-10-24/25. The last review decision is from 2026-11-20; 5,190 books have alternate titles not yet judged (most arrived since, from merges and enrichment). |
| Goodreads rebuild | DONE 2026-11-01, enrichment running | 39,148 of 39,152 approved fixes and 194 of 207 approved book merges applied, the last on 2026-11-01. The fixed books still enrich: 299 Goodreads fetches wait at the in-flight cap. `GOODREADS_DAILY_FETCH_CAP` is unset (default 1,500). |
| MCP sign-in (OAuth) | PARTIAL | 9 OAuth connections since 2026-11-09, 5 of them to `/api/mcp/admin`, so discovery and admin sign-in work. The docs-only acceptance (section 4, step 15) is not recorded. |
| Origins and categories (enrichment) | PARTIAL | Judge on (`BOOKS_CATEGORIES_JUDGE_ENABLED=1`), research to the agent queues (`AI_RESEARCH_VIA=queue`). Genre and audience definitions written (a dry run would write 0). Agent queues pending: book facts 213, author facts 70, origin 1,008, categories 580. The paced backfill has not started (no `backfill` runs of the categorize workflow). |
| Local Wikidata | DONE | Service live; the ranked-author enrichment ran 2026-11-10 to 11-12 (13,574 completed runs). The re-check after refresh is off (an after-launch step). |
| Ranking archives | DONE | 44 archives: 43 copied from legacy, 1 automatic. |
| Cover dimensions | DONE | 0 book cover images without a width (12 edition images remain). The Discord check is not recorded. |
| Publisher intake | PARTIAL | Hachette: one finished run, 1,397 titles, all 1,470 read pages at the current parser version. Penguin Random House is enabled but has no run yet. Macmillan is not enabled. |
| List audits | ONGOING | 48 audits finished. Penalty consolidation, renames (5, 11) and guidance are done: every guidance row matches the YAML, and no dynamic penalty is attached. |
| User-added books | PARTIAL | Deployed; 1 submission (added and approved). Both new Sidekiq queues are served, and 2 tokens with `books:admin:merge` exist. The Amazon `get_items` check and the three end-to-end adds are not recorded. |
| Title notes repair | DONE 2026-11-26 | Ran about 02:39 UTC with #551 deployed (book 11563 changed then). A dry run now finds 0. |
| V1 Firebase accounts | NOT RUN | 0 users carry a `tgbv1-` uid. A cutover step. |
| Membership emails, search indexing | NOT YET (correct) | `MEMBERSHIP_EMAIL_SCOPE` and `BOOKS_PUBLIC_INDEXING` are unset; `BOOKS_DOMAIN` is `new.thegreatestbooks.org`. Hostname-switch steps. |
| `SIDEKIQ_CONCURRENCY` | 25 | Stays at 25 (Shane, 2026-11-26). |

## 3. Every week until cutover

Run these in this order, once the first fixed sync (section 4, step 3) has run. Each is safe to repeat.
Do not merge to `main` (a merge deploys) while the sync runs.

1. **`bin/rails data_migration:sync_report`.** Read-only. A `MISSING` line means the sync will fail
   on rows whose book was removed without callbacks: look at those ids first. A large delete count
   means legacy looks wrong: check it before syncing. The `user_list_items` and `reviews` lines say
   how many rows are held for the Goodreads re-import.
2. **`bin/rails data_migration:sync`.** About 10 minutes. It brings over new books and authors (with
   their identifiers, covers and search indexing), users, user lists and list items, reading goals,
   saved searches, recommendation settings, reviews and corrections, then rebuilds the favorites
   lists. It leaves alone every reader/book pair the Goodreads re-import changed, and it copies no new
   legacy identifier onto a book we already have (`docs/features/books-legacy-sync.md`, "The Goodreads
   re-import hold" and "Identifiers"). Its output lists each step's result; the `user_list_items` step
   shows `held_legacy` and `held_here`, the `reviews` step `held`. A step that would delete more than
   5% of a table (and over 500 rows) refuses; if the deletions are real, re-run with
   `SYNC_ALLOW_DELETES=1`. A failed run moves no watermark, so running it again is safe.
   Avoid book merges (admin, MCP agents, replay apply, submissions) while the sync runs.
3. **`bin/rails data_migration:sync_report` again.** Every insert, update, delete and dropped count
   is 0, every "would insert" is 0, and there is no `MISSING` line. The held counts are still printed,
   and the totals (legacy and here columns, redirects recorded, users deleted on legacy, merge
   collisions, the "legacy edits to existing books" line) stay non-zero. All of that is expected.
4. **`bin/rails books:authors:merge_unknown`.** A dry run. If it lists authors, run it again with
   `APPLY=1`: the sync brings legacy authors over directly, so a new "Anonymous" or "Unknown Author"
   skips the import finder. It prints "Nothing to merge." when there is nothing (2026-11-26: nothing).
5. **`bin/rails books:goodreads_replay:apply`, then `bin/rails books:goodreads_replay:repair_ratings`.**
   The sync overwrites legacy-origin reviews with legacy's truncated integer rating (3 for a 3.75);
   `repair_ratings` puts the quarter-star rating back. `apply` re-runs the replay's approved verdicts,
   each a no-op when already done. Read the tallies they print. Keep running both until several weeks
   in a row show they changed nothing.
6. **`bin/rails books:goodreads_replay:load`.** Copies the legacy Goodreads imports made since the
   last load (it needs the `LEGACY_R2_*` variables, which production has). It reuses imports already
   loaded. If it loaded any new complete import, run a re-import pass (3.2) now, then continue with
   step 7.
7. **`bin/rails books:titles:repair_notes`.** `DRY_RUN=1` first to see the list. The sync never
   rewrites the title of a book we already have, but the books it adds arrive with legacy's titles,
   series notes included. Idempotent: a second run reports 0.
8. **Alternate titles.** `bin/rails "books:alternate_titles:review[all]"` (one AI call per book with
   undecided titles, on the `low` queue; wait for it), then `bin/rails books:alternate_titles:undo_findings`
   (a dry run: read the counts and samples), then `bin/rails "books:alternate_titles:undo_findings[apply]"`.
   Each handles only rows it has not handled before. Details: `docs/features/books-alternate-titles.md`.
9. **Verification of new books, once section 4 step 8 has run.**
   `bin/rails "books:verify[all,post_import]"`. It verifies the ranked books not yet verified, the
   ones the sync added included. Never while a re-import pass is matching (both need Open Library's
   one `/resolve` slot).
10. **WorldCat, once section 4 step 9 has run.** `bin/rails "worldcat:backfill[verified]"`, after
    step 9 above. It is additive and idempotent: it links only books that have no WorldCat links yet,
    and reads verified ISBN-13s only, so it reaches new books once they are verified.
11. **Origins and categories, once section 4 step 10's backfill has finished (optional).**
    `bin/rails "books:categorize:backfill[all,all,weekly]"`, then again with `APPLY=1`. It plans only
    the books the sync added and the books a deferral or failure left undone. Before that backfill
    has run, `all` would plan the whole catalog: do not run it early.
12. **Rankings.** On the admin page of the books primary ranking configuration, use **Refresh
    Rankings**. It reweighs the lists, ranks the books and requests the author rankings when it lands
    (the 04:00 UTC author cron is the safety net).

The recommendations export (02:30 UTC), training (04:00 UTC) and model load (hourly) pick up the
synced data by themselves.

### 3.1 Not weekly

- `firebase:backfill_v1_uids` runs after each sync only once the V1 Firebase import has run. It has
  not (0 `tgbv1-` uids on 2026-11-26), and it is a cutover step (section 5.1). Before that import, the
  backfill would point about 30,000 accounts at Firebase identities that do not exist.
- `books:verify[all,recheck]` re-verified books that got new legacy identifiers. The sync no longer
  adds legacy identifiers to books we already have, so after the one-off run in section 4 step 8 it has
  nothing new to find.

### 3.2 A re-import pass (when `goodreads_replay:load` brings new imports)

Each step queues a Sidekiq job and only takes work not done yet; wait for each to finish before the
next. The `books:goodreads_reimport:*` tasks abort unless `GOODREADS_REIMPORT_ENABLED=true` (the
report, snapshot and sample work without it). Finish a pass, through the report, between two syncs: a sync in the middle deletes what
readers removed on legacy, and the loss check counts that as a drop. Details and where each output
lands: `docs/features/goodreads-reimport.md`. Do not run `books:verify` while a pass runs.

0. **Record legacy's book on the new rows.** `bin/rails books:goodreads_reimport:link_legacy_books`.
   It records, on each new row, the book legacy put it on, read from legacy's own identifiers (the sync
   no longer copies the old importer's Goodreads ids onto our books). The survey and `decide` both read
   it: without it every row is decided "add", and legacy's entry stays on the reader's shelf beside the
   right one. The Sidekiq log line "link_legacy_books batch" gives linked and unlinked counts; a few
   unlinked rows are normal (legacy never put them on a list). The first pass got this from the old
   replay's `resolve` (2026-10-14). The 2026-11-26 pass ran steps 1, 2 and 6 before this step existed:
   run this step, then steps 1, 2 and 6 again.
1. **Refresh the survey.** `bin/rails "books:goodreads_rebuild:survey[all,redo]"`. The new legacy
   books are classified; the mixed books are read from it.
2. **Archive the mixed books.** `bin/rails books:goodreads_reimport:archive_mixed`. It deletes nothing.
3. **Match.** `bin/rails "books:goodreads_reimport:match[all]"`. Run `[all]` again for any editions it
   left. Each match spends AI calls.
4. **Review.** `bin/rails books:goodreads_reimport:report`, then in Admin, Repair verdicts, filtered
   to `reimport_match`: approve the right proposals and **correct** the wrong ones ("Correct this
   match": the right book's id, or create a new book). Do not reject a wrong pick: a rejected match is
   never matched again and its readers stay where they are.
5. **Apply the matches.** `bin/rails books:goodreads_reimport:apply`. It writes the approved matches
   and creates the new books.
6. **Decide.** `bin/rails "books:goodreads_reimport:decide[all]"`, and once it has finished, `decide[all]`
   again: the second run decides the guesses for mixed books, which wait until their rows are decided.
7. **Snapshot.** `bin/rails "books:goodreads_reimport:snapshot[new_pass]"`. It writes
   `counts-<UTC time>.json` beside the first pass's `counts.json` and never touches an existing file.
   Take it right before the apply that moves rows.
8. **Apply.** `bin/rails books:goodreads_reimport:apply`. Re-running is safe.
9. **Authors.** `bin/rails "books:goodreads_reimport:check_authors[all]"`. Every author verdict is a
   proposal: review them in Admin, Repair verdicts, filtered to `reimport_author` (its Copy prompt hands
   the review to an admin agent). Then `bin/rails books:goodreads_reimport:apply` again. Do not merge
   authors by hand between the first `check_authors` and that apply.
10. **Report.** `bin/rails books:goodreads_reimport:report`. It compares against the newest snapshot.
    The acceptance lines at the bottom should each print 0; read the conflicts and the verdicts closed
    with nothing to do.
11. **Sample.** `bin/rails books:goodreads_reimport:sample`. The result is in the Sidekiq log
    ("Goodreads re-import sample check"), not in a file; note it somewhere, because the next deploy
    resets the log. **Any "no" stops the run** until its cause is fixed.

Then continue with section 3, step 7.

## 4. Before cutover, once (not yet done)

In order. Each step says whether it is safe now or what it waits for.

**Shared bottlenecks.** Steps that share one of these must not run at the same time:

- **Open Library's one `/resolve` slot**: `books:verify`, a re-import pass's `match`, member Goodreads
  imports and `goodreads_replay:finish_legacy`, and the list wizard. A caller that cannot get the slot
  within its budget decides without Open Library, so its results get worse, not just slower.
- **The Wikimedia pace** (one request a second): `books:authors:enrich` and
  `books:categorize:backfill`. Two at once halves each.
- **Goodreads fetches** (`GOODREADS_DAILY_FETCH_CAP`, default 1,500 a day): the enrichment of the
  rebuild's fixed books (300 in flight on 2026-11-26), the re-import's new books once their enrichment is
  on, and readers' Goodreads links (100 a day reserved).
- **Sidekiq threads** (`SIDEKIQ_CONCURRENCY` 25): a re-import `match[all]` fills them waiting on the AI.
- **AI spend**: re-import match, decide, author check and sample; `alternate_titles:review`; the
  categorize backfill; `enrichment_queue:work` (paid research, about 15 cents a row).

1. **Pause Goodreads uploads on the old site. Shane merges and deploys.** Safe now. The change is the
   branch `goodreads-import-paused` in `the-greatest-books` (spec section 5.3): the upload refuses with
   a message, the import page and the recommendations card show it instead of the upload button, and
   imports already running finish. Merging there deploys. Afterwards, open `/goodreads_imports` and
   `/user_lists` on the old site and check the message shows.
2. **Deploy the sync fix.** Waits for the dev rehearsal (it replaces the development database, so it
   needs Shane's go) and for step 1. Then merge the branch `worktree-sync-keeps-reimport` (merging
   deploys).
3. **The first sync after the fix.** Waits for steps 1 and 2. `bin/rails data_migration:sync_report`
   (check it prints the "held for the Goodreads re-import" counts; if not, the fix is not deployed:
   stop), `bin/rails data_migration:sync`, `bin/rails data_migration:sync_report` (0 changes, held
   counts printed). Then section 3 from step 4 on; its step 6 loads the 10 legacy imports made since
   2026-11-13 and any made before step 1 deployed, and the re-import pass (3.2) covers them. From
   then on, run section 3 every week.
4. **Re-import: the sample check.** Safe now; read-only, hundreds of AI calls.
   `bin/rails books:goodreads_reimport:sample`, then find "Goodreads re-import sample check" in the
   Sidekiq log and write the result down (section 2 lists it as UNKNOWN). Any "no" stops the next pass
   until its cause is fixed.
5. **Re-import: the 11 proposed author fixes.** Safe now. Admin, Repair verdicts, filtered to
   `reimport_author` and proposed. Approve or reject each; the next `apply` (in the pass of step 3)
   carries out the approved ones, or run `bin/rails books:goodreads_reimport:apply` once reviewed,
   while `GOODREADS_REIMPORT_ENABLED` is on.
6. **Re-import: enrichment on.** Safe now. Set `GOODREADS_REIMPORT_ENRICHMENT=true` in
   `secrets/.env.production` (SOPS) and merge, which deploys and restarts the worker. The books the
   re-import created then join the rebuild's enrichment queue, after the rebuild's fixes, under the same
   Goodreads fetch cap.
7. **Re-import: gate off.** Waits for the pass in step 3. With uploads paused on the old site, no
   further pass is expected. Remove `GOODREADS_REIMPORT_ENABLED` (or set it to `false`) in the SOPS
   file and merge. While it is off, `archive_mixed`, `match`, `decide`, `apply` and `check_authors`
   abort. If `goodreads_replay:load` later brings a new import, turn it back on for that pass.
8. **Verification: the post-import books and the recheck.** Waits for the pass in step 3 (both need
   the `/resolve` slot). `bin/rails "books:verify[all,post_import,recheck]"`: it verifies the ranked
   books not yet verified, post-import ones included, and redoes the verified books in its scope that
   got legacy identifiers after their check (226 such books of every scope on 2026-11-26). Only one
   verification run works at a time; a deploy puts a running pass back on the queue. Then `bin/rails books:verify_report`. Add `unranked` only if you want the rest of the
   catalog. Details: `docs/features/book-verification.md`.
9. **WorldCat: the backfill.** Safe now, best after step 8 (it reads verified ISBN-13s, so more books
   qualify after it). If the development rehearsal has not been done (no record of it), do it first:
   `bin/snapshot-dev-db.sh --label pre-worldcat` from the repo root, then with the local WorldCat API
   running (`docker compose --profile worldcat up -d worldcat` in `data-sources/`),
   `bin/rails "worldcat:backfill[2000]"`; read the "WorldCat backfill" log line and spot-check ten books
   (no book should get both Fiction and Nonfiction); `bin/snapshot-dev-db.sh --restore` if the links look
   wrong. Before the production run, time one full batch on the VM (Shane runs with `!`): from
   the dev machine, after `bin/rails "worldcat:export_isbns[/home/shane/wc-data/our_isbns.txt]"`,
   `test "$(wc -l < /home/shane/wc-data/our_isbns.txt)" -ge 500 || { echo "export has fewer than 500 ISBNs"; exit 1; }; head -500 /home/shane/wc-data/our_isbns.txt | jq -R . | jq -sc '{isbn13s: .}' | ssh debian@<vm-address> "curl -s -o /dev/null -w '%{time_total}\n' -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:8082/lookup"`
   twice (cold, then warm). The VM's address: `ssh pve-mini qm guest cmd 130 network-get-interfaces`.
   Both times should be well under the service's 25 s deadline (`WC_API_DEADLINE_S`); a `504` or a
   time near it means lower the backfill's batch size (100) or raise the deadline first. Then, in
   production (Shane runs with `!`), `bin/rails "worldcat:backfill[verified]"`. Read the worker log's
   "WorldCat backfill" line. The map sends some terms to "Police Procedural", which is not an active
   genre in production (2026-11-26), so the backfill links nothing for them: create the genre (the
   genre plan lists it) or change the map first if you want those links. If the genre map changed
   during review, re-run `bin/rails worldcat:report` in development and commit
   `docs/data-quality/worldcat-genre-mapping.md`. From then on it is weekly (section 3, step 10). Details: `docs/features/worldcat-data-service.md`.
10. **Origins and categories.** The agent queues are safe now; the paced backfill waits.
    Details: `docs/features/enrichment-queue.md` and `docs/features/books_enrichment.md`.
    1. **Work the agent queues**, in this order, each until it is empty (a claim returns no items and
       `remaining` is 0): book facts, author facts, origin, categories. For each, Fill on
       `/admin/enrichment_queues` (or `bin/rails "enrichment_queue:fill[books.book_facts,ranked]"`, and
       the same with `books.author_facts`, `books.origin`, `books.categories`), reload until Pending
       stops moving, then Copy prompt on its row and give it to an agent on the admin MCP server. Check
       Done and Failed afterwards and Re-queue a failed row once its cause is fixed. Work the queues
       before the backfill: once the backfill has planned a run for a book, a fill skips it until the
       run finishes. Fill again after the re-import pass of step 3, which creates and deletes books.
    2. **Optional, spends money: the paid worker** for rows you would rather pay for than give to an
       agent. `bin/rails "enrichment_queue:work[books.origin,100]"` (any of the four kinds; the limit is
       required). It reaches only pending rows and rows whose claim expired; to send it a row an agent
       skipped, press Re-queue on that row first.
    3. **Read what the agents did**: `bin/rails "books:origin:report[agent]"`,
       `bin/rails "books:categories:report[agent]"`, then `bin/rails "books:categories:add_aliases[agent]"`
       (a dry run) and again with `APPLY=1` (add `NAMES=a,b` for only the names you checked).
    4. **Re-run the stage 2 rehearsal in development** (`docs/features/books_enrichment.md`), now that
       it covers the categories judgment. The dev Sidekiq process needs `BOOKS_CATEGORIES_JUDGE_ENABLED=1`.
       There is no record that this re-run happened.
    5. **The paced backfill. Shane runs with `!`.** Waits for 1, 4, the re-import pass of step 3, and no
       `books:authors:enrich` running (the Wikimedia pace). `bin/rails "books:categorize:backfill[all,all,<label>]"`
       prints the count and hours; run it again with `APPLY=1`. One book every 8 seconds, ranked books
       first: about 15 days for the whole catalog. With `AI_RESEARCH_VIA=queue` it never researches;
       a book whose judgment wanted research gets a pending row in the origin or categories queue,
       unless it already has a row there.
    6. **After it finishes**: work the origin and categories queues again (no fill needed for the rows the
       backfill queued). Rows an agent skipped, or whose answer applied nothing, are closed: press
       Re-queue on each one to reach it (one at a time). Then `bin/rails "books:origin:report[<label>]"` and
       `bin/rails "books:categories:report[<label>]"`; `bin/rails "books:categories:add_aliases[<label>]"`
       (dry run, then `APPLY=1`); `bin/rails "books:origin:accept_disagreements[<label>]"` with `IDS=` and
       `APPLY=1`. If a run removed links it should not have, `bin/rails "books:categories:restore_removals[<label>]"`
       prints the count and `APPLY=1` restores them. Then rankings (section 3, step 12): origins change
       the western-canon penalty.
11. **Publisher intake. Shane runs with `!`.** Safe now. Penguin Random House is enabled; its first run
    starts at the 06:20 UTC daily job (or `bin/rails "books:publisher_intake:run[penguin_random_house_us]"`
    on the worker). It is about 10,000 reads, roughly five days at the default cap. Watch it on
    `/admin/publisher_intake` or with `bin/rails books:publisher_intake:status`. A sitemap file over the
    fetcher's file size cap shows on the run as `unavailable`; the size reason is only in the log, and the
    remedy is raising the fetcher's `FETCHER_MAX_FILE_BYTES`. Then add Macmillan:
    `PUBLISHER_INTAKE_SOURCES=hachette_us,penguin_random_house_us,macmillan_us` in the SOPS file, merge,
    and watch its first (baseline) run's duration: its product sitemap files were never measured, and
    discovery writes one row per URL. After that run finishes, release its baseline titles with
    `bin/rails "books:publisher_intake:release_baseline[macmillan_us,<limit>]"` in slices the daily cap
    allows, repeating until none you want remain. After a parser fix, `books:publisher_intake:reparse[<source>]`
    re-reads only listings below the source's `parser_version`, so the fix must raise that version.
    To stop a source, remove it from `PUBLISHER_INTAKE_SOURCES` and deploy. Nothing here touches the
    catalog. Details: `docs/features/publisher-intake.md`.
12. **List audits.** Safe now; ongoing. Open `/admin/list_audits` on the books host, Copy prompt, and
    give it to an agent on the admin MCP endpoint with a `books:admin:write` token. **Release** frees a
    list whose lease got stuck. After each batch, Refresh Rankings (section 3, step 12): audits change
    list fields and penalties, never the weight directly. Details: `docs/features/list-audits.md`.
13. **Duplicates.** Safe now; ongoing. Work the pending pairs in the admin Duplicates queue. A merge is
    recorded as a redirect, so the sync never brings the merged book back.
14. **User-added books checks.** Safe now. Details: `docs/features/user-added-books.md`.
    1. **Amazon's `get_items` response. Shane runs with `!`.** In a shell inside the worker container
       (not a console; `ASIN=x docker compose exec ...` does not pass the variable in):
       `ASIN=0143039431 bin/rails runner 'a = Services::Amazon::Client.new; r = a.send(:client).get_items(marketplace: Services::Amazon::Client::MARKETPLACE, partner_tag: a.send(:partner_tag), item_ids: [ENV.fetch("ASIN")], resources: Services::Books::AmazonProductService::AMAZON_RESOURCES); b = r.parse; puts r.status.code, b.keys.inspect; puts b.values.flat_map { |p| p.is_a?(Hash) ? Array(p["items"]) : [] }.map { |i| i.dig("itemInfo", "title", "displayValue") }'`,
       then again with `ASIN=B0ZZZZZZZZ`. It prints only the status, the top-level keys and the titles.
       The known ASIN must answer with the key `itemsResult` and the right title; the unknown one must
       come back empty, not as an error (an error reads as "Amazon is down" and the request retries for
       an hour). If the key differs, fix `Client#get_items` before relying on Amazon links.
    2. **Add three books end to end. Shane runs with `!`.** Signed in on the books site, on one of your
       own lists, search for a book that is not there and use "Can't find it? Add a book": one by ISBN,
       one by Goodreads link, one by Amazon `/dp/` link. Each should appear on the list within a few
       minutes and under "Needs review" in `/admin/book_submissions`. Reject all three afterwards, which
       also removes the list items.
    3. **The review agent.** Copy prompt on `/admin/book_submissions` and give it to an agent on the
       admin MCP endpoint (a `books:admin:merge` token exists). The defaults of `GOODREADS_PRIORITY_RESERVED` (100),
       `BOOK_SUBMISSION_LOOKUP_RUNS` (100) and `BOOK_SUBMISSION_LOOKUPS_ENABLED` (on; `0` stops the early
       lookups without a deploy) need no setting.
15. **MCP sign-in acceptance from the docs alone.** Safe now. Following only `/developers`, connect
    claude.ai, Claude Code and Codex to `https://<books host>/api/mcp` by signing in and ask each one
    question. Then Revoke each on `/developers/tokens` and confirm each asks to sign in again. Record
    the result on the acceptance line of `docs/features/mcp-server.md`.
16. **Cover thumbnails in Discord.** Safe now. Paste a ranked book link and a ranked game link you have
    not shared before into Discord; both should show a small cover. First check the page's HTML has
    `og:image` (`curl -s <url> | grep og:image`): pages are edge-cached for up to a day.
17. **Recommendations, before books goes live** (code work, safe now). Cap the shelf the collaborative
    signal scores (an 18,534-book shelf takes 1.1 s in the neighbour SQL) and profile the 140-215 ms
    it adds on the 20-99 and 100+ segments. The collaborative list still ignores the quality prior.
    Details: `docs/features/recommendations.md`, "Known gaps".
18. **Goodreads fetch cap (optional).** Read `bin/rails books:goodreads_rebuild:fixes_report`'s
    enrichment section. If nothing failed and the gate never blocked, raise `GOODREADS_DAILY_FETCH_CAP`
    (SOPS, merge). Above 5,760 a day, lower `GOODREADS_FETCH_INTERVAL` too.
19. **Amazon enrichment of ranked books (decide).** `bin/rails books:amazon_enrich_ranked`. Waits for
    steps 8 and 9: it writes book-level identifiers (source amazon) and raises `identifier_collision`
    duplicate pairs, and its collision guard needs verified values to compare against. No record that
    it has run.
20. **Book AI enrichment (decide).** `bin/rails "books:enrich_missing[<limit>]"`. Nothing queues it.
21. **Adaptations with the original's title (decide).** About 75 books the re-import created (approved)
    share the exact title and author of the original: audio dramas, abridgments, adaptations. Nothing on
    the page tells them apart yet. No design.
22. **Author enrichment beyond the ranked authors (decide).** `bin/rails "books:authors:enrich[all]"`.
    Most of the 76,931 authors have no ranked book. One author every 2 seconds on the Wikimedia pace, so not at
    the same time as step 10's backfill. Check it with `bin/rails "books:authors:enrich_report[<the time it printed>]"`.
23. **First-pass duplicate entries (decide; no tool yet).** 21 legacy imports loaded on 2026-11-13 reached the first
    re-import pass without legacy's book on their rows (section 3.2, step 0, did not exist yet), so all 6,358 of their
    rows were applied as adds. 6,123 changed nothing (legacy had already put the reader on the right book). 234 left
    legacy's wrong book on the reader's list beside the right one, nearly all for one reader (user 70967, mostly manhwa
    volumes). Measured read-only 2026-11-27. Removing them needs a small reviewed change (each removal recorded on a
    verdict, so the sync's hold keeps it); until then they are harmless extra entries.
24. **Amazon identifiers skipped for "Last, First" authors. Shane runs with `!`.** Safe now, after the deploy
    that adds `books:amazon_book_identifiers_repair`. Until 2026-11-27 the Amazon enrichment compared the
    author as Amazon writes it ("Johnson, Daisy") with ours ("Daisy Johnson"), so for most books it kept the
    edition but never put the product's ASIN and ISBNs on the book. The repair re-checks the stored Amazon
    data under the same rules as a live enrichment and asks Amazon nothing. First
    `bin/rails "books:amazon_book_identifiers_repair[dry_run]"`, which writes and flags nothing, then
    `bin/rails "books:amazon_book_identifiers_repair[apply]"`. Both queue a chain of jobs on `low`; the totals
    are in the worker log ("Amazon book identifiers repair ... finished"). On the development database
    (2026-11-27): 72,833 editions checked, 46,933 would add 71,829 identifiers to their books, and 38 raise a
    duplicate pair for step 13 instead. A rerun writes nothing new. Running it again after step 19 covers the
    editions step 19 adds.

## 5. Cutover, hostname switch, after launch

### 5.1 Cutover day

1. Take legacy offline.
2. `FINAL=1 bin/rails data_migration:sync_report`, then `FINAL=1 bin/rails data_migration:sync`, then
   `FINAL=1 bin/rails data_migration:sync_report`. `FINAL=1` drops the 24-hour delay, so the last day's
   books come over too.
3. Section 3, steps 4-12, with a re-import pass (3.2) if `goodreads_replay:load` brought new imports.
4. **Finish the failed and stuck legacy Goodreads imports.** Only now: they write into legacy users'
   lists, which a sync would rewrite. `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy` lists
   what it would do. Then `bin/rails "books:goodreads_replay:finish_legacy[1]"`, one import at a time:
   wait until it is no longer in progress before the next, because running imports are skipped, not
   counted, and four at once overloaded Open Library on 2026-10-06. Each also uses Goodreads fetches.
   Approve or reject each under Books, Goodreads Imports. Details: `docs/features/goodreads-import.md`,
   "Finishing legacy imports".
5. **V1 Firebase accounts, once.** Follow "Running it" in `docs/features/v1-user-migration.md`: export,
   import, `firebase:backfill_v1_uids`, then shred the file. Import before backfill. After the final
   sync, because the sync's user overwrite resets `users.auth_uid`. All four domains share one Firebase
   project, so imported accounts can sign in to music and games at once.
6. **The empty import-made books (decide).** About 1,700 books the old importer made had no reader
   items and no reviews on 2026-11-26. Measure again, then decide whether to delete them. No design yet.
7. **If web and worker move to separate servers**, add the worker server's IPv4 to
   `OPENSEARCH_ALLOWED_IPS` (`sops secrets/.env.opensearch`), merge, and run the "Deploy OpenSearch"
   workflow before the worker uses search (`docs/features/opensearch-server.md`, "Add or remove an app
   server").
8. **One reader on the wrong Grabiński book.** After step 3 (no sync runs after it). The 2026-11-27
   sample check answered no for `reimport:row:1493:400`: Goodreads edition 19368780, *The Dark Domain*,
   was matched on 2026-11-17 to #83959 *Niesamowite Opowieści*, a different collection, before #250214
   *The Dark Domain* existed. An applied match cannot be corrected, and a hand move before the last sync
   is undone by it (the sync holds only the moves a verdict recorded). In a console:
   - point the `Books::GoodreadsEdition` with `goodreads_book_id` 19368780 at book 250214, and move its
     `books_work_goodreads_id` 19368780 identifier from #83959 to #250214;
   - move user 69160's entries for this row from #83959 to #250214. The user has three items on #83959
     (one on `read`, two on custom lists) and may also have read the Polish collection: check their other
     rows on #83959 before moving all three.

### 5.2 Hostname switch (thegreatestbooks.org points here)

- **Issue the TLS certificate on the server before merging the hostname change.** Merging deploys. If
  nginx names a certificate that does not exist, it crash-loops, and one nginx container fronts every
  site. The deploy job still shows green.
- **`BOOKS_DOMAIN` lists the apex first.** `config.hosts` and the MCP transport's allowed hosts come
  from it, and the first entry is the OAuth issuer, the base of every metadata URL and the sitemap host.
- **Stripe, in this order** (`docs/guides/stripe-account-setup.md`, sections 7 and 11):
  1. Re-check the legacy guard just before launch.
  2. Delete legacy's webhook endpoint by hand in the Stripe Dashboard. Never run
     `rake stripe:delete_webhooks` once the hostname points here: it would delete this app's endpoint.
  3. Retire legacy's `/support`.
  4. `bin/rails billing:backfill_email_stamps`.
  5. Set `MEMBERSHIP_EMAIL_SCOPE=all`.

  Reversing 4 and 5, or skipping 4, sends every legacy member a welcome email at the next 05:00 UTC sweep.
  After the deploy, check Admin, Webhook Events for `ignored` rows.
- **Search indexing: set `BOOKS_PUBLIC_INDEXING=true`** (`sops secrets/.env.production`, merge), only
  after thegreatestbooks.org serves this app and `BOOKS_DOMAIN` lists the apex first. Until then every
  books page is `noindex`. Pages are edge-cached for up to 24 hours with the old tag, so purge the books
  cache or wait a day, then check a ranked book page reads `index, follow`.
- **Sitemap**, once indexing is on: `https://thegreatestbooks.org/sitemap.xml` returns 200 and
  `/robots.txt` ends with its `Sitemap:` line; purge both from the edge cache or wait 24 hours. Then
  submit `/sitemap.xml` in Google Search Console (`docs/features/sitemaps.md`).
- **MCP connectors.** Tell members who connected before the switch to remove the connector and add
  `https://thegreatestbooks.org/api/mcp`: claude.ai drops `Authorization` across redirects, so a
  connector on the old hostname cannot get in.

### 5.3 After launch

- **Never run the Firebase bulk import again.** An import replaces the whole account, so it would reset
  changed passwords and verified emails. The export and `firebase:backfill_v1_uids` stay safe.
- **Remove the `LEGACY_R2_*` credentials** from production secrets once the final sync and the last
  replay load are done: both read legacy's R2 (the sync for new books' covers).
- **Remove the old site's server from the search allowlist** when it shuts down: take its IP out of
  `OPENSEARCH_ALLOWED_IPS` and run the "Deploy OpenSearch" workflow. Removing an IP does not cut
  connections it already has open (see the runbook).
- **Optional: the Wikidata re-check.** Set `config.x.wikidata.recheck_after_refresh = true`
  (`config/initializers/wikidata.rb`) and deploy. The 06:00 UTC cron then re-checks books and authors
  created in the last 90 days that found no QID, after each new dump. `bin/rails wikidata:recheck` is a
  dry run; `APPLY=1` queues the work. It skips any book whose evidence lists a failed source.
- **The Open Library key and duplicate-key backfill** (list wizard). Not specced yet.

## 6. Done

Finished one-off steps, with what someone needs to run them again. Newest areas last.

- **Full migration and switch-over** (the old sections 1 and 2). The weekly `data_migration:all`, the
  cover images (`data_migration:book_images`), the search reindex and `sync_init` (watermarks created
  2026-10-10 04:44 UTC, with `BOOK_IDENTIFIERS_FROM`). `data_migration:all`, `data_migration:book_images`
  and every other task the sync replaced now refuse with "use data_migration:sync"; the sync brings new
  books' covers itself. Details: `docs/features/books-legacy-sync.md`.
- **Firebase authorized domains.** Every host the app serves is authorized (Shane, 2026-09-05). All
  domains share one Firebase project.
- **Recommendations model** (old section 3, steps 1-4). R2 bucket and secrets, the `recommender-train`
  healthcheck, the home-server timer, the first model. Active: model 42, from the 2026-11-25 export. A
  second export on the same day reuses the day's file name, so a run by hand only helps before 04:00
  UTC. Details: `docs/features/recommendations.md`, "Collaborative signal".
- **Stored-name normalization** (`books:normalize_names:report`, then `books:normalize_names:apply`). The
  report finds 0 to change on 2026-11-26.
- **Identifier provenance** (`identifiers:mark_legacy`). 0 books identifiers without a source; a second
  run prints 0.
- **Verification pass.** `books:verify[all]` over the ranked pre-import books,
  `books:verify[all,post_import,trusted]`, the unsure second chance (2026-10-26: unsure 4,011 to 2,482),
  and keep-the-bigger-work (2026-10-27, 278 books). 21,241 rows, the last on 2026-10-29. To undo a route
  or one book (`books:verify_revert_route`, `books:verify_revert`): `docs/features/book-verification.md`.
- **Duplicate sweep** (`books:find_duplicates`). 3,533 pairs merged, 786 marked not duplicates. The
  queue keeps filling from other sources (section 4, step 13).
- **Goodreads replay** (the old section 5, step 5). Loaded, resolved and applied in October. The
  rebuild and the re-import replaced it: its 2,691 relink and 2,091 strip proposals were retired
  unapplied, and its proposal steps (`fix_slugs`, `resolve`, `duplicates`, `junk`) are not run again.
  `load`, `apply` and `repair_ratings` stay weekly (section 3). Details: `docs/features/goodreads-import.md`.
- **Category cleanup** (runbook in `docs/features/books-categories.md`). 64,296 decisions applied. The
  sync's `category_cleanup` step keeps new legacy categories in line; re-run `propose` now and then for
  what that step leaves undecided.
- **Open Library `/resolve` under load** (#358). One `/resolve` at a time; the rest get an instant 503
  busy (section 4, "Shared bottlenecks").
- **WorldCat service and genre cleanup** (old section 9, steps 1-7, 9, 10 and 12-14). Artifact built; Cloudflare,
  healthchecks and secrets (2026-10-14); VM 130 with the artifact; `WORLDCAT_SERVICE_URL` in production
  (0 of 5,984 match decisions in the week to 2026-11-26 list `worldcat` as failed); the old site stops
  creating genres (`the-greatest-books` PR #10, 2026-10-18); genre map reviewed; `categories:genres:apply`
  (3 audiences; Noir and Hardboiled under Crime Fiction); `worldcat:apply_aliases` (would add 0 now; it
  reports "Police Procedural" as a mapped genre that does not exist). What remains: section 4, step 9.
- **Alternate titles cleanup** (old section 10, steps 1-5). Backfill, `review[ranked]`, `review[all]`,
  `undo_findings[apply]` (2,033 findings undone, 2026-10-24 and 25). `redo_finding[<id>]` reverses one
  finding; `undone_findings[<book id>]` lists a book's. Repeating steps: section 3, step 8. Details:
  `docs/features/books-alternate-titles.md`.
- **Goodreads rebuild** (old section 11, steps 1-5). Cohorts, retired replay proposals, survey and its
  pass-2 evidence, `decide_fixes`, `retire_lump_verdicts`, review, `retire_unneeded_fixes`, apply. 39,148
  of 39,152 approved fixes and 194 of 207 approved book merges applied, the last on 2026-11-01. The
  10-minute job enriches the fixed books by itself. Before any later `decide_fixes`, run
  `books:goodreads_rebuild:survey[all,redo]`. What remains: section 4, step 18. Details:
  `docs/features/goodreads-rebuild.md`.
- **Goodreads re-import, first pass** (old section 12, steps 1-11). Gate on, survey, archive, match (with
  the one-off `recheck_creates`), review, apply, decide twice, snapshot (`counts.json`, 2026-11-20 04:28
  UTC), apply, author check, apply, report (`report-20261121T053123Z.md`). Numbers in section 2. What
  remains: section 4, steps 3-7.
- **Two duplicates the re-import created, merged 2026-11-26** through the admin MCP: *Cosmicomics* 251937
  into 250177, *Why We Eat (Too Much)* 253586 into 253135 (redirects recorded 01:53 UTC).
- **MCP sign-in** (old section 13, steps 1, 2 and 4). The edge rule for `/.well-known/oauth-*` is live,
  `BOOKS_DOMAIN` admits `new.thegreatestbooks.org`, and admin sign-in works: 9 OAuth connections since
  2026-11-09, 5 of them to `/api/mcp/admin`. Admin approvals need renewing every 30 days. What remains:
  section 4, step 15, and section 5.2. Details: `docs/features/mcp-server.md`, "Signing in with OAuth".
- **Origins and categories setup** (old section 14, steps 1-4). Author Wikidata enrichment; the genre and
  audience definitions (`books:categories:write_definitions`, a dry run would write 0);
  `BOOKS_CATEGORIES_JUDGE_ENABLED=1`; `AI_RESEARCH_VIA=queue` (set it to `api` to spend through the API
  again). What remains: section 4, step 10.
- **Local Wikidata** (old section 15, steps 1-4 and 6-11; the optional healthchecks of step 5 are not recorded). VM 150, tunnel, PR #473 and PR #474, and the
  ranked-author enrichment `books:authors:enrich[13333]` (2026-11-10 to 11-12, 13,574 completed runs; check
  one with `books:authors:enrich_report[<the time it printed>]`). 0 of 5,984 match decisions in the week
  to 2026-11-26 list `wikidata` as failed. What remains: section 4, step 10.4, and section 5.3. Details:
  `docs/features/wikidata-data-service.md`.
- **Ranking archives** (old section 16). `data_migration:ranking_archives` copied 43 legacy archives; the
  monthly job made one more. Re-running it at cutover only creates archives that do not exist. If it
  aborts with unknown ids, either the sync is behind legacy or a book was removed without callbacks: do
  not force it. Details: `docs/features/ranking-archives.md`.
- **Cover dimensions** (old section 17, step 1). `images:analyze_missing_dimensions` (production only; in
  development every download fails). 0 book covers lack a width. What remains: section 4, step 16.
- **Publisher intake, Hachette** (old section 18, steps 1-4). The fetcher's `/fetch_file`, Hachette
  enabled, its first run (2026-11-24: 5.5 hours, 2,669 listings, 1,397 titles) and the reparse (every
  read listing at parser version 3). What remains: section 4, step 11.
- **List audit setup** (old section 19, steps 1-3 and 6-9). `penalties:consolidate` (penalty 21 gone, 44
  and 46 renamed), the renames of penalties 5 and 11, every guidance reload (all 29 rows match
  `config/penalties/guidance.yml`), `penalties:detach_dynamic` (none attached). After a later guidance
  edit: `bin/rails penalties:load_guidance OVERWRITE=1`; it exits 1 when a penalty's name differs from
  the file. What remains: section 4, step 12.
- **User-added books** (old section 20, steps 1 and 4). Both new queues (`goodreads_fetch_priority`,
  `serial_priority`) are served; admin tokens with `books:admin:merge` exist. What remains: section 4,
  step 14.
- **Title notes repair** (old section 21). `books:titles:repair_notes`, 2026-11-26. It repeats weekly
  for the books the sync adds (section 3, step 7). About 2,000 titles keep brackets that need judgment
  (publisher series, junk): an agent with the admin MCP, not a rule.
- **Stale `FIREBASE_PROJECT_ID`.** Not set in the production worker's environment on 2026-11-26.
