require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class PromoteRecordsTest < ActiveSupport::TestCase
        setup do
          # Inline Sidekiq would run every planned step, and a real token in a
          # local .env would call Cloudflare.
          stub_workflow_dispatch
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          @author = ::Books::Author.create!(name: "Provisional Promote Author", provisional: true)
          @book = ::Books::Book.create!(title: "Provisional Promote Book", provisional: true)
          ::Books::BookAuthor.create!(book: @book, author: @author, position: 1)
          @plain = ::Books::Book.create!(title: "Provisional Lone Book", provisional: true)
          ::Books::BookAuthor.create!(book: @plain, author: books_authors(:tolstoy), position: 1)
        end

        test "promotes the books and their provisional authors" do
          PromoteRecords.call(books: [@book], authors: [])

          assert_equal [false, false], [@book.reload.provisional?, @author.reload.provisional?]
        end

        def run_for(record, workflow)
          WorkflowRun.find_by!(enrichable: record, workflow: workflow)
        end

        test "promoting a book with a promoted author plans a book run that waits on the author run" do
          PromoteRecords.call(books: [@book], authors: [])

          author_run = run_for(@author, "books.author_enrichment")
          book_run = run_for(@book, "books.book_enrichment")
          assert_equal "goodreads_promote", book_run.initiated_by
          assert_equal [author_run.step(:author_facts)], book_run.step(:book_facts).dependencies.map(&:prerequisite_step)
          assert_equal 0, @book.enrichments.count
        end

        test "a book whose author was already in the catalog plans a run that waits on nothing" do
          PromoteRecords.call(books: [@plain], authors: [])

          assert_equal 0, run_for(@plain, "books.book_enrichment").step(:book_facts).dependencies.count
          assert_equal 0, WorkflowRun.where(enrichable: books_authors(:tolstoy), initiated_by: "goodreads_promote").count
        end

        test "promoting an author with no promoted book plans only its author run" do
          lone = ::Books::Author.create!(name: "Provisional Lone Author", provisional: true)

          PromoteRecords.call(books: [], authors: [lone])

          assert_equal "goodreads_promote", run_for(lone, "books.author_enrichment").initiated_by
          assert_equal 0, WorkflowRun.where(workflow: "books.book_enrichment").count
        end

        test "an author promoted with a book gets one run, the book's, and no second one for being listed too" do
          PromoteRecords.call(books: [@book], authors: [@author])

          assert_equal 1, WorkflowRun.where(enrichable: @author, workflow: "books.author_enrichment").count
        end

        test "two promoted books by one new author both wait on its single run" do
          second = ::Books::Book.create!(title: "Provisional Second Book", provisional: true)
          ::Books::BookAuthor.create!(book: second, author: @author, position: 1)

          PromoteRecords.call(books: [@book, second], authors: [])

          author_step = run_for(@author, "books.author_enrichment").step(:author_facts)
          [@book, second].each do |book|
            assert_equal [author_step], run_for(book, "books.book_enrichment").step(:book_facts).dependencies.map(&:prerequisite_step)
          end
        end

        test "the old queue-based enrichment is gone: no job is enqueued and no deferral row is written" do
          ::Books::Authors::WikidataJob.expects(:perform_async).never
          ::Books::EnrichBookJob.expects(:perform_async).never
          ::Books::AmazonProductEnrichmentJob.expects(:perform_async).never

          PromoteRecords.call(books: [@book, @plain], authors: [])

          assert_equal 0, ::Enrichment.where(reason: ::Services::Books::DeferredEnrichment::REASON).count
        end

        test "a failure inside the transaction leaves no run and dispatches nothing" do
          Workflows::Dispatcher.expects(:dispatch).never
          ::Services::Books::ReadingGoals::DestructionInvalidator.stubs(:for_book).raises(ActiveRecord::RecordInvalid)

          assert_raises(ActiveRecord::RecordInvalid) { PromoteRecords.call(books: [@book], authors: []) }

          assert_equal 0, WorkflowRun.where(enrichable: [@book, @author]).count
          assert @book.reload.provisional?
        end

        test "promoting purges the records' cached show pages" do
          ::Books::PurgeShowPagesJob.expects(:perform_async).with([@book.id], [@author.id])

          PromoteRecords.call(books: [@book], authors: [])
        end

        test "a promoted book on a public goal or a favorites list purges the goal pages and regenerates favorites" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          user = User.create!(email: "promote-goals@example.com", role: :user, email_verified: false)
          ::Books::UserList.find_by!(user: user, list_type: :favorites).user_list_items.create!(listable: @book)
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_book).with(book: @book).returns(["https://b/reading_goals/9"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["https://b/reading_goals/9"])
          ::GenerateUserFavoritesListsJob.expects(:perform_async).with("Books::UserList")

          PromoteRecords.call(books: [@book], authors: [])
        end

        test "a promoted book on nobody's favorites does not regenerate the list" do
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          ::GenerateUserFavoritesListsJob.expects(:perform_async).never

          PromoteRecords.call(books: [@book], authors: [])
        end

        test "a promoted book with no author skips its Amazon step" do
          authorless = ::Books::Book.create!(title: "Provisional Authorless Book", provisional: true)

          PromoteRecords.call(books: [authorless], authors: [])

          step = run_for(authorless, "books.book_enrichment").step(:amazon)
          assert_equal ["skipped", "no_authors"], [step.state, step.outcome]
        end

        test "an already promoted record is left alone and plans nothing" do
          @plain.update!(provisional: false)

          assert_empty PromoteRecords.call(books: [@plain], authors: []).data[:book_ids]
          assert_equal 0, WorkflowRun.where(enrichable: @plain).count
        end
      end
    end
  end
end
