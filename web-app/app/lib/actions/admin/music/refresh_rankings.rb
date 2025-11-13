module Actions
  module Admin
    module Music
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
          config.calculate_rankings_async

          succeed "Ranking calculation queued for #{config.name}."
        end
      end
    end
  end
end
