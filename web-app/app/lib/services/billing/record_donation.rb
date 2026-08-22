# frozen_string_literal: true

module Services
  module Billing
    # Writes a Donation row for a completed one-off payment.
    #
    # Takes only the checkout session ID from the event -- an identifier, never
    # state -- and re-reads the session from the Stripe API for the amount, the
    # paid status and the donor's email, exactly as ReconcileCustomer re-reads
    # subscriptions. That is why a replayed or out-of-order delivery converges
    # instead of double-counting.
    #
    # This also records donations the LEGACY books app takes, because both apps
    # share one Stripe account and both endpoints receive every event. That is
    # intended: stripe_payment_intent_id is unique, so a webhook-recorded row and
    # a migration-imported row converge rather than duplicating. Their domain is
    # nil, which is correct -- they did not come from one of our sites.
    class RecordDonation
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(checkout_session_id:) = new(checkout_session_id: checkout_session_id).call

      def initialize(checkout_session_id:)
        @checkout_session_id = checkout_session_id
      end

      def call
        return failure("checkout_session_id is required") if @checkout_session_id.blank?

        session = ::Stripe::Checkout::Session.retrieve(@checkout_session_id)

        return success(nil) unless session.mode == "payment"
        return success(nil) unless session.payment_status == "paid"

        payment_intent_id = session.payment_intent
        # Without an intent id there is no idempotency key, and
        # find_or_initialize_by(nil) would match the first row with a null intent
        # -- an imported legacy donation -- and overwrite it.
        return success(nil) if payment_intent_id.blank?

        # Donation requires amount_cents > 0. A paid session can only report 0
        # here in some Stripe edge case (e.g. a fully-discounted checkout); treat
        # it as nothing to record rather than letting save! raise RecordInvalid,
        # which the rescue below does not catch and would land this event in the
        # dead set on a permanent, unretryable "failure".
        return success(nil) if session.amount_total.to_i <= 0

        donation = ::Donation.find_or_initialize_by(stripe_payment_intent_id: payment_intent_id)
        donation.assign_attributes(
          user: resolve_user(session),
          amount_cents: session.amount_total,
          currency: session.currency,
          status: :succeeded,
          stripe_checkout_session_id: session.id,
          email: session.customer_details&.email,
          domain: session.metadata&.[]("origin_domain")
        )
        donation.save!
        deliver_receipt(donation)

        success(donation)
      rescue ActiveRecord::RecordNotUnique
        # Stripe fans out one event to both webhook endpoints simultaneously (see
        # Webhooks::StripeController), so two jobs racing find_or_initialize_by
        # on the same brand-new payment_intent_id is the normal case, not a
        # bug -- both find nothing, both build a new row, and the database's
        # partial unique index on stripe_payment_intent_id catches the loser
        # here (a true race: both INSERTs reached the constraint before either
        # committed).
        #
        # Re-reading and returning the winner's row is what makes the loser
        # converge quietly instead of raising -- which would flip its
        # stripe_events row to `failed` and have Sidekiq retry noise a real,
        # successful donation as if something were broken.
        success(::Donation.find_by(stripe_payment_intent_id: payment_intent_id))
      rescue ActiveRecord::RecordInvalid => e
        # Same race, the other way it can surface: the loser's own uniqueness
        # validation SELECT runs after the winner has already committed, so
        # save! never reaches the INSERT and raises RecordInvalid instead of
        # RecordNotUnique.
        #
        # The of_kind? guard is load-bearing, same as
        # Webhooks::StripeController#record_event: a donation invalid for any
        # OTHER reason (a future validation, a data bug) must still raise and
        # surface as a failed stripe_events row, not be swallowed here.
        raise unless e.record.errors.of_kind?(:stripe_payment_intent_id, :taken)
        success(::Donation.find_by(stripe_payment_intent_id: payment_intent_id))
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] donation record failed for #{@checkout_session_id}: #{e.class}")
        failure(e.message)
      end

      private

      # Anonymous donations are allowed and stay unattached. Three paths, tried
      # in order.
      def resolve_user(session)
        # Both app_user_id and client_reference_id are only trustworthy on a
        # session THIS app created -- gated on the same origin_app check.
        # metadata[app_user_id] is the one our own flow actually sets (see
        # CreateCheckoutSession#donation_params), so in practice this app's own
        # sessions always carry origin_app alongside it and this gate changes
        # nothing for our own traffic. The account is shared with the legacy
        # books app, though, and this is a *shared* Stripe account: any session
        # on it, from any source, can carry an app_user_id-shaped metadata key.
        # Legacy does not currently set one, so this closes a hypothetical
        # rather than an observed hole -- but it costs our own traffic nothing,
        # so there is no reason to leave it open. client_reference_id needs the
        # same gate for a concrete reason: legacy's checkout links DO set it,
        # and legacy ids only coincide with ours for users who existed at
        # migration time -- both apps are live simultaneously and now allocate
        # ids from the same number line independently, so an ungated lookup
        # would attach a legacy donor's row (and their email) to an unrelated
        # new-app user.
        if session.metadata&.[]("origin_app") == StripeClient::ORIGIN_APP
          app_user_id = session.metadata&.[]("app_user_id").presence
          return ::User.find_by(id: app_user_id) if app_user_id

          client_reference_id = session.client_reference_id.presence
          return ::User.find_by(id: client_reference_id) if client_reference_id
        end

        # A Stripe customer id is globally unique and genuinely identifies a
        # person, so this match is safe even for a legacy-originated session.
        ::User.find_by(stripe_customer_id: session.customer) if session.customer.present?
      end

      # Legacy still takes donations through its own payment links and emails
      # those donors itself, so this app must stay quiet about anything it did
      # not take. MembershipEmailScope is the switch that opens up at cutover.
      def deliver_receipt(donation)
        return if donation.email.blank?
        return unless MembershipEmailScope.may_email?(donation)

        MembershipMailer.donation_receipt(donation).deliver_later
      end

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
