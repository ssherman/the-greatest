# frozen_string_literal: true

# Builds real Stripe webhook signatures for tests.
#
# Stripe signs the string "#{timestamp}.#{payload}" with HMAC-SHA256 and sends
# it as "t=<timestamp>,v1=<hex>". Generating that here rather than checking in a
# captured header means signature verification is genuinely exercised and no
# real signing secret ever lands in the repository.
module StripeWebhookHelper
  TEST_WEBHOOK_SECRET = "whsec_test_dummy_secret"

  def stripe_event_payload(type:, object:, id: "evt_test_#{SecureRandom.hex(6)}", livemode: false)
    {
      id: id,
      object: "event",
      type: type,
      livemode: livemode,
      api_version: Services::Billing::StripeClient::API_VERSION,
      created: Time.current.to_i,
      data: {object: object}
    }.to_json
  end

  def stripe_signature_header(payload, secret: TEST_WEBHOOK_SECRET, timestamp: Time.current.to_i)
    signed = "#{timestamp}.#{payload}"
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, signed)
    "t=#{timestamp},v1=#{digest}"
  end

  # Minimal subscription object, shaped like the API version we pin. Note
  # current_period_end lives on the ITEM, not the subscription — Basil moved it.
  # metadata defaults to {} to match a subscription with no metadata at all,
  # which is what legacy's Payment Links produce.
  def stripe_subscription_object(id:, customer:, status: "active", interval: "month",
    period_end: 30.days.from_now, cancel_at_period_end: false, canceled_at: nil, metadata: {})
    {
      id: id,
      object: "subscription",
      customer: customer,
      status: status,
      cancel_at_period_end: cancel_at_period_end,
      canceled_at: canceled_at&.to_i,
      metadata: metadata,
      items: {
        object: "list",
        data: [{
          id: "si_#{id}",
          object: "subscription_item",
          current_period_end: period_end.to_i,
          current_period_start: (period_end - 30.days).to_i,
          price: {id: "price_test_monthly", recurring: {interval: interval}}
        }]
      }
    }
  end

  # Posts a correctly signed webhook. Returns the raw payload so callers can
  # assert on the stored row.
  def post_stripe_webhook(payload, secret: TEST_WEBHOOK_SECRET)
    post "/webhooks/stripe",
      params: payload,
      headers: {
        "HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload, secret: secret),
        "CONTENT_TYPE" => "application/json"
      }
    payload
  end
end
