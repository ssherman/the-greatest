require "test_helper"

module Services
  module Billing
    class CreateCheckoutSessionTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @monthly = billing_plans(:monthly)
        @donation = billing_plans(:donation)
        @urls = {success_url: "https://example.test/membership/thanks", cancel_url: "https://example.test/membership"}
      end

      test "returns the session url" do
        ::Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_test_123"))

        result = CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)

        assert result.success?
        assert_equal "https://checkout.stripe.com/c/pay/cs_test_123", result.data
      end

      test "every session carries top-level origin_app metadata" do
        # Load-bearing for legacy coexistence: the legacy books app reads this to
        # decide "not mine, skip". Without it a donation relies on legacy's
        # payment-link backstop alone, and the legacy log line stops saying why.
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_app: "the-greatest"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "a donation session also carries top-level origin_app metadata" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_app: "the-greatest"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :music, **@urls)
      end

      test "a subscription session tags the subscription itself" do
        # A subscription outlives its checkout session, and legacy's guard reads
        # the subscription's metadata on later customer.subscription.* events.
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entries(
            mode: "subscription",
            subscription_data: has_entry(metadata: has_entries(app_user_id: @user.id, origin_app: "the-greatest"))
          )
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "a donation session is payment mode with a donate button" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entries(mode: "payment", submit_type: "donate")
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls)
      end

      test "the price comes from the plan record, never from the caller" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(line_items: [{price: @monthly.stripe_price_id, quantity: 1}])
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "an anonymous donation creates no customer" do
        ::Stripe::Checkout::Session.expects(:create).with { |params| !params.key?(:customer) }
          .returns(stub(url: "https://checkout.stripe.com/x"))

        assert CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls).success?
      end

      test "the origin domain rides along so a receipt can be branded" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_domain: "games"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :games, **@urls)
      end

      test "a subscription plan without a signed-in user fails before calling Stripe" do
        ::Stripe::Checkout::Session.expects(:create).never

        refute CreateCheckoutSession.call(plan: @monthly, domain: :books, **@urls).success?
      end

      test "a Stripe failure is a failed Result, not an exception" do
        ::Stripe::Checkout::Session.expects(:create).raises(::Stripe::InvalidRequestError.new("no such price", "price"))

        refute CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls).success?
      end

      test "the service never calls the PaymentLink API" do
        # Legacy's structural guard is "this session carries no payment_link, so
        # it is not mine". A session created through a payment link would carry
        # one, the guard would never fire, and the donation defect it closes
        # would silently re-open with nothing to catch it.
        ::Stripe::PaymentLink.expects(:create).never
        ::Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls)
      end
    end
  end
end
