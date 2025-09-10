# frozen_string_literal: true

module ItemRankings
  module Music
    module Albums
      class Calculator < ItemRankings::Calculator
        protected

        def list_type
          "Music::Albums::List"
        end

        def item_type
          "Music::Album"
        end
      end
    end
  end
end
