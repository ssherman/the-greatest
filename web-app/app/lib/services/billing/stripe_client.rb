# frozen_string_literal: true

module Services
  module Billing
    # The only place in the app that reads Stripe configuration from ENV.
    #
    # The api_version pin is load-bearing: upgrading the gem would otherwise
    # silently change payload shapes underneath the reconciler. Stripe's Basil
    # release (2025-03-31) is the cautionary example — it moved
    # current_period_end off the Subscription object onto subscription items.
    class StripeClient
      class ConfigurationError < StandardError; end

      API_VERSION = "2026-07-29.dahlia"

      class << self
        def configure!
          key = secret_key

          if key.to_s.start_with?("sk_live_") && !livemode?
            raise ConfigurationError,
              "Refusing to boot: STRIPE_SECRET_KEY is a live key but STRIPE_LIVEMODE is not 'true'. " \
              "This guard exists so a misconfigured environment cannot touch real customers."
          end

          Stripe.api_key = key
          Stripe.api_version = API_VERSION
          true
        end

        def api_version = API_VERSION

        # Deliberately strict: only the exact string "true" enables livemode, so
        # a stray value can never accidentally point a test environment at
        # production data.
        def livemode? = ENV["STRIPE_LIVEMODE"] == "true"

        def webhook_secret = ENV.fetch("STRIPE_WEBHOOK_SECRET", "whsec_missing")

        private

        def secret_key
          ENV.fetch("STRIPE_SECRET_KEY") do
            raise ConfigurationError, "STRIPE_SECRET_KEY is not set" unless Rails.env.local?
            "sk_test_missing"
          end
        end
      end
    end
  end
end
