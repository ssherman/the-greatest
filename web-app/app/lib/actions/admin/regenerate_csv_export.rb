module Actions
  module Admin
    class RegenerateCsvExport < Actions::Admin::BaseAction
      def self.name
        "Regenerate CSV Export"
      end

      def self.message
        "Rebuild the pre-built CSV download for this configuration."
      end

      def self.visible?(context = {})
        context[:view] == :show
      end

      def call
        return error("This action can only be performed on a single configuration.") if models.count != 1

        config = models.first
        result = Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
        return warn(result.errors.join(", ")) if result.data[:reason] == :already_generating
        return error(result.errors.join(", ")) unless result.success?

        succeed "CSV export regeneration queued for #{config.name}."
      end
    end
  end
end
