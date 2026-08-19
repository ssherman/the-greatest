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
      # Refuse before verification when there is nothing to verify against. Without
      # this the endpoint would be wide open in an environment missing the secret:
      # any fallback value would be a literal in this public repository, so an
      # attacker could sign a forged event with it and have it accepted, writing
      # StripeEvent rows and enqueuing jobs at will.
      #
      # 503 rather than 200 on purpose — a non-2xx keeps Stripe retrying, so genuine
      # deliveries are not lost during the window before the secret is configured.
      unless Services::Billing::StripeClient.webhook_configured?
        Rails.logger.error("[stripe-webhook] refusing delivery: STRIPE_WEBHOOK_SECRET is not set")
        return head :service_unavailable
      end

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

    # Tries every configured signing secret and returns the first event that
    # verifies. Two endpoints (one per production host) means two secrets, and a
    # delivery is only ever signed with the secret of the endpoint it went to.
    #
    # Note this is also exactly the shape Stripe documents for rotating a
    # secret: run with old and new configured until the rotation completes.
    def verified_event
      last_error = nil

      Services::Billing::StripeClient.webhook_secrets.each do |secret|
        return Stripe::Webhook.construct_event(
          request.raw_post, request.env["HTTP_STRIPE_SIGNATURE"], secret
        )
      rescue JSON::ParserError, Stripe::SignatureVerificationError => e
        # In the pinned stripe gem, construct_event verifies the signature before
        # parsing the body, so a JSON::ParserError here can only happen once a
        # secret has already verified -- trying the rest would just fail earlier,
        # at verify_header, without reaching the parser. Breaking is defensive
        # against a future gem version that reorders this to parse-then-verify.
        last_error = e
        break if e.is_a?(JSON::ParserError)
      end

      # Never log the payload: it carries customer email, name, address and card
      # last-four. The error class alone is enough to diagnose.
      Rails.logger.warn("[stripe-webhook] rejected: #{last_error&.class}")
      nil
    end
  end
end
