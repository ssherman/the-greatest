require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class PromoteRecordsTest < ActiveSupport::TestCase
        setup do
          @author = ::Books::Author.create!(name: "Provisional Promote Author", provisional: true)
          @book = ::Books::Book.create!(title: "Provisional Promote Book", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: @author, position: 1)
          @plain = ::Books::Book.create!(title: "Provisional Lone Book", provisional: true)
          ::Books::BookAuthor.create!(book: @plain, author: books_authors(:tolstoy), position: 1)
        end

        test "promotes the books and their provisional authors" do
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::EnrichBookJob.stubs(:perform_async)

          PromoteRecords.call(books: [@book], authors: [])

          assert_equal [false, false], [@book.reload.provisional?, @author.reload.provisional?]
        end

        test "a book with a new author waits for the author's chain; a book without starts its own" do
          ::Books::Authors::WikidataJob.expects(:perform_async).with(@author.id)
          ::Books::EnrichBookJob.expects(:perform_async).with(@plain.id)
          ::Books::EnrichBookJob.expects(:perform_async).with(@book.id).never

          PromoteRecords.call(books: [@book, @plain], authors: [])

          assert_equal ::Services::Books::DeferredEnrichment::REASON, @book.enrichments.sole.reason
        end

        test "an already promoted record is left alone and queues nothing" do
          @plain.update!(provisional: false)
          ::Books::EnrichBookJob.expects(:perform_async).never

          assert_empty PromoteRecords.call(books: [@plain], authors: []).data[:book_ids]
        end
      end
    end
  end
end
