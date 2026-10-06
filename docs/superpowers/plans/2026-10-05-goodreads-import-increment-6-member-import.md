# Goodreads Import Increment 6: Member Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Members upload their Goodreads export, the import resolves and writes their shelves, dates, ratings and reviews, and an admin approves or rejects what it created.

**Architecture:** The resolver from increments 3–4 is in place (`ParseRows`, `ResolveImport`, `SettleEdition`). This increment adds:

- the upload, and an import job that drives an import through its phases;
- `WriteLibrary`, which writes list items and reviews in bulk;
- the admin services: `Approve`, `Revert`, `DeleteProvisional`, `PromoteRecords` and `Rerun`;
- the member pages and the admin pages.

Each phase can run again safely. The job claims an import with a conditional status update, so two triggers never run it twice. An import waiting on Goodreads pages moves to `verifying`. The settle job resumes it once nothing it names is still waiting.

**Tech Stack:** Rails 8.1, Sidekiq 9 (inline in tests), Minitest 6 + Mocha, ActiveStorage (`private_imports`), daisyUI 5, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-03-goodreads-import-design.md` (§7, §10, §11; §4 upload validation; §13 failure handling; §14 tests).

## Global Constraints

- Run Rails commands from `web-app/`; docs live in `docs/` at the project root.
- Services live in `app/lib/services/<domain>/` and return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Jobs live in `app/sidekiq/`, created with `bin/rails generate sidekiq:job <path>`.
- Rails 8 enum syntax.
- Root-anchor `::Books::…` inside `module Services; module Books`, because nested namespaces shadow constants.
- Minitest 6: `assert_nil`, never `assert_equal nil`. Sidekiq is inline in tests. Stub every outside service.
- Controller tests assert behavior (status, redirects, records), never copy or CSS.
- **No nested forms.** Use the HTML `form` attribute when a control belongs to a form elsewhere on the page.
- daisyUI 5: none of the removed v4 classes (`form-control`, `label-text`, `input-bordered`, `file-input-bordered`, `tabs-boxed` …).
- Public layouts render no flash. Member feedback is rendered in the page itself.
- Secrets are ENV via SOPS. This increment adds none.
- Copy on member pages and in the email goes through the `avoid-ai-writing` skill.
- Spec values, verbatim:
  - **Upload:** max 10 MB; required headers `Book Id`, `Title`, `Author`, `Exclusive Shelf`.
  - **Limits:** one import in progress per user (database), and at most 3 imports per user per day (`config.x.goodreads_imports.daily_limit`).
  - **Notification:** `config.x.goodreads_imports.notify_to` (`contact@thegreatestbooks.org`).
  - **Stuck:** in progress for more than 2 hours.
- `bundle exec standardrb` is the linter, not `bin/rubocop`. Do not run brakeman.

## Rulings (decided before execution)

- **R1 — Who can import: any signed-in user.** Shane chose this, 2026-10-05. §11 says "signed-in members"; that means accounts, not paying members.
- **R2 — Skipped rows.** A row is `skipped` ("already on your lists") when neither it nor any other row for the same book wrote anything. Re-importing a file therefore comes back as all skipped, and the `skipped_count` counter means something.
- **R3 — Revert undoes what the import inserted, and nothing it changed.** It deletes the list items and reviews in `applied`. It does not restore a reading item that a read row removed, and it does not clear a blank `completed_on` the import filled. Spec §10 lists exactly what Reject removes.
- **R4 — Goal pages are purged per user, not per change.** An import only adds items and fills blank dates, so goal counts only grow. Taken after the write, `DestructionInvalidator.for_user` (every public goal of the user, at its current count) covers every page that changed. Revert takes the same URLs before it deletes. Purging too many pages is harmless.
- **R5 — Approval promotes every provisional book the import's editions link to**, not only the ones it created. It also promotes the provisional authors of those books. Spec §10: "A provisional book referenced by several imports is promoted by whichever of them is approved first." A promoted book never keeps a hidden author.
- **R6 — Admin gates follow Repair Verdicts.**
  - `Admin::Books::BaseController` provides `authenticate_admin!`.
  - These actions need the write gate: approve, bulk approve, promote a record, rerun.
  - These need the delete gate: reject, delete a record, and an approve that unticks records.
- **R7 — The continuation is claimed with a conditional update.**
  - `RunImport` moves an import out of `queued` or `verifying` with `UPDATE … WHERE status IN (…)`. Whoever gets 0 rows back returns without doing anything.
  - After setting `verifying` it checks the waiting editions again. That closes the race with `SettleEditionsJob`.
  - `VerifyUnverifiedJob` also resumes `verifying` imports that have nothing pending, as a safety net.
- **R8 — Replay imports are out of scope here.** Approve, reject and rerun act on `member` imports only. Increment 7 runs the failed legacy imports through this pipeline. The admin index defaults to `source=member`.
- **R9 — Review bodies.** Goodreads `<br/>` becomes a newline, and the existing sanitizer runs through `Review#valid?`. A review that fails validation (too long) is not written; its row carries the reason in `error`, and the row's list items are still written. The review's `created_at` is `Date Read`, else `Date Added`, else the import time.
- **R10 — The daily limit is rolling.** It counts member imports the user created in the last 24 hours. Refused uploads never create a row, so they never count.
- **R11 — A deleted provisional book takes its rows to `skipped`** with "removed by an admin". Their editions lose `book_id` (FK nullify) and are resolved afresh by a later import.
- **R12 — Polling is the `Refresh` response header** (10 s), as `CsvExportable` does, sent only while the import is in progress.

## Review Focus

1. **Re-uploading the same file changes nothing.** No new items, no moved or reordered items, no second review; every row comes back `skipped`. Test: Task 2, "running the same import twice changes nothing".
2. **Two rows for one book with different shelves.** One row is `read` and another is `currently-reading` (two editions of one work). The book ends up on read only, with the latest date, and is removed from reading. Test: Task 2, "read wins over currently-reading for the same book".
3. **The settle finishes while the import is moving to `verifying`.** The import must still complete, and complete once. Test: Task 4, "an edition settled between resolve and verifying does not strand the import".
4. **Rejecting an import whose provisional book another user's import also uses.** The book is kept and only this user's items go. Test: Task 7, "a provisional book another import's rows name is kept".
5. **Hostile uploads are refused before an import row exists.** That covers an xlsx renamed `.csv`, a header-only file, an 11 MB file, and the fourth upload in a day. Test: Task 1, the ValidateUpload refusals.

---

## File Structure

**Create**
- `web-app/config/initializers/goodreads_imports.rb`: upload, limit and notification settings.
- `web-app/app/lib/services/books/goodreads_imports/validate_upload.rb`: refuses bad uploads, returns bytes and rows.
- `web-app/app/lib/services/books/goodreads_imports/start_import.rb`: creates the import, attaches the file, queues the job.
- `web-app/app/lib/services/books/goodreads_imports/write_library.rb`: list items, reviews, row outcomes.
- `web-app/app/lib/services/books/goodreads_imports/run_import.rb`: claims and drives the phases; `resume_waiting`.
- `web-app/app/sidekiq/books/goodreads/run_import_job.rb`: thin wrapper.
- `web-app/app/lib/services/books/goodreads_imports/provisional_references.rb`: who else uses a provisional record.
- `web-app/app/lib/services/books/goodreads_imports/promote_records.rb`: un-provisional plus enrichment.
- `web-app/app/lib/services/books/goodreads_imports/delete_provisional.rb`: deletes one created record and this import's writes for it.
- `web-app/app/lib/services/books/goodreads_imports/approve.rb`.
- `web-app/app/lib/services/books/goodreads_imports/revert.rb`.
- `web-app/app/lib/services/books/goodreads_imports/rerun.rb`.
- `web-app/app/views/admin_mailer/goodreads_import_finished.{html,text}.erb`.
- `web-app/app/controllers/books/my/goodreads_imports_controller.rb`, plus views in `app/views/books/my/goodreads_imports/`.
- `web-app/app/controllers/admin/books/goodreads_imports_controller.rb`, plus views in `app/views/admin/books/goodreads_imports/`.
- `web-app/e2e/tests/books/account/goodreads-import.spec.ts`, `web-app/e2e/tests/books/admin/goodreads-imports.spec.ts`, `web-app/e2e/fixtures/goodreads_export.csv`.
- Tests mirroring each of the above.

**Modify**
- `app/models/books/goodreads_import.rb`: `IN_PROGRESS`, `in_progress`, `stuck?`, `applied_ids`.
- `app/models/books/goodreads_import_row.rb`: `member_status`, `MEMBER_STATUS_LABELS`.
- `app/models/user_list_item.rb`: public `self.renumber(user_list_id)`, used by the callback and by Revert.
- `app/sidekiq/books/goodreads/settle_editions_job.rb`: resumes waiting imports.
- `app/sidekiq/books/goodreads/verify_unverified_job.rb`: resumes waiting imports.
- `app/mailers/admin_mailer.rb`: `goodreads_import_finished`.
- `config/routes.rb`: member routes in the books constraint; admin resources.
- `app/lib/admin/domain_nav.rb`: "Goodreads Imports".
- `app/views/books/shared/_nav_links.html.erb`: "Import from Goodreads" in My Books, both variants.
- `lib/tasks/e2e.rake`: `goodreads_import_seed` / `goodreads_import_cleanup`.
- `docs/features/goodreads-import.md`: Member import section and status table.

---

### Task 1: Upload settings, validation and start

**Files:**
- Create: `web-app/config/initializers/goodreads_imports.rb`
- Create: `web-app/app/lib/services/books/goodreads_imports/validate_upload.rb`
- Create: `web-app/app/lib/services/books/goodreads_imports/start_import.rb`
- Modify: `web-app/app/models/books/goodreads_import.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/validate_upload_test.rb`, `start_import_test.rb`, `web-app/test/models/books/goodreads_import_test.rb`

**Interfaces:**
- Produces:
  - `Rails.application.config.x.goodreads_imports` with `max_file_bytes`, `daily_limit`, `notify_to`, `stuck_after` (seconds).
  - `Books::GoodreadsImport::IN_PROGRESS` (status strings), `.in_progress`, `#in_progress?`, `#stuck?(now = Time.current)`, `#applied_ids(key)` (Integer array from every row's `applied[key]`; keys `"list_item_ids"` (array) and `"review_id"` (integer)).
  - `ValidateUpload.call(user:, upload:)` returns `Result`, `data: {bytes:, rows:, filename:}`, `errors:` user-facing strings.
  - `StartImport.call(user:, upload:)` returns `Result`, `data: {import:}`.
  - `Books::Goodreads::RunImportJob.perform_async(import_id)`, built in Task 4 (this task creates the job class with an empty `perform` so the constant exists).

- [ ] **Step 1: Write the failing tests**

`test/models/books/goodreads_import_test.rb`, add inside the class:

```ruby
    test "stuck means in progress for longer than stuck_after" do
      import = GoodreadsImport.create!(user: users(:editor_user), status: :resolving, started_at: 3.hours.ago)

      assert import.stuck?
      assert_not import.stuck?(import.started_at + 1.hour)
      import.update!(status: :complete)
      assert_not import.stuck?
    end

    test "applied_ids gathers one key across every row" do
      import = GoodreadsImport.create!(user: users(:editor_user), status: :complete)
      import.rows.create!(row_number: 1, applied: {"list_item_ids" => [3, 4], "review_id" => 9})
      import.rows.create!(row_number: 2, applied: {"list_item_ids" => [5]})
      import.rows.create!(row_number: 3)

      assert_equal [3, 4, 5], import.applied_ids("list_item_ids").sort
      assert_equal [9], import.applied_ids("review_id")
    end
```

`test/lib/services/books/goodreads_imports/validate_upload_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ValidateUploadTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "uploader@example.com", role: :user, email_verified: false)
        end

        def upload(bytes, filename: "goodreads_library_export.csv")
          Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: filename)
        end

        def export
          goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
        end

        test "a Goodreads export passes with its bytes, rows and filename" do
          result = ValidateUpload.call(user: @user, upload: upload(export))

          assert result.success?
          assert_equal 1, result.data[:rows].size
          assert_equal "goodreads_library_export.csv", result.data[:filename]
          assert_equal export.b, result.data[:bytes]
        end

        test "no file is refused" do
          assert_not ValidateUpload.call(user: @user, upload: nil).success?
        end

        test "a file over the size limit is refused unread" do
          with_goodreads_import_config(max_file_bytes: 10) do
            result = ValidateUpload.call(user: @user, upload: upload(export))

            assert_not result.success?
          end
        end

        test "an xlsx renamed .csv is refused" do
          bytes = "PK\x03\x04\x14\x00\x06\x00".b + SecureRandom.random_bytes(200)

          assert_not ValidateUpload.call(user: @user, upload: upload(bytes)).success?
        end

        test "a csv without the export headers is refused" do
          assert_not ValidateUpload.call(user: @user, upload: upload("Title,Author\nDune,Frank Herbert\n")).success?
        end

        test "an export with no rows is refused" do
          assert_not ValidateUpload.call(user: @user, upload: upload(goodreads_csv)).success?
        end

        test "an import in progress refuses another" do
          @user.goodreads_imports.create!(status: :resolving)

          assert_not ValidateUpload.call(user: @user, upload: upload(export)).success?
        end

        test "the daily limit counts member imports from the last 24 hours" do
          with_goodreads_import_config(daily_limit: 2) do
            @user.goodreads_imports.create!(status: :complete, created_at: 25.hours.ago)
            @user.goodreads_imports.create!(status: :complete)
            @user.goodreads_imports.create!(status: :failed, source: :legacy_replay, legacy_import_id: 991)
            assert ValidateUpload.call(user: @user, upload: upload(export)).success?

            @user.goodreads_imports.create!(status: :failed)
            assert_not ValidateUpload.call(user: @user, upload: upload(export)).success?
          end
        end

        def with_goodreads_import_config(**overrides)
          config = Rails.application.config.x.goodreads_imports
          saved = overrides.keys.index_with { |key| config[key] }
          overrides.each { |key, value| config[key] = value }
          yield
        ensure
          saved.each { |key, value| config[key] = value }
        end
      end
    end
  end
end
```

`test/lib/services/books/goodreads_imports/start_import_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class StartImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "starter@example.com", role: :user, email_verified: false)
          @bytes = goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
        end

        def upload(bytes)
          Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: "export.csv")
        end

        test "a valid upload makes a queued member import with the file and queues the job" do
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with { |id| id.is_a?(Integer) }

          result = StartImport.call(user: @user, upload: upload(@bytes))

          import = result.data[:import]
          assert result.success?
          assert_equal %w[member queued], [import.source, import.status]
          assert_equal @bytes.b, import.file.download
        end

        test "a refused upload makes no import and queues nothing" do
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_no_difference -> { ::Books::GoodreadsImport.count } do
            assert_not StartImport.call(user: @user, upload: upload("not,a,goodreads\nfile,,\n")).success?
          end
        end

        test "losing the in-progress race is refused, not raised" do
          ValidateUpload.stubs(:call).returns(ValidateUpload::Result.new(success?: true,
            data: {bytes: @bytes, rows: [], filename: "export.csv"}, errors: []))
          @user.goodreads_imports.create!(status: :parsing)
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_not StartImport.call(user: @user, upload: upload(@bytes)).success?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/models/books/goodreads_import_test.rb test/lib/services/books/goodreads_imports/validate_upload_test.rb test/lib/services/books/goodreads_imports/start_import_test.rb`
Expected: errors. `stuck?` and `applied_ids` are undefined; `ValidateUpload`, `StartImport` and `Books::Goodreads::RunImportJob` are uninitialized constants.

- [ ] **Step 3: Implement**

`config/initializers/goodreads_imports.rb`:

```ruby
# frozen_string_literal: true

# Member Goodreads imports (Goodreads import spec §4, §10). Rails config, not
# an admin UI.
Rails.application.config.x.goodreads_imports = ActiveSupport::OrderedOptions.new.merge(
  # The largest legacy upload was 8.1 MB.
  max_file_bytes: 10.megabytes,
  # Imports a user may start in any 24 hours.
  daily_limit: 3,
  # One email per finished or failed member import.
  notify_to: "contact@thegreatestbooks.org",
  # An import in progress for longer than this is flagged stuck on the admin
  # page and can be run again.
  stuck_after: 2.hours.to_i
)
```

`app/models/books/goodreads_import.rb`: add after the enums.

```ruby
    # The statuses the one-in-progress-per-user index covers.
    IN_PROGRESS = %w[queued parsing resolving verifying writing].freeze

    scope :in_progress, -> { where(status: IN_PROGRESS) }

    def in_progress?
      IN_PROGRESS.include?(status)
    end

    def stuck?(now = Time.current)
      in_progress? && (started_at || created_at) < now - Rails.application.config.x.goodreads_imports.stuck_after
    end

    # Ids one key of every row's `applied` names: "list_item_ids" (arrays)
    # or "review_id".
    def applied_ids(key)
      rows.where("applied ? :key", key: key).pluck(Arel.sql("applied -> #{self.class.connection.quote(key)}"))
        .flat_map { |value| Array(value) }.map(&:to_i)
    end
```

Create the job stub with the generator (Task 4 fills it in):

```bash
bin/rails generate sidekiq:job books/goodreads/run_import
```

Then make `app/sidekiq/books/goodreads/run_import_job.rb`:

```ruby
# frozen_string_literal: true

class Books::Goodreads::RunImportJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: false

  def perform(import_id)
  end
end
```

Delete the generator's test body if it asserts nothing meaningful; Task 4 writes the real test.

`app/lib/services/books/goodreads_imports/validate_upload.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Refuses an upload before any import row exists (Goodreads import spec
      # §4): no file, too large, not a Goodreads export, no rows, an import
      # already running, or the daily limit spent. The errors are shown to the
      # member as they are.
      class ValidateUpload
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        DEFAULT_FILENAME = "goodreads_library_export.csv"

        def self.call(user:, upload:)
          new(user: user, upload: upload).call
        end

        def initialize(user:, upload:)
          @user = user
          @upload = upload
        end

        def call
          return refuse("Choose your Goodreads export file first.") if @upload.blank?
          if @upload.size > config.max_file_bytes
            return refuse("That file is over #{config.max_file_bytes / 1.megabyte} MB. A Goodreads export is much smaller, so check you picked the right file.")
          end
          return refuse("You already have an import running. You can upload another when it finishes.") if @user.goodreads_imports.in_progress.exists?
          if @user.goodreads_imports.member.where(created_at: 24.hours.ago..).count >= config.daily_limit
            return refuse("You can start #{config.daily_limit} imports a day. Try again tomorrow.")
          end

          bytes = @upload.read.to_s.b
          parsed = ::Books::Goodreads::ExportFile.parse(bytes)
          unless parsed.success?
            return refuse("That isn't a Goodreads library export. Export your library from Goodreads and upload the CSV file it gives you.")
          end
          return refuse("That export has no books in it.") if parsed.data[:rows].empty?

          Result.new(success?: true, data: {bytes: bytes, rows: parsed.data[:rows], filename: filename}, errors: [])
        end

        private

        def config = Rails.application.config.x.goodreads_imports

        def filename
          name = @upload.respond_to?(:original_filename) ? @upload.original_filename.to_s : ""
          ActiveStorage::Filename.new(name.presence || DEFAULT_FILENAME).sanitized
        end

        def refuse(message)
          Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end
```

`app/lib/services/books/goodreads_imports/start_import.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Starts a member import: validates the upload, saves it on the private
      # service with a queued import, and queues the run once that commits.
      class StartImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        IN_PROGRESS = "You already have an import running. You can upload another when it finishes."

        def self.call(user:, upload:)
          new(user: user, upload: upload).call
        end

        def initialize(user:, upload:)
          @user = user
          @upload = upload
        end

        def call
          validated = ValidateUpload.call(user: @user, upload: @upload)
          return Result.new(success?: false, data: {}, errors: validated.errors) unless validated.success?

          import = ActiveRecord::Base.transaction do
            @user.goodreads_imports.create!(source: :member, status: :queued).tap do |created|
              created.file.attach(io: StringIO.new(validated.data[:bytes]), filename: validated.data[:filename],
                content_type: "text/csv", identify: false)
            end
          end
          ::Books::Goodreads::RunImportJob.perform_async(import.id)
          Result.new(success?: true, data: {import: import}, errors: [])
        rescue ActiveRecord::RecordNotUnique
          Result.new(success?: false, data: {}, errors: [IN_PROGRESS])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/books/goodreads_import_test.rb test/lib/services/books/goodreads_imports/validate_upload_test.rb test/lib/services/books/goodreads_imports/start_import_test.rb test/sidekiq/books/goodreads/run_import_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add config/initializers/goodreads_imports.rb app/models/books/goodreads_import.rb app/lib/services/books/goodreads_imports/validate_upload.rb app/lib/services/books/goodreads_imports/start_import.rb app/sidekiq/books/goodreads/run_import_job.rb test/
git commit -m "Goodreads import: upload validation and start"
```

---

### Task 2: WriteLibrary: shelves and list items

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/write_library.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/write_library_test.rb`

**Interfaces:**
- Consumes:
  - rows with `exclusive_shelf`, `shelves`, `shelf_positions` (`{"shelf" => position}`), `date_read`, `date_added`, `rating`, `review_body`, `row_number`;
  - `GoodreadsEdition#book_id`, `#parked?`, `#verification`, `#verification_pending?`;
  - `SettleEdition::PARKED_DETAIL`;
  - `Services::UserLists::EnsureDefaults.call(user:, domain: :books, existing:)`.
- Produces:
  - `WriteLibrary.call(import:)` returns `Result`, `data: {applied:, skipped:, parked:, failed:, purge_urls:}` (row counts plus the purge URLs it queued).
  - After it runs, each written row's `applied` is `{"list_item_ids" => [...], "review_id" => id?}`, and its outcome is `applied`, `skipped`, `parked` or `failed`.
  - The import's `skipped_count` is set.
  - `WriteLibrary::SKIPPED_DETAIL = "already on your lists"`.

The reviews half (Task 3) adds to this same class. Task 2 writes only list items.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/goodreads_imports/write_library_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class WriteLibraryTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "writer@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :writing, created_at: Time.zone.local(2026, 9, 1, 12))
          @book = books_books(:war_and_peace)
          @other = books_books(:got)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
        end

        def list(type)
          ::Books::UserList.find_by!(user: @user, list_type: type)
        end

        def custom(name)
          ::Books::UserList.custom.find_by!(user: @user, name: name)
        end

        # A row on an edition resolved to `book`.
        def row(book, number: @import.rows.count + 1, **attributes)
          edition = goodreads_edition(title: "#{book.title} #{number}", book: book, resolution: :matched, resolved_at: Time.current)
          @import.rows.create!({row_number: number, goodreads_edition: edition, exclusive_shelf: "read"}.merge(attributes))
        end

        def items(user_list)
          user_list.user_list_items.reload.map { |item| [item.listable_id, item.position] }
        end

        test "exclusive shelves map to the default lists" do
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3))
          row(@other, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)

          read_item = list(:read).user_list_items.sole
          assert_equal [@book.id, Date.new(2024, 5, 3)], [read_item.listable_id, read_item.completed_on]
          assert_equal [@other.id], list(:want_to_read).user_list_items.map(&:listable_id)
        end

        test "a read book with no Date Read is never dated today" do
          row(@book, exclusive_shelf: "read", date_read: nil)

          WriteLibrary.call(import: @import)

          assert_nil list(:read).user_list_items.sole.completed_on
        end

        test "currently-reading goes to reading" do
          row(@book, exclusive_shelf: "currently-reading")

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], list(:reading).user_list_items.map(&:listable_id)
        end

        test "reading a book removes it from the reading list" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          list(:reading).user_list_items.create!(listable: @book)
          row(@book, exclusive_shelf: "read")

          WriteLibrary.call(import: @import)

          assert_empty list(:reading).user_list_items.reload
          assert_equal [@book.id], list(:read).user_list_items.map(&:listable_id)
        end

        test "read wins over currently-reading for the same book" do
          row(@book, exclusive_shelf: "currently-reading")
          row(@book, exclusive_shelf: "read", date_read: Date.new(2023, 1, 2))
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 6, 7))

          WriteLibrary.call(import: @import)

          assert_empty list(:reading).user_list_items
          assert_equal Date.new(2024, 6, 7), list(:read).user_list_items.sole.completed_on
        end

        test "other shelves become custom lists, matched case-insensitively, with hyphens as spaces" do
          ::Books::UserList.create!(user: @user, list_type: :custom, name: "Science Fiction")
          row(@book, exclusive_shelf: "read", shelves: %w[science-fiction did-not-finish read])

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("Science Fiction").user_list_items.map(&:listable_id)
          assert_equal [@book.id], custom("did not finish").user_list_items.map(&:listable_id)
          assert_equal 1, ::Books::UserList.custom.where(user: @user).where("lower(name) = ?", "science fiction").count
        end

        test "a custom exclusive shelf becomes a custom list" do
          row(@book, exclusive_shelf: "abandoned")

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("abandoned").user_list_items.map(&:listable_id)
        end

        test "a favorites shelf is a custom list, never the favorites list" do
          row(@book, exclusive_shelf: "read", shelves: %w[favorites])

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("favorites").user_list_items.map(&:listable_id)
          assert_empty list(:favorites).user_list_items
        end

        test "new items follow shelf positions and append after existing items" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          kept = books_books(:crime_and_punishment)
          list(:want_to_read).user_list_items.create!(listable: kept)
          row(@book, exclusive_shelf: "to-read", shelf_positions: {"to-read" => 9})
          row(@other, exclusive_shelf: "to-read", shelf_positions: {"to-read" => 2})

          WriteLibrary.call(import: @import)

          assert_equal [[kept.id, 1], [@other.id, 2], [@book.id, 3]], items(list(:want_to_read)).sort_by(&:last)
        end

        test "a new item's created_at is Date Added, else the import time" do
          row(@book, exclusive_shelf: "to-read", date_added: Date.new(2020, 3, 4))
          row(@other, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)

          created = list(:want_to_read).user_list_items.to_h { |item| [item.listable_id, item.created_at] }
          assert_equal Date.new(2020, 3, 4), created[@book.id].to_date
          assert_equal @import.created_at, created[@other.id]
        end

        test "an existing item is not moved; only a blank completed_on is filled" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          dated = list(:read).user_list_items.create!(listable: @other, completed_on: Date.new(2019, 1, 1))
          blank = list(:read).user_list_items.create!(listable: @book)
          row(@other, exclusive_shelf: "read", date_read: Date.new(2024, 1, 1))
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 2, 2))

          WriteLibrary.call(import: @import)

          assert_equal [Date.new(2019, 1, 1), 1], [dated.reload.completed_on, dated.position]
          assert_equal [Date.new(2024, 2, 2), 2], [blank.reload.completed_on, blank.position]
        end

        test "a row records the list items it wrote" do
          written = row(@book, exclusive_shelf: "read", shelves: %w[classics])

          WriteLibrary.call(import: @import)

          ids = ::UserListItem.where(listable: @book, user_list: ::Books::UserList.where(user: @user)).pluck(:id)
          assert_equal ids.sort, written.reload.applied["list_item_ids"].sort
          assert written.applied?
        end

        test "running the same import twice changes nothing" do
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3), shelves: %w[classics])
          WriteLibrary.call(import: @import)
          before = ::UserListItem.where(user_list: ::Books::UserList.where(user: @user)).order(:id)
            .pluck(:id, :user_list_id, :position, :completed_on)

          again = ::Books::GoodreadsImport.create!(user: @user, status: :writing)
          edition = @import.rows.first.goodreads_edition
          again.rows.create!(row_number: 1, goodreads_edition: edition, exclusive_shelf: "read",
            date_read: Date.new(2024, 5, 3), shelves: %w[classics])
          WriteLibrary.call(import: again)

          assert_equal before, ::UserListItem.where(user_list: ::Books::UserList.where(user: @user)).order(:id)
            .pluck(:id, :user_list_id, :position, :completed_on)
          assert_equal ["skipped", WriteLibrary::SKIPPED_DETAIL], [again.rows.sole.outcome, again.rows.sole.outcome_detail]
          assert_equal 1, again.reload.skipped_count
        end

        test "a parked edition's rows are parked; an unresolved one's are failed with its error" do
          parked = goodreads_edition(title: "Invented", resolution: :parked, verification: :not_found, resolved_at: Time.current)
          unresolved = goodreads_edition(title: "Broken")
          parked_row = @import.rows.create!(row_number: 1, goodreads_edition: parked, exclusive_shelf: "read")
          failed_row = @import.rows.create!(row_number: 2, goodreads_edition: unresolved, exclusive_shelf: "read",
            error: "resolution failed: Timeout")

          WriteLibrary.call(import: @import)

          assert_equal ["parked", "not found on Goodreads"], [parked_row.reload.outcome, parked_row.outcome_detail]
          assert_equal ["failed", "resolution failed: Timeout"], [failed_row.reload.outcome, failed_row.error]
        end

        test "a completion date purges the user's goal pages" do
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).with(user: @user).returns(["https://b/reading_goals/1"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["https://b/reading_goals/1"])
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3))

          WriteLibrary.call(import: @import)
        end

        test "no completion date purges nothing" do
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).never
          row(@book, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)
        end
      end
    end
  end
end
```

Book fixtures used: `war_and_peace`, `got` and `crime_and_punishment`, all checked to exist.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/write_library_test.rb`
Expected: errors, because `WriteLibrary` is an uninitialized constant.

- [ ] **Step 3: Implement**

`app/lib/services/books/goodreads_imports/write_library.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Writes an import's rows to the member's library in one pass (Goodreads
      # import spec §7). Not Services::UserLists::AddItem per row: that dates
      # a read item today and fires per-item side effects. The list rules are
      # the same.
      #
      # - read, to-read, currently-reading go to the read, want to read and
      #   reading lists. A read book leaves the reading list, and is never put
      #   on it by the same import. Read is dated from Date Read, never today.
      # - Every other shelf, exclusive or not, is a custom list named after the
      #   shelf with hyphens as spaces, matched case-insensitively. A
      #   "favorites" shelf is a custom list too, never the favorites list,
      #   which feeds the generated users' favorites list.
      # - New items follow Bookshelves with positions and go after the items
      #   already there; created_at is Date Added, else the import time.
      # - Additive: an existing item is never moved, only a blank completed_on
      #   filled, and nothing is deleted except the reading item a read book
      #   replaces. The same file twice changes nothing.
      #
      # Each row's `applied` records the ids it wrote, for Revert. A row whose
      # book this import wrote nothing for is skipped.
      #
      # Runs under the user's row lock, the lock the list-item controller takes,
      # so a member editing lists meanwhile waits rather than interleaves.
      class WriteLibrary
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        DEFAULT_SHELVES = {"read" => :read, "to-read" => :want_to_read, "currently-reading" => :reading}.freeze
        SKIPPED_DETAIL = "already on your lists"
        UNMATCHED_ERROR = "could not be matched to a book"

        # One list item this import wants: the list, the book, the rows behind
        # it (the lowest-numbered one records it), and the shelf it came from.
        Want = Struct.new(:list, :book_id, :rows, :shelf, keyword_init: true)

        def self.call(import:)
          new(import: import).call
        end

        def initialize(import:)
          @import = import
          @user = import.user
          @written = Hash.new { |hash, row_id| hash[row_id] = {"list_item_ids" => []} }
          @completion_changed = false
          @touched_list_ids = Set.new
        end

        def call
          purge_urls = []
          @user.with_lock do
            settle_unwritable_rows
            rows = writable_rows
            by_book = rows.group_by { |row| row.goodreads_edition.book_id }
            write_items(by_book) if by_book.any?
            finish(rows, by_book)
            ::UserList.where(id: @touched_list_ids.to_a).touch_all if @touched_list_ids.any?
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_user(user: @user) if @completion_changed
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          @import.update!(skipped_count: @import.rows.skipped.count)
          Result.new(success?: true, data: @import.rows.group(:outcome).count.symbolize_keys.merge(purge_urls: purge_urls), errors: [])
        end

        private

        # Pending rows that cannot be written: a parked edition's rows are
        # parked, and an edition the resolver never settled fails its rows
        # with the resolver's error. An edition still waiting on Goodreads is
        # left alone: the import is not finished with it.
        def settle_unwritable_rows
          @import.rows.pending.where.not(goodreads_edition_id: nil).includes(:goodreads_edition).find_each do |row|
            edition = row.goodreads_edition
            next if edition.book_id.present? || edition.verification_pending?

            if edition.parked?
              row.update!(outcome: :parked, outcome_detail: SettleEdition::PARKED_DETAIL.fetch(edition.verification.to_sym, "not found on Goodreads"))
            else
              row.update!(outcome: :failed, error: row.error.presence || UNMATCHED_ERROR)
            end
          end
        end

        def writable_rows
          @import.rows.pending.joins(:goodreads_edition).where.not(books_goodreads_editions: {book_id: nil})
            .includes(:goodreads_edition).order(:row_number).to_a
        end

        def write_items(by_book)
          lists = default_lists
          wants = by_book.flat_map { |book_id, rows| wants_for(book_id, rows, lists) }
          existing = existing_items(wants)
          inserts = Hash.new { |hash, list| hash[list] = [] }

          wants.each do |want|
            item = existing[[want.list.id, want.book_id]]
            if item
              fill_completion(item, want)
            else
              inserts[want.list] << want
            end
          end
          remove_from_reading(by_book.keys.select { |book_id| reading_replaced?(by_book[book_id]) }, lists)
          inserts.each { |user_list, list_wants| insert(user_list, list_wants) }
        end

        def default_lists
          existing = ::Books::UserList.where(user: @user).to_a
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: existing)
            .select { |list| list.is_a?(::Books::UserList) && list.default? }.index_by { |list| list.list_type.to_sym }
        end

        def wants_for(book_id, rows, lists)
          shelves = Hash.new { |hash, shelf| hash[shelf] = [] }
          rows.each do |row|
            shelves[row.exclusive_shelf] << row if row.exclusive_shelf.present?
            row.shelves.each { |shelf| shelves[shelf] << row unless DEFAULT_SHELVES.key?(shelf) }
          end
          shelves.delete("currently-reading") if shelves.key?("read")

          shelves.map do |shelf, shelf_rows|
            list = DEFAULT_SHELVES.key?(shelf) ? lists.fetch(DEFAULT_SHELVES[shelf]) : custom_list(shelf)
            Want.new(list: list, book_id: book_id, rows: shelf_rows.uniq.sort_by(&:row_number), shelf: shelf)
          end
        end

        def reading_replaced?(rows)
          rows.any? { |row| row.exclusive_shelf == "read" }
        end

        def custom_list(shelf)
          name = shelf.tr("-", " ").squish
          @custom_lists ||= ::Books::UserList.custom.where(user: @user).to_a.index_by { |list| list.name.downcase.squish }
          @custom_lists[name.downcase] ||= ::Books::UserList.create!(user: @user, list_type: :custom, name: name)
        end

        def existing_items(wants)
          return {} if wants.empty?

          ::UserListItem.where(user_list_id: wants.map { |want| want.list.id }.uniq, listable_type: "Books::Book",
            listable_id: wants.map(&:book_id).uniq).index_by { |item| [item.user_list_id, item.listable_id] }
        end

        def completed_on(want)
          return nil unless want.list.completed_on_enabled?

          want.rows.filter_map(&:date_read).max
        end

        def fill_completion(item, want)
          date = completed_on(want)
          return if date.nil? || item.completed_on.present?

          item.update!(completed_on: date)
          @completion_changed = true
          @touched_list_ids << item.user_list_id
        end

        def remove_from_reading(book_ids, lists)
          reading = lists[:reading]
          return if reading.nil? || book_ids.empty?

          reading.user_list_items.where(listable_type: "Books::Book", listable_id: book_ids).find_each(&:destroy!)
        end

        def insert(user_list, list_wants)
          start = ::UserListItem.where(user_list_id: user_list.id).maximum(:position).to_i
          ordered = list_wants.sort_by do |want|
            positions = want.rows.filter_map { |row| row.shelf_positions[want.shelf] }
            [positions.min || Float::INFINITY, want.rows.first.row_number]
          end
          now = Time.current
          records = ordered.each_with_index.map do |want, index|
            date_added = want.rows.filter_map(&:date_added).min
            {user_list_id: user_list.id, listable_type: "Books::Book", listable_id: want.book_id,
             position: start + index + 1, completed_on: completed_on(want),
             created_at: date_added&.in_time_zone || @import.created_at, updated_at: now}
          end
          inserted = ::UserListItem.insert_all(records, unique_by: :index_user_list_items_on_list_and_listable_unique,
            returning: %w[id listable_id])
          by_book = ordered.index_by(&:book_id)
          inserted.rows.each do |id, listable_id|
            want = by_book.fetch(listable_id)
            @written[want.rows.first.id]["list_item_ids"] << id
            @completion_changed ||= completed_on(want).present?
          end
          @touched_list_ids << user_list.id if inserted.rows.any?
        end

        def finish(rows, by_book)
          wrote = by_book.select { |_book_id, book_rows| book_rows.any? { |row| written?(row) } }.keys.to_set
          rows.each do |row|
            applied = @written.key?(row.id) ? @written[row.id].reject { |_key, value| value.blank? } : {}
            if wrote.include?(row.goodreads_edition.book_id)
              row.update!(outcome: :applied, outcome_detail: nil, applied: applied)
            else
              row.update!(outcome: :skipped, outcome_detail: SKIPPED_DETAIL, applied: applied)
            end
          end
        end

        def written?(row)
          @written.key?(row.id) && @written[row.id].values.any?(&:present?)
        end
      end
    end
  end
end
```

Note for the implementer: `insert_all(...).rows` returns `[id, listable_id]` pairs in the order of the `returning` columns. If the adapter returns a hash per row instead, use `inserted.each { |record| record["id"] … }`. Check with one run and keep whichever form works, adding a ledger ruling if the plan's form was wrong.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/write_library_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_imports/write_library.rb test/lib/services/books/goodreads_imports/write_library_test.rb
git commit -m "Goodreads import: WriteLibrary writes shelves to the member's lists"
```

---

### Task 3: WriteLibrary: reviews

**Files:**
- Modify: `web-app/app/lib/services/books/goodreads_imports/write_library.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/write_library_test.rb`

**Interfaces:**
- Consumes: `Review` validations (sanitizer, length, rating or body), `Services::Reviews::SummaryRecalculator.recalculate(type, id)`.
- Produces: `applied["review_id"]` on the winning row. One summary recalculation per touched book after the lock is released.

- [ ] **Step 1: Write the failing tests** (append to the class)

```ruby
        test "a rating with text becomes a review, Goodreads breaks as newlines" do
          winner = row(@book, rating: 4, review_body: "Long.<br/><br/>Worth it.", date_read: Date.new(2024, 5, 3))

          WriteLibrary.call(import: @import)

          review = ::Review.find_by!(user: @user, reviewable: @book)
          assert_equal [4, "Long.\n\nWorth it."], [review.rating, review.body]
          assert_equal Date.new(2024, 5, 3), review.created_at.to_date
          assert_equal review.id, winner.reload.applied["review_id"]
        end

        test "rating 0 with text is an unrated review; rating 0 and no text is nothing" do
          row(@book, rating: 0, review_body: "No stars from me.")
          row(@other, rating: 0, review_body: nil)

          WriteLibrary.call(import: @import)

          assert_nil ::Review.find_by!(user: @user, reviewable: @book).rating
          assert_not ::Review.exists?(user: @user, reviewable: @other)
        end

        test "an existing review is left untouched" do
          existing = ::Review.create!(user: @user, reviewable: @book, rating: 2, body: "Mine.")
          row(@book, rating: 5, review_body: "Imported.")

          WriteLibrary.call(import: @import)

          assert_equal [2, "Mine."], [existing.reload.rating, existing.body]
        end

        test "two rows for one book: the rated row, then the latest read, then the lowest row number wins" do
          row(@book, number: 1, rating: 0, review_body: "Text only.", date_read: Date.new(2025, 1, 1))
          row(@book, number: 2, rating: 3, review_body: "Older.", date_read: Date.new(2020, 1, 1))
          row(@book, number: 3, rating: 5, review_body: "Newer.", date_read: Date.new(2022, 1, 1))
          row(@other, number: 4, rating: 4, review_body: "First.")
          row(@other, number: 5, rating: 2, review_body: "Second.")

          WriteLibrary.call(import: @import)

          assert_equal "Newer.", ::Review.find_by!(user: @user, reviewable: @book).body
          assert_equal "First.", ::Review.find_by!(user: @user, reviewable: @other).body
        end

        test "a review that fails validation is not written; the row says why and keeps its list items" do
          long = row(@book, rating: 5, review_body: "x" * (::Review::MAX_BODY_LENGTH + 1))

          WriteLibrary.call(import: @import)

          assert_not ::Review.exists?(user: @user, reviewable: @book)
          assert_match(/review not imported/, long.reload.error)
          assert long.applied?
        end

        test "summaries are recalculated once per reviewed book, not per review callback" do
          row(@book, rating: 4)
          row(@book, rating: 2)
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @book.id).once

          WriteLibrary.call(import: @import)
        end

        test "a row that only wrote a review is applied" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          list(:read).user_list_items.create!(listable: @book)
          reviewed = row(@book, rating: 4)

          WriteLibrary.call(import: @import)

          assert reviewed.reload.applied?
          assert_equal [], Array(reviewed.applied["list_item_ids"])
        end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/write_library_test.rb`
Expected: the new tests FAIL (no review written, and `recalculate` is never called).

- [ ] **Step 3: Implement**

In `write_library.rb`:

- Add the constant `REVIEW_BREAK = %r{<br\s*/?>}i`.
- Add `@touched_book_ids = Set.new` to `initialize`.
- In `call`, after `write_items(by_book) if by_book.any?`, add `write_reviews(by_book)`.
- After the purge enqueue, add `@touched_book_ids.each { |book_id| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book_id) }`.
- Add the private methods:

```ruby
        # One deterministic review per book (spec §7): the row with a rating,
        # then the latest Date Read, then the lowest row number. Rating 0 with
        # text is an unrated review; rating 0 and no text is nothing. An
        # existing review by the user is left as it is. Validated as a model
        # (the sanitizer and the length rule run) and inserted in bulk, so the
        # per-review summary callback does not fire; `call` recalculates once
        # per book instead.
        def write_reviews(by_book)
          reviewed = ::Review.where(user: @user, reviewable_type: "Books::Book", reviewable_id: by_book.keys).pluck(:reviewable_id).to_set
          by_book.each do |book_id, rows|
            next if reviewed.include?(book_id)

            winner = rows.select { |row| row.rating.to_i.positive? || row.review_body.present? }
              .min_by { |row| [row.rating.to_i.positive? ? 0 : 1, -(row.date_read&.jd || 0), row.row_number] }
            write_review(book_id, winner) if winner
          end
        end

        def write_review(book_id, row)
          review = ::Review.new(user: @user, reviewable_type: "Books::Book", reviewable_id: book_id,
            rating: (row.rating if row.rating.to_i.positive?), body: row.review_body&.gsub(REVIEW_BREAK, "\n"))
          unless review.valid?
            row.update!(error: "review not imported: #{review.errors.full_messages.to_sentence}")
            return
          end

          now = Time.current
          attributes = review.attributes.slice("user_id", "reviewable_type", "reviewable_id", "rating", "body", "title")
            .merge("created_at" => (row.date_read || row.date_added)&.in_time_zone || @import.created_at, "updated_at" => now)
          inserted = ::Review.insert_all([attributes], unique_by: :index_reviews_on_user_and_reviewable, returning: %w[id])
          return if inserted.rows.empty?

          @written[row.id]["review_id"] = inserted.rows.first.first
          @touched_book_ids << book_id
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/write_library_test.rb test/models/review_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_imports/write_library.rb test/lib/services/books/goodreads_imports/write_library_test.rb
git commit -m "Goodreads import: WriteLibrary writes one review per book"
```

---

### Task 4: The import run, its continuation and the email

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/run_import.rb`
- Modify: `web-app/app/sidekiq/books/goodreads/run_import_job.rb`, `settle_editions_job.rb`, `verify_unverified_job.rb`
- Modify: `web-app/app/mailers/admin_mailer.rb`
- Create: `web-app/app/views/admin_mailer/goodreads_import_finished.html.erb`, `.text.erb`
- Test: `web-app/test/lib/services/books/goodreads_imports/run_import_test.rb`, `web-app/test/sidekiq/books/goodreads/run_import_job_test.rb`, `settle_editions_job_test.rb`, `verify_unverified_job_test.rb`, `web-app/test/mailers/admin_mailer_test.rb`

**Interfaces:**
- Consumes:
  - `ExportFile.parse`, `ParseRows.call(import:, rows:)`;
  - `ResolveImport.call(import:, finder:, importer:)`;
  - `WriteLibrary.call(import:)` (Tasks 2–3).
- Produces:
  - `RunImport.call(import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)` returns `Result`, `data: {outcome:}`. The outcome is one of `:complete`, `:verifying`, `:failed`, `:not_claimed`.
  - `RunImport.resume_waiting(goodreads_book_id: nil)` queues `RunImportJob` for every `verifying` import with no pending edition (all of them when the id is nil).
  - `AdminMailer.goodreads_import_finished(import)`.
  - Route helper `admin_books_goodreads_import_url`, defined in Task 9. This task adds that route now (only `:show`) so the mailer can link. Task 9 extends the same `resources` block.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/goodreads_imports/run_import_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RunImportTest < ActiveSupport::TestCase
        include GoodreadsImportHelper
        include ActionMailer::TestHelper

        setup do
          stub_resolution_services
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "runner@example.com", role: :user, email_verified: false)
          @book = books_books(:war_and_peace)
        end

        def start(bytes)
          @user.goodreads_imports.create!(status: :queued).tap do |import|
            import.file.attach(io: StringIO.new(bytes), filename: "export.csv", content_type: "text/csv", identify: false)
          end
        end

        def cached_row(book)
          title = "Run Import #{book.id}"
          goodreads_edition(title: title, primary_author: "Leo Tolstoy", goodreads_book_id: 77_000_000 + book.id,
            book: book, resolution: :matched, resolved_at: Time.current)
          {"Book Id" => (77_000_000 + book.id).to_s, "Title" => title, "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"}
        end

        test "a queued import is parsed, resolved, written and completed, and the admin is told" do
          import = start(goodreads_csv(cached_row(@book)))

          assert_enqueued_email_with AdminMailer, :goodreads_import_finished, args: [import] do
            assert_equal :complete, RunImport.call(import: import).data[:outcome]
          end

          import.reload
          assert_equal "complete", import.status
          assert import.started_at.present? && import.finished_at.present?
          assert_equal [1, 1], [import.rows_count, import.matched_count]
          assert import.rows.sole.applied?
        end

        test "an import that is not queued or verifying is left alone" do
          import = start(goodreads_csv(cached_row(@book)))
          import.update!(status: :resolving)

          assert_equal :not_claimed, RunImport.call(import: import).data[:outcome]
          assert_equal 0, import.rows.count
        end

        test "an unreadable file fails the import with the reason and tells the admin" do
          import = start("PK\x03\x04 not a csv".b)

          assert_enqueued_emails 1 do
            assert_equal :failed, RunImport.call(import: import).data[:outcome]
          end
          assert_equal "failed", import.reload.status
          assert_match(/Goodreads export/, import.error)
        end

        test "an import with an edition waiting on Goodreads waits in verifying, then completes on resume" do
          waiting = goodreads_edition(title: "Waiting Book", primary_author: "Anna Brenner", goodreads_book_id: 88_000_001,
            verification: :pending)
          import = start(goodreads_csv({"Book Id" => "88000001", "Title" => "Waiting Book", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "to-read"}))

          assert_equal :verifying, RunImport.call(import: import).data[:outcome]
          assert_equal "verifying", import.reload.status

          waiting.update!(verification: :verified, book: @book, resolution: :created, resolved_at: Time.current)
          assert_equal :complete, RunImport.call(import: import).data[:outcome]
          assert import.reload.complete?
        end

        test "an edition settled between resolve and verifying does not strand the import" do
          waiting = goodreads_edition(title: "Racing Book", primary_author: "Anna Brenner", goodreads_book_id: 88_000_002,
            verification: :pending)
          import = start(goodreads_csv({"Book Id" => "88000002", "Title" => "Racing Book", "Author" => "Anna Brenner",
            "Exclusive Shelf" => "to-read"}))
          # The settle commits after the first check, before the import is verifying.
          RunImport.any_instance.stubs(:waiting?).returns(true).then.returns(false)
          waiting.update!(verification: :verified, book: @book, resolution: :created, resolved_at: Time.current)

          assert_equal :complete, RunImport.call(import: import).data[:outcome]
        end

        test "a replay import sends no email" do
          import = start(goodreads_csv(cached_row(@book)))
          import.update!(source: :legacy_replay, legacy_import_id: 4242)

          assert_no_enqueued_emails { RunImport.call(import: import) }
        end

        test "resume_waiting queues verifying imports with nothing pending" do
          ready = @user.goodreads_imports.create!(status: :verifying)
          other = User.create!(email: "waiter@example.com", role: :user, email_verified: false)
          still = other.goodreads_imports.create!(status: :verifying)
          still.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Still Waiting", verification: :pending))
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(ready.id).once
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(still.id).never

          RunImport.resume_waiting
        end

        test "resume_waiting by Goodreads id looks only at imports naming it" do
          ready = @user.goodreads_imports.create!(status: :verifying)
          ready.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Settled", goodreads_book_id: 88_000_003))
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(ready.id).once

          RunImport.resume_waiting(goodreads_book_id: 88_000_003)
          RunImport.resume_waiting(goodreads_book_id: 1)
        end
      end
    end
  end
end
```

`test/sidekiq/books/goodreads/run_import_job_test.rb`:

```ruby
require "test_helper"

class Books::Goodreads::RunImportJobTest < ActiveSupport::TestCase
  test "runs the import" do
    import = books_goodreads_imports(:regular_user_import)
    ::Services::Books::GoodreadsImports::RunImport.expects(:call).with(import: import)

    Books::Goodreads::RunImportJob.new.perform(import.id)
  end

  test "a deleted import is a no-op" do
    ::Services::Books::GoodreadsImports::RunImport.expects(:call).never

    Books::Goodreads::RunImportJob.new.perform(-1)
  end
end
```

`test/sidekiq/books/goodreads/settle_editions_job_test.rb`, add:

```ruby
  test "resumes imports waiting on this Goodreads id" do
    ::Services::Books::GoodreadsImports::RunImport.expects(:resume_waiting).with(goodreads_book_id: 123)

    Books::Goodreads::SettleEditionsJob.new.perform(123)
  end
```

`test/sidekiq/books/goodreads/verify_unverified_job_test.rb`, add:

```ruby
  test "resumes every verifying import with nothing left waiting" do
    ::Services::Books::GoodreadsImports::RunImport.expects(:resume_waiting).with
    Books::Goodreads::VerifyUnverifiedJob.new.perform
  end
```

`test/mailers/admin_mailer_test.rb`, add:

```ruby
  test "goodreads_import_finished goes to the configured address with a link to the admin page" do
    import = books_goodreads_imports(:regular_user_import)

    mail = AdminMailer.goodreads_import_finished(import)

    assert_equal [Rails.application.config.x.goodreads_imports.notify_to], mail.to
    assert_match(/Goodreads import/, mail.subject)
    assert_no_match(/#{Regexp.escape(import.user.email)}/, mail.subject)
    assert_match(%r{/admin/goodreads_imports/#{import.id}}, mail.body.encoded)
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/run_import_test.rb test/sidekiq/books/goodreads/ test/mailers/admin_mailer_test.rb`
Expected: errors. `RunImport` is uninitialized, `goodreads_import_finished` is undefined, and `resume_waiting` is never called.

- [ ] **Step 3: Implement**

`config/routes.rb`, inside `namespace :admin, module: "admin/books", as: "admin_books"`, next to `repair_verdicts`:

```ruby
      resources :goodreads_imports, only: [:show]
```

Also create a placeholder `app/controllers/admin/books/goodreads_imports_controller.rb`. Task 9 replaces it.

```ruby
class Admin::Books::GoodreadsImportsController < Admin::Books::BaseController
  def show
    @import = ::Books::GoodreadsImport.find(params[:id])
    head :ok
  end
end
```

`app/lib/services/books/goodreads_imports/run_import.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Drives one import through its phases (Goodreads import spec §5–§7,
      # §13): parse the file, resolve every edition, wait for Goodreads where
      # an edition needs its page, write the library, complete. Every phase can
      # run again: rows are parsed once, editions resolve once, writes skip on
      # conflict.
      #
      # An import is claimed by a conditional update from queued or verifying,
      # so the job, the settle job's resume and the sweep can all ask for a run
      # and only one does it. After an import is set verifying, the waiting
      # editions are checked again: a settle that finished in between found
      # nothing verifying to resume, so this run carries on itself.
      #
      # A failure fails the import with the error; Postgres errors re-raise
      # after that. A member import emails the admin once it completes or
      # fails; replay imports send nothing.
      class RunImport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze
        UNREADABLE = "the uploaded file is not a readable Goodreads export"

        def self.call(import:, finder: nil, importer: ::DataImporters::Books::Book::Importer)
          new(import: import, finder: finder, importer: importer).call
        end

        # Queues a run for every verifying import that no longer waits on any
        # edition: those naming goodreads_book_id, or all of them.
        def self.resume_waiting(goodreads_book_id: nil)
          imports = ::Books::GoodreadsImport.verifying
          if goodreads_book_id
            imports = imports.where(id: ::Books::GoodreadsImportRow.joins(:goodreads_edition)
              .where(books_goodreads_editions: {goodreads_book_id: goodreads_book_id}).select(:import_id))
          end
          imports.find_each do |import|
            next if import.editions.verification_pending.exists?

            ::Books::Goodreads::RunImportJob.perform_async(import.id)
          end
        end

        def initialize(import:, finder:, importer:)
          @import = import
          @finder = finder
          @importer = importer
        end

        def call
          resuming = @import.verifying?
          return done(:not_claimed) unless claim(from: resuming ? :verifying : :queued, to: resuming ? :resolving : :parsing)

          @import.reload
          parse unless resuming
          @import.update!(status: :resolving)
          ResolveImport.call(import: @import, finder: @finder, importer: @importer)
          return done(:verifying) if wait_for_goodreads

          @import.update!(status: :writing)
          WriteLibrary.call(import: @import)
          finish(:complete)
        rescue => e
          fail!(e)
          raise if POSTGRES_ERRORS.any? { |klass| e.is_a?(klass) }

          done(:failed)
        end

        private

        def claim(from:, to:)
          now = Time.current
          ::Books::GoodreadsImport.where(id: @import.id, status: from)
            .update_all([
              "status = ?, started_at = COALESCE(started_at, ?), updated_at = ?",
              ::Books::GoodreadsImport.statuses[to], now, now
            ]) == 1
        end

        def parse
          parsed = ::Books::Goodreads::ExportFile.parse(@import.file.download)
          raise ArgumentError, "#{UNREADABLE}: #{parsed.errors.join("; ")}" unless parsed.success?

          ParseRows.call(import: @import, rows: parsed.data[:rows])
        end

        # True when the import now waits in verifying for a settle to resume it.
        def wait_for_goodreads
          return false unless waiting?

          @import.update!(status: :verifying)
          return true if waiting?

          # Nothing waits any more, and a settle may have queued a resume:
          # whoever claims verifying first writes the library.
          throw_away = !claim(from: :verifying, to: :writing)
          @import.reload
          throw_away
        end

        def waiting?
          @import.editions.verification_pending.exists?
        end

        def finish(status)
          @import.update!(status: status, finished_at: Time.current, error: nil)
          notify
          done(status)
        end

        def fail!(error)
          Rails.logger.error("#{self.class.name}: Goodreads import #{@import.id} failed: #{error.class}: #{error.message}")
          @import.update_columns(status: ::Books::GoodreadsImport.statuses[:failed], error: "#{error.class}: #{error.message}",
            finished_at: Time.current, updated_at: Time.current)
          notify
        rescue *POSTGRES_ERRORS
          nil
        end

        def notify
          AdminMailer.goodreads_import_finished(@import).deliver_later if @import.member?
        end

        def done(outcome)
          Result.new(success?: outcome != :failed, data: {outcome: outcome}, errors: [])
        end
      end
    end
  end
end
```

Note for the implementer: in `wait_for_goodreads`, when the second claim fails, another run took the import and this run must stop; it returns `true` (treated as "waiting", `:verifying`). `throw_away` is that value. If the name reads badly, rename it `taken_elsewhere`. Behavior is fixed by the race test.

`app/sidekiq/books/goodreads/run_import_job.rb`:

```ruby
# frozen_string_literal: true

# Runs one Goodreads import (Services::Books::GoodreadsImports::RunImport).
# The import keeps its state on its own row, so a failed run is retried by an
# admin, not by Sidekiq (spec §13).
class Books::Goodreads::RunImportJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: false

  def perform(import_id)
    import = ::Books::GoodreadsImport.find_by(id: import_id)
    return if import.nil?

    ::Services::Books::GoodreadsImports::RunImport.call(import: import)
  end
end
```

`settle_editions_job.rb`: after the `each` loop inside `perform`, add:

```ruby
    # An import that waited on these editions in verifying writes its
    # library once nothing it names is still waiting.
    ::Services::Books::GoodreadsImports::RunImport.resume_waiting(goodreads_book_id: goodreads_book_id)
```

`verify_unverified_job.rb`: at the end of `perform`, add:

```ruby
    # Safety net for a resume a crash lost.
    ::Services::Books::GoodreadsImports::RunImport.resume_waiting
```

`app/mailers/admin_mailer.rb`: add a public method before `private`.

```ruby
  # One per member import, when it completes or fails (Goodreads import spec
  # §10). To the site's contact inbox, not ADMIN_NOTIFICATION_EMAIL, which is
  # for sales.
  def goodreads_import_finished(import)
    @import = import
    @site_name = MailBranding.for(:books).site_name

    branded_mail(
      domain: :books,
      to: Rails.application.config.x.goodreads_imports.notify_to,
      subject: "Goodreads import #{import.id} #{import.failed? ? "failed" : "finished"}"
    )
  end
```

`app/views/admin_mailer/goodreads_import_finished.text.erb`:

```erb
A Goodreads import <%= @import.failed? ? "failed" : "finished" %> on <%= @site_name %>.

Member:   <%= @import.user.email %>
Started:  <%= (@import.started_at || @import.created_at).strftime("%B %-d, %Y at %H:%M") %>
Rows:     <%= @import.rows_count %> (<%= @import.editions_count %> editions)
Matched:  <%= @import.matched_count %>
Created:  <%= @import.created_count %>
Flagged:  <%= @import.flagged_count %>
Parked:   <%= @import.parked_count %>
Skipped:  <%= @import.skipped_count %>
AI calls: <%= @import.ai_calls_count %>
<% if @import.error.present? -%>

Error: <%= @import.error %>
<% end -%>

Review it: <%= admin_books_goodreads_import_url(@import) %>
```

`goodreads_import_finished.html.erb`: the same facts in a `<table>`, with `<p><%= link_to "Review it", admin_books_goodreads_import_url(@import) %></p>`. Follow `new_correction.html.erb` for its structure.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/run_import_test.rb test/sidekiq/books/goodreads/ test/mailers/admin_mailer_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_imports/run_import.rb app/sidekiq/books/goodreads/ app/mailers/admin_mailer.rb app/views/admin_mailer/goodreads_import_finished.* app/controllers/admin/books/goodreads_imports_controller.rb config/routes.rb test/
git commit -m "Goodreads import: the import run, resume after verification, admin email"
```

---

### Task 5: Promote and delete provisional records

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/provisional_references.rb`, `promote_records.rb`, `delete_provisional.rb`
- Test: matching files under `web-app/test/lib/services/books/goodreads_imports/`

**Interfaces:**
- Consumes:
  - `GoodreadsImport#applied_ids` (Task 1);
  - `Services::Books::DeferredEnrichment.defer!(book)`;
  - `Books::EnrichBookJob.perform_async(book_id)`, `Books::Authors::WikidataJob.perform_async(author_id)`;
  - `DestructionInvalidator.for_book(book:)`.
- Produces:
  - `ProvisionalReferences.book_used_elsewhere?(book, import:)`: true when another import's rows name the book, or a list item or review outside this import's `applied` uses it, or a curated list holds it.
  - `ProvisionalReferences.author_used?(author)`: true when the author has any book_authors.
  - `PromoteRecords.call(books:, authors:)` returns `Result`, `data: {book_ids:, author_ids:}`. It promotes the given books, their provisional authors and the given authors, then queues enrichment after commit.
  - `DeleteProvisional.call(import:, record:)` returns `Result`, `data: {deleted:}`, `errors:` with the reason when kept.

- [ ] **Step 1: Write the failing tests**

`test/lib/services/books/goodreads_imports/promote_records_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class PromoteRecordsTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Provisional Promote Author", provisional: true)
          @book = ::Books::Book.create!(title: "Provisional Promote Book", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: @author, position: 1)
          @plain = ::Books::Book.create!(title: "Provisional Lone Book", provisional: true)
          ::Books::BookAuthor.create!(book: @plain, author: books_authors(:tolstoy), position: 1)
        end

        test "promotes the books and their provisional authors" do
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::EnrichBookJob.stubs(:perform_async)

          PromoteRecords.call(books: [@book], authors: [])

          assert_equal [false, false], [@book.reload.provisional?, @author.reload.provisional?]
        end

        test "a book with a new author waits for the author's chain; a book without starts its own" do
          ::Books::Authors::WikidataJob.expects(:perform_async).with(@author.id)
          ::Books::EnrichBookJob.expects(:perform_async).with(@plain.id)
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id).never

          PromoteRecords.call(books: [@book, @plain], authors: [])

          assert_equal ::Services::Books::DeferredEnrichment::REASON, @book.enrichments.sole.reason
        end

        test "an already promoted record is left alone and queues nothing" do
          @plain.update!(provisional: false)
          ::Books::EnrichBookJob.expects(:perform_async).never

          assert_empty PromoteRecords.call(books: [@plain], authors: []).data[:book_ids]
        end
      end
    end
  end
end
```

`test/lib/services/books/goodreads_imports/delete_provisional_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class DeleteProvisionalTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "deleter@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @author = ::Books::Author.create!(name: "Delete Provisional Author", provisional: true)
          @book = ::Books::Book.create!(title: "Delete Provisional Book", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: @author, position: 1)
          @import.records.create!(record: @book, action: :created)
          @import.records.create!(record: @author, action: :created)
          @edition = goodreads_edition(title: "Delete Provisional Book", book: @book, resolution: :created, resolved_at: Time.current)
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          @item = ::Books::UserList.find_by!(user: @user, list_type: :read).user_list_items.create!(listable: @book)
          @review = ::Review.create!(user: @user, reviewable: @book, rating: 3)
          @row = @import.rows.create!(row_number: 1, goodreads_edition: @edition, outcome: :applied,
            applied: {"list_item_ids" => [@item.id], "review_id" => @review.id})
        end

        test "deletes the book with this import's items and review, its orphaned author, and skips the row" do
          result = DeleteProvisional.call(import: @import, record: @book)

          assert result.data[:deleted]
          assert_not ::Books::Book.exists?(@book.id)
          assert_not ::Books::Author.exists?(@author.id)
          assert_not ::UserListItem.exists?(@item.id)
          assert_not ::Review.exists?(@review.id)
          assert_equal ["skipped", "removed by an admin", {}], [@row.reload.outcome, @row.outcome_detail, @row.applied]
          assert_nil @edition.reload.book_id
        end

        test "a book another import's rows name is kept" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          other.rows.create!(row_number: 1, goodreads_edition: @edition)

          result = DeleteProvisional.call(import: @import, record: @book)

          assert_not result.data[:deleted]
          assert ::Books::Book.exists?(@book.id)
          assert ::UserListItem.exists?(@item.id)
        end

        test "a book on a curated list, or on a list outside this import, is kept" do
          ::Books::UserList.find_by!(user: @user, list_type: :want_to_read).user_list_items.create!(listable: @book)

          assert_not DeleteProvisional.call(import: @import, record: @book).data[:deleted]
        end

        test "an approved book is never deleted" do
          @book.update!(provisional: false)

          assert_not DeleteProvisional.call(import: @import, record: @book).data[:deleted]
        end

        test "an author still credited on a book is kept; an uncredited one is deleted" do
          assert_not DeleteProvisional.call(import: @import, record: @author).data[:deleted]

          ::Books::BookAuthor.where(author: @author).delete_all
          assert DeleteProvisional.call(import: @import, record: @author).data[:deleted]
        end
      end
    end
  end
end
```

Before running, check the fixture names with `grep -n "^tolstoy:" test/fixtures/books/authors.yml` and the curated `ListItem` fixtures. Replace `tolstoy` with an existing author fixture if needed. Also check `Books::Book.create!`'s required attributes in the model's validations (a slug is generated by friendly_id). If `create!` needs more, build the book the way `test/lib/services/books/goodreads_replay/apply/mark_provisional_test.rb` does.

`test/lib/services/books/goodreads_imports/provisional_references_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ProvisionalReferencesTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "refs@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @book = ::Books::Book.create!(title: "References Book", provisional: true)
        end

        test "a book only this import uses is not used elsewhere" do
          assert_not ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end

        test "a curated list item is a use" do
          ::ListItem.create!(list: lists(:books_list), listable: @book, position: 1)

          assert ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end

        test "another user's review is a use" do
          ::Review.create!(user: users(:regular_user), reviewable: @book, rating: 2)

          assert ProvisionalReferences.book_used_elsewhere?(@book, import: @import)
        end
      end
    end
  end
end
```

Check the curated list fixture name (`grep -n "^[a-z_]*:" test/fixtures/lists.yml | head`) and the `ListItem` required columns before running.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/promote_records_test.rb test/lib/services/books/goodreads_imports/delete_provisional_test.rb test/lib/services/books/goodreads_imports/provisional_references_test.rb`
Expected: errors (uninitialized constants).

- [ ] **Step 3: Implement**

`provisional_references.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Who else uses a provisional record an import created (Goodreads import
      # spec §10, Reject): another import's rows, a list item or review this
      # import did not write, or a curated list. A record anything else uses
      # stays.
      module ProvisionalReferences
        module_function

        def book_used_elsewhere?(book, import:)
          ::Books::GoodreadsImportRow.joins(:goodreads_edition).where(books_goodreads_editions: {book_id: book.id})
            .where.not(import_id: import.id).exists? ||
            book.user_list_items.where.not(id: import.applied_ids("list_item_ids")).exists? ||
            ::Review.where(reviewable: book).where.not(id: import.applied_ids("review_id")).exists? ||
            ::ListItem.where(listable: book).exists?
        end

        def author_used?(author)
          ::Books::BookAuthor.where(author: author).exists?
        end
      end
    end
  end
end
```

`promote_records.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Makes provisional books and authors part of the catalog and queues
      # their enrichment (Goodreads import spec §10, Approve steps 2–3). A
      # promoted book takes its provisional authors with it: the catalog never
      # shows a book whose author is hidden. update! reindexes each record.
      #
      # Enrichment as the importer queues it for a new book: a book credited to
      # an author promoted here waits for that author's chain (a deferral
      # ledger row; Books::Authors::EnrichJob hands it on), any other book is
      # enriched at once, and every promoted author starts its chain. Jobs are
      # queued after commit, so a chain never runs before the deferral exists.
      class PromoteRecords
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(books:, authors:)
          new(books: books, authors: authors).call
        end

        def initialize(books:, authors:)
          @books = Array(books).select(&:provisional?)
          @authors = Array(authors)
        end

        def call
          authors = (@authors + @books.flat_map(&:authors)).uniq.select(&:provisional?)
          author_ids = authors.map(&:id).to_set
          enrich_now = []
          ActiveRecord::Base.transaction(requires_new: true) do
            authors.each { |author| author.update!(provisional: false) }
            @books.each do |book|
              book.update!(provisional: false)
              if book.book_authors.any? { |book_author| author_ids.include?(book_author.author_id) }
                ::Services::Books::DeferredEnrichment.defer!(book)
              else
                enrich_now << book.id
              end
            end
          end
          ActiveRecord.after_all_transactions_commit do
            author_ids.each { |id| ::Books::Authors::WikidataJob.perform_async(id) }
            enrich_now.each { |id| ::Books::EnrichBookJob.perform_async(id) }
          end
          Result.new(success?: true, data: {book_ids: @books.map(&:id), author_ids: author_ids.to_a}, errors: [])
        end
      end
    end
  end
end
```

`delete_provisional.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Deletes one provisional book or author an import created, with what
      # the import wrote for it: the member's list items and review (spec §10,
      # Approve step 1 and per record). A record anything else uses stays
      # (ProvisionalReferences), and an approved record is never deleted here.
      #
      # The book's editions lose it (FK nullify) and are resolved afresh by
      # the next import that names them. Rows that wrote for it read "removed
      # by an admin". An author the import created and left with no book goes
      # too.
      class DeleteProvisional
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        REMOVED_DETAIL = "removed by an admin"

        def self.call(import:, record:)
          new(import: import, record: record).call
        end

        def initialize(import:, record:)
          @import = import
          @record = record
        end

        def call
          return kept("it is already approved") unless @record.provisional?

          case @record
          when ::Books::Book then delete_book
          when ::Books::Author then delete_author
          else kept("only books and authors can be deleted here")
          end
        end

        private

        def delete_book
          return kept("another import, list or review uses it") if ProvisionalReferences.book_used_elsewhere?(@record, import: @import)

          purge_urls = []
          ActiveRecord::Base.transaction do
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: @record)
            item_ids = @record.user_list_items.pluck(:id)
            review_ids = ::Review.where(reviewable: @record).pluck(:id)
            release_rows(item_ids, review_ids)
            author_ids = @import.records.created.where(record_type: "Books::Author").pluck(:record_id)
            @record.destroy!
            ::Books::Author.where(id: author_ids, provisional: true).where.missing(:book_authors).find_each(&:destroy!)
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          deleted
        end

        def delete_author
          return kept("it is still credited on a book") if ProvisionalReferences.author_used?(@record)

          @record.destroy!
          deleted
        end

        # The rows that wrote these items or this review stop recording them.
        def release_rows(item_ids, review_ids)
          @import.rows.where("applied != '{}'::jsonb").find_each do |row|
            items = Array(row.applied["list_item_ids"]).map(&:to_i)
            review = row.applied["review_id"]&.to_i
            next unless items.intersect?(item_ids) || review_ids.include?(review)

            applied = row.applied.merge("list_item_ids" => items - item_ids)
            applied.delete("review_id") if review_ids.include?(review)
            applied = applied.reject { |_key, value| value.blank? }
            row.update!(applied: applied, outcome: applied.empty? ? :skipped : row.outcome,
              outcome_detail: applied.empty? ? REMOVED_DETAIL : row.outcome_detail)
          end
        end

        def kept(reason)
          Result.new(success?: false, data: {deleted: false}, errors: ["Kept: #{reason}."])
        end

        def deleted
          Result.new(success?: true, data: {deleted: true}, errors: [])
        end
      end
    end
  end
end
```

Note: the row whose only item was deleted ends `skipped` with "removed by an admin", which is R11. The book's own `dependent: :destroy` on `user_list_items` and the `Reviewable` reviews removes the items and reviews. `release_rows` only fixes the rows' records of them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/promote_records_test.rb test/lib/services/books/goodreads_imports/delete_provisional_test.rb test/lib/services/books/goodreads_imports/provisional_references_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_imports/{provisional_references,promote_records,delete_provisional}.rb test/lib/services/books/goodreads_imports/
git commit -m "Goodreads import: promote and delete provisional records"
```

---

### Task 6: Approve

**Files:**
- Create: `web-app/app/lib/services/books/goodreads_imports/approve.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/approve_test.rb`

**Interfaces:**
- Consumes: `PromoteRecords`, `DeleteProvisional` (Task 5).
- Produces: `Approve.call(import:, reviewer:, exclude_book_ids: [], exclude_author_ids: [])` returns `Result`, `data: {promoted_book_ids:, promoted_author_ids:, deleted:, kept:}`, `errors:`. Only a `member`, `complete`, review-pending import is approved.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class ApproveTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::EnrichBookJob.stubs(:perform_async)
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "approve@example.com", role: :user, email_verified: false)
          @reviewer = users(:admin_user)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @created = provisional_book("Approve Created Book", created_by: @import)
          @junk = provisional_book("Approve Junk Book", created_by: @import)
          @other_import = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          @linked = provisional_book("Approve Linked Book", created_by: @other_import)
          @import.rows.create!(row_number: 3, goodreads_edition: @linked_edition)
        end

        def provisional_book(title, created_by:)
          author = ::Books::Author.create!(name: "#{title} Author", provisional: true)
          book = ::Books::Book.create!(title: title, provisional: true)
          ::Books::BookAuthor.create!(book: book, author: author, position: 1)
          [book, author].each { |record| created_by.records.create!(record: record, action: :created) }
          edition = goodreads_edition(title: title, book: book, resolution: :created, resolved_at: Time.current)
          created_by.rows.create!(row_number: created_by.rows.count + 1, goodreads_edition: edition, outcome: :applied)
          @linked_edition = edition
          book
        end

        test "promotes what it created and what its editions link to, minus the unticked, and records the reviewer" do
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_book_ids: [@junk.id])

          assert result.success?
          assert_not @created.reload.provisional?
          assert_not @linked.reload.provisional?
          assert_not ::Books::Book.exists?(@junk.id)
          assert_equal ["approved", @reviewer.id], [@import.reload.review_status, @import.reviewed_by_id]
          assert @import.reviewed_at.present?
        end

        test "an unticked book something else uses is kept provisional and reported" do
          @import.rows.create!(row_number: 9, goodreads_edition: @linked_edition)
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_book_ids: [@linked.id])

          assert ::Books::Book.find(@linked.id).provisional?
          assert_includes result.data[:kept].map(&:first), @linked.id
        end

        test "an unticked author still credited on a promoted book is promoted anyway" do
          author = @created.authors.first
          result = Approve.call(import: @import, reviewer: @reviewer, exclude_author_ids: [author.id])

          assert_not author.reload.provisional?
          assert_includes result.data[:kept].map(&:first), author.id
        end

        test "only a finished member import still pending review can be approved" do
          @import.update!(status: :writing)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?

          @import.update!(status: :complete, review_status: :rejected)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?

          @import.update!(review_status: :pending, source: :legacy_replay, legacy_import_id: 7001)
          assert_not Approve.call(import: @import, reviewer: @reviewer).success?
          assert @created.reload.provisional?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/services/books/goodreads_imports/approve_test.rb`
Expected: errors (uninitialized constant `Approve`).

- [ ] **Step 3: Implement**

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # An admin's approval of a finished member import (Goodreads import spec
      # §10, R5):
      #
      # 1. Unticked records are deleted, when still provisional and nothing
      #    else uses them (DeleteProvisional); a record something else uses is
      #    kept and reported.
      # 2. Every provisional book the import created or its editions link to
      #    is promoted, with its provisional authors, and so is every
      #    provisional author it created (PromoteRecords). An unticked author
      #    still credited on a promoted book is promoted with it.
      # 3. Enrichment is queued (PromoteRecords).
      #
      # A provisional book several imports reference is promoted by whichever
      # is approved first.
      class Approve
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:, reviewer:, exclude_book_ids: [], exclude_author_ids: [])
          new(import: import, reviewer: reviewer, exclude_book_ids: exclude_book_ids, exclude_author_ids: exclude_author_ids).call
        end

        def initialize(import:, reviewer:, exclude_book_ids:, exclude_author_ids:)
          @import = import
          @reviewer = reviewer
          @exclude_book_ids = Array(exclude_book_ids).map(&:to_i).to_set
          @exclude_author_ids = Array(exclude_author_ids).map(&:to_i).to_set
        end

        def call
          refusal = refusal_reason
          return Result.new(success?: false, data: {}, errors: [refusal]) if refusal

          kept = []
          deleted = []
          promoted = nil
          ActiveRecord::Base.transaction do
            @import.lock!
            excluded_records.each do |record|
              result = DeleteProvisional.call(import: @import, record: record)
              result.data[:deleted] ? deleted << [record.id, record.class.name] : kept << [record.id, result.errors.first]
            end
            books = promotable_books
            authors = promotable_authors(books)
            authors.each { |author| kept << [author.id, "Kept: still credited on a promoted book."] if @exclude_author_ids.include?(author.id) && credited_on?(author, books) }
            promoted = PromoteRecords.call(books: books, authors: authors.reject { |author| @exclude_author_ids.include?(author.id) && !credited_on?(author, books) })
            @import.update!(review_status: :approved, reviewed_by: @reviewer, reviewed_at: Time.current)
          end
          Result.new(success?: true, errors: [], data: {promoted_book_ids: promoted.data[:book_ids],
            promoted_author_ids: promoted.data[:author_ids], deleted: deleted, kept: kept.uniq})
        end

        private

        def refusal_reason
          return "Only member imports are approved here." unless @import.member?
          return "Only a finished import can be approved." unless @import.complete?
          "This import is already #{@import.review_status}." unless @import.review_pending?
        end

        # Only records this import created can be unticked: an approval is
        # not a way to delete any provisional record by id.
        def excluded_records
          created = @import.records.created
          ::Books::Book.where(id: @exclude_book_ids.to_a).where(id: created.where(record_type: "Books::Book").select(:record_id)).to_a +
            ::Books::Author.where(id: @exclude_author_ids.to_a).where(id: created.where(record_type: "Books::Author").select(:record_id)).to_a
        end

        def promotable_books
          ids = @import.records.created.where(record_type: "Books::Book").select(:record_id)
          ::Books::Book.where(provisional: true).where(id: ids)
            .or(::Books::Book.where(provisional: true).where(id: @import.editions.select(:book_id)))
            .where.not(id: @exclude_book_ids.to_a).includes(:authors, :book_authors).to_a
        end

        def promotable_authors(books)
          ids = @import.records.created.where(record_type: "Books::Author").select(:record_id)
          (::Books::Author.where(provisional: true, id: ids).to_a + books.flat_map(&:authors).select(&:provisional?)).uniq
        end

        def credited_on?(author, books)
          books.any? { |book| book.book_authors.any? { |book_author| book_author.author_id == author.id } }
        end
      end
    end
  end
end
```

Note: `PromoteRecords` already promotes a book's provisional authors whatever list it is given. So an unticked author credited on a promoted book is promoted even when it is left out of `authors:`. The `kept` line reports that. The `reject` keeps uncredited unticked authors out. `DeleteProvisional` has normally deleted those already.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/books/goodreads_imports/approve_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/services/books/goodreads_imports/approve.rb test/lib/services/books/goodreads_imports/approve_test.rb
git commit -m "Goodreads import: admin approval"
```

---

### Task 7: Revert (reject) and Rerun

**Files:**
- Modify: `web-app/app/models/user_list_item.rb`
- Create: `web-app/app/lib/services/books/goodreads_imports/revert.rb`, `rerun.rb`
- Test: `web-app/test/lib/services/books/goodreads_imports/revert_test.rb`, `rerun_test.rb`, `web-app/test/models/user_list_item_test.rb`

**Interfaces:**
- Consumes: `ProvisionalReferences` (Task 5), `GoodreadsImport#applied_ids`, `#stuck?` (Task 1), `DestructionInvalidator.for_user`.
- Produces:
  - `UserListItem.renumber(user_list_id)`, public, the SQL the destroy callback already runs.
  - `Revert.call(import:, reviewer:)` returns `Result`, `data: {deleted_items:, deleted_reviews:, deleted_book_ids:, deleted_author_ids:}`.
  - `Rerun.call(import:)` returns `Result`.

- [ ] **Step 1: Write the failing tests**

`test/models/user_list_item_test.rb`, add:

```ruby
  test "renumber closes the gaps a bulk delete leaves" do
    user = User.create!(email: "renumber@example.com", role: :user, email_verified: false)
    list = Books::UserList.find_by!(user: user, list_type: :read)
    first, second, third = [books_books(:war_and_peace), books_books(:got), books_books(:crime_and_punishment)].map { |book| list.user_list_items.create!(listable: book) }
    UserListItem.where(id: second.id).delete_all

    UserListItem.renumber(list.id)

    assert_equal [1, 2], [first.reload.position, third.reload.position]
  end
```

`test/lib/services/books/goodreads_imports/revert_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RevertTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "revert@example.com", role: :user, email_verified: false)
          @reviewer = users(:admin_user)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @read = ::Books::UserList.find_by!(user: @user, list_type: :read)
          @kept = @read.user_list_items.create!(listable: books_books(:crime_and_punishment))
          @matched = books_books(:war_and_peace)
          @author = ::Books::Author.create!(name: "Revert Author", provisional: true)
          @created = ::Books::Book.create!(title: "Revert Created Book", provisional: true)
          ::Books::BookAuthor.create!(book: @created, author: @author, position: 1)
          [@created, @author].each { |record| @import.records.create!(record: record, action: :created) }
          @created_edition = goodreads_edition(title: "Revert Created Book", book: @created, resolution: :created, resolved_at: Time.current)
          @items = [@matched, @created].map { |book| @read.user_list_items.create!(listable: book) }
          @review = ::Review.create!(user: @user, reviewable: @matched, rating: 4)
          @import.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Revert Matched", book: @matched,
            resolution: :matched, resolved_at: Time.current), outcome: :applied,
            applied: {"list_item_ids" => [@items.first.id], "review_id" => @review.id})
          @import.rows.create!(row_number: 2, goodreads_edition: @created_edition, outcome: :applied,
            applied: {"list_item_ids" => [@items.last.id]})
        end

        test "removes exactly what the import wrote and the provisional records nothing else uses" do
          result = Revert.call(import: @import, reviewer: @reviewer)

          assert result.success?
          assert_equal [@kept.id], @read.user_list_items.reload.map(&:id)
          assert_equal 1, @kept.reload.position
          assert_not ::Review.exists?(@review.id)
          assert_not ::Books::Book.exists?(@created.id)
          assert_not ::Books::Author.exists?(@author.id)
          assert ::Books::Book.exists?(@matched.id)
          assert_equal ["rejected", @reviewer.id], [@import.reload.review_status, @import.reviewed_by_id]
          assert_empty @import.rows.where("applied != '{}'::jsonb")
        end

        test "a provisional book another import's rows name is kept" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          other.rows.create!(row_number: 1, goodreads_edition: @created_edition)

          Revert.call(import: @import, reviewer: @reviewer)

          assert ::Books::Book.exists?(@created.id)
          assert_not ::UserListItem.exists?(@items.last.id)
        end

        test "identifiers the import stamped on an existing book are removed" do
          stamped = ::Identifier.create!(identifiable: @matched, identifier_type: :books_work_goodreads_id, value: "999123")
          @import.records.create!(record: stamped, action: :stamped)

          Revert.call(import: @import, reviewer: @reviewer)

          assert_not ::Identifier.exists?(stamped.id)
        end

        test "summaries are recalculated for reviewed books and goal pages purged" do
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @matched.id)
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).with(user: @user).returns(["u"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["u"])

          Revert.call(import: @import, reviewer: @reviewer)
        end

        test "a stuck import is failed as it is rejected, freeing the member to upload again" do
          @import.update!(status: :writing, started_at: 3.hours.ago)

          assert Revert.call(import: @import, reviewer: @reviewer).success?
          assert @import.reload.failed?
        end

        test "an import still running, a replay import, or one already rejected is refused" do
          @import.update!(status: :resolving, started_at: Time.current)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?

          @import.update!(status: :complete, review_status: :rejected)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?

          @import.update!(review_status: :pending, source: :legacy_replay, legacy_import_id: 7002)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?
        end
      end
    end
  end
end
```

Check the Identifier enum value for the Goodreads type (`grep -n "books_work_goodreads_id" app/models/identifier.rb`) and the required columns before running.

`test/lib/services/books/goodreads_imports/rerun_test.rb`:

```ruby
require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RerunTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "rerun@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :failed, error: "boom", finished_at: Time.current)
        end

        test "a failed import is queued again with its unwritten failed rows reset" do
          edition = goodreads_edition(title: "Rerun Book")
          retried = @import.rows.create!(row_number: 1, goodreads_edition: edition, outcome: :failed, error: "resolution failed")
          unparsed = @import.rows.create!(row_number: 2, outcome: :failed, error: "columns do not line up")
          ::Books::Goodreads::RunImportJob.expects(:perform_async).with(@import.id)

          assert Rerun.call(import: @import).success?

          assert_equal ["queued", nil, nil], [@import.reload.status, @import.error, @import.finished_at]
          assert_equal ["pending", nil], [retried.reload.outcome, retried.error]
          assert unparsed.reload.failed?
        end

        test "a stuck import can be rerun; a running or complete one cannot" do
          ::Books::Goodreads::RunImportJob.stubs(:perform_async)
          @import.update!(status: :resolving, started_at: 3.hours.ago)
          assert Rerun.call(import: @import).success?

          @import.update!(status: :resolving, started_at: Time.current)
          assert_not Rerun.call(import: @import).success?

          @import.update!(status: :complete)
          assert_not Rerun.call(import: @import).success?
        end

        test "a failed import cannot rerun while the member has another in progress" do
          @user.goodreads_imports.create!(status: :parsing)
          ::Books::Goodreads::RunImportJob.expects(:perform_async).never

          assert_not Rerun.call(import: @import).success?
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/models/user_list_item_test.rb test/lib/services/books/goodreads_imports/revert_test.rb test/lib/services/books/goodreads_imports/rerun_test.rb`
Expected: errors (`renumber` undefined, uninitialized constants).

- [ ] **Step 3: Implement**

`app/models/user_list_item.rb`:

- Add a public class method above `private`. Its body is moved from `shift_positions_up` unchanged, with `user_list_id` as the argument:

```ruby
  # Renumbers a list's items to 1..N in position order, in one statement (see
  # shift_positions_up). Public for bulk deletes that skip the callback.
  def self.renumber(user_list_id)
    sql = sanitize_sql_array([<<~SQL.squish, user_list_id])
      UPDATE user_list_items
      SET position = ranked.new_position
      FROM (
        SELECT id, ROW_NUMBER() OVER (ORDER BY position, id) AS new_position
        FROM user_list_items
        WHERE user_list_id = ?
      ) ranked
      WHERE user_list_items.id = ranked.id
        AND user_list_items.position <> ranked.new_position
    SQL
    connection.execute(sql)
  end
```

- Make `shift_positions_up` keep its guard and then call `self.class.renumber(user_list_id)`.

`revert.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # An admin's rejection of a member import (Goodreads import spec §10):
      #
      # - deletes the list items and reviews every row's `applied` names;
      # - deletes the provisional books and authors the import created that
      #   nothing else uses (ProvisionalReferences);
      # - removes identifiers it stamped onto existing books;
      # - recalculates review summaries and purges goal pages it touched.
      #
      # What it changed rather than inserted stays (R3): a reading item a read
      # row replaced, a blank date it filled. A stuck import is failed as it is
      # rejected, which frees the member to upload again.
      class Revert
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:, reviewer:)
          new(import: import, reviewer: reviewer).call
        end

        def initialize(import:, reviewer:)
          @import = import
          @reviewer = reviewer
        end

        def call
          refusal = refusal_reason
          return Result.new(success?: false, data: {}, errors: [refusal]) if refusal

          data = nil
          purge_urls = []
          book_ids = []
          ActiveRecord::Base.transaction do
            @import.lock!
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_user(user: @import.user)
            item_ids = @import.applied_ids("list_item_ids")
            review_ids = @import.applied_ids("review_id")
            book_ids = ::Review.where(id: review_ids).pluck(:reviewable_id)
            list_ids = ::UserListItem.where(id: item_ids).distinct.pluck(:user_list_id)
            deleted_items = ::UserListItem.where(id: item_ids).delete_all
            deleted_reviews = ::Review.where(id: review_ids).delete_all
            list_ids.each { |list_id| ::UserListItem.renumber(list_id) }
            ::UserList.where(id: list_ids).touch_all if list_ids.any?
            @import.rows.where("applied != '{}'::jsonb").update_all(applied: {}, updated_at: Time.current)
            deleted_books = delete_books
            deleted_authors = delete_authors
            ::Identifier.where(id: @import.records.stamped.where(record_type: "Identifier").select(:record_id)).destroy_all
            close!
            data = {deleted_items: deleted_items, deleted_reviews: deleted_reviews, deleted_book_ids: deleted_books,
                    deleted_author_ids: deleted_authors}
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          book_ids.uniq.each { |id| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", id) }
          Result.new(success?: true, data: data, errors: [])
        end

        private

        def refusal_reason
          return "Only member imports are rejected here." unless @import.member?
          return "This import is already rejected." if @import.review_rejected?
          "This import is still running. Wait for it to finish, or for it to be flagged stuck." if @import.in_progress? && !@import.stuck?
        end

        def delete_books
          ids = @import.records.created.where(record_type: "Books::Book").select(:record_id)
          ::Books::Book.where(id: ids, provisional: true).to_a.filter_map do |book|
            next if ProvisionalReferences.book_used_elsewhere?(book, import: @import)

            book.destroy!
            book.id
          end
        end

        def delete_authors
          ids = @import.records.created.where(record_type: "Books::Author").select(:record_id)
          ::Books::Author.where(id: ids, provisional: true).to_a.filter_map do |author|
            next if ProvisionalReferences.author_used?(author)

            author.destroy!
            author.id
          end
        end

        def close!
          attributes = {review_status: :rejected, reviewed_by: @reviewer, reviewed_at: Time.current}
          attributes.merge!(status: :failed, error: "rejected while stuck", finished_at: Time.current) if @import.in_progress?
          @import.update!(attributes)
        end
      end
    end
  end
end
```

`rerun.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Runs a failed or stuck member import again (Goodreads import spec §10,
      # "Retry"; §13). Rows that failed after parsing and wrote nothing go back
      # to pending, so the run resolves and writes them; rows that never
      # parsed stay failed. The run continues from where the import stopped.
      class Rerun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:)
          new(import: import).call
        end

        def initialize(import:)
          @import = import
        end

        def call
          return refuse("Only member imports are rerun here.") unless @import.member?
          return refuse("Only a failed or stuck import can be rerun.") unless @import.failed? || @import.stuck?
          return refuse("A rejected import is not rerun.") if @import.review_rejected?

          ActiveRecord::Base.transaction do
            @import.rows.failed.where.not(goodreads_edition_id: nil).where("applied = '{}'::jsonb")
              .update_all(outcome: ::Books::GoodreadsImportRow.outcomes[:pending], error: nil, updated_at: Time.current)
            @import.update!(status: :queued, error: nil, finished_at: nil)
          end
          ::Books::Goodreads::RunImportJob.perform_async(@import.id)
          Result.new(success?: true, data: {import: @import}, errors: [])
        rescue ActiveRecord::RecordNotUnique
          refuse("The member has another import in progress.")
        end

        private

        def refuse(message)
          Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/user_list_item_test.rb test/lib/services/books/goodreads_imports/revert_test.rb test/lib/services/books/goodreads_imports/rerun_test.rb test/controllers/user_list_items_controller_test.rb`
Expected: PASS. The last file proves the refactored callback still renumbers.

- [ ] **Step 5: Commit**

```bash
git add app/models/user_list_item.rb app/lib/services/books/goodreads_imports/{revert,rerun}.rb test/
git commit -m "Goodreads import: reject reverts what an import wrote; rerun a failed import"
```

---

### Task 8: Member pages

**Files:**
- Create: `web-app/app/controllers/books/my/goodreads_imports_controller.rb`
- Create: `web-app/app/views/books/my/goodreads_imports/index.html.erb`, `show.html.erb`
- Modify: `web-app/app/models/books/goodreads_import_row.rb`, `web-app/config/routes.rb`, `web-app/app/views/books/shared/_nav_links.html.erb`
- Test: `web-app/test/controllers/books/my/goodreads_imports_controller_test.rb`, `web-app/test/models/books/goodreads_import_row_test.rb`

**Interfaces:**
- Consumes: `StartImport.call(user:, upload:)` (Task 1), `GoodreadsImport#in_progress?`.
- Produces:
  - routes `books_my_goodreads_imports_path` (GET index, POST create) and `books_my_goodreads_import_path(id)` (GET show);
  - `GoodreadsImportRow#member_status` → one of `:working, :matched, :new_pending_review, :flagged, :not_found, :skipped, :failed`;
  - `GoodreadsImportRow::MEMBER_STATUS_LABELS` (Symbol → String).

- [ ] **Step 1: Write the failing tests**

`test/models/books/goodreads_import_row_test.rb`, add:

```ruby
    test "member_status reads the row's outcome, its book and its decision" do
      import = books_goodreads_imports(:regular_user_import)
      edition = books_goodreads_editions(:war_and_peace_edition)
      row = import.rows.create!(row_number: 50, goodreads_edition: edition, outcome: :applied)

      edition.update!(book: books_books(:war_and_peace), match_decision: nil)
      assert_equal :matched, row.reload.member_status

      edition.book.update_column(:provisional, true)
      assert_equal :new_pending_review, row.reload.member_status
      edition.book.update_column(:provisional, false)

      decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: edition, outcome: :matched,
        confidence: :medium, decided_by: :ai, needs_review: true)
      edition.update!(match_decision: decision)
      assert_equal :flagged, row.reload.member_status

      assert_equal [:not_found, :skipped, :failed, :working],
        %i[parked skipped failed pending].map { |outcome| row.tap { |r| r.outcome = outcome }.member_status }
      assert(GoodreadsImportRow::MEMBER_STATUS_LABELS.keys.to_set >= %i[working matched new_pending_review flagged not_found skipped failed].to_set)
    end
```

`test/controllers/books/my/goodreads_imports_controller_test.rb`:

```ruby
require "test_helper"

class Books::My::GoodreadsImportsControllerTest < ActionDispatch::IntegrationTest
  include GoodreadsImportHelper

  setup do
    host! Rails.application.config.domains[:books]
    @user = User.create!(email: "member-import@example.com", role: :user, email_verified: false)
    @import = @user.goodreads_imports.create!(status: :complete, rows_count: 1)
    @import.rows.create!(row_number: 1, raw: {"Title" => "War and Peace", "Author" => "Leo Tolstoy"}, outcome: :failed, error: "x")
  end

  def upload
    bytes = goodreads_csv({"Book Id" => "656", "Title" => "War and Peace", "Author" => "Leo Tolstoy", "Exclusive Shelf" => "read"})
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "text/csv", original_filename: "export.csv")
  end

  test "every action needs a signed-in user" do
    get books_my_goodreads_imports_path
    assert_response :redirect
    post books_my_goodreads_imports_path, params: {goodreads_import: {file: upload}}
    assert_response :redirect
    get books_my_goodreads_import_path(@import)
    assert_response :redirect
  end

  test "index lists only the member's own member imports and is not cached" do
    other = users(:regular_user).goodreads_imports.create!(status: :complete)
    @user.goodreads_imports.create!(status: :complete, source: :legacy_replay, legacy_import_id: 8101)
    sign_in_as(@user, stub_auth: true)

    get books_my_goodreads_imports_path

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal [@import.id], @controller.view_assigns.fetch("imports").map(&:id)
    assert_not_includes @controller.view_assigns.fetch("imports").map(&:id), other.id
  end

  test "create starts an import and redirects to its summary" do
    ::Books::Goodreads::RunImportJob.stubs(:perform_async)
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.goodreads_imports.count }, 1 do
      post books_my_goodreads_imports_path, params: {goodreads_import: {file: upload}}
    end

    assert_redirected_to books_my_goodreads_import_path(@user.goodreads_imports.order(:id).last)
  end

  test "a refused upload re-renders the page as unprocessable" do
    sign_in_as(@user, stub_auth: true)

    assert_no_difference -> { ::Books::GoodreadsImport.count } do
      post books_my_goodreads_imports_path, params: {goodreads_import: {file: nil}}
    end

    assert_response :unprocessable_entity
    assert_not_empty @controller.view_assigns.fetch("errors")
  end

  test "show is the member's own import; another member's is a 404" do
    sign_in_as(@user, stub_auth: true)
    get books_my_goodreads_import_path(@import)
    assert_response :success

    other = users(:regular_user).goodreads_imports.create!(status: :complete)
    get books_my_goodreads_import_path(other)
    assert_response :not_found
  end

  test "show asks the browser to refresh only while the import runs" do
    sign_in_as(@user, stub_auth: true)
    get books_my_goodreads_import_path(@import)
    assert_nil response.headers["Refresh"]

    @import.update!(status: :resolving)
    get books_my_goodreads_import_path(@import)
    assert_equal "10", response.headers["Refresh"]
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/books/my/goodreads_imports_controller_test.rb test/models/books/goodreads_import_row_test.rb`
Expected: errors (undefined route helpers, `member_status`).

- [ ] **Step 3: Implement**

Generate the controller (it creates the test file; keep the tests above):

```bash
bin/rails generate controller books/my/goodreads_imports index show --skip-routes --no-helper
```

`app/models/books/goodreads_import_row.rb`: add after the enums.

```ruby
    # What the member's summary page says about a row (Goodreads import spec §11).
    MEMBER_STATUS_LABELS = {
      working: "Working on it",
      matched: "Matched",
      new_pending_review: "Added, waiting for review",
      flagged: "Matched, but we're not sure",
      not_found: "Not found on Goodreads",
      skipped: "Already on your lists",
      failed: "Couldn't import"
    }.freeze

    def member_status
      return :working if pending?
      return :not_found if parked?
      return :skipped if skipped?
      return :failed if failed?

      book = goodreads_edition&.book
      return :skipped if book.nil?
      return :new_pending_review if book.provisional?
      return :flagged if goodreads_edition.match_decision&.needs_review?

      :matched
    end
```

`config/routes.rb`, inside the books constraint, below the reading-goals routes:

```ruby
    get "my/goodreads-import", to: "books/my/goodreads_imports#index", as: :books_my_goodreads_imports
    post "my/goodreads-import", to: "books/my/goodreads_imports#create"
    get "my/goodreads-import/:id", to: "books/my/goodreads_imports#show", as: :books_my_goodreads_import,
      constraints: {id: /\d+/}
```

`app/controllers/books/my/goodreads_imports_controller.rb`:

```ruby
# The member's Goodreads import pages (Goodreads import spec §11): how to
# export, the upload form and past imports, and a summary per import that
# refreshes itself while the import runs.
class Books::My::GoodreadsImportsController < ApplicationController
  include Cacheable

  REFRESH_SECONDS = 10
  ROWS_PER_PAGE = 100

  layout "books/application"

  before_action :prevent_caching
  before_action :require_signed_in!

  def index
    @imports = imports
  end

  def create
    result = Services::Books::GoodreadsImports::StartImport.call(user: current_user, upload: params.dig(:goodreads_import, :file))
    if result.success?
      redirect_to books_my_goodreads_import_path(result.data[:import]), status: :see_other
    else
      @errors = result.errors
      @imports = imports
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @import = imports.find(params[:id])
    response.headers["Refresh"] = REFRESH_SECONDS.to_s if @import.in_progress?
    @pagy, @rows = pagy(@import.rows.order(:row_number).includes(goodreads_edition: [:match_decision, :book]),
      limit: ROWS_PER_PAGE)
  end

  private

  def imports
    current_user.goodreads_imports.member.order(created_at: :desc)
  end
end
```

Views: run the `avoid-ai-writing` skill on every sentence of copy before committing. Use daisyUI 5 classes only: `fieldset`, `fieldset-legend`, bare `file-input`, `alert`, `table`, `badge`, `steps`.

- `index.html.erb`:
  - an `<h1>` "Import from Goodreads";
  - a short "How to export" ordered list: on Goodreads, My Books → Import and export → Export Library, then download the CSV;
  - one sentence that new books wait for a quick review before others see them;
  - `@errors` in an `alert alert-error` with `role="alert"`;
  - a `form_with url: books_my_goodreads_imports_path, scope: :goodreads_import, multipart: true` containing `f.file_field :file, accept: ".csv,text/csv", required: true, class: "file-input"` and a submit "Upload";
  - a history `table` of `@imports` (date, status humanized, rows, matched, new, not found), each linking to `books_my_goodreads_import_path(import)`.

  The form is disabled with a note when `@imports.any?(&:in_progress?)`.
- `show.html.erb`:
  - the status, plus a spinner `alert alert-info` while `@import.in_progress?`, saying the page refreshes itself;
  - the error when failed;
  - an `alert alert-warning` when `@import.review_rejected?` ("an admin removed the books this import added");
  - counters in a `stats` block with `bg-base-100`: matched, created (new, waiting for review), flagged, not found (parked), skipped;
  - a rows `table`: row number, title and author from `row.raw` (or the edition), the label `GoodreadsImportRow::MEMBER_STATUS_LABELS.fetch(row.member_status)`, and `row.outcome_detail || row.error`;
  - for a row with a book, a link to the book (`book_path(slug: book.slug)`) and a "Wrong book?" link to `books_book_correction_path(slug: book.slug)`;
  - `<%== @pagy.series_nav if @pagy.pages > 1 %>`;
  - a link back to `books_my_goodreads_imports_path`.

  Add `data-testid="import-status"` on the status text and `data-testid="import-row"` on each row; the E2E test reads them.

`app/views/books/shared/_nav_links.html.erb`: in both My Books lists, after "Reading Goals", add:

```erb
        <li><%= link_to "Import from Goodreads", books_my_goodreads_imports_path %></li>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `yarn build:all > /dev/null && bin/rails test test/controllers/books/my/goodreads_imports_controller_test.rb test/models/books/goodreads_import_row_test.rb test/lint/daisyui_v4_classes_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/books/my/goodreads_imports_controller.rb app/views/books/my/goodreads_imports app/models/books/goodreads_import_row.rb config/routes.rb app/views/books/shared/_nav_links.html.erb test/
git commit -m "Goodreads import: member upload and summary pages"
```

---

### Task 9: Admin pages

**Files:**
- Modify: `web-app/app/controllers/admin/books/goodreads_imports_controller.rb` (replaces the Task 4 placeholder)
- Create: `web-app/app/views/admin/books/goodreads_imports/index.html.erb`, `show.html.erb`
- Modify: `web-app/config/routes.rb`, `web-app/app/lib/admin/domain_nav.rb`
- Test: `web-app/test/controllers/admin/books/goodreads_imports_controller_test.rb`

**Interfaces:**
- Consumes: `Approve`, `Revert`, `Rerun`, `PromoteRecords`, `DeleteProvisional`, `GoodreadsImport#stuck?`.
- Produces:
  - route helpers `admin_books_goodreads_imports_path`, `admin_books_goodreads_import_path`;
  - `approve_`, `reject_`, `rerun_`, `promote_record_` and `delete_record_admin_books_goodreads_import_path`;
  - `bulk_approve_admin_books_goodreads_imports_path`.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

module Admin
  module Books
    class GoodreadsImportsControllerTest < ActionDispatch::IntegrationTest
      include GoodreadsImportHelper

      setup do
        host! Rails.application.config.domains[:books]
        @admin = users(:admin_user)
        @viewer = users(:books_viewer_user)
        @member = User.create!(email: "admin-import@example.com", role: :user, email_verified: false)
        @import = @member.goodreads_imports.create!(status: :complete)
        @book = ::Books::Book.create!(title: "Admin Import Book", provisional: true)
        @import.records.create!(record: @book, action: :created)
        ::Books::EnrichBookJob.stubs(:perform_async)
        ::Books::Authors::WikidataJob.stubs(:perform_async)
        ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
      end

      def import_ids
        css_select("[data-testid=import-row]").map { |row| row["data-import-id"].to_i }
      end

      test "signed-out users are redirected from every action" do
        get admin_books_goodreads_imports_path
        assert_redirected_to books_root_path
        [approve_admin_books_goodreads_import_path(@import), reject_admin_books_goodreads_import_path(@import),
          rerun_admin_books_goodreads_import_path(@import), promote_record_admin_books_goodreads_import_path(@import),
          delete_record_admin_books_goodreads_import_path(@import), bulk_approve_admin_books_goodreads_imports_path].each do |path|
          post path
          assert_redirected_to books_root_path
        end
      end

      test "a read-only viewer cannot approve, reject, rerun or change records" do
        sign_in_as(@viewer, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import)
        post reject_admin_books_goodreads_import_path(@import)
        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: @book.id}

        assert @import.reload.review_pending?
        assert ::Books::Book.exists?(@book.id)
      end

      test "index defaults to member imports and filters by status and review status" do
        replay = @member.goodreads_imports.create!(status: :complete, source: :legacy_replay, legacy_import_id: 9101)
        sign_in_as(@admin, stub_auth: true)

        get admin_books_goodreads_imports_path
        assert_includes import_ids, @import.id
        assert_not_includes import_ids, replay.id

        get admin_books_goodreads_imports_path(source: "legacy_replay")
        assert_equal [replay.id], import_ids

        get admin_books_goodreads_imports_path(review_status: "approved")
        assert_not_includes import_ids, @import.id
      end

      test "show renders every tab" do
        sign_in_as(@admin, stub_auth: true)

        %w[created flagged parked rows].each do |tab|
          get admin_books_goodreads_import_path(@import, tab: tab)
          assert_response :success
        end
      end

      test "approve promotes and records the reviewer" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import), params: {listed_book_ids: [@book.id], keep_book_ids: [@book.id]}

        assert_redirected_to admin_books_goodreads_import_path(@import)
        assert_not @book.reload.provisional?
        assert_equal @admin.id, @import.reload.reviewed_by_id
      end

      test "approve deletes a listed book that was unticked" do
        sign_in_as(@admin, stub_auth: true)

        post approve_admin_books_goodreads_import_path(@import), params: {listed_book_ids: [@book.id]}

        assert_not ::Books::Book.exists?(@book.id)
        assert @import.reload.review_approved?
      end

      test "bulk approve approves the selected imports" do
        second = User.create!(email: "admin-import-2@example.com", role: :user, email_verified: false)
          .goodreads_imports.create!(status: :complete)
        sign_in_as(@admin, stub_auth: true)

        post bulk_approve_admin_books_goodreads_imports_path, params: {ids: [@import.id, second.id]}

        assert_equal [true, true], [@import.reload.review_approved?, second.reload.review_approved?]
      end

      test "reject reverts the import" do
        sign_in_as(@admin, stub_auth: true)

        post reject_admin_books_goodreads_import_path(@import)

        assert @import.reload.review_rejected?
        assert_not ::Books::Book.exists?(@book.id)
      end

      test "rerun queues a failed import" do
        @import.update!(status: :failed)
        ::Books::Goodreads::RunImportJob.expects(:perform_async).with(@import.id)
        sign_in_as(@admin, stub_auth: true)

        post rerun_admin_books_goodreads_import_path(@import)

        assert @import.reload.queued?
      end

      test "promote_record and delete_record act on one created record" do
        other = ::Books::Book.create!(title: "Admin Import Other", provisional: true)
        @import.records.create!(record: other, action: :created)
        sign_in_as(@admin, stub_auth: true)

        post promote_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: @book.id}
        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: other.id}

        assert_not @book.reload.provisional?
        assert_not ::Books::Book.exists?(other.id)
      end

      test "a record outside the import's provenance cannot be promoted or deleted through it" do
        stranger = ::Books::Book.create!(title: "Admin Import Stranger", provisional: true)
        sign_in_as(@admin, stub_auth: true)

        post delete_record_admin_books_goodreads_import_path(@import), params: {record_type: "Books::Book", record_id: stranger.id}

        assert_response :not_found
        assert ::Books::Book.exists?(stranger.id)
      end
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/controllers/admin/books/goodreads_imports_controller_test.rb`
Expected: errors (undefined route helpers).

- [ ] **Step 3: Implement**

`config/routes.rb`: replace the Task 4 line with:

```ruby
      resources :goodreads_imports, only: [:index, :show] do
        member do
          post :approve
          post :reject
          post :rerun
          post :promote_record
          post :delete_record
        end
        collection do
          post :bulk_approve
        end
      end
```

`app/lib/admin/domain_nav.rb`: after the Repair Verdicts entry:

```ruby
          {label: "Goodreads Imports", icon: :list, path: -> { URL_HELPERS.admin_books_goodreads_imports_path }},
```

`app/controllers/admin/books/goodreads_imports_controller.rb`:

```ruby
# Books → Goodreads Imports (Goodreads import spec §10): every import, its
# created records, flagged decisions, parked rows and raw rows, and the
# approve, reject, rerun and per-record actions. Gates follow Repair Verdicts
# (R6): writing for approve, promote and rerun; deleting for reject, delete
# and an approve that unticks records.
class Admin::Books::GoodreadsImportsController < Admin::Books::BaseController
  SOURCES = ::Books::GoodreadsImport.sources.keys.freeze
  STATUSES = ::Books::GoodreadsImport.statuses.keys.freeze
  REVIEW_STATUSES = ::Books::GoodreadsImport.review_statuses.keys.freeze
  TABS = %w[created flagged parked rows].freeze
  RECORD_TYPES = {"Books::Book" => ::Books::Book, "Books::Author" => ::Books::Author}.freeze
  PER_PAGE = 50

  before_action :set_import, except: [:index, :bulk_approve]
  before_action :require_domain_write!, only: [:approve, :bulk_approve, :promote_record, :rerun]
  before_action :require_domain_delete!, only: [:reject, :delete_record]

  helper_method :filter_params

  def index
    @source = SOURCES.include?(params[:source]) ? params[:source] : "member"
    scope = ::Books::GoodreadsImport.where(source: @source).includes(:user)
    scope = scope.where(status: params[:status]) if STATUSES.include?(params[:status])
    scope = scope.where(review_status: params[:review_status]) if REVIEW_STATUSES.include?(params[:review_status])
    @pagy, @imports = pagy(scope.order(created_at: :desc), limit: PER_PAGE)
  end

  def show
    @tab = TABS.include?(params[:tab]) ? params[:tab] : "created"
    case @tab
    when "created"
      records = @import.records.created.where(record_type: RECORD_TYPES.keys)
      @books = ::Books::Book.where(id: records.where(record_type: "Books::Book").select(:record_id)).includes(:goodreads_editions, :authors)
      @authors = ::Books::Author.where(id: records.where(record_type: "Books::Author").select(:record_id))
    when "flagged"
      @flagged = @import.editions.joins(:match_decision).merge(::MatchDecision.needing_review).includes(:match_decision, :book)
    when "parked"
      @pagy, @rows = pagy(@import.rows.parked.order(:row_number), limit: PER_PAGE)
    when "rows"
      @pagy, @rows = pagy(@import.rows.order(:row_number), limit: PER_PAGE)
    end
  end

  def approve
    excluded = Array(params[:listed_book_ids]).map(&:to_i) - Array(params[:keep_book_ids]).map(&:to_i)
    excluded_authors = Array(params[:listed_author_ids]).map(&:to_i) - Array(params[:keep_author_ids]).map(&:to_i)
    if (excluded.any? || excluded_authors.any?) && !current_user_can_delete?
      redirect_to admin_books_goodreads_import_path(@import), alert: "Unticking records deletes them, which needs delete access."
      return
    end

    result = Services::Books::GoodreadsImports::Approve.call(import: @import, reviewer: current_user,
      exclude_book_ids: excluded, exclude_author_ids: excluded_authors)
    respond_with(result, "Approved. #{result.data&.dig(:promoted_book_ids)&.size.to_i} books promoted; enrichment is queued.")
  end

  def bulk_approve
    approved = ::Books::GoodreadsImport.where(id: Array(params[:ids]).map(&:to_i)).count do |import|
      Services::Books::GoodreadsImports::Approve.call(import: import, reviewer: current_user).success?
    end
    redirect_to admin_books_goodreads_imports_path(filter_params), notice: "Approved #{approved}."
  end

  def reject
    respond_with(Services::Books::GoodreadsImports::Revert.call(import: @import, reviewer: current_user),
      "Rejected. The member's imported items and reviews are removed.")
  end

  def rerun
    respond_with(Services::Books::GoodreadsImports::Rerun.call(import: @import), "Queued to run again.")
  end

  def promote_record
    record = provenance_record
    result = Services::Books::GoodreadsImports::PromoteRecords.call(
      books: (record.is_a?(::Books::Book) ? [record] : []), authors: (record.is_a?(::Books::Author) ? [record] : [])
    )
    respond_with(result, "Promoted.")
  end

  def delete_record
    respond_with(Services::Books::GoodreadsImports::DeleteProvisional.call(import: @import, record: provenance_record), "Deleted.")
  end

  private

  def set_import
    @import = ::Books::GoodreadsImport.find(params[:id])
  end

  # Only a record this import created: an import page is not a way to delete
  # any provisional record by id.
  def provenance_record
    klass = RECORD_TYPES.fetch(params[:record_type]) { raise ActiveRecord::RecordNotFound }
    @import.records.created.find_by!(record_type: klass.name, record_id: params[:record_id])
    klass.find(params[:record_id])
  end

  def respond_with(result, notice)
    if result.success?
      redirect_to admin_books_goodreads_import_path(@import), notice: notice
    else
      redirect_to admin_books_goodreads_import_path(@import), alert: result.errors.to_sentence
    end
  end

  def filter_params(overrides = {})
    request.query_parameters.slice("source", "status", "review_status").merge(overrides.stringify_keys).compact
  end
end
```

Note: `Enumerable#count` with a block runs the block for each import. If Standard flags it, use `filter { … }.size` instead.

Views. Admin layout; daisyUI 5. The repair verdicts views are the model.

- `index.html.erb`:
  - a filter form (source, status, review status selects);
  - a table with `data-testid="import-row" data-import-id=…` showing user email, created date, source, status (badge, plus a `badge-warning` "stuck" when `import.stuck?`), review status, rows, matched, created, flagged, parked, skipped, AI calls, and a link to show;
  - a checkbox `ids[]` for each `complete` member import pending review when `current_user_can_write?`, with the checkboxes carrying `form: "bulk-approve-form"`;
  - one `form_with url: bulk_approve_…, id: "bulk-approve-form"` holding the "Approve selected" button;
  - `@pagy.series_nav`.
- `show.html.erb`:
  - a header with user, source, status, review status and every counter;
  - the error, if any;
  - buttons, as `button_to` (each its own form, never nested):
    - Approve (`form: {id: "approve-form"}`), when complete and pending, `current_user_can_write?`;
    - Reject, delete gate, `turbo_confirm`;
    - Rerun, when failed or stuck.
  - tabs (`tabs tabs-border`, links with `?tab=`);
  - **created**:
    - a table of `@books`: title (link to `admin_books_book_path`), authors, provisional badge, each edition's verification, and a link to `admin_books_match_decision_path(edition.match_decision)` when present;
    - per book, a hidden `listed_book_ids[]` and a checked "keep" checkbox `keep_book_ids[]`, both with `form: "approve-form"`;
    - per-record Promote and Delete `button_to` (params `record_type`, `record_id`), shown while provisional;
    - the same for `@authors`, with `listed_author_ids[]` / `keep_author_ids[]`.
  - **flagged**: editions with title, author, the book, the decision's confidence and reason, linked to `admin_books_match_decision_path`.
  - **parked** and **rows**: row number, `raw["Title"]`, `raw["Author"]`, outcome, `outcome_detail`, `error`, and `raw` inside a `<details>`, paginated.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/admin/books/goodreads_imports_controller_test.rb test/lib/admin/domain_nav_test.rb test/lint/daisyui_v4_classes_test.rb`
Expected: PASS. If `domain_nav_test` pins the books entries, add the new entry to its expectation.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/admin/books/goodreads_imports_controller.rb app/views/admin/books/goodreads_imports config/routes.rb app/lib/admin/domain_nav.rb test/
git commit -m "Goodreads import: admin index, show, approve, reject, rerun, per-record actions"
```

---

### Task 10: E2E

**Files:**
- Modify: `web-app/lib/tasks/e2e.rake`
- Create: `web-app/e2e/fixtures/goodreads_export.csv`, `web-app/e2e/tests/books/account/goodreads-import.spec.ts`, `web-app/e2e/tests/books/admin/goodreads-imports.spec.ts`
- Test: `web-app/test/lib/tasks/e2e_goodreads_import_rake_test.rb`

**Interfaces:**
- Consumes: the member and admin routes (Tasks 8–9).
- Produces:
  - `bin/rails e2e:goodreads_import_seed` prints JSON `{"import_id":…, "book_id":…}` on its last line;
  - `bin/rails e2e:goodreads_import_cleanup` removes every import, edition, book and author the seed or the upload made.

The seed owns these records, all found by marker:
- **The seed edition:** Goodreads id `999000001`, title `GOODREADS_SEED_TITLE = "E2E Goodreads Import Seed"`, author `"E2E Goodreads Import Author"`. It is resolved to the provisional seed book, so an upload of the fixture CSV resolves from the cache with no finder, AI or Open Library call, even if a dev Sidekiq runs it.
- **One complete member import** for the Playwright admin user (the account and admin projects share that login), pending review, whose provenance holds the seed book and author.
- **One applied row** naming the seed edition.

The cleanup finds by marker:
- every import with a row naming the seed edition;
- each import's file, purged synchronously, not with `purge_later`;
- the seed edition and the seed book and author, each by title or name;
- list items and reviews of the seed book, removed by the book's destroy.

The admin spec approves with the seed book **unticked**. That deletes it, and nothing is promoted, so no enrichment job reaches the dev queue.

- [ ] **Step 1: Write the failing rake test**

`test/lib/tasks/e2e_goodreads_import_rake_test.rb`: mirror `test/lib/tasks/e2e_repair_verdicts_rake_test.rb`. Load the tasks the same way. Stub `playwright_env` (or write a temporary `e2e/.env` the way that test does) to the email of a fixture user. Then assert three things:
- `e2e:goodreads_import_seed` run twice leaves one seed import, one seed edition and one seed book, and prints JSON whose `import_id` is that import;
- after an extra import whose row names the seed edition, `e2e:goodreads_import_cleanup` leaves none of them;
- the cleanup touches no other import (the fixture `regular_user_import` survives).

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/lib/tasks/e2e_goodreads_import_rake_test.rb`
Expected: errors, because `Don't know how to build task 'e2e:goodreads_import_seed'`.

- [ ] **Step 3: Implement**

`lib/tasks/e2e.rake`: add at the top, beside the other markers:

```ruby
# The seed edition, book and author e2e:goodreads_import_seed owns. The id is
# far above any real Goodreads id in the dev data.
GOODREADS_SEED_ID = 999_000_001
GOODREADS_SEED_TITLE = "E2E Goodreads Import Seed"
GOODREADS_SEED_AUTHOR = "E2E Goodreads Import Author"
```

Add inside `namespace :e2e`:

```ruby
  desc "Seed a finished Goodreads import for the Playwright admin, with one provisional book (idempotent)"
  task goodreads_import_seed: :environment do
    user = User.find_by!(email: playwright_email)
    author = Books::Author.find_or_create_by!(name: GOODREADS_SEED_AUTHOR) { |a| a.provisional = true }
    book = Books::Book.find_by(title: GOODREADS_SEED_TITLE) || Books::Book.create!(title: GOODREADS_SEED_TITLE, provisional: true)
    Books::BookAuthor.find_or_create_by!(book: book, author: author) { |ba| ba.position = 1 }
    signature = Books::Goodreads::ExportRow.signature(GOODREADS_SEED_TITLE, GOODREADS_SEED_AUTHOR)
    edition = Books::GoodreadsEdition.find_or_create_by!(goodreads_book_id: GOODREADS_SEED_ID, signature: signature) do |e|
      e.assign_attributes(title: GOODREADS_SEED_TITLE, primary_author: GOODREADS_SEED_AUTHOR)
    end
    edition.update!(book: book, resolution: :created, verification: :verified, resolved_at: edition.resolved_at || Time.current)
    import = Books::GoodreadsImport.joins(:rows).where(user: user, status: :complete, review_status: :pending)
      .where(books_goodreads_import_rows: {goodreads_edition_id: edition.id}).first
    import ||= user.goodreads_imports.create!(status: :complete, rows_count: 1, editions_count: 1, created_count: 1,
      started_at: Time.current, finished_at: Time.current).tap do |created|
      created.rows.create!(row_number: 1, goodreads_edition: edition, outcome: :applied, exclusive_shelf: "to-read",
        raw: {"Book Id" => GOODREADS_SEED_ID.to_s, "Title" => GOODREADS_SEED_TITLE, "Author" => GOODREADS_SEED_AUTHOR})
      [book, author].each { |record| created.records.create!(record: record, action: :created) }
    end
    puts({import_id: import.id, book_id: book.id}.to_json)
  end

  desc "Remove what e2e:goodreads_import_seed and the Goodreads import E2E upload created"
  task goodreads_import_cleanup: :environment do
    edition_ids = Books::GoodreadsEdition.where(goodreads_book_id: GOODREADS_SEED_ID).pluck(:id)
    Books::GoodreadsImport.where(id: Books::GoodreadsImportRow.where(goodreads_edition_id: edition_ids).select(:import_id)).find_each do |import|
      Services::Books::GoodreadsImports::Revert.call(import: import, reviewer: import.user) if import.member? && !import.review_rejected? && !import.in_progress?
      import.file.purge if import.file.attached?
      import.destroy!
    end
    Books::GoodreadsEdition.where(id: edition_ids).find_each(&:destroy!)
    Books::Book.where(title: GOODREADS_SEED_TITLE).find_each(&:destroy!)
    Books::Author.where(name: GOODREADS_SEED_AUTHOR).find_each(&:destroy!)
    puts "cleaned up Goodreads import E2E records"
  end
```

`destroy!` on an import that still has rows: the rows go with `dependent: :delete_all`. The edition's `restrict_with_exception` is satisfied because the rows are gone first. An upload that is still queued is destroyed without a revert; it wrote nothing. An upload the dev worker actually ran is reverted first.

`e2e/fixtures/goodreads_export.csv`:

```csv
Book Id,Title,Author,Additional Authors,ISBN,ISBN13,My Rating,Year Published,Original Publication Year,Date Read,Date Added,Bookshelves,Bookshelves with positions,Exclusive Shelf,My Review,Private Notes,Read Count
999000001,E2E Goodreads Import Seed,E2E Goodreads Import Author,,,,0,,,,2026/10/01,,,to-read,,,0
```

`e2e/tests/books/account/goodreads-import.spec.ts`:

```ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Uploads a one-row export whose only edition the seed already resolved, so
// a dev worker that picks the import up resolves it from the cache with no
// finder or AI call. Without a worker the import stays queued; the page is
// tested either way. Cleanup removes the upload and the seed.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

test.describe("Books account — Goodreads import", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    rails("e2e:goodreads_import_cleanup");
    rails("e2e:goodreads_import_seed");
  });

  test.afterAll(() => {
    rails("e2e:goodreads_import_cleanup");
  });

  test("a member uploads an export and lands on its summary", async ({ page }) => {
    await page.goto("/my/goodreads-import");
    await expect(page.getByRole("heading", { level: 1 })).toContainText("Goodreads");

    await page.locator('input[type="file"]').setInputFiles(path.join(WEB_APP, "e2e", "fixtures", "goodreads_export.csv"));
    await page.getByRole("button", { name: "Upload" }).click();

    await expect(page).toHaveURL(/\/my\/goodreads-import\/\d+$/);
    await expect(page.getByTestId("import-status")).toBeVisible();

    await page.goto("/my/goodreads-import");
    await expect(page.getByRole("link", { name: /\d/ }).first()).toBeVisible();
  });
});
```

`e2e/tests/books/admin/goodreads-imports.spec.ts`:

```ts
import { test, expect } from "@playwright/test";
import { execSync } from "node:child_process";
import path from "node:path";

// Approves the seeded import with its one created book unticked: the book is
// deleted rather than promoted, so no enrichment job reaches the dev queue.
const WEB_APP = path.resolve(__dirname, "..", "..", "..", "..");
const rails = (task: string) => execSync(`bin/rails ${task}`, { cwd: WEB_APP, encoding: "utf8" });

let importId: number;

test.describe("Books admin — Goodreads imports", () => {
  test.describe.configure({ mode: "serial" });

  test.beforeAll(() => {
    rails("e2e:goodreads_import_cleanup");
    const lines = rails("e2e:goodreads_import_seed").trim().split("\n");
    importId = JSON.parse(lines[lines.length - 1]).import_id;
  });

  test.afterAll(() => {
    rails("e2e:goodreads_import_cleanup");
  });

  test("an admin unticks the created book and approves the import", async ({ page }) => {
    await page.goto("/admin/goodreads_imports");
    const row = page.locator(`[data-testid="import-row"][data-import-id="${importId}"]`);
    await expect(row).toBeVisible();
    await row.getByRole("link").first().click();

    await expect(page).toHaveURL(new RegExp(`/admin/goodreads_imports/${importId}`));
    await page.getByRole("checkbox", { name: /keep/i }).first().uncheck();
    await page.getByRole("button", { name: "Approve" }).click();

    await expect(page.getByRole("alert")).toContainText("Approved");
    await expect(page.getByTestId("review-status")).toHaveText("Approved");
  });
});
```

The show view needs `data-testid="review-status"` on the review status text. Each keep checkbox needs an accessible name that includes "Keep", for example `aria-label="Keep <title>"`.

- [ ] **Step 4: Run the rake test, then the E2E specs**

Run: `bin/rails test test/lib/tasks/e2e_goodreads_import_rake_test.rb`
Expected: PASS.

Then, after confirming port 3000 belongs to this worktree (AGENTS.md snippet), run `yarn build:all` and `bin/rails server`, then:

Run: `yarn test:e2e --project=books-account e2e/tests/books/account/goodreads-import.spec.ts` and `yarn test:e2e --project=books-admin e2e/tests/books/admin/goodreads-imports.spec.ts`
Expected: both pass. If port 3000 belongs to another checkout, stop and tell the user. Do not kill their server.

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/e2e.rake e2e/ test/lib/tasks/e2e_goodreads_import_rake_test.rb app/views
git commit -m "Goodreads import: E2E for upload and admin approval"
```

---

### Task 11: Docs and the full suite

**Files:**
- Modify: `docs/features/goodreads-import.md`

- [ ] **Step 1: Update the feature doc**

- **Status table:** row 6 becomes "this doc".
- **Replace** "No member flow calls the resolver yet…" with one sentence naming the member pages.
- **Replace** the last paragraph of "Goodreads verification" ("Moving an import through verifying … belong to the import job (increment 6).") with a pointer to the new section.
- **Add a `## Member import` section**, before "Legacy replay", covering:
  - the routes (`/my/goodreads-import`) and the upload limits (`config/initializers/goodreads_imports.rb`);
  - the phases and the claim (R7), the resume from `SettleEditionsJob` and the sweep, Rerun;
  - WriteLibrary's shelf and review rules, briefly, with R2 (skipped), R3 (what revert does not restore) and R4 (goal purge);
  - admin: Books → Goodreads Imports, the gates (R6), Approve (R5: what is promoted, unticking deletes), Reject, per-record actions, the email to `notify_to`;
  - replay imports are not approved or rejected here (R8).

  Each fact goes in once.

- [ ] **Step 2: Run the full suite, lint and zeitwerk**

Run: `bin/rails test > ../.superpowers/inc6-suite.log 2>&1; tail -5 ../.superpowers/inc6-suite.log`
Expected: 0 failures, 0 errors, and no new warning lines (compare `grep -ic warn` against main's).

Run: `bundle exec standardrb` → no offenses.
Run: `CI=1 bin/rails zeitwerk:check` → "All is good!"

- [ ] **Step 3: Commit**

```bash
git add ../docs/features/goodreads-import.md
git commit -m "Goodreads import: member import docs"
```
