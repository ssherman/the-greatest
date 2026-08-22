# frozen_string_literal: true

module Services
  module Billing
    # What changed about a membership during one reconcile.
    #
    # Exists because ReconcileCustomer#upsert uses assign_attributes + save!,
    # which discards the prior status -- previous_status is the only place
    # that value survives past the one reconcile that overwrote it.
    #
    # #upsert returns this on every path, including the comped-row no-op --
    # never a bare Membership -- so any caller that expects #membership
    # (MembershipNotifier, the per-transition error log in
    # ReconcileCustomer#call) gets a uniform type to call it on.
    #
    # Task 2: MembershipNotifier no longer derives email eligibility from a
    # transition (it used to, via predicates this class no longer defines --
    # became_active?, became_canceled?, status_changed?). A status transition
    # is observable exactly once, but upsert commits the new status before
    # MembershipNotifier runs, so a failed mail enqueue (Redis unavailable,
    # say) could roll back the once-only stamp while the status stayed
    # committed -- leaving the email owed forever with nothing left able to
    # see that it was owed. Eligibility reads the membership's own
    # *_email_sent_at columns instead, which are durable. See
    # MembershipNotifier for the current logic; previous_status remains here
    # as the transition's data, even though nothing currently derives a
    # boolean from it.
    class MembershipTransition
      attr_reader :membership, :previous_status

      def initialize(membership:, previous_status:)
        @membership = membership
        @previous_status = previous_status
      end
    end
  end
end
