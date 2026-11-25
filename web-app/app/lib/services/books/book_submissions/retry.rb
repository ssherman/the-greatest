# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The admin page's Retry: a failed request with no book goes back to
      # queued with its counters reset, and its job is queued. Never reached
      # through the API, so no lease is involved; a row an agent holds is
      # released with the rest of the reset.
      class Retry
        Result = Lease::Result

        def self.call(submission:, user:)
          new(submission: submission, user: user).call
        end

        def initialize(submission:, user:)
          @submission = submission
          @user = user
        end

        def call
          changed = Requeue.call(::Books::BookSubmission.where(status: :failed), id: @submission.id)
          return Lease.failure(:conflict, "only a failed submission with no book can be retried") if changed.zero?

          Rails.logger.info "Books::BookSubmission #{@submission.id} retried by user #{@user.id}"
          Lease.success(submission: ::Books::BookSubmission.find(@submission.id))
        end
      end
    end
  end
end
