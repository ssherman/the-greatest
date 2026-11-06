# Checks the credited authors of re-imported books against their CSV rows
# (Services::Books::GoodreadsReimport::CheckAuthor; .enqueue queues the books 100 at a time).
# Records verdicts only. Does nothing while the re-import gate is off. One book failing is logged and the batch
# carries on; a book whose AI call failed ("failed") is simply picked up by the next enqueue.
class Books::GoodreadsReimport::CheckAuthorsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100
  OUTCOMES = %i[agrees recorded kept].freeze
  REIMPORT_ROW_KIND = ::Books::RepairVerdict.kinds.fetch("reimport_row")

  # Books that are the destination of an applied reimport_row verdict. Returns how many books were queued.
  def self.enqueue(limit: nil)
    ids = ::Books::RepairVerdict.where(kind: REIMPORT_ROW_KIND).where.not(applied_at: nil).where(superseded_at: nil)
      .where("payload ->> 'to_book_id' IS NOT NULL")
      .distinct.pluck(Arel.sql("(payload ->> 'to_book_id')::bigint")).sort
    ids = ids.first(limit) if limit
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(book_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = OUTCOMES.index_with(0).merge(failed: 0, errors: 0)
    ::Books::Book.where(id: book_ids).find_each do |book|
      result = ::Services::Books::GoodreadsReimport::CheckAuthor.call(book: book)
      key = result.success? ? result.data[:outcome] : :failed
      counts[key] += 1 if counts.key?(key)
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("check_authors: book #{book.id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("check_authors batch: #{book_ids.size} books — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
