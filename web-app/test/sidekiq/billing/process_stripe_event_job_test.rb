# frozen_string_literal: true

require "test_helper"

module Billing
  class ProcessStripeEventJobTest < ActiveSupport::TestCase
    include StripeWebhookHelper

    setup do
      @user = users(:contractor_user)
      @user.update!(stripe_customer_id: "cus_order")
    end

    def event_row(type:, object:, id: "evt_#{SecureRandom.hex(4)}")
      StripeEvent.create!(
        stripe_event_id: id, event_type: type,
        payload: JSON.parse(stripe_event_payload(type: type, object: object, id: id)),
        livemode: false, status: :received, stripe_created_at: Time.current
      )
    end

    def expect_reconcile(customer_id, times: 1)
      Services::Billing::ReconcileCustomer.expects(:call)
        .with(stripe_customer_id: customer_id).times(times)
        .returns(Services::Billing::ReconcileCustomer::Result.new(
          success?: true, data: [], errors: []
        ))
    end

    test "reconciles the customer named on a subscription event" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o1", customer: "cus_order"))
      expect_reconcile("cus_order")

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.processed?
    end

    test "ignores an event with no customer" do
      event = event_row(type: "price.updated", object: {id: "price_x", object: "price"})
      Services::Billing::ReconcileCustomer.expects(:call).never

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.ignored?
    end

    test "does not reprocess an already-processed event" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o2", customer: "cus_order"))
      event.mark_processed!
      Services::Billing::ReconcileCustomer.expects(:call).never

      ProcessStripeEventJob.new.perform(event.id)
    end

    test "marks the event failed and re-raises so Sidekiq retries" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o3", customer: "cus_order"))
      Services::Billing::ReconcileCustomer.expects(:call).raises(StandardError, "boom")

      assert_raises(StandardError) { ProcessStripeEventJob.new.perform(event.id) }

      assert event.reload.failed?
      assert_equal 1, event.attempts
    end

    test "a failed reconcile result marks the event failed without raising" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o4", customer: "cus_order"))
      Services::Billing::ReconcileCustomer.expects(:call)
        .returns(Services::Billing::ReconcileCustomer::Result.new(
          success?: false, data: nil, errors: ["stripe unavailable"]
        ))

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.failed?
      assert_match(/stripe unavailable/, event.error)
    end

    # ---- The design claim ----
    #
    # Every delivery order of the three events that arrive when someone
    # subscribes must produce identical final state. This passes only because
    # the job reads the event for a customer id and nothing else. If anyone
    # reintroduces payload-as-truth, this is the test that should fail.
    test "every permutation of subscribe-time events converges on the same state" do
      subscription = stripe_subscription_object(id: "sub_perm", customer: "cus_order")
      specs = [
        {type: "customer.subscription.created", object: subscription},
        {type: "checkout.session.completed",
         object: {id: "cs_perm", object: "checkout_session", customer: "cus_order",
                  mode: "subscription", subscription: "sub_perm"}},
        {type: "invoice.paid",
         object: {id: "in_perm", object: "invoice", customer: "cus_order",
                  subscription: "sub_perm"}}
      ]

      states = specs.permutation.map do |ordering|
        Membership.delete_all

        ordering.each_with_index do |spec, index|
          event = event_row(type: spec[:type], object: spec[:object],
            id: "evt_perm_#{SecureRandom.hex(6)}_#{index}")

          Stripe::Customer.stubs(:retrieve).returns(
            Stripe::Customer.construct_from({id: "cus_order", object: "customer", metadata: {}})
          )
          Stripe::Subscription.stubs(:list).returns(
            Stripe::ListObject.construct_from({
              object: "list", has_more: false,
              data: [subscription.deep_symbolize_keys]
            })
          )

          ProcessStripeEventJob.new.perform(event.id)
        end

        Membership.order(:stripe_subscription_id).map do |m|
          m.attributes.slice("user_id", "source", "status", "interval",
            "stripe_subscription_id", "stripe_customer_id", "cancel_at_period_end")
        end
      end

      assert_equal 6, states.size, "expected all six permutations"
      assert_equal 1, states.uniq.size,
        "delivery order changed the final state: #{states.uniq.inspect}"
      assert_equal 1, states.first.size
      assert_equal @user.id, states.first.first["user_id"]
    end
  end
end
