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
            Rails.logger.error("[billing] sweep could not reconcile #{customer_id}")
          end
        end

        Result.new(
          success?: true,
          data: {customers: customer_ids.size, reconciled: reconciled, failed: failed},
          errors: []
        )
      rescue Stripe::StripeError => e
        Rails.logger.error("[billing] sweep aborted: #{e.class}")
        Result.new(success?: false, data: nil, errors: [e.message])
      end

      private

      def distinct_customer_ids
        list = Stripe::Subscription.list(status: "all", limit: 100)
        rows = list.respond_to?(:auto_paging_each) ? list.auto_paging_each.to_a : list.data
        rows.filter_map { |subscription| subscription.customer }.uniq
      end
    end
  end
end
