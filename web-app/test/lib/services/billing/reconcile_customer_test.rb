# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class ReconcileCustomerTest < ActiveSupport::TestCase
      include StripeWebhookHelper

      setup do
        @user = users(:contractor_user)
        @user.update!(stripe_customer_id: "cus_reconcile")
      end

      # Builds a Stripe::Subscription from the helper's hash so the service sees
      # the same object shape the real API returns.
      def stripe_subscription(**opts)
        Stripe::Subscription.construct_from(
          stripe_subscription_object(**opts).deep_symbolize_keys
        )
      end

      def stub_stripe_list(subscriptions)
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_reconcile", status: "all"))
          .returns(Stripe::ListObject.construct_from(
            {object: "list", data: subscriptions.map(&:to_hash), has_more: false}
          ))
      end

      test "creates a membership from a stripe subscription" do
        stub_stripe_list([stripe_subscription(id: "sub_r1", customer: "cus_reconcile")])

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert result.success?
        membership = Membership.find_by!(stripe_subscription_id: "sub_r1")
        assert_equal @user, membership.user
        assert membership.source_stripe?
        assert membership.active?
        assert membership.interval_monthly?
        assert_equal "cus_reconcile", membership.stripe_customer_id
        assert_not_nil membership.stripe_synced_at
      end

      test "reads current_period_end from the subscription item, not the subscription" do
        period_end = 45.days.from_now
        stub_stripe_list([stripe_subscription(id: "sub_r2", customer: "cus_reconcile",
          period_end: period_end)])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        membership = Membership.find_by!(stripe_subscription_id: "sub_r2")
        assert_in_delta period_end.to_i, membership.current_period_end.to_i, 1
      end

      test "maps a yearly interval" do
        stub_stripe_list([stripe_subscription(id: "sub_r3", customer: "cus_reconcile",
          interval: "year")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert Membership.find_by!(stripe_subscription_id: "sub_r3").interval_yearly?
      end

      test "updates an existing membership rather than duplicating it" do
        Membership.create!(user: @user, source: :stripe, status: :past_due,
          interval: :monthly, stripe_subscription_id: "sub_r4",
          stripe_customer_id: "cus_reconcile")
        stub_stripe_list([stripe_subscription(id: "sub_r4", customer: "cus_reconcile",
          status: "active")])

        assert_no_difference "Membership.count" do
          ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")
        end

        assert Membership.find_by!(stripe_subscription_id: "sub_r4").active?
      end

      test "never modifies a comped membership" do
        comped = memberships(:editor_user_comped)
        original = comped.attributes.slice("status", "current_period_end", "note")
        stub_stripe_list([])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert_equal original, comped.reload.attributes.slice("status", "current_period_end", "note")
      end

      test "stores an unattached membership when no user matches the customer" do
        # No user has stripe_customer_id "cus_unknown", and the Stripe customer
        # carries no app_user_id metadata, so both resolution paths miss.
        Stripe::Customer.stubs(:retrieve).returns(
          Stripe::Customer.construct_from({id: "cus_unknown", object: "customer", metadata: {}})
        )
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_unknown", status: "all"))
          .returns(Stripe::ListObject.construct_from({
            object: "list", has_more: false,
            data: [stripe_subscription(id: "sub_orphan", customer: "cus_unknown").to_hash]
          }))

        ReconcileCustomer.call(stripe_customer_id: "cus_unknown")

        membership = Membership.find_by!(stripe_subscription_id: "sub_orphan")
        assert_nil membership.user
        assert_equal "cus_unknown", membership.stripe_customer_id
      end

      test "recovers the user from customer metadata when the column is unset" do
        @user.update!(stripe_customer_id: nil)
        Stripe::Customer.stubs(:retrieve).returns(
          Stripe::Customer.construct_from({
            id: "cus_reconcile", object: "customer",
            metadata: {app_user_id: @user.id.to_s}
          })
        )
        stub_stripe_list([stripe_subscription(id: "sub_meta", customer: "cus_reconcile")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert_equal @user, Membership.find_by!(stripe_subscription_id: "sub_meta").user
      end

      test "returns a failure result when Stripe errors" do
        Stripe::Subscription.expects(:list).raises(Stripe::APIError.new("upstream down"))

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        refute result.success?
        assert_match(/upstream down/, result.errors.join)
      end
    end
  end
end
