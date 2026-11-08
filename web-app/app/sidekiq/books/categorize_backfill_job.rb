# frozen_string_literal: true

# Plans the paced origin backfill (Services::Books::Categorize::Backfill).
# Queued by books:categorize:backfill with APPLY=1. Retry is off: a rerun is
# the rake task again, and the backfill only plans what is still undone.
class Books::CategorizeBackfillJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(scope, limit, label, book_ids = nil)
    result = ::Services::Books::Categorize::Backfill.call(scope: scope, limit: limit, label: label, book_ids: book_ids)
    return Rails.logger.warn("Categorize backfill #{label}: did not start (#{result.errors.join("; ")})") unless result.success?

    data = result.data
    Rails.logger.info("Categorize backfill #{label}: planned #{data[:planned]} (reused #{data[:reused]}), evidence done by #{data[:done_at].utc.iso8601}")
  end
end
