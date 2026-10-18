# frozen_string_literal: true

# The WorldCat genre/subject backfill (docs/features/worldcat-data-service.md).
# Queued by worldcat:backfill. One run walks every book with an ISBN; `low`
# keeps it behind members' work, and retry is off because the run is its own
# retry loop and a second run while the first holds the lock exits at once.
class Books::WorldCatBackfillJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, run_id)
    result = ::Services::Books::WorldCat::Backfill.call(limit: limit, run_id: run_id)
    data = result.data
    return Rails.logger.warn("WorldCat backfill #{run_id}: did not start (#{result.errors.join("; ")})") if data.nil?

    Rails.logger.info(
      "WorldCat backfill #{run_id}: #{data[:processed]} books, #{data[:matched]} matched, " \
      "#{data[:genres_linked]} genre links, #{data[:audiences_linked]} audience links, #{data[:subjects_linked]} subject links, " \
      "#{data[:type_conflicts]} type conflicts, " \
      "#{data[:subjects_unresolved].size} unresolved subject phrases" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}"
    )
  end
end
