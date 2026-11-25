require "test_helper"

module Services
  module Books
    module BookSubmissions
      class RowActionsTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup { stub_review_side_effects }

        def actions(row) = RowActions.for(::Books::BookSubmission.includes(book: :submissions).find(row.id))

        test "a pending row with a provisional book can be approved, merged and rejected" do
          assert_equal %i[approve merge reject], actions(reviewable_submission)
        end

        test "a needs_human row keeps the three decisions" do
          assert_equal %i[approve merge reject], actions(reviewable_submission(review_status: :needs_human))
        end

        test "a settled row has no actions" do
          %i[approved merged rejected].each do |review|
            assert_equal [], actions(reviewable_submission(review_status: review)), review
          end
        end

        test "a row whose book is already public cannot be merged or rejected" do
          row = reviewable_submission
          row.book.update_columns(provisional: false)

          assert_equal %i[approve], actions(row)
        end

        test "a book no submission created cannot be rejected" do
          row = reviewable_submission(created_book: false)

          assert_equal %i[approve merge], actions(row)
        end

        test "a row with no book can be supplied; a failed one can also be retried" do
          stuck = reviewable_submission(book: nil, status: :needs_details, review_status: :not_needed, created_book: false)
          failed = reviewable_submission(book: nil, status: :failed, review_status: :needs_human, created_book: false)

          assert_equal %i[supply_details], actions(stuck)
          assert_equal %i[supply_details retry], actions(failed)
        end

        test "a row still being looked up has no actions" do
          assert_equal [], actions(reviewable_submission(book: nil, status: :looking_up, review_status: :not_needed, created_book: false))
        end

        test "a failed row with a book is decided or retried, not supplied" do
          row = reviewable_submission(status: :failed, review_status: :needs_human)

          assert_equal %i[approve merge reject retry], actions(row)
        end

        test "the supply and retry offers match what their services accept" do
          admin = users(:admin_user)
          failed = reviewable_submission(book: nil, status: :failed, review_status: :needs_human, created_book: false)
          assert_includes actions(failed), :supply_details
          supplied = SupplyDetails.call(submission: failed, title: "A Title", author_names: ["An Author"], user: admin, via: "admin_ui", note: "found it")
          assert supplied.success?, supplied.errors.inspect

          again = reviewable_submission(book: nil, status: :failed, review_status: :needs_human, created_book: false)
          assert_includes actions(again), :retry
          assert Retry.call(submission: again, user: admin).success?
        end

        test "a rejected failed row is offered no retry, and the service refuses it" do
          rejected = reviewable_submission(book: nil, status: :failed, review_status: :rejected, created_book: false)

          assert_equal [], actions(rejected)
          assert_not Retry.call(submission: rejected, user: users(:admin_user)).success?
        end
      end
    end
  end
end
