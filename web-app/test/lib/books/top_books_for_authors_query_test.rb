require "test_helper"

module Books
  class TopBooksForAuthorsQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @tolstoy = books_authors(:tolstoy)
    end

    test "returns each author's ranked books ordered best rank first" do
      book_a = Books::Book.create!(title: "Top Books Query A")
      book_b = Books::Book.create!(title: "Top Books Query B")
      Books::BookAuthor.create!(book: book_a, author: @tolstoy, role: :author)
      Books::BookAuthor.create!(book: book_b, author: @tolstoy, role: :author)
      RankedItem.create!(item: book_b, ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: book_a, ranking_configuration: @rc, rank: 2, score: 90)

      result = Books::TopBooksForAuthorsQuery.call(author_ids: [@tolstoy.id], ranking_configuration: @rc)

      assert_equal [book_b, book_a], result[@tolstoy.id]
    end

    test "limits each author to the given number of books" do
      books = Array.new(3) { |i| Books::Book.create!(title: "Top Books Query Limit #{i}") }
      books.each_with_index do |book, i|
        Books::BookAuthor.create!(book: book, author: @tolstoy, role: :author)
        RankedItem.create!(item: book, ranking_configuration: @rc, rank: i + 1, score: 100 - i)
      end

      result = Books::TopBooksForAuthorsQuery.call(author_ids: [@tolstoy.id], ranking_configuration: @rc, limit: 2)

      assert_equal books.first(2), result[@tolstoy.id]
    end

    test "excludes book_authors with a non-author role" do
      book = Books::Book.create!(title: "Top Books Query Editor")
      Books::BookAuthor.create!(book: book, author: @tolstoy, role: :editor)
      RankedItem.create!(item: book, ranking_configuration: @rc, rank: 1, score: 100)

      result = Books::TopBooksForAuthorsQuery.call(author_ids: [@tolstoy.id], ranking_configuration: @rc)

      assert_equal({}, result)
    end

    test "excludes books ranked in a different ranking configuration" do
      other_rc = ranking_configurations(:books_inherited)
      book = Books::Book.create!(title: "Top Books Query Other RC")
      Books::BookAuthor.create!(book: book, author: @tolstoy, role: :author)
      RankedItem.create!(item: book, ranking_configuration: other_rc, rank: 1, score: 100)

      result = Books::TopBooksForAuthorsQuery.call(author_ids: [@tolstoy.id], ranking_configuration: @rc)

      assert_equal({}, result)
    end

    test "returns an empty hash for blank author ids" do
      assert_equal({}, Books::TopBooksForAuthorsQuery.call(author_ids: [], ranking_configuration: @rc))
    end

    test "returns an empty hash for a nil ranking configuration" do
      assert_equal({}, Books::TopBooksForAuthorsQuery.call(author_ids: [@tolstoy.id], ranking_configuration: nil))
    end
  end
end
