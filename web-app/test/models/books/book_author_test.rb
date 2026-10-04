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

    # Search freshness: adding/removing authorship reindexes the book
    test "creating a book author enqueues the book for reindexing" do
      book = books_books(:crime_and_punishment)
      author = books_authors(:garnett)

      assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book.id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
        Books::BookAuthor.create!(book: book, author: author, position: 1)
      end
    end

    test "destroying a book author enqueues the book for reindexing" do
      book_author = books_book_authors(:war_and_peace_tolstoy)
      book_id = book_author.book_id

      assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book_id, action: SearchIndexRequest.actions[:index_item]).count }, 1 do
        book_author.destroy!
      end
    end

    test "destroying a book that has authors does not raise and enqueues the book's unindex" do
      book = Books::Book.create!(title: "Destroyable Book")
      author = Books::Author.create!(name: "Destroyable Author")
      Books::BookAuthor.create!(book: book, author: author, position: 1)
      book_id = book.id

      assert_nothing_raised { book.destroy! }

      assert SearchIndexRequest.where(parent_type: "Books::Book", parent_id: book_id, action: SearchIndexRequest.actions[:unindex_item]).exists?
    end

    test "reassigning a book author's book_id reindexes both the old and new book" do
      old_book = Books::Book.create!(title: "Reassign Old Book")
      new_book = Books::Book.create!(title: "Reassign New Book")
      author = Books::Author.create!(name: "Reassigned Author")
      book_author = Books::BookAuthor.create!(book: old_book, author: author, position: 1)

      SearchIndexRequest.delete_all

      book_author.update!(book: new_book)

      assert SearchIndexRequest.where(parent_type: "Books::Book", parent_id: old_book.id, action: SearchIndexRequest.actions[:index_item]).exists?, "old book should be reindexed"
      assert SearchIndexRequest.where(parent_type: "Books::Book", parent_id: new_book.id, action: SearchIndexRequest.actions[:index_item]).exists?, "new book should be reindexed"
    end

    test "reindex is suppressed inside without_search_indexing" do
      author = Books::Author.create!(name: "Guard Author")
      book = Books::Book.create!(title: "Guard Book")
      assert_no_difference -> { SearchIndexRequest.count } do
        Services::BooksMigration.without_search_indexing do
          Books::BookAuthor.create!(book: book, author: author)
        end
      end
    end

    test "reindex still fires outside suppression" do
      author = Books::Author.create!(name: "Unguarded Author")
      book = Books::Book.create!(title: "Unguarded Book")
      assert_difference -> { SearchIndexRequest.where(parent_type: "Books::Book").count }, 1 do
        Books::BookAuthor.create!(book: book, author: author)
      end
    end
  end
end
