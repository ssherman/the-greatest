# frozen_string_literal: true

# Re-runs book enrichment for books whose Goodreads step failed every attempt
# (Services::Books::GoodreadsEnrichment::RerunFailed). Queued by
# books:goodreads:rerun_failed once the cause (an outage, a fetcher fault) has
# passed.
class Books::Goodreads::RerunFailedJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  DEFAULT_LIMIT = 500

  def perform(limit = DEFAULT_LIMIT)
    data = ::Services::Books::GoodreadsEnrichment::RerunFailed.call(limit: limit).data
    Rails.logger.info("#{self.class.name}: started #{data[:started]} book runs; #{data[:remaining]} remain")
  end
end
