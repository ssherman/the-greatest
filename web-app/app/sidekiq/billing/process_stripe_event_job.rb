# frozen_string_literal: true

module Billing
  # Turns a stored event into a reconcile. The event is only ever read for an
  # identifier — never for state — which is what makes delivery order irrelevant.
  class ProcessStripeEventJob
    include Sidekiq::Job

    def perform(stripe_event_id)
      event = StripeEvent.find(stripe_event_id)
      return unless event.received? || event.failed?

      customer_id = event.stripe_customer_id_from_payload
      if customer_id.blank?
        event.mark_ignored!("no customer on event type #{event.event_type}")
        return
      end

      result = Services::Billing::ReconcileCustomer.call(stripe_customer_id: customer_id)

      if result.success?
        event.mark_processed!
      else
        # A soft failure — usually Stripe being unavailable. Recorded rather than
        # raised, because Sidekiq's retry and the nightly reconcile both cover it.
        event.mark_failed!(result.errors.join("; "))
      end
    rescue => e
      event&.mark_failed!(e)
      raise
    end
  end
end
