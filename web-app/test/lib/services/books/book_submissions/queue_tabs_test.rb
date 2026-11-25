require "test_helper"

module Services
  module Books
    module BookSubmissions
      class QueueTabsTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper
        include SqlCapture

        setup do
          stub_review_side_effects
          @review = reviewable_submission
          @details = reviewable_submission(book: nil, status: :needs_details, created_book: false)
          @human = reviewable_submission(review_status: :needs_human)
          @approved = reviewable_submission(review_status: :approved)
          @merged = reviewable_submission(review_status: :merged)
          @rejected = reviewable_submission(review_status: :rejected, book: nil)
          @failed = reviewable_submission(book: nil, status: :failed, review_status: :not_needed, created_book: false)
          @looking = reviewable_submission(book: nil, status: :looking_up, review_status: :not_needed, created_book: false)
        end

        def ids(tab) = QueueTabs.scope(tab).pluck(:id)

        test "each tab holds the rows its name says" do
          assert_includes ids("needs_review"), @review.id
          assert_not_includes ids("needs_review"), @details.id
          assert_includes ids("needs_details"), @details.id
          assert_includes ids("needs_details"), @failed.id
          assert_not_includes ids("needs_details"), @review.id
          assert_includes ids("needs_human"), @human.id
          assert_includes ids("approved"), @approved.id
          assert_includes ids("merged"), @merged.id
          assert_includes ids("rejected"), @rejected.id
          assert_includes ids("failed"), @failed.id
          assert_not_includes ids("failed"), @looking.id
          assert_includes ids("all"), @looking.id
        end

        test "needs review and needs details leave out a row nobody can act on" do
          assert_not_includes ids("needs_review") + ids("needs_details"), @looking.id
          assert_not_includes ids("needs_review") + ids("needs_details"), @human.id
        end

        test "counts agree with the tabs and cost one query" do
          counts = nil
          queries = capture_sql { counts = QueueTabs.counts }

          assert_equal 1, queries.size
          assert_equal QueueTabs::KEYS, counts.keys
          QueueTabs::KEYS.each { |tab| assert_equal QueueTabs.scope(tab).count, counts[tab], tab }
        end

        test "an unknown tab falls back to needs review" do
          assert_equal "needs_review", QueueTabs.valid("nope")
          assert_equal "needs_review", QueueTabs.valid(nil)
          assert_equal "merged", QueueTabs.valid("merged")
        end
      end
    end
  end
end
