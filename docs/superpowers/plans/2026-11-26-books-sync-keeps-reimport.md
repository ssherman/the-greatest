# The weekly sync keeps the Goodreads re-import — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `data_migration:sync` and `sync_report` leave every reader/book pair the Goodreads re-import changed alone, copy
legacy identifiers only for books new in the sync, the old site stops taking Goodreads uploads, and
`docs/launch-todo.md` is rewritten to be accurate.

**Architecture:** One new value object, `Services::BooksMigration::ReimportHold`, is built once per sync from the
re-import verdicts and carried on `SyncScope`. The list-item plan, the review migrator and the user-data diff ask it
`held?(user_id, book_id)` and leave held rows untouched on both sides. `BookIdentifierMigrator` narrows its scope to
new books. The old-site change is a separate repo; the doc work is last.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, PostgreSQL. Old site: Rails app in `/home/shane/dev/the-greatest-books/admin`.

**Spec:** `docs/superpowers/specs/2026-11-26-books-sync-keeps-reimport-design.md` (approved 2026-11-26). Read it first.

## Global Constraints

- All Rails commands from `web-app/`. Lint with `bundle exec standardrb`, never `bin/rubocop`. No brakeman.
- No migration in this plan (the sync shares a database with live music and games).
- Tests mirror namespaces (`Services::BooksMigration::ReimportHoldTest`); Minitest 6 (`assert_nil`, never `assert_equal nil`).
- Never run `data_migration:sync`, `sync_report` or anything against production. Never run a destructive command
  against the development database; the rehearsal (Task 9) waits for Shane's explicit go.
- Held set (spec 5.1): `reimport_row` and `reimport_guess` verdicts whose payload has `moved` or `leftovers_removed`,
  **any status, `applied_at` set or not, current or superseded**; pairs `(payload user_id, from_book_id)` and
  `(payload user_id, to_book_id)`. `reimport_mixed` verdicts with `deleted`: `(item["user_id"], payload["book_id"])`
  per item. Book ids are followed through later merges, but never past a book that is some `reimport_mixed`
  verdict's `payload["book_id"]`.
- A legacy row is held when `held?(user, legacy book_id)` or `held?(user, routed book_id)`; a row here is held when
  `held?(user, its book_id)`. The user of a list item is `user_lists.user_id`.
- `UserListMigrator` is unchanged: a list deleted on legacy is deleted here with all its items, held or not.
- Identifiers (spec 5.6): `BookIdentifierMigrator` in sync mode copies a legacy row only when `sync.book_ids`
  includes its `book_id`. The `book_identifiers` watermark still advances as today.
- The old site gets no tests (Shane's standing rule for that repo).

## Review Focus

1. **A reader who has the same book on two lists, one item moved by the re-import.** Both lists must be left alone for
   that book (the hold is per reader and book, not per list) — Task 2 test "holds the pair in every list of the reader".
2. **A held book that was merged after the re-import.** The pair must follow the merge: an item on the survivor is
   still held — Task 1 test "follows a later merge".
3. **A legacy review whose id the re-import moved to another book.** The id must neither be re-pointed nor deleted —
   Task 3 test "leaves a moved review's id on its new book".
4. **`sync_report` disagreeing with `sync`.** A held row counted as insert/delete in the report but skipped by the run
   would make the report never converge — Task 4 tests compare report counts with run counts on the same data.
5. **A legacy identifier on a book the same sync brings over.** It must still be copied (new books arrive whole) —
   Task 5 test "copies identifiers of a book new in this sync".

---

### Task 1: `ReimportHold`, on the sync scope

**Files:**
- Create: `web-app/app/lib/services/books_migration/reimport_hold.rb`
- Modify: `web-app/app/lib/services/books_migration/sync_scope.rb` (add member `:hold`)
- Modify: `web-app/app/lib/services/books_migration/sync_plan.rb:38-44` (pass `hold: ReimportHold.load(redirects: redirects)`)
- Modify: `web-app/test/support/books_legacy_sync_helper.rb:67` (`sync_scope(..., hold: Services::BooksMigration::ReimportHold.none)`)
- Test: `web-app/test/lib/services/books_migration/reimport_hold_test.rb`

**Interfaces:**
- Produces:
  - `ReimportHold.new(pairs:, redirects:, mixed_book_ids: Set.new)`; `pairs` is an Enumerable of `[user_id, book_id]` Integers.
  - `ReimportHold.load(redirects:) -> ReimportHold` (reads `Books::RepairVerdict`, per Global Constraints).
  - `ReimportHold.none -> ReimportHold` (empty).
  - `#held?(user_id, book_id) -> Boolean` (false for a nil or Symbol book id).
  - `#size -> Integer` (distinct expanded pairs).
  - `SyncScope#hold` (always set by `SyncPlan`; the test helper defaults it to `none`).

- [ ] **Step 1: Write the failing tests** (`ReimportHoldTest`, `include BooksLegacySyncHelper`):
  - "holds both books of a move": `ReimportHold.new(pairs: [[7, 10], [7, 20]], redirects: Redirects.new([]))` →
    `held?(7, 10)`, `held?(7, 20)` true; `held?(8, 10)` false; `held?(7, :deleted)` and `held?(7, nil)` false.
  - "follows a later merge": redirects `[["Books::Book", 20, 30]]` → `held?(7, 30)` true.
  - "follows a merge chain": `[["Books::Book", 20, 30], ["Books::Book", 30, 40]]` → `held?(7, 40)` true.
  - "does not follow the redirect a deleted mixed book left": pairs `[[7, 50]]`, redirects `[["Books::Book", 50, 60]]`,
    `mixed_book_ids: Set[50]` → `held?(7, 50)` true, `held?(7, 60)` false.
  - "stops at a deleted book": redirects `[["Books::Book", 20, nil]]` → `held?(7, 20)` true and nothing else added.
  - "load reads changed row, guess and mixed verdicts": create with `GoodreadsReimportApplyHelper`-style records
    (`Books::RepairVerdict.create!` with `kind:`, `subject_key:`, `decided_by: :rule`, `status:`, `payload:`):
    a `reimport_row` with `"moved" => {}` and `applied_at: nil` (held), a `reimport_row` with
    `"leftovers_removed" => []` and status `rejected` (held), a `reimport_row` keep with neither key (not held), a
    `reimport_guess` with `"moved" => {}` (held), a `reimport_mixed` with
    `{"book_id" => 50, "deleted" => [{"id" => 1, "user_id" => 9}]}` (`held?(9, 50)`), and assert `size`.
  - "none holds nothing": `ReimportHold.none.held?(1, 1)` false, `size` 0.

- [ ] **Step 2: Run** `bin/rails test test/lib/services/books_migration/reimport_hold_test.rb` — expect NameError.

- [ ] **Step 3: Implement `ReimportHold`.** Expansion at construction: for each pair add `[user, book]`; then walk
  `redirects` one step at a time from `book` while the current id is not in `mixed_book_ids` and is redirected,
  adding each target, stopping on nil (deleted). Do not use `Redirects#resolve` (it cannot stop at a mixed book); add
  `Redirects#target(item_type, id)` (`@targets[[item_type, id]]`, with `redirected?` to tell nil-deleted from absent)
  and test it in `redirects_test.rb`. Guard cycles like `resolve` does. `load` plucks only the payload fields it needs
  (`Arel.sql("payload->>'user_id'")` etc.); `mixed_book_ids` = every `reimport_mixed` verdict's `payload->>'book_id'`.
  Class comment: why it exists (spec section 1) and the mixed-redirect rule (spec 5.1).

- [ ] **Step 4: Wire it.** `SyncScope` gains `:hold`; `SyncPlan` sets it; the helper's `sync_scope` takes
  `hold: Services::BooksMigration::ReimportHold.none`. Run `bin/rails test test/lib/services/books_migration/` — all pass.

- [ ] **Step 5: Commit** — "Sync: ReimportHold, the reader/book pairs the Goodreads re-import changed".

### Task 2: List items leave held pairs alone

**Files:**
- Modify: `web-app/app/lib/services/books_migration/user_list_item_plan.rb`
- Modify: `web-app/app/lib/services/books_migration/user_list_item_migrator.rb:94-126` (`sync_lists`, stats)
- Test: `web-app/test/lib/services/books_migration/user_list_item_plan_test.rb`, `user_list_item_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `SyncScope#hold`, `ReimportHold#held?`.
- Produces: `UserListItemPlan.call(legacy_rows, here_rows, route, hold: ReimportHold.none, list_users: {}) -> Plan`;
  `Plan` gains `held_legacy` (legacy rows skipped) and `held_here` (rows here left alone), both Integers.
  `list_users` is `{user_list_id => user_id}`. Migrator result data gains `held_legacy:` and `held_here:`.

- [ ] **Step 1: Failing plan tests** (in `UserListItemPlanTest`, hold built with `ReimportHold.new(pairs:, redirects: Redirects.new([]))`, `list_users: {7 => 70}`):
  - "a legacy row on a held book is neither kept nor inserted": legacy `row(1, 7, 10, 1)`, hold `[[70, 10]]` →
    `plan.keep` empty, `inserted` 0, `held_legacy` 1.
  - "a legacy row whose routed book is held is skipped": legacy on 5, redirects `[["Books::Book", 5, 20]]`,
    hold `[[70, 20]]` → `held_legacy` 1.
  - "a row here on a held book is not stale": here `[[90, 7, "Books::Book", 30]]`, no legacy row, hold `[[70, 30]]`
    → `stale_ids` empty, `held_here` 1.
  - "holds the pair in every list of the reader": lists 7 and 8 both user 70 → both lists' items on the held book untouched.
  - "another reader's row on the same book still syncs": hold `[[70, 10]]`, list 9 of user 71, legacy row on 10 → kept.
- [ ] **Step 2: Failing migrator test** (`UserListItemMigratorSyncTest`; the setup list 600 belongs to `@user`): item
  here on `@survivor` (`add_here`), legacy row on `@book`, hold `[[@user.id, @book.id], [@user.id, @survivor.id]]`
  via `sync_scope(hold:)` → after `run_sync`, `listed` is `[@survivor.id]`, position and `completed_on` of that item
  unchanged, `result[:data][:held_here]` 1, `held_legacy` 1. Extend `run_sync` with a `hold:` keyword.
- [ ] **Step 3: Run both files** — fail.
- [ ] **Step 4: Implement.** Plan: skip held legacy rows before the collision check; skip held here rows before
  marking stale. `sync_lists` builds `list_users` with `::Books::UserList.where(id: list_ids).pluck(:id, :user_id).to_h`
  and passes `hold: sync.hold`. Add both counts to `@stats`.
- [ ] **Step 5: Run** both files and `user_list_item_migrator_test.rb` — pass.
- [ ] **Step 6: Commit** — "Sync: list items leave the re-import's reader/book pairs alone".

### Task 3: Reviews leave held pairs alone

**Files:**
- Modify: `web-app/app/lib/services/books_migration/review_migrator.rb` (`preload_context`, `build_rows`, `delete_reviews_legacy_lacks`)
- Test: `web-app/test/lib/services/books_migration/review_migrator_sync_test.rb`

**Interfaces:**
- Consumes: `SyncScope#hold`.
- Produces: review sync stats gain `held:` (legacy rows skipped plus reviews here left alone that legacy lacks).

- [ ] **Step 1: Failing tests** (extend `run_sync` with `hold:`):
  - "leaves a moved review's id on its new book": `here_review(100, book: @survivor, rating: 3.75)`; legacy
    `legacy_review(100, "book_id" => @book.id, "rating" => 3)`; hold `[[@user.id, @book.id], [@user.id, @survivor.id]]`
    → review 100 still on `@survivor` with rating 3.75; `stats[:deleted]` 0; `result[:data][:held]` 1.
  - "keeps a re-import review legacy lacks": `here_review(101, book: @survivor)` (below the reviews ceiling), legacy
    empty, hold `[[@user.id, @survivor.id]]` → still exists, not counted as deleted.
  - "an unheld review of the same reader still syncs": legacy `legacy_review(102, "book_id" => @book.id, "rating" => 5)`,
    hold only `[[@user.id, @survivor.id]]` → review 102 on `@book` with rating 5.
- [ ] **Step 2: Run** — fail.
- [ ] **Step 3: Implement.** In `build_rows` (sync only), after routing: if held for the legacy or routed book, count,
  add the id to `@held_ids`, return `[]` before `@seen`. In `preload_context`, collect ids of legacy-origin reviews
  here whose `(user_id, reviewable_id)` is held into `@held_ids`. `delete_reviews_legacy_lacks` excludes `@held_ids`.
- [ ] **Step 4: Run** `review_migrator_sync_test.rb` and `review_migrator_test.rb` — pass.
- [ ] **Step 5: Commit** — "Sync: reviews leave the re-import's reader/book pairs alone".

### Task 4: `sync_report` counts what the run does

**Files:**
- Modify: `web-app/app/lib/services/books_migration/user_data_diff.rb` (`initialize`, `user_list_items`, `reviews`)
- Modify: `web-app/app/lib/services/books_migration/sync_report.rb` (`user_data_lines`)
- Test: `web-app/test/lib/services/books_migration/user_data_diff_test.rb`, `sync_report_test.rb`

**Interfaces:**
- Consumes: `SyncScope#hold`, the Task 2 plan signature.
- Produces: `user_list_items` counts gain `held_legacy`, `held_here`; `reviews` counts gain `held`. Report notes:
  user_list_items "… N held for the Goodreads re-import"; reviews likewise.

- [ ] **Step 1: Failing tests.** With the same rows and hold as Task 2's migrator test and Task 3's first two tests,
  `UserDataDiff.call(scope: sync_scope(hold:), legacy: FakeLegacySource.new(...))` reports `inserted` 0, `deleted` 0,
  `updated` 0 for those rows and the held counts equal the migrators' `result[:data]` held counts on the same data
  (run both in one test). `SyncReport.render(plan, user_data:)` includes "held for the Goodreads re-import".
- [ ] **Step 2: Run** — fail.
- [ ] **Step 3: Implement.** Pass `hold: scope.hold` and `list_users` into `UserListItemPlan` (the digest shortcut is
  unchanged: lists with held items differ and go through the plan). In `reviews`, skip held legacy rows (count them,
  keep their ids out of insert/update), and drop held here-ids from `deleted`.
- [ ] **Step 4: Run** both files and `sync_test.rb` — pass.
- [ ] **Step 5: Commit** — "sync_report counts the re-import hold the way the sync applies it".

### Task 5: Identifiers only on books new in the sync

**Files:**
- Modify: `web-app/app/lib/services/books_migration/book_identifier_migrator.rb:53-68` (`in_sync_scope?`, `legacy_each`, comment)
- Modify: `web-app/app/lib/services/books_migration/legacy_source.rb` (add `book_identifier_book_ids(ids)`)
- Modify: `web-app/app/lib/services/books_migration/sync_plan.rb` (`build_report` `book_identifiers`)
- Modify: `web-app/app/lib/services/books_migration/sync_report.rb:26` (the identifiers line)
- Modify: `web-app/test/support/books_legacy_sync_helper.rb` (`FakeLegacySource` `book_identifier_books: {}` and the method)
- Test: `book_identifier_migrator_test.rb`, `sync_plan_test.rb`, `sync_report_test.rb`

**Interfaces:**
- Produces: `LegacySource#book_identifier_book_ids(ids) -> {identifier_id => book_id}`; report
  `book_identifiers: {would_insert:, skipped_existing_book:, waiting:}`.

- [ ] **Step 1: Failing tests:**
  - "skips a new identifier on a book we already have": `sync_scope(identifier_ids: [5], book_ids: [])`, legacy row
    id 5 on an existing book → no `Identifier` created.
  - "copies identifiers of a book new in this sync": `sync_scope(identifier_ids: [6], book_ids: [book.id])` → created.
  - Plan report: two window rows, one on a new book → `would_insert` 1, `skipped_existing_book` 1.
  - Report line reads "book_identifiers (on new books only)" and prints the skipped count.
- [ ] **Step 2: Run** — fail.
- [ ] **Step 3: Implement.** `in_sync_scope?` → `sync.book_ids.include?(attrs["book_id"])`; `legacy_each` queries
  `where(book_id: sync.book_ids.to_a)`. Rewrite the method comment to say why (spec 5.6, Shane's 2026-11-26 ruling).
  `SyncPlan` asks `@legacy.book_identifier_book_ids(identifiers.ids)` once.
- [ ] **Step 4: Run** the three files and `sync_test.rb` — pass.
- [ ] **Step 5: Commit** — "Sync: legacy identifiers only for books new in the sync".

### Task 6: Proof — apply the re-import, then sync

**Files:**
- Test: `web-app/test/lib/services/books_migration/sync_keeps_reimport_test.rb`

**Interfaces:**
- Consumes: `GoodreadsReimportApplyHelper` (`setup_reader`, `csv_row`, `row_verdict`, `guess_verdict`),
  `Services::Books::GoodreadsReimport::Apply::Row.call(verdict:)`, `ReimportHold.load`, `UserListItemMigrator`,
  `ReviewMigrator`, `UserDataDiff`.

- [ ] **Step 1: Write the test.** A reader with a legacy-origin list (`Books::UserList.create!(id: 600, user: @user, ...)`)
  holding `@from`, and a legacy-origin review on `@from` (id below the reviews ceiling). Apply real verdicts with
  `Apply::Row.call`: a `move` (`@from` → `@to`, `review: true`), and on a second book pair an `add` and a `copy`. Then
  build `sync_scope(hold: ReimportHold.load(redirects: Redirects.new([])))` and run the list-item and review sync
  steps with legacy rows that still show the pre-apply state, plus, for the same reader, one unrelated legacy shelf
  move (a third book from list 600 to a second legacy-origin list) and one new legacy review on a fourth book.
  Assert: every id in each verdict's `payload["moved"]["list_item_ids_after"]` and `review_id_after` still exists on
  `to_book_id`; nothing is back on `@from`; the unrelated shelf move and new review came over; `UserDataDiff` on the
  same state then reports 0 inserted/deleted/updated for items and reviews.
- [ ] **Step 2: Run** — it must pass with Tasks 1-5 in place. Revert Task 2's plan change locally to watch it fail,
  then restore.
- [ ] **Step 3: Run the whole suite** `bin/rails test` and `bundle exec standardrb` — clean, no new warnings.
- [ ] **Step 4: Commit** — "Test: the sync keeps an applied Goodreads re-import".

### Task 7: A snapshot per re-import pass

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_reimport/report.rb` (`snapshot`, `snapshot_path`, `dropped_users`)
- Modify: `web-app/lib/tasks/books/goodreads_reimport.rake:76-84`
- Modify: `web-app/app/sidekiq/books/goodreads_reimport/snapshot_job.rb` (`perform(replace = false, new_pass = false)`)
- Test: `web-app/test/lib/services/books/goodreads_reimport/report_test.rb`, the rake/job test if one exists

**Interfaces:**
- Produces: `Report.snapshot(replace: false, new_pass: false)`; with `new_pass: true` it writes
  `storage_dir.join("counts-<UTC %Y%m%dT%H%M%SZ>.json")` and never touches an existing file.
  `Report.snapshot_path` returns the newest of `counts.json` and `counts-*.json` by its `taken_at`.
  Task: `books:goodreads_reimport:snapshot[new_pass]` (and `[redo]` as today).

- [ ] **Step 1: Failing tests:** `snapshot(new_pass: true)` with an existing `counts.json` writes a second file and
  leaves the first byte-identical; `dropped_users` compares against the newer file; a plain `snapshot` still refuses
  when any snapshot exists. Use a temp `storage_dir` (stub it as the existing tests do).
- [ ] **Step 2: Run** — fail. **Step 3: Implement.** **Step 4: Run** — pass.
- [ ] **Step 5: Commit** — "Re-import: a snapshot per pass, so a later pass has its own loss check".

### Task 8: Old site — pause Goodreads import

**Repo:** `/home/shane/dev/the-greatest-books` (merging its `main` deploys). Do **not** touch its current checkout
(branch `front-page-new-site-banner`, uncommitted `.gitignore`). (This repo's no-`git worktree add` rule is about `the-greatest`, not the old site.) Create a second checkout for branch
`goodreads-import-paused` from `origin/main` with `git -C /home/shane/dev/the-greatest-books worktree add
../the-greatest-books-goodreads-paused -b goodreads-import-paused origin/main`, and work there. No tests (Shane's rule).

**Files (in `admin/`):**
- Modify: `app/controllers/goodreads_imports_controller.rb` (`upload`)
- Modify: `app/components/goodreads_import_component.html.erb`
- Modify: `app/views/recommendations/step_2.html.erb` (the Goodreads card)

- [ ] **Step 1:** `upload` no longer saves: HTML redirects back with `alert:` the message; JSON returns
  `{error: message}` with status 503. Message, exactly: "Goodreads import is paused while we move to our new site,
  which launches soon with a new and improved Goodreads import."
- [ ] **Step 2:** The component keeps the latest-import status block, and shows the message (Bootstrap `alert
  alert-info`) in place of the "Import from Goodreads" button, the how-to list and the modal.
- [ ] **Step 3:** The recommendations card shows the message instead of the link.
- [ ] **Step 4:** Boot check: `cd admin && bin/rails runner 'puts GoodreadsImportsController.instance_method(:upload).source_location'`
  and render the component in `bin/rails runner` with `ApplicationController.render(GoodreadsImportComponent.new(latest_goodreads_import: nil), layout: false)`; both run without error.
- [ ] **Step 5: Commit** on `goodreads-import-paused`. Do not push; Shane pushes and merges it, before the first fixed sync.

### Task 9: Docs, then the dev rehearsal

**Files:**
- Modify: `docs/features/books-legacy-sync.md` (a section on the re-import hold and the identifier rule)
- Modify: `docs/features/goodreads-reimport.md` ("The weekly legacy sync" section: replace "do not run" with how the hold works; the snapshot per pass; the loss check is for right after an apply)
- Modify: `docs/launch-todo.md` — the rewrite, spec section 6

- [ ] **Step 1: Feature docs.** Describe the hold (spec 5.1-5.2), the identifier rule (5.6) and the per-pass
  snapshot, with the reasons. Code is the source of truth; no per-class doc files.
- [ ] **Step 2: Launch todo rewrite** to spec section 6's structure. Inputs, all to be re-checked, never copied blind:
  the 2026-11-26 command audit (fix: §1/§2 tasks refuse after `sync_init`; §11's "replay stays paused" vs the weekly
  `goodreads_replay:apply`; §5 step 5's full replay pass is retired; §12 "stage two of section 11" → section 11 step 5;
  §9 step 8's deadline is 25 s, not 5 s; remove §12 step 1's "lower it to 10" line (Shane keeps
  `SIDEKIQ_CONCURRENCY` high until cutover; add no step for it); §18's `reparse` needs a `parser_version` bump; §15 step 13 skips books with
  any failed source). Every status (DONE date / PARTIAL / NOT RUN) comes from a read-only production check run by
  read-only check of production (Shane allowed read-only access on 2026-11-26:
  `ssh deploy@45.33.28.21 'docker exec -i the-greatest-worker bin/rails runner -' < script.rb`, counts and config
  reads only; never a rake task that writes). Add the new entries spec section 6 lists. The weekly cycle is: `sync_report`,
  `sync`, `sync_report` (held counts printed, 0 changes), `merge_unknown`, `goodreads_replay:load`, a re-import pass
  when there are new legacy imports (with `snapshot[new_pass]` before its apply), rankings.
- [ ] **Step 3: Commit** — "Docs: the sync's re-import hold; launch todo rewritten and re-checked".
- [ ] **Step 4: Dev rehearsal — only after Shane says go** (it replaces the dev database:
  `bin/snapshot-dev-db.sh --label pre-sync-hold` first, then `bin/refresh-dev-db.sh --legacy`, from the repo root).
  Then in `web-app/`: `bin/rails data_migration:sync_report`, `bin/rails data_migration:sync`,
  `bin/rails data_migration:sync_report`. Pass: the second report shows 0 inserts/updates/deletes and the held counts;
  a runner script finds every `list_item_ids_after` / `review_id_after` id of every changed re-import verdict still on
  its `to_book_id` (merge-resolved), except items of lists deleted on legacy. Record the numbers in the PR body.
