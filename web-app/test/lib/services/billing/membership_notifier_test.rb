require "test_helper"

module Services
  module Billing
    class MembershipNotifierTest < ActiveSupport::TestCase
      # ActionMailer::TestHelper (not the plain ActiveJob one) is what defines
      # assert_enqueued_emails / assert_no_enqueued_emails; it includes
      # ActiveJob::TestHelper itself, so this is the superset.
      include ActionMailer::TestHelper

      setup { ENV["MAIL_FROM_ADDRESS"] = "contact@example.org" }
      teardown { ENV.delete("MAIL_FROM_ADDRESS") }

      test "sends the welcome email when a membership this app sold becomes active" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_enqueued_emails 1 do
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
          assert_enqueued_emails(1) { MembershipNotifier.call(transition) }
        end
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

      private

      def sold_membership(status:)
        memberships(:regular_user_monthly).tap { |m| m.update!(status: status, origin_domain: "books") }
      end
    end
  end
end
