module Admin
  module Games
    class RankingConfigurationsController < Admin::RankingConfigurationsController
      include Admin::DomainScopedAuth

      layout "games/admin"

      private

      def policy_class
        ::Games::RankingConfigurationPolicy
      end

      def domain_name
        "games"
      end

      def ranking_configuration_class
        ::Games::RankingConfiguration
      end

      def ranking_configurations_path(**opts)
        admin_games_ranking_configurations_path(**opts)
      end

      def ranking_configuration_path(config, **opts)
        admin_games_ranking_configuration_path(config, **opts)
      end

      def new_ranking_configuration_path
        new_admin_games_ranking_configuration_path
      end

      def edit_ranking_configuration_path(config)
        edit_admin_games_ranking_configuration_path(config)
      end

      def execute_action_ranking_configuration_path(config, **opts)
        execute_action_admin_games_ranking_configuration_path(config, **opts)
      end

      def index_action_ranking_configurations_path(**opts)
        index_action_admin_games_ranking_configurations_path(**opts)
      end
    end
  end
end
