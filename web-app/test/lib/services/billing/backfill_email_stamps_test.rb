require "test_helper"

module Services
  module Billing
    class BackfillEmailStampsTest < ActiveSupport::TestCase
      include ActionMailer::TestHelper

      # Only exercised by the two load-bearing demonstration tests below,
      # which route through MembershipNotifier -> AdminMailer; the ordinary
      # backfill tests never render mail. Set unconditionally anyway, to
      # match the convention in membership_notifier_test.rb.
      setup do
        ENV["MAIL_FROM_ADDRESS"] = "contact@example.org"
        ENV["ADMIN_NOTIFICATION_EMAIL"] = "owner@example.org"
      end

      teardown do
        ENV.delete("MAIL_FROM_ADDRESS")
        ENV.delete("ADMIN_NOTIFICATION_EMAIL")
      end

      test "stamps a membership that was never welcomed" do
        # origin_domain: nil -- the backfill is scoped to rows this app never
        # had authority over (see the service's ownership-scope comment); an
        # own-sold row is covered separately below.
        membership = memberships(:regular_user_monthly)
        membership.update!(origin_domain: nil, welcome_email_sent_at: nil, status: :active)

        BackfillEmailStamps.call

        assert_not_nil membership.reload.welcome_email_sent_at
      end

      test "stamps the ending notice on a membership that is already cancelled" do
        membership = memberships(:regular_user_monthly)
        membership.update!(origin_domain: nil, status: :canceled, welcome_email_sent_at: nil, ended_email_sent_at: nil)

        BackfillEmailStamps.call

        assert_not_nil membership.reload.ended_email_sent_at
      end

      # Idempotent: running it twice must not move a stamp that already exists,
      # or a genuine send date would be rewritten to the backfill date.
      #
      # origin_domain: nil -- this must be a blank-origin row, i.e. inside the
      # backfill's scope, or the assertion passes for the wrong reason (the
      # ownership scope keeping it untouched, not the nil guard this test
      # claims to exercise). Confirmed by deleting
      # `.where(welcome_email_sent_at: nil)` from the service and watching
      # this test go red -- see the fix-round report.
      test "leaves an existing stamp untouched" do
        original = 3.days.ago.change(usec: 0)
        membership = memberships(:regular_user_monthly)
        membership.update!(origin_domain: nil, welcome_email_sent_at: original)

        BackfillEmailStamps.call

        assert_equal original.to_i, membership.reload.welcome_email_sent_at.to_i
      end

      # The whole point: it must not send anything.
      test "sends no email of any kind" do
        memberships(:regular_user_monthly).update!(welcome_email_sent_at: nil)

        assert_no_enqueued_emails { BackfillEmailStamps.call }
      end

      test "reports how many rows it stamped" do
        memberships(:regular_user_monthly).update!(origin_domain: nil, welcome_email_sent_at: nil, status: :active)

        result = BackfillEmailStamps.call

        assert result.success?
        assert result.data[:welcome] >= 1
      end

      # FIX ROUND 1 -- ownership scoping. MembershipEmailScope already lets an
      # own-sold row (origin_domain present) through regardless of the scope
      # setting, so a nil stamp on one is never a legacy-cutover artifact: it
      # is either a membership that has not yet earned its welcome (mid-trial,
      # incomplete) or exactly the failed-enqueue recovery case Task 2 exists
      # to self-heal. The backfill must never touch these rows.
      test "does not stamp an own-sold membership, even with a nil welcome stamp" do
        membership = memberships(:regular_user_monthly)
        membership.update!(origin_domain: "books", welcome_email_sent_at: nil, status: :active)

        BackfillEmailStamps.call

        assert_nil membership.reload.welcome_email_sent_at
      end

      # The recovery path Task 2 added must survive a cutover backfill: an
      # own-sold membership backfilled while not yet access-granting (or mid
      # failed-enqueue-recovery) must still receive its welcome once it
      # actually earns one.
      test "an own-sold membership backfilled while unwelcomed still gets its welcome once it converts" do
        membership = memberships(:regular_user_monthly)
        membership.update!(origin_domain: "books", welcome_email_sent_at: nil, status: :incomplete)

        BackfillEmailStamps.call
        assert_nil membership.reload.welcome_email_sent_at

        membership.update!(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: "incomplete")

        assert_enqueued_email_with MembershipMailer, :welcome, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      # LOAD-BEARING DEMONSTRATION. This is the actual hazard the backfill
      # exists to close: the moment MEMBERSHIP_EMAIL_SCOPE=all is set at
      # legacy cutover, a legacy-shaped membership (no origin_domain, never
      # welcomed, access-granting) is exactly what MembershipNotifier would
      # mail on the very next reconcile. Without the backfill run first, it
      # does; with it run first, it does not. If this pair of assertions ever
      # both pass with the "before" half showing no mail, the protection is
      # decorative, not load-bearing -- so the "before" half must show mail
      # actually going out.
      test "without the backfill, opening the scope mails a legacy membership on the next reconcile" do
        membership = legacy_shaped_membership

        with_env(MembershipEmailScope::ENV_VAR => "all") do
          assert_enqueued_emails(2) do
            MembershipNotifier.call(
              MembershipTransition.new(membership: membership, previous_status: "active")
            )
          end
        end
      end

      test "after the backfill, opening the scope sends nothing for the same legacy membership" do
        membership = legacy_shaped_membership

        BackfillEmailStamps.call

        with_env(MembershipEmailScope::ENV_VAR => "all") do
          assert_no_enqueued_emails do
            MembershipNotifier.call(
              MembershipTransition.new(membership: membership, previous_status: "active")
            )
          end
        end
      end

      # LOAD-BEARING DEMONSTRATION, second half. The ended-stamp query narrows
      # to `status: :canceled` deliberately: only a row that is ALREADY
      # cancelled at backfill time should have its ended stamp pre-filled. A
      # legacy row that is still active at cutover and cancels LATER must not
      # be pre-stamped, or cancellation_owed? finds ended_email_sent_at
      # already set and the member never gets a goodbye. Confirmed by
      # deleting `status: :canceled` from the service's ended-stamp query and
      # watching this test go red -- see the fix-round report.
      test "a legacy row that cancels after cutover still gets its goodbye" do
        membership = legacy_shaped_membership

        BackfillEmailStamps.call
        assert_not_nil membership.reload.welcome_email_sent_at
        assert_nil membership.ended_email_sent_at

        membership.update!(status: :canceled)

        with_env(MembershipEmailScope::ENV_VAR => "all") do
          assert_enqueued_email_with MembershipMailer, :canceled_last, args: [membership] do
            MembershipNotifier.call(
              MembershipTransition.new(membership: membership, previous_status: "active")
            )
          end
        end
      end

      private

      # Never sold by this app (no origin_domain), never welcomed, currently
      # access-granting -- exactly what every pre-cutover legacy membership
      # looks like.
      def legacy_shaped_membership
        memberships(:regular_user_monthly).tap do |m|
          m.update!(origin_domain: nil, welcome_email_sent_at: nil, status: :active)
        end
      end
    end
  end
end
