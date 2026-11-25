require "test_helper"

module Services
  module Books
    module BookSubmissions
      class CancelTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @list = user_lists(:regular_user_books_favorites)
        end

        def row(status: :queued, user: @user, **attrs)
          ::Books::BookSubmission.create!({
            user: user, user_list: @list, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            status: status, fingerprint: SecureRandom.hex(4)
          }.merge(attrs))
        end

        test "cancels each open status" do
          %i[queued looking_up needs_details].each do |status|
            submission = row(status: status)

            assert Cancel.call(user: @user, id: submission.id).success?
            assert_equal "cancelled", submission.reload.status
          end
        end

        test "refuses finished rows" do
          %i[added failed cancelled].each do |status|
            submission = row(status: status)

            refute Cancel.call(user: @user, id: submission.id).success?
            assert_equal status.to_s, submission.reload.status
          end
        end

        test "refuses once a book exists" do
          submission = row(status: :looking_up, book: ::Books::Book.create!(title: "Made"))

          refute Cancel.call(user: @user, id: submission.id).success?
          assert_equal "looking_up", submission.reload.status
        end

        test "refuses another user's row" do
          submission = row(user: users(:editor_user))

          refute Cancel.call(user: @user, id: submission.id).success?
          assert_equal "queued", submission.reload.status
        end

        test "takes the match decision out of the review queue" do
          submission = row
          decision = MatchDecision.create!(finder: "t", outcome: :unmatched, confidence: :low, decided_by: :fallback, subject: submission, needs_review: true)

          Cancel.call(user: @user, id: submission.id)

          refute decision.reload.needs_review
        end

        test "leaves the queue alone when the cancel is refused" do
          submission = row(status: :added)
          decision = MatchDecision.create!(finder: "t", outcome: :unmatched, confidence: :low, decided_by: :fallback, subject: submission, needs_review: true)

          Cancel.call(user: @user, id: submission.id)

          assert decision.reload.needs_review
        end

        test "a cancelled needs_human row leaves the review tabs and keeps its note" do
          submission = row(status: :needs_details, review_status: :needs_human, review_note: "abandoned by agents")

          assert Cancel.call(user: @user, id: submission.id).success?

          submission.reload
          assert_equal ["cancelled", "not_needed", "abandoned by agents"], [submission.status, submission.review_status, submission.review_note]
        end

        test "a cancel changes no other review status" do
          (::Books::BookSubmission.review_statuses.keys - %w[needs_human]).each do |review|
            submission = row(status: :needs_details, review_status: review)

            assert Cancel.call(user: @user, id: submission.id).success?
            assert_equal review, submission.reload.review_status
          end
        end
      end
    end
  end
end
