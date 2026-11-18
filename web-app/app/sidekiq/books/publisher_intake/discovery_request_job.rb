# frozen_string_literal: true

# Performs one discovery request of a publisher intake run (design §3), on the
# publisher_fetch capsule. It never waits in a thread: a wait reschedules the same request
# with due true. The run's counts track the requests still outstanding; the run
# is finished when the last one is done, and a failed run is left failed.
class Books::PublisherIntake::DiscoveryRequestJob
  include Sidekiq::Job

  sidekiq_options queue: :publisher_fetch, retry: 2

  def perform(run_id, request_hash, due = false, attempt = 1)
    run = ::Books::PublisherIntakeRun.find_by(id: run_id)
    return if run.nil?

    request = ::Books::PublisherIntake::Request.from_h(request_hash)
    data = ::Services::Books::PublisherIntake::RunDiscoveryRequest.call(run: run, request: request, due: due, attempt: attempt).data
    case data[:action]
    when :wait then self.class.perform_in(data[:wait], run_id, request_hash, true, attempt)
    when :retry then self.class.perform_async(run_id, request_hash, false, attempt + 1)
    when :done then complete(run, request, data[:requests])
    end
  end

  private

  # The counts change under the run's lock so concurrent requests cannot lose
  # an update. Follow-ups are enqueued after it commits, so they never run
  # against counts that are not yet visible. Outstanding cannot reach zero
  # while follow-ups were added, because the finished request is only one of
  # them.
  def complete(run, request, follow_ups)
    run.with_lock do
      next unless run.status_running?

      counts = run.counts.dup
      counts["requests"] = counts["requests"].to_i + follow_ups.size
      counts["outstanding"] = counts["outstanding"].to_i + follow_ups.size - 1
      run.counts = counts
      run.assign_attributes(status: :finished, finished_at: Time.current) if counts["outstanding"] <= 0
      run.save!
    end

    seed = request.context["seed"] == true
    follow_ups.each do |follow_up|
      follow_up = follow_up.with(context: follow_up.context.merge("seed" => true)) if seed
      self.class.perform_async(run.id, follow_up.to_h, false, 1)
    end
  end
end
