require "test_helper"

module Services
  module Billing
    class RecordDonationTest < ActiveSupport::TestCase
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
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(metadata: {"origin_domain" => "books", "app_user_id" => user.id.to_s}))

        assert_equal user, RecordDonation.call(checkout_session_id: "cs_test_1").data.user
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
    end
  end
end
