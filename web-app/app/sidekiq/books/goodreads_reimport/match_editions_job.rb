# Matches a batch of Goodreads editions to catalog books for the re-import
# (Services::Books::GoodreadsReimport::MatchEdition; .enqueue queues them 100 at a time).
# Records verdicts only. Does nothing while the re-import gate is off. One edition failing is logged and the
# batch carries on; a "retry" edition (finder or AI failed) is simply picked up by the next enqueue.
class Books::GoodreadsReimport::MatchEditionsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100
  OUTCOMES = %i[matched create kept retry].freeze

  # Editions of the replayed imports, the ones with the most rows first so a stop part way leaves the least
  # important undone. Returns how many editions were queued.
  def self.enqueue(limit: nil)
    ids = ::Books::GoodreadsImportRow
      .joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
      .where.not(goodreads_edition_id: nil)
      .group(:goodreads_edition_id)
      .reorder(Arel.sql("COUNT(*) DESC, goodreads_edition_id"))
      .pluck(:goodreads_edition_id)
    ids = ids.first(limit) if limit
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(edition_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = OUTCOMES.index_with(0).merge(errors: 0)
    ::Books::GoodreadsEdition.where(id: edition_ids).find_each do |edition|
      outcome = ::Services::Books::GoodreadsReimport::MatchEdition.call(edition: edition).data[:outcome]
      counts[outcome] += 1 if counts.key?(outcome)
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("match_editions: edition #{edition.id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("match_editions batch: #{edition_ids.size} editions — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
