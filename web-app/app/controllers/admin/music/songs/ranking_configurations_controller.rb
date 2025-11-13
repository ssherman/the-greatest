module Admin
  module Music
    module Songs
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        protected

        def ranking_configuration_class
          ::Music::Songs::RankingConfiguration
        end

        def ranking_configurations_path
          admin_songs_ranking_configurations_path
        end

        def ranking_configuration_path(config)
          admin_songs_ranking_configuration_path(config)
        end

        def table_partial_path
          "admin/music/songs/ranking_configurations/table"
        end
      end
    end
  end
end
