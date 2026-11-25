require "test_helper"

module Services
  module Books
    module BookSubmissions
      # A book deleted while a submission for it is still in progress must not be
      # made again by a job that resumes afterwards.
      class RejectedResumeTest < ActiveSupport::TestCase
        include GoodreadsImportHelper
        include BookSubmissionHelper

        setup do
          stub_resolution_services
          freeze_time
          ::Books::PurgeShowPagesJob.stubs(:perform_async)
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
          @editor = users(:editor_user)
          @editor_list = ::Books::UserList.create!(user: @editor, name: "Editor read", list_type: :read)
          @book = ::Books::Book.create!(title: "Doomed In Flight", provisional: true)
          @creator = row(user: users(:regular_user), list: user_lists(:regular_user_books_read), review_status: :pending, created_book: true)
          @second = row(user: @editor, list: @editor_list, review_status: :not_needed, created_book: false)
        end

        def row(user:, list:, **attrs)
          book_submission(user: user, list: list, input_method: :goodreads, goodreads_book_id: rand(1_000_000..9_999_999),
            typed_title: nil, typed_author_names: nil, status: :looking_up, book: @book, **attrs)
        end

        def destroy_book = @book.destroy!

        def snapshot = [::Books::Book.count, UserListItem.count, ::Books::BookSubmission.where(id: [@creator.id, @second.id]).pluck(:id, :status, :review_status, :book_id)]

        test "destroying a book closes in-progress rows as cancelled and rejected" do
          destroy_book

          [@creator, @second].each do |submission|
            submission.reload
            assert_equal ["cancelled", "rejected", nil], [submission.status, submission.review_status, submission.book_id]
          end
        end

        test "a queued row is cancelled too, and a row that is not in progress keeps its status" do
          queued = row(user: users(:regular_user), list: user_lists(:regular_user_books_read), review_status: :pending, status: :queued)
          failed = row(user: users(:regular_user), list: user_lists(:regular_user_books_read), review_status: :pending, status: :failed)

          destroy_book

          assert_equal %w[cancelled failed], [queued.reload.status, failed.reload.status]
        end

        test "a process job, a fetch job and the sweep after the delete create nothing, for the creator and a second reader" do
          destroy_book
          before = snapshot
          ::Books::Goodreads::GateTurn.expects(:call).never
          ::Services::Books::GoodreadsPages::FetchPage.expects(:call).never
          [@creator, @second].each { |submission| submission.update_columns(updated_at: 2.hours.ago) }

          [@creator, @second].each do |submission|
            ::Books::ProcessBookSubmissionJob.new.perform(submission.id)
            ::Books::FetchSubmissionGoodreadsPageJob.new.perform(submission.id)
          end
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never
          ::Books::RequeueStuckBookSubmissionsJob.new.perform

          assert_equal before, snapshot
        end

        test "an in-progress row whose review is rejected is not claimed" do
          @creator.update_columns(book_id: nil, review_status: ::Books::BookSubmission.review_statuses[:rejected], processing_started_at: nil)

          result = ProcessSubmission.call(submission: @creator.reload)

          assert_equal :done, result.data[:outcome]
          assert_nil @creator.reload.processing_started_at
        end

        test "CreateBook under its lock refuses an in-progress row whose review is rejected" do
          @creator.update_columns(book_id: nil, review_status: ::Books::BookSubmission.review_statuses[:rejected])

          result = CreateBook.call(submission: @creator.reload, resolved: resolved_facts, match: finder_match(subject: @creator))

          assert_equal [false, :aborted], [result.success?, result.data[:outcome]]
          assert_nil @creator.reload.book_id
        end

        test "the sweep leaves an in-progress row whose review is rejected alone" do
          @creator.update_columns(review_status: ::Books::BookSubmission.review_statuses[:rejected], updated_at: 2.hours.ago, sweeps: 0)
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never

          ::Books::RequeueStuckBookSubmissionsJob.new.perform

          assert_equal 0, @creator.reload.sweeps
        end
      end
    end
  end
end
