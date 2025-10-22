require "test_helper"

module Music
  class ListsHelperTest < ActionView::TestCase
    test "penalty_badge_class returns success for low penalties" do
      assert_equal "badge-success", penalty_badge_class(5)
      assert_equal "badge-success", penalty_badge_class(9.9)
    end

    test "penalty_badge_class returns warning for medium penalties" do
      assert_equal "badge-warning", penalty_badge_class(10)
      assert_equal "badge-warning", penalty_badge_class(15)
      assert_equal "badge-warning", penalty_badge_class(24.9)
    end

    test "penalty_badge_class returns error for high penalties" do
      assert_equal "badge-error", penalty_badge_class(25)
      assert_equal "badge-error", penalty_badge_class(50)
      assert_equal "badge-error", penalty_badge_class(100)
    end
  end
end
