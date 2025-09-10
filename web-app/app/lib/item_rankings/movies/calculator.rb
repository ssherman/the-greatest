# frozen_string_literal: true

module ItemRankings
  module Movies
    class Calculator < ItemRankings::Calculator
      protected

      def list_type
        "Movies::List"
      end

      def item_type
        "Movies::Movie"
      end
    end
  end
end
