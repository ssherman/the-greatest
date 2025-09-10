# frozen_string_literal: true

module ItemRankings
  module Games
    class Calculator < ItemRankings::Calculator
      protected

      def list_type
        "Games::List"
      end

      def item_type
        "Games::Game"
      end
    end
  end
end
