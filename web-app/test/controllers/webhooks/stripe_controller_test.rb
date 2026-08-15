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

    test "records an accepted event and enqueues processing" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_brand_new", customer: "cus_brand_new"),
        id: "evt_brand_new"
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

    test "a redelivered event returns 200, writes no second row and enqueues nothing" do
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
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
    end

    test "ignores an event whose livemode does not match and writes nothing else" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_live", customer: "cus_live"),
        id: "evt_live", livemode: true
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
      # Build a mock Stripe event object to pass to the controller.
      # This avoids the HTTP request layer and tests record_event directly.
      mock_event = Object.new
      mock_event.stubs(:id).returns("evt_validation")
      mock_event.stubs(:type).returns("customer.subscription.created")
      mock_event.stubs(:livemode).returns(false)
      mock_event.stubs(:api_version).returns("2024-04-10")
      mock_event.stubs(:created).returns(Time.current.to_i)
      mock_event.stubs(:to_hash).returns({
        "id" => "evt_validation",
        "type" => "customer.subscription.created",
        "data" => {"object" => {"id" => "sub_validation", "customer" => "cus_validation"}}
      })

      # Stub create! to raise RecordInvalid with an error that is NOT stripe_event_id.
      record = StripeEvent.new(stripe_event_id: "evt_validation")
      record.errors.add(:event_type, :blank)
      StripeEvent.stubs(:create!).raises(ActiveRecord::RecordInvalid.new(record))

      controller = Webhooks::StripeController.new
      # The record_event method should raise RecordInvalid because the error
      # is NOT :stripe_event_id being :taken.
      assert_raises(ActiveRecord::RecordInvalid) do
        controller.send(:record_event, mock_event)
      end
    end
  end
end
