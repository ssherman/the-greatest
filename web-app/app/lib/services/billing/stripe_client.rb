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

          # Both prefixes matter: Stripe issues standard live keys as sk_live_ and
          # restricted live keys as rk_live_, and a restricted key still reads real
          # customers. The livemode interlock only guards the webhook path, so a
          # live key here would let the nightly sweep pull production data into a
          # non-production database.
          if key.to_s.start_with?("sk_live_", "rk_live_") && !livemode?
            raise ConfigurationError,
              "Refusing to boot: STRIPE_SECRET_KEY is a live key but STRIPE_LIVEMODE is not 'true'. " \
              "This guard exists so a misconfigured environment cannot touch real customers."
          end

          # Touched here so a missing webhook secret surfaces at boot rather than on
          # the first delivery, when the only symptom is a 400 Stripe eventually
          # gives up on.
          webhook_secret

          Stripe.api_key = key
          Stripe.api_version = API_VERSION
          true
        end

        def api_version = API_VERSION

        # Deliberately strict: only the exact string "true" enables livemode, so
        # a stray value can never accidentally point a test environment at
        # production data.
        def livemode? = ENV["STRIPE_LIVEMODE"] == "true"

        # Mirrors secret_key's guard. Without it, a production deploy missing this
        # variable boots perfectly healthy and then fails signature verification on
        # every delivery with a 400 — and Stripe disables an endpoint that keeps
        # failing. Nothing in the app would look wrong while webhook ingestion was
        # entirely dead, so this must be loud.
        def webhook_secret
          ENV.fetch("STRIPE_WEBHOOK_SECRET") do
            raise ConfigurationError, "STRIPE_WEBHOOK_SECRET is not set" unless secrets_optional?
            "whsec_missing"
          end
        end

        # `assets:precompile` in the Docker build boots the entire app with
        # RAILS_ENV=production and none of the runtime secrets — SOPS injects those on
        # the server at container start, never into the image. Without this the boot
        # guard fails the image build, which blocks every deploy including unrelated
        # ones.
        #
        # SECRET_KEY_BASE_DUMMY is Rails' own signal for exactly this situation, and
        # the Dockerfile sets it inline on the precompile RUN line only, so it is
        # never present in the running container. That is what keeps the guard
        # fail-closed where it matters while letting the image build.
        def secrets_optional? = Rails.env.local? || ENV["SECRET_KEY_BASE_DUMMY"].present?

        private

        def secret_key
          ENV.fetch("STRIPE_SECRET_KEY") do
            raise ConfigurationError, "STRIPE_SECRET_KEY is not set" unless secrets_optional?
            "sk_test_missing"
          end
        end
      end
    end
  end
end
