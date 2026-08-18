require "test_helper"

module Services
  module Billing
    class LabelPriceTest < ActiveSupport::TestCase
      test "writes the lookup key and reports the amount either side of the change" do
        # The amount is reported so "this is a label-only change" is something the
        # operator can SEE, not something the plan asserts.
        ::Stripe::Price.expects(:retrieve).with("price_live_x")
          .returns(stub(id: "price_live_x", lookup_key: nil, unit_amount: 500, currency: "usd", active: true))
        ::Stripe::Price.expects(:update).with("price_live_x", has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_live_x", lookup_key: "membership_monthly", unit_amount: 500, currency: "usd", active: true))

        result = LabelPrice.call(price_id: "price_live_x", lookup_key: "membership_monthly")

        assert result.success?
        assert_nil result.data[:before]
        assert_equal "membership_monthly", result.data[:after]
        assert_equal 500, result.data[:unit_amount]
      end

      test "a blank price id fails without calling Stripe" do
        ::Stripe::Price.expects(:retrieve).never

        refute LabelPrice.call(price_id: "", lookup_key: "membership_monthly").success?
      end

      test "a blank lookup key fails without calling Stripe" do
        ::Stripe::Price.expects(:retrieve).never

        refute LabelPrice.call(price_id: "price_live_x", lookup_key: "").success?
      end

      test "refuses when the key is already on a different price" do
        # transfer_lookup_key is deliberately NOT passed, so Stripe rejects this.
        # Silently moving a lookup key off another price is how a production
        # checkout starts pointing at the wrong amount.
        ::Stripe::Price.stubs(:retrieve).returns(stub(id: "price_live_x", lookup_key: nil, unit_amount: 500, currency: "usd", active: true))
        ::Stripe::Price.stubs(:update).raises(::Stripe::InvalidRequestError.new("lookup_key already in use", "lookup_key"))

        refute LabelPrice.call(price_id: "price_live_x", lookup_key: "membership_monthly").success?
      end
    end
  end
end
