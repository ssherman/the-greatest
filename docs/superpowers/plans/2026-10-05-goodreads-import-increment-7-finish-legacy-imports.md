# Goodreads Import Increment 7: Finishing Failed Legacy Imports — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repeatable rake step that sends the legacy imports that failed or never finished through
the increment-6 member pipeline. Each becomes a member import of the same user, built from the upload
the replay already loaded.

**Architecture:** One service, `Services::Books::GoodreadsReplay::FinishLegacyImports`. It reads the
legacy statuses live, chooses the eligible imports, and for each one creates (or, after a re-migration,
restarts) a `source: :member` import linked by a new `finishes_legacy_import_id` column. Then it queues
`RunImportJob`. Everything after that is increment 6, unchanged: parse, resolve, verify, write, admin
approval. A rake task `books:goodreads_replay:finish_legacy[limit]` wraps it, with `IDS=` and
`DRY_RUN=1`.

**Tech Stack:** Rails 8.1, Minitest 6 + Mocha, Sidekiq (inline in tests).

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md`, §12.8 (and §7, §10, §13 for
the pipeline it reuses).

## Global Constraints

- Shane, 2026-10-05: this increment is mainly a check that the matcher works. Production books data is
  truncated and re-migrated before launch, so the real run happens once, in the final launch sequence.
  Keep it small: no new pages, no new email, no new job.
- The step must be idempotent, and it must be safe to run again after every books migration pass.
- "An import is skipped if the same user has a later completed import" (spec §12.8).
- Carried from increment 5 (memory): the step must re-check each legacy status, because the loader
  never refreshes it.
- Carried from increment 5 (memory): do not flood the shared Goodreads fetch line ahead of member
  imports. This step queues imports in batches (`limit`). It adds no priority mechanism.
- Services live in `app/lib/services/`, use the Result struct, and are tested through public methods
  only. Legacy DB access is injected (the test DB has no legacy tables), the way `LoadImports` does it.
- Migrations come from the generator. Lint is `bundle exec standardrb`. No brakeman.
- `Sidekiq.testing!(:inline)` is global. Stub `RunImportJob.perform_async` in unit tests that must not
  run the pipeline.
- `docs/launch-todo.md` (already committed on this branch) gets this step's entry.

## Review Focus

1. **A re-migration truncates rows but keeps imports.** `books_goodreads_import_rows` cascades from
   `books_goodreads_editions`, which cascades from `books_books`. Imports and their file attachments
   survive. A finishing import with no rows must run again. One with rows has run this pass and must
   not. (Task 2, tests "after a re-migration..." and "...left alone".)
2. **A user with several unfinished legacy imports.** Only the newest one that has a readable file is
   finished. Finishing two would write an older file over a newer one. (Task 2, two tests.)
3. **The user is busy.** The one-in-progress-per-user index raises `RecordNotUnique` on create, and on
   restart too. The step reports `:user_busy` and must not abort the batch, or poison the transaction.
   (Task 2.)
4. **A legacy import that completed since the load,** or a later completed import read live from the
   legacy DB. It is never finished. (Task 2.)
5. **Rows the stalled legacy import already wrote** are already on the user's lists through the data
   migration. Finishing must skip them, not duplicate them. (Task 2, the end-to-end test.)

---

## File Structure

- Create: `web-app/db/migrate/<timestamp>_add_finishes_legacy_import_id_to_books_goodreads_imports.rb`
- Modify: `web-app/app/models/books/goodreads_import.rb` (validation; annotation is regenerated)
- Modify: `web-app/app/lib/services/books/goodreads_imports/validate_upload.rb` (the daily limit
  ignores finishing imports)
- Create: `web-app/app/lib/services/books/goodreads_replay/finish_legacy_imports.rb`
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake`
- Modify: `web-app/app/views/admin/books/goodreads_imports/show.html.erb` (one badge)
- Modify: `docs/features/goodreads-import.md`, `docs/launch-todo.md`
- Tests: `web-app/test/models/books/goodreads_import_test.rb`,
  `web-app/test/lib/services/books/goodreads_imports/validate_upload_test.rb`,
  `web-app/test/lib/services/books/goodreads_replay/finish_legacy_imports_test.rb`,
  `web-app/test/lib/tasks/books_goodreads_replay_rake_test.rb`

---

### Task 1: The finishing link

**Files:**
- Create: migration (generator)
- Modify: `web-app/app/models/books/goodreads_import.rb`
- Modify: `web-app/app/lib/services/books/goodreads_imports/validate_upload.rb:29`
- Test: `web-app/test/models/books/goodreads_import_test.rb`,
  `web-app/test/lib/services/books/goodreads_imports/validate_upload_test.rb`

**Interfaces:**
- Produces: `books_goodreads_imports.finishes_legacy_import_id` (integer, unique where not null).
  `Books::GoodreadsImport#finishes_legacy_import_id`. A member import with it set is "finishing" legacy
  import N.

- [ ] **Step 1: Write the failing tests**

In `test/models/books/goodreads_import_test.rb`, after "a legacy import id is replayed into one import
only":

```ruby
    test "a legacy import is finished by one member import only" do
      GoodreadsImport.create!(user: users(:regular_user), finishes_legacy_import_id: 42, status: :complete)

      assert_not GoodreadsImport.new(user: users(:editor_user), finishes_legacy_import_id: 42).valid?
    end
```

In `test/lib/services/books/goodreads_imports/validate_upload_test.rb`, after the daily-limit test:

```ruby
        test "the daily limit does not count an import finishing a legacy one" do
          with_goodreads_import_config(daily_limit: 1) do
            @user.goodreads_imports.create!(status: :complete, finishes_legacy_import_id: 991)

            assert ValidateUpload.call(user: @user, upload: upload(export)).success?
          end
        end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/models/books/goodreads_import_test.rb test/lib/services/books/goodreads_imports/validate_upload_test.rb`
Expected: 2 errors, `ActiveModel::UnknownAttributeError: unknown attribute 'finishes_legacy_import_id'`.

- [ ] **Step 3: Generate and write the migration**

Run: `cd web-app && bin/rails generate migration AddFinishesLegacyImportIdToBooksGoodreadsImports`

Replace the generated body with:

```ruby
class AddFinishesLegacyImportIdToBooksGoodreadsImports < ActiveRecord::Migration[8.1]
  def change
    add_column :books_goodreads_imports, :finishes_legacy_import_id, :integer
    add_index :books_goodreads_imports, :finishes_legacy_import_id, unique: true,
      where: "finishes_legacy_import_id IS NOT NULL"
  end
end
```

Run: `cd web-app && bin/rails db:migrate`, then `RAILS_ENV=test bin/rails db:test:prepare`.
annotaterb's post-migrate hook regenerates the model's schema comment. If the hook errors on a
missing legacy database, re-run with `ANNOTATERB_SKIP_ON_DB_TASKS=1` and then
`bundle exec annotaterb models`.
Expected: `db/schema.rb` has the column and the partial unique index, and the model's annotation
lists them.

- [ ] **Step 4: Model validation and the daily limit**

In `app/models/books/goodreads_import.rb`, below `validates :legacy_import_id, ...`:

```ruby
    validates :finishes_legacy_import_id, uniqueness: true, allow_nil: true
```

In `validate_upload.rb`, replace line 29's condition:

```ruby
          if @user.goodreads_imports.member.where(finishes_legacy_import_id: nil, created_at: 24.hours.ago..).count >= config.daily_limit
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: same command as Step 2.
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add web-app/db web-app/app/models/books/goodreads_import.rb web-app/app/lib/services/books/goodreads_imports/validate_upload.rb web-app/test/models/books/goodreads_import_test.rb web-app/test/lib/services/books/goodreads_imports/validate_upload_test.rb
git commit -m "Goodreads import: a member import can finish a legacy one"
```

---

### Task 2: FinishLegacyImports

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_replay/finish_legacy_imports.rb`
- Test: `web-app/test/lib/services/books/goodreads_replay/finish_legacy_imports_test.rb`

**Interfaces:**
- Consumes: `finishes_legacy_import_id` (Task 1); `Books::GoodreadsImport.legacy_replay` with
  `legacy_import_id` and an attached `file` (the increment-5 loader);
  `Books::Goodreads::ExportFile.parse(bytes)` → Result with `data[:rows]`;
  `Books::Goodreads::RunImportJob.perform_async(import_id)`.
- Produces:
  `Services::Books::GoodreadsReplay::FinishLegacyImports.call(legacy_imports: LegacyImports.new, ids: nil, limit: nil, dry_run: false)`
  → `Result(data: {outcomes: {legacy_id => Symbol}, tally: {Symbol => Integer}})`. Outcomes:
  `:started`, `:would_start`, `:running`, `:already_run`, `:rejected`, `:user_busy`,
  `:later_import_completed`, `:member_import_completed`, `:newer_import_finishing`, `:missing_user`,
  `:no_file`, `:unreadable`. The keys are in processing order, newest legacy import first.
  `FinishLegacyImports::LegacyImport = Data.define(:id, :user_id, :status, :created_at)`, where status
  is a `LegacyBooks::GoodreadsImport::STATUSES` name.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FinishLegacyImportsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "finisher@example.com", role: :user, email_verified: false)
          @csv = goodreads_csv({"Book Id" => "1001", "Title" => "The Quiet Year", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "read"})
          ::Books::Goodreads::RunImportJob.stubs(:perform_async)
        end

        def legacy(id: 601, status: "pending", created_at: Time.zone.local(2026, 5, 1), user_id: @user.id)
          FinishLegacyImports::LegacyImport.new(id: id, user_id: user_id, status: status, created_at: created_at)
        end

        # The replay import the loader made, with its upload unless bytes is nil.
        def replay(legacy_id: 601, bytes: @csv, user: @user)
          ::Books::GoodreadsImport.create!(user: user, source: :legacy_replay, legacy_import_id: legacy_id,
            status: :failed, error: "legacy import never finished (pending)").tap do |import|
            next unless bytes

            import.file.attach(io: StringIO.new(bytes), filename: "goodreads_library_export.csv",
              content_type: "text/csv", identify: false)
          end
        end

        def finish(*legacy_imports, **options)
          FinishLegacyImports.call(legacy_imports: legacy_imports, **options).data[:outcomes]
        end

        def finishing(legacy_id = 601)
          ::Books::GoodreadsImport.find_by(finishes_legacy_import_id: legacy_id)
        end

        test "a stuck legacy import becomes a queued member import of the same user, with a copy of its upload" do
          replay
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with { |id| id == finishing&.id }

          assert_equal({601 => :started}, finish(legacy))

          import = finishing
          assert_predicate import, :member?
          assert_predicate import, :queued?
          assert_equal @user, import.user
          assert_equal @csv, import.file.download
        end

        test "a failed legacy import is finished too" do
          replay

          assert_equal({601 => :started}, finish(legacy(status: "failed")))
        end

        test "a legacy import that completed since the load is left alone" do
          replay

          assert_equal({}, finish(legacy(status: "complete")))
          assert_nil finishing
        end

        test "a later completed legacy import of the same user skips it" do
          replay
          later = legacy(id: 602, status: "complete", created_at: Time.zone.local(2026, 6, 1))

          assert_equal({601 => :later_import_completed}, finish(legacy, later))
          assert_nil finishing
        end

        test "an earlier completed legacy import does not skip it" do
          replay
          earlier = legacy(id: 600, status: "complete", created_at: Time.zone.local(2026, 4, 1))

          assert_equal({601 => :started}, finish(legacy, earlier))
        end

        test "a completed upload in this app skips it" do
          replay
          @user.goodreads_imports.create!(status: :complete)

          assert_equal({601 => :member_import_completed}, finish(legacy))
        end

        test "only the user's newest unfinished import is finished" do
          replay(legacy_id: 601)
          replay(legacy_id: 602)
          newer = legacy(id: 602, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :started, 601 => :newer_import_finishing}, finish(legacy, newer))
          assert_nil finishing(601)
        end

        test "a newer import with no usable file leaves the older one to finish" do
          replay(legacy_id: 601)
          replay(legacy_id: 602, bytes: nil)
          newer = legacy(id: 602, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :no_file, 601 => :started}, finish(legacy, newer))
        end

        test "an import the replay has no file for, or an unreadable one, is skipped" do
          assert_equal({601 => :no_file}, finish(legacy))

          replay(bytes: "Title,Author\nThe Quiet Year,Anna Brenner\n")
          assert_equal({601 => :unreadable}, finish(legacy))
          assert_nil finishing
        end

        test "a legacy import whose user is gone is skipped" do
          assert_equal({601 => :missing_user}, finish(legacy(user_id: 0)))
        end

        test "finishing twice in one pass starts it once" do
          replay
          finish(legacy)

          assert_equal({601 => :running}, finish(legacy))
          assert_equal 1, ::Books::GoodreadsImport.where(finishes_legacy_import_id: 601).count
        end

        test "an import that has run this pass is left alone" do
          replay
          finish(legacy)
          finishing.update!(status: :complete)
          finishing.rows.create!(row_number: 1, outcome: :failed, error: "boom")

          assert_equal({601 => :already_run}, finish(legacy))
        end

        test "after a re-migration truncated its rows, it runs again from the kept file, pending review" do
          replay
          finish(legacy)
          import = finishing
          import.update!(status: :complete, finished_at: Time.current, review_status: :approved,
            reviewed_by: users(:admin_user), reviewed_at: Time.current, ai_calls_count: 4)
          import.records.create!(record: books_books(:war_and_peace), action: :created)

          assert_equal({601 => :started}, finish(legacy))

          import.reload
          assert_equal %w[queued pending], [import.status, import.review_status]
          assert_nil import.reviewed_at
          assert_equal 0, import.ai_calls_count
          assert_empty import.records
        end

        test "an import an admin rejected is never finished again" do
          replay
          finish(legacy)
          finishing.update!(status: :complete, review_status: :rejected)

          assert_equal({601 => :rejected}, finish(legacy))
        end

        test "a user with an import in progress is busy, and the batch goes on" do
          replay
          other = User.create!(email: "finisher-two@example.com", role: :user, email_verified: false)
          replay(legacy_id: 602, user: other)
          @user.goodreads_imports.create!(status: :resolving)

          outcomes = finish(legacy, legacy(id: 602, user_id: other.id))

          assert_equal({602 => :started, 601 => :user_busy}, outcomes)
          assert_nil finishing(601)
        end

        test "a dry run says what would start and changes nothing" do
          replay
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_equal({601 => :would_start}, finish(legacy, dry_run: true))
          assert_nil finishing
        end

        test "a limit counts the imports started, newest first, and ids pick legacy imports" do
          other = User.create!(email: "finisher-two@example.com", role: :user, email_verified: false)
          replay(legacy_id: 601)
          replay(legacy_id: 602, user: other)
          newer = legacy(id: 602, user_id: other.id, created_at: Time.zone.local(2026, 6, 1))

          assert_equal({602 => :started}, finish(legacy, newer, limit: 1))
          assert_equal({601 => :started}, finish(legacy, newer, ids: [601]))
        end

        test "a book the stalled legacy import already shelved is not shelved twice" do
          ::Books::Goodreads::RunImportJob.unstub(:perform_async)
          stub_resolution_services
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          book = books_books(:war_and_peace)
          title = "Finish Legacy #{book.id}"
          goodreads_edition(title: title, primary_author: "Leo Tolstoy", goodreads_book_id: 78_000_000 + book.id,
            book: book, resolution: :matched, resolved_at: Time.current)
          replay(bytes: goodreads_csv({"Book Id" => (78_000_000 + book.id).to_s, "Title" => title,
            "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"}))
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          read = ::Books::UserList.find_by!(user: @user, list_type: :read)
          read.user_list_items.create!(listable: book)

          finish(legacy)

          assert_predicate finishing, :complete?
          assert_equal [book.id], read.user_list_items.reload.map(&:listable_id)
          assert_predicate finishing.rows.sole, :skipped?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/books/goodreads_replay/finish_legacy_imports_test.rb`
Expected: every test errors with `NameError: uninitialized constant ...FinishLegacyImports`.

- [ ] **Step 3: Write the service**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Finishes the legacy imports that failed or never finished (Goodreads
      # import spec §12.8) through the member pipeline. Each becomes a member
      # import of the same user, with a copy of the upload the replay loaded,
      # and runs like an upload: it writes list items and reviews, creates
      # unmatched books provisional, and waits for an admin's approval.
      #
      # Legacy statuses are read live, because the loader never refreshes
      # them. A legacy import is skipped when:
      # - the user later completed a legacy import, or any upload here, whose
      #   file could bring back books they have since removed;
      # - a newer unfinished import of theirs is finished instead;
      # - the replay has no readable file for it;
      # - an admin rejected the import that finished it.
      #
      # Repeatable after every books migration pass. A finishing import with
      # rows has run this pass and is left alone. One whose rows a
      # re-migration truncated runs again from its kept file, pending review,
      # its old provenance gone. Writes skip on conflict, so items the legacy
      # import already wrote are not written twice.
      class FinishLegacyImports
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LegacyImport = Data.define(:id, :user_id, :status, :created_at)
        STARTS = %i[started would_start].freeze
        # Outcomes that mean this import, not an older one, is the user's.
        CLAIMS = %i[started would_start running already_run rejected user_busy].freeze

        # Every legacy import, with its status as the legacy app holds it now.
        class LegacyImports
          include Enumerable

          def each
            ::LegacyBooks::GoodreadsImport.select(:id, :user_id, :status, :created_at).find_each do |import|
              yield LegacyImport.new(
                id: import.id, user_id: import.user_id, created_at: import.created_at,
                status: ::LegacyBooks::GoodreadsImport::STATUSES.fetch(import.status, import.status.to_s)
              )
            end
          end
        end

        def self.call(legacy_imports: LegacyImports.new, ids: nil, limit: nil, dry_run: false)
          new(legacy_imports: legacy_imports, ids: ids, limit: limit, dry_run: dry_run).call
        end

        def initialize(legacy_imports:, ids:, limit:, dry_run:)
          @legacy_imports = legacy_imports
          @ids = ids
          @limit = limit
          @dry_run = dry_run
        end

        def call
          imports = @legacy_imports.to_a
          @last_completed = imports.select { |import| import.status == "complete" }
            .group_by(&:user_id).transform_values { |list| list.map(&:created_at).max }
          @claimed_users = Set.new
          outcomes = {}
          unfinished(imports).each do |legacy|
            break if @limit && outcomes.values.count { |outcome| STARTS.include?(outcome) } >= @limit

            outcome = finish(legacy)
            @claimed_users << legacy.user_id if CLAIMS.include?(outcome)
            outcomes[legacy.id] = outcome
          end
          Result.new(success?: true, data: {outcomes: outcomes, tally: outcomes.values.tally}, errors: [])
        end

        private

        def unfinished(imports)
          imports = imports.reject { |import| import.status == "complete" }
          imports = imports.select { |import| @ids.include?(import.id) } if @ids
          imports.sort_by { |import| [import.created_at, import.id] }.reverse
        end

        def finish(legacy)
          last = @last_completed[legacy.user_id]
          return :later_import_completed if last && last > legacy.created_at
          return :newer_import_finishing if @claimed_users.include?(legacy.user_id)

          user = ::User.find_by(id: legacy.user_id)
          return :missing_user unless user
          return :member_import_completed if user.goodreads_imports.member.complete.where(finishes_legacy_import_id: nil).exists?

          replay = ::Books::GoodreadsImport.legacy_replay.find_by(legacy_import_id: legacy.id)
          return :no_file unless replay&.file&.attached?

          existing = ::Books::GoodreadsImport.find_by(finishes_legacy_import_id: legacy.id)
          return :rejected if existing&.review_rejected?
          return :running if existing&.in_progress?
          return :already_run if existing&.rows&.exists?

          bytes = replay.file.download
          parsed = ::Books::Goodreads::ExportFile.parse(bytes)
          return :unreadable unless parsed.success? && parsed.data[:rows].any?
          return :user_busy if user.goodreads_imports.in_progress.exists?
          return :would_start if @dry_run

          start(user, legacy, existing, replay, bytes)
        end

        def start(user, legacy, existing, replay, bytes)
          import = ActiveRecord::Base.transaction(requires_new: true) do
            existing ? restart(existing) : create(user, legacy, replay, bytes)
          end
          ::Books::Goodreads::RunImportJob.perform_async(import.id)
          :started
        rescue ActiveRecord::RecordNotUnique
          # The user started an upload since the check above.
          :user_busy
        end

        def create(user, legacy, replay, bytes)
          user.goodreads_imports.create!(source: :member, status: :queued, finishes_legacy_import_id: legacy.id).tap do |import|
            import.file.attach(io: StringIO.new(bytes), filename: replay.file.filename.to_s, content_type: "text/csv",
              identify: false)
          end
        end

        # A re-migration truncated this import's rows and the books its
        # provenance names, so it starts over and waits for a new approval.
        def restart(import)
          import.records.delete_all
          import.update!(status: :queued, error: nil, started_at: nil, finished_at: nil, review_status: :pending,
            reviewed_by: nil, reviewed_at: nil, ai_calls_count: 0)
          import
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: same command as Step 2.
Expected: 18 runs, 0 failures. If the end-to-end test's row is not `skipped`, read
`WriteLibrary`'s skip rule before changing anything. The test pins spec §12.8's claim, so the code is
what has to give, not the test.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/lib/services/books/goodreads_replay/finish_legacy_imports.rb web-app/test/lib/services/books/goodreads_replay/finish_legacy_imports_test.rb
git commit -m "Goodreads replay: finish failed and stuck legacy imports through the member pipeline"
```

---

### Task 3: Rake task and admin badge

**Files:**
- Modify: `web-app/lib/tasks/books/goodreads_replay.rake`
- Modify: `web-app/app/views/admin/books/goodreads_imports/show.html.erb:12`
- Test: `web-app/test/lib/tasks/books_goodreads_replay_rake_test.rb`

**Interfaces:**
- Consumes: `FinishLegacyImports.call(ids:, limit:, dry_run:)` (Task 2).
- Produces: `bin/rails "books:goodreads_replay:finish_legacy[limit]"`, plus `IDS="73 285"` and
  `DRY_RUN=1`.

- [ ] **Step 1: Write the failing tests**

Append to `BooksGoodreadsReplayRakeTest`:

```ruby
  def with_env(values)
    saved = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  test "finish_legacy passes the limit, IDS and DRY_RUN, then prints each outcome and the tally" do
    REPLAY::FinishLegacyImports.expects(:call).with(limit: 3, ids: [73, 285], dry_run: true)
      .returns(result(outcomes: {285 => :would_start, 73 => :no_file}, tally: {would_start: 1, no_file: 1}))

    with_env("IDS" => "73 285", "DRY_RUN" => "1") do
      assert_output(/legacy import 285: would_start\nlegacy import 73: no_file\nlegacy imports to finish: would_start 1, no_file 1/) do
        Rake::Task["books:goodreads_replay:finish_legacy"].invoke("3")
      end
    end
  end

  test "finish_legacy with no arguments finishes every eligible import" do
    REPLAY::FinishLegacyImports.expects(:call).with(limit: nil, ids: nil, dry_run: false)
      .returns(result(outcomes: {}, tally: {}))

    with_env("IDS" => nil, "DRY_RUN" => nil) do
      assert_output(/legacy imports to finish: nothing/) { Rake::Task["books:goodreads_replay:finish_legacy"].invoke }
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb`
Expected: 2 errors, `Don't know how to build task 'books:goodreads_replay:finish_legacy'`.

- [ ] **Step 3: Add the task**

In `goodreads_replay.rake`, update the header comment's pass to
`load -> fix_slugs -> apply -> resolve (wait for the jobs) -> duplicates -> junk -> apply -> report`,
then add `finish_legacy (final launch pass only)` as a second line. Add the task after `junk`:

```ruby
    desc "Finish the legacy imports that failed or never finished (spec §12.8) as member imports, for admin " \
      "approval. Run after load. Optional limit; IDS=\"73 285\" picks legacy imports; DRY_RUN=1 starts nothing."
    task :finish_legacy, [:limit] => :environment do |_task, args|
      ids = ENV["IDS"].to_s.split(/[\s,]+/).reject(&:blank?).map(&:to_i).presence
      result = Services::Books::GoodreadsReplay::FinishLegacyImports.call(
        limit: args[:limit].presence&.to_i, ids: ids, dry_run: ENV["DRY_RUN"].present?
      )
      result.data[:outcomes].each { |id, outcome| puts "legacy import #{id}: #{outcome}" }
      puts "legacy imports to finish: #{tally.call(result.data[:tally])}"
    end
```

- [ ] **Step 4: The admin badge**

In `app/views/admin/books/goodreads_imports/show.html.erb`, after the source badge on line 12:

```erb
    <% if @import.finishes_legacy_import_id %><span class="badge badge-ghost">finishes legacy import <%= @import.finishes_legacy_import_id %></span><% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/tasks/books_goodreads_replay_rake_test.rb test/controllers/admin/books/goodreads_imports_controller_test.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add web-app/lib/tasks/books/goodreads_replay.rake web-app/test/lib/tasks/books_goodreads_replay_rake_test.rb web-app/app/views/admin/books/goodreads_imports/show.html.erb
git commit -m "Goodreads replay: books:goodreads_replay:finish_legacy, and say so on the admin import page"
```

---

### Task 4: Docs

**Files:**
- Modify: `docs/features/goodreads-import.md` (Status; the "Replay imports are listed..." line in
  Member import; a new "Finishing legacy imports" subsection at the end of Legacy replay)
- Modify: `docs/launch-todo.md` (section 2, item 8)

- [ ] **Step 1: Feature doc**

Replace "Replay imports are listed but never approved, rejected or rerun here; increment 7 runs the
failed ones through this pipeline." with:

```markdown
- Replay imports are listed but never approved, rejected or rerun here. A legacy import that failed or never
  finished is finished as a member import (below, "Finishing legacy imports"), and that one is approved here like an
  upload. Its page says which legacy import it finishes.
```

Add at the end of the "Legacy replay" section:

```markdown
### Finishing legacy imports

Spec §12.8. `bin/rails "books:goodreads_replay:finish_legacy[limit]"` (`FinishLegacyImports`) runs each legacy import
that failed or never finished through the member pipeline. It makes a member import of the same user, linked by
`finishes_legacy_import_id`, from the upload `load` kept. Admins approve or reject it under Goodreads Imports, and the
user sees it in their import history. Run it after `load`. `DRY_RUN=1` lists what it would do; `IDS="73 285"` picks
imports.

- Legacy statuses are read live. An import is skipped when the user later completed a legacy import, or completed any
  upload here, since its file could bring back books they removed. Only the user's newest unfinished import with a
  readable file is finished.
- Rows the stalled legacy import already wrote came over with the data migration, and are skipped as already on the
  user's lists.
- A re-migration truncates the import's rows but keeps the import and its file. The next run restarts it, pending
  review again. One with rows has already run this pass and is left alone. One an admin rejected stays rejected.
- Each import fetches Goodreads pages for the books it would create, on the fetch line member uploads use. Run it in
  batches (`[5]`).
- Measured on the 2026-10-05 development load: 46 unfinished legacy imports. 10 have a later completed import, and
  14 have no usable file (missing from the legacy bucket, not a CSV, or no Goodreads header). That leaves 22, all stuck
  in `pending`, with 40,345 rows between them.
```

In the Status section, mark increment 7 the way the earlier increments are marked there.

- [ ] **Step 2: Launch todo**

Replace section 2's item 8 with:

```markdown
8. **Finish the failed and stuck legacy Goodreads imports, on the final pass only.** A rehearsal run is
   wiped by the next truncate. After the replay's `load`, `DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy`
   lists what it would do. Then run `bin/rails "books:goodreads_replay:finish_legacy[5]"` until nothing starts. Each
   import fetches Goodreads pages on the line member uploads use, so batches keep it from crowding them out. Approve
   or reject each one under Books → Goodreads Imports. See `docs/features/goodreads-import.md`, "Finishing legacy
   imports".
```

- [ ] **Step 3: Commit**

```bash
git add docs/features/goodreads-import.md docs/launch-todo.md
git commit -m "Docs: finishing legacy Goodreads imports, and its launch step"
```

---

### Task 5: The test run on development

This is the check Shane asked for: 3 or 4 imports on the dev data, about 1,000 rows in all. It writes
to the shared dev DB (provisional books, list items, reviews, all reversible with Reject). It also
spends a little OpenAI money and uses the home-server fetcher.

- [ ] **Step 1: Full suite and lint**

Run: `cd web-app && bin/rails test > <workspace>/suite.log 2>&1; tail -5 <workspace>/suite.log` and
`bundle exec standardrb`. Filter `Bearer` out of anything printed.
Expected: 0 failures, no new warnings, standardrb clean.

- [ ] **Step 2: Dry run**

Run: `cd web-app && DRY_RUN=1 bin/rails books:goodreads_replay:finish_legacy`
Expected: about 22 `would_start`, 10 `later_import_completed`, and the rest `no_file` or `unreadable`.
Differences from those counts are findings: note them, don't fix them.

- [ ] **Step 3: Pick the imports**

With a read-only `bin/rails runner` script in the scratchpad: for each `would_start` legacy id, print
the replay import's `rows_count` and the user's count of books list items. Pick 3 or 4 imports with
100–600 rows each, at least two of them with list items already on the user's lists (a stalled run
that had written some).

- [ ] **Step 4: Check the queues before starting a worker**

Run a read-only runner: every `Sidekiq::Queue.all` name and size, plus `Sidekiq::RetrySet.new.size`
and `Sidekiq::ScheduledSet.new.size`.
Expected: all empty. **If anything else is queued, stop and ask Shane.** A worker would run those
jobs too.

- [ ] **Step 5: Run them**

Start `bundle exec sidekiq` in the background from `web-app/`. Then run
`IDS="<ids>" bin/rails books:goodreads_replay:finish_legacy`.
Expected: `started` for each.

Wait with Monitor until none of the finishing imports is in progress (or 30 minutes pass). Then stop
the worker.

- [ ] **Step 6: Read the results**

For each import, print: status, error, rows/matched/created/flagged/parked/skipped counts,
`ai_calls_count`, and the count of skipped rows whose message is "already on your lists". Confirm the
user has no duplicate list items, and that the admin page for each import renders. Report it all to
Shane, and leave the imports in place for him to approve or reject.

---

## Self-review notes

- Spec §12.8: member pipeline (Task 2 creates `source: :member`; increment 6 does the rest),
  provisional books, list items and reviews, admin approval, skip on conflict (Task 2's end-to-end
  test), later completed import (Task 2). Covered.
- Carried requirements: live legacy status (Task 2, the `LegacyImports` default, plus the "completed
  since the load" test). Fetch line (batches, Task 4 docs). Both covered.
- Email: increment 6's `goodreads_import_finished` fires for these imports because they are member
  imports. That's intended: one email per import, and 22 at launch.
