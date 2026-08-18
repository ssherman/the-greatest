require "test_helper"

module Services
  module Billing
    class CreateDonationPriceTest < ActiveSupport::TestCase
      test "creates a product and a custom-amount price with the default name" do
        ::Stripe::Product.expects(:create).with(
          name: "Donation to The Greatest",
          metadata: {origin_app: ::Services::Billing::StripeClient::ORIGIN_APP}
        ).returns(stub(id: "prod_donation"))
        ::Stripe::Price.expects(:create).with(
          product: "prod_donation",
          currency: "usd",
          custom_unit_amount: {enabled: true, minimum: 100, preset: 2500},
          lookup_key: "donation_custom",
          nickname: "Custom donation",
          metadata: {origin_app: ::Services::Billing::StripeClient::ORIGIN_APP}
        ).returns(stub(id: "price_donation", lookup_key: "donation_custom", unit_amount: nil, currency: "usd"))

        result = CreateDonationPrice.call

        assert result.success?
        assert_equal "price_donation", result.data.id
        assert_equal "donation_custom", result.data.lookup_key
      end

      test "accepts a custom product name" do
        ::Stripe::Product.expects(:create).with(
          name: "Custom Fundraiser",
          metadata: {origin_app: ::Services::Billing::StripeClient::ORIGIN_APP}
        ).returns(stub(id: "prod_custom"))
        ::Stripe::Price.stubs(:create)
          .returns(stub(id: "price_custom", lookup_key: "donation_custom", unit_amount: nil, currency: "usd"))

        result = CreateDonationPrice.call(product_name: "Custom Fundraiser")

        assert result.success?
      end

      # This is a SHARED Stripe account (see the class comment) -- the product
      # and price this creates need to be identifiable as this app's own, the
      # same as every checkout session, subscription and customer this app
      # writes there.
      test "tags both the product and the price with origin_app" do
        ::Stripe::Product.expects(:create)
          .with(has_entry(metadata: {origin_app: ::Services::Billing::StripeClient::ORIGIN_APP}))
          .returns(stub(id: "prod_donation"))
        ::Stripe::Price.expects(:create)
          .with(has_entry(metadata: {origin_app: ::Services::Billing::StripeClient::ORIGIN_APP}))
          .returns(stub(id: "price_donation", lookup_key: "donation_custom", unit_amount: nil, currency: "usd"))

        assert CreateDonationPrice.call.success?
      end

      test "a Stripe failure is a failed Result, not an exception" do
        ::Stripe::Product.stubs(:create).raises(::Stripe::APIConnectionError.new("down"))

        result = CreateDonationPrice.call

        refute result.success?
        assert_equal ["down"], result.errors
      end
    end
  end
end
