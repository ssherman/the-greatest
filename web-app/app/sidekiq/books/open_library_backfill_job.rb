# frozen_string_literal: true

# The Open Library key backfill (docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md).
# Queued by books:ol_backfill. One run works through books one at a time, so
# it can hold a thread for days; `low` keeps it behind members' work.
class Books::OpenLibraryBackfillJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, run_id, retry_unsure = false)
    data = ::Services::Books::OlBackfill::Run.call(limit: limit, run_id: run_id, retry_unsure: retry_unsure).data
    Rails.logger.info("Open Library backfill run #{run_id}: #{data[:processed]} books" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}")
  end
end
