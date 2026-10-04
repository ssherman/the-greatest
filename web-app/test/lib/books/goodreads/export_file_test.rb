# frozen_string_literal: true

require "test_helper"

module Books
  module Goodreads
    class ExportFileTest < ActiveSupport::TestCase
      HEADER = "Book Id,Title,Author,Exclusive Shelf\n"

      test "columns are read by header name in any order" do
        result = ExportFile.parse("Exclusive Shelf,Author,Title,Book Id\nread,Leo Tolstoy,War and Peace,656\n")

        row = result.data[:rows].sole
        assert_equal [656, "War and Peace", "Leo Tolstoy", "read"], [row.goodreads_book_id, row.title, row.primary_author, row.exclusive_shelf]
      end

      test "a UTF-8 byte order mark is stripped" do
        result = ExportFile.parse("\xEF\xBB\xBF".b + "#{HEADER}656,War and Peace,Leo Tolstoy,read\n".b)

        assert result.success?, result.errors.inspect
        assert_equal 656, result.data[:rows].sole.goodreads_book_id
      end

      test "a Windows-1252 file is read as Windows-1252" do
        result = ExportFile.parse("#{HEADER}1,Caf\xE9 Stories,Jos\xE9 Saramago,read\n".b)

        assert_equal ["Café Stories", "José Saramago"], result.data[:rows].sole.then { |row| [row.title, row.primary_author] }
      end

      test "bytes that are neither UTF-8 nor Windows-1252 are scrubbed" do
        result = ExportFile.parse("#{HEADER}1,Bad\x81Title,Ann Author,read\n".b)

        assert_equal "BadTitle", result.data[:rows].sole.title
      end

      test "a file without the export headers is refused" do
        result = ExportFile.parse("Book Id,Title,Author\n1,War and Peace,Leo Tolstoy\n")

        assert_not result.success?
        assert_equal ["missing Goodreads export headers: Exclusive Shelf"], result.errors
      end

      test "a spreadsheet renamed to .csv is refused" do
        result = ExportFile.parse("PK\x03\x04\x14\x00\x06\x00\x08\x00\x00\x00!\x00\xA4\x9B\"\x8F\x01\x00".b)

        assert_not result.success?
      end

      test "an empty file is refused" do
        assert_not ExportFile.parse("").success?
      end

      test "a header-only file has no rows" do
        result = ExportFile.parse(HEADER)

        assert result.success?
        assert_equal [], result.data[:rows]
      end

      test "keeps a row with a stray quote" do
        result = ExportFile.parse(%(#{HEADER}1,The "Best" Book,Ann Author,read\n2,Second,Ann Author,read\n))

        assert result.success?, result.errors.inspect
        assert_equal ['The "Best" Book', "Second"], result.data[:rows].map(&:title)
      end

      test "a row whose columns no longer line up with the header is failed, and nothing in it is trusted" do
        csv = %(#{HEADER}656,"War "and", Peace",Leo Tolstoy,read\n3,Short Row\n2,Second,Ann Author,read\n)

        rows = ExportFile.parse(csv).data[:rows]

        rows.first(2).each do |row|
          assert_equal [false, ["columns do not line up with the header"], {}, nil],
            [row.valid?, row.errors, row.raw, row.title]
        end
        assert_equal "Second", rows.last.title
      end

      test "NUL bytes are removed" do
        assert_equal "Nul Title", ExportFile.parse("#{HEADER}1,Nul\u0000 Title,Ann Author,read\n").data[:rows].sole.title
      end

      test "a UTF-8 file with one stray byte stays UTF-8" do
        rows = ExportFile.parse("#{HEADER}1,Cien años de soledad,Gabriel García Márquez,read\n2,Bad\xFFByte,Ann Author,read\n".b).data[:rows]

        assert_equal ["Cien años de soledad", "Gabriel García Márquez", "BadByte"], [rows.first.title, rows.first.primary_author, rows.last.title]
      end

      test "a Windows-1252 file with an undefined byte keeps its accents" do
        result = ExportFile.parse("#{HEADER}1,Caf\xE9 \x81Stories,Jos\xE9 Saramago,read\n".b)

        assert_equal ["Café Stories", "José Saramago"], result.data[:rows].sole.then { |row| [row.title, row.primary_author] }
      end

      test "numbers rows by record, so a review spanning lines is one row" do
        csv = "Book Id,Title,Author,Exclusive Shelf,My Review\n" \
          "1,First,Ann Author,read,\"line one\nline two, with a comma\"\n" \
          "2,Second,Ann Author,read,\n"

        rows = ExportFile.parse(csv).data[:rows]

        assert_equal [[1, "First"], [2, "Second"]], rows.map { |row| [row.row_number, row.title] }
        assert_equal "line one\nline two, with a comma", rows.first.review_body
      end
    end
  end
end
