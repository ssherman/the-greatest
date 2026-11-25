require "test_helper"

module Services
  module Books
    module BookSubmissions
      class CloseForBookTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @admin = users(:admin_user)
          @book = ::Books::Book.create!(title: "Closing Book", provisional: true)
        end

        teardown { Current.reset }

        def submission(book: @book, review_status: :pending, status: :added, **attrs)
          ::Books::BookSubmission.create!({
            user: @user, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            fingerprint: SecureRandom.hex(4), status: status, review_status: review_status,
            created_book: true, book: book
          }.merge(attrs))
        end

        def close(**args)
          CloseForBook.call(book_ids: [@book.id], review_status: :approved, **args)
        end

        test "closes pending and needs_human rows with the reviewer, via and time" do
          pending = submission
          flagged = submission(review_status: :needs_human)

          close(user: @admin, via: "api", note: "settled")

          [pending, flagged].each do |row|
            row.reload
            assert_equal ["approved", "api", @admin.id, "settled"], [row.review_status, row.reviewed_via, row.reviewed_by_id, row.review_note]
            assert_not_nil row.reviewed_at
          end
        end

        test "takes the acting user and via from Current, and falls back to system" do
          Current.acting_user = @admin
          Current.acting_via = "admin_ui"
          first = submission
          close
          assert_equal ["admin_ui", @admin.id], [first.reload.reviewed_via, first.reviewed_by_id]

          Current.reset
          second = submission
          close
          assert_equal ["system", nil], [second.reload.reviewed_via, second.reviewed_by_id]
        end

        test "an unknown via is recorded as system rather than raising" do
          row = submission

          close(via: "carrier_pigeon")

          assert_equal "system", row.reload.reviewed_via
        end

        test "clears the lease and takes the row out of the agent queue" do
          row = submission(lease_token: "tok", lease_expires_at: 1.hour.ago, claimed_by: @admin)
          assert_includes ::Books::BookSubmission.claimable, row

          close

          row.reload
          assert_nil row.lease_token
          assert_nil row.lease_expires_at
          assert_not_includes ::Books::BookSubmission.claimable, row
          assert_not_includes ::Books::BookSubmission.reviewable, row
        end

        test "leaves matched not_needed rows alone unless asked" do
          matched = submission(review_status: :not_needed, created_book: false)

          close
          assert_equal "not_needed", matched.reload.review_status

          close(include_matched: true, review_status: :rejected)
          assert_equal "rejected", matched.reload.review_status
        end

        test "a closed row is untouched" do
          done = submission(review_status: :approved, reviewed_via: :admin_ui, reviewed_by: @admin, reviewed_at: 2.days.ago, review_note: "mine")
          before = done.reload.attributes

          close(review_status: :rejected, include_matched: true)

          assert_equal before, done.reload.attributes
        end

        test "other books' rows are untouched" do
          other = submission(book: books_books(:war_and_peace))
          unrelated = submission(book: nil, status: :queued, review_status: :not_needed, created_book: false)

          close

          assert_equal ["pending", "not_needed"], [other.reload.review_status, unrelated.reload.review_status]
        end

        test "submission_ids narrows the close to those rows" do
          chosen = submission
          other = submission

          close(submission_ids: [chosen.id])

          assert_equal ["approved", "pending"], [chosen.reload.review_status, other.reload.review_status]
        end

        test "runs one query when the book has no submissions" do
          queries = []
          callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { close }

          assert_equal 1, queries.size
        end
      end
    end
  end
end
