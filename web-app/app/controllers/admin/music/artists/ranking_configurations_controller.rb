module Admin
  module Music
    module Artists
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        protected

        def ranking_configuration_class
          ::Music::Artists::RankingConfiguration
        end

        def ranking_configurations_path
          admin_artists_ranking_configurations_path
        end

        def ranking_configuration_path(config)
          admin_artists_ranking_configuration_path(config)
        end

        def table_partial_path
          "admin/music/artists/ranking_configurations/table"
        end
      end
    end
  end
end
