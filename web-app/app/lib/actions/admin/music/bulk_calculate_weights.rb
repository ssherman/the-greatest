module Actions
  module Admin
    module Music
      class BulkCalculateWeights < Actions::Admin::BaseAction
        def self.name
          "Bulk Calculate Weights"
        end

        def self.message
          "Recalculate weights for all ranked lists in the selected configurations."
        end

        def self.visible?(context = {})
          [:index, :show].include?(context[:view])
        end

        def call
          return error("No configurations selected.") if models.empty?

          count = 0
          models.each do |config|
            BulkCalculateWeightsJob.perform_async(config.id)
            count += 1
          end

          succeed "Weight calculation queued for #{count} #{"configuration".pluralize(count)}."
        end
      end
    end
  end
end
