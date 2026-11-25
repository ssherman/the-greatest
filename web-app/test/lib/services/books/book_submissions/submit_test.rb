require "test_helper"

module Services
  module Books
    module BookSubmissions
      class SubmitTest < ActiveSupport::TestCase
        GOODREADS = {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/13651"}.freeze

        setup do
          @user = users(:regular_user)
          @list = user_lists(:regular_user_books_favorites)
          @user.book_submissions.delete_all
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
        end

        def submit(params = GOODREADS, **options)
          Submit.call(user: @user, list: @list, params: params, **options)
        end

        def goodreads(id) = {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/#{id}"}

        def other_list = @user.user_lists.where(type: "Books::UserList").where.not(id: @list.id).first

        def row(status: :queued, user: @user, list: @list, created_at: Time.current, **attrs)
          ::Books::BookSubmission.create!({
            user: user, user_list: list, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            status: status, created_at: created_at, fingerprint: SecureRandom.hex(4)
          }.merge(attrs))
        end

        def hold_goodreads_book
          book = ::Books::Book.create!(title: "Already Here")
          Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "13651", source: :open_library)
          book
        end

        test "creates a queued submission on the list and queues the job after it is saved" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with { |id| ::Books::BookSubmission.exists?(id) }

          result = submit

          assert result.success?
          assert_equal :created, result.data[:outcome]
          submission = result.data[:submission]
          assert_equal [@user.id, @list.id, "queued", 13651], [submission.user_id, submission.user_list_id, submission.status, submission.goodreads_book_id]
          assert submission.fingerprint.present?
        end

        test "a replayed request returns the open submission and makes no second row" do
          first = submit.data[:submission]
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never

          again = submit

          assert_equal :existing, again.data[:outcome]
          assert_equal first.id, again.data[:submission].id
          assert_equal 1, @user.book_submissions.count
        end

        test "a dismissed or finished submission is not an open one" do
          first = submit.data[:submission]
          first.update_columns(dismissed_at: Time.current)
          assert_equal :created, submit.data[:outcome]

          @user.book_submissions.update_all(status: ::Books::BookSubmission.statuses[:added])
          assert_equal :created, submit.data[:outcome]
        end

        test "the same input for another list is a new submission" do
          submit

          result = Submit.call(user: @user, list: other_list, params: GOODREADS)

          assert_equal :created, result.data[:outcome]
        end

        test "the twentieth in 24 hours is made and the twenty-first is refused without a row" do
          19.times { row }
          assert_equal :created, submit.data[:outcome]

          refused = submit(goodreads(99))

          refute refused.success?
          assert_equal 20, @user.book_submissions.count
        end

        test "the cap counts every status and ignores rows older than 24 hours" do
          %i[queued looking_up needs_details added failed cancelled].each { |status| row(status: status) }
          14.times { row(created_at: 25.hours.ago) }

          assert_equal :created, submit.data[:outcome]
        end

        test "the cap counts rows made in the last 24 hours even when they are old news" do
          20.times { |index| row(created_at: (23 * 60 + index).minutes.ago, status: :cancelled) }

          refute submit.success?
        end

        test "a replayed request at the cap still answers with the open submission" do
          first = submit.data[:submission]
          19.times { row(status: :added) }

          assert_equal first.id, submit.data[:submission].id
        end

        test "the limit comes from config" do
          config = Rails.application.config.x.book_submissions
          config.stubs(:daily_limit).returns(2)
          2.times { row }

          refute submit.success?
        end

        test "the cap counts the row a request replaces" do
          19.times { row }
          old = row(status: :needs_details)

          refute submit(GOODREADS, replaces: old.id).success?
          assert_equal "needs_details", old.reload.status
        end

        test "another user's rows do not count" do
          25.times { row(user: users(:editor_user), list: nil) }

          assert_equal :created, submit.data[:outcome]
        end

        test "hits are returned and create nothing" do
          book = hold_goodreads_book

          result = submit

          assert_equal :hits, result.data[:outcome]
          assert_equal [book.id], result.data[:books].map(&:id)
          assert_equal 0, @user.book_submissions.count
        end

        test "confirmed_new skips the instant check" do
          hold_goodreads_book

          assert_equal :created, submit(GOODREADS, confirmed_new: true).data[:outcome]
        end

        test "hits do not count toward the cap" do
          19.times { row }
          hold_goodreads_book

          assert_equal :hits, submit.data[:outcome]
          assert_equal :created, submit(goodreads(77)).data[:outcome]
        end

        test "invalid input fails with the parser's message and no row" do
          result = submit({method: "goodreads", goodreads_url: "https://example.com/x"})

          refute result.success?
          assert_predicate result.errors, :any?
          assert_equal 0, @user.book_submissions.count
        end

        test "two methods in one request fail" do
          refute submit(GOODREADS.merge(isbn: "9780441478125")).success?
        end

        test "replaces cancels the user's own needs_details row on the same list" do
          old = row(status: :needs_details)

          assert_equal :created, submit(GOODREADS, replaces: old.id).data[:outcome]
          assert_equal "cancelled", old.reload.status
        end

        test "replacing a needs_human row takes it out of the review tabs and keeps its note" do
          %i[needs_details failed].each_with_index do |status, index|
            old = row(status: status, review_status: :needs_human, review_note: "a person must look")

            assert_equal :created, submit(goodreads(300 + index), replaces: old.id).data[:outcome]
            old.reload
            assert_equal ["cancelled", "not_needed", "a person must look"], [old.status, old.review_status, old.review_note]
          end
        end

        test "replaces works for a needs_details row, even when the new input is the old row's input" do
          fingerprint = ParseInput.call(GOODREADS).data[:fingerprint]
          old = row(status: :needs_details, goodreads_book_id: 13651, fingerprint: fingerprint)

          result = submit(GOODREADS, replaces: old.id)

          assert_equal :created, result.data[:outcome]
          refute_equal old.id, result.data[:submission].id
          assert_equal "cancelled", old.reload.status
        end

        test "replaces ignores rows that do not qualify" do
          queued = row(status: :queued)
          booked = row(status: :failed, book: ::Books::Book.create!(title: "Has book"))
          others = row(status: :needs_details, user: users(:editor_user))
          elsewhere = row(status: :needs_details, list: other_list)
          candidates = [queued, booked, others, elsewhere]

          candidates.each_with_index do |candidate, index|
            assert_equal :created, submit(goodreads(100 + index), replaces: candidate.id).data[:outcome]
          end

          assert_equal %w[queued failed needs_details needs_details], candidates.map { |r| r.reload.status }
        end

        test "replaces with junk is ignored" do
          assert_equal :created, submit(GOODREADS, replaces: "nope").data[:outcome]
          assert_equal :created, submit(goodreads(5), replaces: ["1"]).data[:outcome]
        end

        test "cancelling the replaced row clears its review flag" do
          old = row(status: :needs_details)
          decision = MatchDecision.create!(finder: "t", outcome: :unmatched, confidence: :low, decided_by: :fallback, subject: old, needs_review: true)

          submit(GOODREADS, replaces: old.id)

          refute decision.reload.needs_review
        end

        test "the duplicate check, the count and the insert run after the user's row is locked" do
          statements = []
          subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

          submit

          lock = statements.index { |sql| sql.match?(/FROM "users".*FOR UPDATE/m) }
          count = statements.index { |sql| sql.match?(/COUNT.*books_book_submissions/m) }
          insert = statements.index { |sql| sql.match?(/INSERT INTO "books_book_submissions"/) }
          assert lock
          assert lock < count
          assert count < insert
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        end

        test "a failed enqueue still leaves the row and answers success" do
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async).raises(RedisClient::CannotConnectError, "down")

          result = submit

          assert result.success?
          assert_equal :created, result.data[:outcome]
          assert ::Books::BookSubmission.exists?(result.data[:submission].id)
        end

        test "a list deleted after it was looked up is a refusal, not an error, and makes no row" do
          list = ::Books::UserList.create!(user: @user, name: "Going", list_type: :custom)
          ::UserList.where(id: list.id).delete_all
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never

          result = Submit.call(user: @user, list: list, params: GOODREADS)

          refute result.success?
          assert_equal :gone, result.data[:reason]
          assert_predicate result.errors, :any?
          assert_equal 0, @user.book_submissions.count
        end

        test "a list deleted meanwhile leaves the request being replaced as it was" do
          list = ::Books::UserList.create!(user: @user, name: "Going", list_type: :custom)
          old = row(status: :failed, list: list)
          ::Books::BookSubmission.stubs(:create!).raises(ActiveRecord::InvalidForeignKey, "gone")

          refute Submit.call(user: @user, list: list, params: GOODREADS, replaces: old.id).success?
          assert_equal "failed", old.reload.status
        end

        test "a title and authors request with an author array is accepted" do
          result = submit({method: "title_authors", title: "The Dispossessed", authors: ["Ursula K. Le Guin"]})

          assert_equal :created, result.data[:outcome]
        end

        test "params of the wrong type fail without raising" do
          [nil, "x", [1], {method: ["goodreads"]}, {method: "title_authors", title: {a: 1}, authors: {a: 1}}].each do |junk|
            refute submit(junk).success?
          end
        end
      end
    end
  end
end
