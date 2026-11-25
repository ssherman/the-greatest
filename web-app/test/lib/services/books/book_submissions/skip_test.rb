require "test_helper"

module Services
  module Books
    module BookSubmissions
      class SkipTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          @admin = users(:admin_user)
          @submission = lease(reviewable_submission)
        end

        def skip(submission = @submission, via: "api", lease_token: TOKEN, reason: "Cannot tell it from a box set")
          Skip.call(submission: submission, reason: reason, user: @admin, via: via, lease_token: lease_token)
        end

        test "hands the row to a human with the reason and clears the lease" do
          assert_success skip

          row = fresh(@submission)
          assert_equal ["needs_human", "Cannot tell it from a box set", nil, nil, @admin.id, "api"],
            [row.review_status, row.review_note, row.lease_token, row.lease_expires_at, row.reviewed_by_id, row.reviewed_via]
          assert_not_includes ::Books::BookSubmission.claimable.pluck(:id), row.id
        end

        test "the lease is judged before the reason" do
          assert_failure skip(lease_token: "x", reason: ""), :conflict
          @submission.update_columns(lease_expires_at: 1.minute.ago)
          assert_failure skip, :conflict
        end

        test "the reason is 1 to 1,000 characters" do
          assert_failure skip(reason: ""), :invalid
          assert_failure skip(reason: nil), :invalid
          assert_failure skip(reason: "x" * 1_001), :invalid
          assert_equal "pending", fresh(@submission).review_status
        end

        test "a row with no book can be skipped too" do
          row = lease(reviewable_submission(book: nil, review_status: :not_needed, status: :failed))

          assert_success skip(row)
          assert_equal "needs_human", fresh(row).review_status
        end

        test "refuses a row that is already closed or flagged" do
          assert_failure skip(lease(reviewable_submission(review_status: :approved))), :conflict
          assert_failure skip(lease(reviewable_submission(review_status: :needs_human))), :conflict
        end

        test "the admin page needs no lease" do
          assert_success skip(via: "admin_ui", lease_token: nil)
        end

        test "a second skip with the same token is a conflict" do
          assert_success skip
          assert_failure skip, :conflict
        end
      end
    end
  end
end
