# frozen_string_literal: true

module Webhooks
  # Inherits ActionController::Base rather than ApplicationController on
  # purpose: no Pundit, no set_current_domain, no allow_browser check standing
  # between Stripe and a 200.
  #
  # There is no verification bypass — not behind an ENV var, not behind
  # Rails.env.development?, not behind a param. This application is open source,
  # and a bypass someone can read about is a bypass someone will probe for.
  # Local development uses `stripe listen`, which signs with a real secret.
  class StripeController < ActionController::Base
    skip_forgery_protection

    def create
      event = verified_event
      return head :bad_request if event.nil?

      record = record_event(event)
      return head :ok if record.nil? # redelivery; already handled

      if event.livemode != Rails.configuration.stripe_livemode
        # The interlock. A sandbox endpoint misconfigured to point at production
        # (or the reverse) writes nothing beyond this audit row.
        record.mark_ignored!("livemode mismatch: event=#{event.livemode} app=#{Rails.configuration.stripe_livemode}")
        return head :ok
      end

      ::Billing::ProcessStripeEventJob.perform_async(record.id)
      head :ok
    end

    private

    # Returns nil when the event has already been recorded. The unique index on
    # stripe_event_id IS the idempotency check — there is no lookup-then-insert
    # race to lose.
    def record_event(event)
      # stripe_customer_id is derived by StripeEvent's before_validation hook,
      # so the extraction rule lives in exactly one place.
      StripeEvent.create!(
        stripe_event_id: event.id,
        event_type: event.type,
        payload: event.to_hash.deep_stringify_keys,
        livemode: event.livemode,
        api_version: event.api_version,
        status: :received,
        stripe_created_at: Time.at(event.created)
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      nil
    end

    def verified_event
      Stripe::Webhook.construct_event(
        request.raw_post,
        request.env["HTTP_STRIPE_SIGNATURE"],
        Services::Billing::StripeClient.webhook_secret
      )
    rescue JSON::ParserError, Stripe::SignatureVerificationError => e
      # Never log the payload: it carries customer email, name, address and card
      # last-four. The error class and message are enough to diagnose.
      Rails.logger.warn("[stripe-webhook] rejected: #{e.class}")
      nil
    end
  end
end
