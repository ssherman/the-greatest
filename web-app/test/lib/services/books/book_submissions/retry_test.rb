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

        test "refuses a row that is not failed, has a book, or was rejected" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never
          @row.update_columns(status: ::Books::BookSubmission.statuses[:needs_details])
          assert_failure Retry.call(submission: @row, user: @admin), :conflict

          failed_with_book = reviewable_submission(status: :failed, review_status: :not_needed)
          assert_failure Retry.call(submission: failed_with_book, user: @admin), :conflict

          rejected = reviewable_submission(book: nil, status: :failed, review_status: :rejected)
          assert_failure Retry.call(submission: rejected, user: @admin), :conflict
          assert_equal "failed", fresh(rejected).status
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
