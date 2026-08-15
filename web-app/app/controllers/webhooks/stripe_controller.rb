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

    # Stripe posts a JSON body, and wrap_parameters would nest a second copy of it
    # under a "stripe" key -- logging the whole payload twice on the hottest path.
    wrap_parameters false

    def create
      event = verified_event
      return head :bad_request if event.nil?

      record = record_event(event)
      return head :ok if record.nil?

      if event.livemode != Rails.configuration.stripe_livemode
        # The interlock. A sandbox endpoint misconfigured to point at production
        # (or the reverse) writes nothing beyond this audit row.
        record.mark_ignored!("livemode mismatch: event=#{event.livemode} app=#{Rails.configuration.stripe_livemode}") unless record.ignored?
        return head :ok
      end

      # Enqueue for a new row, and ALSO for a redelivery still sitting at received
      # or failed. A duplicate is not proof the event was handled: if the first
      # delivery committed the row and then perform_async blew up (Redis down, say),
      # the row is stranded at `received` and answering 200 here would tell Stripe
      # it was delivered. It would then stop retrying and the event would never be
      # processed. The job is idempotent, so a redundant enqueue costs nothing.
      # Only `processed` and `ignored` mean genuinely finished.
      ::Billing::ProcessStripeEventJob.perform_async(record.id) if record.received? || record.failed?
      head :ok
    end

    private

    # Returns the StripeEvent row for this event — the one just created, or the
    # already-stored one on a redelivery. Returns nil only if the row cannot be
    # found at all, which needs a delete racing this request.
    #
    # Returning the existing row rather than nil is what lets `create` tell a
    # finished redelivery from one whose job never got enqueued.
    #
    # Two rescues, because a duplicate can surface as either exception. StripeEvent
    # validates stripe_event_id for uniqueness, so the ordinary redelivery fails
    # that validation (a SELECT) and raises RecordInvalid. RecordNotUnique still
    # happens when two concurrent deliveries both pass the SELECT before either
    # INSERTs, and the database constraint catches the loser.
    #
    # The `of_kind?` guard is load-bearing: rescuing RecordInvalid broadly would
    # also swallow an event that fails validation for some OTHER reason, returning
    # 200 with nothing persisted. Stripe treats 200 as delivered and never retries,
    # so that event would be lost permanently with no audit row. Anything that is
    # not a taken id must raise, so Stripe retries and the failure is visible.
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
    rescue ActiveRecord::RecordNotUnique
      StripeEvent.find_by(stripe_event_id: event.id)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:stripe_event_id, :taken)
      StripeEvent.find_by(stripe_event_id: event.id)
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
