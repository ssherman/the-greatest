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

      head :ok
    end

    private

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
