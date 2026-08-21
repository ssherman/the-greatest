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
      # the same object shape the real API returns. id and customer default so a
      # test that only cares about one attribute (e.g. metadata) doesn't have to
      # restate the rest -- customer defaults to the fixture user's
      # stripe_customer_id set up in `setup`, so resolving it never falls through
      # to a real Stripe::Customer.retrieve call.
      def stripe_subscription(id: "sub_#{SecureRandom.hex(6)}", customer: "cus_reconcile", **opts)
        Stripe::Subscription.construct_from(
          stripe_subscription_object(id: id, customer: customer, **opts).deep_symbolize_keys
        )
      end

      def stub_stripe_list(subscriptions)
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_reconcile", status: "all"))
          .returns(Stripe::ListObject.construct_from(
            {object: "list", data: subscriptions.map(&:to_hash), has_more: false}
          ))
      end

      # Runs the reconcile for one subscription and re-queries the resulting row
      # from the database, rather than trusting whatever ReconcileCustomer.call
      # returns -- a later task changes that return shape, and re-querying keeps
      # these tests indifferent to it.
      def reconcile_and_fetch(subscription)
        stub_stripe_list([subscription])
        ReconcileCustomer.call(stripe_customer_id: subscription.customer)
        ::Membership.find_by(stripe_subscription_id: subscription.id)
      end

      # Runs the reconcile for one subscription and returns the resulting
      # MembershipTransition. Unlike reconcile_and_fetch, this cannot be
      # re-derived from the database -- previous_status only ever exists for
      # the duration of one reconcile -- so it reads the service's own return
      # value instead.
      def reconcile_and_transition(subscription)
        stub_stripe_list([subscription])
        result = ReconcileCustomer.call(stripe_customer_id: subscription.customer)
        result.data.first
      end

      test "creates a membership from a stripe subscription" do
        stub_stripe_list([stripe_subscription(id: "sub_r1", customer: "cus_reconcile")])

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert result.success?
        membership = ::Membership.find_by!(stripe_subscription_id: "sub_r1")
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

        membership = ::Membership.find_by!(stripe_subscription_id: "sub_r2")
        assert_in_delta period_end.to_i, membership.current_period_end.to_i, 1
      end

      test "maps a yearly interval" do
        stub_stripe_list([stripe_subscription(id: "sub_r3", customer: "cus_reconcile",
          interval: "year")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert ::Membership.find_by!(stripe_subscription_id: "sub_r3").interval_yearly?
      end

      test "updates an existing membership rather than duplicating it" do
        ::Membership.create!(user: @user, source: :stripe, status: :past_due,
          interval: :monthly, stripe_subscription_id: "sub_r4",
          stripe_customer_id: "cus_reconcile")
        stub_stripe_list([stripe_subscription(id: "sub_r4", customer: "cus_reconcile",
          status: "active")])

        assert_no_difference "::Membership.count" do
          ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")
        end

        assert ::Membership.find_by!(stripe_subscription_id: "sub_r4").active?
      end

      test "never modifies a comped membership" do
        comped = memberships(:editor_user_comped)
        original = comped.attributes.slice("status", "current_period_end", "note")
        stub_stripe_list([])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert_equal original, comped.reload.attributes.slice("status", "current_period_end", "note")
      end

      # The guard `return membership if membership.persisted? && !membership.stripe?`
      # is what makes a comped membership safe from webhooks. Membership's
      # `absence: true, unless: :source_stripe?` validation blocks a comped row
      # from picking up a stripe_subscription_id through the normal AR write path,
      # but it is a validation, not a database constraint: it does not apply to
      # update_column, insert_all, or save(validate: false), and it does not
      # retroactively clean up rows written before the validation shipped (127 of
      # them in production). So the collision this test sets up is still reachable
      # in practice -- the setup below bypasses validation deliberately, to
      # reproduce that legacy-shaped row, not because the guard is dead code. The
      # existing comped test passes by non-interaction (no id to collide), never
      # executing the guard at all.
      test "does not modify a persisted non-stripe row whose id collides with an incoming subscription" do
        guarded = ::Membership.new(user: @user, source: :comped, status: :active,
          stripe_subscription_id: "sub_guard", stripe_customer_id: "cus_reconcile",
          note: "should never be touched")
        guarded.save!(validate: false)
        stub_stripe_list([stripe_subscription(id: "sub_guard", customer: "cus_reconcile",
          status: "canceled")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        guarded.reload
        assert guarded.source_comped?
        assert guarded.active?, "reconcile overwrote a comped membership's status"
        assert_equal "should never be touched", guarded.note
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

        membership = ::Membership.find_by!(stripe_subscription_id: "sub_orphan")
        assert_nil membership.user
        assert_equal "cus_unknown", membership.stripe_customer_id
      end

      # A Stripe subscription cannot change customer, so a link established by any
      # other path must survive. The nightly sweep runs this over every subscription
      # in the account, so an unconditional `user: user` would detach it within a day.
      test "preserves an existing user attachment when the customer cannot be resolved" do
        ::Membership.create!(user: @user, source: :stripe, status: :active, interval: :monthly,
          stripe_subscription_id: "sub_attached", stripe_customer_id: "cus_unknown_owner")
        Stripe::Customer.stubs(:retrieve).returns(
          Stripe::Customer.construct_from({id: "cus_unknown_owner", object: "customer", metadata: {}})
        )
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_unknown_owner", status: "all"))
          .returns(Stripe::ListObject.construct_from({
            object: "list", has_more: false,
            data: [stripe_subscription(id: "sub_attached", customer: "cus_unknown_owner").to_hash]
          }))

        ReconcileCustomer.call(stripe_customer_id: "cus_unknown_owner")

        assert_equal @user, ::Membership.find_by!(stripe_subscription_id: "sub_attached").user
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

        assert_equal @user, ::Membership.find_by!(stripe_subscription_id: "sub_meta").user
      end

      test "returns a failure result when Stripe errors" do
        Stripe::Subscription.expects(:list).raises(Stripe::APIError.new("upstream down"))

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        refute result.success?
        assert_match(/upstream down/, result.errors.join)
      end

      test "a transient Stripe error while resolving the user fails rather than orphaning the membership" do
        @user.update!(stripe_customer_id: nil)
        # No stub_stripe_list here: resolve_user raises before `subscriptions` is
        # ever called, so a list stub would be an unsatisfied Mocha expectation.
        Stripe::Customer.expects(:retrieve).raises(Stripe::RateLimitError.new("slow down"))

        result = nil
        assert_no_difference "::Membership.count" do
          result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")
        end

        refute result.success?
      end

      # Pins the OTHER direction of the narrowed rescue. A genuinely missing customer
      # raises InvalidRequestError, which must still be swallowed so the subscription
      # lands as an unattached membership -- that is how legacy- and dashboard-created
      # subscriptions get recorded. The pre-existing unattached test stubs a successful
      # return with empty metadata, so it never exercises this rescue at all.
      test "a missing Stripe customer still yields an unattached membership" do
        @user.update!(stripe_customer_id: nil)
        Stripe::Customer.expects(:retrieve).raises(Stripe::InvalidRequestError.new("No such customer", "customer"))
        stub_stripe_list([stripe_subscription(id: "sub_missing_customer", customer: "cus_reconcile")])

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert result.success?
        membership = ::Membership.find_by!(stripe_subscription_id: "sub_missing_customer")
        assert_nil membership.user
      end

      # THE GAP. origin_domain is stamped into subscription metadata at checkout,
      # but upsert never read it back, so every membership row had origin_domain
      # nil. That breaks two things at once: MailBranding.for(nil) falls back to
      # books, so a music subscriber gets books-branded mail; and with no value
      # there is no way to tell this app's memberships from legacy's, which is the
      # ownership signal the email gate depends on.
      test "writes origin_domain from the subscription's Stripe metadata" do
        subscription = stripe_subscription(metadata: {"origin_domain" => "music"})

        membership = reconcile_and_fetch(subscription)

        assert_equal "music", membership.origin_domain
      end

      # Legacy sells through Stripe Payment Links and sets no metadata at all.
      test "leaves origin_domain nil for a subscription with no metadata" do
        subscription = stripe_subscription(metadata: {})

        membership = reconcile_and_fetch(subscription)

        assert_nil membership.origin_domain
      end

      # The nightly sweep re-reconciles every subscription on the account. Stripe
      # is the source of truth, so the assignment must be unconditional: if
      # origin_domain is absent on a later read, it must be cleared here too, not
      # stuck at whatever an earlier reconcile saw. A sticky `|| membership.
      # origin_domain` (the natural analogy to the `user: user || membership.user`
      # line above) would silently keep emailing about a membership whose
      # ownership signal Stripe no longer reports.
      test "clears origin_domain when it disappears from the subscription's Stripe metadata" do
        subscription = stripe_subscription(id: "sub_origin_clears", metadata: {"origin_domain" => "games"})
        reconcile_and_fetch(subscription)

        subscription = stripe_subscription(id: "sub_origin_clears", metadata: {})
        membership = reconcile_and_fetch(subscription)

        assert_nil membership.origin_domain
      end

      test "reports a brand-new active membership as having become active" do
        subscription = stripe_subscription(status: "active")

        transition = reconcile_and_transition(subscription)

        assert_nil transition.previous_status
        assert transition.became_active?
        assert_not transition.became_canceled?
      end

      # The nightly sweep re-reconciles everything. An unchanged active membership
      # must NOT look like a new activation, or every member gets a welcome email
      # every night.
      test "an unchanged active membership has not become active" do
        subscription = stripe_subscription(status: "active")
        reconcile_and_transition(subscription)

        transition = reconcile_and_transition(subscription)

        assert_equal "active", transition.previous_status
        assert_not transition.became_active?
        assert_not transition.status_changed?
      end

      test "reports the move from active to canceled as having become canceled" do
        subscription = stripe_subscription(status: "active")
        reconcile_and_transition(subscription)

        transition = reconcile_and_transition(stripe_subscription(id: subscription.id, status: "canceled"))

        assert_equal "active", transition.previous_status
        assert transition.became_canceled?
        assert transition.status_changed?
      end

      # trialing -> active is a real transition but not a new membership. The
      # welcome email already went out when the trial started; sending a second on
      # conversion would be a duplicate.
      test "trialing counts as active, so converting a trial is not a new activation" do
        subscription = stripe_subscription(status: "trialing")
        reconcile_and_transition(subscription)

        transition = reconcile_and_transition(stripe_subscription(id: subscription.id, status: "active"))

        assert_not transition.became_active?
      end

      # The comped-row guard in `upsert` used to return a bare Membership on this
      # path, while every other path returned a MembershipTransition -- a
      # heterogeneous return type that would raise NoMethodError the moment a
      # caller (the welcome-email dispatcher) calls #became_active? on whatever
      # this returns. A real comped fixture validates absence of
      # stripe_subscription_id, so update_column (which skips validations) is
      # used to reproduce the legacy-shaped collision, exactly as the
      # hand-built guarded row above does for the same reason.
      test "a comped collision returns a no-op transition, not a bare Membership" do
        comped = memberships(:editor_user_comped)
        comped.update_column(:stripe_subscription_id, "sub_comped_collision")
        original = comped.attributes.slice("status", "current_period_end", "note")

        transition = reconcile_and_transition(
          stripe_subscription(id: "sub_comped_collision", status: "canceled")
        )

        assert_instance_of MembershipTransition, transition
        assert_not transition.status_changed?
        assert_not transition.became_active?
        assert_not transition.became_canceled?
        assert_equal original, comped.reload.attributes.slice("status", "current_period_end", "note")
      end

      # The account-wide migration produced already-cancelled memberships in
      # bulk. Without the `!previous_status.nil?` clause in became_canceled?,
      # every one of those brand-new-but-already-cancelled rows would look
      # like a fresh cancellation and get emailed a cancellation notice for a
      # subscription they cancelled long ago. previous_status is nil here
      # specifically because there is no prior membership row -- a random,
      # never-seen-before subscription id (the stripe_subscription helper's
      # default) is deliberate, not incidental: it guarantees no row exists to
      # find.
      test "a membership that arrives already cancelled is not a cancellation event" do
        subscription = stripe_subscription(status: "canceled")

        transition = reconcile_and_transition(subscription)

        assert_nil transition.previous_status
        assert_not transition.became_canceled?
      end
    end
  end
end
