# frozen_string_literal: true

module Services
  module Books
    # An admin action is about to put a provisional (reader- or import-added,
    # unreviewed) book on a curated list, so the book becomes public first. This
    # is BookSubmissions::Approve without the lease and the stamp: there is no
    # submission being decided, only a book being promoted.
    #
    # Same lock order as Approve and Reject: the reader locks
    # (DestructionInvalidator), then the book row FOR UPDATE, then the
    # promotion. Running inside Lease.acting attributes the readers' open
    # submissions that CloseForBook closes to the acting admin, via "api".
    class PromoteProvisionalBook
      Result = BookSubmissions::Lease::Result

      def self.call(book:, user:) = new(book: book, user: user).call

      def initialize(book:, user:)
        @book = book
        @user = user
      end

      def call
        BookSubmissions::Lease.acting(@user, "api") { promote }
      end

      private

      def promote
        locked = nil
        promoted = false
        ActiveRecord::Base.transaction do
          ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: @book)
          locked = ::Books::Book.lock.find_by(id: @book.id)
          if locked&.provisional?
            ::Services::Books::GoodreadsImports::PromoteRecords.call(books: [locked], authors: [], initiated_by: "admin_list_item", lane: "priority")
            promoted = true
          end
        end
        return gone if locked.nil?

        Result.new(success?: true, data: {book: locked, promoted: promoted}, errors: [])
      end

      def gone = Result.new(success?: false, data: {conflict: true}, errors: ["the book no longer exists"])
    end
  end
end
