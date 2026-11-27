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

        test "an admin row has no actions" do
          assert_equal [], actions(reviewable_submission(origin: :admin))
          assert_equal [], actions(reviewable_submission(origin: :admin, book: nil, status: :failed, review_status: :not_needed))
        end

        test "a needs_human row keeps the three decisions" do
          assert_equal %i[approve merge reject], actions(reviewable_submission(review_status: :needs_human))
        end

        test "a settled row has no actions" do
          %i[approved merged rejected].each do |review|
            assert_equal [], actions(reviewable_submission(review_status: review)), review
          end
        end

        test "a row whose book is already public is offered no decision" do
          row = reviewable_submission
          row.book.update_columns(provisional: false)

          assert_equal [], actions(row)
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

        # Every offer is compared with what the service really answers, over every status, review
        # state and kind of book. Merge and reject are asked with dry_run (they answer the same
        # without destroying anything).
        test "the offers match what the services accept across the whole matrix" do
          admin = users(:admin_user)
          target = ::Books::Book.create!(title: "Catalog Target")
          kinds = %i[none provisional provisional_not_created public]
          mismatches = []
          checked = 0
          accepted = Hash.new(0)

          row_for = lambda do |status, review, kind|
            attrs = {status: status, review_status: review}
            attrs.update(book: nil, created_book: false) if kind == :none
            attrs[:created_book] = false if kind == :provisional_not_created
            row = reviewable_submission(**attrs)
            row.book.update_columns(provisional: false) if kind == :public
            row
          end
          offered = lambda do |row, action|
            RowActions.for(::Books::BookSubmission.includes(book: :submissions).find(row.id)).include?(action)
          end

          ::Books::BookSubmission.statuses.each_key do |status|
            ::Books::BookSubmission.review_statuses.each_key do |review|
              kinds.each do |kind|
                answers = {
                  approve: ->(row) { Approve.call(submission: row, user: admin, via: "admin_ui", note: "n").success? },
                  merge: ->(row) { Merge.call(submission: row, target_id: target.id, user: admin, via: "admin_ui", note: "n", dry_run: true).success? },
                  reject: ->(row) { Reject.call(submission: row, user: admin, via: "admin_ui", note: "n", dry_run: true).success? },
                  supply_details: ->(row) { SupplyDetails.call(submission: row, title: "T", author_names: ["A"], user: admin, via: "admin_ui", note: "n").success? },
                  retry: ->(row) { Retry.call(submission: row, user: admin).success? }
                }
                answers.each do |action, ask|
                  expected = offered.call(row_for.call(status, review, kind), action)
                  actual = ask.call(row_for.call(status, review, kind))
                  checked += 1
                  accepted[action] += 1 if actual
                  mismatches << [action, status, review, kind, "offered=#{expected} accepted=#{actual}"] if expected != actual
                end
              end
            end
          end

          assert_equal 6 * 6 * 4 * 5, checked
          assert_equal %i[approve merge reject retry supply_details].sort, accepted.keys.sort, "every action is accepted somewhere in the matrix"
          assert_equal [], mismatches, mismatches.first(10).inspect
        end
      end
    end
  end
end
