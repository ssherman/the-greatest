require "test_helper"

module Services
  module Books
    module BookSubmissions
      class DismissTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
        end

        def row(status:, user: @user)
          ::Books::BookSubmission.create!(
            user: user, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            status: status, fingerprint: SecureRandom.hex(4)
          )
        end

        test "dismisses each finished status" do
          %i[added failed cancelled].each do |status|
            submission = row(status: status)

            assert Dismiss.call(user: @user, id: submission.id).success?
            assert_not_nil submission.reload.dismissed_at
          end
        end

        test "refuses open rows" do
          %i[queued looking_up needs_details].each do |status|
            submission = row(status: status)

            refute Dismiss.call(user: @user, id: submission.id).success?
            assert_nil submission.reload.dismissed_at
          end
        end

        test "refuses another user's row" do
          submission = row(status: :added, user: users(:editor_user))

          refute Dismiss.call(user: @user, id: submission.id).success?
          assert_nil submission.reload.dismissed_at
        end

        test "dismissing twice keeps the first time and succeeds" do
          submission = row(status: :added)
          Dismiss.call(user: @user, id: submission.id)
          first = submission.reload.dismissed_at

          assert Dismiss.call(user: @user, id: submission.id).success?
          assert_equal first, submission.reload.dismissed_at
        end
      end
    end
  end
end
