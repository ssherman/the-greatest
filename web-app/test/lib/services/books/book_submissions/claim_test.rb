require "test_helper"

module Services
  module Books
    module BookSubmissions
      class ClaimTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          @admin = users(:admin_user)
          # Other tests' fixtures may be reviewable; start from an empty queue.
          ::Books::BookSubmission.where(review_status: %i[pending not_needed]).where(status: %i[added needs_details failed]).update_all(review_status: ::Books::BookSubmission.review_statuses[:approved])
        end

        test "hands out pending reviews, needs_details and failed rows under one lease, oldest first" do
          older = reviewable_submission(created_at: 3.days.ago)
          details = reviewable_submission(book: nil, review_status: :not_needed, status: :needs_details, created_at: 2.days.ago)
          failed = reviewable_submission(book: nil, review_status: :not_needed, status: :failed, created_at: 1.day.ago)

          result = Claim.call(user: @admin)

          assert_success result
          assert_equal [older.id, details.id, failed.id], result.data[:items].map(&:id)
          token = result.data[:lease_token]
          assert_predicate token, :present?
          assert_in_delta 30.minutes.from_now.to_f, result.data[:lease_expires_at].to_f, 5
          [older, details, failed].each do |row|
            row.reload
            assert_equal [token, @admin.id, 1], [row.lease_token, row.claimed_by_id, row.claims]
          end
          assert_equal 0, result.data[:remaining]
        end

        test "never hands out needs_human, a cancelled row, a closed review or a held lease" do
          reviewable_submission(review_status: :needs_human)
          reviewable_submission(book: nil, review_status: :not_needed, status: :cancelled)
          reviewable_submission(review_status: :approved)
          reviewable_submission(review_status: :rejected)
          lease(reviewable_submission)
          reviewable_submission(review_status: :not_needed)

          result = Claim.call(user: @admin)

          assert_empty result.data[:items]
          assert_nil result.data[:lease_token]
        end

        test "an expired lease can be claimed again, and the old token no longer matches" do
          row = lease(reviewable_submission, token: "old", expires_at: 1.minute.ago)
          row.update_columns(claims: 1)

          result = Claim.call(user: @admin)

          assert_equal [row.id], result.data[:items].map(&:id)
          row.reload
          assert_not_equal "old", row.lease_token
          assert_equal 2, row.claims
        end

        test "a row already claimed three times becomes needs_human with a note and is not handed out" do
          row = reviewable_submission
          row.update_columns(claims: 3, lease_token: "gone", lease_expires_at: 1.hour.ago)
          other = reviewable_submission

          result = Claim.call(user: @admin, limit: 1)

          assert_equal [other.id], result.data[:items].map(&:id)
          row.reload
          assert_equal ["needs_human", "abandoned by agents", nil, "system"], [row.review_status, row.review_note, row.lease_token, row.reviewed_via]
        end

        test "lookup retries on the row do not count as claims" do
          row = reviewable_submission(attempts: 7, sweeps: 5)

          result = Claim.call(user: @admin)

          assert_equal [row.id], result.data[:items].map(&:id)
          assert_equal [7, 1], [row.reload.attempts, row.claims]
        end

        test "limit is 1 to 25 and remaining counts what is left" do
          3.times { reviewable_submission }

          assert_failure Claim.call(user: @admin, limit: 0), :invalid
          assert_failure Claim.call(user: @admin, limit: 26), :invalid
          assert_failure Claim.call(user: @admin, limit: "5"), :invalid

          result = Claim.call(user: @admin, limit: 2)
          assert_equal [2, 1], [result.data[:items].size, result.data[:remaining]]
        end

        test "an empty queue answers with no items and no token" do
          result = Claim.call(user: @admin)

          assert_success result
          assert_equal [[], nil, 0], [result.data[:items], result.data[:lease_token], result.data[:remaining]]
        end
      end
    end
  end
end
