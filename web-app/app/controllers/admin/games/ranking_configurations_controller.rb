module Admin
  module Games
    class RankingConfigurationsController < Admin::RankingConfigurationsController
      layout "games/admin"

      private

      # Override authenticate_admin! to allow games domain access
      def authenticate_admin!
        return if current_user&.admin? || current_user&.editor?

        unless current_user&.can_access_domain?("games")
          redirect_to domain_root_path, alert: "Access denied. You need permission for games admin."
        end
      end

      def policy_class
        ::Games::RankingConfigurationPolicy
      end

      def domain_name
        "games"
      end

      def ranking_configuration_class
        ::Games::RankingConfiguration
      end

      def ranking_configurations_path
        admin_games_ranking_configurations_path
      end

      def ranking_configuration_path(config)
        admin_games_ranking_configuration_path(config)
      end

      def table_partial_path
        "admin/games/ranking_configurations/table"
      end
    end
  end
end
