# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Puts a submission back to the start of its work, for SupplyDetails,
      # Retry and an Approve that resumes a failed row. Every counter the lookup
      # keeps is reset, and the lease with them, so the row is a fresh request.
      #
      # `scope` is the caller's whole condition (status, book, review, lease);
      # the write is one conditional UPDATE on it, and it returns how many rows
      # changed, zero meaning refused. A row with no book that was flagged
      # needs_human (a skip, or abandoned by agents) goes back to not_needed:
      # the request has new life and no review is owed yet. A row with a book
      # keeps its review state and its book, and the job resumes at the list.
      #
      # The job is queued after the write (`call`), or by the caller after its
      # own commit (`reset` then `enqueue`); a failure to queue it is logged and
      # tolerated: the requeue sweep picks a queued row up.
      module Requeue
        RESET = {
          status: :queued, error: nil, attempts: 0, blocked_fetches: 0, sweeps: 0, fetch_errors: 0, claims: 0,
          next_attempt_at: nil, processing_started_at: nil, lease_token: nil, lease_expires_at: nil, claimed_by_id: nil
        }.freeze

        module_function

        def call(scope, id:, **extra)
          changed = reset(scope, id: id, **extra)
          enqueue(id) if changed.positive?
          changed
        end

        def reset(scope, id:, **extra)
          statuses = ::Books::BookSubmission.review_statuses
          review = Arel.sql("CASE WHEN review_status = #{statuses.fetch("needs_human")} AND book_id IS NULL " \
            "THEN #{statuses.fetch("not_needed")} ELSE review_status END")
          scope.where(id: id).update_all(RESET.merge(review_status: review).merge(extra).merge(updated_at: Time.current))
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
