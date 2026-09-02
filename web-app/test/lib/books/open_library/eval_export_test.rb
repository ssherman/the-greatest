# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class EvalExportTest < ActiveSupport::TestCase
      test "writes one JSON line per book" do
        io = StringIO.new

        count = EvalExport.call(io: io)

        lines = io.string.lines
        assert_equal ::Books::Book.count, count
        assert_equal count, lines.size
      end

      test "each line carries the fields the evaluation pool needs" do
        io = StringIO.new

        EvalExport.call(io: io)
        record = JSON.parse(io.string.lines.first)

        assert record.key?("book_id")
        assert record.key?("title")
        assert record.key?("author_names")
        assert record.key?("isbn13")
        assert record.key?("goodreads_id")
        assert record.key?("existing_ol_work_keys")
      end

      test "includes author names for a book that has authors" do
        book = ::Books::Book.joins(:book_authors).first
        io = StringIO.new

        EvalExport.call(io: io)
        record = io.string.lines.map { |line| JSON.parse(line) }.find { |r| r["book_id"] == book.id }

        assert_equal book.authors.map(&:name).sort, record["author_names"].sort
      end

      test "groups identifiers by type" do
        identifier = Identifier.find_by(
          identifiable_type: "Books::Book",
          identifier_type: :books_work_isbn13
        )
        skip "no isbn13 identifier fixture" if identifier.nil?
        io = StringIO.new

        EvalExport.call(io: io)
        record = io.string.lines.map { |line| JSON.parse(line) }
          .find { |r| r["book_id"] == identifier.identifiable_id }

        assert_includes record["isbn13"], identifier.value
      end

      test "emits an empty array rather than nil for a book with no identifiers" do
        io = StringIO.new

        EvalExport.call(io: io)
        record = JSON.parse(io.string.lines.first)

        assert_kind_of Array, record["isbn13"]
        assert_kind_of Array, record["existing_ol_work_keys"]
      end
    end
  end
end
