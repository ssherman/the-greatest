module Images
  # Measures image blobs that were identified but never analyzed.
  #
  # The July 2026 image migration created ~6,756 book-cover blobs with metadata
  # {"identified": true} and no width/height, because Active Storage skips its own
  # analysis once a blob is marked identified. Link previews need the dimensions
  # (a thumbnail is only emitted at 200x200 or larger), so this fills them in.
  #
  # One bad blob (missing file, undecodable image) must not sink the batch: it is
  # logged and the rest carry on. Blobs that already have a width are skipped, so
  # re-running the backfill is harmless.
  class AnalyzeDimensionsJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform(blob_ids)
      ActiveStorage::Blob.where(id: blob_ids).each do |blob|
        next if blob.metadata["width"].present?

        blob.analyze
      rescue => e
        Rails.logger.error("Images::AnalyzeDimensionsJob: blob #{blob.id} failed: #{e.class}: #{e.message}")
      end
    end
  end
end
