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

        def row_titled(title)
          ::Books::Goodreads::SearchPage::Row.new(goodreads_book_id: 2, title: title,
            author_names: ["Joseph Heller"], year: nil, ratings_count: 5, editions_count: 1)
        end

        test "set words in the series parenthetical do not drop the book" do
          book = ::Books::Book.create!(title: "Pretty Horses")
          book.authors << @book.authors.first

          assert_equal [2], CandidateFilter.call(book: book, rows: [row_titled("Pretty Horses (The Border Trilogy, #1)")]).map(&:goodreads_book_id)
        end

        test "a numbered range in the series parenthetical is still an omnibus" do
          book = ::Books::Book.create!(title: "Pretty Horses")
          book.authors << @book.authors.first

          assert_empty CandidateFilter.call(book: book, rows: [row_titled("Pretty Horses (The Border Trilogy, #1-3)")])
        end

        test "a leading article on our title does not drop a row without one" do
          book = ::Books::Book.create!(title: "The Lord of the Rings")
          book.authors << @book.authors.first

          assert_equal [2], CandidateFilter.call(book: book, rows: [row_titled("Lord of the Rings")]).map(&:goodreads_book_id)
        end

        test "accents do not drop a row spelled without them" do
          book = ::Books::Book.create!(title: "Les Misérables")
          book.authors << @book.authors.first

          assert_equal [2], CandidateFilter.call(book: book, rows: [row_titled("Les Miserables")]).map(&:goodreads_book_id)
        end

        test "a row under one of our alternate titles is kept" do
          book = ::Books::Book.create!(title: "Der Prozess", alternate_titles: ["The Trial"])
          book.authors << @book.authors.first

          assert_equal [2], CandidateFilter.call(book: book, rows: [row_titled("The Trial")]).map(&:goodreads_book_id)
        end

        test "a title is matched word for word, never inside a longer word" do
          book = ::Books::Book.create!(title: "The Road")
          book.authors << @book.authors.first

          assert_empty CandidateFilter.call(book: book, rows: [row_titled("Roadside Picnic")])
        end
      end
    end
  end
end
