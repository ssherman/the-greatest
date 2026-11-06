# Book Verification Pass (Increment 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One per-book verification pass, absorbing the OL key backfill as stage 1, that adds trusted identifiers from Open Library editions (stage 2), confirms held legacy ISBNs against WorldCat (stage 3), and records lump / wrong-identifier signals (stage 4), with one log, report and revert.

**Architecture:** The OL key backfill is renamed in place (`books_open_library_backfills` → `books_verifications`, `Services::Books::OlBackfill` → `Services::Books::Verification`). Its `ApplyBook` stays stage 1 and now also stamps the row's cohort and next stage. Three new stage services run after it, each committing its own writes and findings and advancing `stage`. `VerifyBook` drives one book through the stages it has left; `Run` picks books (ranked, pre-import by default) and handles retries. Every identifier the pass writes or confirms goes through one `Stamp` service that records a finding.

**Tech Stack:** Rails 8.1, PostgreSQL, Sidekiq, Minitest + Mocha + fixtures, the Open Library client (`Books::OpenLibrary::Client`) and the WorldCat client (`Books::WorldCat::Client`), Standard Ruby.

**Spec:** `docs/superpowers/specs/2026-10-16-book-verification-design.md` (sections 2-4 and 6-7; section 1 shipped in #395, which this plan builds on: `Identifier.sources`, `Identifier.verified`, `Identifier::VERIFIED_SOURCES`).

## Global Constraints

- Run Rails commands from `web-app/`; docs live in `docs/` at the project root.
- Default run scope: books in the default primary `Books::RankingConfiguration`, rank order, `pre_import` cohort only. Flags: `post_import`, `unranked`, `retry_unsure`, `recheck`.
- Cohort: `post_import` is exactly `Cohort::FIRST_POST_IMPORT_ID (16_572) <= id < Services::BooksMigration::RESERVED_CEILINGS["books_books"] (250_000)`; everything else is `pre_import` (spec section 4, amended).
- Stage 2 runs only for work outcomes `confirmed` (incl. confirmed-on-abstain), `updated`, `replaced`, `keyed`. Stage 3 runs for every processed book. Stage 4 runs for every processed book.
- `SET_WORDS`: "box set", "boxed set", "collection", "omnibus", "trilogy", "volumes", "books 1" (whole words, case-folded), applied only to subtitle text dropped from the edition to reach agreement.
- Year rule (editions and WorldCat records): year absent, or book has no `first_published_year`, or `year >= first_published_year - 1`.
- `MAX_WORLDCAT_ISBNS = 50`, `MAX_SIGNAL_LOOKUPS = 20` (five concurrent), lump suspect = `foreign_work` findings on two or more distinct works.
- Never delete an identifier except in revert. Signals are recorded only.
- Every identifier the pass writes names its source (`open_library` or `worldcat`); the `identifier_source` lint enforces it.
- Retries: 15, 30, 60, 120, 240, 300 s (`Run::RETRY_DELAYS`); 400/422/parse errors are book-specific; one run at a time (`Run::LOCK_KEY`); 4 s pause after `/resolve` (`Run::RESOLVE_PAUSE`).
- Rails 8 enum syntax; Result struct services; Minitest 6 (`assert_nil`); `bundle exec standardrb`; no brakeman; never run destructive commands against development.
- Generators for new models (`bin/rails generate model ...`); `ANNOTATERB_SKIP_ON_DB_TASKS=1` on every `db:migrate`.

## Review Focus

1. **A resumed book.** WorldCat went down after stage 2 wrote identifiers. Expected: the next run resumes at stage 3, never re-runs stage 1 or 2 for that book, and the earlier findings stay. Pinned in Task 6.
2. **Re-running a done book.** A second `[all]` must not touch it; `recheck` re-runs only stages 2-4 and only for books that gained a `legacy` identifier after `checked_at`; findings are upserted, never duplicated. Pinned in Tasks 3 and 6.
3. **An identifier another book already holds.** Verified elsewhere → `conflict`, nothing written; legacy elsewhere → written here plus `also_held`, the other book untouched. Pinned in Task 3.
4. **Garbled or partial WorldCat records.** Mojibake, a missing creator, a pre-publication placeholder title: none confirms, and a one-sided disagreement is never `wrong_identifier`. Pinned in Task 4.
5. **Revert after identifiers moved.** A merge moved or an admin deleted an identifier the pass added: revert skips and counts it, never raises. Pinned in Task 7.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `web-app/db/migrate/<ts>_rename_open_library_backfills_to_verifications.rb` | create | table + column rename, new columns |
| `web-app/db/migrate/<ts>_create_books_verification_findings.rb` | generator | findings table |
| `web-app/db/migrate/<ts>_create_books_edition_candidates.rb` | generator | candidates table |
| `web-app/app/models/books/verification.rb` | renamed from `open_library_backfill.rb` | the per-book log row |
| `web-app/app/models/books/verification_finding.rb` | generator | one identifier the pass touched or flagged |
| `web-app/app/models/books/edition_candidate.rb` | generator | one non-agreeing OL edition |
| `web-app/app/models/books/book.rb` | modify | `has_one :verification`, `has_many` findings and candidates |
| `web-app/app/models/identifier.rb` | modify | `unverified` scope |
| `web-app/app/lib/services/books/verification/` | renamed from `ol_backfill/` | `apply_book`, `author_keys`, `check`, `lookup`, `report`, `revert`, `run` |
| `.../verification/cohort.rb` | create | pre/post-import by id |
| `.../verification/stamp.rb` | create | write or confirm one identifier + its finding |
| `.../verification/counts.rb` | create | refresh the row's counters |
| `.../verification/edition_check.rb` | create | does an OL edition agree with the book |
| `.../verification/harvest_editions.rb` | create | stage 2 |
| `.../verification/world_cat_check.rb` | create | does a WorldCat record agree / clearly differ |
| `.../verification/confirm_with_world_cat.rb` | create | stage 3 |
| `.../verification/signals.rb` | create | stage 4 |
| `.../verification/verify_book.rb` | create | one book through its remaining stages |
| `web-app/app/sidekiq/books/verification_job.rb` | renamed from `open_library_backfill_job.rb` | the job |
| `web-app/lib/tasks/books/verify.rake` | renamed from `ol_backfill.rake` | `books:verify`, `_report`, `_revert` |
| `web-app/app/lib/services/identifiers/mark_legacy.rb` | modify | reads the renamed model |
| `web-app/test/support/ol_backfill_helper.rb` | modify | editions + WorldCat fakes and builders |
| `docs/features/book-verification.md` | renamed from `open-library-backfill.md`, rewritten | feature doc |
| `docs/features/worldcat-data-service.md`, `docs/features/identifier-provenance.md`, `docs/launch-todo.md`, `docs/todos/goodreads-import-accuracy.md` | modify | cross-references |

Tests mirror: `web-app/test/lib/services/books/verification/*_test.rb`, `web-app/test/models/books/verification*_test.rb`, `web-app/test/models/books/edition_candidate_test.rb`, `web-app/test/sidekiq/books/verification_job_test.rb`, `web-app/test/lib/tasks/books_verify_rake_test.rb`.

---

### Task 1: Rename the OL key backfill to the verification pass

A mechanical rename; behaviour does not change and the existing tests are the gate.

**Files:**
- Create: `web-app/db/migrate/<ts>_rename_open_library_backfills_to_verifications.rb` (`bin/rails generate migration RenameOpenLibraryBackfillsToVerifications`)
- Move: `app/models/books/open_library_backfill.rb` → `app/models/books/verification.rb`; `app/lib/services/books/ol_backfill/` → `app/lib/services/books/verification/`; `app/sidekiq/books/open_library_backfill_job.rb` → `app/sidekiq/books/verification_job.rb`; `lib/tasks/books/ol_backfill.rake` → `lib/tasks/books/verify.rake`; matching tests (`test/models/books/open_library_backfill_test.rb` → `verification_test.rb`, `test/lib/services/books/ol_backfill/` → `.../verification/`, `test/sidekiq/books/open_library_backfill_job_test.rb` → `verification_job_test.rb`, `test/lib/tasks/books_ol_backfill_rake_test.rb` → `books_verify_rake_test.rb`)
- Modify: `app/lib/services/identifiers/mark_legacy.rb`, `test/lib/services/identifiers/mark_legacy_test.rb`

**Interfaces:**
- Produces: `Books::Verification` (table `books_verifications`, enum `work_outcome` with the old outcome values, `KEYED_OUTCOMES`), `Services::Books::Verification::{ApplyBook, AuthorKeys, Check, Lookup, Report, Revert, Run}`, `Books::VerificationJob#perform(limit, run_id, retry_unsure = false)` (flags come in Task 6), rake `books:verify`, `books:verify_report`, `books:verify_revert`.
- **Naming rule for every later task:** inside `module Services; module Books; module Verification`, the model is always written `::Books::Verification` (the bare `Verification` resolves to the service module).

- [ ] **Step 1: Migration**

```bash
cd web-app
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails generate migration RenameOpenLibraryBackfillsToVerifications
```

Body:

```ruby
class RenameOpenLibraryBackfillsToVerifications < ActiveRecord::Migration[8.1]
  def change
    rename_table :books_open_library_backfills, :books_verifications
    rename_column :books_verifications, :outcome, :work_outcome
  end
end
```

`rename_table` and `rename_column` rename the default-named indexes with them. Production has no rows in this table (the backfill never ran there); nothing reads it during a deploy. Run `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate` and confirm `db/schema.rb` shows `create_table "books_verifications"` with `work_outcome` and indexes `index_books_verifications_on_book_id` (unique), `..._on_work_outcome`, `..._on_run_id`.

- [ ] **Step 2: Move the files**

```bash
git mv app/models/books/open_library_backfill.rb app/models/books/verification.rb
git mv app/lib/services/books/ol_backfill app/lib/services/books/verification
git mv app/sidekiq/books/open_library_backfill_job.rb app/sidekiq/books/verification_job.rb
git mv lib/tasks/books/ol_backfill.rake lib/tasks/books/verify.rake
git mv test/models/books/open_library_backfill_test.rb test/models/books/verification_test.rb
git mv test/lib/services/books/ol_backfill test/lib/services/books/verification
git mv test/sidekiq/books/open_library_backfill_job_test.rb test/sidekiq/books/verification_job_test.rb
git mv test/lib/tasks/books_ol_backfill_rake_test.rb test/lib/tasks/books_verify_rake_test.rb
```

- [ ] **Step 3: Rename the constants**

In every moved file and in `mark_legacy.rb` / `mark_legacy_test.rb`:

- `class OpenLibraryBackfill` → `class Verification` (model; update its header comment: "One row per book from the verification pass (spec docs/superpowers/specs/2026-10-16-book-verification-design.md, section 3). Stage 1 is the OL key backfill (2026-10-07 spec).")
- `::Books::OpenLibraryBackfill` / `Books::OpenLibraryBackfill` → `::Books::Verification`
- `module OlBackfill` → `module Verification`; `Services::Books::OlBackfill` → `Services::Books::Verification`
- `class Books::OpenLibraryBackfillJob` → `class Books::VerificationJob`; `Books::OpenLibraryBackfillJob` → `Books::VerificationJob`
- model enum `enum :outcome, {...}` → `enum :work_outcome, {...}` (same values); every `outcome:` keyword, `.outcome`, `outcome ==`, `group(:outcome)`, `outcomes` (→ `work_outcomes`), `where(outcome:` in the moved code and tests → `work_outcome`. Use `grep -rn "outcome" app/lib/services/books/verification test/lib/services/books/verification app/models/books/verification.rb app/lib/services/identifiers test/lib/services/identifiers test/models/books/verification_test.rb` and change only the backfill row's attribute (a `result.data[:outcome]` from another service, if any, is not this attribute).
- In `verify.rake`: tasks become `books:verify`, `books:verify_report`, `books:verify_revert`; usage strings and `puts` text say "verification pass" / `books:verify...`.
- In `books_verify_rake_test.rb`: load `lib/tasks/books/verify.rake`, task names as above, expectations on the new strings.
- `Run::LOCK_BUSY` → `"another verification run is in progress"`; log lines in `run.rb` and the job say "Verification run".
- Leave `DuplicateCandidate`'s `ol_backfill` source value alone (stored data; its label stays "OL backfill").
- Leave `test/support/ol_backfill_helper.rb` and `OlBackfillHelper` as named (it builds Open Library values).

- [ ] **Step 4: Run the moved tests**

Run: `bin/rails test test/lib/services/books/verification/ test/models/books/verification_test.rb test/sidekiq/books/verification_job_test.rb test/lib/tasks/books_verify_rake_test.rb test/lib/services/identifiers/ && CI=1 bin/rails zeitwerk:check`
Expected: PASS (same count as the old files), zeitwerk "all is good". Then `grep -rn "OlBackfill\|OpenLibraryBackfill\|ol_backfill" app lib test` lists only `DuplicateCandidate`'s `ol_backfill` enum value/label, its tests, and `OlBackfillHelper`.

- [ ] **Step 5: Commit**

```bash
git add -A app/models/books app/lib/services/books app/sidekiq/books lib/tasks/books test db app/lib/services/identifiers
git commit -m "Verification: rename the OL key backfill to the book verification pass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Schema: row columns, findings, candidates, associations

**Files:**
- Create: `web-app/db/migrate/<ts>_add_stages_to_books_verifications.rb`
- Create (generators): `Books::VerificationFinding`, `Books::EditionCandidate` + migrations, tests, fixtures
- Modify: `web-app/app/models/books/verification.rb`, `web-app/app/models/books/book.rb`, `web-app/app/models/identifier.rb`
- Test: `web-app/test/models/books/verification_test.rb`, `.../verification_finding_test.rb`, `.../edition_candidate_test.rb`, `web-app/test/models/identifier_test.rb`, `web-app/test/lib/books/book/merger_test.rb`

**Interfaces:**
- Produces: `Books::Verification` enums `cohort` (`pre_import: 0, post_import: 1`, prefix `cohort`), `stage` (`work: 0, identifiers: 1, worldcat: 2, signals: 3, done: 4`, prefix `stage`), columns `stage_error`, `added_count`, `confirmed_count`, `candidate_count`, `wrong_count`, `lump_suspect`, `worldcat_dump_date`, `checked_at`; `has_many :findings`; `SETTLED_FOR_EDITIONS = KEYED_OUTCOMES`.
- `Books::VerificationFinding`: `verification`, `book`, `other_book` (optional), enum `kind` (`added: 0, confirmed: 1, conflict: 2, also_held: 3, wrong_identifier: 4, foreign_work: 5`), `identifier_type` (enum mapped to `Identifier.identifier_types`, prefix `type`), `value`, `identifier_id`, `source` / `previous_source` (enums mapped to `Identifier.sources`, prefixes `source` / `previous`), `work_key`, `evidence` (jsonb).
- `Books::EditionCandidate`: `book`, `edition_key`, `work_key`, `title`, `subtitle`, `language_code`, `publish_year`, `identifiers` (jsonb).
- `Books::Book#verification`, `#verification_findings`, `#edition_candidates`.
- `Identifier.unverified` (`source IS NULL OR source NOT IN verified`).

- [ ] **Step 1: Row columns**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails generate migration AddStagesToBooksVerifications
```

```ruby
class AddStagesToBooksVerifications < ActiveRecord::Migration[8.1]
  def change
    change_table :books_verifications, bulk: true do |t|
      t.integer :cohort, null: false, default: 0
      t.integer :stage, null: false, default: 0
      t.text :stage_error
      t.integer :added_count, null: false, default: 0
      t.integer :confirmed_count, null: false, default: 0
      t.integer :candidate_count, null: false, default: 0
      t.integer :wrong_count, null: false, default: 0
      t.boolean :lump_suspect, null: false, default: false
      t.string :worldcat_dump_date
      t.datetime :checked_at
      t.index :stage
      t.index :lump_suspect
    end
  end
end
```

- [ ] **Step 2: Generate the two models**

```bash
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails generate model Books::VerificationFinding verification:references book:references kind:integer identifier_type:integer value:string identifier_id:bigint source:integer previous_source:integer other_book_id:bigint work_key:string evidence:jsonb
ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails generate model Books::EditionCandidate book:references edition_key:string work_key:string title:string subtitle:string language_code:string publish_year:integer identifiers:jsonb
```

Edit the findings migration to:

```ruby
class CreateBooksVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :books_verification_findings do |t|
      t.references :verification, null: false, foreign_key: {to_table: :books_verifications, on_delete: :cascade}
      t.references :book, null: false, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.integer :kind, null: false
      t.integer :identifier_type, null: false
      t.string :value, null: false
      t.bigint :identifier_id
      t.integer :source
      t.integer :previous_source
      t.references :other_book, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.string :work_key
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :books_verification_findings, [:verification_id, :kind, :identifier_type, :value],
      unique: true, name: "index_books_verification_findings_unique"
    add_index :books_verification_findings, :kind
  end
end
```

(Remove the generator's separate `other_book_id:bigint` column line; `t.references :other_book` creates it with its index.) Edit the candidates migration to:

```ruby
class CreateBooksEditionCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :books_edition_candidates do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.string :edition_key, null: false
      t.string :work_key
      t.string :title
      t.string :subtitle
      t.string :language_code
      t.integer :publish_year
      t.jsonb :identifiers, null: false, default: {}
      t.timestamps
    end
    add_index :books_edition_candidates, [:book_id, :edition_key], unique: true
  end
end
```

Check the generated model files' `table_name` (the `Books` module supplies the `books_` prefix; the tables above must match). Delete any generated fixture rows the tests do not use (keep the files empty: `# empty`), so no fixture references a missing verification.

Run `ANNOTATERB_SKIP_ON_DB_TASKS=1 bin/rails db:migrate`.

- [ ] **Step 3: Write the failing model tests**

`test/models/books/verification_finding_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class VerificationFindingTest < ActiveSupport::TestCase
    setup do
      @book = books_books(:war_and_peace)
      @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "r")
    end

    test "kind, identifier type and sources use the identifier enums" do
      finding = VerificationFinding.create!(verification: @row, book: @book, kind: :confirmed,
        identifier_type: :books_work_isbn13, value: "9780140447934", source: :worldcat, previous_source: :legacy)

      assert finding.confirmed?
      assert finding.type_books_work_isbn13?
      assert finding.source_worldcat?
      assert finding.previous_legacy?
    end

    test "one finding per kind, type and value on a row" do
      attributes = {verification: @row, book: @book, kind: :added, identifier_type: :books_work_isbn13, value: "9780140447934"}
      VerificationFinding.create!(attributes)

      assert_raises(ActiveRecord::RecordNotUnique) { VerificationFinding.create!(attributes) }
    end
  end
end
```

`test/models/books/edition_candidate_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Books
  class EditionCandidateTest < ActiveSupport::TestCase
    test "one candidate per book and edition key" do
      book = books_books(:war_and_peace)
      EditionCandidate.create!(book: book, edition_key: "OL1M", identifiers: {"isbn13" => ["9780000000017"]})

      assert_raises(ActiveRecord::RecordNotUnique) { EditionCandidate.create!(book: book, edition_key: "OL1M") }
    end
  end
end
```

Append to `test/models/books/verification_test.rb`:

```ruby
  test "cohort and stage default to pre_import and work" do
    row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r")

    assert row.cohort_pre_import?
    assert row.stage_work?
    assert_equal [0, 0, 0, 0, false], [row.added_count, row.confirmed_count, row.candidate_count, row.wrong_count, row.lump_suspect]
  end
```

Append to `test/models/identifier_test.rb`:

```ruby
  test "unverified is every source but open_library and worldcat, nil included" do
    book = books_books(:war_and_peace)
    legacy = Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "656", source: :legacy)
    verified = Identifier.create!(identifiable: book, identifier_type: :books_work_oclc_id, value: "1", source: :worldcat)
    unmarked = identifiers(:war_and_peace_isbn13)

    unverified = Identifier.unverified.where(identifiable: book)

    assert_includes unverified, legacy
    assert_includes unverified, unmarked
    refute_includes unverified, verified
  end
```

Append to `test/lib/books/book/merger_test.rb`:

```ruby
      test "the merged-away book's verification, findings and candidates go; the target's stay" do
        source_row = ::Books::Verification.create!(book: @source, work_outcome: :keyed, run_id: "r")
        target_row = ::Books::Verification.create!(book: @target, work_outcome: :keyed, run_id: "r")
        ::Books::VerificationFinding.create!(verification: source_row, book: @source, kind: :added, identifier_type: :books_work_isbn13, value: "1")
        pointing = ::Books::VerificationFinding.create!(verification: target_row, book: @target, kind: :also_held,
          identifier_type: :books_work_isbn13, value: "2", other_book_id: @source.id)
        kept = ::Books::VerificationFinding.create!(verification: target_row, book: @target, kind: :added, identifier_type: :books_work_isbn13, value: "3")
        ::Books::EditionCandidate.create!(book: @source, edition_key: "OL1M")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::Verification.exists?(source_row.id)
        assert_not ::Books::VerificationFinding.exists?(pointing.id)
        assert ::Books::VerificationFinding.exists?(kept.id)
        assert_equal 0, ::Books::EditionCandidate.where(book_id: @source.id).count
      end
```

- [ ] **Step 4: Run them to verify they fail**

Run: `bin/rails test test/models/books/ test/models/identifier_test.rb test/lib/books/book/merger_test.rb`
Expected: FAIL (`undefined method 'cohort_pre_import?'`, `undefined method 'unverified'`, enum methods missing).

- [ ] **Step 5: Implement**

`app/models/books/verification.rb` (add below the existing enums):

```ruby
    has_many :findings, class_name: "Books::VerificationFinding", dependent: :delete_all

    # Spec section 4: pre_import books run by default; post_import ones only with the flag.
    enum :cohort, {pre_import: 0, post_import: 1}, prefix: true
    # The next stage to run (spec section 3). done: all four ran.
    enum :stage, {work: 0, identifiers: 1, worldcat: 2, signals: 3, done: 4}, prefix: true

    # Work outcomes that settled a work whose editions stage 2 reads.
    SETTLED_FOR_EDITIONS = KEYED_OUTCOMES
```

`app/models/books/verification_finding.rb`:

```ruby
module Books
  # One identifier the verification pass wrote, confirmed or flagged (spec section 3).
  class VerificationFinding < ApplicationRecord
    belongs_to :verification, class_name: "Books::Verification"
    belongs_to :book, class_name: "Books::Book"
    belongs_to :other_book, class_name: "Books::Book", optional: true

    enum :kind, {added: 0, confirmed: 1, conflict: 2, also_held: 3, wrong_identifier: 4, foreign_work: 5}
    enum :identifier_type, ::Identifier.identifier_types, prefix: :type
    enum :source, ::Identifier.sources, prefix: :source
    enum :previous_source, ::Identifier.sources, prefix: :previous

    validates :kind, :identifier_type, :value, presence: true
  end
end
```

`app/models/books/edition_candidate.rb`:

```ruby
module Books
  # An Open Library edition of a book's work whose title does not agree with
  # the book: a translation, box set or alternate title. Kept for a later AI
  # check (spec section 3); never read by the finders.
  class EditionCandidate < ApplicationRecord
    belongs_to :book, class_name: "Books::Book"

    validates :edition_key, presence: true
  end
end
```

`app/models/books/book.rb`, next to the other `has_many` lines:

```ruby
  has_one :verification, class_name: "Books::Verification", dependent: :delete
  has_many :verification_findings, class_name: "Books::VerificationFinding", dependent: :delete_all
  has_many :edition_candidates, class_name: "Books::EditionCandidate", dependent: :delete_all
```

(A merge destroys the source book, so these go with it; findings pointing at it through `other_book_id` go by the foreign key's cascade. Verification data is per book and recomputed for the survivor by its own run, so the merger moves none of it.)

`app/models/identifier.rb`, after `scope :verified`:

```ruby
  scope :unverified, -> { where(source: nil).or(where.not(source: VERIFIED_SOURCES)) }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/models/ test/lib/books/book/merger_test.rb && CI=1 bin/rails zeitwerk:check`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add db app/models test/models test/lib/books/book/merger_test.rb test/fixtures/books
git commit -m "Verification: stage columns, findings and edition candidates

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Stamp, counters, the edition check and stage 2

**Files:**
- Create: `app/lib/services/books/verification/{stamp,counts,edition_check,harvest_editions}.rb`
- Modify: `test/support/ol_backfill_helper.rb` (editions in `FakeOlClient`, `ol_edition` builder)
- Test: `test/lib/services/books/verification/{stamp,edition_check,harvest_editions}_test.rb`

**Interfaces:**
- Consumes: `::Books::Verification` / `::Books::VerificationFinding` / `::Books::EditionCandidate` (Task 2), `Identifier.verified`, `Check.titles_agree?`, `Check.their_titles`, `Check.short`, `Check.normalize` (existing `module_function`s), `Books::Isbn.normalize`.
- Produces:
  - `Stamp.call(verification:, type:, value:, source:, evidence: {}) -> Symbol` (`:added`, `:confirmed`, `:conflict`, `:unchanged`); writes `also_held` alongside `:added` when another book holds the value unverified.
  - `Stamp.confirm(verification:, identifier:, source:, evidence: {})` (stage 3 uses it on rows it already found).
  - `Counts.call(verification)` → updates the four counters.
  - `EditionCheck.agrees?(book, work, edition) -> Boolean`, `EditionCheck.year_ok?(book, year) -> Boolean`.
  - `HarvestEditions.call(verification:, client:)`: fetches editions, writes, advances `stage` to `worldcat`.
  - `OlBackfillHelper#ol_edition(key, title:, subtitle: nil, publish_year: nil, isbn13: [], isbn10: [], oclc: [], goodreads: [], language_code: "eng")`; `FakeOlClient.new(..., editions: {work_key => [Edition]})` with `#editions(key)`.

- [ ] **Step 1: Test helper additions**

In `test/support/ol_backfill_helper.rb` add:

```ruby
  def ol_edition(key, title:, subtitle: nil, publish_year: nil, isbn13: [], isbn10: [], oclc: [], goodreads: [], language_code: "eng")
    ::Books::OpenLibrary::Edition.from_record({
      "key" => {"source" => "openlibrary", "key" => key}, "title" => title, "subtitle" => subtitle,
      "publish_year" => publish_year, "language_code" => language_code,
      "isbn13" => isbn13, "isbn10" => isbn10, "oclc" => oclc, "goodreads" => goodreads
    })
  end
```

and in `FakeOlClient`: an `editions: {}` keyword stored as `@editions`, and

```ruby
    def editions(key)
      record([:editions, key])
      raise_next!
      @editions.fetch(key, [])
    end
```

- [ ] **Step 2: Failing tests for Stamp**

`test/lib/services/books/verification/stamp_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class StampTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "r")
        end

        def stamp(value, source: :open_library) = Stamp.call(verification: @row, type: "books_work_isbn13", value: value, source: source, evidence: {"edition_key" => "OL1M"})

        def finding(kind, value) = @row.findings.find_by(kind: kind, value: value)

        test "a value nobody holds is added with an added finding" do
          assert_equal :added, stamp("9780000000017")

          identifier = @book.identifiers.find_by!(identifier_type: :books_work_isbn13, value: "9780000000017")
          assert identifier.source_open_library?
          assert_equal [identifier.id, "OL1M"], [finding(:added, "9780000000017").identifier_id, finding(:added, "9780000000017").evidence["edition_key"]]
        end

        test "a legacy value the book holds is confirmed in place, its old source logged" do
          held = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)

          assert_equal :confirmed, stamp("9780000000017")

          assert held.reload.source_open_library?
          assert_equal "legacy", finding(:confirmed, "9780000000017").previous_source
        end

        test "an unmarked (nil) value the book holds is confirmed too" do
          held = identifiers(:war_and_peace_isbn13)

          assert_equal :confirmed, stamp(held.value)
          assert held.reload.source_open_library?
        end

        test "a value the book holds verified is left alone with no finding" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780000000017", source: :worldcat)

          assert_equal :unchanged, stamp("9780000000017")
          assert_empty @row.findings
        end

        test "a value another book holds verified is not written: conflict" do
          Identifier.create!(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000017", source: :worldcat)

          assert_equal :conflict, stamp("9780000000017")

          refute @book.identifiers.exists?(value: "9780000000017")
          assert_equal @other.id, finding(:conflict, "9780000000017").other_book_id
        end

        test "a value another book holds unverified is written here and flagged also_held; the other book is untouched" do
          theirs = Identifier.create!(identifiable: @other, identifier_type: :books_work_isbn13, value: "9780000000017", source: :legacy)

          assert_equal :added, stamp("9780000000017")

          assert @book.identifiers.exists?(value: "9780000000017")
          assert_equal @other.id, finding(:also_held, "9780000000017").other_book_id
          assert theirs.reload.source_legacy?
        end

        test "stamping twice writes one identifier and one finding" do
          stamp("9780000000017")
          stamp("9780000000017")

          assert_equal 1, @book.identifiers.where(value: "9780000000017").count
          assert_equal 1, @row.findings.where(value: "9780000000017").count
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/verification/stamp_test.rb` → FAIL (`uninitialized constant ...Stamp`).

- [ ] **Step 3: Implement Stamp and Counts**

`app/lib/services/books/verification/stamp.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2's table: one identifier a verified source ties
      # to the book. Writes or confirms it and records the finding. Never
      # touches another book's row. Callers run it inside their stage's
      # transaction.
      module Stamp
        module_function

        def call(verification:, type:, value:, source:, evidence: {})
          book = verification.book
          held = book.identifiers.find_by(identifier_type: type, value: value)
          if held
            return :unchanged if held.source.in?(::Identifier::VERIFIED_SOURCES)

            confirm(verification: verification, identifier: held, source: source, evidence: evidence)
            return :confirmed
          end

          others = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value).where.not(identifiable_id: book.id)
          if (verified_holder = others.verified.order(:identifiable_id).pick(:identifiable_id))
            finding(verification, :conflict, type, value, other_book_id: verified_holder, evidence: evidence)
            return :conflict
          end

          holders = others.order(:identifiable_id).pluck(:identifiable_id)
          identifier = book.identifiers.create!(identifier_type: type, value: value, source: source)
          finding(verification, :added, type, value, identifier_id: identifier.id, source: source, evidence: evidence)
          if holders.any?
            finding(verification, :also_held, type, value, other_book_id: holders.first, evidence: evidence.merge("holders" => holders))
          end
          :added
        end

        def confirm(verification:, identifier:, source:, evidence: {})
          previous = identifier.source
          identifier.update!(source: source)
          finding(verification, :confirmed, identifier.identifier_type, identifier.value,
            identifier_id: identifier.id, source: source, previous_source: previous, evidence: evidence)
        end

        def finding(verification, kind, type, value, **attributes)
          row = ::Books::VerificationFinding.find_or_initialize_by(verification: verification, kind: kind, identifier_type: type, value: value)
          row.assign_attributes(book_id: verification.book_id, **attributes)
          row.save!
          row
        end
      end
    end
  end
end
```

`app/lib/services/books/verification/counts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # The report's counters on the row, recounted from its findings.
      module Counts
        module_function

        def call(verification)
          kinds = verification.findings.group(:kind).count
          verification.update!(
            added_count: kinds.fetch("added", 0),
            confirmed_count: kinds.fetch("confirmed", 0),
            wrong_count: kinds.fetch("wrong_identifier", 0),
            candidate_count: ::Books::EditionCandidate.where(book_id: verification.book_id).count
          )
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/verification/stamp_test.rb` → PASS.

- [ ] **Step 4: Failing tests for EditionCheck**

`test/lib/services/books/verification/edition_check_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class EditionCheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @book.update_columns(first_published_year: 1869, alternate_titles: [])
          @work = ol_work("OL1W", title: "War and Peace")
        end

        def agrees?(title, subtitle: nil, year: nil) = EditionCheck.agrees?(@book, @work, ol_edition("OL1M", title: title, subtitle: subtitle, publish_year: year))

        test "an edition with the book's title agrees" do
          assert agrees?("War and Peace", year: 2007)
          assert agrees?("war and peace")
        end

        test "an edition whose subtitle is ordinary agrees once it is dropped" do
          assert agrees?("War and Peace", subtitle: "A Novel")
          assert agrees?("War and Peace: Complete and Unabridged")
        end

        test "an edition whose dropped subtitle names a set does not agree" do
          refute agrees?("War and Peace", subtitle: "Box Set")
          refute agrees?("War and Peace: The Boxed Set")
          refute agrees?("War and Peace", subtitle: "Volumes 1-4")
          refute agrees?("War and Peace: An Omnibus")
        end

        test "a translation or another title does not agree" do
          refute agrees?("Krieg und Frieden")
          refute agrees?("Anna Karenina")
        end

        test "the work's own title counts as one of ours" do
          @book.update_columns(title: "War & Peace")

          assert agrees?("War and Peace")
        end

        test "an edition dated before the book's first publication does not agree; one year of slack" do
          refute agrees?("War and Peace", year: 1850)
          assert agrees?("War and Peace", year: 1868)
        end

        test "a book with no first-published year skips the year rule" do
          @book.update_columns(first_published_year: nil)

          assert agrees?("War and Peace", year: 1700)
        end
      end
    end
  end
end
```

Run → FAIL (`uninitialized constant ...EditionCheck`).

- [ ] **Step 5: Implement EditionCheck**

`app/lib/services/books/verification/edition_check.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2: does an Open Library edition of the settled
      # work agree with the book? Its title must agree with one of our titles
      # or the work's (Check's rule); a subtitle dropped from the edition to
      # get there must not name a set; and it cannot predate the work.
      module EditionCheck
        module_function

        SET_WORDS = /\b(box(ed)? set|collection|omnibus|trilogy|volumes|books 1)\b/i
        YEAR_SLACK = 1

        def agrees?(book, work, edition)
          title_agrees?(book, work, edition) && year_ok?(book, edition.publish_year)
        end

        def year_ok?(book, year)
          year.nil? || book.first_published_year.nil? || year.to_i >= book.first_published_year - YEAR_SLACK
        end

        def title_agrees?(book, work, edition)
          full, short = Check.their_titles(edition)
          return false if full.nil?

          ours = our_titles(book, work)
          return true if ours.include?(full)
          return !full.delete_prefix(short).match?(SET_WORDS) if short && ours.include?(short)

          # Our title carries a subtitle the edition lacks: nothing was dropped from the edition.
          ours.filter_map { |title| Check.short(title) }.include?(full)
        end

        def our_titles(book, work)
          titles = ([book.title] + Array(book.alternate_titles)).filter_map { |title| Check.normalize(title) }
          titles.concat(Check.their_titles(work).compact) if work
          titles.uniq
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/verification/edition_check_test.rb` → PASS.

- [ ] **Step 6: Failing tests for HarvestEditions**

`test/lib/services/books/verification/harvest_editions_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class HarvestEditionsTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @book.update_columns(first_published_year: 1869)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :identifiers)
          @work = ol_work("OL1W", title: "War and Peace")
        end

        def harvest(editions)
          client = FakeOlClient.new(works: {"OL1W" => @work}, editions: {"OL1W" => editions})
          HarvestEditions.call(verification: @row, client: client)
          @row.reload
        end

        def held(type) = @book.identifiers.where(identifier_type: type).pluck(:value, :source).sort

        test "agreeing editions give work-level ISBNs, OCLC numbers and Goodreads ids as open_library" do
          harvest([ol_edition("OL1M", title: "War and Peace", isbn13: ["978-0-307-26693-4"], isbn10: ["0307266931"], oclc: ["123"], goodreads: ["656"])])

          assert_includes held("books_work_isbn13"), ["9780307266934", "open_library"]
          assert_includes held("books_work_isbn10"), ["0307266931", "open_library"]
          assert_equal [["123", "open_library"]], held("books_work_oclc_id")
          assert_equal [["656", "open_library"]], held("books_work_goodreads_id")
        end

        test "invalid ISBNs are dropped" do
          harvest([ol_edition("OL1M", title: "War and Peace", isbn13: ["9780307266935"], isbn10: ["12345"])])

          refute @book.identifiers.exists?(value: "9780307266935")
          refute @book.identifiers.exists?(value: "12345")
        end

        test "a non-agreeing edition becomes a candidate and writes nothing" do
          harvest([ol_edition("OL2M", title: "Krieg und Frieden", publish_year: 1950, isbn13: ["9783423131681"], language_code: "ger")])

          refute @book.identifiers.exists?(value: "9783423131681")
          candidate = ::Books::EditionCandidate.find_by!(book: @book, edition_key: "OL2M")
          assert_equal ["Krieg und Frieden", "ger", 1950, "OL1W", ["9783423131681"]],
            [candidate.title, candidate.language_code, candidate.publish_year, candidate.work_key, candidate.identifiers["isbn13"]]
        end

        test "the row moves on to worldcat with its counters" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: "656", source: :legacy)

          row = harvest([
            ol_edition("OL1M", title: "War and Peace", goodreads: ["656"], oclc: ["9"]),
            ol_edition("OL2M", title: "Guerre et paix")
          ])

          assert row.stage_worldcat?
          assert_equal [1, 1, 1], [row.added_count, row.confirmed_count, row.candidate_count]
        end

        test "harvesting again changes nothing" do
          editions = [ol_edition("OL1M", title: "War and Peace", oclc: ["9"]), ol_edition("OL2M", title: "Guerre et paix")]
          harvest(editions)
          @row.update!(stage: :identifiers)

          assert_no_difference -> { [Identifier.count, ::Books::VerificationFinding.count, ::Books::EditionCandidate.count] } do
            harvest(editions)
          end
        end

        test "an Open Library error writes nothing and leaves the stage" do
          client = FakeOlClient.new(works: {"OL1W" => @work}, errors: [nil, ::Books::OpenLibrary::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::OpenLibrary::Exceptions::TimeoutError) { HarvestEditions.call(verification: @row, client: client) }
          assert @row.reload.stage_identifiers?
        end
      end
    end
  end
end
```

(`errors: [nil, error]`: the first call, `works_batch`, succeeds; the second, `editions`, raises.) Run → FAIL.

- [ ] **Step 7: Implement HarvestEditions**

`app/lib/services/books/verification/harvest_editions.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2: the settled work's editions. Agreeing ones
      # give trusted work-level identifiers (Stamp); the rest are kept as
      # candidates for a later AI check. Network first, then one transaction
      # that ends by moving the row to worldcat.
      class HarvestEditions
        FIELDS = {
          isbn13: "books_work_isbn13",
          isbn10: "books_work_isbn10",
          oclc: "books_work_oclc_id",
          goodreads: "books_work_goodreads_id"
        }.freeze
        DIGITS = /\A\d+\z/

        def self.call(verification:, client:)
          new(verification, client).call
        end

        def initialize(verification, client)
          @row = verification
          @client = client
          @book = verification.book
        end

        def call
          key = @row.new_key
          work = @client.works_batch([key])[key]
          editions = @client.editions(key)

          ::ActiveRecord::Base.transaction do
            editions.each do |edition|
              if EditionCheck.agrees?(@book, work, edition)
                stamp_values(edition)
              else
                keep_candidate(edition, key)
              end
            end
            Counts.call(@row)
            @row.update!(stage: :worldcat, stage_error: nil)
          end
        end

        private

        def stamp_values(edition)
          evidence = {"edition_key" => edition.key, "title" => [edition.title, edition.subtitle].compact.join(": ")}
          FIELDS.each do |field, type|
            values(edition, field).each do |value|
              Stamp.call(verification: @row, type: type, value: value, source: :open_library, evidence: evidence)
            end
          end
        end

        def values(edition, field)
          raw = Array(edition.public_send(field))
          case field
          when :isbn13 then raw.filter_map { |value| ::Books::Isbn.normalize(value)&.isbn13 }
          when :isbn10 then raw.filter_map { |value| ::Books::Isbn.normalize(value)&.isbn10 }
          else raw.map { |value| value.to_s.strip }.grep(DIGITS)
          end.uniq
        end

        def keep_candidate(edition, work_key)
          candidate = ::Books::EditionCandidate.find_or_initialize_by(book_id: @book.id, edition_key: edition.key)
          candidate.update!(
            work_key: work_key, title: edition.title, subtitle: edition.subtitle, language_code: edition.language_code,
            publish_year: edition.publish_year,
            identifiers: FIELDS.keys.to_h { |field| [field.to_s, Array(edition.public_send(field))] }
          )
        end
      end
    end
  end
end
```

Note the `isbn10` branch: `Books::Isbn.normalize` of a valid ISBN-13 starting 979 returns `isbn10: nil`, which `filter_map` drops; an edition's `isbn10` list holds 10-digit values, which normalize to themselves.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/verification/ test/lint/identifier_source_test.rb`
Expected: PASS (the lint sees `source:` in `Stamp`'s `create!` and in the `update!` calls).

- [ ] **Step 9: Commit**

```bash
git add app/lib/services/books/verification test/lib/services/books/verification test/support/ol_backfill_helper.rb
git commit -m "Verification: stage 2, identifiers from agreeing Open Library editions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The WorldCat check and stage 3

**Files:**
- Create: `app/lib/services/books/verification/{world_cat_check,confirm_with_world_cat}.rb`
- Modify: `test/support/ol_backfill_helper.rb` (`FakeWcClient`, `wc_record`)
- Test: `test/lib/services/books/verification/{world_cat_check,confirm_with_world_cat}_test.rb`

**Interfaces:**
- Consumes: `Stamp`, `Counts` (Task 3), `Identifier.unverified` (Task 2), `Check.titles_agree?` / `Check.authors_agree?`, `EditionCheck.year_ok?`, `Books::WorldCat::Record`.
- Produces:
  - `WorldCatCheck.agrees?(book, record) -> Boolean`; `WorldCatCheck.clearly_different?(book, record) -> Boolean` (false when the record has no title or no creator, or the book has no authors).
  - `ConfirmWithWorldCat.call(verification:, client:, dump_date:)`: advances `stage` to `signals`, sets `worldcat_dump_date`.
  - `ConfirmWithWorldCat::MAX_WORLDCAT_ISBNS = 50`.
  - Helpers: `wc_record(oclc:, title:, creator: nil, contributors: [], year: nil, isbn13s: [])`; `FakeWcClient.new(records: {isbn13 => [Record]}, version: {dump_date: "2025-09-04"}, errors: [])` with `#record_by_isbn(isbn)`, `#version`, `#calls`.

- [ ] **Step 1: Helper additions**

```ruby
  def wc_record(oclc:, title:, creator: nil, contributors: [], year: nil, isbn13s: [])
    ::Books::WorldCat::Record.from_hash({"oclc" => oclc, "title" => title, "creator" => creator,
      "contributors" => contributors, "year" => year, "isbn13s" => isbn13s})
  end

  class FakeWcClient
    attr_reader :calls

    def initialize(records: {}, version: {dump_date: "2025-09-04"}, errors: [])
      @records = records
      @version = version
      @errors = errors.dup
      @calls = []
    end

    def record_by_isbn(isbn)
      @calls << [:record_by_isbn, isbn]
      error = @errors.shift
      raise error if error

      @records.fetch(isbn, [])
    end

    def version
      @calls << [:version]
      @version
    end
  end
```

- [ ] **Step 2: Failing tests for WorldCatCheck**

`test/lib/services/books/verification/world_cat_check_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class WorldCatCheckTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # Leo Tolstoy
          @book.update_columns(first_published_year: 1869)
        end

        def record(**overrides) = wc_record(oclc: 1, title: "War and peace", creator: "Leo Tolstoy", year: 2007, **overrides)

        test "a record agreeing on title, creator and year agrees" do
          assert WorldCatCheck.agrees?(@book, record)
        end

        test "WorldCat's ' : ' subtitle form and lowercase are tolerated" do
          assert WorldCatCheck.agrees?(@book, record(title: "War and peace : a novel"))
        end

        test "an inverted creator with dates still matches" do
          assert WorldCatCheck.agrees?(@book, record(creator: "Tolstoy, Leo, 1828-1910."))
          assert WorldCatCheck.agrees?(@book, record(creator: nil, contributors: ["Tolstoy, Leo (Lev Nikolaevich)"]))
        end

        test "a garbled record never agrees" do
          refute WorldCatCheck.agrees?(@book, record(title: "War and peace", creator: "L©Øev Tol©Østoy"))
        end

        test "a placeholder title does not agree" do
          refute WorldCatCheck.agrees?(@book, record(title: "Untitled Leo Tolstoy novel"))
        end

        test "a record dated before the book does not agree" do
          refute WorldCatCheck.agrees?(@book, record(year: 1800))
        end

        test "clearly_different needs both title and creator to disagree" do
          assert WorldCatCheck.clearly_different?(@book, record(title: "Gloriana", creator: "Michael Moorcock"))
          refute WorldCatCheck.clearly_different?(@book, record(title: "Gloriana"))
          refute WorldCatCheck.clearly_different?(@book, record(creator: "Michael Moorcock"))
        end

        test "a record with no creator is unknown, not clearly different" do
          refute WorldCatCheck.clearly_different?(@book, record(title: "Gloriana", creator: nil))
        end
      end
    end
  end
end
```

Run → FAIL.

- [ ] **Step 3: Implement WorldCatCheck**

`app/lib/services/books/verification/world_cat_check.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 3: a WorldCat record agrees with the book when
      # its title, its creator (or a contributor) and its year all agree. The
      # record is reshaped into what Check compares: WorldCat writes
      # "Title : subtitle" and "Last, First, 1828-1910." creators.
      module WorldCatCheck
        module_function

        WorkLike = Data.define(:title, :subtitle, :author_names, :author_keys)
        DATES = /,?\s*\d{4}\s*-\s*(\d{4})?\s*\.?\s*\z/
        PARENTHESES = /\s*\([^)]*\)/

        def agrees?(book, record)
          work = work_like(record)
          return false if work.title.blank? || work.author_names.empty?

          Check.titles_agree?(book, work) && Check.authors_agree?(book, work) && EditionCheck.year_ok?(book, record.year)
        end

        # Both title and creator disagree. A missing title or creator, or a
        # book with no authors, is unknown.
        def clearly_different?(book, record)
          work = work_like(record)
          return false if work.title.blank? || work.author_names.empty? || book.authors.empty?

          !Check.titles_agree?(book, work) && !Check.authors_agree?(book, work)
        end

        def work_like(record)
          title, _, subtitle = record.title.to_s.partition(" : ")
          title = title.sub(%r{\s*/\s*\z}, "").strip
          subtitle = record.subtitle.presence || subtitle.sub(%r{\s*/.*\z}, "").strip.presence
          WorkLike.new(title: title.presence, subtitle: subtitle, author_names: names(record), author_keys: [])
        end

        def names(record)
          raw = [record.creator, *Array(record.contributors)].map { |name| name.is_a?(Hash) ? name["name"] : name }
          raw.compact.flat_map { |name| variants(name.to_s) }.uniq
        end

        def variants(name)
          cleaned = name.gsub(PARENTHESES, "").sub(DATES, "").strip.chomp(",").chomp(".").strip
          return [] if cleaned.blank?

          last, comma, first = cleaned.partition(",")
          comma.empty? ? [cleaned] : [cleaned, "#{first.strip} #{last.strip}"]
        end
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/verification/world_cat_check_test.rb` → PASS. (If the mojibake case agrees because `Check.compact` strips the © characters down to "levtolstoy"-like letters, tighten `variants` to reject names containing `©` or the Unicode replacement character `�` and record that as a ruling.)

- [ ] **Step 4: Failing tests for ConfirmWithWorldCat**

`test/lib/services/books/verification/confirm_with_world_cat_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class ConfirmWithWorldCatTest < ActiveSupport::TestCase
        include OlBackfillHelper

        ISBN13 = "9780307266934"
        ISBN10 = "0307266931"

        setup do
          @book = books_books(:war_and_peace) # holds 9780140447934 (fixture, nil source)
          @book.update_columns(first_published_year: 1869)
          @row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :worldcat)
        end

        def agreeing(oclc: 77) = wc_record(oclc: oclc, title: "War and peace", creator: "Tolstoy, Leo", year: 2007)

        def confirm(records)
          ConfirmWithWorldCat.call(verification: @row, client: FakeWcClient.new(records: records), dump_date: "2025-09-04")
          @row.reload
        end

        test "an agreeing record confirms both forms of the ISBN as worldcat and adds its OCLC number" do
          isbn13 = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)
          isbn10 = Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn10, value: ISBN10, source: :legacy)

          row = confirm(ISBN13 => [agreeing])

          assert isbn13.reload.source_worldcat?
          assert isbn10.reload.source_worldcat?
          assert_equal "worldcat", @book.identifiers.find_by!(identifier_type: :books_work_oclc_id, value: "77").source
          assert_equal [2, 1], [row.confirmed_count, row.added_count]
          assert row.stage_signals?
          assert_equal "2025-09-04", row.worldcat_dump_date
        end

        test "records that all clearly differ make a wrong_identifier finding and remove nothing" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)

          row = confirm(ISBN13 => [wc_record(oclc: 5, title: "Gloriana", creator: "Moorcock, Michael", year: 1978)])

          assert @book.identifiers.exists?(value: ISBN13)
          finding = row.findings.find_by!(kind: :wrong_identifier)
          assert_equal [ISBN13, "Gloriana"], [finding.value, finding.evidence["records"].first["title"]]
          assert_equal 1, row.wrong_count
        end

        test "a record disagreeing on one side only, or no record, changes nothing" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)

          row = confirm(ISBN13 => [wc_record(oclc: 5, title: "Gloriana", creator: "Leo Tolstoy", year: 2007)])

          assert_empty row.findings
          assert row.stage_signals?
        end

        test "verified ISBNs are not looked up; the fixture's unmarked one is" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :open_library)
          client = FakeWcClient.new

          ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "2025-09-04")

          assert_equal [[:record_by_isbn, "9780140447934"]], client.calls
        end

        test "at most MAX_WORLDCAT_ISBNS are looked up" do
          stub_const = ConfirmWithWorldCat::MAX_WORLDCAT_ISBNS
          client = FakeWcClient.new
          ConfirmWithWorldCat.stubs(:max_isbns).returns(1)

          ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "2025-09-04")

          assert_equal 50, stub_const
          assert_equal 1, client.calls.size
        end

        test "a WorldCat error writes nothing and leaves the stage" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: ISBN13, source: :legacy)
          client = FakeWcClient.new(errors: [::Books::WorldCat::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::WorldCat::Exceptions::TimeoutError) { ConfirmWithWorldCat.call(verification: @row, client: client, dump_date: "x") }
          assert @row.reload.stage_worldcat?
        end
      end
    end
  end
end
```

Run → FAIL.

- [ ] **Step 5: Implement ConfirmWithWorldCat**

`app/lib/services/books/verification/confirm_with_world_cat.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 3: the book's held ISBNs not yet verified, each
      # looked up in WorldCat (one GET /isbns per ISBN, ~2.7 s on the home
      # server). An agreeing record confirms the ISBN (both forms) as
      # worldcat and adds its OCLC number; records that all clearly differ
      # are a wrong_identifier finding. Runs whatever stage 1 decided.
      class ConfirmWithWorldCat
        MAX_WORLDCAT_ISBNS = 50
        ISBN_TYPES = %w[books_work_isbn13 books_work_isbn10].freeze

        def self.call(verification:, client:, dump_date:)
          new(verification, client, dump_date).call
        end

        def self.max_isbns = MAX_WORLDCAT_ISBNS

        def initialize(verification, client, dump_date)
          @row = verification
          @client = client
          @dump_date = dump_date
          @book = verification.book
        end

        def call
          held = @book.identifiers.unverified.where(identifier_type: ISBN_TYPES).order(:id).to_a
          isbns = held.filter_map { |identifier| ::Books::Isbn.normalize(identifier.value)&.isbn13 }.uniq.first(self.class.max_isbns)
          records = isbns.to_h { |isbn| [isbn, @client.record_by_isbn(isbn)] }

          ::ActiveRecord::Base.transaction do
            records.each { |isbn, found| judge(isbn, found, held) }
            Counts.call(@row)
            @row.update!(stage: :signals, stage_error: nil, worldcat_dump_date: @dump_date)
          end
        end

        private

        def judge(isbn, found, held)
          agreeing = found.select { |record| WorldCatCheck.agrees?(@book, record) }
          if agreeing.any?
            evidence = {"records" => agreeing.map { |record| summary(record) }}
            forms = ::Books::Isbn.normalize(isbn)
            held.select { |identifier| [forms.isbn13, forms.isbn10].include?(identifier.value) }.each do |identifier|
              Stamp.confirm(verification: @row, identifier: identifier, source: :worldcat, evidence: evidence)
            end
            agreeing.map(&:oclc).compact.uniq.each do |oclc|
              Stamp.call(verification: @row, type: "books_work_oclc_id", value: oclc.to_s, source: :worldcat, evidence: evidence)
            end
          elsif found.any? && found.all? { |record| WorldCatCheck.clearly_different?(@book, record) }
            Stamp.finding(@row, :wrong_identifier, "books_work_isbn13", isbn, evidence: {"records" => found.map { |record| summary(record) }})
          end
        end

        def summary(record)
          {"oclc" => record.oclc, "title" => record.title, "creator" => record.creator, "year" => record.year}
        end
      end
    end
  end
end
```

Replace the test's `stubs(:max_isbns)` approach if it reads awkwardly: the point is that the cap exists and is applied; keep `self.class.max_isbns` as the one seam.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/verification/ test/lint/identifier_source_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/books/verification test/lib/services/books/verification test/support/ol_backfill_helper.rb
git commit -m "Verification: stage 3, held ISBNs confirmed against WorldCat

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Stage 4, signals

**Files:**
- Create: `app/lib/services/books/verification/signals.rb`
- Test: `test/lib/services/books/verification/signals_test.rb`

**Interfaces:**
- Consumes: `Identifier.unverified`, `Stamp.finding`, `Counts`, `Check.titles_agree?`, the OL client's `identifier` / `works_batch`.
- Produces: `Signals.call(verification:, client:)`: records `foreign_work` findings, sets `lump_suspect`, `checked_at`, `stage: :done`. `Signals::MAX_SIGNAL_LOOKUPS = 20`, `Signals::CONCURRENCY = 5`.

- [ ] **Step 1: Failing tests**

`test/lib/services/books/verification/signals_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class SignalsTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # fixture isbn13 9780140447934, unmarked
          @row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "r", stage: :signals)
        end

        def hold(type, value) = Identifier.create!(identifiable: @book, identifier_type: type, value: value, source: :legacy)

        def run_signals(hits:, works:)
          Signals.call(verification: @row, client: FakeOlClient.new(hits: hits, works: works))
          @row.reload
        end

        test "identifiers pointing at two other works with other titles make a lump suspect" do
          hold(:books_work_goodreads_id, "1")
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")], ["goodreads", "1"] => [ol_hit("OL8W", id_type: "goodreads", value: "1")]},
            works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina"), "OL8W" => ol_work("OL8W", title: "Resurrection")}
          )

          assert row.lump_suspect
          assert_equal %w[OL7W OL8W], row.findings.foreign_work.order(:work_key).pluck(:work_key)
          assert_equal "Anna Karenina", row.findings.find_by!(work_key: "OL7W").evidence["title"]
          assert row.stage_done?
          assert_not_nil row.checked_at
        end

        test "one foreign work is recorded but is not a lump" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL7W")]}, works: {"OL7W" => ol_work("OL7W", title: "Anna Karenina")})

          assert_equal 1, row.findings.foreign_work.count
          refute row.lump_suspect
        end

        test "the settled work, its duplicates and its redirects are not foreign; a same-title work is ignored" do
          Identifier.create!(identifiable: @book, identifier_type: :books_work_openlibrary_duplicate_id, value: "OL2W", source: :open_library)
          hold(:books_work_goodreads_id, "1")
          hold(:books_work_goodreads_id, "2")
          redirected = ::Books::OpenLibrary::IdentifierHit.new(work_key: "OL3W", source: "openlibrary", redirected_from: ["OL1W"],
            edition_keys: [], id_type: "goodreads", value: "2")
          row = run_signals(
            hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")], ["goodreads", "1"] => [ol_hit("OL2W", id_type: "goodreads", value: "1")],
                   ["goodreads", "2"] => [redirected]},
            works: {}
          )

          assert_empty row.findings.foreign_work
        end

        test "an unsure book has no work to exclude: titles alone decide" do
          @row.update!(work_outcome: :unsure, new_key: nil)
          row = run_signals(hits: {["isbn13", "9780140447934"] => [ol_hit("OL9W")]}, works: {"OL9W" => ol_work("OL9W", title: "War and Peace")})

          assert_empty row.findings.foreign_work
        end

        test "verified identifiers are not looked up" do
          identifiers(:war_and_peace_isbn13).update!(source: :worldcat)
          client = FakeOlClient.new

          Signals.call(verification: @row, client: client)

          assert_empty client.calls
        end

        test "an unknown identifier (404) is no hit" do
          row = run_signals(hits: {["isbn13", "9780140447934"] => ::Books::OpenLibrary::Exceptions::NotFoundError.new("no", status_code: 404)}, works: {})

          assert row.stage_done?
        end
      end
    end
  end
end
```

(Check `NotFoundError`'s constructor in `app/lib/books/open_library/exceptions.rb` and build it the way `lookup_test.rb` does.) Run → FAIL.

- [ ] **Step 2: Implement**

`app/lib/services/books/verification/signals.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 4: recorded, never acted on. The book's held
      # ISBNs and Goodreads ids that are still not verified are looked up in
      # Open Library; one that points at another work whose title disagrees
      # with ours is a foreign_work finding. Two or more distinct foreign
      # works make the book a lump suspect ("X Men" holding several volumes,
      # an omnibus holding its parts' ISBNs).
      class Signals
        MAX_SIGNAL_LOOKUPS = 20
        CONCURRENCY = 5
        TYPES = {
          "books_work_isbn13" => "isbn13",
          "books_work_isbn10" => "isbn10",
          "books_work_goodreads_id" => "goodreads"
        }.freeze
        NO_HIT_STATUSES = [400, 422].freeze

        def self.call(verification:, client:)
          new(verification, client).call
        end

        def initialize(verification, client)
          @row = verification
          @client = client
          @book = verification.book
        end

        def call
          held = @book.identifiers.unverified.where(identifier_type: TYPES.keys).order(:id).limit(MAX_SIGNAL_LOOKUPS).pluck(:identifier_type, :value)
          hits = lookups(held).flat_map { |(type, value), found| found.map { |hit| [type, value, hit] } }
          foreign = hits.reject { |_type, _value, hit| ours?(hit) }
          works = foreign.empty? ? {} : @client.works_batch(foreign.map { |_t, _v, hit| hit.work_key }.uniq)
          foreign = foreign.select { |_t, _v, hit| (work = works[hit.work_key]) && !Check.titles_agree?(@book, work) }

          ::ActiveRecord::Base.transaction do
            foreign.each do |type, value, hit|
              Stamp.finding(@row, :foreign_work, type, value, work_key: hit.work_key, evidence: {"title" => works[hit.work_key].title})
            end
            Counts.call(@row)
            @row.update!(stage: :done, stage_error: nil, checked_at: Time.current,
              lump_suspect: foreign.map { |_t, _v, hit| hit.work_key }.uniq.size >= 2)
          end
        end

        private

        def excluded_keys
          @excluded_keys ||= begin
            keys = @book.identifiers.where(identifier_type: :books_work_openlibrary_duplicate_id).pluck(:value)
            keys << @row.new_key if @row.new_key.present? && ::Books::Verification::SETTLED_FOR_EDITIONS.include?(@row.work_outcome)
            keys
          end
        end

        def ours?(hit) = excluded_keys.include?(hit.work_key) || Array(hit.redirected_from).intersect?(excluded_keys)

        # [[type, value], [hits]] pairs, CONCURRENCY lookups at a time. The
        # threads touch no database connection.
        def lookups(held)
          held.each_slice(CONCURRENCY).flat_map do |slice|
            threads = slice.map do |type, value|
              Thread.new { [[type, value], hits_for(TYPES.fetch(type), value)] }
            end
            threads.map(&:value)
          end
        end

        def hits_for(type, value)
          @client.identifier(type, value)
        rescue ::Books::OpenLibrary::Exceptions::ClientError => e
          raise unless e.is_a?(::Books::OpenLibrary::Exceptions::NotFoundError) || NO_HIT_STATUSES.include?(e.status_code)

          []
        end
      end
    end
  end
end
```

`Thread#value` re-raises a thread's exception in the caller, so an Open Library outage propagates to the run as in the fast pass.

- [ ] **Step 3: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/verification/signals_test.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add app/lib/services/books/verification/signals.rb test/lib/services/books/verification/signals_test.rb
git commit -m "Verification: stage 4, foreign-work signals and lump suspects

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Cohorts, VerifyBook, the run, the job and the rake task

**Files:**
- Create: `app/lib/services/books/verification/{cohort,verify_book}.rb`
- Modify: `app/lib/services/books/verification/{apply_book,run}.rb`, `app/sidekiq/books/verification_job.rb`, `lib/tasks/books/verify.rake`
- Test: `test/lib/services/books/verification/{cohort,verify_book,run,apply_book}_test.rb`, `test/sidekiq/books/verification_job_test.rb`, `test/lib/tasks/books_verify_rake_test.rb`

**Interfaces:**
- Consumes: Tasks 2-5.
- Produces:
  - `Cohort::FIRST_POST_IMPORT_ID = 16_572`; `Cohort.for(book_id) -> :pre_import | :post_import`; `Cohort.post_import_range -> Range`.
  - `ApplyBook.call(book:, client:, run_id:, cohort: :pre_import)`: also writes `cohort` and `stage` (`identifiers` when the outcome is in `SETTLED_FOR_EDITIONS`, else `worldcat`) in its transaction.
  - `VerifyBook.call(book:, ol_client:, wc_client:, run_id:, wc_dump_date:) -> Result` (`data`: `VerifyBook::Outcome` with `row` and `via_resolve`).
  - `Run.call(limit:, run_id:, flags: [], client: nil, wc_client: nil, sleeper: nil, scope: nil)`; `Run::FLAGS = %w[post_import unranked retry_unsure recheck]`.
  - `Books::VerificationJob#perform(limit, run_id, flags = [])`.
  - Rake `books:verify[<count>|all,<flag>,...]`.

- [ ] **Step 1: Cohort, test first**

`test/lib/services/books/verification/cohort_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class CohortTest < ActiveSupport::TestCase
        test "legacy books created after the Goodreads imports feature are post_import" do
          assert_equal :pre_import, Cohort.for(16_571)
          assert_equal :post_import, Cohort.for(16_572)
          assert_equal :post_import, Cohort.for(249_999)
        end

        test "new-app books, above the reserved ceiling, are pre_import" do
          assert_equal :pre_import, Cohort.for(250_000)
        end
      end
    end
  end
end
```

`app/lib/services/books/verification/cohort.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 4, amended: legacy book ids are strictly monotonic with
      # created_at, and the first one created on or after the Goodreads
      # imports feature (2024-09-09 03:22:31 UTC) is 16,572 (measured on the
      # legacy database 2026-10-16: no exceptions either side). New-app books
      # start at the reserved ceiling and count as pre_import.
      module Cohort
        module_function

        FIRST_POST_IMPORT_ID = 16_572

        def post_import_range = FIRST_POST_IMPORT_ID...::Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

        def for(book_id) = post_import_range.cover?(book_id) ? :post_import : :pre_import
      end
    end
  end
end
```

Run: `bin/rails test test/lib/services/books/verification/cohort_test.rb` → FAIL first (before creating the file), then PASS.

- [ ] **Step 2: ApplyBook writes cohort and stage, test first**

Append to `test/lib/services/books/verification/apply_book_test.rb`:

```ruby
        test "the row carries the cohort and moves to identifiers when a work settled" do
          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1", cohort: :post_import).data

          assert row.cohort_post_import?
          assert row.stage_identifiers?
        end

        test "an unsure book moves straight to worldcat" do
          row = ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1").data

          assert row.stage_worldcat?
          assert row.cohort_pre_import?
        end

        test "a failed lookup leaves the row at work" do
          row = ApplyBook.record_failure(book: @book, run_id: "run-1", error: "boom")

          assert row.stage_work?
        end
```

Run → FAIL (`unknown keyword: :cohort`). In `apply_book.rb`: `self.call(book:, client:, run_id:, cohort: :pre_import)` → `new(book, client, run_id, cohort)`; store `@cohort`; in `call`'s `row.assign_attributes(decide(answer).merge(...))` add `cohort: @cohort` and, after `decide`, the stage:

```ruby
            decided = decide(answer)
            stage = ::Books::Verification::SETTLED_FOR_EDITIONS.include?(decided[:work_outcome].to_s) ? :identifiers : :worldcat
            row.assign_attributes(decided.merge(
              cohort: @cohort, stage: stage, stage_error: nil,
              lookup: answer.lookup, run_id: @run_id, attempts: attempts, error: nil, confirmed_on_abstain: answer.confirm_only,
              dump_date: answer.source_version&.dig(:dump_date), matcher_version: answer.source_version&.dig(:matcher_version)
            ))
```

(Task 1 renamed the `outcome:` keys in `decide` and `unchanged` to `work_outcome:`.) Run → PASS.

- [ ] **Step 3: VerifyBook, test first**

`test/lib/services/books/verification/verify_book_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
      class VerifyBookTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace)
          @wc = FakeWcClient.new
        end

        def verify(ol) = VerifyBook.call(book: @book, ol_client: ol, wc_client: @wc, run_id: "run-1", wc_dump_date: "2025-09-04")

        test "a new book runs all four stages and ends done" do
          work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          ol = FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit("OL1W")]}, works: {"OL1W" => work},
            editions: {"OL1W" => [ol_edition("OL1M", title: "War and Peace", oclc: ["9"])]})

          result = verify(ol)

          assert result.success?
          assert result.data.stage_done?
          assert_equal "open_library", @book.identifiers.find_by!(identifier_type: :books_work_oclc_id).source
        end

        test "a row stopped at worldcat resumes there and never repeats stages 1 and 2" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :worldcat)
          ol = FakeOlClient.new

          verify(ol)

          assert row.reload.stage_done?
          assert ol.calls.none? { |call| %i[resolve editions].include?(call.first) }
          assert_equal "run-1", row.run_id
        end

        test "a WorldCat error stops the book at worldcat with its earlier stages kept" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :identifiers)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "1")
          ol = FakeOlClient.new(works: {"OL1W" => ol_work("OL1W", title: "War and Peace")}, editions: {"OL1W" => []})
          @wc = FakeWcClient.new(errors: [::Books::WorldCat::Exceptions::TimeoutError.new("slow")])

          assert_raises(::Books::WorldCat::Exceptions::TimeoutError) { verify(ol) }
          assert row.reload.stage_worldcat?
          assert_equal 1, row.findings.count
        end
      end
    end
  end
end
```

Run → FAIL. `app/lib/services/books/verification/verify_book.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module Verification
      # One book through the stages it has left (spec section 3): stage 1 when
      # it has no settled row, then whatever `stage` says. Each stage commits
      # on its own, so an error stops the book at the stage that raised and a
      # later run resumes there. Service errors propagate to Run.
      class VerifyBook
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        Outcome = ::Data.define(:row, :via_resolve)

        def self.call(book:, ol_client:, wc_client:, run_id:, wc_dump_date:)
          new(book, ol_client, wc_client, run_id, wc_dump_date).call
        end

        def initialize(book, ol_client, wc_client, run_id, wc_dump_date)
          @book = book
          @ol = ol_client
          @wc = wc_client
          @run_id = run_id
          @wc_dump_date = wc_dump_date
        end

        def call
          row = ::Books::Verification.find_by(book_id: @book.id)
          via_resolve = false
          if row.nil? || row.stage_work?
            applied = ApplyBook.call(book: @book, client: @ol, run_id: @run_id, cohort: Cohort.for(@book.id))
            return Result.new(success?: false, data: nil, errors: applied.errors) unless applied.success?

            row = applied.data
            via_resolve = row.via_resolve?
          end
          row.update!(run_id: @run_id) unless row.run_id == @run_id

          HarvestEditions.call(verification: row, client: @ol) if row.reload.stage_identifiers?
          ConfirmWithWorldCat.call(verification: row, client: @wc, dump_date: @wc_dump_date) if row.reload.stage_worldcat?
          Signals.call(verification: row, client: @ol) if row.reload.stage_signals?

          Result.new(success?: true, data: Outcome.new(row: row.reload, via_resolve: via_resolve), errors: [])
        end
      end
    end
  end
end
```

Run → PASS.

- [ ] **Step 4: Run, test first**

Rework `test/lib/services/books/verification/run_test.rb`: its `record_applies` helper stubs `ApplyBook.call`; change it to stub `VerifyBook.call` the same way (create a `::Books::Verification` row with `stage: :done`, return `VerifyBook::Result` with `data: VerifyBook::Outcome.new(row:, via_resolve: false)`), and `run_backfill` to `Run.call(limit: nil, run_id: "run-1", client: @client, wc_client: FakeWcClient.new, sleeper: no_sleep, scope: @scope, **options)`. Keep every existing ordering, limit, lock, retry and failure test passing under the new names. Then add:

```ruby
        test "by default only ranked pre_import books are taken" do
          order = record_applies
          rank(@war, 1)
          rank(@crime, 2)
          Cohort.stubs(:post_import_range).returns(@crime.id..@crime.id)

          run_backfill(scope: nil)

          assert_equal [@war.id], order
        end

        test "unranked continues past the ranking; post_import includes that cohort" do
          order = record_applies
          rank(@war, 1)
          Cohort.stubs(:post_import_range).returns(@crime.id..@crime.id)

          run_backfill(scope: nil, flags: %w[unranked post_import])

          assert_includes order, @crime.id
          assert_includes order, @got.id
        end

        test "a row stopped at a later stage is taken again; a done row is not" do
          order = record_applies
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "old", stage: :worldcat)
          ::Books::Verification.create!(book: @crime, work_outcome: :keyed, run_id: "old", stage: :done)

          run_backfill

          assert_includes order, @war.id
          refute_includes order, @crime.id
        end

        test "recheck takes done books that gained a legacy identifier since checked_at, from stage 2 or 3" do
          VerifyBook.stubs(:call).returns(VerifyBook::Result.new(success?: true, data: VerifyBook::Outcome.new(row: nil, via_resolve: false), errors: []))
          settled = ::Books::Verification.create!(book: @war, work_outcome: :keyed, run_id: "old", stage: :done, checked_at: 1.day.ago)
          unsure = ::Books::Verification.create!(book: @crime, work_outcome: :unsure, run_id: "old", stage: :done, checked_at: 1.day.ago)
          quiet = ::Books::Verification.create!(book: @got, work_outcome: :keyed, run_id: "old", stage: :done, checked_at: 1.minute.from_now)
          [@war, @crime, @got].each { |book| Identifier.create!(identifiable: book, identifier_type: :books_work_isbn10, value: "0140447938", source: :legacy) }

          run_backfill(flags: %w[recheck])

          assert settled.reload.stage_identifiers?
          assert unsure.reload.stage_worldcat?
          assert quiet.reload.stage_done?
        end

        test "a WorldCat outage after the retries stops the run and leaves the book at its stage" do
          ::Books::Verification.create!(book: @war, work_outcome: :keyed, new_key: "OL1W", run_id: "old", stage: :worldcat)
          VerifyBook.stubs(:call).raises(::Books::WorldCat::Exceptions::ServerError.new("down", status_code: 503))
          sleeps = []

          result = Run.call(limit: nil, run_id: "run-1", client: @client, wc_client: FakeWcClient.new, sleeper: ->(s) { sleeps << s },
            scope: ::Books::Book.where(id: @war.id))

          assert result.data[:stopped]
          assert_equal Run::RETRY_DELAYS, sleeps
          row = ::Books::Verification.find_by!(book: @war)
          assert row.stage_worldcat?
          assert_match(/ServerError/, row.stage_error)
        end
```

(Build `ServerError` the way the WorldCat client tests do; check its constructor in `app/lib/books/world_cat/exceptions.rb`. Check the fixture book ids fall outside 16,572...250,000 (`bin/rails runner` is not needed: fixture ids are hashed from names, so assert it in a guard test `assert_equal :pre_import, Cohort.for(books_books(:war_and_peace).id)` and, if a fixture lands in the range, stub `Cohort.post_import_range` to an empty range in `setup`). The tests move the post-import range onto one fixture with `Cohort.stubs(:post_import_range)`.) Run → FAIL.

- [ ] **Step 5: Implement the Run changes**

In `run.rb`:

- Signature: `self.call(limit:, run_id:, flags: [], client: nil, wc_client: nil, sleeper: nil, scope: nil)`. `FLAGS = %w[post_import unranked retry_unsure recheck].freeze`; raise `ArgumentError` on an unknown flag. Store `@post_import`, `@unranked`, `@retry_unsure`, `@recheck`. `@wc_client = wc_client || ::Books::WorldCat::Client.new(config: ::Books::WorldCat::Configuration.new(timeout: WORLDCAT_TIMEOUT))` with `WORLDCAT_TIMEOUT = 15` (a popular ISBN takes 3-5 s; the client's default is 5).
- `@scope = scope || ::Books::Book.all` stays; the ranked restriction is applied in `next_ids` unless `@unranked`.
- In `run_locked`: fetch `@wc_dump_date = @wc_client.version[:dump_date]` once (inside the rescue, so a WorldCat outage at start stops the run with an error); count done as rows with `run_id: @run_id` and `work_outcome` not failed.
- `process(book)` calls `prepare(book)` then `VerifyBook.call(book:, ol_client: @client, wc_client: @wc_client, run_id: @run_id, wc_dump_date: @wc_dump_date)`; pause on `result.data&.via_resolve`; rescue `::Books::OpenLibrary::Exceptions::Error, ::Books::WorldCat::Exceptions::Error`; `book_specific?` checks both namespaces' `ParseError` and `ClientError` with 400/422; on giving up (or a book-specific error), call `record_stop(book, error)`:

```ruby
        # Stage 1 failing logs the book failed, as before; a later stage keeps
        # the row's stage and records why it stopped.
        def record_stop(book, message)
          row = ::Books::Verification.find_by(book_id: book.id)
          if row.nil? || row.stage_work?
            ApplyBook.record_failure(book: book, run_id: @run_id, error: message)
          else
            row.update!(stage_error: message.truncate(1000), run_id: @run_id)
          end
        end
```

- `prepare(book)`: for a row picked by `retry_unsure` (unsure, older version) set `stage: :work`; for a row picked by `recheck` (done, legacy identifier newer than `checked_at`) set `stage: SETTLED_FOR_EDITIONS.include?(row.work_outcome) ? :identifiers : :worldcat`. Use the same SQL predicates as `next_ids` (`retryable_unsure(version)`, `recheckable`) on `where(book_id: book.id)`.
- `next_ids`:

```ruby
          finished = ::Books::Verification.stage_done.or(::Books::Verification.where(work_outcome: :reverted))
          finished = finished.where.not(id: retryable_unsure(version)) if version
          finished = finished.where.not(id: recheckable) if @recheck

          scope = @scope.where.not(id: finished.select(:book_id))
          scope = scope.where.not(id: @attempted.to_a) if @attempted.any?
          scope = scope.where.not(id: Cohort.post_import_range) unless @post_import
          ranked_join = @unranked ? "LEFT JOIN" : "INNER JOIN"
          # ... the existing joins, with ranked_join for ranked_items, prior now
          # books_verifications and its work_outcome
```

  and

```ruby
        def recheckable
          ::Books::Verification.stage_done.where(<<~SQL.squish).select(:id)
            EXISTS (SELECT 1 FROM identifiers i WHERE i.identifiable_type = 'Books::Book'
              AND i.identifiable_id = books_verifications.book_id AND i.source = #{::Identifier.sources[:legacy]}
              AND i.created_at > books_verifications.checked_at)
          SQL
        end
```

  `retryable_unsure` keeps its SQL against `books_verifications` and `work_outcome`.

Run: `bin/rails test test/lib/services/books/verification/` → PASS.

- [ ] **Step 6: Job and rake, test first**

`test/sidekiq/books/verification_job_test.rb`: the job passes flags through:

```ruby
  test "passes the limit, run id and flags to the run" do
    Services::Books::Verification::Run.expects(:call).with(limit: 10, run_id: "r", flags: %w[post_import]).returns(
      Services::Books::Verification::Run::Result.new(success?: true, data: {processed: 10, stopped: false}, errors: [])
    )

    Books::VerificationJob.new.perform(10, "r", %w[post_import])
  end
```

`test/lib/tasks/books_verify_rake_test.rb`: replace the queue tests with:

```ruby
  test "a count and flags queue one run" do
    Books::VerificationJob.expects(:perform_async).with(100, instance_of(String), %w[post_import unranked])

    assert_output(/queued verification run .*: 100 books \(post_import, unranked\)/) { Rake::Task["books:verify"].invoke("100", "post_import", "unranked") }
  end

  test "all with no flags queues a ranked, pre-import run" do
    Books::VerificationJob.expects(:perform_async).with(nil, instance_of(String), [])

    assert_output(/all books \(ranked, pre-import\)/) { Rake::Task["books:verify"].invoke("all") }
  end

  test "an unknown flag or count aborts with usage" do
    Books::VerificationJob.expects(:perform_async).never

    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("5", "everything") } }
    Rake::Task["books:verify"].reenable
    assert_output(nil, /usage: books:verify/) { assert_raises(SystemExit) { Rake::Task["books:verify"].invoke("soon") } }
  end
```

Run → FAIL. Implement: job `perform(limit, run_id, flags = [])` → `Run.call(limit: limit, run_id: run_id, flags: Array(flags))`, logging as before. Rake:

```ruby
  desc "Book verification pass: queue one run over <count> books or all; flags: post_import, unranked, retry_unsure, recheck"
  task :verify, [:limit] => :environment do |_task, args|
    flags = args.extras
    usage = "usage: books:verify[<count>|all(,#{Services::Books::Verification::Run::FLAGS.join("|")})...]"
    limit = case args[:limit]
    when "all" then nil
    when /\A[1-9]\d*\z/ then args[:limit].to_i
    else abort usage
    end
    abort usage unless (flags - Services::Books::Verification::Run::FLAGS).empty?

    run_id = SecureRandom.uuid
    Books::VerificationJob.perform_async(limit, run_id, flags)
    scope = flags.empty? ? "ranked, pre-import" : flags.join(", ")
    puts "queued verification run #{run_id}: #{limit || "all"} books (#{scope}). " \
      "Only one run works at a time: one started while another is in progress exits at once, so queue it again later. " \
      "Progress: bin/rails books:verify_report"
  end
```

Run: `bin/rails test test/sidekiq/books/verification_job_test.rb test/lib/tasks/books_verify_rake_test.rb test/lib/services/books/verification/` → PASS.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/books/verification app/sidekiq/books/verification_job.rb lib/tasks/books/verify.rake test
git commit -m "Verification: cohorts, one book through its stages, run flags, job and rake task

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Revert and report

**Files:**
- Modify: `app/lib/services/books/verification/{revert,report}.rb`, `lib/tasks/books/verify.rake` (revert output)
- Test: `test/lib/services/books/verification/{revert,report}_test.rb`, `test/lib/tasks/books_verify_rake_test.rb`

**Interfaces:**
- Consumes: findings and candidates (Task 2), `Identifier.verified`.
- Produces: `Revert.call(book:) -> Result` (`data: {row:, skipped:}`); `Report.call(client: nil) -> Array<String>`; `Report::SAMPLE = 10`.

- [ ] **Step 1: Revert, test first**

Append to `revert_test.rb`:

```ruby
        test "revert removes what the pass added, restores what it confirmed, and drops findings and candidates" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :done)
          added = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_oclc_id, value: "77", source: :worldcat)
          confirmed = ::Identifier.create!(identifiable: @book, identifier_type: :books_work_isbn13, value: "9780307266934", source: :worldcat)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "77", identifier_id: added.id)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :confirmed, identifier_type: :books_work_isbn13,
            value: "9780307266934", identifier_id: confirmed.id, previous_source: :legacy)
          ::Books::EditionCandidate.create!(book: @book, edition_key: "OL2M")

          result = Revert.call(book: @book)

          assert result.success?
          assert_not ::Identifier.exists?(added.id)
          assert confirmed.reload.source_legacy?
          assert_empty row.reload.findings
          assert_equal 0, ::Books::EditionCandidate.where(book: @book).count
          assert row.reverted?
          assert_equal 0, result.data[:skipped]
        end

        test "an identifier the pass added that has since moved or gone is skipped and counted" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "r", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: @book, kind: :added, identifier_type: :books_work_oclc_id, value: "77", identifier_id: 999_999_999)

          result = Revert.call(book: @book)

          assert result.success?
          assert_equal 1, result.data[:skipped]
        end

        test "a failed or already reverted row cannot be reverted" do
          ::Books::Verification.create!(book: @book, work_outcome: :failed, run_id: "r")

          refute Revert.call(book: @book).success?
        end
```

Update the existing revert tests to read `result.data[:row]` where they used `result.data`. Run → FAIL. Implement in `revert.rb`:

- `REVERTIBLE = (::Books::Verification.work_outcomes.keys - %w[failed reverted]).freeze`; `KEY_REVERTIBLE = (::Books::Verification::KEYED_OUTCOMES + %w[removed]).freeze` (the old set: only these restore work keys, duplicate keys and author keys as today).
- In the transaction: the existing key restoring guarded by `KEY_REVERTIBLE.include?(row.work_outcome)`; then

```ruby
            skipped = 0
            row.findings.added.each do |finding|
              identifier = ::Identifier.find_by(id: finding.identifier_id, identifiable_type: "Books::Book", identifiable_id: @book.id)
              identifier ? identifier.destroy! : skipped += 1
            end
            row.findings.confirmed.each do |finding|
              identifier = ::Identifier.find_by(id: finding.identifier_id, identifiable_type: "Books::Book", identifiable_id: @book.id)
              identifier ? identifier.update!(source: finding.previous_source) : skipped += 1
            end
            row.findings.delete_all
            ::Books::EditionCandidate.where(book_id: @book.id).delete_all
            row.update!(work_outcome: :reverted, stage: :done, lump_suspect: false, added_count: 0, confirmed_count: 0,
              candidate_count: 0, wrong_count: 0)
```

  and `Result.new(success?: true, data: {row: row, skipped: skipped}, errors: [])`. The rake's revert line prints `"reverted book #{book.id}: work keys back to #{result.data[:row].old_keys.inspect}; #{result.data[:skipped]} identifiers had moved and were skipped"`; update its test.

Run → PASS.

- [ ] **Step 2: Report, test first**

Rework `report_test.rb` around the new lines (keep its existing assertions under the new names). Add:

```ruby
        test "the report counts cohorts, stages, findings, lump suspects and candidates" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :keyed, run_id: "r", stage: :done, lump_suspect: true)
          ::Books::VerificationFinding.create!(verification: row, book: row.book, kind: :wrong_identifier, identifier_type: :books_work_isbn13, value: "1")
          ::Books::EditionCandidate.create!(book: row.book, edition_key: "OL2M")

          text = Report.call.join("\n")

          assert_match(/pre_import\s+done\s+1/, text)
          assert_match(/wrong_identifier\s+1/, text)
          assert_match(/Lump suspects: 1/, text)
          assert_match(/Edition candidates: 1/, text)
        end

        test "the report shows ranked identifier coverage by type and source" do
          book = books_books(:war_and_peace)
          ::RankedItem.create!(item: book, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 1)
          Identifier.create!(identifiable: book, identifier_type: :books_work_oclc_id, value: "1", source: :worldcat)

          assert_match(/books_work_oclc_id\s+worldcat\s+1/, Report.call.join("\n"))
        end

        test "samples print our title and authors beside the evidence" do
          row = ::Books::Verification.create!(book: books_books(:war_and_peace), work_outcome: :unsure, run_id: "r", stage: :done)
          ::Books::VerificationFinding.create!(verification: row, book: row.book, kind: :wrong_identifier, identifier_type: :books_work_isbn13,
            value: "9780307266934", evidence: {"records" => [{"title" => "Gloriana", "creator" => "Moorcock, Michael"}]})

          assert_match(/War and Peace.*Tolstoy.*9780307266934.*Gloriana.*Moorcock/, Report.call.join("\n"))
        end
```

(Check the `books_global` ranking configuration fixture is the default primary one, as `run_test.rb` already assumes.) Run → FAIL. Implement `report.rb`:

- `self.call(client: nil)`; lines in this order: title "Book verification pass"; "Rows by cohort and stage:" (`group(:cohort, :stage).count`, `format("  %-12s %-12s %d", cohort, stage, n)`); "Work outcomes:" (the existing per-outcome block on `work_outcome`); the existing abstain, ranked, latest run, latest failure (stage 1) lines; a "Latest stage error" line (newest row with `stage_error`); the existing author line; "Ranked identifiers by type and source:" (identifiers on ranked books of the default primary configuration, `group(:identifier_type, :source).count`, `format("  %-28s %-16s %d", type, source || "none", n)`); "Findings:" by kind; `"Lump suspects: #{n}"`; `"Edition candidates: #{n}"`; the existing "Most recent replaced keys and pairs"; then "Samples:" with up to `SAMPLE` random rows per work outcome (`order(Arel.sql("random()")).limit(SAMPLE)`), `SAMPLE` random WorldCat confirmations (`findings.confirmed.where(source: :worldcat)`) and `SAMPLE` random `wrong_identifier` findings. Each sample line: `book <id> "<title>" by <author names>` then, for a work-outcome row, `-> <new_key>` plus Open Library's title and authors when a `client` was given (one `works_batch` over the sampled keys; on any `Books::OpenLibrary::Exceptions::Error` print the keys alone), and for a finding `<value> -> <evidence records' title / creator / year>`.
- The rake's `verify_report` task passes `client: ::Books::OpenLibrary::Client.new`.

Run: `bin/rails test test/lib/services/books/verification/ test/lib/tasks/books_verify_rake_test.rb` → PASS.

- [ ] **Step 3: Commit**

```bash
git add app/lib/services/books/verification lib/tasks/books/verify.rake test
git commit -m "Verification: revert undoes findings; report adds stages, coverage, signals and samples

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Docs and the full gate

**Files:**
- Move + rewrite: `docs/features/open-library-backfill.md` → `docs/features/book-verification.md`
- Modify: `docs/features/worldcat-data-service.md` ("What this does not do"), `docs/features/identifier-provenance.md` (writers table), `docs/launch-todo.md` (section 5 item 3, section 4 weekly), `docs/todos/goodreads-import-accuracy.md`, and every other doc that names `books:ol_backfill` or `open-library-backfill.md` (`grep -rn "ol_backfill\|open-library-backfill" docs AGENTS.md`), except the dated specs and plans, which are history.

- [ ] **Step 1: The feature doc**

`git mv docs/features/open-library-backfill.md docs/features/book-verification.md`, then rewrite it to cover, in this order, with the commands verbatim:

1. What it is: one pass per book, four stages (spec link), ranked pre-import books by default.
2. Running it: `bin/rails "books:verify[200]"`, `"books:verify[all]"`, flags `post_import`, `unranked`, `retry_unsure`, `recheck`, `books:verify_report`, `"books:verify_revert[<id>]"`; one run at a time; deploys requeue the job; resumption at the stopped stage.
3. Stage 1: keep the old doc's "One book" section and outcome table (it is still accurate), retitled.
4. Stages 2-4: the agreement rules (title, set words, year; WorldCat title/creator/year), what is written and with which source, candidates, `wrong_identifier`, `foreign_work`, lump suspects.
5. Cohorts: the id range and why.
6. The log: `books_verifications`, `books_verification_findings`, `books_edition_candidates`.
7. Reading the report, and revert.
8. Speed: the spec's per-stage estimates, to be replaced by the before-merge measurement.

- [ ] **Step 2: Cross-references**

- `worldcat-data-service.md`, "What this does not do": replace the "No identifiers yet" bullet with: "**Identifiers come from the verification pass, not this service.** `docs/features/book-verification.md` stage 3 looks up a book's held ISBNs one at a time (`GET /isbns`) and confirms one only when a record agrees on title, creator and year; it never writes the other ISBNs a record lists, so box sets cannot spread."
- `identifier-provenance.md`: `worldcat` row "the verification pass (stage 3)"; `open_library` row adds "the verification pass (stages 1-2)"; replace "OL key backfill" mentions with "the verification pass's stage 1".
- `launch-todo.md` section 5 item 3: replace the OL key backfill text with the verification pass: `bin/rails "books:verify[200]"`, read `books:verify_report` (hand-check the risky list and the samples), then `"books:verify[all]"`; later `"books:verify[all,post_import]"` after the Goodreads rebuild; `unranked` optional; keep the "shares the one `/resolve` slot" warning; details `docs/features/book-verification.md`. Section 4 (weekly): add "`bin/rails "books:verify[all,recheck]"` after the sync, once the pass has run".
- `docs/todos/goodreads-import-accuracy.md`: a short "Available now" note: `Identifier.verified`, `books_verification_findings` (`wrong_identifier`, `foreign_work`, `also_held`, `conflict`), `books_verifications.lump_suspect`, `books_edition_candidates`.

- [ ] **Step 3: Full gate**

```bash
bin/rails test
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: all green, no new warning lines.

- [ ] **Step 4: Commit**

```bash
git add ../docs
git commit -m "Docs: book verification pass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After the plan (needs Shane)

Spec section 6, before merging: on a snapshot of the shared dev database (`bin/snapshot-dev-db.sh --label pre-verification`, from a worktree with `COMPOSE_PROJECT_NAME=the-greatest`), run `books:verify[200]` against the live Open Library service and the home-server WorldCat (`WORLDCAT_SERVICE_URL=https://worldcat-api.thegreatestbooks.org`), read the report, hand-check the risky lists and every sample, and put the outcome mix, per-stage timings and the hand-check in the PR. This writes to the shared dev database, so it waits for Shane's go-ahead.
