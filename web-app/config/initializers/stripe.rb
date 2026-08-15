# frozen_string_literal: true

# Configure Stripe at boot so the live-key guard fires before any request can.
# Tolerated in local environments so a developer without Stripe credentials can
# still boot the app; production has no such escape hatch.
Rails.application.config.to_prepare do
  Services::Billing::StripeClient.configure!
  Rails.application.config.stripe_livemode = Services::Billing::StripeClient.livemode?
rescue Services::Billing::StripeClient::ConfigurationError => e
  raise unless Rails.env.local?
  Rails.logger.warn("[stripe] #{e.message}")
end
