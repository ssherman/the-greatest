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
