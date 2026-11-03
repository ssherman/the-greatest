# Decides a batch of Goodreads CSV rows for the re-import (Services::Books::GoodreadsReimport::DecideRow;
# .enqueue queues them 100 at a time). Records verdicts only. Does nothing while the re-import gate is off. A row
# whose edition match is not applied yet comes back "waiting" and is picked up by the next enqueue; one row
# failing is logged and the batch carries on.
class Books::GoodreadsReimport::DecideRowsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100
  OUTCOMES = %i[recorded waiting kept].freeze

  # Rows of the replayed imports that have an edition. Returns how many rows were queued.
  def self.enqueue(limit: nil)
    ids = ::Books::GoodreadsImportRow
      .joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
      .where.not(goodreads_edition_id: nil)
      .reorder(:id)
      .pluck(:id)
    ids = ids.first(limit) if limit
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(row_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = OUTCOMES.index_with(0).merge(errors: 0)
    ::Books::GoodreadsImportRow.where(id: row_ids).find_each do |row|
      outcome = ::Services::Books::GoodreadsReimport::DecideRow.call(row: row).data[:outcome]
      counts[outcome] += 1 if counts.key?(outcome)
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("decide_rows: row #{row.id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("decide_rows batch: #{row_ids.size} rows — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
