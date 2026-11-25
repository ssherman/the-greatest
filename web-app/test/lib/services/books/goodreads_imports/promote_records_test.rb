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
          assert_equal [author_run.step(:author_facts)], book_run.step(:book_facts).dependencies.map(&:prerequisite_step).reject { it.key == "goodreads" }
          assert_equal 0, @book.enrichments.count
        end

        test "a book whose author was already in the catalog plans a run that waits on nothing" do
          PromoteRecords.call(books: [@plain], authors: [])

          assert_equal 0, run_for(@plain, "books.book_enrichment").step(:book_facts).dependencies.map(&:prerequisite_step).reject { it.key == "goodreads" }.size
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
            assert_equal [author_step], run_for(book, "books.book_enrichment").step(:book_facts).dependencies.map(&:prerequisite_step).reject { it.key == "goodreads" }
          end
        end

        test "a submission promotion stamps the initiator and the priority lane on the run" do
          PromoteRecords.call(books: [@book], authors: [], initiated_by: "book_submission", lane: "priority")

          run = run_for(@book, "books.book_enrichment")
          assert_equal ["book_submission", "priority", "goodreads_fetch_priority"], [run.initiated_by, run.options["lane"], run.step(:goodreads).queue]
          assert_equal "book_submission", run_for(@author, "books.author_enrichment").initiated_by
        end

        test "the defaults add no lane to the run" do
          PromoteRecords.call(books: [@book], authors: [])

          run = run_for(@book, "books.book_enrichment")
          assert_not run.options.key?("lane")
          assert_equal "goodreads_fetch", run.step(:goodreads).queue
        end

        test "an import approval of a book with an active limited submission run supersedes it" do
          limited = ::Workflows::Books::BookEnrichment.start(@plain, initiated_by: "book_submission", options: {only: ["goodreads"], lane: "priority"})

          PromoteRecords.call(books: [@plain], authors: [])

          assert_equal "cancelled", limited.reload.status
          full = WorkflowRun.running.find_by!(enrichable: @plain, workflow: "books.book_enrichment")
          assert_equal ["goodreads_promote", "ready"], [full.initiated_by, full.step(:goodreads).state]
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

        test "promoting closes the book's open submissions approved, the second reader's too" do
          first = submission_for(@book, :pending)
          second = submission_for(@book, :not_needed, created_book: false)
          other = submission_for(@plain, :pending)
          Current.acting_user = users(:admin_user)
          Current.acting_via = "admin_ui"

          PromoteRecords.call(books: [@book], authors: [])

          assert_equal ["approved", "admin_ui", users(:admin_user).id, nil], [first.reload.review_status, first.reviewed_via, first.reviewed_by_id, first.lease_token]
          assert_equal "approved", second.reload.review_status
          assert_equal "pending", other.reload.review_status
        ensure
          Current.reset
        end

        test "a row already stamped by an approve keeps its own review" do
          row = submission_for(@book, :approved)
          row.update!(reviewed_via: :api, reviewed_by: users(:editor_user), review_note: "approved by hand")

          PromoteRecords.call(books: [@book], authors: [])

          assert_equal ["api", users(:editor_user).id, "approved by hand"], [row.reload.reviewed_via, row.reviewed_by_id, row.review_note]
        end

        test "a failed promotion closes nothing" do
          row = submission_for(@book, :pending)
          loner = ::Books::Author.create!(name: "Uncredited Provisional", provisional: true)
          ::Workflows::Books::AuthorEnrichment.stubs(:start).raises("boom")

          assert_raises(RuntimeError) { PromoteRecords.call(books: [@book], authors: [loner]) }

          assert_equal "pending", row.reload.review_status
        end

        def submission_for(book, review_status, created_book: true)
          ::Books::BookSubmission.create!(
            user: users(:regular_user), input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            fingerprint: SecureRandom.hex(4), status: :added, review_status: review_status, created_book: created_book,
            book: book, lease_token: "tok", lease_expires_at: 1.hour.from_now
          )
        end
      end
    end
  end
end
