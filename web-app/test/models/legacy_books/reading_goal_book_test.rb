require "test_helper"

# == Schema Information
#
# Table name: reading_goal_books
#
#  id              :bigint           not null, primary key
#  read_date       :date
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  book_id         :bigint           not null
#  reading_goal_id :bigint           not null
#
# Indexes
#
#  index_reading_goal_books_on_book_id          (book_id)
#  index_reading_goal_books_on_reading_goal_id  (reading_goal_id)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books.id)
#  fk_rails_...  (reading_goal_id => reading_goals.id)
#
module LegacyBooks
  class ReadingGoalBookTest < ActiveSupport::TestCase
    test "uses the explicit legacy table through the read-only record base" do
      ReadingGoalBook.stubs(:connection).raises("legacy connection must not open in tests")

      assert_equal "reading_goal_books", ReadingGoalBook.table_name
      assert_operator ReadingGoalBook, :<, Record
    end
  end
end
