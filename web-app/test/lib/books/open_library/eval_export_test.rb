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
        isbn13 = identifiers(:war_and_peace_isbn13)
        asin = identifiers(:war_and_peace_asin)
        io = StringIO.new

        EvalExport.call(io: io)
        record = io.string.lines.map { |line| JSON.parse(line) }
          .find { |r| r["book_id"] == isbn13.identifiable_id }

        assert_includes record["isbn13"], isbn13.value
        assert_includes record["asin"], asin.value
        refute_includes record["isbn13"], asin.value
        refute_includes record["asin"], isbn13.value
      end

      test "does not set a scope order that find_each throws away" do
        # `find_each` always batches by primary key and warns that it is
        # discarding any scope order it was handed. A `.order(:id)` in front of
        # it is therefore a no-op that emits a warning on every run.
        captured = StringIO.new
        original_logger = ActiveRecord::Base.logger
        ActiveRecord::Base.logger = ActiveSupport::Logger.new(captured)

        begin
          EvalExport.call(io: StringIO.new)
        ensure
          ActiveRecord::Base.logger = original_logger
        end

        refute_match(/Scoped order is ignored/, captured.string)
      end

      test "exports books in ascending id order" do
        io = StringIO.new

        EvalExport.call(io: io)
        ids = io.string.lines.map { |line| JSON.parse(line)["book_id"] }

        assert_equal ids.sort, ids
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
