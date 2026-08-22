require "test_helper"

module Services
  module Billing
    class RecordDonationTest < ActiveSupport::TestCase
      # ActionMailer::TestHelper (not the plain ActiveJob one) is what defines
      # assert_enqueued_emails / assert_no_enqueued_emails; it includes
      # ActiveJob::TestHelper itself, so this is the superset.
      include ActionMailer::TestHelper

      def session_stub(overrides = {})
        stub({
          id: "cs_test_1",
          mode: "payment",
          payment_status: "paid",
          payment_intent: "pi_test_1",
          amount_total: 2500,
          currency: "usd",
          customer: nil,
          customer_details: stub(email: "donor@example.com"),
          client_reference_id: nil,
          metadata: {"origin_domain" => "books", "app_user_id" => nil}
        }.merge(overrides))
      end

      test "records a paid donation" do
        ::Stripe::Checkout::Session.expects(:retrieve).with("cs_test_1").returns(session_stub)

        result = RecordDonation.call(checkout_session_id: "cs_test_1")

        assert result.success?
        donation = result.data
        assert_equal 2500, donation.amount_cents
        assert_equal "succeeded", donation.status
        assert_equal "pi_test_1", donation.stripe_payment_intent_id
        assert_equal "donor@example.com", donation.email
        assert_equal "books", donation.domain
      end

      test "attaches the donation to a signed-in donor" do
        # This app's own donation flow always stamps origin_app alongside
        # app_user_id (see CreateCheckoutSession#donation_params) -- this is
        # what a session THIS app created actually looks like.
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(metadata: {
            "origin_domain" => "books", "app_user_id" => user.id.to_s,
            "origin_app" => ::Services::Billing::StripeClient::ORIGIN_APP
          }))

        assert_equal user, RecordDonation.call(checkout_session_id: "cs_test_1").data.user
      end

      test "does not trust an app_user_id on a session not tagged as this app's own" do
        # Hardening against the shared Stripe account, mirroring the existing
        # client_reference_id gate below: an app_user_id-shaped metadata key on
        # a session this app did not create must not be trusted, even though
        # legacy does not currently set one. Costs our own traffic nothing --
        # see the test above.
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(metadata: {"origin_domain" => "books", "app_user_id" => user.id.to_s}))

        assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data.user
      end

      test "ignores a subscription-mode session" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(mode: "subscription"))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end
      end

      test "ignores a session that was not actually paid" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(payment_status: "unpaid"))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end
      end

      test "ignores a zero-amount paid session rather than raising RecordInvalid" do
        # Donation validates amount_cents > 0. Without this guard, save! would
        # raise on a fully-discounted checkout and the job's rescue would treat
        # a one-off Stripe oddity as a permanent failure headed for the dead set.
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(amount_total: 0))

        result = nil
        assert_no_difference "Donation.count" do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert result.success?
        assert_nil result.data
      end

      test "ignores a paid session with no payment intent rather than matching every nil row" do
        # find_or_initialize_by(stripe_payment_intent_id: nil) would match the
        # first legacy-imported row with a null intent and overwrite it. Prove it
        # by constructing exactly that row and asserting it is untouched.
        legacy_row = donations(:legacy_imported_no_intent)
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(payment_intent: nil))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end

        assert_equal 750, legacy_row.reload.amount_cents
        assert_equal "legacy_donor@example.com", legacy_row.email
      end

      test "recording the same session twice writes one row" do
        ::Stripe::Checkout::Session.expects(:retrieve).twice.returns(session_stub)

        RecordDonation.call(checkout_session_id: "cs_test_1")
        assert_no_difference "Donation.count" do
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end
      end

      # Stripe fans out one event to both webhook endpoints simultaneously, so
      # two ProcessStripeEventJob runs racing find_or_initialize_by on the same
      # brand-new payment_intent_id is the normal case. Simulate the loser by
      # stubbing save! to raise what the database raises when two INSERTs both
      # reach the partial unique index before either commits, with the winner's
      # row already there for the re-read to find.
      test "a RecordNotUnique race on the same payment intent converges on the winner's row instead of raising" do
        winner = Donation.create!(
          amount_cents: 2500, currency: "usd", status: :succeeded,
          stripe_payment_intent_id: "pi_test_1", stripe_checkout_session_id: "cs_other",
          email: "donor@example.com"
        )
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub)
        ::Donation.any_instance.expects(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))

        result = nil
        assert_no_difference "Donation.count" do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert result.success?
        assert_equal winner, result.data
      end

      # The other shape the same race can take: the loser's own uniqueness
      # validation SELECT runs after the winner has already committed, so
      # save! raises RecordInvalid instead of reaching the database constraint.
      test "a RecordInvalid race on stripe_payment_intent_id converges on the winner's row instead of raising" do
        winner = Donation.create!(
          amount_cents: 2500, currency: "usd", status: :succeeded,
          stripe_payment_intent_id: "pi_test_1", stripe_checkout_session_id: "cs_other",
          email: "donor@example.com"
        )
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub)
        invalid_donation = Donation.new
        invalid_donation.errors.add(:stripe_payment_intent_id, :taken)
        ::Donation.any_instance.expects(:save!)
          .raises(ActiveRecord::RecordInvalid.new(invalid_donation))

        result = nil
        assert_no_difference "Donation.count" do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert result.success?
        assert_equal winner, result.data
      end

      # Proves deliver_receipt is placed outside the rescue blocks: the first
      # call is the genuine winner (creates the row and sends), the second is
      # forced into the RecordNotUnique recovery path exactly like the test
      # above -- it must converge on the winner's row WITHOUT sending a second
      # receipt. This exercises the real rescue code (save! actually raises and
      # is actually caught here), not a short-circuit earlier in #call -- both
      # calls reach the same session/paid/amount checks and the same
      # find_or_initialize_by + save! line.
      #
      # Task 6: deliver_receipt now also fires one admin notice alongside the
      # donor receipt, so the total is two jobs, not one -- but exactly two,
      # not four, is still the same "only the winner sends" invariant this
      # test exists to prove. Checking both mailer/method pairs individually
      # (rather than a bare count of 2) is what would catch a regression that
      # sent the receipt twice and dropped the admin notice, or vice versa.
      test "running RecordDonation.call twice for a race'd payment intent sends exactly one receipt and one admin notice" do
        ::Stripe::Checkout::Session.expects(:retrieve).twice.returns(session_stub)

        result = nil
        assert_enqueued_emails(2) do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")

          ::Donation.any_instance.expects(:save!).raises(ActiveRecord::RecordNotUnique.new("duplicate key"))
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        donation = result.data
        assert_enqueued_email_with MembershipMailer, :donation_receipt, args: [donation]
        assert_enqueued_email_with AdminMailer, :anonymous_donation, args: [donation]
      end

      # The gap the exception-driven race test above cannot see: ProcessStripeEventJob
      # re-enqueues whenever its stripe_events row is still `received` or `failed`, and
      # Sidekiq retries on top of that -- so an ordinary second call for an
      # already-committed donation, with no unique-constraint collision at all, must
      # still send only once. previously_new_record? is what tells the two calls apart.
      #
      # Task 6: same two-jobs-not-four accounting as the race test above.
      test "running RecordDonation.call twice through the ordinary path sends exactly one receipt and one admin notice" do
        ::Stripe::Checkout::Session.expects(:retrieve).twice.returns(session_stub)

        result = nil
        assert_enqueued_emails(2) do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        donation = result.data
        assert_enqueued_email_with MembershipMailer, :donation_receipt, args: [donation]
        assert_enqueued_email_with AdminMailer, :anonymous_donation, args: [donation]
      end

      # The of_kind? guard must not swallow a donation that is invalid for some
      # OTHER reason -- that would return success with nothing recorded and no
      # audit trail, which is exactly the defect class this codebase has been
      # bitten by before (see the sanitizer/idempotent-write-paths lessons).
      test "a RecordInvalid for a reason other than the intent-id race still raises" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub)
        invalid_donation = Donation.new
        invalid_donation.errors.add(:amount_cents, :greater_than, count: 0)
        ::Donation.any_instance.expects(:save!)
          .raises(ActiveRecord::RecordInvalid.new(invalid_donation))

        assert_raises(ActiveRecord::RecordInvalid) do
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end
      end

      test "a Stripe failure is a failed Result" do
        ::Stripe::Checkout::Session.expects(:retrieve).raises(::Stripe::APIConnectionError.new("down"))

        refute RecordDonation.call(checkout_session_id: "cs_test_1").success?
      end

      test "trusts client_reference_id when the session is this app's own" do
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve).returns(
          session_stub(client_reference_id: user.id.to_s,
            metadata: {"origin_domain" => "books", "app_user_id" => nil,
                       "origin_app" => ::Services::Billing::StripeClient::ORIGIN_APP})
        )

        assert_equal user, RecordDonation.call(checkout_session_id: "cs_test_1").data.user
      end

      test "does not attach a legacy session's client_reference_id to an unrelated new-app user" do
        # Legacy's checkout links set client_reference_id to a legacy user id.
        # Post-cutover the two apps allocate ids from the same number line
        # independently, so an id that happens to match one of ours may belong
        # to a different person. Only trust it when origin_app marks the
        # session as ours -- this session carries no such tag.
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve).returns(
          session_stub(client_reference_id: user.id.to_s,
            metadata: {"origin_domain" => "books", "app_user_id" => nil})
        )

        assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data.user
      end

      test "emails a receipt for a donation this app took, plus one admin notice" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub)

        result = nil
        assert_enqueued_emails(2) do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert_enqueued_email_with MembershipMailer, :donation_receipt, args: [result.data]
        assert_enqueued_email_with AdminMailer, :anonymous_donation, args: [result.data]
      end

      # Legacy is still live, still takes donations through its own payment links,
      # and still emails its own donors.
      test "emails nothing for a donation this app did not take" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(metadata: {}))

        assert_no_enqueued_emails do
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end
      end

      # Task 6 revision: a donation with no collected email still gets exactly
      # one email out -- the admin notice, not a donor receipt there is no
      # address for. Asserting which mailer fired (not just a bare count)
      # is what would catch a regression that swapped in a donor receipt
      # instead.
      test "emails no donor receipt when Stripe collected no address, but still notifies the owner" do
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(customer_details: stub(email: nil)))

        result = nil
        assert_enqueued_emails(1) do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert_enqueued_email_with AdminMailer, :anonymous_donation, args: [result.data]
      end

      # Finding 3, fix round 1: every other donation-flow test above leaves
      # the donation userless, so all of them exercise deliver_receipt's
      # anonymous_donation branch. This one attaches a real signed-in donor
      # end-to-end through RecordDonation.call, so the OTHER branch --
      # new_donation for an identified donor -- has real service-level
      # coverage too. If that branch inverted (a named donor's notice saying
      # "anonymous"), this is the test that would catch it.
      test "notifies the owner with new_donation, not anonymous_donation, for a donation from a signed-in donor" do
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(metadata: {
            "origin_domain" => "books", "app_user_id" => user.id.to_s,
            "origin_app" => ::Services::Billing::StripeClient::ORIGIN_APP
          }))

        result = nil
        assert_enqueued_emails(2) do
          result = RecordDonation.call(checkout_session_id: "cs_test_1")
        end

        assert_equal user, result.data.user
        assert_enqueued_email_with MembershipMailer, :donation_receipt, args: [result.data]
        assert_enqueued_email_with AdminMailer, :new_donation, args: [result.data]
      end
    end
  end
end
