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
  end
end
