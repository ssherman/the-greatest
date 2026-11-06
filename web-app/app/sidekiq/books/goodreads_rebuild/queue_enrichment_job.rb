# Every 10 minutes (config/schedule.yml): starts enrichment for the fixed books of the Goodreads
# rebuild so that config.x.goodreads_rebuild.in_flight of them wait for Goodreads at a time. See
# Services::Books::GoodreadsRebuild::QueueEnrichment.
class Books::GoodreadsRebuild::QueueEnrichmentJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  def perform
    data = ::Services::Books::GoodreadsRebuild::QueueEnrichment.call(in_flight: Rails.application.config.x.goodreads_rebuild.in_flight).data
    Rails.logger.info("goodreads_rebuild enrichment: started #{data[:started]}, in flight #{data[:in_flight]}, waiting #{data[:waiting]}")
  end
end
