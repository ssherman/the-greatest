# Alternate Titles Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every book's alternate titles a table row with a source and a status, have AI review them and remove
the ones that are another work, and undo the verification pass's trusted identifier writes that agreed only
through a removed title.

**Architecture:** A `books_alternate_titles` table becomes the master. `books_books.alternate_titles` stays as a copy
of the `kept` and `review` rows, which every writer service assigns before the book is saved, so every reader keeps
working unchanged. One service module (`Services::Books::AlternateTitles`) owns every write. An AI task judges each
book's titles in numbered chunks through a Sidekiq job. A one-shot service re-judges verification findings with the
verification pass's own title rule, run twice: once with the removed titles and once without.

**Tech Stack:** Rails 8, Postgres, Minitest 6 + fixtures + Mocha, Sidekiq, OpenAI via `Services::Ai::Tasks::BaseTask`,
ViewComponents/ERB + DaisyUI 5, Stimulus (`shared--form-token`), Playwright.

**Spec:** `docs/superpowers/specs/2026-10-23-alternate-titles-cleanup-design.md` (Parts 1-3; Part 4 gets its own plan).

## Global Constraints

- All Rails commands run from `web-app/`. Docs live in `docs/` at the project root.
- Use generators: `bin/rails generate model ...`, `bin/rails generate migration ...`, `bin/rails generate sidekiq:job ...`, `bin/rails generate controller ...`.
- Services live in `app/lib/services/`, jobs in `app/sidekiq/`, and tests mirror them (`test/lib/services/...`, `test/sidekiq/...`).
- Inside `module Services::Books`, model constants are root-anchored: `::Books::Book`, `::Books::AlternateTitle`.
- Rails 8 enum syntax: `enum :status, {kept: 0, removed: 1, review: 2}`.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`. Mocha stubs every OpenAI and Open Library call.
- Controller tests assert behavior (status, redirects, rows changed), never HTML or copy.
- Lint with `bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.
- Never run a destructive command against the development database. Never use bare `git stash`.
- The normalized form of a title is `Services::Books::Verification::Check.normalize(title)` (NameNormalizer, then QuoteNormalizer, then downcase). It is nil for a blank title.
- Auto-remove threshold: `Rails.configuration.x.books_alternate_titles.auto_remove_confidence`, set to `0.8`.
- A `removed` title is never added back by `legacy`, `merge` or `ai_enrichment`. Only `admin` and `correction` may reinstate one.
- Rows whose source is `admin` are never removed automatically: a `not_same_work` verdict sends them to `review`.
- The array copy is the book's `kept` and `review` rows, ordered by `id`.
- Removed titles are marked, never deleted.

## Review Focus

1. **A writer runs on a book before the production backfill has reached it.** The writer must first create that book's `legacy` rows from its array, or the array copy it then assigns drops every legacy title. Pinned in Task 2 (`test_add_backfills_a_book_with_no_rows_first`).
2. **An identifier stage 2 added from Open Library and stage 3 then confirmed through WorldCat, where both findings agree only through a removed title.** It must end destroyed. Confirmed findings are undone before added ones; the other order leaves it alive. Pinned in Task 9 (`test_added_then_worldcat_confirmed_identifier_is_destroyed`).
3. **A title holding a comma ("Good Night, Mr. Tom") saved through the admin edit form.** It stays one title and nothing is marked removed. Pinned in Task 5 (controller test and E2E).
4. **The AI answers with a repeated key, an unknown key, a category that contradicts its verdict, or a confidence outside 0..1.** That entry is ignored and its row stays unjudged for the next run. Pinned in Task 6 (`test_malformed_results_leave_rows_unjudged`).
5. **A merge where the source book removed a title the target still keeps, or where the target removed the source's main title.** The target ends with that title `removed` and it is not re-added. Pinned in Task 3 (`test_merge_removed_wins_over_kept`, `test_merge_does_not_readd_a_removed_source_title`).

---

### Task 1: The table, the model and the backfill

**Files:**
- Create (generator): `web-app/db/migrate/<ts>_create_books_alternate_titles.rb`, `web-app/app/models/books/alternate_title.rb`, `web-app/test/models/books/alternate_title_test.rb`, `web-app/test/fixtures/books/alternate_titles.yml`
- Create: `web-app/app/lib/services/books/alternate_titles/backfill.rb`, `web-app/test/lib/services/books/alternate_titles/backfill_test.rb`
- Create: `web-app/lib/tasks/books/alternate_titles.rake`
- Modify: `web-app/app/models/books/book.rb` (association)

**Interfaces:**
- Produces: `Books::AlternateTitle` with
  - `enum :source, {legacy: 0, merge: 1, ai_enrichment: 2, admin: 3, correction: 4}, prefix: :from`
  - `enum :status, {kept: 0, removed: 1, review: 2}`
  - `enum :verdict, {same_work: 0, not_same_work: 1}, prefix: true`
  - `enum :category, {translation: 0, variant: 1, fuller_title: 2, short_title: 3, other_work: 4, volume_or_part: 5, combined_edition: 6, junk: 7}, prefix: true`
  - `enum :decided_by, {ai: 0, admin: 1, correction: 2}, prefix: true`
  - scopes `listed` (kept or review, `order(:id)`) and `unjudged` (kept, `verdict: nil`)
- Produces: `Books::Book has_many :alternate_title_records, class_name: "Books::AlternateTitle", dependent: :delete_all`
- Produces: `Services::Books::AlternateTitles::Backfill.call(book) -> Integer` (rows inserted) and `Backfill.all -> Integer`

Columns: `book_id` (bigint, not null, FK `books_books` on delete cascade), `title` (string, not null), `normalized_title`
(string, not null), `source` (integer, not null), `status` (integer, not null, default 0), `verdict`, `category`
(integer, null), `confidence` (float, null), `reason` (text), `ai_chat_id` (bigint, FK `ai_chats` on delete nullify),
`decided_by` (integer, null), `decided_by_user_id` (bigint, FK `users` on delete nullify), `decided_at`, `judged_at`,
`undo_checked_at` (datetime, null), timestamps. Indexes: unique `[book_id, normalized_title]`, `[status]`.

- [ ] **Step 1: Generate the model and migration**

Run: `bin/rails generate model books/alternate_title book:references title:string normalized_title:string source:integer status:integer verdict:integer category:integer confidence:float reason:text ai_chat:references decided_by:integer decided_by_user_id:bigint decided_at:datetime judged_at:datetime undo_checked_at:datetime`
Rewrite the generated fixture file with semantic names (rows on existing `books.yml` books, e.g. `war_and_peace_voyna`), never `one`/`two`.
Then edit the migration to the columns above: null constraints, the default, the cascade/nullify foreign keys
(`foreign_key: {to_table: :books_books, on_delete: :cascade}`, `{to_table: :ai_chats, on_delete: :nullify}`,
`add_foreign_key :books_alternate_titles, :users, column: :decided_by_user_id, on_delete: :nullify`), both indexes.
Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && bin/rails db:test:prepare`
Expected: migration runs; `db/schema.rb` has `books_alternate_titles`.

- [ ] **Step 2: Write the failing model and backfill tests**

`test/models/books/alternate_title_test.rb`:
- `test_normalized_title_is_set_from_title`: `"“Don Quixote”"` saves with `normalized_title == Check.normalize("“Don Quixote”")`.
- `test_one_row_per_book_and_normalized_title`: a second row on the same book with `"WAR AND PEACE"` after `"War and Peace"` is invalid; on another book it is valid.
- `test_listed_is_kept_and_review_in_id_order`: with kept, removed, review rows, `listed.pluck(:title)` is the kept and review titles in insertion order.
- `test_unjudged_is_kept_without_a_verdict`.

`test/lib/services/books/alternate_titles/backfill_test.rb`:
- `test_creates_one_legacy_row_per_array_element`: book with `alternate_titles: ["Voyna i mir", "Guerre et paix"]` → 2 `legacy`, `kept` rows in array order; returns 2; the array is unchanged.
- `test_is_idempotent`: a second call returns 0 and the row count is unchanged.
- `test_collapses_spellings_that_normalize_alike`: `["Voyna i mir", "VOYNA I MIR"]` → 1 row.
- `test_never_touches_an_existing_removed_row`: a `removed` row for "Guerre et paix" stays `removed`; no second row.
- `test_all_backfills_every_book_with_alternate_titles`.

- [ ] **Step 3: Run them to see them fail**

Run: `bin/rails test test/models/books/alternate_title_test.rb test/lib/services/books/alternate_titles/backfill_test.rb`
Expected: FAIL (no normalization callback, no `Backfill`).

- [ ] **Step 4: Implement**

Model: the enums, scopes, `belongs_to :book`, `belongs_to :ai_chat, optional: true`,
`belongs_to :decided_by_user, class_name: "User", optional: true`, `validates :title, :normalized_title, presence: true`,
`validates :normalized_title, uniqueness: {scope: :book_id}`, and a `before_validation` that sets `normalized_title`
from `title`. Add the `has_many` to `Books::Book` and `has_many :decided_alternate_titles, class_name: "Books::AlternateTitle", foreign_key: :decided_by_user_id, dependent: :nullify` to `User` (every user FK needs a `has_many`).

`Backfill.call(book)`: `insert_all` one row per array element whose normalized form is present, with `source: legacy`,
`status: kept`, `unique_by: [:book_id, :normalized_title]` (skip duplicates), in array order so `id` order is array
order. `Backfill.all`: `::Books::Book.where("cardinality(alternate_titles) > 0").find_each`, summing.

Rake `books:alternate_titles:backfill` prints the count.

- [ ] **Step 5: Run the tests to see them pass**

Run: same command as Step 3. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A web-app/db web-app/app/models web-app/app/lib/services/books/alternate_titles web-app/lib/tasks/books/alternate_titles.rake web-app/test
git commit -m "Alternate titles table, model and backfill"
```

---

### Task 2: The writer service

**Files:**
- Create: `web-app/app/lib/services/books/alternate_titles/writer.rb`, `web-app/test/lib/services/books/alternate_titles/writer_test.rb`

**Interfaces:**
- Consumes: Task 1's model, `Backfill.call(book)`.
- Produces (all class methods on `Services::Books::AlternateTitles::Writer`; each first calls `Backfill.call(book)`, writes rows, then assigns `book.alternate_titles = listed titles` **without saving** unless stated):
  - `add(book:, titles:, source:) -> Result` data `{added: [String], reinstated: [String], skipped_removed: [String]}`. Skips blanks, titles whose normalized form equals the book's main title's, titles that already have a row, and `removed` rows (reinstates those only when `source` is `:admin` or `:correction`).
  - `replace(book:, titles:, source:, user: nil) -> Result` data `{added:, reinstated:, removed: [String]}`. `source` must be `:admin` or `:correction` (`ArgumentError` otherwise). Every `kept`/`review` row not in `titles` becomes `removed` with `reason` `REMOVED_BY[source]`, `decided_by: source`, `decided_by_user_id: user&.id`, `decided_at: now`. A title in `titles` that matches a row by normalized form but differs in spelling updates that row's `title`.
  - `decide(row:, status:, user: nil) -> Result`: `status` is `:kept` or `:removed`; sets `decided_by: admin`, the user, `decided_at`; sets `reason` to `REMOVED_BY[:admin]` / `KEPT_BY_ADMIN` only when the row has no AI reason; **saves the book** with the new copy.
  - `move(source_book:, target_book:) -> [String]` the titles newly listed on the target (used by the merger, Task 3).
  - `listed_titles(book) -> [String]`.
  - Constants: `REMOVED_BY = {admin: "removed by admin", correction: "removed by correction"}`, `KEPT_BY_ADMIN = "kept by admin"`.

- [ ] **Step 1: Write the failing tests**

- `test_add_creates_rows_with_the_source_and_assigns_the_copy`: `add(titles: ["Anna K"], source: :ai_enrichment)` → row `from_ai_enrichment`, `kept`; `book.alternate_titles` ends with `"Anna K"`; `book.changed?` is true (not saved).
- `test_add_backfills_a_book_with_no_rows_first`: book with array `["Voyna i mir"]` and no rows; `add(["Guerre et paix"], source: :merge)` → copy is `["Voyna i mir", "Guerre et paix"]`, the first row `from_legacy`.
- `test_add_skips_a_removed_title`: removed row "Capítulo 22"; `add(["capítulo 22"], source: :legacy)` → still removed, `skipped_removed == ["capítulo 22"]`, not in the copy.
- `test_add_reinstates_a_removed_title_for_admin`: same with `source: :admin` → row `kept`, `from_admin`, in `reinstated`.
- `test_add_skips_the_main_title_and_existing_rows`.
- `test_replace_removes_titles_left_out`: rows A, B; `replace(titles: ["A"], source: :correction)` → B `removed`, `reason == "removed by correction"`, `decided_by_correction?`.
- `test_replace_keeps_a_comma_title_whole`: `replace(titles: ["Good Night, Mr. Tom"], source: :admin)` with that row existing → no row removed, copy `["Good Night, Mr. Tom"]`.
- `test_replace_rejects_other_sources`: `assert_raises(ArgumentError) { replace(..., source: :legacy) }`.
- `test_decide_removes_and_saves_the_book`: `decide(row:, status: :removed, user:)` → row removed, `decided_by_admin?`, user recorded; `book.reload.alternate_titles` excludes it.
- `test_decide_keeps_the_ai_reason`: a row with AI reason keeps that reason after `decide(..., status: :kept)`.
- `test_review_rows_stay_in_the_copy`.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/books/alternate_titles/writer_test.rb`
Expected: FAIL (`Writer` undefined).

- [ ] **Step 3: Implement `Writer`** per the Interfaces block. `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Normalize with `Check.normalize`; dedupe incoming titles by normalized form, first spelling wins. `move` is specified in Task 3 but implemented here, with Task 3's tests: rows of `source_book` move to `target_book` (`update_columns(book_id:)`); where the target holds the same normalized title, the target's row is kept, it becomes `removed` if either side is removed (copying the source row's verdict fields when the source was the removed one), and the source row is deleted; a moved row equal to the target's main title is deleted; then `add(book: target_book, titles: [source_book.title], source: :merge)`.

- [ ] **Step 4: Run them to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books/alternate_titles/writer.rb web-app/test/lib/services/books/alternate_titles/writer_test.rb
git commit -m "Alternate titles writer: add, replace, decide, move"
```

---

### Task 3: Route the automatic writers through the table

**Files:**
- Modify: `web-app/app/lib/books/book/merger.rb:540-555` (`absorb_alternate_titles`)
- Modify: `web-app/app/lib/services/books/apply_book_facts.rb:147-160` (`apply_alternate_titles`)
- Modify: `web-app/app/lib/services/books_migration/book_migrator.rb:20-28` (`upsert_row`)
- Modify: `web-app/app/lib/services/books/normalize_stored_names.rb:137-155` (`apply_books`)
- Test: `web-app/test/lib/books/book/merger_test.rb`, `web-app/test/lib/services/books/apply_book_facts_test.rb`, the migrator and normalize-names tests next to them

**Interfaces:**
- Consumes: `Writer.add`, `Writer.move`, `Writer.listed_titles`.

- [ ] **Step 1: Write the failing tests**

Merger:
- `test_merge_moves_rows_with_their_status`: source has a `review` row with an AI verdict → after the merge it is on the target, still `review`, verdict intact; the source's main title is a `from_merge` row on the target; `stats[:alternate_titles_added]` lists the newly listed titles.
- `test_merge_removed_wins_over_kept`: source `removed` "The Treasure of the City of Ladies", target `kept` same → target row `removed`, one row.
- `test_merge_does_not_readd_a_removed_source_title`: target holds a `removed` row equal to the source's main title → it stays `removed` and is not in the target's array.

ApplyBookFacts:
- `test_alternate_titles_fill_through_the_table`: new titles become `from_ai_enrichment` rows; a title matching a `removed` row is not added and the ledger value excludes it.

BookMigrator:
- `test_new_book_gets_legacy_rows`: `upsert_row` for a new legacy book with `alternate_titles` → `from_legacy` rows and the matching array.
- `test_rerun_does_not_readd_a_removed_title` (non-sync mode): a re-run over a book whose "Capítulo 22" row is `removed` leaves it removed and out of the array.

NormalizeStoredNames:
- `test_apply_rewrites_row_titles`: a row whose title has curly quotes gets the normalized spelling; the array matches the rows.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/books/book/merger_test.rb test/lib/services/books/apply_book_facts_test.rb test/lib/services/books_migration test/lib/services/books/normalize_stored_names_test.rb`
Expected: the new tests FAIL; existing ones pass.

- [ ] **Step 3: Implement**

- Merger: `absorb_alternate_titles` becomes `@stats[:alternate_titles_added] = Writer.move(source_book:, target_book:)`. It already runs before `destroy_source_book`, which must stay true.
- ApplyBookFacts: `Writer.add(book:, titles: incoming, source: :ai_enrichment)`; the ledger `value` is `data[:added]`; reason `already_set` when nothing was added. `human_cleared` stays as it is.
- BookMigrator: `alternate_titles` comes out of the `assign_attributes` hash; after `book.save!`, `Writer.add(book:, titles: <transformer's list>, source: :legacy)` and `book.save! if book.changed?`. `BookTransformer` keeps returning the list; the migrator reads it from there.
- NormalizeStoredNames: for each book it applies, rewrite each row's `title` with `normalize` (same method it uses now), then `book.alternate_titles = Writer.listed_titles(book)` in place of `normalize_list(...)`. `changed_alternates` is still the difference against the old array.

- [ ] **Step 4: Run them to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib web-app/test
git commit -m "Merger, enrichment, legacy migrator and name normalizer write alternate titles through the table"
```

---

### Task 4: Corrections write through the table

**Files:**
- Create: `web-app/app/lib/services/corrections/targets/alternate_titles.rb`
- Modify: `web-app/app/lib/services/corrections/targets.rb`, `web-app/app/models/concerns/correctable.rb` (`TARGETS`), `web-app/app/models/books/book.rb:108`
- Test: `web-app/test/lib/services/corrections/applier_test.rb`

**Interfaces:**
- Consumes: `Writer.replace(book:, titles:, source: :correction)`.
- Produces: correctable target `:alternate_titles` (`Services::Corrections::Targets::AlternateTitles` with `read`, `write`, `accepts_blank?` → true).

- [ ] **Step 1: Write the failing tests**

- `test_accepted_alternate_titles_remove_the_titles_left_out`: book rows A, B; accepting `["A", "C"]` → B `removed` with reason "removed by correction", C `from_correction`, the book's array `["A", "C"]`.
- `test_accepted_alternate_titles_reinstate_a_removed_title`.
- `test_rejected_correction_changes_no_rows`.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/corrections/applier_test.rb`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement** the target (`read` returns `record.alternate_titles`; `write` calls `Writer.replace` — the applier's transaction and its `save!` cover it), add `:alternate_titles` to `Correctable::TARGETS` and `Targets.for`, and declare `correctable_field :alternate_titles, type: :string_array, target: :alternate_titles`.

- [ ] **Step 4: Run them to see them pass**

Run: `bin/rails test test/lib/services/corrections test/models/concerns test/controllers/admin/corrections_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app web-app/test
git commit -m "Accepted corrections write alternate titles through the table"
```

---

### Task 5: The admin form edits one title per input

**Files:**
- Modify: `web-app/app/views/admin/books/books/_form.html.erb:119-128`, `web-app/app/controllers/admin/books/books_controller.rb:147-151` and its create/update actions
- Test: `web-app/test/controllers/admin/books/books_controller_test.rb`, `web-app/e2e/tests/books/admin/books.spec.ts`

**Interfaces:**
- Consumes: `Writer.replace(book:, titles:, source: :admin, user: current_user)`.
- The form posts `books_book[alternate_titles][]`, one per input, plus one always-blank hidden input (so clearing every row still sends the key), using the `shared--form-token` list markup from `app/views/admin/corrections/show.html.erb:88-115`.

- [ ] **Step 1: Write the failing tests**

Controller:
- `test_update_keeps_a_comma_title_whole`: PATCH with `alternate_titles: ["", "Good Night, Mr. Tom"]` → one row, `kept`, no removed rows.
- `test_update_marks_a_dropped_title_removed`: rows A, B; PATCH `["", "A"]` → B `removed`, `decided_by_admin?`, `decided_by_user_id` is the admin.
- `test_update_without_the_key_changes_no_titles`: PATCH with no `alternate_titles` param → rows unchanged.
- `test_create_writes_admin_rows`.

E2E (`books.spec.ts`): on a book's edit page, add an alternate title containing a comma, save, and see it shown once, whole, on the book page; remove it, save, and see it gone.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement**

`assign_book_attributes` stops writing `alternate_titles`. After a successful save in `create` and `update`, when `params[:books_book]` has the `alternate_titles` key, call `Writer.replace` with the compacted list and `book.save!` if changed. Keep it in the same transaction as the save.

- [ ] **Step 4: Run the tests and the E2E**

Run: `bin/rails test test/controllers/admin/books/books_controller_test.rb`. Expected: PASS.
Run (after `yarn build:all`, `bin/rails server`, and the port-3000 check from AGENTS.md): `yarn test:e2e e2e/tests/books/admin/books.spec.ts`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app web-app/test web-app/e2e
git commit -m "Admin book form edits one alternate title per input"
```

---

### Task 6: The AI review task and the review service

**Files:**
- Create: `web-app/app/lib/services/ai/tasks/books/alternate_titles_review_task.rb`, `web-app/test/lib/services/ai/tasks/books/alternate_titles_review_task_test.rb`
- Create: `web-app/app/lib/services/books/alternate_titles/review.rb`, `web-app/test/lib/services/books/alternate_titles/review_test.rb`
- Create: `web-app/config/initializers/books_alternate_titles.rb`

**Interfaces:**
- Produces: `Services::Ai::Tasks::Books::AlternateTitlesReviewTask.new(parent: book, entries: [Entry], accepted: [String]).call -> Services::Ai::Result` with `data[:results]` a Hash of key → `{verdict:, category:, confidence: Float, reason:}`. `Entry = Struct.new(:key, :title, keyword_init: true)`. Role `:fast`. Response schema `ResponseSchema` (`results: ArrayOf[TitleResult]`; `TitleResult`: `key` String, `verdict` String, `category` String, `confidence` Float, `reason` String).
- Produces: `Services::Books::AlternateTitles::Review.call(book:) -> Result` data `{judged:, kept:, removed:, review:, missing:}`; failure Result when an AI call fails. `CHUNK = 40`.
- Config: `config.x.books_alternate_titles.auto_remove_confidence = 0.8`.

- [ ] **Step 1: Write the failing tests**

Task (`process_and_persist` driven through a stubbed provider response, as the category-cleanup task tests do):
- `test_results_are_keyed_by_number`.
- `test_malformed_results_leave_rows_unjudged`: a repeated key keeps the first; an unknown key, a `same_work` verdict with category `other_work`, and a confidence of `1.4` are each dropped.
- `test_user_prompt_holds_the_book_and_numbered_titles`: the prompt contains the title, subtitle, author names, first published year, `[1] "Capítulo 22"`, and the accepted titles line.

Review (the task stubbed with Mocha):
- `test_same_work_keeps_and_records_the_verdict`: row stays `kept` with verdict, category, confidence, reason, `ai_chat`, `judged_at`, `decided_by_ai?`.
- `test_confident_not_same_work_is_removed`: confidence 0.9 → `removed`; the book's saved array excludes it.
- `test_unsure_not_same_work_goes_to_review`: confidence 0.5 → `review`; still in the array.
- `test_admin_rows_go_to_review_whatever_the_confidence`: `from_admin`, confidence 0.99 → `review`.
- `test_only_unjudged_rows_are_sent`: a judged row's title goes in `accepted`, not in `entries`, and its verdict does not change.
- `test_missing_keys_are_asked_once_more`: first call answers 1 of 2, the second answers the other → both judged; with no answer the second time, `missing == 1` and that row stays unjudged.
- `test_long_lists_are_chunked`: 45 unjudged rows → 2 calls (40 + 5), each with the book's details.
- `test_a_book_with_nothing_unjudged_makes_no_call`.
- `test_a_failed_call_returns_failure_and_writes_nothing`.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/lib/services/ai/tasks/books/alternate_titles_review_task_test.rb test/lib/services/books/alternate_titles/review_test.rb`
Expected: FAIL (undefined constants).

- [ ] **Step 3: Implement**

The task follows `CategoryCleanup::BaseCleanupTask` (keyed results, `value`/`string` readers for the shallow `to_h`) but subclasses `BaseTask` directly, with `parent: book` (an `AiChat` per call). The system message defines the two verdicts and eight categories from the spec, says a translation or transliteration of the same work is `same_work`, a single volume or part of a multi-volume work is `volume_or_part`, a sequel, prequel, companion or a different book by the same author is `other_work`, a book combined with others is `combined_edition`, and asks for a confidence from 0 to 1 and a one-sentence reason. `Review` applies verdicts per the spec's "What a verdict does", using the threshold from config; rows and the book's copy are written in one transaction per book; the book is saved only when its listed titles changed.

- [ ] **Step 4: Run them to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib web-app/config/initializers/books_alternate_titles.rb web-app/test
git commit -m "AI review of a book's alternate titles"
```

---

### Task 7: The review job, the queueing rake task and the report

**Files:**
- Create (generator `bin/rails generate sidekiq:job books/alternate_titles/review`): `web-app/app/sidekiq/books/alternate_titles/review_job.rb`, `web-app/test/sidekiq/books/alternate_titles/review_job_test.rb`
- Create: `web-app/app/lib/services/books/alternate_titles/report.rb`, `web-app/test/lib/services/books/alternate_titles/report_test.rb`
- Modify: `web-app/lib/tasks/books/alternate_titles.rake`
- Test: `web-app/test/lib/tasks/books_alternate_titles_rake_test.rb`

**Interfaces:**
- Consumes: `Review.call(book:)`.
- Produces: `Books::AlternateTitles::ReviewJob` (`queue: :low`, `retry: 3`); `perform(book_id)` raises on a failed Result so Sidekiq retries; `self.pending_book_ids(scope) -> [Integer]` where `scope` is `"ranked"`, `"all"` or a count string; `self.enqueue(scope) -> Integer`, `perform_bulk` in slices of 1,000.
- Ordering: books with an `unjudged` row; ranked first, by `rank` in `Books::RankingConfiguration.default_primary` (as `Services::Books::Verification::Run` reads it, `run.rb:227`), then the rest by id. `"ranked"` is the first group only; a count is the first N of `"all"`.
- Produces: `Report.call -> String`: counts by status, verdict, category and source; up to 10 samples per category (`book id, book title, title, confidence, reason`); the count of `admin` rows in review.
- Rake: `books:alternate_titles:review[scope]` (default `ranked`), `books:alternate_titles:report`, `books:alternate_titles:restore[row_id]` (`Writer.decide(row:, status: :kept)`).

- [ ] **Step 1: Write the failing tests**

- Job: `test_pending_ranked_comes_first_by_rank`, `test_count_scope_takes_the_first_n`, `test_books_with_nothing_unjudged_are_not_queued`, `test_perform_raises_on_failure` (Review stubbed to fail), `test_perform_skips_a_missing_book`.
- Report: `test_counts_and_samples` against fixture rows.
- Rake: `test_review_task_enqueues_the_scope` (`ReviewJob.expects(:enqueue).with("ranked")`), `test_restore_task_keeps_the_row`.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/sidekiq/books/alternate_titles test/lib/services/books/alternate_titles/report_test.rb test/lib/tasks/books_alternate_titles_rake_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement** per the Interfaces block.

- [ ] **Step 4: Run them to see them pass**

Run: same as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app web-app/lib/tasks web-app/test
git commit -m "Queue the alternate-title review by rank, and report on it"
```

---

### Task 8: Admin card and review page

The spec suggested the Goodreads `RepairVerdict` queue. It does not fit: its approve only marks a row for a later
`goodreads_replay:apply`, its bulk approve uses `update_all`, and its rows are keyed for the replay. The row's own
`review` status is the queue, so it gets its own page (the spec left this to the builder).

**Files:**
- Create (generator `bin/rails generate controller admin/books/alternate_titles`): `web-app/app/controllers/admin/books/alternate_titles_controller.rb`, `web-app/app/views/admin/books/alternate_titles/index.html.erb`, `web-app/app/views/admin/books/alternate_titles/review.html.erb`, `web-app/test/controllers/admin/books/alternate_titles_controller_test.rb`
- Modify: `web-app/config/routes.rb` (books admin namespace, near `resources :identifiers` at line 710), `web-app/app/views/admin/books/books/show.html.erb` (a card after Identifiers, line ~168), the books admin nav partial (a "Alternate titles" link to the review page)
- Test: `web-app/e2e/tests/books/admin/books.spec.ts`

**Interfaces:**
- Consumes: `Writer.decide(row:, status:, user:)`.
- Routes: nested `resources :alternate_titles, only: [:index]` under `books` (the lazy card frame, `alternate_titles_list`, `render layout: false`, paginated 50); top-level `resources :alternate_titles, only: [] do collection { get :review }; member { post :keep; post :remove; post :restore } end`.
- `review` lists `review` rows across books, oldest first, paginated 50, filterable by `source`. `keep` acts on a `review` row; `remove` on a `kept` or `review` row; `restore` on a `removed` row; anything else redirects with an alert and changes nothing. Members take `require_domain_write!`; the frame and the page take the read gate, as `IdentifiersController` does. Every member action redirects back (`redirect_back_or_to` the book's admin page). Buttons sit in forms with `data: {turbo_frame: "_top"}`.
- The card shows, per row: title, source, status, verdict, category, confidence, reason, a link to the AI chat (`admin_books_ai_chat_path`), decided by and when, and the button that fits its status.

- [ ] **Step 1: Write the failing tests**

Controller:
- `test_index_renders_the_book_rows`, `test_review_lists_only_review_rows`, `test_review_filters_by_source`.
- `test_keep_marks_a_review_row_kept`, `test_remove_marks_it_removed_and_updates_the_book_array`, `test_restore_brings_back_a_removed_row`.
- `test_restore_on_a_kept_row_changes_nothing`.
- `test_members_require_write_access` (a read-only admin gets the denied response; the row is unchanged).

E2E: open a fixture book's admin page, see its Alternate titles card, remove a title and see it marked removed, restore it; open the review page and keep a row.

- [ ] **Step 2: Run them to see them fail**

Run: `bin/rails test test/controllers/admin/books/alternate_titles_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement** per the Interfaces block, with DaisyUI 5 classes only (no `form-control`, `label-text`, `input-bordered` and the rest of the removed list). Seed the E2E data in `e2e:prepare` if the fixture book has no rows.

- [ ] **Step 4: Run the tests and the E2E**

Run: `bin/rails test test/controllers/admin/books`. Expected: PASS.
Run (port check first): `yarn test:e2e e2e/tests/books/admin/books.spec.ts`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/app web-app/config/routes.rb web-app/test web-app/e2e web-app/lib
git commit -m "Admin alternate titles card and review page"
```

---

### Task 9: Undo the findings removed titles let in

**Files:**
- Create (generator): `web-app/db/migrate/<ts>_add_undo_to_books_verification_findings.rb` (`undone_at` datetime, `undo_action` integer)
- Modify: `web-app/app/models/books/verification_finding.rb`, `web-app/app/lib/services/books/verification/stamp.rb:47-52`
- Create: `web-app/app/lib/services/books/alternate_titles/undo_findings.rb`, `web-app/test/lib/services/books/alternate_titles/undo_findings_test.rb`
- Modify: `web-app/lib/tasks/books/alternate_titles.rake`, `web-app/test/lib/tasks/books_alternate_titles_rake_test.rb`

**Interfaces:**
- Produces: `Books::VerificationFinding` `enum :undo_action, {identifier_destroyed: 0, source_restored: 1, identifier_gone: 2}, prefix: :undo` and scope `not_undone`.
- `Stamp.finding` clears `undone_at` and `undo_action` when it writes a finding again.
- Produces: `Services::Books::AlternateTitles::UndoFindings.call(apply: false, client: ::Books::OpenLibrary::Client.new) -> Result` data `{books:, findings_checked:, undone: {identifier_destroyed:, source_restored:, identifier_gone:}, wrong_work: [{book_id:, title:, work_key:, work_title:}], samples: [String]}`; `UndoFindings.redo(finding:) -> Result`.
- Rake: `books:alternate_titles:undo_findings[apply]` (prints the dry run unless `apply` is `apply`), `books:alternate_titles:redo_finding[finding_id]`.

The rule, per book that has a `removed` row with `undo_checked_at: nil`:

```
TitleView = Data.define(:title, :alternate_titles)
kept_view = TitleView.new(book.title, kept + review titles)
full_view = TitleView.new(book.title, kept + review + removed titles)
work      = the settled Open Library work: verification.new_key, or the book's single books_work_openlibrary_id,
            fetched with client.works_batch; nil unless work_outcome is in Books::Verification::KEYED_OUTCOMES
wrong_work = work && !Check.titles_agree?(kept_view, work) && Check.titles_agree?(full_view, work)
agrees?(view, w, finding):
  open_library -> EditionCheck.title_agrees?(view, w, EditionLike(title: evidence["title"], subtitle: nil))
  worldcat     -> evidence["records"].any? { EditionCheck.title_agrees?(view, nil, WorldCatCheck.work_like(RecordLike(record))) }
undo a finding when agrees?(full_view, work) && !agrees?(kept_view, wrong_work ? nil : work)
```

Findings considered: `kind` `added` or `confirmed`, `source` `open_library` or `worldcat`, `not_undone`, with an evidence
title (or records). Confirmed findings are undone before added ones. An `added` finding destroys its identifier only if
the book still holds it (`identifier_id`, this book) with `source == finding.source`; a `confirmed` one sets the
identifier's `source` back to `previous_source`; an identifier that is gone or moved is recorded as `identifier_gone`.
Each undone finding gets `undone_at` and `undo_action`. With `apply`, each book's changes and its rows'
`undo_checked_at` are written in one transaction. The dry run writes nothing. `redo` reverses one undone finding:
recreate the identifier on the book with `finding.source` (unless another book holds it as verified: then fail), or set
its source back to `finding.source`, and clear the undo fields.

- [ ] **Step 1: Write the failing tests** (Open Library client stubbed with Mocha; fixtures for a verification row, findings and identifiers)

- `test_finding_agreeing_only_through_a_removed_title_is_undone`: edition "The Treasure of the City of Ladies", removed row with that title → the added identifier is destroyed, `undo_identifier_destroyed?`.
- `test_finding_agreeing_through_a_kept_title_too_stays`: an identifier whose edition title matches both a removed and a kept title is untouched.
- `test_review_titles_still_agree`.
- `test_confirmed_finding_goes_back_to_its_previous_source`.
- `test_added_then_worldcat_confirmed_identifier_is_destroyed`: OL `added` + WorldCat `confirmed` (previous `open_library`), both only through the removed title → identifier destroyed.
- `test_identifier_held_with_another_source_is_left`: an added finding whose identifier is now `worldcat`-sourced (a WorldCat confirmation that still agrees) is not destroyed.
- `test_wrong_work_is_listed_and_its_title_does_not_count`: the settled work's title agrees only through the removed title → book in `wrong_work`; an edition matching only the work's title is undone; the work key identifier is untouched.
- `test_dry_run_writes_nothing`.
- `test_apply_is_idempotent`: a second `apply` run checks no books and changes nothing.
- `test_a_later_removal_is_processed_on_the_next_run`.
- `test_redo_recreates_the_identifier`.
- Stamp: `test_rewriting_a_finding_clears_its_undo` in `test/lib/services/books/verification/stamp_test.rb`.

- [ ] **Step 2: Run them to see them fail**

Run: `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/lib/services/books/alternate_titles/undo_findings_test.rb test/lib/services/books/verification/stamp_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement** per the rule above. Fetch works in batches of 50 keys. A work key Open Library does not return counts as `work = nil` and is listed in the samples as "work not found". Root-anchor `::Books::Verification`, `::Identifier`.

- [ ] **Step 4: Run them to see them pass**

Run: same test command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web-app/db web-app/app web-app/lib/tasks web-app/test
git commit -m "Undo verification findings that agreed only through a removed alternate title"
```

---

### Task 10: Docs, launch order and the full suite

**Files:**
- Create: `docs/features/books-alternate-titles.md`
- Modify: `docs/launch-todo.md`, `docs/features/book-verification.md` (a pointer to the undo step)

- [ ] **Step 1: Write the feature doc**: the table, sources and statuses, the copy array and why it exists until Part 4, the writers and the no-come-back rule, the review (threshold, chunking, re-runs), the admin card and review page, the undo rule, and every rake task.

- [ ] **Step 2: Add the production order to `docs/launch-todo.md`**: deploy; `books:alternate_titles:backfill`; `books:alternate_titles:review[ranked]`, wait for the queue, `books:alternate_titles:report` and the hand checks the spec lists; `review[all]`; `undo_findings` dry run, checked by hand, then `undo_findings[apply]`. Mark `review` and `undo_findings` as **repeating**: run again after merges, the weekly sync, the review page and corrections, and in the final launch sequence. The second-chance run follows.

- [ ] **Step 3: Run the whole suite and the linter**

Run: `bin/rails test 2>&1 | tail -20 && bundle exec standardrb`
Expected: 0 failures, 0 errors, no new warning lines, no offenses.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "Docs and launch order for the alternate titles cleanup"
```
