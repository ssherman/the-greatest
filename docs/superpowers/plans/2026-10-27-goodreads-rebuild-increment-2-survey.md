# Goodreads Rebuild Increment 2: Stage One Survey Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For every derived (import-made) book, gather the Goodreads editions its export rows name, check each edition against WorldCat and Open Library by ISBN, group the editions into works, and record whether the book is coherent, a lump, or unsupported. This is read-only for the catalog.

**Architecture:** Two new tables hold the results. `books_rebuild_edition_evidences` has one row per Goodreads edition, for what WorldCat and Open Library say about its ISBN. Stage two reuses it. `books_rebuild_book_surveys` has one row per derived book: its class and edition groups.

A run service, `Survey`, works through `Cohort.derived` one book at a time under an advisory lock, with one Sidekiq job and a report rake task. It writes nothing to books, authors, identifiers or verdicts. The fixes (`fix_identity`, `split`) are increment 2b, built on the survey's stored results.

**Tech Stack:** Rails 8, PostgreSQL, Sidekiq, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md`:
- §4 stage one;
- §7 evidence services and the WorldCat timing;
- §10, where the survey feeds the labeled sample.

Increments: 1 foundation (merged, #423) · **2 survey (this plan)** · 2b identity fixes and splits · 3 verification scope · 4 stage two and member guards · 5 sweep and catch-up.

**Ruling recorded here:** the spec's stage one is split into a read-only survey (2) and the fixes (2b). The survey's report measures lumps, WorldCat agreement and lookup speed on real data before any rule edits a book, and settles §7's WorldCat timing question by itself. Cost if wrong: one extra increment.

## Global Constraints

- **Read-only for the catalog.** Write only the two new tables. No changes to books, authors, identifiers, list items or `RepairVerdict`.
- **Where code lives:**
  - Services in `app/lib/services/books/goodreads_rebuild/`, returning `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
  - The job via `bin/rails generate sidekiq:job books/goodreads_rebuild/survey`: queue `low`, `retry: false`.
  - Models via `bin/rails generate model`.
  - Migrations run annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Delete annotation and schema lines for tables that aren't this branch's: the shared dev DB holds another branch's `sessions` table.
- **Enum syntax:** Rails 8, `enum :world_cat, {...}`.
- **Which books:** `Services::Books::GoodreadsRebuild::Cohort.derived` (increment 1). Trusted books are never surveyed.
- **An edition's rows** are `Books::GoodreadsImportRow`s, linked through `goodreads_edition_id`. A row names a book through `legacy_book_id`, which is legacy's choice. A `legacy_book_id` whose book no longer exists is followed with `Services::Books::GoodreadsReplay::Apply::MergedBook.call(id)`, which returns the book it was merged into, or nil.
- **The edition facts used:** `Books::GoodreadsEdition` `title` (the series suffix is already split into `series_name` and `series_number`), `primary_author`, `additional_authors`, `original_publication_year`, `series_number`, `isbn13`, `isbn10` and `goodreads_book_id`.
- **ISBNs:** `Books::Isbn.normalize(raw)` returns `isbn13`/`isbn10`, or nil for a bad checksum. Use `isbn13`, falling back to `isbn10`'s derived 13.
- **WorldCat:** `Books::WorldCat::Client#record_by_isbn(isbn13)` returns an Array of `Record`s.
  - **Agreement:** a record agrees when `Check.titles_agree?(edition_like, work)` and `Check.authors_agree?(edition_like, work)` both hold, with `work = WorldCatCheck.work_like(record)`.
  - **Disagreement:** a record disagrees when neither holds.
  - Anything else is `unclear`. Several records: `agrees` if any agrees, else `disagrees` if any disagrees, else `unclear`.
  - (`Check` and `WorldCatCheck` are in `Services::Books::Verification`.)
- **Open Library:** `Books::OpenLibrary::Client#identifier("isbn_13", isbn13)` returns an Array of `IdentifierHit`, with `work_key` on each. Keep every distinct `work_key`.
- **Errors:** an `::Books::OpenLibrary::Exceptions::Error` or `::Books::WorldCat::Exceptions::Error` stops the run. The book keeps no survey row, so the next run retries it. That's the same rule as `Verification::Run`.
- **One survey run at a time:** a `pg_try_advisory_lock` with a fixed `LOCK_KEY = 7_262_024_100_802`. The verification run uses `...801`.
- **The services are shared.** Dev and production share the WorldCat and Open Library services. No dev run of more than 200 books while a production verification run is going. Shane runs production.
- Lint with `bundle exec standardrb`; the full `bin/rails test` must pass.

## The grouping rule (Task 3), pinned here

Each edition gets:

- `author_key`: `Check.compact(primary_author)`. Letters only, so "J.D. Salinger" equals "J. D. Salinger". Nil when blank or too short.
- `year`: `original_publication_year`.
- `volume`: `series_number` stripped, or nil when blank.

Then:

1. **Group** editions with the same `[author_key, year, volume]`, where all three are non-nil.
2. **Merge by Open Library work.** Merge two groups when an edition in each shares an Open Library work key and both editions have the same `volume`, nil included. An Open Library work holds translations whose Goodreads author string may be transliterated.
3. **Place editions with a nil field.** An edition with a nil `author_key` or nil `year` joins the group that matches it on every non-nil field. If several match, it joins the one with the most rows. If none match, it starts its own group.
4. **Classify.** No editions: `unsupported`. One group: `coherent`. Two or more groups: `lump`.

Groups are stored biggest first, by row count, then lowest Goodreads book id.

## Review Focus

1. **A translation whose Goodreads author string differs** ("Lev Tolstoy" against "Leo Tolstoy"). It must not be called a lump when Open Library puts both ISBNs on one work. Test in Task 3.
2. **Numbered volumes by one author in one year** (*V for Vendetta* #1 and #2, same year). They must be a lump. Test in Task 3.
3. **A row whose `legacy_book_id` was merged away.** Its editions count for the surviving book. Test in Task 4.
4. **A service outage mid-run.** The run stops, the current book gets no survey row, and the next run picks it up. Evidence already gathered for other editions is kept. Test in Task 5.
5. **An edition with no ISBN, or a bad checksum.** It gets `world_cat: :no_isbn` and no Open Library work, with no service call and no crash. Test in Task 2.

---

### Task 1: The two tables

**Files:**
- Create (generators): migrations, `web-app/app/models/books/rebuild_edition_evidence.rb`, `web-app/app/models/books/rebuild_book_survey.rb`, and their tests and fixtures.

**Interfaces:**
- Produces `Books::RebuildEditionEvidence` (table `books_rebuild_edition_evidences`):
  - `goodreads_edition_id` (bigint, not null, unique, FK `books_goodreads_editions` `on_delete: :cascade`);
  - `isbn13` (string, nullable);
  - `world_cat` (integer, not null; enum `no_isbn: 0, no_record: 1, agrees: 2, disagrees: 3, unclear: 4`);
  - `world_cat_title`, `world_cat_creator` (string, nullable);
  - `world_cat_year` (integer, nullable);
  - `ol_work_keys` (string array, default `[]`, not null);
  - `checked_at` (datetime, not null);
  - `belongs_to :goodreads_edition, class_name: "Books::GoodreadsEdition"`.
- Produces `Books::RebuildBookSurvey` (table `books_rebuild_book_surveys`):
  - `book_id` (bigint, not null, unique, FK `books_books` `on_delete: :cascade`);
  - `classification` (integer, not null; enum `coherent: 0, lump: 1, unsupported: 2`);
  - `edition_count`, `row_count`, `world_cat_agreeing` (integers, not null, default 0);
  - `groups` (jsonb, not null, default `[]`);
  - `surveyed_at` (datetime, not null);
  - `belongs_to :book, class_name: "Books::Book"`.
  - Each `groups` element is `{"edition_ids" => [..], "goodreads_book_ids" => [..], "titles" => [up to 3], "author" => String, "year" => Integer|nil, "volume" => String|nil, "row_count" => Integer}`.

- [ ] **Step 1: Generate both models.**
  - `bin/rails generate model books/rebuild_edition_evidence goodreads_edition:references isbn13:string world_cat:integer world_cat_title:string world_cat_creator:string world_cat_year:integer ol_work_keys:string checked_at:datetime`
  - `bin/rails generate model books/rebuild_book_survey book:references classification:integer edition_count:integer row_count:integer world_cat_agreeing:integer groups:jsonb surveyed_at:datetime`

  Then edit the migrations:
  - nulls and defaults as above, with `ol_work_keys` as `array: true, default: [], null: false`;
  - the FKs with `to_table` and `on_delete: :cascade`;
  - unique indexes on `goodreads_edition_id` and `book_id`;
  - an index on `classification`.

  Fixtures: one evidence row (`agrees`) and two surveys (`coherent`, `lump`), on existing fixtures. Check `test/fixtures/books/goodreads_editions.yml` and `books.yml` for labels.
- [ ] **Step 2: Write the failing model tests.**
  - `test "an edition has one evidence row"`: a duplicate insert raises `ActiveRecord::RecordNotUnique`.
  - `test "a book has one survey"`: the same, on `book_id`.
  - `test "deleting the book deletes its survey"`: `book.delete`, and the survey is gone.
  - `test "the enums"`: `assert_equal %w[no_isbn no_record agrees disagrees unclear], Books::RebuildEditionEvidence.world_cats.keys`, and the same for `classifications`.
- [ ] **Step 3: Run them to see them fail.** `bin/rails test test/models/books/rebuild_edition_evidence_test.rb test/models/books/rebuild_book_survey_test.rb`. Expected: FAIL before the migrate.
- [ ] **Step 4: Migrate and implement.** Run `bin/rails db:migrate` and `RAILS_ENV=test bin/rails db:schema:load`. Strip foreign tables from `schema.rb`. Add the enums, `belongs_to` and presence validations. Each class comment says the table is rebuild scratch data, safe to rebuild, and keyed so stage two can reuse it.
- [ ] **Step 5: Run them to see them pass.** Expected: PASS.
- [ ] **Step 6: Commit.** Message: "Goodreads rebuild: tables for edition evidence and book surveys".

### Task 2: `GatherEvidence`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/gather_evidence.rb` and `web-app/app/lib/services/books/goodreads_rebuild/edition_like.rb`. Test `web-app/test/lib/services/books/goodreads_rebuild/gather_evidence_test.rb`.

**Interfaces:**
- Produces:
  - `EditionLike.from(edition) -> Data(title:, alternate_titles:, authors:, first_published_year:)`. `authors` holds `Data(name:, alternate_names: [], id: nil)` for `primary_author` plus each of `additional_authors`. It's shaped for `Verification::Check.titles_agree?`/`authors_agree?`.
  - `GatherEvidence.call(editions:, world_cat:, open_library:) -> Result`, with `data` = `{evidence: Hash{edition_id => Books::RebuildEditionEvidence}, looked_up: Integer}`.
    - It reuses an existing evidence row, so it never looks up again.
    - It creates the missing ones.
    - Service errors propagate.

- [ ] **Step 1: Write the failing tests.** Stub the clients with `Mocha` (`world_cat.stubs(:record_by_isbn)`, `open_library.stubs(:identifier)`). Build `Books::WorldCat::Record`s with `Record.from_hash`, and `IdentifierHit`s with `new(...)`.
  - `test "an agreeing WorldCat record and an Open Library work are stored"`:
    - Edition: "The Remains of the Day", by Kazuo Ishiguro, ISBN 9780679731726.
    - Record: title "The remains of the day /", creator "Ishiguro, Kazuo".
    - OL hit: work_key "OL15936W".
    - Expect: `world_cat == "agrees"`, `ol_work_keys == ["OL15936W"]`, `world_cat_title` and `world_cat_creator` stored, `looked_up == 1`.
  - `test "a record for another book disagrees"`: record "Cooking for one /" by "Smith, Jane" → `disagrees`.
  - `test "no record"`: an empty array → `no_record`.
  - `test "no ISBN or a bad checksum makes no call"`:
    - Editions with nil ISBNs, and one with ISBN `9780679731727` (bad checksum).
    - Stub `record_by_isbn` and `identifier` with `.never`.
    - Expect `world_cat == "no_isbn"` and `ol_work_keys == []`.
  - `test "ISBN-10 only is looked up as its ISBN-13"`: `isbn10: "0679731725"` → `record_by_isbn` with `"9780679731726"`.
  - `test "an existing evidence row is reused"`: a fixture row → no calls, `looked_up == 0`.
  - `test "a service error propagates and stores nothing for that edition"`: `record_by_isbn` raises `::Books::WorldCat::Exceptions::Error` → `assert_raises`, and no evidence row for the edition.
- [ ] **Step 2: Run them to see them fail.** `bin/rails test test/lib/services/books/goodreads_rebuild/gather_evidence_test.rb`. Expected: FAIL, uninitialized constant.
- [ ] **Step 3: Implement** both classes, with the agreement rule from Global Constraints. Look up WorldCat first, then Open Library, then create the row, so a failure stores nothing.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: GatherEvidence checks each edition's ISBN against WorldCat and Open Library".

### Task 3: `GroupEditions`

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/group_editions.rb`. Test `web-app/test/lib/services/books/goodreads_rebuild/group_editions_test.rb`.

**Interfaces:**
- Produces `GroupEditions.call(editions:, evidence:, row_counts:) -> Array<Hash>`.
  - `editions` is an Array of `Books::GoodreadsEdition`.
  - `evidence` is a `Hash{edition_id => RebuildEditionEvidence}`.
  - `row_counts` is a `Hash{edition_id => Integer}`.
  - It returns the group hashes in Task 1's shape, biggest first.
- Also produces `GroupEditions.classify(groups) -> :coherent | :lump | :unsupported`.

Build editions with `Books::GoodreadsEdition.new(...)` (unsaved, with ids set), and evidence with `Books::RebuildEditionEvidence.new(ol_work_keys: [...])`. No database is needed.

- [ ] **Step 1: Write the failing tests**, one per rule:
  - `test "editions agreeing on author, year and volume are one group"`: an English and a German title of one work, same author and year → 1 group, `classify == :coherent`.
  - `test "initials spelled differently are one author"`: "J.D. Salinger" and "J. D. Salinger" → 1 group.
  - `test "different original years are a lump"`: *Hothouse* (Brian W. Aldiss, 1962) and a Hardy Boys title (Franklin W. Dixon, 1927) → 2 groups, `:lump`. The bigger row count comes first.
  - `test "numbered volumes by one author in one year are a lump"`: *V for Vendetta* volume "1" and "2", Alan Moore, 1988 → 2 groups.
  - `test "a shared Open Library work joins a transliterated author"`: "Leo Tolstoy" 1869 and "Lev Tolstoy" 1869, both with evidence `ol_work_keys ["OL267933W"]` → 1 group.
  - `test "a shared Open Library work does not join different volumes"`: volumes "1" and "2" sharing a work key → 2 groups.
  - `test "an edition with no year joins the matching group with the most rows"`: two groups for one author (1950 with 5 rows, 1960 with 2 rows), plus that author with a nil year → it joins 1950.
  - `test "an edition matching no group starts its own"`
  - `test "no editions is unsupported"`: `classify([]) == :unsupported`.
  - `test "group hash shape"`: the keys are exactly the eight in Task 1, `titles` holds at most 3, and `goodreads_book_ids` is sorted.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement** the pinned rule. The OL merge uses union-find over group indexes. Nil placement comes after the merge.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: GroupEditions splits a book's editions into works".

### Task 4: `SurveyBook` and the merged-book map

**Files:** Create `web-app/app/lib/services/books/goodreads_rebuild/survey_book.rb` and `web-app/app/lib/services/books/goodreads_rebuild/legacy_book_map.rb`. Test both under `web-app/test/lib/services/books/goodreads_rebuild/`.

**Interfaces:**
- Consumes `GatherEvidence` (Task 2), `GroupEditions` (Task 3) and the models (Task 1).
- Produces `LegacyBookMap.build -> LegacyBookMap`, with `#legacy_ids_for(book_id) -> Array<Integer>`.
  - Build it once per run.
  - It finds the distinct `legacy_book_id`s on rows whose book no longer exists, resolves each with `MergedBook.call`, and inverts that.
  - `legacy_ids_for(b)` is `[b] + every vanished id that resolves to b`.
- Produces `SurveyBook.call(book:, map:, world_cat:, open_library:) -> Result`, with `data` = `{survey: Books::RebuildBookSurvey, looked_up: Integer}`. It upserts the book's survey row:
  - editions are the distinct `goodreads_edition` of rows `where(legacy_book_id: map.legacy_ids_for(book.id))`;
  - `row_count` is those rows;
  - `world_cat_agreeing` is the number of editions with `agrees`.

- [ ] **Step 1: Write the failing tests.**
  - `test "the map follows a merged-away legacy book"`: a row with `legacy_book_id` 999_999, which doesn't exist; stub `MergedBook.call(999_999)` to return the fixture book → `legacy_ids_for(book.id) == [book.id, 999_999]`.
  - `test "a coherent book"`: two rows on two editions of one work. Stub `GatherEvidence` (or the clients) → survey `coherent`, `edition_count` 2, `row_count` 2, one group.
  - `test "a lump"`: editions with different years → `lump`, 2 groups.
  - `test "a book no row names is unsupported"`: no service calls, `row_count` 0.
  - `test "rows on a merged-away legacy id count for the survivor"`
  - `test "re-surveying replaces the row"`: call twice, one row, `surveyed_at` updated.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement both.** Upsert with `find_or_initialize_by(book:)` and then `update!`.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: SurveyBook records a derived book's editions, evidence and groups".

### Task 5: The `Survey` run, its job and rake tasks

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_rebuild/survey.rb`, `web-app/app/lib/services/books/goodreads_rebuild/survey_report.rb`, the job via `bin/rails generate sidekiq:job books/goodreads_rebuild/survey`.
- Modify: `web-app/lib/tasks/books/goodreads_rebuild.rake`.
- Tests: `survey_test.rb`, `survey_report_test.rb`, `test/sidekiq/books/goodreads_rebuild/survey_job_test.rb`, `test/lib/tasks/books_goodreads_rebuild_rake_test.rb`.

**Interfaces:**
- Produces `Survey.call(limit:, world_cat: nil, open_library: nil) -> Result`, with `data` = `{processed:, looked_up:, stopped: Boolean, error: String|nil}`.
  - It takes `Cohort.derived` books with no survey row, ordered by id, `limit` of them (nil means all), in batches of 100.
  - It builds the `LegacyBookMap` once.
  - It's under the advisory lock. When the lock is busy it returns `stopped: true` and `error: "another survey run is in progress"`.
  - On a service error it returns `stopped: true` with the error message.
- Produces `Books::GoodreadsRebuild::SurveyJob#perform(limit)`, which calls `Survey` and logs `"Goodreads rebuild survey: <processed> books -- stopped: <error>"`.
- Produces `SurveyReport.call -> String`, a plain-text report:
  - surveyed books and derived books left;
  - counts by classification;
  - evidence counts by `world_cat`;
  - the share of editions with an Open Library work;
  - the lookup rate: evidence rows in the last hour, and over the whole run (`count / (max(checked_at) - min(checked_at))`);
  - 10 random lumps, with each group's titles, author, year, volume and row count;
  - 10 random coherent books.
- Rake tasks:
  - `books:goodreads_rebuild:survey[limit]` takes a number or `all` (anything else aborts with usage), queues the job and prints `queued survey of <limit> books`.
  - `books:goodreads_rebuild:survey_report` prints the report.

- [ ] **Step 1: Write the failing tests.**
  - `survey_test.rb`:
    - `test "surveys derived books without a survey, up to the limit"`: stub `Cohort.derived` to a relation of 3 fixture books, with `limit: 2` → 2 surveys.
    - `test "skips books already surveyed"`
    - `test "stops on a WorldCat error and keeps going next run"`: the first book's lookup raises → `stopped: true`, 0 surveys. Then a run with the stub fixed surveys it.
    - `test "a second run while one holds the lock stops at once"`: take the lock in the test with `pg_try_advisory_lock(7_262_024_100_802)` → `error == "another survey run is in progress"`. Release it in `ensure`.
  - `survey_report_test.rb`: `test "report lists counts and a lump sample"`, with fixture surveys → includes `lump 1` and the lump's group titles.
  - Job test: `test "perform runs the survey with the limit"`. `Survey.expects(:call).with(limit: 50)` returns a Result.
  - Rake tests: `test "survey queues the job"` (`SurveyJob.expects(:perform_async).with(200)` for `survey[200]`, and `.with(nil)` for `survey[all]`); `test "survey rejects a bad limit"` (`assert_raises(SystemExit)`); `test "survey_report prints the report"`.
- [ ] **Step 2: Run them to see them fail.** Expected: FAIL.
- [ ] **Step 3: Implement.** The lock pattern copies `Verification::Run#call`, with `pg_try_advisory_lock` and `pg_advisory_unlock` in `ensure`, on one checked-out connection.
- [ ] **Step 4: Run them to see them pass.** Expected: PASS.
- [ ] **Step 5: Commit.** Message: "Goodreads rebuild: survey run, job, and survey/survey_report rake tasks".

### Task 6: Docs, launch steps, and a dev smoke run

**Files:** Modify `docs/features/goodreads-rebuild.md` (a "Stage one survey" section) and `docs/launch-todo.md` §11 (replace the step 3 placeholder).

- [ ] **Step 1: Docs.**
  - The feature doc covers the tables, the grouping rule, the lookup and stop rules, the commands, and that the fixes are increment 2b.
  - The launch-todo step, in plain words:
    1. `bin/rails "books:goodreads_rebuild:survey[200]"`, then `bin/rails books:goodreads_rebuild:survey_report`: read the lump sample and the lookup rate.
    2. Then `bin/rails "books:goodreads_rebuild:survey[all]"`.
    3. If it stops, run it again, and it resumes.
    4. Don't run it while a verification run is going: they share the WorldCat and Open Library services.
- [ ] **Step 2: Verify.** `bin/rails test` and `bundle exec standardrb`. Expected: 0 failures, 0 offenses, no new warnings.
- [ ] **Step 3: Dev smoke run, only if no production verification run is going** (ask Shane). From `web-app/`, run `bin/rails runner 'pp Services::Books::GoodreadsRebuild::Survey.call(limit: 50).data'`, then `bin/rails books:goodreads_rebuild:survey_report`. Record the lookup rate and classification counts in the PR body. This writes only the two rebuild tables.
- [ ] **Step 4: Commit.** Message: "Docs: Goodreads rebuild stage one survey".
