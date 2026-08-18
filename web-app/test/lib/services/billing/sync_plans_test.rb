require "test_helper"

module Services
  module Billing
    class SyncPlansTest < ActiveSupport::TestCase
      def price_stub(id:, unit_amount:, interval: nil)
        stub(id: id, unit_amount: unit_amount, currency: "usd",
          recurring: interval && stub(interval: interval))
      end

      test "resolves each plan's price id from its lookup key" do
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_monthly"]))
          .returns(stub(data: [price_stub(id: "price_resolved_monthly", unit_amount: 600, interval: "month")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_yearly"]))
          .returns(stub(data: [price_stub(id: "price_resolved_yearly", unit_amount: 5000, interval: "year")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["donation_custom"]))
          .returns(stub(data: [price_stub(id: "price_resolved_donation", unit_amount: nil)]))

        result = SyncPlans.call

        assert result.success?
        assert_equal "price_resolved_monthly", billing_plans(:monthly).reload.stripe_price_id
        assert_equal 600, billing_plans(:monthly).reload.amount_cents
        assert_equal "yearly", billing_plans(:yearly).reload.interval
      end

      test "a custom-amount donation price resolves with no amount and no interval" do
        # unit_amount is nil for a custom_unit_amount price, and that is correct:
        # the amount is whatever the donor types. Writing 0 here would render "$0"
        # on the membership page.
        ::Stripe::Price.stubs(:list).returns(stub(data: [price_stub(id: "price_x", unit_amount: nil)]))

        SyncPlans.call

        donation = billing_plans(:donation).reload
        assert_nil donation.amount_cents
        assert_nil donation.interval
      end

      test "an unresolvable lookup key fails the whole run and names it" do
        ::Stripe::Price.stubs(:list).returns(stub(data: []))

        result = SyncPlans.call

        refute result.success?
        assert_includes result.data[:failures], "membership_monthly"
      end

      test "an unresolvable key leaves the existing price id alone" do
        # Better a stale id than a nil one: a nil stripe_price_id violates the
        # model's presence validation and would raise on the next save.
        ::Stripe::Price.stubs(:list).returns(stub(data: []))
        before = billing_plans(:monthly).stripe_price_id

        SyncPlans.call

        assert_equal before, billing_plans(:monthly).reload.stripe_price_id
      end

      test "plans with no lookup key are skipped rather than failing the run" do
        billing_plans(:monthly).update!(stripe_lookup_key: nil)
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_yearly"]))
          .returns(stub(data: [price_stub(id: "price_y", unit_amount: 5000, interval: "year")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["donation_custom"]))
          .returns(stub(data: [price_stub(id: "price_d", unit_amount: nil)]))

        result = SyncPlans.call

        assert result.success?
        refute_includes result.data[:resolved], "membership_monthly"
      end

      test "a Stripe failure is a failed Result, not an exception" do
        ::Stripe::Price.stubs(:list).raises(::Stripe::APIConnectionError.new("down"))

        refute SyncPlans.call.success?
      end
    end
  end
end
