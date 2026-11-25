# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # An agent gives up on a claimed row and hands it to a person: needs_human,
      # the reason as the note, the lease cleared. A claim never returns it
      # again; the admin page can still act on it. The same check order as
      # Approve: lease first (:conflict), the reason second (:invalid).
      class Skip
        Result = Lease::Result

        def self.call(submission:, reason:, user:, via:, lease_token: nil)
          new(submission: submission, reason: reason, user: user, via: via, lease_token: lease_token).call
        end

        def initialize(submission:, reason:, user:, via:, lease_token:)
          @submission = submission
          @reason = reason
          @user = user
          @via = Lease.via!(via)
          @token = lease_token
        end

        def call
          row = ::Books::BookSubmission.find_by(id: @submission.id)
          return Lease.failure(:conflict, "the submission no longer exists") unless row
          return Lease.failure(:conflict, "the submission is #{row.review_status}, not awaiting review") unless reviewable?(row)

          refusal = Lease.lease_failure(row, @token, @via) || Lease.input_failure(note: @reason, sources: [])
          return refusal if refusal

          changed = Lease.guard(::Books::BookSubmission.where(id: row.id).reviewable, @token, @via)
            .update_all(Lease.closing(:needs_human, user: @user, via: @via, note: @reason, sources: []))
          return Lease.failure(:conflict, "the submission changed while it was being skipped") if changed.zero?

          Lease.success(submission: ::Books::BookSubmission.find(row.id))
        end

        private

        def reviewable?(row) = ::Books::BookSubmission.reviewable.exists?(row.id)
      end
    end
  end
end
