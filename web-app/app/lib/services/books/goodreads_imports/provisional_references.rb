# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Who else uses a provisional record an import created (Goodreads import
      # spec §10, Reject): another import's rows, a list item or review this
      # import did not write, or a curated list. A record anything else uses
      # stays.
      module ProvisionalReferences
        module_function

        def book_used_elsewhere?(book, import:)
          # A rejected import's rows no longer stand behind anything.
          ::Books::GoodreadsImportRow.joins(:goodreads_edition).where(books_goodreads_editions: {book_id: book.id})
            .where.not(import_id: import.id)
            .where(import_id: ::Books::GoodreadsImport.where.not(review_status: :rejected).select(:id)).exists? ||
            book.user_list_items.where.not(id: import.applied_ids("list_item_ids")).exists? ||
            ::Review.where(reviewable: book).where.not(id: import.applied_ids("review_id")).exists? ||
            ::ListItem.where(listable: book).exists?
        end

        def author_used?(author)
          ::Books::BookAuthor.where(author: author).exists?
        end
      end
    end
  end
end
