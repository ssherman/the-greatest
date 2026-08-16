require "test_helper"

# Compact class definition on purpose, matching every other service test in
# this codebase. `module Services; module Billing; class ...` would put
# Services::Billing into the lexical scope, where a bare `Membership` searches
# Services::Billing::Membership first -- the constant-shadowing shape that has
# produced confusing NameErrors here three times.
class Services::Billing::VerifyMigrationTest < ActiveSupport::TestCase
  # The three legacy reads are the only seams that touch the replica; every
  # test stubs all three, because no legacy test database exists.
  def verify(subscription_ids: [], paid_user_ids: [], donation_intent_ids: [])
    service = Services::Billing::VerifyMigration.new
    service.stubs(:legacy_subscription_ids).returns(subscription_ids)
    service.stubs(:legacy_paid_user_ids).returns(paid_user_ids)
    service.stubs(:legacy_donation_intent_ids).returns(donation_intent_ids)
    service.call
  end

  test "succeeds when every legacy record has a counterpart" do
    result = verify(
      subscription_ids: ["sub_regular_monthly", "sub_google_yearly"],
      paid_user_ids: [users(:password_user).id],
      donation_intent_ids: ["pi_regular_gift"]
    )

    assert result.success?
    assert_empty result.data[:missing_subscriptions]
    assert_empty result.data[:missing_grants]
    assert_empty result.data[:missing_donations]
  end

  test "reports a legacy subscription with no membership" do
    result = verify(subscription_ids: ["sub_regular_monthly", "sub_vanished"])

    assert_not result.success?
    assert_equal ["sub_vanished"], result.data[:missing_subscriptions]
  end

  test "reports a paid user with no legacy grant" do
    result = verify(paid_user_ids: [users(:password_user).id, users(:contractor_user).id])

    assert_not result.success?
    assert_equal [users(:contractor_user).id], result.data[:missing_grants]
  end

  test "reports a legacy donation with no counterpart" do
    result = verify(donation_intent_ids: ["pi_regular_gift", "pi_never_imported"])

    assert_not result.success?
    assert_equal ["pi_never_imported"], result.data[:missing_donations]
  end

  test "lists unattached memberships" do
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan", stripe_customer_id: "cus_orphan"
    )

    result = verify
    row = result.data[:unattached].find { |r| r[:id] == orphan.id }

    assert_not_nil row
    assert_equal "cus_orphan", row[:stripe_customer_id]
    assert_equal "active", row[:status]
  end

  test "reports users holding both a legacy grant and a stripe membership" do
    Membership.create!(user: users(:regular_user), source: :legacy, status: :active)

    result = verify(paid_user_ids: [users(:regular_user).id, users(:password_user).id])

    # regular_user has regular_user_monthly (stripe) plus the new legacy row;
    # password_user has only password_user_legacy, so it is not an overlap.
    assert_equal [users(:regular_user).id], result.data[:overlap_user_ids]
  end

  test "an unattached membership alone does not fail the run" do
    Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_two", stripe_customer_id: "cus_orphan_two"
    )

    assert verify.success?
  end
end
