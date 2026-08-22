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
        elsif @transition.became_canceled? && @membership.ended_email_sent_at.nil?
          deliver_cancellation
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

        # Deliberately OUTSIDE the with_lock above -- but NOT because
        # AdminMailer's own action body could raise inside the transaction.
        # deliver_later never runs the mailer action at enqueue time; it only
        # serialises (mailer_class, action, args) into an ActiveJob, so
        # admin_address's MissingAdminAddress raise (if ADMIN_NOTIFICATION_EMAIL
        # were ever unset) would fire later, when that job PERFORMS in Sidekiq
        # -- fully decoupled from this transaction by then. Confirmed: with
        # ADMIN_NOTIFICATION_EMAIL unset, MembershipNotifier.call does not raise.
        #
        # The real risk is the enqueue itself: deliver_later's push to Redis is
        # a synchronous call that can fail (Redis down, say). Two deliver_later
        # calls sharing one with_lock means a failure on the SECOND leaves the
        # FIRST irrevocably already pushed to Sidekiq -- the transaction still
        # rolls back and clears welcome_email_sent_at, but the customer's
        # welcome job is already queued to run. A retried reconcile would then
        # find the once-only guard cleared and send a second welcome email --
        # reopening the exact double-send Task 5's with_lock exists to prevent,
        # only now triggered by the admin enqueue instead of the customer one.
        # Keeping the admin send outside the lock means a failed admin enqueue
        # can never affect whether the member gets exactly one welcome email;
        # at worst the owner misses a notice, the same silent-miss tradeoff
        # RecordDonation accepts for a donor receipt.
        AdminMailer.new_subscription(@membership).deliver_later

        Result.new(success?: true, data: :welcome, errors: [])
      end

      def deliver_cancellation
        # Stamp before enqueuing -- see deliver_welcome. with_lock wraps the
        # stamp and the enqueue in one transaction, so a raising enqueue rolls
        # the stamp back too, and a retried reconcile can genuinely resend.
        result = nil

        @membership.with_lock do
          @membership.update!(ended_email_sent_at: Time.current)

          if other_access?
            MembershipMailer.canceled_with_other_active(@membership).deliver_later
            result = :canceled_with_other_active
          else
            MembershipMailer.canceled_last(@membership).deliver_later
            result = :canceled_last
          end
        end

        # Same reasoning as deliver_welcome: outside the lock not because the
        # mailer action body could raise transactionally (deliver_later never
        # runs it there -- see deliver_welcome), but because a failed Redis
        # enqueue for this admin send, if it shared the lock above, would roll
        # back ended_email_sent_at after the customer's cancellation job was
        # already irrevocably queued -- reopening a double-send of that email.
        AdminMailer.subscription_canceled(@membership).deliver_later

        Result.new(success?: true, data: result, errors: [])
      end

      # Does the user still hold access from some OTHER membership? Reuses the
      # same scope that answers User#member?, so the email can never contradict
      # what the site actually does.
      def other_access?
        @membership.user.memberships.granting_access.where.not(id: @membership.id).exists?
      end

      def skipped(reason)
        Result.new(success?: true, data: nil, errors: [])
      ensure
        Rails.logger.info("MembershipNotifier skipped membership #{@membership.id}: #{reason}")
      end
    end
  end
end
