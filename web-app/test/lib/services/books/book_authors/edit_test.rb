require "test_helper"

module Services
  module Books
    module BookAuthors
      class EditTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
          @other = books_authors(:garnett)
        end

        test "add appends at the end by default" do
          result = Edit.add(book: @book, author_id: @other.id)
          assert result.success?
          assert_equal 2, result.data.position
          assert_equal "author", result.data.role
        end

        test "add defaults position to 1 when existing rows have none" do
          @book.book_authors.update_all(position: nil)
          result = Edit.add(book: @book, author_id: @other.id)
          assert_equal 1, result.data.position
        end

        test "add keeps a given role, position and credited_as" do
          result = Edit.add(book: @book, author_id: @other.id, attrs: {"role" => "editor", "position" => 5, "credited_as" => "C. Garnett"})
          assert result.success?
          assert_equal ["editor", 5, "C. Garnett"], [result.data.role, result.data.position, result.data.credited_as]
        end

        test "add refuses an author already on the book" do
          assert_no_difference("::Books::BookAuthor.count") do
            result = Edit.add(book: @book, author_id: @tolstoy.id)
            refute result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["Author #{@tolstoy.id} is already on this book. Use update_book_author to change the role, position or credited_as."], result.errors
          end
        end

        test "add refuses an unknown author" do
          result = Edit.add(book: @book, author_id: 999_999_999)
          refute result.success?
          assert_equal :unprocessable, result.code
          assert_equal ["No author 999999999."], result.errors
        end

        test "add stores blank credited_as as nil" do
          result = Edit.add(book: @book, author_id: @other.id, attrs: {"credited_as" => ""})
          assert_nil result.data.credited_as
        end

        test "update changes only the given fields" do
          row = @book.book_authors.find_by(author_id: @tolstoy.id)
          row.update!(credited_as: "Leo")
          result = Edit.update(book: @book, author_id: @tolstoy.id, attrs: {"role" => "editor"})
          assert result.success?
          row.reload
          assert_equal ["editor", 1, "Leo"], [row.role, row.position, row.credited_as]
        end

        test "update with nil clears credited_as and position" do
          row = @book.book_authors.find_by(author_id: @tolstoy.id)
          row.update!(credited_as: "Leo")
          result = Edit.update(book: @book, author_id: @tolstoy.id, attrs: {"credited_as" => nil, "position" => nil})
          assert result.success?
          row.reload
          assert_nil row.credited_as
          assert_nil row.position
        end

        test "update on an author not on the book is not_found" do
          result = Edit.update(book: @book, author_id: @other.id, attrs: {"role" => "editor"})
          refute result.success?
          assert_equal :not_found, result.code
          assert_equal ["Book #{@book.id} has no author #{@other.id}."], result.errors
        end

        test "add refuses an unknown role" do
          assert_no_difference("::Books::BookAuthor.count") do
            result = Edit.add(book: @book, author_id: @other.id, attrs: {"role" => "illustrator"})
            refute result.success?
            assert_equal :unprocessable, result.code
            assert_equal ["role must be one of author, editor."], result.errors
          end
        end

        test "update refuses an unknown role and changes nothing" do
          result = Edit.update(book: @book, author_id: @tolstoy.id, attrs: {"role" => "illustrator"})
          refute result.success?
          assert_equal :unprocessable, result.code
          assert_equal "author", @book.book_authors.find_by(author_id: @tolstoy.id).role
        end

        test "remove deletes the row and leaves the author record" do
          assert_difference("::Books::BookAuthor.count", -1) do
            assert Edit.remove(book: @book, author_id: @tolstoy.id).success?
          end
          assert ::Books::Author.exists?(@tolstoy.id)
        end

        test "remove the last author is allowed" do
          @book.book_authors.where.not(author_id: @tolstoy.id).destroy_all
          assert Edit.remove(book: @book, author_id: @tolstoy.id).success?
          assert_equal 0, @book.book_authors.count
        end

        test "remove on an author not on the book is not_found" do
          result = Edit.remove(book: @book, author_id: @other.id)
          refute result.success?
          assert_equal :not_found, result.code
        end
      end
    end
  end
end
