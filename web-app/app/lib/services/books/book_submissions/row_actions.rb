# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The buttons the admin page offers on one row: those whose service would
      # accept it now. Built from the services' own constants and predicates,
      # not from the view, and read from the row in memory (the page lists
      # fifty). A row another reviewer settles meanwhile still gets the
      # service's refusal; this only keeps the page from offering what could
      # never work. Preload `book: :submissions` on the rows.
      module RowActions
        module_function

        def for(row)
          actions = []
          if row.book_id && Lease::OPEN_REVIEWS.include?(row.review_status)
            actions << :approve
            actions << :merge if row.book&.provisional?
            actions << :reject if row.book&.provisional? && row.book.submissions.any?(&:created_book?)
          end
          actions << :supply_details if supplyable?(row)
          actions << :retry if Retry.retryable?(row)
          actions
        end

        def supplyable?(row)
          row.book_id.nil? && SupplyDetails::STATUSES.include?(row.status) && SupplyDetails::ADMIN_REVIEWS.include?(row.review_status)
        end
      end
    end
  end
end
