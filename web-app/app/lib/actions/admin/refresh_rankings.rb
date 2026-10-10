module Actions
  module Admin
    class RefreshRankings < Actions::Admin::BaseAction
      def self.name
        "Refresh Rankings"
      end

      def self.message
        "Recalculate rankings using current configuration and weights."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        result = Services::RankingConfigurations::RequestRefresh.call(config: config)
        return succeed("Ranking calculation queued for #{config.name}.") if result.success?
        return warn("A ranking calculation is already queued or running for #{config.name}.") if result.data[:reason] == :already_running

        error(result.errors.first)
      end
    end
  end
end
