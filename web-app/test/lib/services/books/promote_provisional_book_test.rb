require "test_helper"

module Services
  module Books
    class PromoteProvisionalBookTest < ActiveSupport::TestCase
      include BookSubmissionReviewHelper

      setup do
        stub_review_side_effects
        @admin = users(:admin_user)
      end

      teardown { Current.reset }

      test "a provisional book becomes public and its open submissions close approved" do
        submission = reviewable_submission
        book = submission.book

        result = PromoteProvisionalBook.call(book: book, user: @admin)

        assert result.success?
        assert_equal [book, true], [result.data[:book], result.data[:promoted]]
        assert_not book.reload.provisional?
        submission.reload
        assert_equal ["approved", "api", @admin.id], [submission.review_status, submission.reviewed_via, submission.reviewed_by_id]
      end

      test "a catalog book is left alone" do
        book = books_books(:war_and_peace)
        ::Services::Books::GoodreadsImports::PromoteRecords.expects(:call).never

        result = PromoteProvisionalBook.call(book: book, user: @admin)

        assert result.success?
        assert_equal false, result.data[:promoted]
      end

      test "a book deleted before the lock is a conflict" do
        book = ::Books::Book.create!(title: "Gone Book", provisional: true)
        ::Books::Book.where(id: book.id).delete_all

        result = PromoteProvisionalBook.call(book: book, user: @admin)

        assert_not result.success?
        assert_equal true, result.data[:conflict]
        assert_match(/no longer exists/, result.errors.first)
      end
    end
  end
end
