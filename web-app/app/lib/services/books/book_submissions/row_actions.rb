# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The buttons the admin page offers on one row: those whose service would
      # accept it now. Each service answers for itself (`available?`, beside the
      # rules it refuses by), and this only collects the answers, in memory (the
      # page lists fifty). A row another reviewer settles meanwhile still gets the
      # service's refusal; this only keeps the page from offering what could
      # never work. Preload `book: :submissions` on the rows.
      module RowActions
        module_function

        def for(row)
          # An admin agent's row is worked only by that agent, so none of the page's buttons apply.
          return [] if row.origin_admin?

          actions = []
          actions << :approve if Approve.available?(row)
          actions << :merge if Merge.available?(row)
          actions << :reject if Reject.available?(row)
          actions << :supply_details if SupplyDetails.available?(row)
          actions << :retry if Retry.retryable?(row)
          actions
        end
      end
    end
  end
end
