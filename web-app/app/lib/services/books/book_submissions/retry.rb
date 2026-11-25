# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The admin page's Retry: a failed request goes back to queued with its
      # counters reset, and its job is queued. Never reached through the API, so
      # no lease is involved; a row an agent holds is released with the rest of
      # the reset. A rejected row is refused. One with no book that was flagged
      # needs_human goes back to not_needed (Requeue); one that failed after it
      # got a book keeps the book and its review state, and the job resumes at
      # the list step.
      class Retry
        Result = Lease::Result

        def self.call(submission:, user:)
          new(submission: submission, user: user).call
        end

        # What the service accepts, for the page to offer the button by: the
        # rule of the scope in #call, read from a loaded row.
        def self.retryable?(row) = row.failed? && !row.review_rejected?

        def initialize(submission:, user:)
          @submission = submission
          @user = user
        end

        def call
          changed = Requeue.call(::Books::BookSubmission.where(status: :failed).where.not(review_status: :rejected), id: @submission.id)
          return Lease.failure(:conflict, "only a failed submission that was not rejected can be retried") if changed.zero?

          Rails.logger.info "Books::BookSubmission #{@submission.id} retried by user #{@user.id}"
          Lease.success(submission: ::Books::BookSubmission.find(@submission.id))
        end
      end
    end
  end
end
