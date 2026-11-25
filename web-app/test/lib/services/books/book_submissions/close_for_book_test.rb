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

        test "a closed failed or needs_details row leaves the agent queue, whichever way it was closed" do
          %i[approved merged rejected].each do |review_status|
            %i[failed needs_details].each do |status|
              row = submission(status: status)
              assert_includes ::Books::BookSubmission.claimable, row

              close(review_status: review_status)

              row.reload
              assert_not_includes ::Books::BookSubmission.reviewable, row, "#{status} #{review_status}"
              assert_not_includes ::Books::BookSubmission.claimable, row, "#{status} #{review_status}"
            end
          end
        end

        test "a failed or needs_details row that is open still shows in the queue, and a needs_human one does not" do
          open = %i[failed needs_details].map { |status| submission(book: nil, status: status, review_status: :not_needed, created_book: false) }
          pending = submission(status: :failed)
          flagged = submission(status: :failed, review_status: :needs_human)
          resumable = submission(status: :failed, review_status: :not_needed, created_book: false)

          assert_equal [], (open + [pending]) - ::Books::BookSubmission.reviewable.to_a
          assert_not_includes ::Books::BookSubmission.reviewable, flagged
          assert_not_includes ::Books::BookSubmission.reviewable, resumable
        end

        test "reviewable and claimable still compose in a chain" do
          mine = submission(status: :failed)
          other = submission(status: :failed, user: @admin)
          done = submission(status: :failed)
          close(submission_ids: [done.id])

          chained = ::Books::BookSubmission.where(user_id: @user.id).reviewable
          assert_equal [mine.id], chained.where(id: [mine.id, other.id, done.id]).pluck(:id)
          assert_equal [mine.id], ::Books::BookSubmission.where(user_id: @user.id).claimable.where(id: [mine.id, done.id]).pluck(:id)
          assert_equal [other.id], ::Books::BookSubmission.reviewable.where(user_id: @admin.id).pluck(:id)
          assert_equal [mine.id], ::Books::BookSubmission.reviewable.claimable.where(user_id: @user.id, id: [mine.id, done.id]).pluck(:id)
        end

        test "a rejection cancels rows still in progress, and nothing else changes status" do
          queued = submission(status: :queued)
          looking = submission(status: :looking_up)
          added = submission

          close(review_status: :rejected)

          assert_equal %w[cancelled cancelled added], [queued, looking, added].map { it.reload.status }
        end

        test "an approval or merge leaves an in-progress row's status alone" do
          looking = submission(status: :looking_up)

          close(review_status: :merged)

          assert_equal "looking_up", looking.reload.status
        end

        test "a note is kept when none is given, and replaced when one is" do
          flagged = submission(review_status: :needs_human, review_note: "needs a person")

          close
          assert_equal "needs a person", flagged.reload.review_note

          again = submission(review_note: "old")
          close(note: "new")
          assert_equal "new", again.reload.review_note
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
