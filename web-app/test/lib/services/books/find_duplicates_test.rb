# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class FindDuplicatesTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
        @decision = match_decisions(:low_confidence_book_match)
        @finder = mock("finder")
      end

      def call(book = @book)
        FindDuplicates.call(book: book, finder: @finder)
      end

      test "resolves the book against the rest of the catalog: its own fields as the query, verify, subject and exclude set" do
        isbn = identifiers(:war_and_peace_isbn13).value
        asin = identifiers(:war_and_peace_asin).value
        @finder.expects(:call).with do |args|
          query = args[:query]
          query.title == "War and Peace" && query.author_names == ["Leo Tolstoy"] && query.year == 1869 &&
            query.isbn13 == [isbn] && query.asin == [asin] && query.open_library_work_key.nil? &&
            args[:verify] == true && args[:subject] == @book && args[:exclude] == @book
        end.returns(DataImporters::Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule))

        result = nil
        assert_no_difference("DuplicateCandidate.count") { result = call }

        assert result.success?
        assert result.data[:match].unmatched?
        assert_nil result.data[:pair]
      end

      test "the book's Open Library key travels as open_library_work_key" do
        @finder.expects(:call).with { |args| args[:query].open_library_work_key == "OL262758W" }
          .returns(DataImporters::Match.new(outcome: :unmatched))

        assert call(@other).success?
      end

      test "a match flags the pair as bulk_verify with the decision's reason and the decision itself, and returns it" do
        @finder.stubs(:call).returns(
          DataImporters::Match.new(outcome: :matched, record: @other, confidence: :high, decided_by: :ai, reason: "Same work, other title.", decision: @decision)
        )

        result = nil
        assert_difference("DuplicateCandidate.count", 1) { result = call }

        pair = result.data[:pair]
        assert_equal DuplicateCandidate.last, pair
        assert_equal ["Books::Book", [@book.id, @other.id].min, [@book.id, @other.id].max], [pair.item_type, pair.item_a_id, pair.item_b_id]
        assert pair.raised_by_bulk_verify?
        assert_equal({"reason" => "Same work, other title.", "decided_by" => "ai", "confidence" => "high"}, pair.evidence)
        assert_equal @decision, pair.match_decision
        assert result.data[:match].matched?
      end

      test "caps identifiers per type: a book with five ISBN-13 rows sends the finder the first three in sorted order" do
        fixture_isbn = identifiers(:war_and_peace_isbn13).value
        4.times { |i| @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "isbn-cap-#{i}") }
        assert_equal 5, @book.identifiers.where(identifier_type: :books_work_isbn13).count
        expected = ([fixture_isbn] + %w[isbn-cap-0 isbn-cap-1 isbn-cap-2 isbn-cap-3]).sort.first(3)
        @finder.expects(:call).with { |args| args[:query].isbn13 == expected }
          .returns(DataImporters::Match.new(outcome: :unmatched))

        call
      end

      test "a match decided with the Open Library source failed is a failure that flags nothing and still returns the match" do
        match = DataImporters::Match.new(outcome: :matched, record: @other, confidence: :medium, decided_by: :rule,
          reason: "Exact title and author match.", sources_failed: ["open_library"])
        @finder.stubs(:call).returns(match)

        result = nil
        assert_no_difference("DuplicateCandidate.count") { result = call }

        assert_not result.success?
        assert_match(/Open Library source failed for Books::Book##{@book.id}/, result.errors.first)
        assert_equal match, result.data[:match]
        assert_nil result.data[:pair]
      end

      test "builds the real finder when none is injected" do
        DataImporters::Books::Book::Finder.any_instance.expects(:call).returns(DataImporters::Match.new(outcome: :unmatched))

        assert FindDuplicates.call(book: @book).success?
      end
    end
  end
end
