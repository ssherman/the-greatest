require "test_helper"

module Services
  module Billing
    class CreateDonationPriceTest < ActiveSupport::TestCase
      test "creates a product and a custom-amount price with the default name" do
        ::Stripe::Product.expects(:create).with(name: "Donation to The Greatest")
          .returns(stub(id: "prod_donation"))
        ::Stripe::Price.expects(:create).with(
          product: "prod_donation",
          currency: "usd",
          custom_unit_amount: {enabled: true, minimum: 100, preset: 2500},
          lookup_key: "donation_custom",
          nickname: "Custom donation"
        ).returns(stub(id: "price_donation", lookup_key: "donation_custom", unit_amount: nil, currency: "usd"))

        result = CreateDonationPrice.call

        assert result.success?
        assert_equal "price_donation", result.data.id
        assert_equal "donation_custom", result.data.lookup_key
      end

      test "accepts a custom product name" do
        ::Stripe::Product.expects(:create).with(name: "Custom Fundraiser")
          .returns(stub(id: "prod_custom"))
        ::Stripe::Price.stubs(:create)
          .returns(stub(id: "price_custom", lookup_key: "donation_custom", unit_amount: nil, currency: "usd"))

        result = CreateDonationPrice.call(product_name: "Custom Fundraiser")

        assert result.success?
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
