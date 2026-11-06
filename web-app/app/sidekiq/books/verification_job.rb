# frozen_string_literal: true

# The book verification pass, stage 1 the OL key backfill (docs/superpowers/specs/2026-10-07-ol-key-backfill-design.md).
# Queued by books:verify. One run works through books one at a time, so
# it can hold a thread for days; `low` keeps it behind members' work.
class Books::VerificationJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  # book_ids: the books a redo names (books:verify_keep_bigger); the run's scope.
  def perform(limit, run_id, flags = [], book_ids = nil)
    scope = book_ids && {scope: ::Books::Book.where(id: book_ids)}
    data = ::Services::Books::Verification::Run.call(limit: limit, run_id: run_id, flags: Array(flags), **scope.to_h).data
    Rails.logger.info("Verification run #{run_id}: #{data[:processed]} books" \
      "#{" -- stopped: #{data[:error]}" if data[:stopped]}")
  end
end
