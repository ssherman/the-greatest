# frozen_string_literal: true

module ItemRankings
  module Books
    class Calculator < ItemRankings::Calculator
      protected

      def list_type
        "Books::List"
      end

      def item_type
        "Books::Book"
      end

      # Provisional books are imports nobody has approved. update_ranked_items
      # deletes ranked rows missing from the new set, so a book flagged after it
      # was ranked drops out on the next calculation.
      def excluded_item_ids
        ::Books::Book.where(provisional: true).pluck(:id).to_set
      end
    end
  end
end
