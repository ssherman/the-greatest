require "test_helper"

module LegacyBooks
  class ReadingGoalBookTest < ActiveSupport::TestCase
    test "uses the explicit legacy table through the read-only record base" do
      ReadingGoalBook.stubs(:connection).raises("legacy connection must not open in tests")

      assert_equal "reading_goal_books", ReadingGoalBook.table_name
      assert_operator ReadingGoalBook, :<, Record
    end
  end
end
