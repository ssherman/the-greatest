# Goodreads Rebuild Increment 2: Stage One Survey, Pass 1 (local) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For every derived (import-made) book, read the Goodreads editions its export rows name and record five things:
- whether the book is coherent, a lump or unsupported;
- its edition groups;
- whether our title agrees with the export;
- whether our authors agree with the export;
- whether it is the wrong book altogether.

It uses only our own database, with no Open Library or WorldCat calls, and is read-only for the catalog.

**Architecture:**
- **Results table:** `books_rebuild_book_surveys`, one row per derived book.
- **Services:**
  - `GroupEditions` sorts a book's editions into works.
  - `CompareIdentity` checks our title and authors against the export, reusing the verification pass's `Check`.
  - `SurveyBook` records one book.
  - `Survey` runs over `Cohort.derived` in batches of 500, preloading rows and editions per batch.
- **Running it:** a Sidekiq job and two rake tasks, `survey` and `survey_report`.
- **New index:** `books_goodreads_import_rows.legacy_book_id`, so batch loads don't scan 498k rows.

**Tech Stack:** Rails 8, PostgreSQL, Sidekiq, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md` (§4 stage one, §10 the labeled sample and acceptance).

Increments: 1 foundation (merged, #423) · **2 survey pass 1, local (this plan)** · 2-pass-2 evidence: WorldCat and Open Library per ISBN, run after the production verification run · 2b identity fixes and splits · 3 verification scope · 4 stage two and member guards · 5 sweep and catch-up.

**Rulings recorded here** (Shane agreed to the split on 2026-10-27):

1. **Stage one splits into a read-only survey and the fixes (2b).** Real counts come before any rule edits a book. Cost if wrong: one extra increment.
2. **The survey splits into a local pass 1 and a service pass 2.** The production verification run holds Open Library and WorldCat for days. Pass 1 needs neither and can run now. Pass 2 adds the Open Library work merge, which joins transliterated authors, and the WorldCat check. Cost if wrong: pass 1 reports some translations whose Goodreads author string differs as lump suspects, until pass 2.
3. **The survey also compares our title and authors with the export** (Shane, 2026-10-27: he suspects many wrong authors and wrong books). That count is the main output Shane wants.

## Global Constraints

- **Read-only for the catalog.** Write only `books_rebuild_book_surveys`, plus the one index migration. No changes to books, authors, identifiers, list items or `RepairVerdict`. No Open Library, WorldCat or AI calls.
- **Where code lives:**
  - Services in `app/lib/services/books/goodreads_rebuild/`, returning `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
  - The job via `bin/rails generate sidekiq:job books/goodreads_rebuild/survey`: queue `low`, `retry: false`.
  - The model via `bin/rails generate model`, and migrations via generators.
  - `db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Strip schema and annotation lines for tables that aren't this branch's: the shared dev DB holds another branch's `sessions` table.
- **Which books:** `Services::Books::GoodreadsRebuild::Cohort.derived` (increment 1).
- **A book's rows** are `Books::GoodreadsImportRow`s whose `legacy_book_id` is in `LegacyBookMap#legacy_ids_for(book.id)`. That's the book itself, plus legacy ids merged into it, followed by `Services::Books::GoodreadsReplay::Apply::MergedBook.call(id)`. A row's edition is `row.goodreads_edition`, and rows with none are skipped.
- **The edition facts used:** `Books::GoodreadsEdition` `title` (already without the series suffix), `primary_author`, `additional_authors`, `original_publication_year`, `series_number` and `goodreads_book_id`.
- **The comparisons** reuse `Services::Books::Verification::Check`: `titles_agree?(book, work)`, `authors_agree?(book, work)` and `compact(name)`.
  - `work` is a `Services::Books::Verification::WorldCatCheck::WorkLike.new(title:, subtitle: nil, author_names:, author_keys: [])`.
  - `book` is the real `Books::Book`, whose `title`, `alternate_titles` and `authors` are what Check reads.
- **One run at a time:** `pg_try_advisory_lock(7_262_024_100_802)`. The verification run uses `...801`.
- Lint with `bundle exec standardrb`; the full `bin/rails test` must pass.

## The rules, pinned

**Grouping** (`GroupEditions`, Task 2). Each edition gets three fields:
- `author_key`: `Check.compact(primary_author)`. Letters only, so "J.D. Salinger" equals "J. D. Salinger". Nil when blank or too short.
- `year`: `original_publication_year`.
- `volume`: `series_number` stripped, or nil when blank.

Then:
1. **Group** editions with the same `[author_key, year, volume]`, where all three are non-nil.
2. **Merge by Open Library work** (only when `evidence:` is given, which pass 2 does; pass 1 passes `{}`). Merge two groups when an edition in each shares an Open Library work key and both editions have the same `volume`, nil included.
3. **Place editions with a nil field.** An edition with a nil `author_key` or nil `year` joins the group that matches it on every non-nil field. If several match, it joins the one with the most rows. If none match, it starts its own group.
4. **Classify.** No editions: `unsupported`. One group: `coherent`. Two or more: `lump`.

Groups are stored biggest first, by row count, then lowest Goodreads book id. Each is a Hash:
```
{"edition_ids" => [..], "goodreads_book_ids" => [..sorted], "titles" => [up to 3 distinct],
 "authors" => [distinct primary_author values, up to 3], "year" => Integer|nil,
 "volume" => String|nil, "row_count" => Integer}
```

**Identity** (`CompareIdentity`, Task 3), against the main group (the first):
- `title_agrees`: some edition in the main group gives `Check.titles_agree?(book, WorkLike(title: edition.title, author_names: []))`.
- `authors_agree`: `Check.authors_agree?(book, WorkLike(title: nil, author_names: <every primary_author and additional_authors in the main group>))`. A book with no authors is `false`.
- `wrong_book`: no edition in **any** group agrees on title, **and** no group agrees on authors. In plain words, the record is a different book from everything people imported onto it.
- An `unsupported` book gets all three nil.

## Review Focus

1. **A book whose title we store stripped** ("X Men" against the export's "X-Men: The Age of Apocalypse, Vol. 2"). `title_agrees` is false, and it isn't `wrong_book` while the authors agree. Test in Task 3.
2. **A translation edition in the main group.** Our English title and a German edition title in the same group give `title_agrees` true, because any edition in the group may agree. Test in Task 3.
3. **A row whose `legacy_book_id` was merged away.** Its editions count for the surviving book. Test in Task 4.
4. **A batch boundary.** A book's rows are loaded with its batch, never another batch's, and a book merged into a book in a different batch still gets its rows. Test in Task 5.
5. **A re-run.** `survey[all]` takes only books with no survey. `redo` re-surveys every derived book and updates the rows in place. Test in Task 5.

---

### Task 1: Survey table and the row index

**Files:**
- Create (generators): the model `web-app/app/models/books/rebuild_book_survey.rb`, its migration, test and fixture, and the migration `AddLegacyBookIdIndexToBooksGoodreadsImportRows`.

**Interfaces:**
- Produces `Books::RebuildBookSurvey` (table `books_rebuild_book_surveys`):
  - `book_id` (bigint, not null, unique, FK `books_books` `on_delete: :cascade`);
  - `classification` (integer, not null; enum `coherent: 0, lump: 1, unsupported: 2`);
  - `edition_count`, `row_count` (integers, not null, default 0);
  - `groups` (jsonb, not null, default `[]`);
  - `title_agrees`, `authors_agree` (boolean, nullable);
  - `wrong_book` (boolean, not null, default false);
  - `surveyed_at` (datetime, not null);
  - `belongs_to :book, class_name: "Books::Book"`.
  - Scopes: `title_disagrees` (`title_agrees: false`) and `authors_disagree` (`authors_agree: false`).
- Produces an index on `books_goodreads_import_rows(legacy_book_id)`.

- [ ] **Step 1: Generate.**
  - `bin/rails generate model books/rebuild_book_survey book:references classification:integer edition_count:integer row_count:integer groups:jsonb title_agrees:boolean authors_agree:boolean wrong_book:boolean surveyed_at:datetime`
  - `bin/rails generate migration AddLegacyBookIdIndexToBooksGoodreadsImportRows`, containing `add_index :books_goodreads_import_rows, :legacy_book_id`.

  Then edit the survey migration:
  - nulls and defaults as above;
  - `foreign_key: {to_table: :books_books, on_delete: :cascade}`;
  - a unique index on `book_id`, replacing the one `references` adds;
  - indexes on `classification` and `wrong_book`.

  Fixtures: `coherent_survey` and `lump_survey`, on two existing `books_books` fixtures.
- [ ] **Step 2: Write the failing model tests.**
  - `test "a book has one survey"`: a duplicate `book_id` raises `ActiveRecord::RecordNotUnique` (use `save!(validate: false)`).
  - `test "deleting the book deletes its survey"`: `survey.book.delete` → the survey is gone.
  - `test "classification enum"`: `%w[coherent lump unsupported]`.
  - `test "disagreement scopes"`: a survey with `title_agrees: false` is in `title_disagrees`, and one with `true` isn't. The same for `authors_disagree`.
- [ ] **Step 3: Run them to see them fail.** `bin/rails test test/models/books/rebuild_book_survey_test.rb`. Expected: FAIL.
- [ ] **Step 4: Migrate and implement.** Run `bin/rails db:migrate` and `RAILS_ENV=test bin/rails db:schema:load`. Strip foreign tables. Implement the enum, `belongs_to`, presence validations and scopes. The class comment says it's rebuild scratch data, re-runnable, and that 2b reads it.
- [ ] **Step 5: Run them to see them pass.** Expected: PASS.
- [ ] **Step 6: Commit.** Message: "Goodreads rebuild: books_rebuild_book_surveys table; index import rows by legacy book".

### Task 2: `GroupEditions`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/group_editions.rb`. Test `web-app/test/lib/services/books/goodreads_rebuild/group_editions_test.rb`.

**Interfaces:**
- Produces `GroupEditions.call(editions:, row_counts:, evidence: {}) -> Array<Hash>`. The group hashes are as pinned above, biggest first.
  - `editions` is an Array of `Books::GoodreadsEdition`.
  - `row_counts` is a `Hash{edition_id => Integer}`.
  - `evidence` is a `Hash{edition_id => object responding to ol_work_keys}`. It's empty in pass 1.
- Also produces `GroupEditions.classify(groups) -> :coherent | :lump | :unsupported`.

Build unsaved `Books::GoodreadsEdition.new(id:, ...)`. Stand in for evidence with `Struct.new(:ol_work_keys)`.

- [ ] **Step 1: Write the failing tests.**
  - `test "one work's editions are one group"`: an English and a German title, same author and year → 1 group, `:coherent`.
  - `test "initials spelled differently are one author"`: "J.D. Salinger" and "J. D. Salinger".
  - `test "different original years are a lump, biggest group first"`:
    - *Hothouse*: Brian W. Aldiss, 1962, 3 rows.
    - A Hardy Boys title: Franklin W. Dixon, 1927, 1 row.
    - Expect 2 groups, `:lump`, with *Hothouse* first.
  - `test "numbered volumes by one author in one year are a lump"`: *V for Vendetta* volumes "1" and "2", Alan Moore, 1988.
  - `test "a shared Open Library work joins a transliterated author"`: "Leo Tolstoy" and "Lev Tolstoy", 1869, both with evidence `["OL267933W"]` → 1 group. Without evidence → 2 groups.
  - `test "a shared Open Library work does not join different volumes"`
  - `test "an edition with no year joins the matching group with the most rows"`
  - `test "an edition matching no group starts its own"`
  - `test "classify with no groups is unsupported"`
  - `test "group hash shape"`: exactly the seven keys, `titles` at most 3, and `goodreads_book_ids` sorted.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement** the pinned rule, with union-find for the Open Library merge and nil placement after it.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: GroupEditions splits a book's editions into works".

### Task 3: `CompareIdentity`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/compare_identity.rb`. Test `web-app/test/lib/services/books/goodreads_rebuild/compare_identity_test.rb`.

**Interfaces:**
- Consumes Task 2's group hashes, with each group's editions available. Signature: `CompareIdentity.call(book:, groups:, editions_by_id:) -> Hash{title_agrees:, authors_agree:, wrong_book:}`.
  - `editions_by_id` is a `Hash{edition_id => Books::GoodreadsEdition}`.
  - With no groups, it returns `{title_agrees: nil, authors_agree: nil, wrong_book: false}`.

- [ ] **Step 1: Write the failing tests.** Use a real `Books::Book` created with authors, as in existing tests with `Books::Author`. Check `test/fixtures/books/authors.yml`.
  - `test "matching title and author agree"`: book "The Remains of the Day", by Kazuo Ishiguro; edition "The Remains of the Day", by Kazuo Ishiguro → `{true, true, false}`.
  - `test "a stripped title disagrees but is not the wrong book"`: book "X Men" by Chris Claremont; edition "X-Men: The Age of Apocalypse, Vol. 2" by Chris Claremont → `title_agrees: false`, `authors_agree: true`, `wrong_book: false`.
  - `test "a wrong author"`: book "The Eyes of Darkness" by Beverley Nichols; edition by Dean Koontz → `authors_agree: false`, `title_agrees: true`, `wrong_book: false`.
  - `test "the wrong book"`: book "Hothouse" by Brian W. Aldiss; its only group is a Hardy Boys title by Franklin W. Dixon → `wrong_book: true`.
  - `test "a lump whose minor group matches is not the wrong book"`: the main group is the Hardy Boys, and a second group is *Hothouse* by Aldiss → `title_agrees: false`, `authors_agree: false`, `wrong_book: false`.
  - `test "a translation in the main group lets the title agree"`: book "Tenth of December"; group editions "Dez de Dezembro" and "Tenth of December" → `title_agrees: true`.
  - `test "a book with no authors does not agree on authors"`
  - `test "no groups"`: all nil, and `wrong_book` false.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement** the pinned identity rule.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: CompareIdentity checks our title and authors against the export".

### Task 4: `LegacyBookMap` and `SurveyBook`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/legacy_book_map.rb` and `web-app/app/lib/services/books/goodreads_rebuild/survey_book.rb`. Tests under `web-app/test/lib/services/books/goodreads_rebuild/`.

**Interfaces:**
- Produces `LegacyBookMap.build -> LegacyBookMap`.
  - It takes the distinct non-null `legacy_book_id`s on rows whose book doesn't exist, resolves each with `MergedBook.call`, and inverts that.
  - `#legacy_ids_for(book_id) -> Array<Integer>`: `[book_id] + vanished ids resolving to it`, sorted.
  - `#all_legacy_ids_for(book_ids) -> Array<Integer>`: the union, for batch loading.
- Produces `SurveyBook.call(book:, rows:) -> Result`, with `data` = `{survey: Books::RebuildBookSurvey}`.
  - `rows` is this book's preloaded `GoodreadsImportRow`s, with `goodreads_edition` loaded.
  - It upserts one survey: editions are the distinct non-nil `row.goodreads_edition`, `row_counts` are per edition id, and `GroupEditions.call(..., evidence: {})`, `classify` and `CompareIdentity` fill it in.
  - It sets `edition_count`, `row_count` (rows with an edition), and `surveyed_at = Time.current`.

- [ ] **Step 1: Write the failing tests.**
  - `test "the map follows a merged-away legacy book"`: a row with `legacy_book_id` 999_999, which doesn't exist; `MergedBook.stubs(:call).with(999_999).returns(book)` → `legacy_ids_for(book.id) == [book.id, 999_999].sort`.
  - `test "a vanished id that resolves to nothing is dropped"`
  - `test "a coherent book"`: two rows on two editions of one work → `coherent`, `edition_count` 2, `row_count` 2, 1 group, `title_agrees` true.
  - `test "a lump"` → `lump`, 2 groups.
  - `test "no rows is unsupported"` → `row_count` 0, and the identity fields are nil.
  - `test "re-surveying updates the row in place"`: call twice → one row, with the newer `surveyed_at`.

  Create rows with `Books::GoodreadsImportRow.create!` on an import fixture, and editions with `Books::GoodreadsEdition.create!`. Check the fixtures and the required columns (`signature`, `primary_author`, `title`, `goodreads_book_id`, `row_number`, `raw`).
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement both.**
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: SurveyBook records a derived book's groups and identity check".

### Task 5: `Survey` run, report, job and rake tasks

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/survey.rb`, `web-app/app/lib/services/books/goodreads_rebuild/survey_report.rb`, and the job via `bin/rails generate sidekiq:job books/goodreads_rebuild/survey`.
- Modify: `web-app/lib/tasks/books/goodreads_rebuild.rake`.
- Tests: `survey_test.rb`, `survey_report_test.rb`, `web-app/test/sidekiq/books/goodreads_rebuild/survey_job_test.rb`, `web-app/test/lib/tasks/books_goodreads_rebuild_rake_test.rb`.

**Interfaces:**
- Produces `Survey.call(limit:, redo: false) -> Result`, with `data` = `{processed: Integer, stopped: Boolean, error: String|nil}`.
  - It takes `Cohort.derived` ordered by id. Without `redo`, it leaves out books with a survey row. `limit` nil means all.
  - It builds the `LegacyBookMap` once, then works in batches of 500 books. Per batch, it runs one `GoodreadsImportRow.where(legacy_book_id: map.all_legacy_ids_for(batch_ids)).includes(:goodreads_edition)` and groups those rows back per book through `legacy_ids_for`.
  - It works under the advisory lock. When busy, it returns `stopped: true` and `error: "another survey run is in progress"`.
  - It logs progress every batch (`Rails.logger.info`).
- Produces `Books::GoodreadsRebuild::SurveyJob#perform(limit, redo = false)`. It calls `Survey` and logs `"Goodreads rebuild survey: <processed> books -- stopped: <error>"` when stopped.
- Produces `SurveyReport.call -> String`, plain text with:
  - surveyed books, and derived books not yet surveyed;
  - counts by classification;
  - counts of `title_agrees` false, `authors_agree` false and `wrong_book` true, among `coherent` and `lump` books;
  - 10 random samples of each of: wrong book, wrong author (`authors_agree` false, not `wrong_book`) and stripped or different title (`title_agrees` false, not `wrong_book`). Each sample line reads: `#<id> "<our title>" by <our authors> | export: "<main group titles>" by <main group authors> (<rows> rows)`.
  - 10 random lumps, showing each group's titles, authors, year, volume and rows.
- Rake tasks:
  - `books:goodreads_rebuild:survey[limit,redo]`: `limit` is a number or `all` (anything else aborts with usage), and the optional second argument is `redo`. It queues `SurveyJob.perform_async(limit_or_nil, redo)` and prints `queued survey of <limit> derived books`, adding ` (redo)` when redoing.
  - `books:goodreads_rebuild:survey_report` prints the report.

- [ ] **Step 1: Write the failing tests.**
  - `survey_test.rb`:
    - `test "surveys derived books without a survey, up to the limit"`: stub `Cohort.derived` to `Books::Book.where(id: [a, b, c])`, with `limit: 2` → 2 survey rows.
    - `test "skips books already surveyed unless redo"`
    - `test "a book's rows on a merged-away id are found across batches"`: stub `Survey::BATCH` to 1 (`stub_const` style, or make `BATCH` an overridable keyword `batch_size:`).
    - `test "a second run while one holds the lock stops at once"`
  - `survey_report_test.rb`: `test "report counts and samples"`, using fixtures with one `wrong_book` → it includes `wrong book: 1` and the sample line.
  - Job test: `test "perform runs the survey"`: `Survey.expects(:call).with(limit: 50, redo: false)`.
  - Rake tests:
    - `survey[200]` → `perform_async(200, false)`;
    - `survey[all]` → `perform_async(nil, false)`;
    - `survey[all,redo]` → `perform_async(nil, true)`;
    - `survey[bogus]` aborts;
    - `survey_report` prints.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement.** The lock pattern copies `Verification::Run#call`. Give `Survey.call` a `batch_size: BATCH` keyword (BATCH = 500) for the batch test.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: survey run, job, and survey/survey_report rake tasks".

### Task 6: Docs, launch steps and the full dev run

**Files:** Modify `docs/features/goodreads-rebuild.md` (a "Stage one survey, pass 1" section) and `docs/launch-todo.md` §11 (replace the step 3 placeholder).

- [ ] **Step 1: Docs.**
  - The feature doc covers the table, the grouping and identity rules, the commands, what pass 2 adds, and that 2b acts on it.
  - The launch-todo step, in plain words: `bin/rails "books:goodreads_rebuild:survey[all]"`, wait for the job, then `bin/rails books:goodreads_rebuild:survey_report`, and check the samples by eye. It's local and safe to run alongside a verification run.
- [ ] **Step 2: Verify.** `bin/rails test` and `bundle exec standardrb`. Expected: 0 failures, 0 offenses, no new warnings.
- [ ] **Step 3: Full dev run.** It's local, and writes only the survey table. From `web-app/`:
  1. `bin/rails runner 't=Time.now; pp Services::Books::GoodreadsRebuild::Survey.call(limit: nil).data; puts Time.now-t'`
  2. `bin/rails books:goodreads_rebuild:survey_report > <workspace>/survey_report.txt`

  Record the runtime and the counts in the PR body, and read the samples for rule mistakes. A mistake found here is fixed with a failing test first.
- [ ] **Step 4: Commit.** Message: "Docs: Goodreads rebuild stage one survey, pass 1".
