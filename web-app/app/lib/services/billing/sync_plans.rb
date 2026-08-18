# frozen_string_literal: true

module Services
  module Billing
    # Re-resolves every billing_plan's Stripe price id from its lookup key,
    # against whichever Stripe account this environment is pointed at.
    #
    # This is what replaces the legacy app's hand-edited per-environment block in
    # config/stripe_products.yml. A lookup key is stable across accounts; a price
    # id is not.
    class SyncPlans
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        resolved = []
        failures = []

        ::BillingPlan.where.not(stripe_lookup_key: [nil, ""]).find_each do |plan|
          price = ::Stripe::Price.list(lookup_keys: [plan.stripe_lookup_key], active: true).data.first

          if price.nil?
            # Leave the existing id alone. Better a stale id than a nil one:
            # stripe_price_id has a presence validation, so nilling it would raise
            # on save and leave the plan half-updated.
            failures << plan.stripe_lookup_key
            next
          end

          plan.update!(
            stripe_price_id: price.id,
            # nil for a custom-amount donation price, which is correct -- the
            # amount is whatever the donor types. Writing 0 would render "$0".
            amount_cents: price.unit_amount,
            currency: price.currency,
            interval: price.recurring && ((price.recurring.interval == "year") ? :yearly : :monthly)
          )
          resolved << plan.stripe_lookup_key
        rescue ActiveRecord::RecordInvalid
          # One plan's row failing to save (e.g. a duplicate stripe_price_id --
          # data corruption Stripe itself could never produce, since price ids
          # are globally unique, but the catalogue could) must never cost every
          # other plan its resolution. Same "one poisoned item" rule
          # ReconcileAllCustomers follows for the nightly customer sweep.
          failures << plan.stripe_lookup_key
        end

        data = {resolved: resolved, failures: failures}
        return Result.new(success?: true, data: data, errors: []) if failures.empty?

        # Loud, never silent: a plan pointing at a price that does not exist in
        # this account produces "No such price" at the checkout redirect, which
        # the visitor sees and nobody else does.
        Result.new(success?: false, data: data,
          errors: ["could not resolve: #{failures.join(", ")}"])
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] plan sync failed: #{e.class}")
        Result.new(success?: false, data: {resolved: [], failures: []}, errors: [e.message])
      end
    end
  end
end
