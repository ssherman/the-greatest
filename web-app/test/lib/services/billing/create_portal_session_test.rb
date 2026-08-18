require "test_helper"

module Services
  module Billing
    class CreatePortalSessionTest < ActiveSupport::TestCase
      test "returns the portal url" do
        ::Stripe::BillingPortal::Session.expects(:create).with(
          has_entries(customer: "cus_x", return_url: "https://example.test/members")
        ).returns(stub(url: "https://billing.stripe.com/p/session/live_abc"))

        result = CreatePortalSession.call(customer_id: "cus_x", return_url: "https://example.test/members")

        assert result.success?
        assert_equal "https://billing.stripe.com/p/session/live_abc", result.data
      end

      test "a blank customer id fails without calling Stripe" do
        ::Stripe::BillingPortal::Session.expects(:create).never

        refute CreatePortalSession.call(customer_id: "", return_url: "https://example.test/members").success?
      end

      test "a Stripe failure is a failed Result" do
        # The most likely one in practice: no portal configuration has been
        # activated for this account in this livemode yet.
        ::Stripe::BillingPortal::Session.expects(:create)
          .raises(::Stripe::InvalidRequestError.new("No configuration provided", "configuration"))

        refute CreatePortalSession.call(customer_id: "cus_x", return_url: "https://example.test/members").success?
      end
    end
  end
end
