# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class SimilarBooksTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:crime_and_punishment)
        # got and clash are both by `king`; war_and_peace is by `tolstoy`.
        @got = books_books(:got)
        @clash = books_books(:clash)
        @war_and_peace = books_books(:war_and_peace)
      end

      def stub_hits(books)
        hits = books.each_with_index.map do |book, i|
          {id: book.id.to_s, score: 10.0 - i, source: nil}
        end
        ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits)
      end

      test "returns books in the order the search returned them" do
        stub_hits([@war_and_peace, @got])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_equal [@war_and_peace.id, @got.id], result.data[:books].map(&:id)
      end

      test "caps books per author" do
        stub_hits([@got, @clash, @war_and_peace])

        result = ::Services::Books::SimilarBooks.call(@book, max_per_author: 1)

        assert_equal [@got.id, @war_and_peace.id], result.data[:books].map(&:id)
      end

      test "allows two books by one author at the default cap" do
        stub_hits([@got, @clash, @war_and_peace])

        result = ::Services::Books::SimilarBooks.call(@book, max_per_author: 2)

        assert_equal [@got.id, @clash.id, @war_and_peace.id], result.data[:books].map(&:id)
      end

      test "truncates to the limit" do
        stub_hits([@war_and_peace, @got, @clash])

        result = ::Services::Books::SimilarBooks.call(@book, limit: 2)

        assert_equal 2, result.data[:books].size
      end

      test "reports more_available when the cap left more than the limit" do
        stub_hits([@war_and_peace, @got, @clash])

        assert ::Services::Books::SimilarBooks.call(@book, limit: 2).data[:more_available]
      end

      test "does not report more_available when it returned everything" do
        stub_hits([@war_and_peace, @got])

        refute ::Services::Books::SimilarBooks.call(@book, limit: 5).data[:more_available]
      end

      test "does not report more_available when the cap trimmed the surplus" do
        stub_hits([@got, @clash, @war_and_peace])

        result = ::Services::Books::SimilarBooks.call(@book, max_per_author: 1, limit: 2)

        assert_equal [@got.id, @war_and_peace.id], result.data[:books].map(&:id)
        refute result.data[:more_available]
      end

      test "skips a hit whose database row is gone" do
        ::Search::Books::Search::BookSimilar.stubs(:call).returns([
          {id: "99999999", score: 10.0, source: nil},
          {id: @war_and_peace.id.to_s, score: 9.0, source: nil}
        ])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert_equal [@war_and_peace.id], result.data[:books].map(&:id)
      end

      test "returns an empty success when the search returns nothing" do
        ::Search::Books::Search::BookSimilar.stubs(:call).returns([])

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_empty result.data[:books]
        refute result.data[:more_available]
      end

      test "returns an empty success when the search raises" do
        ::Search::Books::Search::BookSimilar.stubs(:call).raises(StandardError, "opensearch down")

        result = ::Services::Books::SimilarBooks.call(@book)

        assert result.success?
        assert_empty result.data[:books]
      end

      test "preloads authors and the primary image with its attachment so views do not N+1" do
        image = Image.new(parent: @war_and_peace, primary: true)
        image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
        image.save!

        stub_hits([@war_and_peace, @got])
        books = ::Services::Books::SimilarBooks.call(@book).data[:books]
        pictured = books.find { |book| book.id == @war_and_peace.id }

        # Without this, a fixture/attachment change could silently empty
        # primary_image and this test would stop exercising the nested chain
        # at all while staying green.
        assert pictured.primary_image.present?

        assert_queries_count(0) do
          books.each { |book| book.book_authors.map { |ba| ba.author.name } }
          # No `&.` guard: a nil primary_image here should raise, not quietly
          # skip the file_attachment/blob/variant_records chain being tested.
          pictured.primary_image.file.attached?
        end
      end
    end
  end
end
