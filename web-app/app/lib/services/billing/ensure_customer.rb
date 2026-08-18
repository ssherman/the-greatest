# frozen_string_literal: true

module Services
  module Billing
    # Find-or-create the Stripe Customer for a user, and write the id back to
    # the user IN THIS REQUEST.
    #
    # That write is the point of the service. It means the user<->customer link
    # exists before any webhook for the subscription can arrive, which is why
    # ReconcileCustomer needs no checkout-session user-recovery path -- the
    # legacy handler's find_checkout_session_for_subscription exists precisely
    # because it did not have this.
    class EnsureCustomer
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(user:) = new(user: user).call

      def initialize(user:)
        @user = user
      end

      def call
        return failure("user is required") if @user.nil?
        return success(@user.stripe_customer_id) if @user.stripe_customer_id.present?

        customer = ::Stripe::Customer.create(
          {
            email: @user.email,
            name: @user.display_name.presence || @user.name,
            # app_user_id is the reconciler's second attachment path, used when a
            # subscription turns up whose customer we have no local row for.
            # origin_app matches the tag on sessions and subscriptions so every
            # object this app creates is identifiable in a shared account.
            metadata: {app_user_id: @user.id, origin_app: StripeClient::ORIGIN_APP}
          },
          # Protects against a double-submitted checkout form creating two
          # customers for one user. Stripe expires these keys after 24 hours,
          # so it is a duplicate-click guard, not a permanent uniqueness claim.
          {idempotency_key: "customer-#{@user.id}"}
        )

        @user.update!(stripe_customer_id: customer.id)
        success(customer.id)
      rescue ::Stripe::StripeError => e
        # Never log the exception message here: Stripe echoes request parameters
        # in some error messages, and those carry the customer's email.
        Rails.logger.error("[billing] EnsureCustomer failed for user #{@user&.id}: #{e.class}")
        failure(e.message)
      end

      private

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
