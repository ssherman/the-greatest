# frozen_string_literal: true

# Once a day: fails runs that stopped making progress, queues due re-reads, then
# starts a weekly run for each enabled source that is due one (publisher intake
# design §3 and §6). Does nothing unless PUBLISHER_INTAKE_SOURCES names a source.
class Books::PublisherIntake::DailyJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 2

  def perform
    sources = ::Books::PublisherIntake::Sources.enabled
    return if sources.empty?

    settings = ::Books::PublisherIntake.settings
    fail_stuck_runs(settings.stuck_run_days)
    sources.each { |source| ::Services::Books::PublisherIntake::QueueRereads.call(source: source) }
    sources.each do |source|
      next unless due_for_run?(source, settings.run_every_days)

      ::Services::Books::PublisherIntake::StartRun.call(source: source)
    end
  end

  private

  # Any source, enabled or not: a run whose jobs were lost must not stay running forever.
  def fail_stuck_runs(days)
    ::Books::PublisherIntakeRun.status_running.where(started_at: ...days.days.ago)
      .update_all(status: ::Books::PublisherIntakeRun.statuses[:failed], finished_at: Time.current,
        error: "no progress for #{days} days", updated_at: Time.current)
  end

  def due_for_run?(source, run_every_days)
    runs = ::Books::PublisherIntakeRun.where(source: source.key)
    !runs.status_running.exists? && !runs.status_finished.where(finished_at: run_every_days.days.ago..).exists?
  end
end
