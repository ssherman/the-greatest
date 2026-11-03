# Writes the archive verdict of mixed books for the re-import (Services::Books::GoodreadsReimport::MixedBooks.archive;
# .enqueue queues the books 100 at a time). Records verdicts only: nothing is deleted here. Does nothing while the
# re-import gate is off. One book failing is logged and the batch carries on. Re-running is safe: archive keeps the
# first snapshot it took.
class Books::GoodreadsReimport::ArchiveMixedJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100

  # Returns how many mixed books were queued.
  def self.enqueue
    ids = ::Services::Books::GoodreadsReimport::MixedBooks.ids.to_a.sort
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(book_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    # Building the map scans every row, so it is built once per batch, not once per book.
    legacy_map = ::Services::Books::GoodreadsRebuild::LegacyBookMap.build
    archived = errors = 0
    ::Books::Book.where(id: book_ids).find_each do |book|
      ::Services::Books::GoodreadsReimport::MixedBooks.archive(book, legacy_map: legacy_map)
      archived += 1
    rescue => e
      errors += 1
      Rails.logger.error("archive_mixed: book #{book.id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("archive_mixed batch: #{book_ids.size} books — archived #{archived}, errors #{errors}")
  end
end
