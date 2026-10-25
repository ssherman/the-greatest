require "test_helper"

module Services
  module Books
    module GoodreadsEnrichment
      class CandidateFilterTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Catch-22")
          @book.authors << ::Books::Author.create!(name: "Joseph Heller")
        end

        def rows(name)
          html = Zlib.gunzip(file_fixture("goodreads/searches/#{name}").binread).force_encoding(Encoding::UTF_8)
          ::Books::Goodreads::SearchPage.parse(html: html, status: 200).rows
        end

        test "a title and author search keeps only the real book's row" do
          kept = CandidateFilter.call(book: @book, rows: rows("catch_22_title_and_author.html.gz"))

          assert_equal [147719920], kept.map(&:goodreads_book_id)
        end

        test "a title-only search puts the book first by ratings and drops the sequel" do
          kept = CandidateFilter.call(book: @book, rows: rows("catch_22_title_only.html.gz"))

          assert_equal 168668, kept.first.goodreads_book_id
          assert_not_includes kept.map(&:title), "Closing Time (Catch-22, #2)"
        end

        test "study guides are dropped even when author and title agree" do
          row = ::Books::Goodreads::SearchPage::Row.new(goodreads_book_id: 1, title: "Catch-22 Study Guide",
            author_names: ["Joseph Heller"], year: nil, ratings_count: 5, editions_count: 1)

          assert_empty CandidateFilter.call(book: @book, rows: [row])
        end
      end
    end
  end
end
