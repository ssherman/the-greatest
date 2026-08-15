# frozen_string_literal: true

module Services
  module Billing
    # Makes local Membership rows match what Stripe says about one customer,
    # right now.
    #
    # This is the whole design. Webhook events are never read for state — only
    # for a customer id — so delivery order cannot affect the outcome. A late
    # customer.subscription.created triggers a redundant reconcile that
    # converges on the same rows, and cannot downgrade an active subscription
    # because the event's own status is never written.
    #
    # The same call is also the data migration, the nightly drift check, and the
    # recovery path if the endpoint is ever down past Stripe's 72-hour retry
    # window.
    class ReconcileCustomer
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(stripe_customer_id:)
        new(stripe_customer_id: stripe_customer_id).call
      end

      def initialize(stripe_customer_id:)
        @stripe_customer_id = stripe_customer_id
      end

      def call
        return failure("stripe_customer_id is required") if @stripe_customer_id.blank?

        memberships = ActiveRecord::Base.transaction do
          acquire_lock
          user = resolve_user
          subscriptions.map { |subscription| upsert(subscription, user) }
        end

        Result.new(success?: true, data: memberships, errors: [])
      rescue Stripe::StripeError => e
        Rails.logger.error("[billing] reconcile failed for #{@stripe_customer_id}: #{e.class}")
        failure(e.message)
      end

      private

      # Serialises concurrent reconciles for one customer without adding a
      # dependency. Transaction-scoped, so it releases on commit or rollback and
      # cannot leak. This replaces the legacy handler's RecordNotUnique rescue
      # and retry: the race is removed rather than recovered from.
      def acquire_lock
        ActiveRecord::Base.connection.exec_query(
          "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)",
          "billing-reconcile-lock",
          [@stripe_customer_id]
        )
      end

      def subscriptions
        list = Stripe::Subscription.list(
          customer: @stripe_customer_id, status: "all", limit: 100
        )
        list.auto_paging_each.to_a
      end

      # Two independent paths, tried in order. The first should almost always
      # win, because checkout writes stripe_customer_id to the user before any
      # webhook can fire. The second covers subscriptions created outside our
      # checkout — by the legacy books app, or by hand in the Stripe dashboard.
      def resolve_user
        found = ::User.find_by(stripe_customer_id: @stripe_customer_id)
        return found if found

        metadata_user_id = customer&.metadata&.[]("app_user_id")
        return nil if metadata_user_id.blank?

        ::User.find_by(id: metadata_user_id)
      end

      # Only a genuine "no such customer" means we should fall through to an
      # unattached membership. Every other StripeError -- rate limiting, auth,
      # a connection blip -- must propagate to the outer rescue, which turns it
      # into a failure Result so the job marks the event failed and Sidekiq
      # retries. Swallowing those here would silently orphan a real user's
      # membership on a transient error, with no signal that anything went wrong.
      def customer
        @customer ||= Stripe::Customer.retrieve(@stripe_customer_id)
      rescue Stripe::InvalidRequestError
        nil
      end

      def upsert(subscription, user)
        membership = ::Membership.find_or_initialize_by(
          stripe_subscription_id: subscription.id
        )

        # Belt and braces. A comped row has no stripe_subscription_id so it can
        # never be found here, but the design promise is that a webhook cannot
        # touch a manual grant, and that promise deserves an explicit guard.
        return membership if membership.persisted? && !membership.stripe?

        item = subscription.items.data.first

        membership.assign_attributes(
          # Never downgrade an existing attachment: a Stripe subscription cannot change
          # customer, so a user link resolved by any other path (a future email match,
          # or the unattached-membership claim service) must survive a reconcile. The
          # nightly sweep runs this over every subscription in the account, so an
          # unconditional assignment would silently detach those links within 24 hours.
          user: user || membership.user,
          source: :stripe,
          status: subscription.status,
          interval: (item&.price&.recurring&.interval == "year") ? :yearly : :monthly,
          stripe_customer_id: subscription.customer,
          # Basil (2025-03-31) moved this off the subscription onto the item.
          # Reading subscription.current_period_end works today via a deprecated
          # accessor and will stop working without warning.
          current_period_end: item && Time.at(item.current_period_end),
          cancel_at_period_end: !!subscription.cancel_at_period_end,
          canceled_at: subscription.canceled_at && Time.at(subscription.canceled_at),
          stripe_synced_at: Time.current
        )
        membership.save!
        membership
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
