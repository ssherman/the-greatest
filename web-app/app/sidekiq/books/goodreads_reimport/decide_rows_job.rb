# Decides the Goodreads CSV rows of a batch of users for the re-import
# (Services::Books::GoodreadsReimport::DecideRow.decide_user; .enqueue queues them 20 users at a time).
# Records verdicts only. Does nothing while the re-import gate is off. A user whose editions are not all matched
# and applied yet comes back "waiting" and is picked up by the next enqueue; one user failing is logged and the
# batch carries on.
class Books::GoodreadsReimport::DecideRowsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 20
  OUTCOMES = %i[recorded waiting kept conflict].freeze
  REIMPORT_ROW_KIND = ::Books::RepairVerdict.kinds.fetch("reimport_row")

  # Users with a row of the replayed imports that has no applied reimport_row verdict yet. Returns how many
  # users were queued.
  def self.enqueue(limit: nil)
    ids = ::Books::GoodreadsImportRow
      .joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
      .where.not(goodreads_edition_id: nil)
      .where("NOT EXISTS (SELECT 1 FROM books_repair_verdicts v WHERE v.kind = #{REIMPORT_ROW_KIND} AND v.applied_at IS NOT NULL " \
        "AND v.subject_key = 'reimport:row:' || books_goodreads_import_rows.import_id || ':' || books_goodreads_import_rows.row_number)")
      .reorder(nil).distinct.order("books_goodreads_imports.user_id").pluck("books_goodreads_imports.user_id")
    ids = ids.first(limit) if limit
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(user_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = OUTCOMES.index_with(0).merge(errors: 0)
    user_ids.each do |user_id|
      ::Services::Books::GoodreadsReimport::DecideRow.decide_user(user_id: user_id).data[:tally].each do |outcome, count|
        counts[outcome] += count if counts.key?(outcome)
      end
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("decide_rows: user #{user_id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("decide_rows batch: #{user_ids.size} users — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
