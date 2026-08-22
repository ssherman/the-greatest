# frozen_string_literal: true

module Services
  module Billing
    # What changed about a membership during one reconcile.
    #
    # Exists because ReconcileCustomer#upsert uses assign_attributes + save!,
    # which discards the prior status -- and every customer email in this
    # subsystem is driven by a genuine transition, not by a current state. The
    # nightly sweep re-reconciles every subscription on the account, so
    # "currently active" fires every night; "just became active" fires once.
    class MembershipTransition
      # trialing and active both grant access, so moving between them is not a
      # new activation -- the welcome email already went out at trial start.
      ACCESS_GRANTING = %w[trialing active].freeze

      attr_reader :membership, :previous_status

      def initialize(membership:, previous_status:)
        @membership = membership
        @previous_status = previous_status
      end

      def status_changed?
        previous_status.to_s != membership.status.to_s
      end

      def became_active?
        ACCESS_GRANTING.include?(membership.status.to_s) &&
          !ACCESS_GRANTING.include?(previous_status.to_s)
      end

      def became_canceled?
        membership.canceled? && !previous_status.nil? && previous_status.to_s != "canceled"
      end
    end
  end
end
