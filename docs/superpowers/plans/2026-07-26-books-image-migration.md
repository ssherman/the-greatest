# Books Cover Image Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the 37,296 legacy Book `primary_image` covers from the old TheGreatestBooks Cloudflare R2 bucket into the new app as polymorphic `Image` records on `Books::Book`, uploaded to the new R2 bucket via ActiveStorage.

**Architecture:** A `data_migration:book_images` rake task runs `Services::BooksMigration::BookImageMigrator`, which streams legacy `active_storage_attachments` (Book/primary_image) joined to their blobs and enqueues one `Books::MigrateCoverImageJob` per image. Each job reads the original from the old R2 bucket via the S3 API (`Services::BooksMigration::LegacyR2`), attaches it to a new `Image` through ActiveStorage (which uploads to the new R2 bucket and regenerates the 100/150/250 variants), and is idempotent (skips a book that already has a primary image).

**Tech Stack:** Rails 8, ActiveStorage on Cloudflare R2, `aws-sdk-s3`, Sidekiq, Minitest + Mocha. Design spec: `docs/superpowers/specs/2026-07-25-book-cover-image-migration-design.md`.

## Global Constraints

- Run **all** commands from `web-app/`.
- Work on the current feature branch **`books-image-migration`** (never commit to `main`).
- Namespace all media code (`Books::`); tests mirror the namespace and directory.
- **Skinny models, fat services.** Migration services live in `app/lib/services/books_migration/` and subclass the base `Services::BooksMigration::Migrator`, which returns `{success: true/false, data: {model:, count:}}` (or `{success: false, error:, data:}`).
- **Generators:** create the Sidekiq job with `bin/rails generate sidekiq:job books/migrate_cover_image` (jobs live in `app/sidekiq/`, NOT `app/jobs/`). **Hand-create** the legacy replica models and the migration service/helper — every existing `LegacyBooks::*` and `Services::BooksMigration::*` is hand-written; `rails g model` would wrongly add a primary-DB migration + fixture.
- No code comments unless asked — write self-documenting code.
- **Testing:** Minitest + Mocha + fixtures. Stub the R2 S3 client — never hit the network in tests. 100% coverage of public methods; never test private methods. Check actual fixture names before referencing.
- **Idempotency:** the job skips a book that already has a primary `Image` (`book.images.where(primary: true).exists?`).
- **ENV vars** (already in `web-app/.env` and encrypted `secrets/.env.production`): `LEGACY_R2_ACCOUNT_ID`, `LEGACY_R2_ACCESS_KEY`, `LEGACY_R2_SECRET_KEY`, `LEGACY_R2_BUCKET`. The endpoint is built as `https://<account-id>.r2.cloudflarestorage.com`.
- **Gate before "done":** `bundle exec standardrb` and `bin/rails test` must pass. The owner does **not** use brakeman. No new user-facing page → **no** Playwright E2E.
- Every git commit message ends with the trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

- `app/lib/services/books_migration/legacy_r2.rb` — **new.** S3 client + endpoint/bucket helper for the old R2 bucket (reads the four `LEGACY_R2_*` env vars). One responsibility: connect to legacy R2.
- `app/sidekiq/books/migrate_cover_image_job.rb` — **new (generated).** Per-book worker: fetch original from legacy R2 → attach a primary `Image` → save. Idempotent.
- `app/models/legacy_books/active_storage_blob.rb` — **new.** Read-only replica mapping for `active_storage_blobs`.
- `app/models/legacy_books/active_storage_attachment.rb` — **new.** Read-only replica mapping for `active_storage_attachments`, `belongs_to :blob`.
- `app/lib/services/books_migration/book_image_migrator.rb` — **new.** Streams legacy Book primary_image attachments, enqueues one job per image.
- `lib/tasks/data_migration.rake` — **modify.** Add the standalone `book_images` task (not in `:all`).
- Tests mirror each of the above under `test/`.

Task order (dependencies): **Task 1** (LegacyR2) → **Task 2** (job, consumes LegacyR2) → **Task 3** (migrator + models + rake, consumes the job) → **Task 4** (real-R2 integration run, no new code).

---

### Task 1: `Services::BooksMigration::LegacyR2` S3 client helper

**Files:**
- Create: `app/lib/services/books_migration/legacy_r2.rb`
- Test: `test/lib/services/books_migration/legacy_r2_test.rb`

**Interfaces:**
- Consumes: the four `LEGACY_R2_*` env vars.
- Produces:
  - `Services::BooksMigration::LegacyR2.endpoint -> String` (`"https://<account-id>.r2.cloudflarestorage.com"`)
  - `Services::BooksMigration::LegacyR2.bucket -> String`
  - `Services::BooksMigration::LegacyR2.client -> Aws::S3::Client` (region `"auto"`, path-style, pointed at the endpoint)

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/legacy_r2_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class LegacyR2Test < ActiveSupport::TestCase
      setup do
        @original = ENV.to_h.slice(
          "LEGACY_R2_ACCOUNT_ID", "LEGACY_R2_ACCESS_KEY", "LEGACY_R2_SECRET_KEY", "LEGACY_R2_BUCKET"
        )
        ENV["LEGACY_R2_ACCOUNT_ID"] = "test-account"
        ENV["LEGACY_R2_ACCESS_KEY"] = "test-access-key"
        ENV["LEGACY_R2_SECRET_KEY"] = "test-secret-key"
        ENV["LEGACY_R2_BUCKET"] = "test-bucket"
      end

      teardown do
        %w[LEGACY_R2_ACCOUNT_ID LEGACY_R2_ACCESS_KEY LEGACY_R2_SECRET_KEY LEGACY_R2_BUCKET].each { |k| ENV.delete(k) }
        @original.each { |k, v| ENV[k] = v }
      end

      test "endpoint is built from the account id" do
        assert_equal "https://test-account.r2.cloudflarestorage.com", LegacyR2.endpoint
      end

      test "bucket returns the LEGACY_R2_BUCKET env var" do
        assert_equal "test-bucket", LegacyR2.bucket
      end

      test "client is an Aws::S3::Client in region auto" do
        client = LegacyR2.client
        assert_instance_of Aws::S3::Client, client
        assert_equal "auto", client.config.region
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/legacy_r2_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::LegacyR2`.

- [ ] **Step 3: Write minimal implementation**

Create `app/lib/services/books_migration/legacy_r2.rb`:

```ruby
require "aws-sdk-s3"

module Services
  module BooksMigration
    # S3-API access to the OLD TheGreatestBooks Cloudflare R2 bucket, the source
    # of the legacy book cover originals. Credentials come from four LEGACY_R2_*
    # env vars (dev: web-app/.env; prod: encrypted secrets/.env.production). These
    # are transient — needed only by the one-time data_migration:book_images run.
    module LegacyR2
      def self.endpoint
        "https://#{ENV.fetch("LEGACY_R2_ACCOUNT_ID")}.r2.cloudflarestorage.com"
      end

      def self.bucket
        ENV.fetch("LEGACY_R2_BUCKET")
      end

      def self.client
        Aws::S3::Client.new(
          endpoint: endpoint,
          access_key_id: ENV.fetch("LEGACY_R2_ACCESS_KEY"),
          secret_access_key: ENV.fetch("LEGACY_R2_SECRET_KEY"),
          region: "auto",
          force_path_style: true
        )
      end
    end
  end
end
```

(The comment here documents non-obvious provenance/lifecycle of the creds — allowed under the "no comments unless it aids the reader" spirit; keep it, matching how other `books_migration` files carry a short intent header.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/legacy_r2_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Lint**

Run: `bundle exec standardrb app/lib/services/books_migration/legacy_r2.rb test/lib/services/books_migration/legacy_r2_test.rb`
Expected: no offenses (run with `--fix` if it reports formatting).

- [ ] **Step 6: Commit**

```bash
git add app/lib/services/books_migration/legacy_r2.rb test/lib/services/books_migration/legacy_r2_test.rb
git commit -m "Add LegacyR2 S3 client helper for old book-cover R2 bucket" \
  -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Books::MigrateCoverImageJob`

**Files:**
- Create (generated): `app/sidekiq/books/migrate_cover_image_job.rb`
- Test (generated, then filled in): `test/sidekiq/books/migrate_cover_image_job_test.rb`

**Interfaces:**
- Consumes: `Services::BooksMigration::LegacyR2.client` / `.bucket` (Task 1); `Books::Book`; the shared `Image` model (`book.images.build(primary:, metadata:)`, `image.file.attach(io:, filename:, content_type:)`).
- Produces: `Books::MigrateCoverImageJob.perform_async(book_id, key, filename, content_type)` and `#perform(book_id, key, filename, content_type)`. Creates one primary `Image` (`parent: Books::Book`) with `metadata = {"source" => "legacy_migration", "legacy_blob_key" => key}`.

- [ ] **Step 1: Generate the job (creates job + test file)**

Run: `bin/rails generate sidekiq:job books/migrate_cover_image`
Expected: creates `app/sidekiq/books/migrate_cover_image_job.rb` and `test/sidekiq/books/migrate_cover_image_job_test.rb`.

- [ ] **Step 2: Write the failing test**

Replace the generated `test/sidekiq/books/migrate_cover_image_job_test.rb` with:

```ruby
require "test_helper"

module Books
  class MigrateCoverImageJobTest < ActiveSupport::TestCase
    setup do
      @book = Books::Book.create!(title: "Cover Migration Book")
    end

    def s3_response(bytes)
      Struct.new(:body).new(StringIO.new(bytes))
    end

    def stub_legacy_r2
      client = mock
      Services::BooksMigration::LegacyR2.stubs(:client).returns(client)
      Services::BooksMigration::LegacyR2.stubs(:bucket).returns("legacy-bucket")
      client
    end

    test "fetches the original from legacy R2 and creates a primary Image with provenance" do
      client = stub_legacy_r2
      client.expects(:get_object)
        .with(bucket: "legacy-bucket", key: "blobkey123")
        .returns(s3_response("fake-jpeg-bytes"))

      Books::MigrateCoverImageJob.new.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")

      image = @book.reload.images.where(primary: true).first
      assert_not_nil image
      assert image.file.attached?
      assert_equal "cover.jpg", image.file.filename.to_s
      assert_equal "image/jpeg", image.file.blob.content_type
      assert_equal "legacy_migration", image.metadata["source"]
      assert_equal "blobkey123", image.metadata["legacy_blob_key"]
    end

    test "skips (no R2 fetch) when the book already has a primary image" do
      existing = @book.images.build(primary: true)
      existing.file.attach(io: StringIO.new("existing"), filename: "existing.jpg", content_type: "image/jpeg")
      existing.save!

      Services::BooksMigration::LegacyR2.expects(:client).never

      Books::MigrateCoverImageJob.new.perform(@book.id, "blobkey123", "cover.jpg", "image/jpeg")

      assert_equal 1, @book.reload.images.where(primary: true).count
    end

    test "skips (no R2 fetch, no raise) when the book does not exist" do
      Services::BooksMigration::LegacyR2.expects(:client).never
      missing_id = Books::Book.maximum(:id).to_i + 999_999

      assert_nothing_raised do
        Books::MigrateCoverImageJob.new.perform(missing_id, "blobkey123", "cover.jpg", "image/jpeg")
      end
    end

    test "is configured to retry" do
      assert_equal 5, Books::MigrateCoverImageJob.get_sidekiq_options["retry"]
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/sidekiq/books/migrate_cover_image_job_test.rb`
Expected: FAIL — the first test fails because the generated `perform` is empty (no `Image` is created; `image` is nil).

- [ ] **Step 4: Write minimal implementation**

Replace `app/sidekiq/books/migrate_cover_image_job.rb` with:

```ruby
class Books::MigrateCoverImageJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 5

  def perform(book_id, key, filename, content_type)
    book = Books::Book.find_by(id: book_id)
    return unless book
    return if book.images.where(primary: true).exists?

    response = Services::BooksMigration::LegacyR2.client.get_object(
      bucket: Services::BooksMigration::LegacyR2.bucket,
      key: key
    )

    image = book.images.build(
      primary: true,
      metadata: {source: "legacy_migration", legacy_blob_key: key}
    )
    image.file.attach(
      io: StringIO.new(response.body.read),
      filename: filename,
      content_type: content_type
    )
    image.save!
  end
end
```

Note on `metadata`: assigned with symbol keys but read back as string keys after `reload` (the `Image` model's `store :metadata, coder: ActiveRecord::Coders::JSON`) — that is why the test reloads before asserting `image.metadata["source"]`. The job intentionally does **not** rescue: a failed R2 fetch should propagate so Sidekiq retries (transient network errors), and after retries it lands in the dead set (visible), never silently dropped.

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/sidekiq/books/migrate_cover_image_job_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 6: Lint**

Run: `bundle exec standardrb app/sidekiq/books/migrate_cover_image_job.rb test/sidekiq/books/migrate_cover_image_job_test.rb`
Expected: no offenses (use `--fix` if needed).

- [ ] **Step 7: Commit**

```bash
git add app/sidekiq/books/migrate_cover_image_job.rb test/sidekiq/books/migrate_cover_image_job_test.rb
git commit -m "Add Books::MigrateCoverImageJob to import a legacy cover from R2" \
  -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Legacy AS models + `BookImageMigrator` + rake task

**Files:**
- Create: `app/models/legacy_books/active_storage_blob.rb`
- Create: `app/models/legacy_books/active_storage_attachment.rb`
- Create: `app/lib/services/books_migration/book_image_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/book_image_migrator_test.rb`

**Interfaces:**
- Consumes: `Books::MigrateCoverImageJob.perform_async(book_id, key, filename, content_type)` (Task 2); the base `Services::BooksMigration::Migrator`.
- Produces: `Services::BooksMigration::BookImageMigrator.call -> {success:, data: {model: "Books::Book#primary_image", count:}}`; the rake task `data_migration:book_images`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/books_migration/book_image_migrator_test.rb`:

```ruby
require "test_helper"

module Services
  module BooksMigration
    class BookImageMigratorTest < ActiveSupport::TestCase
      # Stub the join/stream so the legacy replica connection is never opened.
      def run_migrator(rows)
        migrator = BookImageMigrator.new
        migrator.stubs(:legacy_each).multiple_yields(*rows.zip)
        migrator.call
      end

      def row(overrides = {})
        {"book_id" => 42, "key" => "blobkey", "filename" => "cover.jpg", "content_type" => "image/jpeg"}.merge(overrides)
      end

      test "enqueues one MigrateCoverImageJob per legacy attachment with the blob fields" do
        Books::MigrateCoverImageJob.expects(:perform_async).with(42, "blobkey", "cover.jpg", "image/jpeg").once

        result = run_migrator([row])

        assert result[:success], result[:error]
        assert_equal 1, result[:data][:count]
        assert_equal "Books::Book#primary_image", result[:data][:model]
      end

      test "enqueues a job for every row" do
        Books::MigrateCoverImageJob.expects(:perform_async).twice

        result = run_migrator([row("book_id" => 1), row("book_id" => 2)])

        assert result[:success], result[:error]
        assert_equal 2, result[:data][:count]
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/services/books_migration/book_image_migrator_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::BookImageMigrator`.

- [ ] **Step 3: Create the legacy replica models**

Create `app/models/legacy_books/active_storage_blob.rb`:

```ruby
module LegacyBooks
  class ActiveStorageBlob < Record
    self.table_name = "active_storage_blobs"
  end
end
```

Create `app/models/legacy_books/active_storage_attachment.rb`:

```ruby
module LegacyBooks
  class ActiveStorageAttachment < Record
    self.table_name = "active_storage_attachments"

    belongs_to :blob, class_name: "LegacyBooks::ActiveStorageBlob"
  end
end
```

- [ ] **Step 4: Create the migrator**

Create `app/lib/services/books_migration/book_image_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy Book `primary_image` ActiveStorage attachments -> new polymorphic
    # Image records on Books::Book. Book ids were preserved in Phase 1b, so the
    # legacy attachment's record_id is the new Books::Book id directly. Streams
    # each attachment (joined to its blob) and enqueues one MigrateCoverImageJob
    # per image; the job does the R2 fetch + attach + variant regeneration and
    # holds the idempotency guard. Re-running re-enqueues; already-done books
    # no-op in the job.
    class BookImageMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::ActiveStorageAttachment
      end

      def model_key
        "Books::Book#primary_image"
      end

      def legacy_each
        LegacyBooks::ActiveStorageAttachment
          .where(record_type: "Book", name: "primary_image")
          .includes(:blob)
          .find_each(batch_size: BATCH_SIZE) do |attachment|
            yield({
              "book_id" => attachment.record_id,
              "key" => attachment.blob.key,
              "filename" => attachment.blob.filename,
              "content_type" => attachment.blob.content_type
            })
          end
      end

      def upsert_row(attrs)
        Books::MigrateCoverImageJob.perform_async(
          attrs["book_id"], attrs["key"], attrs["filename"], attrs["content_type"]
        )
      end
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/lib/services/books_migration/book_image_migrator_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 6: Add the rake task**

In `lib/tasks/data_migration.rake`, add this task **inside** the `namespace :data_migration do` block, just before the `task all:` line (do **not** add it to the `:all` dependency list):

```ruby
  desc "Enqueue cover-image import jobs for legacy Book primary_images (reads old R2 via S3 API; needs LEGACY_R2_* env)"
  task book_images: :environment do
    pp Services::BooksMigration::BookImageMigrator.call
  end
```

- [ ] **Step 7: Verify the rake task is wired (no real run)**

Run: `bin/rails -T data_migration:book_images`
Expected: lists `rake data_migration:book_images  # Enqueue cover-image import jobs ...`.

- [ ] **Step 8: Run the full migration test suite for this area + lint**

Run: `bin/rails test test/lib/services/books_migration/ test/sidekiq/books/`
Expected: PASS (all migration + job tests green).

Run: `bundle exec standardrb app/models/legacy_books/active_storage_blob.rb app/models/legacy_books/active_storage_attachment.rb app/lib/services/books_migration/book_image_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/book_image_migrator_test.rb`
Expected: no offenses (use `--fix` if needed).

- [ ] **Step 9: Run the whole suite (regression gate)**

Run: `bin/rails test`
Expected: all green (baseline ~4500+ tests, 0 failures/errors).

- [ ] **Step 10: Commit**

```bash
git add app/models/legacy_books/active_storage_blob.rb \
  app/models/legacy_books/active_storage_attachment.rb \
  app/lib/services/books_migration/book_image_migrator.rb \
  lib/tasks/data_migration.rake \
  test/lib/services/books_migration/book_image_migrator_test.rb
git commit -m "Add BookImageMigrator + data_migration:book_images rake task" \
  -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: End-to-end run against real legacy R2 (dev) — no new code

This task exercises the real path (legacy DB read → old R2 fetch → new R2 upload → variants). It is operational: it hits the real old R2 bucket and enqueues real jobs. Requires `LEGACY_R2_*` in `web-app/.env` (already added and smoke-tested) and Sidekiq running to process jobs (`bin/dev`).

- [ ] **Step 1: Snapshot the dev DB (house rule for bulk work)**

Run: `bin/snapshot-dev-db.sh --label pre-book-images`
Expected: snapshot created (restore later with `bin/snapshot-dev-db.sh --restore` if needed). The migration is additive/reversible (delete the migrated `Image` rows), but snapshot anyway.

- [ ] **Step 2: Inline smoke on 3 real books (bypasses Sidekiq, proves the real fetch+attach)**

Run:

```bash
bin/rails runner '
LegacyBooks::ActiveStorageAttachment
  .where(record_type: "Book", name: "primary_image")
  .includes(:blob)
  .limit(3)
  .each do |att|
    Books::MigrateCoverImageJob.new.perform(att.record_id, att.blob.key, att.blob.filename, att.blob.content_type)
    book = Books::Book.find(att.record_id)
    img = book.images.where(primary: true).first
    puts "book #{book.id}: primary? #{!img.nil?}  bytes=#{img&.file&.blob&.byte_size}  type=#{img&.file&.blob&.content_type}"
  end
'
```

Expected: three lines, each `primary? true` with a non-zero `bytes` and an `image/*` type. This confirms the S3 read from old R2, the upload to the new dev R2 bucket, and the `Image` record all work against real data.

- [ ] **Step 3: Confirm variants generate (with Sidekiq running)**

With `bin/dev` running (so ActiveStorage `TransformJob`s process), run:

```bash
bin/rails runner '
book = Books::Book.joins(:images).where(images: {primary: true}).first
img = book.images.where(primary: true).first
puts img.file.variant(:medium).processed.key
puts img.file.variant(:small).processed.key
puts img.file.variant(:large).processed.key
'
```

Expected: three variant keys print with no error (the 100/150/250 variants exist in the new bucket).

- [ ] **Step 4: Full run — enqueue all 37,296 jobs**

Run: `bin/rails data_migration:book_images`
Expected: `{:success=>true, :data=>{:model=>"Books::Book#primary_image", :count=>37296}}`.

- [ ] **Step 5: Let Sidekiq drain, then verify the load**

With Sidekiq running (~148k jobs: 37,296 images + their variant transforms), wait for the queue to drain, then run:

```bash
bin/rails runner '
puts "primary images: #{Image.where(parent_type: "Books::Book", primary: true).count}"
puts "books with a primary image: #{Books::Book.joins(:images).where(images: {primary: true}).distinct.count}"
'
```

Expected: both counts converge to **37296** once the queue is empty.

- [ ] **Step 6: Idempotency check — re-run must not duplicate**

Run:

```bash
bin/rails data_migration:book_images
```

Then, after the (fast, no-op) jobs drain:

```bash
bin/rails runner 'puts Image.where(parent_type: "Books::Book", primary: true).count'
```

Expected: still **37296** — the job's `book.images.where(primary: true).exists?` guard makes re-runs no-ops (no new `Image` rows, no re-download).

- [ ] **Step 7: Spot-check the admin UI**

Open a few book admin show pages (e.g. `/admin/books/books/:id` for ids seen in Step 2) with the dev server running and confirm covers render in the lazy `images_list` frame. No code change — this only confirms the already-built admin image grid displays the migrated covers.

---

## Notes for the executor

- **Prod rollout** is out of scope for this plan (it happens at books-site launch): add the `LEGACY_R2_*` vars to `secrets/.env.production` (already done, encrypted), run `data_migration:book_images` in prod, let Sidekiq drain, then remove the transient creds from `secrets/.env.production`. Reading from old R2 is via the S3 API + creds, independent of the `images.thegreatestbooks.org` CDN cutover.
- If Step 2 or 5 surfaces a persistent job failure (e.g. an unexpected content type), it will land in the Sidekiq dead set — visible, not silent. All 37,296 legacy blobs were verified as jpeg/gif/png/webp (in the `Image` allowed set), so none should fail validation.
