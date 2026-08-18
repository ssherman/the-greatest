require "test_helper"

module Services
  module Billing
    class BootstrapPlansTest < ActiveSupport::TestCase
      test "refuses to run in livemode and touches nothing" do
        # The production account already sells membership through the legacy books
        # app's products. A second set here would split subscribers across two
        # products with no way to tell afterwards which is which.
        Rails.application.config.stubs(:stripe_livemode).returns(true)
        ::Stripe::Product.expects(:create).never
        ::Stripe::Price.expects(:create).never

        result = BootstrapPlans.call

        refute result.success?
        assert_match(/livemode/i, result.errors.join)
      end

      test "creates products and prices and upserts the three plans in a sandbox" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_m", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_yearly"))
          .returns(stub(id: "price_y", unit_amount: 5000, currency: "usd", lookup_key: "membership_yearly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "donation_custom"))
          .returns(stub(id: "price_d", unit_amount: nil, currency: "usd", lookup_key: "donation_custom"))

        result = BootstrapPlans.call

        assert result.success?
        assert_equal "price_m", ::BillingPlan.find_by(key: "monthly").stripe_price_id
        assert_equal "price_d", ::BillingPlan.find_by(key: "donation").stripe_price_id
      end

      test "the donation price is a custom-amount price with a floor and a preset" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_m", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_yearly"))
          .returns(stub(id: "price_y", unit_amount: 5000, currency: "usd", lookup_key: "membership_yearly"))
        ::Stripe::Price.expects(:create).with(
          has_entry(custom_unit_amount: {enabled: true, minimum: 100, preset: 2500})
        ).returns(stub(id: "price_d", unit_amount: nil, currency: "usd", lookup_key: "donation_custom"))

        assert BootstrapPlans.call.success?
      end

      test "running twice does not duplicate plan rows" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        # Distinct ids per lookup key, same as the other sandbox tests: a
        # single shared stub id would collide with stripe_price_id's
        # uniqueness validation on the SECOND plan upserted within one run,
        # which has nothing to do with what "running twice" is meant to prove.
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_m", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_yearly"))
          .returns(stub(id: "price_y", unit_amount: 5000, currency: "usd", lookup_key: "membership_yearly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "donation_custom"))
          .returns(stub(id: "price_d", unit_amount: nil, currency: "usd", lookup_key: "donation_custom"))

        assert_no_difference "BillingPlan.where(key: %w[monthly yearly donation]).count" do
          assert BootstrapPlans.call.success?
          assert BootstrapPlans.call.success?
        end
      end
    end
  end
end
