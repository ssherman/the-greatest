# frozen_string_literal: true

module ItemRankings
  module Music
    module Songs
      class Calculator < ItemRankings::Calculator
        protected

        def list_type
          "Music::Songs::List"
        end

        def item_type
          "Music::Song"
        end
      end
    end
  end
end
