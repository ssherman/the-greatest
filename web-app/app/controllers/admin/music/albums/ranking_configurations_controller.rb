module Admin
  module Music
    module Albums
      class RankingConfigurationsController < Admin::Music::RankingConfigurationsController
        private

        def ranking_configuration_class
          ::Music::Albums::RankingConfiguration
        end

        def ranking_configurations_path(**opts)
          admin_albums_ranking_configurations_path(**opts)
        end

        def ranking_configuration_path(config, **opts)
          admin_albums_ranking_configuration_path(config, **opts)
        end

        def new_ranking_configuration_path
          new_admin_albums_ranking_configuration_path
        end

        def edit_ranking_configuration_path(config)
          edit_admin_albums_ranking_configuration_path(config)
        end

        def execute_action_ranking_configuration_path(config, **opts)
          execute_action_admin_albums_ranking_configuration_path(config, **opts)
        end

        def index_action_ranking_configurations_path(**opts)
          index_action_admin_albums_ranking_configurations_path(**opts)
        end

        def index_heading
          "Albums Ranking Configurations"
        end

        def index_subheading
          "Manage album ranking configurations and algorithms"
        end
      end
    end
  end
end
