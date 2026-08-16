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
    #
    # `missing_grants` is split into two categories, because a naive "every
    # paid: true legacy user has a legacy grant" check has a permanent false
    # positive built in. MembershipMigrator deliberately SKIPS a legacy user
    # who has no row in the new `users` table yet -- the user migration is a
    # separate, occasional task, and the legacy database is live, so a brand
    # new legacy signup who pays shows up here before the next user import
    # ever runs. Reporting that as a failure trains the operator to ignore
    # `verify_migration`'s exit code, which defeats the point of it.
    #
    # - `missing_grants` (fails the run) -- the legacy user DOES exist in the
    #   new `users` table but has no `source: :legacy` membership. The importer
    #   should have created one and did not: a genuine migration gap.
    # - `unmigrated_users` (reported, never fails) -- the legacy user does not
    #   exist in the new `users` table at all. Expected drift, not a billing
    #   problem; the remedy is `data_migration:users`, not re-running this
    #   task or investigating the importer.
    class VerifyMigration
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        paid_user_ids = legacy_paid_user_ids

        subscription_ids = legacy_subscription_ids
        missing_subscriptions = subscription_ids -
          ::Membership.where(stripe_subscription_id: subscription_ids).pluck(:stripe_subscription_id)

        ungranted_user_ids = paid_user_ids -
          ::Membership.source_legacy.where(user_id: paid_user_ids).pluck(:user_id)
        # Split by whether the new `users` table even has the row.
        # MembershipMigrator's own skip condition, mirrored here so the two
        # never drift apart.
        existing_user_ids = ::User.where(id: ungranted_user_ids).pluck(:id).to_set
        missing_grants = ungranted_user_ids.select { |id| existing_user_ids.include?(id) }
        unmigrated_users = ungranted_user_ids - missing_grants

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
            overlap_user_ids: overlap_user_ids,
            unmigrated_users: unmigrated_users
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
