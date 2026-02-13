module Admin
  module Music
    module Artists
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        private

        def ranking_configuration_class
          ::Music::Artists::RankingConfiguration
        end

        def ranking_configurations_path(**opts)
          admin_artists_ranking_configurations_path(**opts)
        end

        def ranking_configuration_path(config, **opts)
          admin_artists_ranking_configuration_path(config, **opts)
        end

        def new_ranking_configuration_path
          new_admin_artists_ranking_configuration_path
        end

        def edit_ranking_configuration_path(config)
          edit_admin_artists_ranking_configuration_path(config)
        end

        def execute_action_ranking_configuration_path(config, **opts)
          execute_action_admin_artists_ranking_configuration_path(config, **opts)
        end

        def index_action_ranking_configurations_path(**opts)
          index_action_admin_artists_ranking_configurations_path(**opts)
        end

        def table_partial_path
          "admin/music/artists/ranking_configurations/table"
        end

        def type_label
          "Artist "
        end

        def index_heading
          "Artists Ranking Configurations"
        end

        def index_subheading
          "Manage artist ranking configurations (aggregated from album and song rankings)"
        end
      end
    end
  end
end
