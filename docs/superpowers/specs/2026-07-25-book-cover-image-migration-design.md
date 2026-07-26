# Books Cover Image Migration — Design

**Status:** Approved 2026-07-25. Execution model = **Sidekiq fan-out** (one job per image), confirmed by owner. Image source = **old R2 bucket via S3 API using owner-supplied ENV credentials**, confirmed by owner.
**Scope:** A standalone migration increment on top of the completed books data migration (Phases 1–3, all merged): the legacy Book `primary_image` ActiveStorage attachments → new polymorphic `Image` records attached to `Books::Book`, with the binaries copied from old R2 into the new site's R2 bucket via the new site's ActiveStorage.
**Parent design:** `docs/superpowers/specs/2026-07-03-old-site-data-migration-design.md`.

## Goal

Bring the 37,296 legacy book cover images into the new app so they render on the books admin (and, later, public) pages through the already-built shared `Image` model — no new UI, no schema change. Read each original from the old Cloudflare R2 bucket via the S3 API and re-attach it through the new site's ActiveStorage, which uploads it to the new R2 bucket and regenerates the app's `small`/`medium`/`large` variants.

## Verified source facts (legacy DB + old/new schema, gathered during brainstorming)

Queried read-only against the `legacy_books` replica (`the_greatest_books_legacy`) and the new dev DB:

- Legacy books total: **126,204**. Books with a `primary_image` ActiveStorage attachment: **37,296**.
- **All** 37,296 primary_image blobs have `service_name = 'cloudflare'` — every original is in the old R2 bucket; **none** stranded on the old AWS `new-tgb-images` bucket. (All 151,561 legacy blobs, originals + variants, are on `cloudflare`.)
- Content types of the 37,296: **36,991 jpeg · 233 gif · 71 png · 1 webp** — every one is in the new `Image` model's allowed set (`jpeg/png/webp/gif`), so nothing is rejected. Average blob ≈ 34 KB, max ≈ 9 MB, total ≈ **1.3 GB** of originals.
- Legacy standalone `images` table (the old polymorphic `Image` model): **0 rows** — unused. The **only** book image source is `Book has_one_attached :primary_image`.
- **All 37,296** image-book ids exist in the new `books_books` (0 missing) — book ids were preserved in Phase 1b, so `legacy Book.id == Books::Book.id` is a direct, gap-free join key. **No dedup/missing-book handling needed.**
- New DB baseline: **0** `Books::Book` currently have a primary `Image` — a first run is a clean load; any re-run is a safe no-op / gap-filler.
- The old public host `https://images.thegreatestbooks.org/<key>` returns **HTTP 403** (Cloudflare block page) to programmatic clients, with **and** without a browser User-Agent — so downloading originals over the CDN is not viable. The S3 API against the old bucket is the source of truth.

## Old → new target model (already on `main`, no schema change)

New shared `Image` model (`web-app/app/models/image.rb`): `belongs_to :parent, polymorphic:`; `has_one_attached :file` with **preprocessed** variants `:small` 100×100, `:medium` 150×150, `:large` 250×250 (same scheme as the old site); `store :metadata` (JSON); validates file present and format ∈ jpeg/png/webp/gif; `primary` boolean whose `after_save` unsets other primaries for the same parent.

`Books::Book` (`web-app/app/models/books/book.rb:57-58`): `has_many :images, as: :parent, dependent: :destroy` and `has_one :primary_image, -> { where(primary: true) }, as: :parent, class_name: "Image"`. `parent_type` for migrated rows = `"Books::Book"`.

Attach mechanism mirrors the proven `Music::AmazonProductService#download_and_set_image` pattern:
`image = book.images.build(primary: true); image.file.attach(io:, filename:, content_type:); image.save!`.

## Source → target field mapping

| Old | New | Handling |
|---|---|---|
| `active_storage_attachments` (record_type `Book`, name `primary_image`) → `active_storage_blobs` | — | join to find the source blob per book |
| `active_storage_blobs.key` | (object key in **old** R2 bucket) | S3 `get_object` source key |
| `active_storage_blobs.filename` | `Image` attachment filename | passthrough (kept verbatim, spaces and all) |
| `active_storage_blobs.content_type` | `Image` attachment content_type | passthrough (all ∈ allowed set) |
| legacy `Book.id` (= `attachment.record_id`) | `Books::Book.id` / `Image.parent_id` | direct passthrough (ids preserved) |
| the original blob bytes | new `Image` `has_one_attached :file` → uploaded to **new** R2 by ActiveStorage | attach + `save!` (auto-enqueues the 3 variant transforms) |
| — | `Image.primary` | `true` |
| — | `Image.metadata` | `{ "source" => "legacy_migration", "legacy_blob_key" => <key> }` (provenance) |
| legacy variant blobs / `active_storage_variant_records` | — | **not** copied — the new site regenerates its own variants |

## Source access — old R2 via S3 API (owner-supplied ENV)

New helper `Services::BooksMigration::LegacyR2` builds a configured `Aws::S3::Client` (`aws-sdk-s3` is in the Gemfile as `require: false`, so the helper file `require`s it) from four ENV vars the owner provides; nothing is read from the old checkout (it has no `master.key`) and nothing goes through the blocked CDN:

```
LEGACY_R2_ACCOUNT_ID          # endpoint built as https://<account-id>.r2.cloudflarestorage.com
LEGACY_R2_ACCESS_KEY
LEGACY_R2_SECRET_KEY
LEGACY_R2_BUCKET
```

```ruby
require "aws-sdk-s3"

module Services
  module BooksMigration
    module LegacyR2
      def self.client
        Aws::S3::Client.new(
          endpoint: "https://#{ENV.fetch("LEGACY_R2_ACCOUNT_ID")}.r2.cloudflarestorage.com",
          access_key_id: ENV.fetch("LEGACY_R2_ACCESS_KEY"),
          secret_access_key: ENV.fetch("LEGACY_R2_SECRET_KEY"),
          region: "auto",
          force_path_style: true
        )
      end

      def self.bucket
        ENV.fetch("LEGACY_R2_BUCKET")
      end
    end
  end
end
```

**Access verified (2026-07-26):** with the dev `.env` values loaded, this client did a `head_object` on a real legacy Book `primary_image` blob key and returned `content_length=35909` / `content_type=image/jpeg`, exactly matching that blob's `byte_size` in the legacy DB — the full source-access path is proven.

## Execution architecture — Sidekiq fan-out

The workload is ~37k network round-trips (old-R2 GET → new-R2 PUT) plus ~111k variant transforms, so it is fanned out rather than run in one synchronous rake loop, giving parallelism, per-image retry/resume, and failure isolation.

**`Services::BooksMigration::BookImageMigrator`** (subclasses the existing `Migrator`) streams the legacy rows and **enqueues one job per image**. It overrides `legacy_each` to yield the joined source fields (avoids an N+1 over the legacy connection):

```ruby
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
    .find_each(batch_size: BATCH_SIZE) do |att|
      yield({
        "book_id" => att.record_id,
        "key" => att.blob.key,
        "filename" => att.blob.filename,
        "content_type" => att.blob.content_type
      })
    end
end

def upsert_row(attrs)
  Books::MigrateCoverImageJob.perform_async(
    attrs["book_id"], attrs["key"], attrs["filename"], attrs["content_type"]
  )
end
```

Two new read-only legacy models (matching the `LegacyBooks::*` pattern, `LegacyBooks::Record` base):
- `LegacyBooks::ActiveStorageAttachment` (`self.table_name = "active_storage_attachments"`, `belongs_to :blob, class_name: "LegacyBooks::ActiveStorageBlob"`).
- `LegacyBooks::ActiveStorageBlob` (`self.table_name = "active_storage_blobs"`).

**`Books::MigrateCoverImageJob`** (`app/sidekiq/books/migrate_cover_image_job.rb`, generated via `bin/rails generate sidekiq:job books/migrate_cover_image`) does the real work per book:

```ruby
def perform(book_id, key, filename, content_type)
  book = Books::Book.find_by(id: book_id)
  return unless book                        # defensive; verified 0 missing
  return if book.images.primary.exists?     # idempotency guard (authoritative)

  tempfile = Tempfile.new("legacy_cover")
  Services::BooksMigration::LegacyR2.client.get_object(
    bucket: Services::BooksMigration::LegacyR2.bucket,
    key: key,
    response_target: tempfile.path         # S3 SDK writes the object bytes to this path
  )
  image = book.images.build(
    primary: true,
    metadata: { source: "legacy_migration", legacy_blob_key: key }
  )
  File.open(tempfile.path, "rb") do |io|
    image.file.attach(io: io, filename: filename, content_type: content_type)
    image.save!                            # uploads to new R2 + enqueues the 3 variant transforms
  end
ensure
  tempfile&.close
  tempfile&.unlink
end
```

`save!` on an `Image` with a newly attached, preprocessed-variant file enqueues the 3 variant transform jobs automatically. Enqueuing the originals plus their variants is ~148k Sidekiq jobs total — run when the queue is otherwise idle and watch it drain.

## Idempotency & provenance

- **Idempotency lives in the job:** `return if book.images.primary.exists?`. The migrator enqueues for all 37,296 rows; on a re-run the already-satisfied jobs no-op on the cheap guard (no re-download, no duplicate `Image`). Baseline is 0, so the first run is a clean load.
- **Provenance:** each `Image.metadata` carries `{ source: "legacy_migration", legacy_blob_key: <key> }` for traceability and future reconciliation.

## Search suppression

The migrator's enqueue loop runs inside the base `Migrator`'s `without_search_indexing` block, but that only covers enqueuing — the jobs run later. `Image` creation itself has no `SearchIndexable` side effects. Attaching an image does **not** reindex the parent `Books::Book` today (no image-driven reindex callback exists), so the fan-out creates no search-index churn. If cover presence is later added to the book search document, a separate reindex pass would be run after the image load — out of scope here.

## Orchestrator

Add `data_migration:book_images` to `web-app/lib/tasks/data_migration.rake` (runs `Services::BooksMigration::BookImageMigrator.call`). It is **standalone — not added to `data_migration:all`** — because it requires the `LEGACY_R2_*` ENV and fans out a heavy, long-running load that shouldn't ride along with the fast DB→DB migrators.

## Files

- Create `web-app/app/models/legacy_books/active_storage_attachment.rb`.
- Create `web-app/app/models/legacy_books/active_storage_blob.rb`.
- Create `web-app/app/lib/services/books_migration/legacy_r2.rb` (S3 client helper).
- Create `web-app/app/lib/services/books_migration/book_image_migrator.rb` (streams + enqueues).
- Generate `web-app/app/sidekiq/books/migrate_cover_image_job.rb` via `bin/rails generate sidekiq:job books/migrate_cover_image` (creates the matching test).
- Modify `web-app/lib/tasks/data_migration.rake` (add `:book_images`).
- Document the four `LEGACY_R2_*` var names in the root `.env.example` (done).
- Tests: `book_image_migrator_test.rb`, `books/migrate_cover_image_job_test.rb` (job test is generated).
- No schema migration. No new user-facing view → no new Playwright E2E.

## Testing (Minitest + Mocha, connection-free)

- **Migrator (`book_image_migrator_test.rb`):** stub `legacy_each` (Mocha `multiple_yields`; never open the legacy connection) and assert `Books::MigrateCoverImageJob` is enqueued once per row with `(book_id, key, filename, content_type)`. Assert no legacy connection is opened in test.
- **Job (`books/migrate_cover_image_job_test.rb`):** stub `Services::BooksMigration::LegacyR2.client` to return a double whose `get_object` writes fixture image bytes to `response_target`. Assert: an `Image` is created with `parent: Books::Book(fixture)`, `primary: true`, the passed filename/content_type, and `metadata` = `{source: "legacy_migration", legacy_blob_key: key}`; the file is attached. Assert the **idempotency skip** (a book that already has a primary image → no new `Image`, no `get_object` call). Assert the **missing-book skip** (`find_by` nil → early return, no `get_object`). Stub ActiveStorage variant processing so the test doesn't shell out to libvips.

## End-to-end verification (real legacy DB + old R2, dev target)

With `LEGACY_R2_*` ENV set and the new site's `STORAGE_*` pointing at the dev R2 bucket:

1. Run `data_migration:book_images`; expect `BookImageMigrator.call` → `{success: true, data: {model: "Books::Book#primary_image", count: 37296}}` (37,296 jobs enqueued — the base `Migrator` return shape).
2. Let Sidekiq drain (~148k jobs). Then expect `Image.where(parent_type: "Books::Book", primary: true).count == 37296` and `Books::Book.joins(:images).where(images: {primary: true}).distinct.count == 37296`.
3. Spot-check a sample of book admin show pages (`/admin/books/books/:id`) and the lazy `images_list` frame — covers render, and each has small/medium/large variants.
4. Re-run the rake task; confirm it is idempotent (no new `Image` rows, jobs no-op on the guard).

## Secrets handling

The four `LEGACY_R2_*` values come from the old site's Rails credentials (`:cloudflare` → `account_id`/`access_key`/`secret_key`/`bucket`; retrieve with `bin/rails credentials:show` in the old checkout). They are transient — needed only for the migration run, not the app's normal runtime — and this repo is open source, so plaintext must never be committed.

- **Dev:** the four vars live in the gitignored `web-app/.env` (loaded by `dotenv-rails`). Already added and verified (see the access smoke test above). Their **names** (blank values) are documented in the tracked root `.env.example` (the `web-app/.env` template).
- **Prod (at cutover):** the same four vars are added to `secrets/.env.production`, which is **SOPS+age-encrypted** (recipient in `.sops.yaml`) and committed encrypted. Edited self-service via `sops secrets/.env.production` (values never leave the maintainer's machine).
- **Hygiene:** because the creds are one-time, remove them from `secrets/.env.production` after the prod migration completes so prod runtime carries no unused legacy creds.

## Rollout & ops

1. Run in **dev** first (writes originals + variants to the dev R2 bucket via the existing `STORAGE_*` ENV). Snapshot the dev DB first per house rules (`bin/snapshot-dev-db.sh --label pre-book-images`) — cheap insurance, though this migration is additive and reversible by deleting the migrated `Image` rows.
2. Repeat in **prod** at books-site launch. Reading from old R2 is via the S3 API + creds, so it is **independent of** the `images.thegreatestbooks.org` CDN cutover (there is no ordering constraint between this migration and repointing that host at the new bucket).
3. Security note (from research, not blocking): the old repo's `config/storage.yml` commits **plaintext AWS keys** (`AKIA…`) for the unused `new-tgb-images` bucket — worth rotating independently of this work.

## Out of scope

- Edition / author / series cover images (the old side has none — the `images` table is empty and only `Book` has attachments).
- Copying the old variant objects (the new site regenerates its own).
- Any book search-document change to include cover presence.
- Public books UI wiring (still deferred per the parent migration effort).
