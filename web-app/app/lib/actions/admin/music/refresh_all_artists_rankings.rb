module Actions
  module Admin
    module Music
      class RefreshAllArtistsRankings < Actions::Admin::BaseAction
        def self.name
          "Refresh All Artists Rankings"
        end

        def self.message
          "This will recalculate rankings for ALL artists in the system."
        end

        def self.visible?(context = {})
          context[:view] == :index
        end

        def call
          primary_config = ::Music::Artists::RankingConfiguration.default_primary

          if primary_config.nil?
            return error("No primary global ranking configuration found for artists.")
          end

          ::Music::CalculateAllArtistsRankingsJob.perform_async(primary_config.id)

          succeed "All artist rankings queued for recalculation."
        end
      end
    end
  end
end
