class EnrichmentQueue::ApplyJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  # The row stays submitted while attempts remain; once they are used up it is
  # marked failed so it shows in the queue's counts and can be re-queued.
  sidekiq_retries_exhausted do |job, exception|
    Services::EnrichmentQueue::Apply.fail!(request_id: job["args"].first, error: exception.message)
  end

  def perform(request_id)
    Services::EnrichmentQueue::Apply.call(request_id: request_id)
  end
end
