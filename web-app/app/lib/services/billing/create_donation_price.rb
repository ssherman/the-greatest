# frozen_string_literal: true

module Services
  module Billing
    # One custom-amount price, replacing the legacy app's eight fixed donation
    # prices and eight payment links.
    #
    # Stripe's documented limits on a custom_unit_amount price -- one line item,
    # quantity 1, no promotion codes, not recurring -- are all fine for a
    # donation. Safe to run against the live account: it creates a new product
    # and price and touches nothing existing.
    class CreateDonationPrice
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      LOOKUP_KEY = "donation_custom"
      MINIMUM_CENTS = 100
      PRESET_CENTS = 2500

      def self.call(product_name: "Donation to The Greatest") = new(product_name: product_name).call

      def initialize(product_name:)
        @product_name = product_name
      end

      def call
        # metadata[origin_app] on both: this is a SHARED Stripe account, and
        # without it the product/price this creates would be an unlabelled
        # object in an account the legacy books app also writes to. It costs
        # nothing else here -- nothing reads this metadata back -- but it is
        # the same tag every session and customer this app creates carries
        # (see StripeClient::ORIGIN_APP), so an object with no tag at all would
        # be the odd one out in the dashboard, not the norm.
        product = ::Stripe::Product.create(
          name: @product_name,
          metadata: {origin_app: StripeClient::ORIGIN_APP}
        )
        price = ::Stripe::Price.create(
          product: product.id,
          currency: "usd",
          custom_unit_amount: {enabled: true, minimum: MINIMUM_CENTS, preset: PRESET_CENTS},
          lookup_key: LOOKUP_KEY,
          nickname: "Custom donation",
          metadata: {origin_app: StripeClient::ORIGIN_APP}
        )

        Result.new(success?: true, data: price, errors: [])
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] donation price creation failed: #{e.class}")
        Result.new(success?: false, data: nil, errors: [e.message])
      end
    end
  end
end
