# frozen_string_literal: true

# Settles every edition of one Goodreads id that a page could settle, against
# the cached page or none (Goodreads import spec §6). Kept off the fetch
# capsule, so creating books never holds up the next fetch.
#
# One failing edition never stops the rest: its waiting rows carry the error,
# and it keeps waiting until the sweep queues it again. Postgres errors
# re-raise.
class Books::Goodreads::SettleEditionsJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 3

  POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

  def perform(goodreads_book_id)
    page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: goodreads_book_id)
    ::Books::GoodreadsEdition.awaiting_goodreads.where(goodreads_book_id: goodreads_book_id).order(:id).each do |edition|
      ::Services::Books::GoodreadsImports::SettleEdition.call(edition: edition, page: page)
      # A run that failed before left its error on the rows; settled, it no
      # longer applies (ResolveImport clears its own the same way).
      edition.import_rows.where.not(error: nil).update_all(error: nil, updated_at: Time.current)
    rescue *POSTGRES_ERRORS
      raise
    rescue => e
      Rails.logger.error("#{self.class.name}: Goodreads edition #{edition.id} failed: #{e.class}: #{e.message}")
      edition.import_rows.pending.update_all(error: "verification failed: #{e.class}: #{e.message}", updated_at: Time.current)
    end
  end
end
