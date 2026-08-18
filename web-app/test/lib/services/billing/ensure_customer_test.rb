require "test_helper"

module Services
  module Billing
    class EnsureCustomerTest < ActiveSupport::TestCase
      test "returns the existing customer id without calling Stripe" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: "cus_already_there")
        ::Stripe::Customer.expects(:create).never

        result = EnsureCustomer.call(user: user)

        assert result.success?
        assert_equal "cus_already_there", result.data
      end

      test "creates a customer and persists the id on the user" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).returns(stub(id: "cus_new"))

        result = EnsureCustomer.call(user: user)

        assert result.success?
        assert_equal "cus_new", result.data
        assert_equal "cus_new", user.reload.stripe_customer_id
      end

      test "tags the customer so the reconciler can attach it without our database" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).with(
          has_entry(metadata: has_entries(app_user_id: user.id, origin_app: "the-greatest")),
          has_entry(idempotency_key: "customer-#{user.id}")
        ).returns(stub(id: "cus_new"))

        assert EnsureCustomer.call(user: user).success?
      end

      test "a Stripe failure is a failed Result, not an exception" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).raises(::Stripe::APIConnectionError.new("boom"))

        result = EnsureCustomer.call(user: user)

        refute result.success?
        assert_nil user.reload.stripe_customer_id
      end

      test "a nil user fails without touching Stripe" do
        ::Stripe::Customer.expects(:create).never

        refute EnsureCustomer.call(user: nil).success?
      end
    end
  end
end
