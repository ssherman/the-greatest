# frozen_string_literal: true

# The book verification pass, stage 1 the OL key backfill (docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md).
# Queued by books:verify. One run works through books one at a time, so
# it can hold a thread for days; `low` keeps it behind members' work.
class Books::VerificationJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  def perform(limit, run_id, retry_unsure = false)
    data = ::Services::Books::Verification::Run.call(limit: limit, run_id: run_id, retry_unsure: retry_unsure).data
    Rails.logger.info("Verification run #{run_id}: #{data[:processed]} books" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}")
  end
end
