# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class ReconcileAllCustomersTest < ActiveSupport::TestCase
      def subscription_list(customer_ids)
        Stripe::ListObject.construct_from({
          object: "list", has_more: false,
          data: customer_ids.each_with_index.map do |customer, index|
            {id: "sub_all_#{index}", object: "subscription", customer: customer}
          end
        })
      end

      def ok_result
        ReconcileCustomer::Result.new(success?: true, data: [], errors: [])
      end

      test "reconciles each distinct customer exactly once" do
        Stripe::Subscription.expects(:list).returns(
          subscription_list(%w[cus_a cus_b cus_a])
        )
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a").once.returns(ok_result)
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b").once.returns(ok_result)

        result = ReconcileAllCustomers.call

        assert result.success?
        assert_equal 2, result.data[:customers]
        assert_equal 2, result.data[:reconciled]
        assert_empty result.data[:failed]
      end

      test "keeps going when one customer fails and reports it" do
        Stripe::Subscription.expects(:list).returns(subscription_list(%w[cus_a cus_b]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a")
          .returns(ReconcileCustomer::Result.new(success?: false, data: nil, errors: ["nope"]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b").returns(ok_result)

        result = ReconcileAllCustomers.call

        assert result.success?, "one failing customer must not fail the whole sweep"
        assert_equal 1, result.data[:reconciled]
        assert_equal ["cus_a"], result.data[:failed]
      end

      # The systemic case: nothing reconciled at all, which a Sidekiq retry can
      # actually fix. Contrast with the test above -- failing whenever ANY customer
      # failed would let one permanently broken subscription make every nightly sweep
      # raise and exhaust its retries, which is the opposite of what the per-customer
      # rescue exists to prevent.
      test "fails when there were customers and none reconciled" do
        Stripe::Subscription.expects(:list).returns(subscription_list(%w[cus_a cus_b]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a")
          .returns(ReconcileCustomer::Result.new(success?: false, data: nil, errors: ["stripe down"]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b")
          .returns(ReconcileCustomer::Result.new(success?: false, data: nil, errors: ["stripe down"]))

        result = ReconcileAllCustomers.call

        refute result.success?, "a sweep that reconciled nothing must fail so Sidekiq retries"
        assert_equal 0, result.data[:reconciled]
        assert_equal %w[cus_a cus_b], result.data[:failed]
        assert_match(/0 of 2/, result.errors.join)
      end

      test "an account with no subscriptions succeeds rather than failing" do
        Stripe::Subscription.expects(:list).returns(subscription_list([]))
        ReconcileCustomer.expects(:call).never

        result = ReconcileAllCustomers.call

        assert result.success?, "an empty account is not a failed sweep"
        assert_equal 0, result.data[:customers]
      end

      # ReconcileCustomer only rescues Stripe::StripeError. A subscription carrying a
      # status Stripe added after Membership's enum was written raises ArgumentError,
      # which would otherwise abort the sweep for every remaining customer.
      test "a customer raising a non-Stripe error is recorded and the sweep continues" do
        Stripe::Subscription.expects(:list).returns(subscription_list(%w[cus_a cus_b]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a")
          .raises(ArgumentError, "'brand_new_status' is not a valid status")
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b").returns(ok_result)

        result = ReconcileAllCustomers.call

        assert result.success?
        assert_equal 1, result.data[:reconciled]
        assert_equal ["cus_a"], result.data[:failed]
      end

      test "returns a failure result when the account listing itself fails" do
        Stripe::Subscription.expects(:list).raises(Stripe::APIError.new("account listing down"))

        result = ReconcileAllCustomers.call

        refute result.success?
        assert_match(/account listing down/, result.errors.join)
      end
    end
  end
end
