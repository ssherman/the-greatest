# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Puts a submission that has no book back to the start of its lookup, for
      # SupplyDetails and Retry. Every counter the lookup keeps is reset, and the
      # lease with them, so the row is a fresh request.
      #
      # The write is one conditional UPDATE: no book yet, the review is not
      # rejected, and `scope` (the caller's status and lease condition) still
      # holds. It returns how many rows changed; zero means refused. The job is
      # queued after the write, and a failure to queue it is logged and
      # tolerated: the requeue sweep picks a queued row up.
      module Requeue
        RESET = {
          status: :queued, error: nil, attempts: 0, blocked_fetches: 0, sweeps: 0, fetch_errors: 0, claims: 0,
          next_attempt_at: nil, processing_started_at: nil, lease_token: nil, lease_expires_at: nil, claimed_by_id: nil
        }.freeze
        REVIEWS = %w[not_needed pending].freeze

        module_function

        def call(scope, id:, **extra)
          changed = scope.where(id: id, book_id: nil, review_status: REVIEWS)
            .update_all(RESET.merge(extra).merge(updated_at: Time.current))
          enqueue(id) if changed.positive?
          changed
        end

        def enqueue(id)
          ::Books::ProcessBookSubmissionJob.perform_async(id)
        rescue => error
          Rails.logger.error "Books::BookSubmission #{id} requeued, but its job could not be queued: #{error.class.name}"
        end
      end
    end
  end
end
