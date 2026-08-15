# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class StripeClientTest < ActiveSupport::TestCase
      test "livemode? is true only for the exact string true" do
        with_env("STRIPE_LIVEMODE" => "true") { assert StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => "false") { refute StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => "TRUE") { refute StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => nil) { refute StripeClient.livemode? }
      end

      test "configure! raises when a live key is used outside livemode" do
        with_env("STRIPE_SECRET_KEY" => "sk_live_abc123", "STRIPE_LIVEMODE" => "false") do
          error = assert_raises(StripeClient::ConfigurationError) { StripeClient.configure! }
          assert_match(/live key/i, error.message)
        end
      end

      # Stripe issues restricted live keys as rk_live_. They read real customers just
      # as sk_live_ does, and the livemode interlock only guards the webhook path --
      # the nightly sweep would happily pull production data into a dev database.
      test "configure! raises when a restricted live key is used outside livemode" do
        with_env("STRIPE_SECRET_KEY" => "rk_live_abc123", "STRIPE_LIVEMODE" => "false") do
          error = assert_raises(StripeClient::ConfigurationError) { StripeClient.configure! }
          assert_match(/live key/i, error.message)
        end
      end

      test "configure! accepts a live key when livemode is on" do
        with_env("STRIPE_SECRET_KEY" => "sk_live_abc123", "STRIPE_LIVEMODE" => "true") do
          StripeClient.configure!
          assert_equal "sk_live_abc123", Stripe.api_key
        end
      end

      test "configure! pins the API version" do
        with_env("STRIPE_SECRET_KEY" => "sk_test_abc", "STRIPE_LIVEMODE" => "false") do
          StripeClient.configure!
          assert_equal "2026-07-29.dahlia", Stripe.api_version
        end
      end

      test "webhook_secret reads the environment variable" do
        with_env("STRIPE_WEBHOOK_SECRET" => "whsec_xyz") do
          assert_equal "whsec_xyz", StripeClient.webhook_secret
        end
      end

      # Without this guard a production deploy missing the variable boots healthy and
      # then 400s every delivery, and Stripe disables an endpoint that keeps failing.
      # Nothing would look wrong while webhook ingestion was entirely dead.
      test "webhook_secret raises outside local environments when unset" do
        with_env("STRIPE_WEBHOOK_SECRET" => nil) do
          Rails.env.stubs(:local?).returns(false)
          error = assert_raises(StripeClient::ConfigurationError) { StripeClient.webhook_secret }
          assert_match(/STRIPE_WEBHOOK_SECRET/, error.message)
        end
      end

      test "webhook_secret falls back to a placeholder locally" do
        with_env("STRIPE_WEBHOOK_SECRET" => nil) do
          assert_equal "whsec_missing", StripeClient.webhook_secret
        end
      end

      # `assets:precompile` in the Docker build boots the app with
      # RAILS_ENV=production and no runtime secrets — SOPS injects those at container
      # start, not into the image. Raising there fails the image build and blocks
      # every deploy, including unrelated ones. These two tests are the regression
      # guard for that; without them the failure only appears in the deploy pipeline.
      test "configure! tolerates missing secrets during a build-time precompile boot" do
        with_env("STRIPE_SECRET_KEY" => nil, "STRIPE_WEBHOOK_SECRET" => nil,
          "SECRET_KEY_BASE_DUMMY" => "1") do
          Rails.env.stubs(:local?).returns(false)
          StripeClient.configure!
          assert_equal "sk_test_missing", Stripe.api_key
        end
      end

      test "webhook_secret tolerates a build-time precompile boot" do
        with_env("STRIPE_WEBHOOK_SECRET" => nil, "SECRET_KEY_BASE_DUMMY" => "1") do
          Rails.env.stubs(:local?).returns(false)
          assert_equal "whsec_missing", StripeClient.webhook_secret
        end
      end

      # The guard must stay fail-closed for a real container start, where
      # SECRET_KEY_BASE_DUMMY is absent — the Dockerfile sets it inline on the
      # precompile RUN line only, never in the image's ENV.
      test "configure! still raises at runtime in production without the secret" do
        with_env("STRIPE_SECRET_KEY" => nil, "SECRET_KEY_BASE_DUMMY" => nil) do
          Rails.env.stubs(:local?).returns(false)
          assert_raises(StripeClient::ConfigurationError) { StripeClient.configure! }
        end
      end

      test "api_version returns the exact API version string" do
        assert_equal "2026-07-29.dahlia", StripeClient.api_version
      end

      private

      # Sets ENV keys for the block and restores prior values afterwards.
      # Also saves and restores Stripe module globals to prevent test pollution.
      def with_env(pairs)
        previous_env = pairs.keys.index_with { |key| ENV[key] }
        previous_stripe_key = Stripe.api_key
        previous_stripe_version = Stripe.api_version

        pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        Stripe.api_key = previous_stripe_key
        Stripe.api_version = previous_stripe_version
      end
    end
  end
end
