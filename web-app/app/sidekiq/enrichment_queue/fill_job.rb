# Fills one enrichment queue (see Services::EnrichmentQueue::Fill). retry: 0 because
# a fill is idempotent and its caller (the rake task, the admin page) can simply
# run it again; a Sidekiq retry would only repeat a long scan.
class EnrichmentQueue::FillJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 0

  def perform(kind, scope, limit)
    result = Services::EnrichmentQueue::Fill.call(kind: kind, scope: scope, limit: limit)
    if result.success?
      Rails.logger.info("EnrichmentQueue::FillJob #{kind}: " + result.data.map { |name, count| "#{name}=#{count}" }.join(" "))
    else
      Rails.logger.error("EnrichmentQueue::FillJob #{kind}: #{result.errors.join("; ")}")
    end
  end
end
