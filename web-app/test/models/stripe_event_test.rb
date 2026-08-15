# frozen_string_literal: true

require "test_helper"

# == Schema Information
#
# Table name: stripe_events
#
#  id                 :bigint           not null, primary key
#  api_version        :string
#  attempts           :integer          default(0), not null
#  error              :text
#  event_type         :string           not null
#  livemode           :boolean          not null
#  payload            :jsonb            not null
#  processed_at       :datetime
#  status             :integer          default(0), not null
#  stripe_created_at  :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  stripe_customer_id :string
#  stripe_event_id    :string           not null
#
# Indexes
#
#  index_stripe_events_on_status_and_created_at  (status,created_at)
#  index_stripe_events_on_stripe_customer_id     (stripe_customer_id)
#  index_stripe_events_on_stripe_event_id        (stripe_event_id) UNIQUE
#
class StripeEventTest < ActiveSupport::TestCase
  test "stripe_event_id is unique" do
    duplicate = StripeEvent.new(
      stripe_event_id: stripe_events(:subscription_created).stripe_event_id,
      event_type: "customer.subscription.created", payload: {}, livemode: false,
      stripe_created_at: Time.current
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_event_id], "has already been taken"
  end

  test "a duplicate insert raises RecordNotUnique at the database level" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      StripeEvent.insert!({
        stripe_event_id: stripe_events(:subscription_created).stripe_event_id,
        event_type: "customer.subscription.created", payload: {}, livemode: false,
        status: 0, stripe_created_at: Time.current, attempts: 0,
        created_at: Time.current, updated_at: Time.current
      })
    end
  end

  test "mark_processed! stamps the time and status" do
    event = stripe_events(:subscription_created)
    event.mark_processed!
    assert event.processed?
    assert_not_nil event.processed_at
  end

  # The exception message deliberately carries a customer id of its own, so the
  # two halves of the claim are separable: what the raiser wrote is kept verbatim
  # (cus_from_exception survives), while nothing is pulled out of the stored
  # payload (cus_regular and the event id, which appear ONLY there, must not).
  # Asserting equality pins it exactly -- appending the payload for "context"
  # would break this test rather than slip through a substring match.
  test "mark_failed! records the class and message but never the payload" do
    event = stripe_events(:subscription_created)
    assert_equal "cus_regular", event.payload.dig("data", "object", "customer")

    event.mark_failed!(ArgumentError.new("no such customer: cus_from_exception"))

    assert event.failed?
    assert_equal "ArgumentError: no such customer: cus_from_exception", event.error
    refute_match "cus_regular", event.error
    refute_match "evt_subscription_created", event.error
  end

  test "mark_ignored! records the reason" do
    event = stripe_events(:subscription_created)
    event.mark_ignored!("livemode mismatch")
    assert event.ignored?
    assert_equal "livemode mismatch", event.error
  end

  test "stripe_customer_id_from_payload reads data.object.customer" do
    assert_equal "cus_regular",
      stripe_events(:subscription_created).stripe_customer_id_from_payload
  end

  test "stripe_customer_id_from_payload reads data.object.id for customer events" do
    assert_equal "cus_regular",
      stripe_events(:customer_updated).stripe_customer_id_from_payload
  end

  test "stripe_customer_id_from_payload returns nil when there is no customer" do
    assert_nil stripe_events(:no_customer).stripe_customer_id_from_payload
  end

  test "unprocessed scope returns received and failed events" do
    assert_includes StripeEvent.unprocessed, stripe_events(:subscription_created)
  end
end
