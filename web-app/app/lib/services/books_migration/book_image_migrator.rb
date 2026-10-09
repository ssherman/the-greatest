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

      # The legacy column is record_id but the yielded key is "book_id", so this
      # narrows by hand rather than through sync_narrowed.
      def legacy_each
        attachments = LegacyBooks::ActiveStorageAttachment.where(record_type: "Book", name: "primary_image")
        attachments = attachments.where(record_id: sync.book_ids.to_a) if sync
        attachments.includes(:blob).find_each(batch_size: BATCH_SIZE) do |attachment|
          yield({
            "book_id" => attachment.record_id,
            "key" => attachment.blob.key,
            "filename" => attachment.blob.filename,
            "content_type" => attachment.blob.content_type
          })
        end
      end

      def sync_filter
        [:book_ids, "book_id"]
      end

      def upsert_row(attrs)
        ::Books::MigrateCoverImageJob.perform_async(
          attrs["book_id"], attrs["key"], attrs["filename"], attrs["content_type"]
        )
      end
    end
  end
end
