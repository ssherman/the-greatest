require "test_helper"

class MembershipHelperTest < ActionView::TestCase
  include MembershipHelper

  test "a nil membership reads as not a member" do
    assert_equal "You are not currently a member.", membership_status_sentence(nil)
  end

  test "an active stripe membership names its renewal date" do
    membership = memberships(:regular_user_monthly)

    sentence = membership_status_sentence(membership)

    assert_match(/renews on/, sentence)
    assert_match(membership.current_period_end.to_fs(:long), sentence)
  end

  test "a cancelled membership in its grace period says it stays active until the paid-through date" do
    membership = memberships(:google_user_canceled_in_grace)

    # Pinned to the exact sentence this branch produces -- not an alternation
    # that would also match the "has ended and access runs until" branch below,
    # which would let a regression where this branch fires the wrong copy (or
    # is deleted entirely, falling through to the next elsif) pass unnoticed.
    assert_equal(
      "Your membership is cancelled and stays active until #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end

  test "a cancelled membership whose grace period has passed says it ended, not that it stays active" do
    membership = memberships(:canceled_and_expired)

    assert_equal(
      "Your membership was cancelled and ended on #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end

  test "a canceled stripe membership without the scheduled-cancel flag says access runs until the paid-through date" do
    membership = memberships(:canceled_no_grace_flag)

    assert_equal(
      "Your membership has ended and access runs until #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end

  test "a canceled stripe membership without the scheduled-cancel flag, past its paid-through date, says it ended" do
    membership = memberships(:canceled_no_grace_flag_and_expired)

    assert_equal(
      "Your membership has ended; access ended on #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end

  test "a comp with no end date says it does not expire" do
    assert_equal "Your membership does not expire.", membership_status_sentence(memberships(:editor_user_comped))
  end

  test "a comp with a future end date says when it runs until" do
    membership = memberships(:comped_with_future_end)

    assert_equal(
      "Your membership runs until #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end

  test "a comp whose end date has passed says it ended, not that it still runs until that date" do
    membership = memberships(:comped_expired)

    assert_equal(
      "Your membership ended on #{membership.current_period_end.to_fs(:long)}.",
      membership_status_sentence(membership)
    )
  end
end
