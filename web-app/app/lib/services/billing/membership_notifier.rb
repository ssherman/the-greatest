module Services
  module Billing
    # Decides which membership email a reconcile owes, and enqueues it.
    #
    # All the "should we send this" logic lives here rather than in the mailers,
    # so a mailer stays a mailer and this stays testable without rendering
    # anything. Two independent guards, each of which exists for a reason:
    #
    #   1. MembershipEmailScope -- the legacy books app is still live on the
    #      same Stripe account and still emails its own subscribers. Without
    #      this, they get two of every email.
    #   2. The *_email_sent_at timestamps -- these are BOTH the once-only guard
    #      AND, as of this service, the entire eligibility signal (see
    #      welcome_owed? / cancellation_owed? below for why a status transition
    #      cannot be trusted for that). The nightly sweep re-reconciles every
    #      subscription on the account, and a transient Stripe blip can replay
    #      a transition, so the stamps make each email once-only per
    #      membership -- self-sufficiently: deliver_welcome / deliver_cancellation
    #      re-check the stamp INSIDE @membership.with_lock, where the row lock
    #      and reload mean a second caller -- even one holding a completely
    #      separate, independently-loaded copy of the membership -- sees the
    #      first caller's committed stamp before it can send.
    class MembershipNotifier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(transition) = new(transition).call

      def initialize(transition)
        # The transition is only ever a carrier for the membership now -- see
        # the class comment. Eligibility reads the membership's own durable
        # state, not anything about the transition itself.
        @membership = transition.membership
      end

      def call
        return skipped("not a stripe membership") unless @membership.stripe?
        return skipped("no user to email") if @membership.user&.email.blank?
        return skipped("outside the configured email scope") unless MembershipEmailScope.may_email?(@membership)

        if welcome_owed?
          deliver_welcome
        elsif cancellation_owed?
          deliver_cancellation
        else
          skipped("no email owed")
        end
      end

      private

      # trialing and active both grant access.
      ACCESS_GRANTING = %w[trialing active].freeze

      # Eligibility is derived from DURABLE state, not from the status
      # transition, and that is the whole point of this service.
      #
      # A transition is observable exactly once. upsert commits the status
      # before this service runs, so a failed enqueue -- Redis unavailable, say
      # -- leaves the stamp rolled back and the status already committed, and
      # every later retry and nightly sweep then computes previous_status ==
      # status. The email would be owed forever and never sent. The
      # *_email_sent_at columns ARE the record of what is owed; reading them
      # makes the whole path self-healing, because the next sweep simply
      # notices and sends.
      def welcome_owed?
        @membership.welcome_email_sent_at.nil? &&
          ACCESS_GRANTING.include?(@membership.status.to_s)
      end

      # Requires that a welcome actually went out. A membership this app never
      # welcomed must never be sent an ending notice -- which covers the
      # bulk-migrated rows that arrived already cancelled, durably, and replaces
      # the transition-era guard that did the same job only at the moment the
      # row was first seen.
      def cancellation_owed?
        @membership.ended_email_sent_at.nil? &&
          @membership.welcome_email_sent_at.present? &&
          @membership.canceled?
      end

      def deliver_welcome
        # The re-check INSIDE with_lock is what makes this guard self-
        # sufficient. with_lock takes a row lock and reloads the membership
        # from the database before the block runs, so a second notifier --
        # holding an entirely separate in-memory copy of this same membership,
        # each loaded via its own Membership.find before either one stamped
        # anything -- blocks on that row lock, then reloads and sees the first
        # notifier's already-committed welcome_email_sent_at. Without this
        # re-check, two such copies both pass call's outer
        # `welcome_email_sent_at.nil?` check (each reads the column before any
        # lock exists), both stamp, and both enqueue: two welcome emails and
        # two admin notices for one transition. See
        # "sends exactly one welcome and one admin notice for two
        # independently-loaded copies of the same membership" below for the
        # regression test.
        #
        # ReconcileCustomer#acquire_lock's transaction-scoped advisory lock,
        # keyed on the Stripe customer, is an ADDITIONAL layer on top of this,
        # not a substitute for it. It serialises today's only path in --two
        # webhook endpoints delivering the same event, or the nightly sweep
        # racing a webhook -- but it says nothing about a caller that does not
        # take that lock: an admin "resend welcome" action, a backfill task,
        # anything calling this notifier directly. The in-lock re-check below
        # is what stays correct regardless of who calls in.
        #
        # with_lock wraps the re-check, the stamp and the enqueue in one DB
        # transaction (with a row lock, so a concurrent updater blocks rather
        # than racing). If MembershipMailer.welcome or .deliver_later raises --
        # Redis is down, say -- the update! above rolls back with it, so the
        # stamp does NOT survive a failed enqueue. Without this, a transient
        # enqueue failure would permanently burn the once-only guard:
        # welcome_email_sent_at would already be set, so no future reconcile
        # would ever try again, and the member would never get a welcome email.
        sent = false
        @membership.with_lock do
          next if @membership.welcome_email_sent_at.present?

          @membership.update!(welcome_email_sent_at: Time.current)
          MembershipMailer.welcome(@membership).deliver_later
          sent = true
        end
        return skipped("welcome already sent") unless sent

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
        # Same shape as deliver_welcome, see there for the full reasoning: the
        # re-check INSIDE with_lock -- not stamp-before-enqueue ordering by
        # itself -- is what makes this guard self-sufficient against two
        # independently-loaded copies of the same membership. with_lock wraps
        # the re-check, the stamp and the enqueue in one transaction, so a
        # raising enqueue rolls the stamp back too, and a retried reconcile
        # can genuinely resend.
        result = nil
        sent = false

        @membership.with_lock do
          next if @membership.ended_email_sent_at.present?

          @membership.update!(ended_email_sent_at: Time.current)

          if other_access?
            MembershipMailer.canceled_with_other_active(@membership).deliver_later
            result = :canceled_with_other_active
          else
            MembershipMailer.canceled_last(@membership).deliver_later
            result = :canceled_last
          end

          sent = true
        end
        return skipped("cancellation already sent") unless sent

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
