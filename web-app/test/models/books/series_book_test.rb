require "test_helper"

# == Schema Information
#
# Table name: books_series_books
#
#  id             :bigint           not null, primary key
#  numbered       :boolean          default(TRUE), not null
#  position       :decimal(8, 2)
#  position_label :string
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  book_id        :bigint           not null
#  series_id      :bigint           not null
#
# Indexes
#
#  index_books_series_books_on_book_id                (book_id)
#  index_books_series_books_on_series_id              (series_id)
#  index_books_series_books_on_series_id_and_book_id  (series_id,book_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (series_id => books_series.id)
#

module Books
  class SeriesBookTest < ActiveSupport::TestCase
    test "is valid with a series and book" do
      sb = Books::SeriesBook.new(series: books_series(:asoiaf), book: books_books(:war_and_peace))
      assert_predicate sb, :valid?
    end

    test "defaults numbered to true" do
      assert_predicate Books::SeriesBook.new, :numbered?
    end

    test "supports decimal positions" do
      assert_equal 1.5, books_series_books(:asoiaf_novella).position
    end

    test "is unique per series and book" do
      dup = Books::SeriesBook.new(series: books_series(:asoiaf), book: books_books(:got))
      assert_not dup.valid?
      assert_includes dup.errors[:series_id], "has already been taken"
    end

    test "series lists its books ordered by position" do
      assert_equal [ books_books(:got), books_series_books(:asoiaf_novella).book, books_books(:clash) ],
        books_series(:asoiaf).books.to_a
    end

    test "resolved_representative_book falls back to the first member" do
      assert_equal books_books(:got), books_series(:asoiaf).resolved_representative_book
    end
  end
end
