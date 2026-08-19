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

      UNKNOWN_INTERVAL = :unknown
      private_constant :UNKNOWN_INTERVAL

      def self.call = new.call

      def call
        resolved = []
        failures = []
        invalid = []

        ::BillingPlan.where.not(stripe_lookup_key: [nil, ""]).find_each do |plan|
          price = ::Stripe::Price.list(lookup_keys: [plan.stripe_lookup_key], active: true).data.first

          if price.nil?
            # Leave the existing id alone. Better a stale id than a nil one:
            # stripe_price_id has a presence validation, so nilling it would raise
            # on save and leave the plan half-updated.
            failures << plan.stripe_lookup_key
            next
          end

          interval = plan_interval(price)
          if interval == UNKNOWN_INTERVAL
            # A recurring interval this catalogue does not model (weekly,
            # daily, or anything Stripe adds later). Reported as a failure,
            # never silently recorded as monthly -- that would misrepresent
            # the price on the membership page.
            failures << plan.stripe_lookup_key
            next
          end

          plan.update!(
            stripe_price_id: price.id,
            # nil for a custom-amount donation price, which is correct -- the
            # amount is whatever the donor types. Writing 0 would render "$0".
            amount_cents: price.unit_amount,
            currency: price.currency,
            interval: interval
          )
          resolved << plan.stripe_lookup_key
        rescue ActiveRecord::RecordInvalid => e
          # A LOCAL validation failure -- two rows sharing a stripe_lookup_key
          # by human error, say -- never a Stripe problem. Kept in a bucket
          # separate from `failures` so the rake task's "write a lookup key
          # onto the live price" advice, which only applies when Stripe has no
          # price for that lookup key, is never shown for a problem Stripe had
          # nothing to do with. e.record.errors is an ActiveRecord validation
          # message, not a Stripe one, so logging it in full carries no
          # customer PII.
          Rails.logger.error(
            "[billing] plan sync could not save #{plan.stripe_lookup_key}: " \
            "#{e.class}: #{e.record.errors.full_messages.join(", ")}"
          )
          invalid << plan.stripe_lookup_key
        end

        data = {resolved: resolved, failures: failures, invalid: invalid}
        return Result.new(success?: true, data: data, errors: []) if failures.empty? && invalid.empty?

        # Loud, never silent: a plan pointing at a price that does not exist in
        # this account produces "No such price" at the checkout redirect, which
        # the visitor sees and nobody else does.
        errors = []
        errors << "could not resolve: #{failures.join(", ")}" if failures.any?
        errors << "could not save locally: #{invalid.join(", ")}" if invalid.any?
        Result.new(success?: false, data: data, errors: errors)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] plan sync failed: #{e.class}")
        Result.new(success?: false, data: {resolved: [], failures: [], invalid: []}, errors: [e.message])
      end

      private

      # nil for a one-off price (no recurring block at all -- the donation
      # price). UNKNOWN_INTERVAL for a recurring interval this catalogue does
      # not model.
      def plan_interval(price)
        return nil unless price.recurring

        case price.recurring.interval
        when "month" then :monthly
        when "year" then :yearly
        else UNKNOWN_INTERVAL
        end
      end
    end
  end
end
