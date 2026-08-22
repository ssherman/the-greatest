module Services
  module Billing
    # Marks every existing membership as "already emailed", so that opening
    # MEMBERSHIP_EMAIL_SCOPE to `all` does not mail the entire back catalogue.
    #
    # MembershipNotifier derives eligibility from durable state: a membership
    # that grants access and has no welcome_email_sent_at is owed a welcome.
    # That is what makes a failed enqueue recoverable. It also means every
    # legacy membership -- none of which this app ever welcomed -- is one
    # config flag away from being owed one. Run this immediately BEFORE
    # flipping the scope at legacy cutover.
    #
    # Idempotent and additive: it only ever fills a nil stamp, never moves an
    # existing one, and never sends anything. This is the one place in the
    # billing codebase permitted to use update_all -- scoped to rows whose
    # stamp is already nil, touching only the stamp column and updated_at.
    class BackfillEmailStamps
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        now = Time.current

        welcome = ::Membership.where(welcome_email_sent_at: nil).update_all(
          welcome_email_sent_at: now, updated_at: now
        )

        ended = ::Membership.where(ended_email_sent_at: nil, status: :canceled).update_all(
          ended_email_sent_at: now, updated_at: now
        )

        Rails.logger.info("[billing] backfilled email stamps: welcome=#{welcome} ended=#{ended}")

        Result.new(success?: true, data: {welcome: welcome, ended: ended}, errors: [])
      end
    end
  end
end
