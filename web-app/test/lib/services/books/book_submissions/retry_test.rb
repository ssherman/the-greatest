require "test_helper"

module Services
  module Books
    module BookSubmissions
      class RetryTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          @admin = users(:admin_user)
          @row = reviewable_submission(book: nil, review_status: :not_needed, status: :failed, error: "lost job", attempts: 4,
            blocked_fetches: 2, sweeps: 3, fetch_errors: 3, claims: 2, next_attempt_at: 1.hour.ago, processing_started_at: 2.hours.ago)
          lease(@row)
        end

        test "puts a failed row back to queued with every counter reset, and queues the job" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(@row.id).once

          result = Retry.call(submission: @row, user: @admin)

          assert_success result
          row = fresh(@row)
          assert_equal ["queued", nil, 0, 0, 0, 0, 0, nil, nil, nil, nil],
            [row.status, row.error, row.attempts, row.blocked_fetches, row.sweeps, row.fetch_errors, row.claims,
              row.next_attempt_at, row.processing_started_at, row.lease_token, row.lease_expires_at]
        end

        test "a pending review stays pending" do
          @row.update_columns(review_status: ::Books::BookSubmission.review_statuses[:pending])
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)

          assert_success Retry.call(submission: @row, user: @admin)
          assert_equal "pending", fresh(@row).review_status
        end

        test "refuses a row that is not failed or was rejected" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never
          @row.update_columns(status: ::Books::BookSubmission.statuses[:needs_details])
          assert_failure Retry.call(submission: @row, user: @admin), :conflict

          rejected = reviewable_submission(book: nil, status: :failed, review_status: :rejected)
          assert_failure Retry.call(submission: rejected, user: @admin), :conflict
          rejected_with_book = reviewable_submission(status: :failed, review_status: :rejected)
          assert_failure Retry.call(submission: rejected_with_book, user: @admin), :conflict
          assert_equal "failed", fresh(rejected).status
        end

        test "a bookless row flagged needs_human goes back to not_needed" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(@row.id).once
          @row.update_columns(review_status: ::Books::BookSubmission.review_statuses[:needs_human])

          assert_success Retry.call(submission: @row, user: @admin)
          assert_equal ["queued", "not_needed"], [fresh(@row).status, fresh(@row).review_status]
        end

        test "a row that failed after it got a book keeps the book and its review, and the job is queued" do
          withbook = reviewable_submission(status: :failed, review_status: :not_needed, attempts: 5)
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(withbook.id).once

          assert_success Retry.call(submission: withbook, user: @admin)
          row = fresh(withbook)
          assert_equal ["queued", "not_needed", withbook.book_id, 0], [row.status, row.review_status, row.book_id, row.attempts]
        end

        test "a needs_human row that has a book keeps its review state" do
          flagged = reviewable_submission(status: :failed, review_status: :needs_human)
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)

          assert_success Retry.call(submission: flagged, user: @admin)
          assert_equal "needs_human", fresh(flagged).review_status
        end

        test "a job that cannot be queued does not undo the retry" do
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async).raises(RuntimeError, "redis is down")

          assert_success Retry.call(submission: @row, user: @admin)
          assert_equal "queued", fresh(@row).status
        end

        test "a stale copy cannot retry a row someone already retried" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).once
          stale = ::Books::BookSubmission.find(@row.id)
          assert_success Retry.call(submission: @row, user: @admin)

          assert_failure Retry.call(submission: stale, user: @admin), :conflict
        end
      end
    end
  end
end
