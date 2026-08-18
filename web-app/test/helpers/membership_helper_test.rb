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

  test "a cancelled membership says it stays active until the paid-through date" do
    membership = memberships(:google_user_canceled_in_grace)

    assert_match(/stays active until|access runs until/, membership_status_sentence(membership))
  end

  test "a comp with no end date says it does not expire" do
    assert_equal "Your membership does not expire.", membership_status_sentence(memberships(:editor_user_comped))
  end
end
