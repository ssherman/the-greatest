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
    end
  end
end
