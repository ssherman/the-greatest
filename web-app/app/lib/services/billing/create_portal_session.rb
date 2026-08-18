# frozen_string_literal: true

module Services
  module Billing
    # A per-customer Billing Portal session -- cancel, update card, see invoices.
    #
    # Replaces the legacy app's hardcoded billing.stripe.com/p/login/... link,
    # which is a shared login page that asks the customer to type their email and
    # wait for a code. A session URL drops them straight into their own portal.
    #
    # Requires a portal CONFIGURATION activated on the Stripe account for the
    # current livemode. That is dashboard setup, not code -- see
    # docs/guides/stripe-account-setup.md. Without it Stripe raises
    # InvalidRequestError and this returns a failed Result.
    class CreatePortalSession
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(customer_id:, return_url:) = new(customer_id: customer_id, return_url: return_url).call

      def initialize(customer_id:, return_url:)
        @customer_id = customer_id
        @return_url = return_url
      end

      def call
        return failure("customer_id is required") if @customer_id.blank?

        session = ::Stripe::BillingPortal::Session.create(
          customer: @customer_id, return_url: @return_url
        )
        success(session.url)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] portal session failed: #{e.class}")
        failure(e.message)
      end

      private

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
