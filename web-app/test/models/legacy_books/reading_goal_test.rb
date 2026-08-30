require "test_helper"

module LegacyBooks
  class ReadingGoalTest < ActiveSupport::TestCase
    test "uses the explicit legacy table through the read-only record base" do
      ReadingGoal.stubs(:connection).raises("legacy connection must not open in tests")

      assert_equal "reading_goals", ReadingGoal.table_name
      assert_operator ReadingGoal, :<, Record
    end
  end
end
