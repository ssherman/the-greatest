# frozen_string_literal: true

module Billing
  # Turns a stored event into a reconcile. The event is only ever read for an
  # identifier — never for state — which is what makes delivery order irrelevant.
  class ProcessStripeEventJob
    include Sidekiq::Job

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
      return nil unless event.event_type == "checkout.session.completed"

      session_id = event.payload.dig("data", "object", "id")
      return nil if session_id.blank?

      result = Services::Billing::RecordDonation.call(checkout_session_id: session_id)
      raise result.errors.join("; ") unless result.success?

      result.data
    end
  end
end
