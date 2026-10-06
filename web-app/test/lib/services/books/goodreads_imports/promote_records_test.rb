require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class PromoteRecordsTest < ActiveSupport::TestCase
        setup do
          # Inline Sidekiq plus a real token in a local .env would call Cloudflare.
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
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

        test "promoting purges the records' cached show pages" do
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::EnrichBookJob.stubs(:perform_async)
          ::Books::PurgeShowPagesJob.expects(:perform_async).with([@book.id], [@author.id])

          PromoteRecords.call(books: [@book], authors: [])
        end

        test "a promoted book on a public goal or a favorites list purges the goal pages and regenerates favorites" do
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::EnrichBookJob.stubs(:perform_async)
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          user = User.create!(email: "promote-goals@example.com", role: :user, email_verified: false)
          ::Books::UserList.find_by!(user: user, list_type: :favorites).user_list_items.create!(listable: @book)
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_book).with(book: @book).returns(["https://b/reading_goals/9"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["https://b/reading_goals/9"])
          ::GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList")

          PromoteRecords.call(books: [@book], authors: [])
        end

        test "a promoted book on nobody's favorites does not regenerate the list" do
          ::Books::Authors::WikidataJob.stubs(:perform_async)
          ::Books::EnrichBookJob.stubs(:perform_async)
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          ::GenerateUserFavoritesListsJob.expects(:perform_async).never

          PromoteRecords.call(books: [@book], authors: [])
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
