require "test_helper"

module Books
  module WorldCat
    class IsbnExportTest < ActiveSupport::TestCase
      test "writes each distinct work ISBN-13 once and returns the count" do
        book = books_books(:crime_and_punishment)
        ::Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "9780140449136")
        ::Identifier.create!(identifiable: books_books(:got), identifier_type: :books_work_isbn13, value: "9780140449136")
        io = StringIO.new
        count = IsbnExport.call(io: io)
        lines = io.string.lines.map(&:strip)
        assert_equal lines.uniq.sort, lines.sort
        assert_includes lines, "9780140447934" # the war_and_peace fixture
        assert_includes lines, "9780140449136"
        assert_equal lines.size, count
      end

      test "skips E2E leftover books" do
        leftover = ::Books::Book.create!(title: "E2E Smoke Book 1700000000000")
        ::Identifier.create!(identifiable: leftover, identifier_type: :books_work_isbn13, value: "9780306406157")
        io = StringIO.new
        IsbnExport.call(io: io)
        assert_not_includes io.string, "9780306406157"
      end

      test "skips identifiers whose check digit is wrong" do
        ::Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_isbn13, value: "9780000000001")
        io = StringIO.new
        count = IsbnExport.call(io: io)
        assert_not_includes io.string, "9780000000001"
        assert_equal io.string.lines.size, count
      end

      test "writes the normalised ISBN-13 and collapses spellings of the same ISBN" do
        book = books_books(:crime_and_punishment)
        ::Identifier.create!(identifiable: book, identifier_type: :books_work_isbn13, value: "978-0-306-40615-7")
        ::Identifier.create!(identifiable: books_books(:got), identifier_type: :books_work_isbn13, value: "9780306406157")
        io = StringIO.new
        IsbnExport.call(io: io)
        lines = io.string.lines.map(&:strip)
        assert_equal 1, lines.count("9780306406157")
        assert_not_includes io.string, "-"
      end
    end
  end
end
