# Goodreads Rebuild Increment 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tell trusted books from import-made (derived) ones, and retire the replay's still-proposed relinks and identifier strips so the rebuild can record its own decisions on the same subjects.

**Architecture:**
- `Services::Books::GoodreadsRebuild::Cohort` computes trust live from `list_items`. A post-import book on any list except the generated user-favorites list is trusted. Nothing is stored and nothing is read from the legacy database.
- `books_repair_verdicts` gains `superseded_at`. A retire service marks the old proposals rejected and superseded.
- `RecordVerdict` replaces a superseded row only when the caller opts in, which the rebuild will and the replay won't.
- Two rake tasks: a cohort report, and the retire step with a dry run.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md` (§3 trust model, §6 "Retire the old replay proposals first", §12 call 1). This plan is increment 1 of 5:

1. foundation (this plan);
2. stage one;
3. verification scope;
4. stage two and the member-import guards;
5. sweep and weekly catch-up.

## Global Constraints

- Services live in `app/lib/services/books/goodreads_rebuild/` (module `Services::Books::GoodreadsRebuild`) and return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Migrations come from `bin/rails generate migration ...`. `bin/rails db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Delete annotation lines for columns this branch's `schema.rb` lacks (the dev DB is shared).
- Post-import ids: `Services::Books::Verification::Cohort.post_import_range` (16,572 up to the reserved ceiling). Reuse it; don't copy the number. Ids below it are pre-import, and ids at or above the ceiling are new-app books. Both are trusted.
- The trust rule (Shane, 2026-10-27): a post-import book is trusted when a `ListItem` (`listable_type: "Books::Book"`) holds it on any list whose `auto_generated_kind` isn't `user_favorites`. Otherwise it is derived. Dev measurement: 9,379 trusted, 138,246 derived (2 of them only on the favorites list).
- Retire only `proposed` verdicts of kinds `relink` and `strip_identifier`. Approved, applied and rejected rows are untouched.
- The replay's own `RecordVerdict` calls keep treating every rejected row, superseded or not, as suppressed. Only callers passing `replace_superseded: true` may replace a superseded row.
- Never run a destructive command against development. The retire task's apply mode is Shane's to run in production.
- Lint with `bundle exec standardrb`; the full `bin/rails test` must pass.

## Review Focus

1. **A replay re-run after the retire step.** Someone runs `books:goodreads_replay:resolve` again. Its `RecordVerdict` calls (no `replace_superseded`) must leave superseded rows rejected, not resurrect them as proposals. Test in Task 2.
2. **A book only on the user-favorites list.** It is derived, not trusted. Test in Task 1.
3. **A book on the favorites list and on a real list.** It is trusted. Test in Task 1.
4. **The admin bulk "approve all matching".** It must never approve a superseded row. They're `rejected`, and `bulk_approve` already filters `proposed`, but the index must hide them too. Test in Task 2.
5. **`derived` as a relation over ~138k ids.** It must be one SQL query (`NOT EXISTS` or `NOT IN` subquery), never Ruby sets, because stage one batches over it with `find_each`. Test in Task 1 by asserting it's an `ActiveRecord::Relation` and runs one query.

---

### Task 1: `Cohort` and `books:goodreads_rebuild:cohorts`

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/cohort.rb`, `web-app/lib/tasks/books/goodreads_rebuild.rake`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/cohort_test.rb`, `web-app/test/lib/tasks/books_goodreads_rebuild_rake_test.rb`

**Interfaces:**
- Produces, in module `Services::Books::GoodreadsRebuild::Cohort` (module_function, like `Services::Books::Verification::Cohort`):
  - `trusted?(book_id) -> Boolean`
  - `derived -> ActiveRecord::Relation<Books::Book>`: post-import books with no qualifying list item.
  - `trusted_post_import -> ActiveRecord::Relation<Books::Book>`
  - `counts -> Hash{"trusted" => Integer, "derived" => Integer, "only_on_user_favorites" => Integer}`, over post-import books.

- [ ] **Step 1: Write the failing tests** in `cohort_test.rb`. Create books with explicit ids in `20_000..20_010` (`Books::Book.create!(id:, title:)`), a real list, and the favorites list. Check `test/fixtures/lists.yml` for an existing `Books::List` fixture and a `user_favorites` one; create them if absent.
  - `test "a pre-import book is trusted"`: `trusted?(Services::Books::Verification::Cohort::FIRST_POST_IMPORT_ID - 1)` is true.
  - `test "a post-import book on a real list is trusted"`
  - `test "a post-import book on no list is derived"`: `trusted?` false, and `derived` includes it.
  - `test "a post-import book only on the user favorites list is derived"`
  - `test "a post-import book on the favorites list and a real list is trusted"`
  - `test "derived is one query"`: `assert_kind_of ActiveRecord::Relation, Cohort.derived`, and `assert_queries_count(1) { Cohort.derived.ids }`.
  - `test "counts tallies post-import books"`: with one of each case above, the counts are `{"trusted" => 2, "derived" => 2, "only_on_user_favorites" => 1}`.
- [ ] **Step 2: Run them to see them fail.** `bin/rails test test/lib/services/books/goodreads_rebuild/cohort_test.rb`. Expected: FAIL, uninitialized constant.
- [ ] **Step 3: Implement `Cohort`.** `derived` is `Books::Book.where(id: post_import_range).where.not(id: qualifying_items.select(:listable_id))`. `qualifying_items` is `ListItem.joins(:list).where(listable_type: "Books::Book").where("lists.auto_generated_kind IS DISTINCT FROM ?", List.auto_generated_kinds[:user_favorites])`. Use `IS DISTINCT FROM` because `auto_generated_kind` is NULL for every hand-made list. Module comment: Shane's rule and why (spec §12 call 1).
- [ ] **Step 4: Run them to see them pass.** Same command. Expected: PASS.
- [ ] **Step 5: Write the failing rake test** in `test/lib/tasks/books_goodreads_rebuild_rake_test.rb`, following `test/lib/tasks/books_goodreads_replay_rake_test.rb`'s loading and output capture:
  - `test "cohorts prints the counts"`: stub `Cohort.counts` to return `{"trusted" => 2, "derived" => 3, "only_on_user_favorites" => 1}`; assert the output includes `trusted 2` and `derived 3`.
- [ ] **Step 6: Implement the rake task.** In `lib/tasks/books/goodreads_rebuild.rake`, add `namespace :books { namespace :goodreads_rebuild { task cohorts: :environment } }`, with a `desc` saying it's read-only. It prints `post-import books: <counts>`, using the same `tally` lambda shape as `goodreads_replay.rake`. Run the rake test. Expected: PASS.
- [ ] **Step 7: Commit** with the message "Goodreads rebuild: Cohort tells trusted books (on a real list) from import-made ones".

### Task 2: Retire the replay's proposals

**Files:**
- Create (generator): `web-app/db/migrate/<ts>_add_superseded_at_to_books_repair_verdicts.rb`, `web-app/app/lib/services/books/goodreads_rebuild/retire_replay_proposals.rb`
- Modify: `web-app/app/models/books/repair_verdict.rb`, `web-app/app/lib/services/books/goodreads_replay/record_verdict.rb`, `web-app/app/controllers/admin/books/repair_verdicts_controller.rb` (`filtered_scope`), `web-app/lib/tasks/books/goodreads_rebuild.rake`
- Test: `web-app/test/models/books/repair_verdict_test.rb`, `web-app/test/lib/services/books/goodreads_replay/record_verdict_test.rb`, `web-app/test/lib/services/books/goodreads_rebuild/retire_replay_proposals_test.rb`, `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`, `web-app/test/lib/tasks/books_goodreads_rebuild_rake_test.rb`

**Interfaces:**
- Produces:
  - Column `books_repair_verdicts.superseded_at` (datetime, nullable), plus scopes `RepairVerdict.current` (`superseded_at: nil`) and `RepairVerdict.superseded`.
  - `Services::Books::GoodreadsRebuild::RetireReplayProposals.call(apply: false) -> Result`, with `data` = `{counts: {"relink" => Integer, "strip_identifier" => Integer}, applied: Boolean}`.
  - `RetireReplayProposals::KINDS = %w[relink strip_identifier]`.
  - `RecordVerdict.call(..., replace_superseded: false)`, a new keyword. When true and the row is superseded, the row takes the new attributes and clears `superseded_at`, `reviewed_at`, `decided_by_user_id`, `applied_at` and `error`. The outcome is `:replaced`.

- [ ] **Step 1: Generate the migration.** Run `bin/rails generate migration AddSupersededAtToBooksRepairVerdicts superseded_at:datetime`, then `bin/rails db:migrate` (annotaterb runs). Add the two scopes to `RepairVerdict`.
- [ ] **Step 2: Write the failing tests.**
  - `retire_replay_proposals_test.rb`, using `Books::RepairVerdict.create!` rows:
    - `test "dry run counts proposed relinks and strips and changes nothing"`: 2 proposed relinks, 1 proposed strip, 1 approved relink, 1 proposed `merge_books` → counts `{"relink" => 2, "strip_identifier" => 1}`, `applied` false, every row unchanged.
    - `test "apply rejects and supersedes exactly those"`: same rows, `apply: true` → the 3 are `rejected` with `superseded_at` set; the approved relink and the `merge_books` row are unchanged.
    - `test "a second apply finds nothing"`: counts are all 0.
  - `record_verdict_test.rb`:
    - `test "a superseded verdict stays suppressed for the replay"`: a superseded, rejected relink; `RecordVerdict.call` without the flag → outcome `:suppressed`, still rejected.
    - `test "the rebuild replaces a superseded verdict"`: same row, `replace_superseded: true, auto: false` → outcome `:replaced`, status `proposed`, `superseded_at` nil, `reviewed_at` nil, new payload stored.
    - `test "replace_superseded leaves an admin-rejected verdict suppressed"`: rejected with no `superseded_at` → `:suppressed`.
  - Controller test: `test "index hides superseded verdicts"`: the superseded row's summary is absent, a current one is listed. Assert on the rendered verdict ids or links, following the existing tests in that file. Also `test "bulk approve all matching never approves a superseded verdict"`.
  - Rake test: `test "retire_replay_proposals is a dry run without apply"`. Stub the service and assert it was called with `apply: false`, and that the output says nothing changed and how to apply. `test "retire_replay_proposals[apply]"` asserts `apply: true`.
- [ ] **Step 3: Run them to see them fail.** `bin/rails test test/lib/services/books/goodreads_rebuild test/lib/services/books/goodreads_replay/record_verdict_test.rb test/lib/tasks/books_goodreads_rebuild_rake_test.rb test/controllers/admin/books/repair_verdicts_controller_test.rb`. Expected: FAIL.
- [ ] **Step 4: Implement.**
  - `RetireReplayProposals`: count `RepairVerdict.proposed.current.where(kind: KINDS).group(:kind)`; on apply, one `update_all(status: rejected, superseded_at: now, updated_at: now)` over that scope.
  - `RecordVerdict`: the `replace_superseded` branch goes before the existing `rejected?` check, and only applies when `superseded_at` is present.
  - `filtered_scope` starts from `::Books::RepairVerdict.current`.
  - Rake task: `task :retire_replay_proposals, [:apply] => :environment`. It prints counts per kind and `dry run: nothing changed; run books:goodreads_rebuild:retire_replay_proposals[apply]`, or `retired`.
- [ ] **Step 5: Run them to see them pass.** Same command. Expected: PASS.
- [ ] **Step 6: Commit.** `git commit -m "Goodreads rebuild: retire the replay's proposed relinks and strips; RecordVerdict replaces a superseded row only for the rebuild"`.

### Task 3: Docs and launch steps

**Files:**
- Create: `docs/features/goodreads-rebuild.md`
- Modify: `docs/launch-todo.md` (add a new last section, `## 11. Goodreads rebuild (repeats until cutover)`), `docs/features/goodreads-import.md` (one line under the replay section pointing to the rebuild doc and saying the replay is paused)

- [ ] **Step 1: Write `docs/features/goodreads-rebuild.md`.**
  - What the rebuild is (one paragraph, link the spec).
  - Cohorts: pre-import and new-app books are trusted by id. A post-import book is trusted when it is on any list except the generated user-favorites list (Shane's rule), and derived otherwise. The rule is computed live, so a book added to a real list becomes trusted with no step to run.
  - The retire step and why `replace_superseded` exists.
  - Both commands, with what a second run prints.
  - "Later increments" lists stage one, verification scope, stage two, and the sweep and catch-up.
- [ ] **Step 2: Add the launch-todo section.** Use exact commands, with the why for each in a plain sentence (Shane reads these):
  1. `bin/rails books:goodreads_rebuild:cohorts` (read-only; prints how many post-import books are trusted and how many are derived);
  2. `bin/rails books:goodreads_rebuild:retire_replay_proposals` (dry run: expect about 2,691 relinks and 2,091 strips), then `bin/rails "books:goodreads_rebuild:retire_replay_proposals[apply]"` once;
  3. a placeholder line, "Stage one: added by increment 2".
- [ ] **Step 3: Verify.** Run `bin/rails test` and `bundle exec standardrb` from `web-app/`. Expected: 0 failures, 0 offenses, no new warning lines.
- [ ] **Step 4: Commit.** `git commit -m "Docs: Goodreads rebuild foundation and launch steps"`.
