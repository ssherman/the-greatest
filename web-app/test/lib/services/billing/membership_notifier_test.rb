require "test_helper"

module Services
  module Billing
    class MembershipNotifierTest < ActiveSupport::TestCase
      # ActionMailer::TestHelper (not the plain ActiveJob one) is what defines
      # assert_enqueued_emails / assert_no_enqueued_emails; it includes
      # ActiveJob::TestHelper itself, so this is the superset.
      include ActionMailer::TestHelper

      setup do
        ENV["MAIL_FROM_ADDRESS"] = "contact@example.org"
        # AdminMailer raises without this now that MembershipNotifier sends an
        # owner notice alongside every customer email.
        ENV["ADMIN_NOTIFICATION_EMAIL"] = "owner@example.org"
      end

      teardown do
        ENV.delete("MAIL_FROM_ADDRESS")
        ENV.delete("ADMIN_NOTIFICATION_EMAIL")
      end

      # Task 6: an activation now sends two emails, not one -- the member's
      # welcome and the owner's admin notice. See the dedicated
      # "sends both the member's welcome and the owner's notice" test below for
      # the precise count; this one keeps asserting the welcome half by name.
      test "sends the welcome email when a membership this app sold becomes active" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_enqueued_email_with MembershipMailer, :welcome, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      test "stamps welcome_email_sent_at so a second reconcile cannot resend" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        MembershipNotifier.call(transition)
        membership.reload
        assert_not_nil membership.welcome_email_sent_at

        assert_no_enqueued_emails do
          MembershipNotifier.call(MembershipTransition.new(membership: membership, previous_status: nil))
        end
      end

      # THE COEXISTENCE GUARD. Legacy is still live and still emails its own
      # subscribers; without this, they would receive two welcome emails.
      test "sends nothing for a membership this app did not sell" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "emails a membership this app did not sell once the scope is opened at cutover" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        with_env(MembershipEmailScope::ENV_VAR => "all") do
          # Welcome to the member, admin notice to the owner -- the scope
          # guard covers both, so opening it up opens both at once. Naming
          # both mailers, not just the total, is what would catch a
          # regression that opened the scope for two welcomes and zero admin
          # notices (or vice versa) while still summing to 2.
          assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
        end

        assert_enqueued_email_with MembershipMailer, :welcome, args: [membership]
        assert_enqueued_email_with AdminMailer, :new_subscription, args: [membership]
      end

      # The nightly sweep re-reconciles every subscription on the account.
      test "sends nothing when the status did not change" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      # A comped membership never came from Stripe and has no origin_domain.
      test "sends nothing for a comped membership" do
        membership = memberships(:editor_user_comped)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "sends nothing when the membership has no user to email" do
        membership = sold_membership(status: :active)
        membership.update!(user: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      # FINDING 1(b). Without wrapping the stamp and the enqueue in one
      # transaction, a raising deliver_later would still leave
      # welcome_email_sent_at set from the update! just before it -- burning
      # the once-only guard on an email nobody actually received. Wrapping
      # both in @membership.with_lock means the raise rolls the stamp back
      # too, so a retried reconcile can genuinely resend.
      #
      # This test does not go through MembershipMailer.welcome's real
      # rendering at all -- it stubs the class method to return a double
      # whose #deliver_later raises, isolating the enqueue failure from
      # anything about mail content.
      test "a failed enqueue does not leave welcome_email_sent_at stamped, so a retry can still resend" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        failing_mail = mock("mail")
        failing_mail.stubs(:deliver_later).raises(StandardError, "redis down")
        MembershipMailer.stubs(:welcome).returns(failing_mail)

        assert_raises(StandardError) { MembershipNotifier.call(transition) }

        assert_nil membership.reload.welcome_email_sent_at
      end

      test "sends the cancelled-last email when the user holds no other access" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_enqueued_email_with MembershipMailer, :canceled_last, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      test "sends the other-active variant when the user still holds another membership" do
        membership = sold_membership(status: :canceled)
        ::Membership.create!(
          user: membership.user, source: :comped, status: :active, current_period_end: nil
        )
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_enqueued_email_with MembershipMailer, :canceled_with_other_active, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      test "stamps ended_email_sent_at so a second reconcile cannot resend" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        MembershipNotifier.call(transition)
        assert_not_nil membership.reload.ended_email_sent_at

        assert_no_enqueued_emails do
          MembershipNotifier.call(
            MembershipTransition.new(membership: membership, previous_status: "active")
          )
        end
      end

      # A membership that arrived already cancelled -- as the account-wide
      # migration produced in bulk -- is not a cancellation anyone should hear
      # about.
      test "sends nothing when a membership arrives already cancelled" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "an activation sends both the member's welcome and the owner's notice" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
      end

      test "a membership this app did not sell notifies nobody, owner included" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      private

      def sold_membership(status:)
        memberships(:regular_user_monthly).tap { |m| m.update!(status: status, origin_domain: "books") }
      end
    end
  end
end
