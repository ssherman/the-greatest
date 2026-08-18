# frozen_string_literal: true

module Services
  module Billing
    # Creates a Stripe Checkout Session for a membership plan or a donation.
    #
    # THREE THINGS IN HERE ARE LOAD-BEARING FOR LEGACY COEXISTENCE. The legacy
    # books app shares this Stripe account until books cuts over, and its webhook
    # handler decides whether an event is its own. Breaking any of these silently
    # re-opens a defect on the legacy side, with a 200 and no error anywhere:
    #
    #   1. Top-level metadata[origin_app] on EVERY session, both modes. A donation
    #      has no subscription to carry the tag.
    #   2. subscription_data[metadata][origin_app] on subscription-mode sessions,
    #      because the subscription outlives the session and later
    #      customer.subscription.* events carry only the subscription.
    #   3. Sessions are created through this API and NEVER through a Payment Link.
    #      Legacy's structural guard is "this session has no payment_link, so it
    #      is not mine"; a session made via a payment link carries one.
    #
    # See docs/specs/membership-and-stripe-billing.md, "Legacy coexistence".
    #
    # The caller passes a BillingPlan record, never a price id, an amount or a
    # user id from the request. A client that could name a price could name a
    # $0.01 one.
    class CreateCheckoutSession
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # One definition, on StripeClient (Task 6). Do not re-declare it here.
      ORIGIN_APP = StripeClient::ORIGIN_APP

      def self.call(plan:, success_url:, cancel_url:, user: nil, customer_id: nil, domain: nil)
        new(plan: plan, success_url: success_url, cancel_url: cancel_url,
          user: user, customer_id: customer_id, domain: domain).call
      end

      def initialize(plan:, success_url:, cancel_url:, user:, customer_id:, domain:)
        @plan = plan
        @success_url = success_url
        @cancel_url = cancel_url
        @user = user
        @customer_id = customer_id
        @domain = domain
      end

      def call
        return failure("plan is required") if @plan.nil?
        return failure("a membership requires a signed-in user") if @plan.kind_membership? && @user.nil?
        return failure("a membership requires a customer_id") if @plan.kind_membership? && @customer_id.blank?

        session = ::Stripe::Checkout::Session.create(session_params)
        success(session.url)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] checkout session failed for plan #{@plan&.key}: #{e.class}")
        failure(e.message)
      end

      private

      def session_params
        base = {
          line_items: [{price: @plan.stripe_price_id, quantity: 1}],
          success_url: @success_url,
          cancel_url: @cancel_url,
          metadata: {
            origin_app: ORIGIN_APP,
            origin_domain: @domain.to_s.presence,
            app_user_id: @user&.id
          }.compact
        }

        @plan.kind_membership? ? base.merge(subscription_params) : base.merge(donation_params)
      end

      def subscription_params
        {
          mode: "subscription",
          customer: @customer_id,
          client_reference_id: @user.id.to_s,
          subscription_data: {
            metadata: {app_user_id: @user.id, origin_app: ORIGIN_APP, origin_domain: @domain.to_s.presence}.compact
          }
        }
      end

      def donation_params
        params = {mode: "payment", submit_type: "donate"}
        # Anonymous donations are allowed and deliberately create no Customer --
        # Stripe collects the email at checkout. Attaching a customer we invented
        # for a one-off donor would pollute the account with rows the reconciler
        # then pages through every night.
        params[:customer] = @customer_id if @customer_id.present?
        params[:payment_intent_data] = {
          metadata: {origin_app: ORIGIN_APP, origin_domain: @domain.to_s.presence, app_user_id: @user&.id}.compact
        }
        params
      end

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
