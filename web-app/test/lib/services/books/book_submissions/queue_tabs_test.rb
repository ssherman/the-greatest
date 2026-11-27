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

        test "admin rows are in neither agent tab" do
          admin_review = reviewable_submission(origin: :admin)
          admin_details = reviewable_submission(book: nil, status: :needs_details, created_book: false, origin: :admin)

          assert_not_includes ids("needs_review") + ids("needs_details"), admin_review.id
          assert_not_includes ids("needs_review") + ids("needs_details"), admin_details.id
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

        # The tabs a person or an agent works from: every row in one must offer something to do.
        WORK_TABS = %w[needs_review needs_details needs_human failed].freeze

        def assert_every_work_row_has_an_action
          WORK_TABS.each do |tab|
            # Not the fixture: no service leaves an added, pending row without its book.
            QueueTabs.scope(tab).where.not(id: books_book_submissions(:added_title_authors).id).includes(book: :submissions).each do |row|
              assert_not_empty RowActions.for(row), "#{tab}: #{row.status} #{row.review_status}, book #{row.book_id.inspect}"
            end
          end
        end

        def human_count = [QueueTabs.counts["needs_human"], ::Services::AgentPrompts.call(domain: :books, queue: :book_submissions)[/(\d+) waiting for a person/, 1].to_i]

        test "a needs_human request the reader cancels or replaces leaves the tab, its count and the prompt's count" do
          reader = users(:regular_user)
          cancelled = reviewable_submission(book: nil, status: :needs_details, review_status: :needs_human, created_book: false)
          replaced = reviewable_submission(book: nil, status: :failed, review_status: :needs_human, created_book: false)
          before = human_count
          assert_equal before.first, before.last

          assert Cancel.call(user: reader, id: cancelled.id).success?
          assert_not_includes ids("needs_human"), cancelled.id
          assert_equal [before.first - 1] * 2, human_count

          submitted = Submit.call(user: reader, list: replaced.user_list, replaces: replaced.id,
            params: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/424242"})
          assert submitted.success?, submitted.errors.inspect
          assert_not_includes ids("needs_human"), replaced.id
          assert_equal [before.first - 2] * 2, human_count
          assert_every_work_row_has_an_action
        end

        test "a request the job cancels because its list is gone waits in no tab, whatever its review was" do
          list = ::Books::UserList.create!(user: users(:regular_user), name: "Going", list_type: :custom)
          human = reviewable_submission(book: nil, status: :needs_details, review_status: :needs_human, created_book: false, user_list: list)
          failed = reviewable_submission(book: nil, status: :failed, review_status: :needs_human, created_book: false, user_list: list)
          assert SupplyDetails.call(submission: human, title: "T", author_names: ["A"], user: users(:admin_user), via: "admin_ui", note: "n").success?
          assert Retry.call(submission: failed, user: users(:admin_user)).success?
          list.destroy!

          [human, failed].each { |row| ProcessSubmission.call(submission: ::Books::BookSubmission.find(row.id)) }

          assert_equal [%w[cancelled not_needed]] * 2, [human, failed].map { |row| fresh(row).then { [it.status, it.review_status] } }
          assert_empty [human.id, failed.id] & WORK_TABS.flat_map { |tab| ids(tab) }
        end

        test "a rejection leaves nothing to work, whatever the rows on the book were doing" do
          book = @review.book
          others = %i[queued looking_up failed].flat_map do |status|
            %i[pending needs_human].map { |review| reviewable_submission(book: book, status: status, review_status: review) }
          end

          assert_success Reject.call(submission: @review, user: users(:admin_user), via: "admin_ui", note: "not a book")

          rows = [@review, *others]
          assert_equal ["rejected"], rows.map { |row| fresh(row).review_status }.uniq
          assert_empty rows.map(&:id) & WORK_TABS.flat_map { |tab| ids(tab) }
          assert_every_work_row_has_an_action
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
