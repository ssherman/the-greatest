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
        # Returns true when Stripe is usable, false when it is not configured.
        #
        # A MISSING key is not fatal, on purpose. Nothing in this app serves a page
        # from Stripe — there is no checkout, no membership page, no user-facing
        # surface — so refusing to boot over an unconfigured optional subsystem takes
        # four production sites down to protect a feature nobody is using yet. That
        # trade is never worth it. Stripe calls fail loudly at the call site instead,
        # and `configured?` lets callers check first.
        #
        # A WRONG key is still fatal, because that one is dangerous rather than
        # merely absent: a live key with STRIPE_LIVEMODE unset would let the nightly
        # sweep pull real customer data into a non-production database. Both prefixes
        # matter — Stripe issues standard live keys as sk_live_ and restricted live
        # keys as rk_live_, and a restricted key still reads real customers.
        def configure!
          key = ENV["STRIPE_SECRET_KEY"]

          if key.to_s.start_with?("sk_live_", "rk_live_") && !livemode?
            raise ConfigurationError,
              "Refusing to boot: STRIPE_SECRET_KEY is a live key but STRIPE_LIVEMODE is not 'true'. " \
              "This guard exists so a misconfigured environment cannot touch real customers."
          end

          if key.blank?
            Rails.logger.warn(
              "[stripe] STRIPE_SECRET_KEY is not set — Stripe is disabled. Webhook deliveries " \
              "will be rejected and the reconcile sweep will fail until it is configured."
            )
            @configured = false
            return false
          end

          Stripe.api_key = key
          Stripe.api_version = API_VERSION
          @configured = true
        end

        # Whether configure! found a usable key. Callers that need Stripe should check
        # this and fail with something better than a nil api_key deep in the gem.
        def configured? = !!@configured

        def api_version = API_VERSION

        # Deliberately strict: only the exact string "true" enables livemode, so
        # a stray value can never accidentally point a test environment at
        # production data.
        def livemode? = ENV["STRIPE_LIVEMODE"] == "true"

        # Never raises. A missing webhook secret means signature verification fails
        # and deliveries are rejected with a 400 — bad, but scoped to webhooks. The
        # boot must not depend on it; see configure! for why an absent Stripe config
        # is not allowed to take the site down.
        def webhook_secret = ENV.fetch("STRIPE_WEBHOOK_SECRET", "whsec_missing")
      end
    end
  end
end
