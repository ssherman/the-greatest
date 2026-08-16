require "test_helper"

class Services::BooksMigration::MembershipMigratorTest < ActiveSupport::TestCase
  # legacy_each is stubbed in every migrator test — no legacy test database
  # exists, and none is required. See the plan's Global Constraints.
  def run_migrator(rows)
    m = Services::BooksMigration::MembershipMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy users row as record.attributes yields it (String keys). Only the
  # three columns this migrator reads need to be realistic.
  def legacy_attrs(overrides = {})
    {"id" => users(:contractor_user).id, "paid" => true, "email" => "supporter@example.com"}.merge(overrides)
  end

  test "grants a never-expiring legacy membership to a paid user" do
    result = run_migrator([legacy_attrs])
    assert result[:success], result[:error]

    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    assert_not_nil membership
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
    assert_equal "Legacy early supporter", membership.note
    assert_nil membership.stripe_subscription_id
  end

  test "is idempotent across two runs" do
    run_migrator([legacy_attrs])
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs])
      assert result[:success], result[:error]
    end
  end

  test "does not overwrite a note an admin has edited" do
    run_migrator([legacy_attrs])
    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    membership.update!(note: "Verified by hand")

    run_migrator([legacy_attrs])
    assert_equal "Verified by hand", membership.reload.note
  end

  test "skips a legacy user that does not exist in the new users table" do
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs("id" => 999_999_999)])
      assert result[:success], result[:error]
    end
  end

  test "skips a row that is not flagged paid" do
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs("paid" => false)])
      assert result[:success], result[:error]
    end
  end

  test "leaves an existing stripe membership for the same user untouched" do
    stripe_membership = memberships(:regular_user_monthly)
    run_migrator([legacy_attrs("id" => users(:regular_user).id)])

    assert_equal "active", stripe_membership.reload.status
    assert_equal "sub_regular_monthly", stripe_membership.stripe_subscription_id
    assert_equal "stripe", stripe_membership.source
    # Both rows coexist: this is the 6-overlap case, and it is intended.
    assert_equal 1, Membership.source_legacy.where(user_id: users(:regular_user).id).count
  end

  test "reactivates a legacy grant an admin previously revoked" do
    run_migrator([legacy_attrs])
    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    membership.update!(status: :canceled, current_period_end: 1.day.ago)

    run_migrator([legacy_attrs])
    membership.reload
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
  end
end
