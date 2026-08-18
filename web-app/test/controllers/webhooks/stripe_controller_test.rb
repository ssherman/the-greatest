# frozen_string_literal: true

require "test_helper"

module Webhooks
  class StripeControllerTest < ActionDispatch::IntegrationTest
    setup do
      # verified_event and webhook_configured? both go through webhook_secrets
      # (plural) now -- stubbing the singular here would be inert and every
      # other test in this file would fall through to the real ENV value.
      Services::Billing::StripeClient.stubs(:webhook_secrets)
        .returns([StripeWebhookHelper::TEST_WEBHOOK_SECRET])
    end

    test "refuses delivery when no webhook secret is configured" do
      # `whsec_missing` is a literal in this PUBLIC repo. Verifying against a published
      # constant is not verification -- anyone can sign with it and be accepted. The
      # endpoint must refuse before verification when there is no real secret.
      Services::Billing::StripeClient.unstub(:webhook_secrets)
      previous = ENV["STRIPE_WEBHOOK_SECRET"]
      ENV.delete("STRIPE_WEBHOOK_SECRET")

      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_forged", customer: "cus_forged"),
        id: "evt_forged"
      )

      Sidekiq::Testing.fake! do
        ::Billing::ProcessStripeEventJob.jobs.clear
        assert_no_difference "StripeEvent.count" do
          post_stripe_webhook(payload, secret: "whsec_missing")
        end
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :service_unavailable
      refute_equal 200, response.status, "a forged event signed with the published placeholder was ACCEPTED"
    ensure
      previous.nil? ? ENV.delete("STRIPE_WEBHOOK_SECRET") : (ENV["STRIPE_WEBHOOK_SECRET"] = previous)
    end

    test "rejects a request with no signature header and writes nothing" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})

      assert_no_difference "StripeEvent.count" do
        post "/webhooks/stripe", params: payload, headers: {"CONTENT_TYPE" => "application/json"}
      end

      assert_response :bad_request
    end

    test "rejects a signature made with the wrong secret and writes nothing" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})

      assert_no_difference "StripeEvent.count" do
        post_stripe_webhook(payload, secret: "whsec_the_wrong_secret")
      end

      assert_response :bad_request
    end

    test "rejects a signature whose timestamp is outside the tolerance window" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})
      stale = stripe_signature_header(payload, timestamp: 10.minutes.ago.to_i)

      assert_no_difference "StripeEvent.count" do
        post "/webhooks/stripe", params: payload,
          headers: {"HTTP_STRIPE_SIGNATURE" => stale, "CONTENT_TYPE" => "application/json"}
      end

      assert_response :bad_request
    end

    test "accepts a correctly signed request" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})

      # This test asserts the ENDPOINT's contract -- a correctly signed request is
      # accepted -- not what happens downstream afterwards. The suite runs
      # Sidekiq::Testing.inline!, so without this block the test would execute
      # whatever background processing the endpoint later grows, and start failing
      # for reasons that have nothing to do with signature verification.
      Sidekiq::Testing.fake! { post_stripe_webhook(payload) }

      assert_response :ok
    end

    test "records an accepted event and enqueues processing" do
      # livemode must MATCH Rails.configuration.stripe_livemode for this event to be
      # processed rather than ignored. Deriving it (instead of hardcoding false) keeps
      # the test correct regardless of STRIPE_LIVEMODE -- .env is loaded in test too,
      # so a hardcoded boolean would pass or fail by accident of the developer's
      # local environment rather than by what this test actually checks.
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_brand_new", customer: "cus_brand_new"),
        id: "evt_brand_new", livemode: Rails.configuration.stripe_livemode
      )

      Sidekiq::Testing.fake! do
        ::Billing::ProcessStripeEventJob.jobs.clear
        assert_difference "StripeEvent.count", 1 do
          post_stripe_webhook(payload)
        end
        assert_equal 1, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
      event = StripeEvent.find_by!(stripe_event_id: "evt_brand_new")
      assert_equal "customer.subscription.created", event.event_type
      assert event.received?
      assert_equal "cus_brand_new", event.stripe_customer_id
      # The FULL event is stored, not just data.object.
      assert_equal "evt_brand_new", event.payload["id"]
      assert_equal "customer.subscription.created", event.payload["type"]
    end

    test "a redelivered event returns 200 and writes no second row" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_dup", customer: "cus_dup"),
        id: "evt_dup"
      )

      Sidekiq::Testing.fake! do
        post_stripe_webhook(payload)
        ::Billing::ProcessStripeEventJob.jobs.clear

        assert_no_difference "StripeEvent.count" do
          post_stripe_webhook(payload)
        end
      end

      assert_response :ok
    end

    # A duplicate is not proof the event was handled. If the first delivery committed
    # the row and perform_async then failed -- Redis unavailable, say -- the row is
    # stranded at `received`. Answering 200 without enqueueing would tell Stripe the
    # event was delivered, it would stop retrying, and the event would never be
    # processed. The queue is cleared here to stand in for that failed enqueue.
    test "a redelivery whose job never ran is enqueued rather than reported handled" do
      # livemode must MATCH the app's, or the first delivery is ignored (not
      # received) and the assertion below fails regardless of the redelivery logic
      # this test exists to cover. See the comment on "records an accepted event...".
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_stranded", customer: "cus_stranded"),
        id: "evt_stranded", livemode: Rails.configuration.stripe_livemode
      )

      Sidekiq::Testing.fake! do
        post_stripe_webhook(payload)
        ::Billing::ProcessStripeEventJob.jobs.clear
        assert StripeEvent.find_by!(stripe_event_id: "evt_stranded").received?

        post_stripe_webhook(payload)

        assert_equal 1, ::Billing::ProcessStripeEventJob.jobs.size,
          "a redelivery of a still-unprocessed event must be re-enqueued"
      end

      assert_response :ok
    end

    test "a redelivery of an already-processed event enqueues nothing" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_done", customer: "cus_done"),
        id: "evt_done"
      )

      Sidekiq::Testing.fake! do
        post_stripe_webhook(payload)
        StripeEvent.find_by!(stripe_event_id: "evt_done").mark_processed!
        ::Billing::ProcessStripeEventJob.jobs.clear

        post_stripe_webhook(payload)

        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
    end

    test "ignores an event whose livemode does not match and writes nothing else" do
      # livemode must MISMATCH the app's for this to exercise the ignore path.
      # `!Rails.configuration.stripe_livemode` (not a hardcoded `true`) is what makes
      # that hold whatever STRIPE_LIVEMODE happens to be locally -- .env is loaded in
      # test too, and a hardcoded boolean here previously coincided with a MATCH
      # once the developer's .env set STRIPE_LIVEMODE=true, turning this into an
      # accidental "processed" test.
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_live", customer: "cus_live"),
        id: "evt_live", livemode: !Rails.configuration.stripe_livemode
      )

      Sidekiq::Testing.fake! do
        ::Billing::ProcessStripeEventJob.jobs.clear
        assert_difference "StripeEvent.count", 1 do
          post_stripe_webhook(payload)
        end
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
      assert StripeEvent.find_by!(stripe_event_id: "evt_live").ignored?
      assert_equal 0, Membership.where(stripe_customer_id: "cus_live").count
    end

    test "a non-duplicate validation failure is not silently swallowed" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_validation", customer: "cus_validation"),
        id: "evt_validation"
      )

      # A validation failure that is NOT "stripe_event_id has already been taken".
      # record_event's rescue must let it out: 200 tells Stripe the event was
      # delivered and Stripe never retries a 200, so swallowing this would lose the
      # event permanently with no audit row.
      record = StripeEvent.new(stripe_event_id: "evt_validation")
      record.errors.add(:event_type, :blank)
      StripeEvent.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(record))

      Sidekiq::Testing.fake! do
        ::Billing::ProcessStripeEventJob.jobs.clear
        post_stripe_webhook(payload)
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      refute_equal 200, response.status,
        "a non-duplicate validation failure was reported to Stripe as delivered"
    end

    test "an event signed with the second configured secret is accepted" do
      # The setup block stub is on webhook_secrets (plural) and would shadow the
      # ENV variable set below -- this test's whole point is exercising the real
      # comma-separated parsing, so it must go.
      Services::Billing::StripeClient.unstub(:webhook_secrets)
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_two_secret", customer: "cus_two_secret"),
        id: "evt_two_secret",
        livemode: Rails.configuration.stripe_livemode
      )

      # Fake, not inline: a verified event enqueues ProcessStripeEventJob, and the
      # suite runs Sidekiq inline by default. This test asserts the endpoint's
      # signature-verification contract, not what a real reconcile sweep does.
      Sidekiq::Testing.fake! do
        with_stripe_webhook_secrets("whsec_other_endpoint,#{StripeWebhookHelper::TEST_WEBHOOK_SECRET}") do
          post webhooks_stripe_url, params: payload,
            headers: {"HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload),
                      "CONTENT_TYPE" => "application/json"}
        end
      end

      assert_response :ok
      assert StripeEvent.exists?(stripe_event_id: "evt_two_secret")
    end

    test "an event signed with none of the configured secrets is rejected" do
      Services::Billing::StripeClient.unstub(:webhook_secrets)
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_bad_sig", customer: "cus_bad_sig"),
        id: "evt_bad_sig",
        livemode: Rails.configuration.stripe_livemode
      )

      assert_no_difference "StripeEvent.count" do
        with_stripe_webhook_secrets("whsec_first,whsec_second") do
          post webhooks_stripe_url, params: payload,
            headers: {"HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload, secret: "whsec_not_configured"),
                      "CONTENT_TYPE" => "application/json"}
        end
      end

      assert_response :bad_request
    end

    private

    def with_stripe_webhook_secrets(value)
      previous = ENV["STRIPE_WEBHOOK_SECRET"]
      ENV["STRIPE_WEBHOOK_SECRET"] = value
      yield
    ensure
      previous.nil? ? ENV.delete("STRIPE_WEBHOOK_SECRET") : (ENV["STRIPE_WEBHOOK_SECRET"] = previous)
    end
  end
end
