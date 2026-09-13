# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class EvalExportTest < ActiveSupport::TestCase
      test "writes one JSON line per exported book" do
        io = StringIO.new

        count = EvalExport.call(io: io)

        lines = io.string.lines
        assert_equal ::Books::Book.count, count
        assert_equal count, lines.size
      end

      test "the returned count is what was written, not what was scanned" do
        ::Books::Book.create!(title: "E2E Smoke Book 1784091457158")
        io = StringIO.new

        count = EvalExport.call(io: io)

        assert_equal ::Books::Book.count - 1, count
        assert_equal count, io.string.lines.size
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

      test "leaves out the books Playwright left behind" do
        # The admin E2E specs title their fixtures "E2E Smoke Book #{Date.now()}"
        # and nothing cleans them up, so 126 sit in the development database.
        # They are eligible for every stratum in the evaluation pool, and the
        # draw before this filter spent 20 of 450 hand-labelling slots on them.
        junk = ::Books::Book.create!(title: "E2E Smoke Book 1784091457158")
        io = StringIO.new

        EvalExport.call(io: io)
        ids = io.string.lines.map { |line| JSON.parse(line)["book_id"] }

        refute_includes ids, junk.id
      end

      test "keeps a real book whose title merely contains digits" do
        # The filter keys on a trailing epoch-millisecond stamp, not on digits.
        # Without this control it could be "drop any title with a number in it".
        real = ::Books::Book.create!(title: "1984 Reissued 2019")
        io = StringIO.new

        EvalExport.call(io: io)
        ids = io.string.lines.map { |line| JSON.parse(line)["book_id"] }

        assert_includes ids, real.id
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

      # Not evidence that removing `.order(:id)` was safe -- `find_each` batches
      # by primary key whatever the scope says, so this holds either way. It
      # guards the contract itself: the evaluation pool's sampler reads this
      # file positionally, so a rewrite away from `find_each` must not silently
      # change the order. The scoped-order test above is what covers the removal.
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
