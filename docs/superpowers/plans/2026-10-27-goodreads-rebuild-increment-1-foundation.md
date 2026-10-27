# Goodreads Rebuild Increment 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record which post-import books are import-made (derived) and which came in with a list (trusted), and retire the replay's still-proposed relinks and identifier strips so the rebuild can record its own decisions on the same subjects.

**Architecture:** A new table `books_rebuild_books` holds one row per post-import legacy book with its cohort, filled by a repeatable service that reads the legacy database. `books_repair_verdicts` gains `superseded_at`. A retire service marks the old proposals rejected and superseded. `RecordVerdict` replaces a superseded row only when the caller opts in, which the rebuild will and the replay won't. Two rake tasks, both repeatable; the retire task has a dry run.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md` (§3 trust model, §6 "Retire the old replay proposals first", §12 call 1). This plan is increment 1 of 5:

1. foundation (this plan);
2. stage one;
3. verification scope;
4. stage two and the member-import guards;
5. sweep and weekly catch-up.

## Global Constraints

- Services live in `app/lib/services/books/goodreads_rebuild/` (module `Services::Books::GoodreadsRebuild`) and return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Use generators: `bin/rails generate model books/rebuild_book ...` and `bin/rails generate migration ...`. `bin/rails db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Delete annotation lines for columns this branch's `schema.rb` lacks (the dev DB is shared).
- Rails 8 enum syntax: `enum :cohort, {list_created: 0, import_created: 1}`.
- Post-import ids: `Services::Books::Verification::Cohort.post_import_range` (16,572 up to the reserved ceiling). Reuse it; don't copy the number.
- The list window is **1 day**: a book is `list_created` when its first legacy `list_items.created_at` is at or before its legacy `books.created_at + 1 day`. This matches the production script that picked the 7,792 books.
- The legacy DB is never queried in tests (`LegacyBooks::Record` skips `connects_to` in test). Put the legacy read behind one private method and stub it with Mocha, as `test/lib/services/books_migration/list_migrator_test.rb:12` does.
- Retire only `proposed` verdicts of kinds `relink` and `strip_identifier`. Approved, applied and rejected rows are untouched.
- The replay's own `RecordVerdict` calls keep treating every rejected row, superseded or not, as suppressed. Only callers passing `replace_superseded: true` may replace a superseded row.
- Never run a destructive command against development. The rake tasks' apply modes are Shane's to run in production.
- Lint with `bundle exec standardrb`; the full `bin/rails test` must pass.

## Review Focus

1. **A replay re-run after the retire step.** Someone runs `books:goodreads_replay:resolve` again. Its `RecordVerdict` calls (no `replace_superseded`) must leave superseded rows rejected, not resurrect them as proposals. Test in Task 3.
2. **A second cohort run after new legacy books arrive.** Only new books get rows, and existing rows aren't rewritten even if legacy data changed. Test in Task 2.
3. **A post-import book missing from legacy** (created in the new app inside the id range, or deleted on legacy). It's counted `not_in_legacy` and gets no row, and the run doesn't crash. Test in Task 2.
4. **The admin bulk "approve all matching".** It must never approve a superseded row. They're `rejected`, and `bulk_approve` already filters `proposed`, but the index must hide them too. Test in Task 3.
5. **A merge deleting a book that has a cohort row.** The FK cascade removes the row, and the merge doesn't fail. Test in Task 1.

---

### Task 1: `Books::RebuildBook` model and table

**Files:**
- Create (generator): `web-app/db/migrate/<ts>_create_books_rebuild_books.rb`, `web-app/app/models/books/rebuild_book.rb`, `web-app/test/models/books/rebuild_book_test.rb`, `web-app/test/fixtures/books/rebuild_books.yml`
- Modify: `web-app/db/schema.rb` (by migrate)

**Interfaces:**
- Produces: `Books::RebuildBook` (table `books_rebuild_books`), with:
  - `book_id` (bigint, not null, unique index, FK to `books_books` `on_delete: :cascade`);
  - `cohort` (integer, not null; enum `list_created: 0, import_created: 1`);
  - `legacy_created_at` (datetime, not null);
  - `first_list_item_at` (datetime, nullable).
  - `belongs_to :book, class_name: "Books::Book"`.
  - Scope `derived` = `import_created`.
  - Class method `Books::RebuildBook.trusted?(book_id) -> Boolean`: true when `Services::Books::Verification::Cohort.for(book_id) == :pre_import`, or a `list_created` row exists for the book. False for `import_created`, **and false for a post-import book with no row** (unknown counts as untrusted).

- [ ] **Step 1: Generate the model.** Run from `web-app/`: `bin/rails generate model books/rebuild_book book:references cohort:integer legacy_created_at:datetime first_list_item_at:datetime`. Edit the migration:
  - `null: false` on `cohort` and `legacy_created_at`;
  - `foreign_key: {to_table: :books_books, on_delete: :cascade}`;
  - a unique index on `book_id`, replacing the non-unique one `references` adds.

  Fixture file: two rows, `derived_book` (cohort `import_created`) and `list_book` (cohort `list_created`), on existing `books_books` fixtures. Check `test/fixtures/books/books.yml` for real labels.
- [ ] **Step 2: Write the failing tests** in `test/models/books/rebuild_book_test.rb`:

```ruby
test "derived scope is the import-created rows" do
  assert_equal [books_rebuild_books(:derived_book)], Books::RebuildBook.derived.to_a
end

test "trusted? is true below the first post-import id" do
  assert Books::RebuildBook.trusted?(Services::Books::Verification::Cohort::FIRST_POST_IMPORT_ID - 1)
end

test "trusted? follows the cohort row for a post-import book" do
  list = Books::Book.create!(id: 20_001, title: "List Book")
  derived = Books::Book.create!(id: 20_002, title: "Derived Book")
  Books::RebuildBook.create!(book: list, cohort: :list_created, legacy_created_at: 1.year.ago)
  Books::RebuildBook.create!(book: derived, cohort: :import_created, legacy_created_at: 1.year.ago)
  assert Books::RebuildBook.trusted?(20_001)
  refute Books::RebuildBook.trusted?(20_002)
  refute Books::RebuildBook.trusted?(20_003) # post-import, no row
end

test "a book_id appears once" do
  dup = Books::RebuildBook.new(book: books_rebuild_books(:derived_book).book, cohort: :list_created, legacy_created_at: Time.current)
  assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
end

test "destroying the book removes its row" do
  row = books_rebuild_books(:derived_book)
  row.book.delete
  refute Books::RebuildBook.exists?(row.id)
end
```

  If the fixture books' ids fall inside the post-import range, the `trusted?` fixture test still holds, because it uses explicit ids.
- [ ] **Step 3: Run them to see them fail.** `bin/rails test test/models/books/rebuild_book_test.rb`. Expected: FAIL (`trusted?` undefined, or no table before the migrate).
- [ ] **Step 4: Migrate and implement.** Run `bin/rails db:migrate`; annotaterb runs. Implement the enum, `belongs_to`, `validates :cohort, :legacy_created_at, presence: true`, the scope and `trusted?` in `app/models/books/rebuild_book.rb`. Add a class comment saying why the table exists (spec §3, §12 call 1).
- [ ] **Step 5: Run the tests.** `bin/rails test test/models/books/rebuild_book_test.rb`. Expected: PASS.
- [ ] **Step 6: Commit.** `git add` the migration, `schema.rb`, model, test and fixture, then `git commit -m "Goodreads rebuild: books_rebuild_books records each post-import book's cohort"`.

### Task 2: `RecordCohorts` service and `books:goodreads_rebuild:cohorts`

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/record_cohorts.rb`, `web-app/lib/tasks/books/goodreads_rebuild.rake`
- Test: `web-app/test/lib/services/books/goodreads_rebuild/record_cohorts_test.rb`, `web-app/test/lib/tasks/books_goodreads_rebuild_rake_test.rb`

**Interfaces:**
- Consumes: `Books::RebuildBook` (Task 1).
- Produces:
  - `Services::Books::GoodreadsRebuild::RecordCohorts.call -> Result`. `data` is `{tally: {"list_created" => Integer, "import_created" => Integer, "not_in_legacy" => Integer}}`, with every key present.
  - `RecordCohorts::LIST_WINDOW = 1.day`.
  - Private `legacy_origins(book_ids) -> Hash{Integer => [Time created_at, Time|nil first_list_item_at]}`. This is the only legacy read, and tests stub it.

- [ ] **Step 1: Write the failing service tests.** Each test creates `Books::Book` rows with explicit ids in `20_000..20_010`, and stubs `RecordCohorts.any_instance.stubs(:legacy_origins).returns({...})`:
  - `test "a book first listed within a day of creation is list_created"`: created `t`, first item `t + 23.hours` → row `list_created`, `legacy_created_at == t`, `first_list_item_at == t + 23.hours`; tally `list_created` 1.
  - `test "a book first listed more than a day later is import_created"`: `t + 25.hours` → `import_created`.
  - `test "a book never listed is import_created"`: first item `nil` → `import_created`.
  - `test "a book missing from legacy gets no row and is counted"`: stub omits the id → no row, tally `not_in_legacy` 1, `success?` true.
  - `test "pre-import books are ignored"`: a book with id `FIRST_POST_IMPORT_ID - 1` → no row, and `legacy_origins` is never asked for it. Use `expects(:legacy_origins).with { |ids| !ids.include?(...) }`, or capture the arguments.
  - `test "a second run only records new books"`: an existing `import_created` row for id 20_001 stays unchanged when the stub now says list-created; a new id 20_005 gets its row; the tally counts only 20_005.
- [ ] **Step 2: Run them to see them fail.** `bin/rails test test/lib/services/books/goodreads_rebuild/record_cohorts_test.rb`. Expected: FAIL, uninitialized constant.
- [ ] **Step 3: Implement `RecordCohorts`.**
  - Select `Books::Book` ids in `Cohort.post_import_range` with no `Books::RebuildBook` row, in slices of 1,000.
  - Call `legacy_origins(slice)`, decide each cohort with `LIST_WINDOW`, and `Books::RebuildBook.insert_all` the rows. Use `unique_by: :book_id`, so a concurrent run can't fail.
  - `legacy_origins` runs one SQL on `LegacyBooks::Record.connection`: `select b.id, b.created_at, min(li.created_at) from books b left join list_items li on li.book_id = b.id where b.id in (...) group by b.id, b.created_at`.
  - Class comment: why "derived" means import-created (spec §12 call 1).
- [ ] **Step 4: Run them to see them pass.** Same command. Expected: PASS.
- [ ] **Step 5: Write the failing rake test** in `test/lib/tasks/books_goodreads_rebuild_rake_test.rb`, following `test/lib/tasks/books_goodreads_replay_rake_test.rb`'s loading and output capture:
  - `test "cohorts prints the tally"`: stub `RecordCohorts.call` to return the tally `{"list_created" => 2, "import_created" => 3, "not_in_legacy" => 0}`; assert the output includes `list_created 2` and `import_created 3`.
- [ ] **Step 6: Implement the rake task.** In `lib/tasks/books/goodreads_rebuild.rake`, add `namespace :books { namespace :goodreads_rebuild { task cohorts: :environment } }`. Give it a `desc` saying it's repeatable, records only books without a row, and reads the legacy DB. It prints `post-import books: <tally>`, using the same `tally` lambda shape as `goodreads_replay.rake`. Run the rake test. Expected: PASS.
- [ ] **Step 7: Commit.** `git commit -m "Goodreads rebuild: RecordCohorts and books:goodreads_rebuild:cohorts"`.

### Task 3: Retire the replay's proposals

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

### Task 4: Docs and launch steps

**Files:**
- Create: `docs/features/goodreads-rebuild.md`
- Modify: `docs/launch-todo.md` (add a new last section, `## 11. Goodreads rebuild (repeats until cutover)`), `docs/features/goodreads-import.md` (one line under the replay section pointing to the rebuild doc and saying the replay is paused)

- [ ] **Step 1: Write `docs/features/goodreads-rebuild.md`.**
  - What the rebuild is (one paragraph, link the spec).
  - Cohorts: pre-import by id, `list_created` and `import_created` by the 1-day list rule, and that a post-import book with no row counts as untrusted.
  - The retire step and why `replace_superseded` exists.
  - Both commands, with what a second run prints.
  - "Later increments" lists stage one, verification scope, stage two, and the sweep and catch-up.
- [ ] **Step 2: Add the launch-todo section.** Use exact commands, with the why for each in a plain sentence (Shane reads these):
  1. `bin/rails books:goodreads_rebuild:cohorts` (repeat after every weekly sync; prints counts; a second run with no new books prints 0s);
  2. `bin/rails books:goodreads_rebuild:retire_replay_proposals` (dry run: expect about 2,691 relinks and 2,091 strips), then `bin/rails "books:goodreads_rebuild:retire_replay_proposals[apply]"` once;
  3. a placeholder line, "Stage one: added by increment 2".
- [ ] **Step 3: Verify.** Run `bin/rails test` and `bundle exec standardrb` from `web-app/`. Expected: 0 failures, 0 offenses, no new warning lines.
- [ ] **Step 4: Commit.** `git commit -m "Docs: Goodreads rebuild foundation and launch steps"`.
