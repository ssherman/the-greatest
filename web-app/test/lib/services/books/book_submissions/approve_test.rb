require "test_helper"

module Services
  module Books
    module BookSubmissions
      class ApproveTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          stub_review_side_effects
          @admin = users(:admin_user)
          @submission = lease(reviewable_submission)
          @book = @submission.book
          @sources = ["https://example.com/evidence"]
        end

        teardown { Current.reset }

        def approve(submission = @submission, via: "api", lease_token: TOKEN, note: "Found in the national library catalogue", sources: @sources, user: @admin)
          Approve.call(submission: submission, user: user, via: via, lease_token: lease_token, note: note, sources: sources)
        end

        test "stamps the row, promotes the book and its authors, and plans a priority enrichment run" do
          author = @book.authors.first

          result = approve

          assert_success result
          row = fresh(@submission)
          assert_equal ["approved", @admin.id, "api", @sources, "Found in the national library catalogue", nil, nil],
            [row.review_status, row.reviewed_by_id, row.reviewed_via, row.review_sources, row.review_note, row.lease_token, row.lease_expires_at]
          assert_not_nil row.reviewed_at
          assert_equal [false, false], [@book.reload.provisional?, author.reload.provisional?]
          run = WorkflowRun.find_by!(enrichable: @book, workflow: "books.book_enrichment")
          assert_equal ["book_submission", "priority"], [run.initiated_by, run.options["lane"]]
        end

        test "every other submission on the book closes approved by the same reviewer" do
          other = reviewable_submission(user: users(:editor_user), book: @book)
          matched = reviewable_submission(user: users(:contractor_user), book: @book, review_status: :not_needed)

          approve

          [other, matched].each do |row|
            row.reload
            assert_equal ["approved", @admin.id, "api"], [row.review_status, row.reviewed_by_id, row.reviewed_via]
          end
        end

        test "an active limited run is replaced by a full one" do
          limited = ::Workflows::Books::BookEnrichment.start(@book, initiated_by: "book_submission", options: {only: ["goodreads"], lane: "priority"})

          approve

          assert_equal "cancelled", limited.reload.status
          full = WorkflowRun.running.find_by!(enrichable: @book, workflow: "books.book_enrichment")
          assert_nil full.options["only"]
          assert_not_equal limited.id, full.id
        end

        test "the admin page needs no lease and also approves a row flagged needs_human" do
          row = reviewable_submission(review_status: :needs_human)

          result = approve(row, via: "admin_ui", lease_token: nil, sources: [])

          assert_success result
          assert_equal ["approved", "admin_ui"], [fresh(row).review_status, fresh(row).reviewed_via]
        end

        test "the API needs a live matching lease" do
          assert_failure approve(lease_token: nil), :conflict
          assert_failure approve(lease_token: "other"), :conflict
          @submission.update_columns(lease_expires_at: 1.second.ago)
          assert_failure approve, :conflict, "expired"
          assert_equal "pending", fresh(@submission).review_status
          assert @book.reload.provisional?
        end

        test "the API refuses a needs_human row even holding a lease" do
          row = lease(reviewable_submission(review_status: :needs_human))

          assert_failure approve(row), :conflict
        end

        test "state and lease are judged before input" do
          assert_failure approve(lease_token: "wrong", note: "", sources: []), :conflict
        end

        test "refuses a row already closed, a book already public and a row with no book" do
          closed = lease(reviewable_submission(review_status: :approved))
          assert_failure approve(closed), :conflict

          public_book = ::Books::Book.create!(title: "Already Public Book")
          public_row = lease(reviewable_submission(book: public_book))
          assert_failure approve(public_row), :conflict, "provisional"

          none = lease(reviewable_submission(book: nil, status: :needs_details, review_status: :not_needed))
          assert_failure approve(none), :conflict
        end

        test "note is 1 to 1,000 characters and the API needs sources" do
          assert_failure approve(note: nil), :invalid, "note"
          assert_failure approve(note: "  "), :invalid, "note"
          assert_failure approve(note: "x" * 1_001), :invalid, "note"
          assert_failure approve(sources: []), :invalid, "sources"
          assert_failure approve(sources: ["ftp://example.com/x"]), :invalid, "sources"
          assert_failure approve(sources: ["not a url"]), :invalid, "sources"
          assert_failure approve(sources: ["https://example.com/" + "a" * 2_000]), :invalid, "sources"
          assert_failure approve(sources: Array.new(21) { "https://example.com/#{it}" }), :invalid, "sources"
          assert_failure approve(sources: "https://example.com/x"), :invalid, "sources"
          assert_equal "pending", fresh(@submission).review_status

          assert_success approve(note: "x" * 1_000, sources: Array.new(20) { "https://example.com/#{it}" })
        end

        test "the admin page may approve with no sources but still needs a note" do
          row = reviewable_submission
          assert_failure approve(row, via: "admin_ui", lease_token: nil, sources: [], note: ""), :invalid
          assert_success approve(row, via: "admin_ui", lease_token: nil, sources: [])
        end

        test "a second approve with the same token is a conflict" do
          assert_success approve
          assert_failure approve, :conflict
        end

        test "a failed promotion rolls the stamp back" do
          ::Services::Books::GoodreadsImports::PromoteRecords.stubs(:call).raises(ArgumentError, "planner failed")

          assert_raises(ArgumentError) { approve }

          assert_equal ["pending", TOKEN], [fresh(@submission).review_status, fresh(@submission).lease_token]
          assert @book.reload.provisional?
        end

        test "the acting admin can be the reader" do
          row = lease(reviewable_submission(user: @admin))

          assert_success approve(row)
        end

        test "Current is set within the call and restored after" do
          Current.acting_user = users(:editor_user)
          Current.acting_via = "admin_ui"
          other = reviewable_submission(user: users(:contractor_user), book: @book)

          approve

          assert_equal [@admin.id, "api"], [other.reload.reviewed_by_id, other.reviewed_via]
          assert_equal [users(:editor_user), "admin_ui"], [Current.acting_user, Current.acting_via]
        end

        test "a lease taken by someone else between the read and the write loses" do
          ::Services::Books::ReadingGoals::DestructionInvalidator.stubs(:for_book).with do
            ::Books::BookSubmission.where(id: @submission.id).update_all(lease_token: "taken")
            true
          end.returns([])

          assert_failure approve, :conflict
          assert_equal "pending", fresh(@submission).review_status
          assert @book.reload.provisional?
          assert_equal 0, WorkflowRun.where(enrichable: @book).count
        end

        test "approving a row that failed after it got a book resumes it: queued, counters reset, job queued after the commit" do
          failed = lease(reviewable_submission(status: :failed, attempts: 4, error: "boom"))
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(failed.id).once

          assert_success approve(failed)

          row = fresh(failed)
          assert_equal ["queued", "approved", 0, nil, nil], [row.status, row.review_status, row.attempts, row.error, row.lease_token]
        end

        test "approving a row that is not failed does not queue the job" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never

          assert_success approve
          assert_equal "added", fresh(@submission).status
        end

        test "a note or source with NUL or invalid UTF-8 is refused before anything is written" do
          assert_failure approve(note: "a \u0000 b"), :invalid, "note"
          assert_failure approve(note: "a \xFF b".b.force_encoding("UTF-8")), :invalid, "note"
          assert_failure approve(sources: ["https://example.com/\u0000"]), :invalid, "sources"
          assert_failure approve(sources: ["https://example.com/\xFF".b.force_encoding("UTF-8")]), :invalid, "sources"
          assert_equal "pending", fresh(@submission).review_status
        end
      end
    end
  end
end
