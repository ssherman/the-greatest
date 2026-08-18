# frozen_string_literal: true

module Services
  module Billing
    # Writes a Donation row for a completed one-off payment.
    #
    # Takes only the checkout session ID from the event -- an identifier, never
    # state -- and re-reads the session from the Stripe API for the amount, the
    # paid status and the donor's email, exactly as ReconcileCustomer re-reads
    # subscriptions. That is why a replayed or out-of-order delivery converges
    # instead of double-counting.
    #
    # This also records donations the LEGACY books app takes, because both apps
    # share one Stripe account and both endpoints receive every event. That is
    # intended: stripe_payment_intent_id is unique, so a webhook-recorded row and
    # a migration-imported row converge rather than duplicating. Their domain is
    # nil, which is correct -- they did not come from one of our sites.
    class RecordDonation
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(checkout_session_id:) = new(checkout_session_id: checkout_session_id).call

      def initialize(checkout_session_id:)
        @checkout_session_id = checkout_session_id
      end

      def call
        return failure("checkout_session_id is required") if @checkout_session_id.blank?

        session = ::Stripe::Checkout::Session.retrieve(@checkout_session_id)

        return success(nil) unless session.mode == "payment"
        return success(nil) unless session.payment_status == "paid"

        payment_intent_id = session.payment_intent
        # Without an intent id there is no idempotency key, and
        # find_or_initialize_by(nil) would match the first row with a null intent
        # -- an imported legacy donation -- and overwrite it.
        return success(nil) if payment_intent_id.blank?

        donation = ::Donation.find_or_initialize_by(stripe_payment_intent_id: payment_intent_id)
        donation.assign_attributes(
          user: resolve_user(session),
          amount_cents: session.amount_total,
          currency: session.currency,
          status: :succeeded,
          stripe_checkout_session_id: session.id,
          email: session.customer_details&.email,
          domain: session.metadata&.[]("origin_domain")
        )
        donation.save!

        success(donation)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] donation record failed for #{@checkout_session_id}: #{e.class}")
        failure(e.message)
      end

      private

      # Anonymous donations are allowed and stay unattached. Two paths, in the
      # same order the reconciler uses.
      def resolve_user(session)
        app_user_id = session.metadata&.[]("app_user_id").presence || session.client_reference_id.presence
        return ::User.find_by(id: app_user_id) if app_user_id

        ::User.find_by(stripe_customer_id: session.customer) if session.customer.present?
      end

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
