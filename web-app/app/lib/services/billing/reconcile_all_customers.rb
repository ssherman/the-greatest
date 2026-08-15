# frozen_string_literal: true

module Services
  module Billing
    # Sweeps every subscription in the Stripe account and reconciles each
    # distinct customer.
    #
    # Three jobs, one implementation:
    #   1. the initial data migration from the legacy books app
    #   2. a nightly drift check
    #   3. recovery if the webhook endpoint is ever down past Stripe's 72-hour
    #      retry window, after which events are gone for good
    #
    # One customer failing never stops the sweep; failures are collected and
    # reported so a partial outage is visible rather than silent.
    class ReconcileAllCustomers
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        customer_ids = distinct_customer_ids
        failed = []
        reconciled = 0

        customer_ids.each do |customer_id|
          result = ReconcileCustomer.call(stripe_customer_id: customer_id)
          if result.success?
            reconciled += 1
          else
            failed << customer_id
            Rails.logger.error("[billing] sweep could not reconcile #{customer_id}: #{result.errors.join("; ")}")
          end
        rescue => e
          # ReconcileCustomer only rescues Stripe::StripeError, so anything else --
          # an unknown subscription status Stripe added after this enum was written,
          # a nil period end -- would propagate and abort the entire sweep. One
          # poisoned customer must never cost every other customer their nightly
          # reconcile, because this sweep is the recovery path when webhooks have
          # been down past Stripe's 72-hour retry window.
          failed << customer_id
          Rails.logger.error("[billing] sweep could not reconcile #{customer_id}: #{e.class}: #{e.message}")
        end

        # Fail only when there were customers and NONE reconciled — the signature of
        # a systemic problem (Stripe down, credentials wrong) that a Sidekiq retry
        # can actually fix. The job raises on a failure Result, so this is what
        # decides whether the sweep is retried.
        #
        # Deliberately NOT "fail if anything failed": one permanently broken customer
        # -- a subscription carrying a status this enum does not know, say -- would
        # then make every nightly sweep raise and burn its retries forever, which is
        # exactly the "one poisoned customer must not cost everyone else" property
        # the per-customer rescue above exists to provide.
        swept_nothing = customer_ids.any? && reconciled.zero?

        Result.new(
          success?: !swept_nothing,
          data: {customers: customer_ids.size, reconciled: reconciled, failed: failed},
          errors: swept_nothing ? ["reconciled 0 of #{customer_ids.size} customers"] : []
        )
      rescue Stripe::StripeError => e
        Rails.logger.error("[billing] sweep aborted: #{e.class}")
        Result.new(success?: false, data: nil, errors: [e.message])
      end

      private

      def distinct_customer_ids
        list = Stripe::Subscription.list(status: "all", limit: 100)
        list.auto_paging_each.to_a.filter_map { |subscription| subscription.customer }.uniq
      end
    end
  end
end
