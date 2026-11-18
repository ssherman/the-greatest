# Runs the paid research for one row of an enrichment queue (see
# Services::EnrichmentQueue::Research). retry: 0 because a run can spend a web
# search: a failed run leaves its row failed instead of being repeated, and a
# person re-queues it.
class EnrichmentQueue::ResearchJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  def perform(kind)
    result = Services::EnrichmentQueue::Research.call(kind: kind)
    Rails.logger.error("EnrichmentQueue::ResearchJob #{kind}: #{result.errors.join("; ")}") unless result.success?
  end
end
