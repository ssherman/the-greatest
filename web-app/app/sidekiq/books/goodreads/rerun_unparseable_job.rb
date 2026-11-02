# frozen_string_literal: true

# Re-runs book enrichment for books whose Goodreads step ended "unparseable"
# (Services::Books::GoodreadsEnrichment::RerunUnparseable). Queued by
# books:goodreads:rerun_unparseable after a Goodreads parser fix.
class Books::Goodreads::RerunUnparseableJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  DEFAULT_LIMIT = 500

  def perform(limit = DEFAULT_LIMIT)
    data = ::Services::Books::GoodreadsEnrichment::RerunUnparseable.call(limit: limit).data
    Rails.logger.info("#{self.class.name}: started #{data[:started]} book runs; #{data[:remaining]} remain")
  end
end
