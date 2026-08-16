require "test_helper"

class Services::BooksMigration::DonationMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::DonationMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_attrs(overrides = {})
    {
      "id" => 4001,
      "user_id" => users(:contractor_user).id,
      "amount" => 2500,
      "status" => 1,
      "stripe_payment_id" => "pi_legacy_4001",
      "created_at" => Time.utc(2024, 3, 14, 9, 30),
      "updated_at" => Time.utc(2024, 3, 14, 9, 30)
    }.merge(overrides)
  end

  test "maps the legacy columns and preserves the donation date" do
    result = run_migrator([legacy_attrs])
    assert result[:success], result[:error]

    donation = Donation.find_by(stripe_payment_intent_id: "pi_legacy_4001")
    assert_not_nil donation
    assert_equal 2500, donation.amount_cents
    assert_equal "succeeded", donation.status
    assert_equal "usd", donation.currency
    assert_equal "books", donation.domain
    assert_equal users(:contractor_user).id, donation.user_id
    assert_equal Time.utc(2024, 3, 14, 9, 30), donation.created_at
  end

  test "copies each legacy status integer to the same symbol" do
    run_migrator([
      legacy_attrs("id" => 4002, "status" => 0, "stripe_payment_id" => "pi_pending"),
      legacy_attrs("id" => 4003, "status" => 2, "stripe_payment_id" => "pi_failed_import"),
      legacy_attrs("id" => 4004, "status" => 3, "stripe_payment_id" => "pi_refunded")
    ])

    assert_equal "pending", Donation.find_by(stripe_payment_intent_id: "pi_pending").status
    assert_equal "failed", Donation.find_by(stripe_payment_intent_id: "pi_failed_import").status
    assert_equal "refunded", Donation.find_by(stripe_payment_intent_id: "pi_refunded").status
  end

  test "is idempotent across two runs" do
    run_migrator([legacy_attrs])
    assert_no_difference -> { Donation.count } do
      result = run_migrator([legacy_attrs])
      assert result[:success], result[:error]
    end
  end

  test "never rewrites a donation that already exists" do
    existing = donations(:regular_user_gift)
    run_migrator([legacy_attrs("stripe_payment_id" => existing.stripe_payment_intent_id, "amount" => 99)])

    assert_equal 2500, existing.reload.amount_cents
  end

  test "imports unattached when the donor no longer exists" do
    result = run_migrator([legacy_attrs("user_id" => 999_999_999)])
    assert result[:success], result[:error]

    assert_nil Donation.find_by(stripe_payment_intent_id: "pi_legacy_4001").user_id
  end

  test "aborts the run naming the legacy id when a payment intent id is missing" do
    result = run_migrator([legacy_attrs("stripe_payment_id" => nil)])

    assert_not result[:success]
    assert_includes result[:error], "4001"
  end
end
