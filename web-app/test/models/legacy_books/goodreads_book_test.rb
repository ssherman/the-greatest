require "test_helper"

module LegacyBooks
  class GoodreadsBookTest < ActiveSupport::TestCase
    test "reads from the legacy goodreads_books table" do
      assert_equal "goodreads_books", GoodreadsBook.table_name
    end

    # .allocate, not .new: in test LegacyBooks::Record falls back to the app's
    # own connection, which has no goodreads_books table (see blog_post_test.rb).
    test "is read only" do
      assert_predicate GoodreadsBook.allocate, :readonly?
    end
  end
end
