# frozen_string_literal: true

module Services
  module Billing
    # Reports the legacy -> new billing migration invariants.
    #
    # Deliberately NOT a count match. A legacy-versus-new count always drifts,
    # because the legacy database is live and still creating rows while this
    # runs. The invariant is membership: every legacy subscription id must exist
    # in memberships, every paid: true user must have a legacy grant, and every
    # legacy donation must exist. Each is reported as the LIST of what is
    # missing, which is actionable; a count is not.
    #
    # Unattached memberships are reported but never fail the run -- an
    # unmappable Stripe customer is an expected outcome the spec designs for,
    # and whether the set is the one deliberately expected is a human judgement.
    class VerifyMigration
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        paid_user_ids = legacy_paid_user_ids

        subscription_ids = legacy_subscription_ids
        missing_subscriptions = subscription_ids -
          ::Membership.where(stripe_subscription_id: subscription_ids).pluck(:stripe_subscription_id)

        missing_grants = paid_user_ids -
          ::Membership.source_legacy.where(user_id: paid_user_ids).pluck(:user_id)

        donation_intent_ids = legacy_donation_intent_ids
        missing_donations = donation_intent_ids -
          ::Donation.where(stripe_payment_intent_id: donation_intent_ids).pluck(:stripe_payment_intent_id)

        # Users holding BOTH a legacy grant and a Stripe subscription -- the 6 early
        # supporters who also pay. Not a problem (legacy `paid? || active_membership?`
        # gives them both today), but two rows for one person reads as a bug unless the
        # report names it.
        #
        # Deliberately NOT gated on paid_user_ids. A legacy grant is permanent and
        # outlives the flag that created it, so a supporter whose legacy `paid` flag is
        # later cleared still holds the row and still shows two memberships in the
        # admin. Gating on the live scan would drop exactly that person from the report
        # -- reintroducing the live-drift dependency this whole service exists to avoid.
        overlap_user_ids = ::Membership.source_stripe
          .where(user_id: ::Membership.source_legacy.where.not(user_id: nil).select(:user_id))
          .distinct.pluck(:user_id).sort

        unattached = ::Membership.where(user_id: nil).order(:stripe_customer_id).map do |membership|
          {
            id: membership.id,
            stripe_customer_id: membership.stripe_customer_id,
            stripe_subscription_id: membership.stripe_subscription_id,
            status: membership.status
          }
        end

        errors = []
        errors << "#{missing_subscriptions.size} legacy subscriptions have no membership" if missing_subscriptions.any?
        errors << "#{missing_grants.size} paid users have no legacy grant" if missing_grants.any?
        errors << "#{missing_donations.size} legacy donations were not imported" if missing_donations.any?

        Result.new(
          success?: errors.empty?,
          data: {
            missing_subscriptions: missing_subscriptions,
            missing_grants: missing_grants,
            missing_donations: missing_donations,
            unattached: unattached,
            overlap_user_ids: overlap_user_ids
          },
          errors: errors
        )
      end

      private

      # The three seams that touch the legacy replica. Isolated as their own
      # methods so tests can stub them: no legacy test database exists, and no
      # test may query a LegacyBooks:: model for real.
      def legacy_subscription_ids
        LegacyBooks::Subscription.where.not(stripe_subscription_id: nil).distinct.pluck(:stripe_subscription_id)
      end

      def legacy_paid_user_ids
        LegacyBooks::User.where(paid: true).pluck(:id)
      end

      def legacy_donation_intent_ids
        LegacyBooks::Donation.where.not(stripe_payment_id: nil).distinct.pluck(:stripe_payment_id)
      end
    end
  end
end
