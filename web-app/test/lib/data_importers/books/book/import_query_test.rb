# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Books
    module Book
      class ImportQueryTest < ActiveSupport::TestCase
        test "valid with a title alone" do
          query = ImportQuery.new(title: "War and Peace")

          assert query.valid?
        end

        test "valid with an identifier alone (title nil)" do
          query = ImportQuery.new(title: nil, isbn13: ["9780140447934"])

          assert query.valid?
        end

        test "valid with an open_library_work_key alone (title nil)" do
          query = ImportQuery.new(title: nil, open_library_work_key: "OL262758W")

          assert query.valid?
        end

        test "invalid with neither title nor an identifier" do
          query = ImportQuery.new(title: nil)

          refute query.valid?
        end

        test "invalid when title is blank string and no identifier" do
          query = ImportQuery.new(title: "")

          refute query.valid?
        end

        test "year must be an Integer when present" do
          query = ImportQuery.new(title: "War and Peace", year: "1925")

          refute query.valid?
        end

        test "valid when year is an Integer" do
          query = ImportQuery.new(title: "War and Peace", year: 1925)

          assert query.valid?
        end

        test "title must be a String when present" do
          query = ImportQuery.new(title: 12345)

          refute query.valid?
        end

        test "array attributes default to empty when omitted" do
          query = ImportQuery.new(title: "War and Peace")

          assert_equal [], query.author_names
          assert_equal [], query.isbn13
          assert_equal [], query.isbn10
          assert_equal [], query.asin
          assert_equal [], query.goodreads_id
        end

        test "array attributes coerce nil to empty" do
          query = ImportQuery.new(title: "War and Peace", author_names: nil, isbn13: nil, isbn10: nil, asin: nil, goodreads_id: nil)

          assert_equal [], query.author_names
          assert_equal [], query.isbn13
          assert_equal [], query.isbn10
          assert_equal [], query.asin
          assert_equal [], query.goodreads_id
        end

        test "array attributes wrap a bare String in an Array" do
          query = ImportQuery.new(title: "War and Peace", author_names: "Leo Tolstoy", isbn13: "9780140447934")

          assert_equal ["Leo Tolstoy"], query.author_names
          assert_equal ["9780140447934"], query.isbn13
        end

        test "validate! raises ArgumentError naming the problem when neither title nor identifier is present" do
          query = ImportQuery.new(title: nil)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_match(/title/i, error.message)
        end

        test "validate! raises ArgumentError naming the problem when year is the wrong type" do
          query = ImportQuery.new(title: "War and Peace", year: "1925")

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_match(/year/i, error.message)
        end

        test "validate! raises ArgumentError naming the problem when title is the wrong type" do
          query = ImportQuery.new(title: 12345)

          error = assert_raises(ArgumentError) do
            query.validate!
          end

          assert_match(/title/i, error.message)
        end

        test "validate! does not raise when the query is valid" do
          query = ImportQuery.new(title: "War and Peace")

          assert_nothing_raised do
            query.validate!
          end
        end

        test "open_library_work_key is accessible as a reader" do
          query = ImportQuery.new(title: nil, open_library_work_key: "OL262758W")

          assert_equal "OL262758W", query.open_library_work_key
        end

        test "year is accessible as a reader" do
          query = ImportQuery.new(title: "War and Peace", year: 1869)

          assert_equal 1869, query.year
        end
      end
    end
  end
end
