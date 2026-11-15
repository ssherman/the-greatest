require "test_helper"

module Services
  module Books
    module SeriesEdits
      class DeleteTest < ActiveSupport::TestCase
        setup do
          @series = ::Books::Series.create!(title: "Delete Me")
          @series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "555001", source: :goodreads)
          @a = books_books(:war_and_peace)
          @b = books_books(:crime_and_punishment)
          ::Books::SeriesBook.create!(series: @series, book: @a, position: 1)
          ::Books::SeriesBook.create!(series: @series, book: @b, position: 2)
        end

        test "delete removes the links and keeps the row and its identifiers" do
          result = Delete.call(series: @series)

          assert result.success?
          assert_equal 2, result.data[:book_count]
          assert_equal @series, result.data[:series]
          @series.reload
          assert @series.deleted?
          assert_equal 0, @series.series_books.count
          assert_equal 1, @series.identifiers.count
        end

        test "delete clears the representative" do
          @series.update!(representative_book: @a)
          Delete.call(series: @series)
          assert_nil @series.reload.representative_book_id
        end

        test "dry run changes nothing and reports book_count" do
          result = Delete.call(series: @series, dry_run: true)

          assert result.success?
          assert_equal 2, result.data[:book_count]
          assert_not @series.reload.deleted?
          assert_equal 2, @series.series_books.count
        end

        test "deleting a deleted series is unprocessable" do
          Delete.call(series: @series)
          result = Delete.call(series: ::Books::Series.find(@series.id))

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["Series #{@series.id} is already deleted."], result.errors
        end

        test "a stale in-memory series is re-checked after the lock" do
          stale = ::Books::Series.find(@series.id)
          Delete.call(series: @series)

          assert_not Delete.call(series: stale).success?
        end
      end
    end
  end
end
