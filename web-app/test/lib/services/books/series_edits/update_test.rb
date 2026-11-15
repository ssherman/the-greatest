require "test_helper"

module Services
  module Books
    module SeriesEdits
      class UpdateTest < ActiveSupport::TestCase
        setup do
          @series = books_series(:asoiaf)
        end

        test "update renames" do
          result = Update.call(series: @series, attrs: {"title" => "Renamed"})

          assert result.success?
          assert_equal "Renamed", @series.reload.title
        end

        test "update refuses a goodreads id that is not digits" do
          ["130291-batman-2011", "https://www.goodreads.com/series/130291-batman-2011"].each do |value|
            result = Update.call(series: @series, attrs: {"goodreads_series_id" => value})
            assert_not result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["goodreads_series_id must be the digits from the series URL (goodreads.com/series/<digits>-name)."], result.errors
          end
          assert_nil @series.identifiers.find_by(identifier_type: :books_series_goodreads_id, source: :admin)
        end

        test "representative must be a book in the series" do
          outsider = books_books(:war_and_peace)
          result = Update.call(series: @series, attrs: {"representative_book_id" => outsider.id})

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["Book #{outsider.id} is not in this series."], result.errors
          assert_nil @series.reload.representative_book_id
        end

        test "representative can be set to a book in the series" do
          book = books_series_books(:asoiaf_got).book
          result = Update.call(series: @series, attrs: {"representative_book_id" => book.id})

          assert result.success?
          assert_equal book.id, @series.reload.representative_book_id
        end

        test "null clears the representative" do
          @series.update!(representative_book: books_series_books(:asoiaf_got).book)
          result = Update.call(series: @series, attrs: {"representative_book_id" => nil})

          assert result.success?
          assert_nil @series.reload.representative_book_id
        end

        test "goodreads id can be set when missing" do
          result = Update.call(series: @series, attrs: {"goodreads_series_id" => "888001"})

          assert result.success?
          identifier = @series.identifiers.sole
          assert_equal "888001", identifier.value
          assert_equal "admin", identifier.source
        end

        test "goodreads id cannot replace an existing one" do
          @series.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "888002", source: :goodreads)
          result = Update.call(series: @series, attrs: {"goodreads_series_id" => "888003"})

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["Series #{@series.id} already has Goodreads series id 888002."], result.errors
          assert_equal ["888002"], @series.identifiers.pluck(:value)
        end

        test "a nil or blank goodreads id is refused" do
          [nil, " "].each do |value|
            result = Update.call(series: @series, attrs: {"goodreads_series_id" => value})
            assert_not result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["goodreads_series_id must not be blank."], result.errors
          end
        end

        test "goodreads id another series holds is refused" do
          other = books_series(:live_target)
          other.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "888004", source: :goodreads)
          result = Update.call(series: @series, attrs: {"goodreads_series_id" => "888004"})

          assert_not result.success?
          assert_equal ["Goodreads series id 888004 already belongs to series #{other.id}."], result.errors
        end

        test "a deleted series cannot be edited" do
          series = books_series(:junk_deleted)
          result = Update.call(series: series, attrs: {"title" => "Nope"})

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["Series #{series.id} is deleted."], result.errors
        end

        test "a merged series cannot be edited" do
          series = books_series(:merged_into_live)
          result = Update.call(series: series, attrs: {"title" => "Nope"})

          assert_not result.success?
          assert_equal ["Series #{series.id} was merged into series #{series.merged_into_id}."], result.errors
        end
      end
    end
  end
end
