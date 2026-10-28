# frozen_string_literal: true

# The Goodreads rebuild's stage one survey, pass 1 (docs/features/goodreads-rebuild.md).
# Queued by books:goodreads_rebuild:survey. Local only, so it can run beside a
# verification run; low keeps it behind members' work. No retries: re-queue it,
# and it resumes at the first unsurveyed book.
class Books::GoodreadsRebuild::SurveyJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, resurvey = false)
    data = ::Services::Books::GoodreadsRebuild::Survey.call(limit: limit, resurvey: resurvey).data
    Rails.logger.info("Goodreads rebuild survey: #{data[:processed]} books#{" -- stopped: #{data[:error]}" if data[:stopped]}")
  end
end
