# frozen_string_literal: true

# The raw inbox for Stripe webhooks.
#
# Rows here are forensic evidence, never a source of truth. Nothing in the app
# reads a payload to decide what a membership's state is — that comes from
# re-reading Stripe. See Services::Billing::ReconcileCustomer.
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
class StripeEvent < ApplicationRecord
  enum :status, {received: 0, processed: 1, failed: 2, ignored: 3}

  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true
  validates :payload, presence: true
  validates :livemode, inclusion: {in: [true, false]}
  validates :stripe_created_at, presence: true

  scope :unprocessed, -> { where(status: [:received, :failed]) }
  scope :recent, -> { order(created_at: :desc) }

  # Derive the customer column from the payload so there is exactly one
  # implementation of "where does Stripe put the customer id?". The webhook
  # controller does not extract it separately.
  before_validation :derive_stripe_customer_id

  def mark_processed!
    update!(status: :processed, processed_at: Time.current, error: nil)
  end

  # Records the class and message only. The payload is never written to the
  # error column or the log: it carries customer email, name, address and card
  # last-four, and this application is open source.
  def mark_failed!(error)
    message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    update!(status: :failed, processed_at: Time.current, error: message,
      attempts: attempts + 1)
  end

  def mark_ignored!(reason)
    update!(status: :ignored, processed_at: Time.current, error: reason)
  end

  # Stripe puts the customer in different places depending on the event family:
  # customer.* events carry it as the object's own id, everything else as a
  # `customer` attribute. Returns nil for events with no customer at all
  # (price.*, product.*), which the job treats as "ignore".
  def stripe_customer_id_from_payload
    parsed_payload = payload.is_a?(String) ? JSON.parse(payload) : payload
    object = parsed_payload.dig("data", "object") || {}
    return object["id"] if object["object"] == "customer"
    object["customer"].presence
  end

  private

  def derive_stripe_customer_id
    self.stripe_customer_id ||= stripe_customer_id_from_payload
  end
end
