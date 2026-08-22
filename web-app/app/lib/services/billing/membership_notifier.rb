module Services
  module Billing
    # Decides which membership email a reconcile owes, and enqueues it.
    #
    # All the "should we send this" logic lives here rather than in the mailers,
    # so a mailer stays a mailer and this stays testable without rendering
    # anything. Three independent guards, each of which exists for a reason:
    #
    #   1. MembershipEmailScope -- the legacy books app is still live on the
    #      same Stripe account and still emails its own subscribers. Without
    #      this, they get two of every email.
    #   2. The *_email_sent_at timestamps -- the nightly sweep re-reconciles
    #      every subscription on the account, and a transient Stripe blip can
    #      replay a transition. These make each email once-only per membership.
    #   3. The transition itself -- "currently active" is true every night;
    #      "just became active" is true once.
    class MembershipNotifier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(transition) = new(transition).call

      def initialize(transition)
        @transition = transition
        @membership = transition.membership
      end

      def call
        return skipped("not a stripe membership") unless @membership.stripe?
        return skipped("no user to email") if @membership.user&.email.blank?
        return skipped("outside the configured email scope") unless MembershipEmailScope.may_email?(@membership)

        if @transition.became_active? && @membership.welcome_email_sent_at.nil?
          deliver_welcome
        else
          skipped("no email owed for this transition")
        end
      end

      private

      def deliver_welcome
        # Stamp BEFORE enqueuing. Two webhook endpoints deliver every event, so
        # two jobs routinely process the same transition concurrently; stamping
        # first means the loser of that race finds the timestamp set and sends
        # nothing. Enqueuing first would send two emails and then stamp twice.
        @membership.update!(welcome_email_sent_at: Time.current)
        MembershipMailer.welcome(@membership).deliver_later

        Result.new(success?: true, data: :welcome, errors: [])
      end

      def skipped(reason)
        Result.new(success?: true, data: nil, errors: [])
      ensure
        Rails.logger.info("MembershipNotifier skipped membership #{@membership.id}: #{reason}")
      end
    end
  end
end
