# frozen_string_literal: true

module Billing
  # Turns a stored event into a reconcile. The event is only ever read for an
  # identifier — never for state — which is what makes delivery order irrelevant.
  class ProcessStripeEventJob
    include Sidekiq::Job

    # Event types that mean "a one-off payment has settled -- go record the
    # donation". checkout.session.completed covers the common, immediate
    # case. checkout.session.async_payment_succeeded exists for
    # delayed-notification payment methods (ACH Direct Debit, SEPA Direct
    # Debit, Bacs, Boleto, OXXO, Konbini, ...): Stripe fires
    # checkout.session.completed right away with payment_status still
    # "unpaid", so RecordDonation's payment_status check no-ops on that
    # delivery, and reports the eventual settlement -- sometimes days later --
    # as this second, separate event instead. Without subscribing to it, a
    # settled delayed-method donation is never recorded even though the money
    # arrives. Both event types deliver a Checkout Session as data.object, so
    # RecordDonation needs no change: it re-reads the session from the API,
    # where payment_status is "paid" by the time either of these fires.
    #
    # Deliberately NOT checkout.session.async_payment_failed: there is
    # nothing to record on a failed delayed payment, and subscribing to it
    # would only add ignored-row noise to stripe_events for an event this job
    # never acts on.
    DONATION_COMPLETION_EVENT_TYPES = %w[
      checkout.session.completed
      checkout.session.async_payment_succeeded
    ].freeze

    def perform(stripe_event_id)
      event = StripeEvent.find(stripe_event_id)
      return unless event.received? || event.failed?

      # A donation has no subscription, and an anonymous one has no customer at
      # all, so it must be handled before the customer check below -- otherwise
      # every anonymous donation is marked "ignored" and never recorded.
      donation = record_donation(event)

      customer_id = event.stripe_customer_id_from_payload
      if customer_id.blank?
        if donation
          event.mark_processed!
        else
          event.mark_ignored!("no customer on event type #{event.event_type}")
        end
        return
      end

      result = Services::Billing::ReconcileCustomer.call(stripe_customer_id: customer_id)

      if result.success?
        event.mark_processed!
      else
        # Raise rather than returning: returning would tell Sidekiq the job succeeded,
        # leaving the membership stale until the nightly sweep -- up to 24 hours for
        # what is usually a seconds-long blip. The method's outer rescue does the
        # mark_failed! bookkeeping, so this branch must NOT call it too, or attempts
        # would increment twice for one execution.
        raise result.errors.join("; ")
      end
    rescue => e
      event&.mark_failed!(e)
      raise
    end

    private

    # Returns the Donation when one was written, nil otherwise. Reads only the
    # session id from the payload; everything else comes from a fresh API read.
    # A Stripe failure propagates so the outer rescue marks the event failed and
    # Sidekiq retries -- silently dropping a donation is not an option.
    def record_donation(event)
      return nil unless DONATION_COMPLETION_EVENT_TYPES.include?(event.event_type)

      session_id = event.payload.dig("data", "object", "id")
      return nil if session_id.blank?

      result = Services::Billing::RecordDonation.call(checkout_session_id: session_id)
      raise result.errors.join("; ") unless result.success?

      result.data
    end
  end
end
