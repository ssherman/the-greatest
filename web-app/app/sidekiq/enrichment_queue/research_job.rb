# Runs the paid research for one row of an enrichment queue (see
# Services::EnrichmentQueue::Research). One job execution makes at most one
# research call. retry: 0 because a retry would claim a different row and spend
# again: a failed run leaves its row failed, and a person re-queues it. A run
# killed mid-call (a hard Sidekiq shutdown re-pushes in-flight jobs) leaves its
# row claimed until the 30-minute lease expires, after which the row can be
# claimed and researched again, while the re-pushed job claims another row. So
# the limit given to enrichment_queue:work bounds job executions, not strictly
# searches.
class EnrichmentQueue::ResearchJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  def perform(kind)
    result = Services::EnrichmentQueue::Research.call(kind: kind)
    Rails.logger.error("EnrichmentQueue::ResearchJob #{kind}: #{result.errors.join("; ")}") unless result.success?
  end
end
