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
        # (Belt and braces: acquire_lock's transaction-scoped advisory lock
        # already serialises concurrent reconciles for one customer, so by the
        # time a second reconcile's upsert re-reads this row, became_active?
        # is already false for it. This ordering matters for the case that
        # guard does not cover -- two independently-triggered reconciles, or a
        # future caller that does not take that lock.)
        #
        # with_lock wraps both statements in one DB transaction (with a row
        # lock, so a concurrent updater blocks rather than racing). If
        # MembershipMailer.welcome or .deliver_later raises -- Redis is down,
        # say -- the update! above rolls back with it, so the stamp does NOT
        # survive a failed enqueue. Without this, a transient enqueue failure
        # would permanently burn the once-only guard: welcome_email_sent_at
        # would already be set, so no future reconcile would ever try again,
        # and the member would never get a welcome email.
        @membership.with_lock do
          @membership.update!(welcome_email_sent_at: Time.current)
          MembershipMailer.welcome(@membership).deliver_later
        end

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
