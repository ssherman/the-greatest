module Admin
  module Music
    module Albums
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        protected

        def ranking_configuration_class
          ::Music::Albums::RankingConfiguration
        end

        def ranking_configurations_path
          admin_albums_ranking_configurations_path
        end

        def ranking_configuration_path(config)
          admin_albums_ranking_configuration_path(config)
        end

        def table_partial_path
          "admin/music/albums/ranking_configurations/table"
        end
      end
    end
  end
end
