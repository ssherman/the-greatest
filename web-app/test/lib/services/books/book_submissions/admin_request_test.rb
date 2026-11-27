require "test_helper"

module Services
  module Books
    module BookSubmissions
      class AdminRequestTest < ActiveSupport::TestCase
        GOODREADS = {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/13651"}.freeze

        setup do
          @user = users(:regular_user)
          @list = lists(:books_list)
          @user.book_submissions.delete_all
          ::Books::BookSubmission.where.not(origin: :reader).delete_all
          ::Books::ProcessBookSubmissionJob.stubs(:perform_async)
        end

        def request_book(params = GOODREADS, **options)
          AdminRequest.call(user: @user, params: params, **options)
        end

        test "a book we hold comes back as hits and nothing is written" do
          book = ::Books::Book.create!(title: "Already Here")
          Identifier.create!(identifiable: book, identifier_type: :books_work_goodreads_id, value: "13651", source: :open_library)

          result = request_book(list: @list, position: 3)

          assert result.success?
          assert_equal :hits, result.data[:outcome]
          assert_includes result.data[:books].map(&:id), book.id
          assert_equal 0, ::Books::BookSubmission.origin_admin.count
        end

        test "confirmed_new skips the check and queues the job" do
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).with(kind_of(Integer))

          result = request_book(list: @list, position: 12, confirmed_new: true)

          assert_equal :created, result.data[:outcome]
          submission = result.data[:submission]
          assert submission.origin_admin?
          assert_equal "queued", submission.status
          assert_nil submission.user_list_id
          assert_equal [@list.id, 12], [submission.list_id, submission.list_position]
        end

        test "no list makes a plain import request" do
          result = request_book

          assert_equal :created, result.data[:outcome]
          assert_nil result.data[:submission].list_id
          assert_nil result.data[:submission].list_position
        end

        test "the reader daily cap does not apply" do
          Rails.application.config.x.book_submissions.stubs(:daily_limit).returns(1)
          ::Books::BookSubmission.create!(user: @user, input_method: :goodreads, goodreads_book_id: 1, status: :queued, fingerprint: "x")

          assert_equal :created, request_book(list: @list).data[:outcome]
        end

        test "the same open request on the same list returns the existing row" do
          first = request_book(list: @list).data[:submission]
          ::Books::ProcessBookSubmissionJob.expects(:perform_async).never

          again = request_book(list: @list)

          assert_equal :existing, again.data[:outcome]
          assert_equal first.id, again.data[:submission].id
        end

        test "the same request without the list is a new row" do
          first = request_book(list: @list).data[:submission]

          other = request_book(list: nil).data[:submission]

          assert_not_equal first.id, other.id
        end

        test "an auto-generated list is refused and nothing is written" do
          generated = ::Books::List.create!(name: "Generated", status: :approved, auto_generated_kind: :year_top, auto_generated_year: 2001)

          result = request_book(list: generated)

          refute result.success?
          assert_equal :list, result.data[:reason]
          assert_equal 0, ::Books::BookSubmission.origin_admin.count
        end

        test "a list that is not a books list is refused" do
          result = request_book(list: lists(:music_albums_list))

          assert_equal :list, result.data[:reason]
        end

        test "a position without a list is refused" do
          result = request_book(position: 2)

          refute result.success?
          assert_equal :invalid, result.data[:reason]
          assert_equal 0, ::Books::BookSubmission.origin_admin.count
        end

        test "a position that is not positive is refused" do
          assert_equal :invalid, request_book(list: @list, position: 0).data[:reason]
        end

        test "bad input is refused as invalid" do
          result = request_book({method: "goodreads", goodreads_url: "nonsense"}, list: @list)

          refute result.success?
          assert_equal :invalid, result.data[:reason]
        end

        test "reader Submit is untouched" do
          reader_list = user_lists(:regular_user_books_favorites)
          Rails.application.config.x.book_submissions.stubs(:daily_limit).returns(1)

          first = Submit.call(user: @user, list: reader_list, params: GOODREADS)
          second = Submit.call(user: @user, list: reader_list, params: {method: "goodreads", goodreads_url: "https://www.goodreads.com/book/show/99"})

          assert_equal reader_list.id, first.data[:submission].user_list_id
          assert first.data[:submission].origin_reader?
          assert_equal :limit, second.data[:reason]
        end
      end
    end
  end
end
