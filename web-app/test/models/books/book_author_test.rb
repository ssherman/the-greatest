require "test_helper"

# == Schema Information
#
# Table name: books_book_authors
#
#  id          :bigint           not null, primary key
#  credited_as :string
#  position    :integer
#  role        :integer          default("author"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  author_id   :bigint           not null
#  book_id     :bigint           not null
#
# Indexes
#
#  index_books_book_authors_on_author_id              (author_id)
#  index_books_book_authors_on_book_id                (book_id)
#  index_books_book_authors_on_book_id_and_author_id  (book_id,author_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (author_id => books_authors.id)
#  fk_rails_...  (book_id => books_books.id)
#
module Books
  class BookAuthorTest < ActiveSupport::TestCase
    test "is valid with a book and author" do
      ba = Books::BookAuthor.new(book: books_books(:crime_and_punishment), author: books_authors(:tolstoy))
      assert_predicate ba, :valid?
    end

    test "defaults to author role" do
      assert_predicate Books::BookAuthor.new, :author?
    end

    test "is unique per book and author" do
      dup = Books::BookAuthor.new(book: books_books(:war_and_peace), author: books_authors(:tolstoy))
      assert_not dup.valid?
      assert_includes dup.errors[:book_id], "has already been taken"
    end

    test "book exposes its authors" do
      assert_includes books_books(:war_and_peace).authors, books_authors(:tolstoy)
    end

    test "author exposes its books" do
      assert_includes books_authors(:tolstoy).books, books_books(:war_and_peace)
    end

    test "credited_as stores the printed name" do
      assert_equal "Lev Tolstoy", books_book_authors(:war_and_peace_tolstoy).credited_as
    end

    test "book as_indexed_json includes author names" do
      assert_includes books_books(:war_and_peace).as_indexed_json[:author_names], "Leo Tolstoy"
    end
  end
end
