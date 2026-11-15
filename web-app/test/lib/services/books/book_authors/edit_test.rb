require "test_helper"

module Services
  module Books
    module BookAuthors
      class EditTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          @tolstoy = books_authors(:tolstoy)
          @other = books_authors(:garnett)
          stub_workflow_dispatch
        end

        test "add appends at the end by default" do
          result = Edit.add(book: @book, author_id: @other.id)
          assert result.success?
          assert_equal @book.book_authors.where.not(id: result.data.id).maximum(:position) + 1, result.data.position
          assert_equal "author", result.data.role
        end

        test "add appends after rows with no position" do
          @book.book_authors.update_all(position: nil)
          result = Edit.add(book: @book, author_id: @other.id)
          assert result.success?
          assert_nil result.data.position
          assert_equal @other.id, @book.book_authors.reload.last.author_id
        end

        test "add gives position 1 to a book with no rows" do
          @book.book_authors.destroy_all
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
            assert_equal ["Author #{@tolstoy.id} is already on this book; edit that entry instead."], result.errors
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

        test "the first book link starts an author enrichment after commit" do
          ::Workflows::Books::AuthorEnrichment.expects(:start).with(@other, initiated_by: "first_book_link").once

          assert Edit.add(book: @book, author_id: @other.id).success?
        end

        test "a unique violation on another index is not reported as a duplicate author" do
          ::Books::BookAuthor.any_instance.stubs(:save).raises(ActiveRecord::RecordNotUnique, "index_workflow_runs_one_active")

          assert_raises(ActiveRecord::RecordNotUnique) { Edit.add(book: @book, author_id: @other.id) }
        end

        test "a second first-book link does not start a second run" do
          other_book = books_books(:got)

          assert Edit.add(book: @book, author_id: @other.id).success?
          assert Edit.add(book: other_book, author_id: @other.id).success?

          assert_equal 1, WorkflowRun.where(workflow: "books.author_enrichment", enrichable: @other).count
        end

        test "linking a book to an existing author with other books and no run starts nothing" do
          ::Workflows::Books::AuthorEnrichment.expects(:start).never
          book = books_books(:got)
          book.book_authors.where(author_id: @tolstoy.id).destroy_all

          assert Edit.add(book: book, author_id: @tolstoy.id).success?
        end

        test "a refused add starts no run" do
          ::Workflows::Books::AuthorEnrichment.expects(:start).never

          refute Edit.add(book: @book, author_id: @tolstoy.id).success?
          refute Edit.add(book: @book, author_id: 0).success?
        end

        test "an author with an earlier run is not re-enriched" do
          ::Workflows::Books::AuthorEnrichment.expects(:start).never
          WorkflowRun.create!(workflow: "books.author_enrichment", definition_version: 1, enrichable: @other,
            initiated_by: "test", options: {}, started_at: 1.day.ago, status: :completed, finished_at: 1.day.ago)

          assert Edit.add(book: @book, author_id: @other.id).success?
        end

        test "an author created with a qid is not re-enriched on its first book" do
          created = ::Services::Books::Authors::AdminCreate.call(attrs: {name: "Nova Pen"}, wikidata_qid: "Q987654321")
          assert created.success?, created.errors.inspect
          author = created.data[:author]
          assert_equal 1, WorkflowRun.where(workflow: "books.author_enrichment", enrichable: author).count

          assert Edit.add(book: @book, author_id: author.id).success?

          assert_equal 1, WorkflowRun.where(workflow: "books.author_enrichment", enrichable: author).count
        end
      end
    end
  end
end
