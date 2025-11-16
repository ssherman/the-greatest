require "test_helper"

class Admin::RankedListsHelperTest < ActionView::TestCase
  test "penalty_badge_class returns badge-success for penalty less than 10" do
    assert_equal "badge-success", penalty_badge_class(5)
    assert_equal "badge-success", penalty_badge_class(9.9)
    assert_equal "badge-success", penalty_badge_class(0)
  end

  test "penalty_badge_class returns badge-warning for penalty 10-24" do
    assert_equal "badge-warning", penalty_badge_class(10)
    assert_equal "badge-warning", penalty_badge_class(15)
    assert_equal "badge-warning", penalty_badge_class(24.9)
  end

  test "penalty_badge_class returns badge-error for penalty 25 and above" do
    assert_equal "badge-error", penalty_badge_class(25)
    assert_equal "badge-error", penalty_badge_class(50)
    assert_equal "badge-error", penalty_badge_class(100)
  end
end
