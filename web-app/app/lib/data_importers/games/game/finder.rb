# frozen_string_literal: true

module DataImporters
  module Games
    module Game
      # Finds existing Games::Game records before import
      # Uses IGDB game identifier for deduplication
      class Finder < DataImporters::FinderBase
        def call(query:)
          return nil if query.igdb_id.blank?

          find_by_identifier(
            identifier_type: :games_igdb_id,
            identifier_value: query.igdb_id.to_s,
            model_class: ::Games::Game
          )
        end
      end
    end
  end
end
