# frozen_string_literal: true

module Services
  module Billing
    # Creates membership and donation products/prices in a SANDBOX and seeds
    # billing_plans to match. A local-development and disaster-recovery tool.
    class BootstrapPlans
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # No "donation" entry: CreateDonationPrice sets its own lookup key
      # (CreateDonationPrice::LOOKUP_KEY) and nothing here ever reads one for
      # the donation price -- a third entry would be documentation
      # masquerading as configuration.
      LOOKUP_KEYS = {
        "monthly" => "membership_monthly",
        "yearly" => "membership_yearly"
      }.freeze

      def self.call = new.call

      def call
        # Refuses in livemode, hard. The production account already sells
        # membership through the legacy books app's products, and the whole "one
        # membership, all sites" decision rests on the new app selling through
        # those SAME prices. Creating a second set here would split subscribers
        # across two products with no way to tell them apart afterwards.
        if Rails.configuration.stripe_livemode
          return failure(
            "refusing to bootstrap: STRIPE_LIVEMODE is true and this is a sandbox-only tool. " \
            "Production plans point at the legacy account's existing prices -- see " \
            "docs/guides/stripe-account-setup.md."
          )
        end

        membership = ::Stripe::Product.create(
          name: "The Greatest Membership",
          description: "Membership across The Greatest Books, Music and Games"
        )

        monthly = ::Stripe::Price.create(
          product: membership.id, currency: "usd", unit_amount: 500,
          recurring: {interval: "month"}, lookup_key: LOOKUP_KEYS["monthly"],
          nickname: "Monthly membership"
        )

        yearly = ::Stripe::Price.create(
          product: membership.id, currency: "usd", unit_amount: 5000,
          recurring: {interval: "year"}, lookup_key: LOOKUP_KEYS["yearly"],
          nickname: "Yearly membership"
        )

        donation = CreateDonationPrice.call
        return failure(donation.errors.join("; ")) unless donation.success?

        plans = [
          upsert(key: "monthly", name: "Monthly Membership", kind: :membership, interval: :monthly, price: monthly, position: 0),
          upsert(key: "yearly", name: "Yearly Membership", kind: :membership, interval: :yearly, price: yearly, position: 1),
          upsert(key: "donation", name: "One-time Donation", kind: :donation, interval: nil, price: donation.data, position: 2)
        ]

        Result.new(success?: true, data: plans, errors: [])
      rescue ::Stripe::StripeError, ActiveRecord::RecordInvalid => e
        # RecordInvalid alongside StripeError: an upsert failing to save (a
        # duplicate stripe_price_id, say) must become a reported failure like
        # any other, not an unhandled exception out of a rake task.
        Rails.logger.error("[billing] bootstrap failed: #{e.class}")
        failure(e.message)
      end

      private

      # find_or_initialize_by on the natural key, so re-running is a no-op rather
      # than a duplicate -- the same rule the DataImporters follow.
      def upsert(key:, name:, kind:, interval:, price:, position:)
        plan = ::BillingPlan.find_or_initialize_by(key: key)
        plan.update!(
          name: name, kind: kind, interval: interval, position: position,
          stripe_price_id: price.id, stripe_lookup_key: price.lookup_key,
          amount_cents: price.unit_amount, currency: price.currency, active: true
        )
        plan
      end

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
