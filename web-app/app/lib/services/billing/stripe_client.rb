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

      # Stamped onto every Stripe object this application creates -- customers,
      # checkout sessions, subscriptions, payment intents. The legacy books app
      # shares this Stripe account and reads this tag to decide "not mine, skip".
      # See docs/specs/membership-and-stripe-billing.md, "Legacy coexistence".
      ORIGIN_APP = "the-greatest"

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

        # Every signing secret this deployment will accept.
        #
        # Plural because the account registers one endpoint per production host
        # (music and games), and Stripe issues a SEPARATE signing secret per
        # endpoint. Verifying against only one would 400 every delivery to the
        # other, and Stripe disables an endpoint that keeps failing. Set
        # STRIPE_WEBHOOK_SECRET to a comma-separated list.
        #
        # There is deliberately NO placeholder fallback. This repository is
        # public, so any literal here is a published value, and verifying a
        # signature against a published value is not verification. An earlier
        # version returned "whsec_missing" and was exactly that bypass. Callers
        # must check webhook_configured? and refuse the request instead.
        def webhook_secrets
          ENV["STRIPE_WEBHOOK_SECRET"].to_s.split(",").map(&:strip).reject(&:empty?)
        end

        # Retained as compatible API surface: existing callers that only ever
        # needed "a" secret still work unchanged. There is currently no caller
        # in app/ or lib/ -- verified_event and webhook_configured? both go
        # through webhook_secrets (plural), and so does local `stripe listen`.
        def webhook_secret = webhook_secrets.first

        # Whether deliveries can be verified at all. The webhook endpoint
        # refuses before verification when this is false.
        def webhook_configured? = webhook_secrets.any?
      end
    end
  end
end
