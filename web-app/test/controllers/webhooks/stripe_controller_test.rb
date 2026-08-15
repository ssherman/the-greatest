# frozen_string_literal: true

require "test_helper"

module Webhooks
  class StripeControllerTest < ActionDispatch::IntegrationTest
    setup do
      Services::Billing::StripeClient.stubs(:webhook_secret)
        .returns(StripeWebhookHelper::TEST_WEBHOOK_SECRET)
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
  end
end
