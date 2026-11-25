# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # What stops a user-added book from being rejected: who else uses it. Each
      # entry is a human-readable line (counts only, no names), empty when
      # nothing blocks the delete.
      #
      # A submitter is any reader with a submission on the book, including a
      # not_needed one (a second reader whose request resolved to the same
      # provisional book). Their list items (on whatever list: moving a book from
      # Reading to Read makes a new item) and reviews go with the book and never
      # block it. Everyone else's do, and so do a curated list, a Goodreads
      # import row whose import is not rejected, and a Goodreads import record
      # naming the book (rejected or not: a record is provenance, and when in
      # doubt the book stays). Series membership and a merge redirect are not
      # uses: the first goes with the book, the second points at nothing.
      module BookUses
        module_function

        def call(book:)
          submitters = ::Books::BookSubmission.where(book_id: book.id).where.not(user_id: nil).select(:user_id)
          [
            line(::UserListItem.joins(:user_list).where(listable: book).where.not(user_lists: {user_id: submitters}).count,
              "list item", "of a reader who did not submit it"),
            line(::Review.where(reviewable: book).where.not(user_id: submitters).count,
              "review", "by a reader who did not submit the book"),
            line(::ListItem.where(listable: book).count, "curated list item", "naming it"),
            line(import_rows(book).count + ::Books::GoodreadsImportRecord.where(record: book).count,
              "Goodreads import entry", "naming it")
          ].compact
        end

        def import_rows(book)
          live = ::Books::GoodreadsImport.where.not(review_status: :rejected).select(:id)
          ::Books::GoodreadsImportRow.joins(:goodreads_edition)
            .where(books_goodreads_editions: {book_id: book.id}, import_id: live)
        end

        def line(count, noun, tail)
          return nil if count.zero?

          "#{count} #{noun}#{"s" unless count == 1} #{tail}"
        end

        private_class_method :import_rows, :line
      end
    end
  end
end
