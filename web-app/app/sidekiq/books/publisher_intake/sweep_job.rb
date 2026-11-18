# frozen_string_literal: true

# Every ten minutes: queues read jobs for the oldest pending listings of each
# enabled source whose gate is open (publisher intake design §3). This is the
# only thing that enqueues reads, so a listing left pending for any reason is
# picked up again. Does nothing unless PUBLISHER_INTAKE_SOURCES names a source.
class Books::PublisherIntake::SweepJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 2

  WINDOW_SECONDS = 600

  def perform
    sources = ::Books::PublisherIntake::Sources.enabled
    return if sources.empty?

    interval = ::Books::PublisherIntake.settings.fetch_interval.to_i
    batch = [(WINDOW_SECONDS / [interval, 1].max).floor, 1].max
    sources.each do |source|
      gate = ::Books::PublisherIntake.gate_for(source.key)
      next if gate.blocked? || gate.reopens_at.present?

      queue(source, batch)
    end
  end

  private

  def queue(source, batch)
    now = Time.current
    ids = ::Books::PublisherListing.state_pending.where(source: source.key)
      .where(queued_at: nil).or(
        ::Books::PublisherListing.state_pending.where(source: source.key).where(queued_at: ...(now - 1.hour))
      )
      .where.not(id: unparseable_recently(source, now))
      .order(:first_seen_at, :id).limit(batch).pluck(:id)
    return if ids.empty?

    ::Books::PublisherListing.where(id: ids).update_all(queued_at: now)
    ids.each { |id| ::Books::PublisherIntake::ReadListingJob.perform_async(id) }
  end

  def unparseable_recently(source, now)
    ::Books::PublisherListing.where(source: source.key).last_attempt_unparseable
      .where(last_attempt_at: (now - 1.day)..).select(:id)
  end
end
