# frozen_string_literal: true

module Actions
  module Admin
    # Regenerates a year configuration's two rollup lists. The job it queues runs
    # the whole chain in the one order that produces a correct result, which is
    # why this exists rather than a bare "refresh" the operator has to sequence.
    class GenerateDynamicLists < Actions::Admin::BaseAction
      def self.name
        "Generate Dynamic Lists"
      end

      def self.message
        "Rebuild this year's top and honorable mention lists, then refresh the main rankings."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        return error("#{config.name} has no year set, so it produces no dynamic lists.") if config.year.blank?
        return error("#{config.class.name} does not support year rollups.") unless config.supports_year_rollups?

        GenerateDynamicListsJob.perform_async(config.id)

        succeed "Dynamic list generation queued for #{config.year}. " \
          "The main rankings will refresh when it finishes."
      end
    end
  end
end
