module Services
  module Billing
    # Marks every existing LEGACY membership as "already emailed", so that
    # opening MEMBERSHIP_EMAIL_SCOPE to `all` does not mail the entire back
    # catalogue.
    #
    # MembershipNotifier derives eligibility from durable state: a membership
    # that grants access and has no welcome_email_sent_at is owed a welcome.
    # That is what makes a failed enqueue recoverable. It also means every
    # legacy membership -- none of which this app ever welcomed -- is one
    # config flag away from being owed one. Run this immediately BEFORE
    # flipping the scope at legacy cutover.
    #
    # THE OWNERSHIP SCOPE IS LOAD-BEARING, not decoration. MembershipEmailScope
    # already lets an own-sold row (origin_domain present) through regardless
    # of the scope setting -- own-sold rows were never blocked by own_only in
    # the first place. So a nil stamp on an own-sold row is never a
    # legacy-cutover artifact; it is one of two live states: a membership that
    # has not yet earned its welcome (mid-trial, incomplete), or exactly the
    # failed-enqueue recovery case Task 2 was built to self-heal. Stamping
    # either one does not defer that email -- it cancels it permanently, with
    # no error and no distinguishing log line. This backfill exists solely to
    # neutralise rows held back by the scope gate, so it must only ever touch
    # rows the gate is currently blocking: origin_domain blank. `[nil, ""]`
    # mirrors Membership#sold_by_this_app? (`origin_domain.present?`) exactly
    # -- a scope that disagreed with that predicate would be its own future
    # bug.
    #
    # Idempotent and additive: it only ever fills a nil stamp, never moves an
    # existing one, and never sends anything. This is the one place in the
    # billing codebase permitted to use update_all -- scoped to rows this app
    # never had authority over AND whose stamp is already nil, touching only
    # the stamp column and updated_at.
    class BackfillEmailStamps
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        now = Time.current
        legacy = ::Membership.where(origin_domain: [nil, ""])

        welcome = legacy.where(welcome_email_sent_at: nil).update_all(
          welcome_email_sent_at: now, updated_at: now
        )

        ended = legacy.where(ended_email_sent_at: nil, status: :canceled).update_all(
          ended_email_sent_at: now, updated_at: now
        )

        Rails.logger.info("[billing] backfilled email stamps: welcome=#{welcome} ended=#{ended}")

        Result.new(success?: true, data: {welcome: welcome, ended: ended}, errors: [])
      end
    end
  end
end
