# frozen_string_literal: true

# The rake-driven sweep (Goodreads import spec §6, "Never in the critical
# path"): queues a Goodreads check for each provisional book created
# unverified, and again for editions stuck waiting (their fetch job was lost
# to a crash or a Redis flush). An id whose page is already cached is settled
# without a fetch. At most `limit` ids, by default the day's fetch cap; the
# fetch line spaces them out.
class Books::Goodreads::VerifyUnverifiedJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  STUCK_AFTER = 1.hour

  def perform(limit = nil)
    limit ||= Rails.application.config.x.goodreads.daily_fetch_cap
    ids = ::Books::GoodreadsEdition.where(id: unverified.select(:id)).or(::Books::GoodreadsEdition.where(id: stuck.select(:id)))
      .distinct.order(:goodreads_book_id).limit(limit).pluck(:goodreads_book_id)
    answered = ::Books::GoodreadsPage.conclusive.where(goodreads_book_id: ids).pluck(:goodreads_book_id).to_set
    ids.each do |goodreads_book_id|
      if answered.include?(goodreads_book_id)
        ::Books::Goodreads::SettleEditionsJob.perform_async(goodreads_book_id)
      else
        ::Books::Goodreads::FetchPageJob.perform_async(goodreads_book_id)
      end
    end
  end

  private

  def unverified
    ::Books::GoodreadsEdition.created.verification_unverified.joins(:book).where(books_books: {provisional: true})
  end

  def stuck
    ::Books::GoodreadsEdition.verification_pending.where(updated_at: ...STUCK_AFTER.ago)
  end
end
