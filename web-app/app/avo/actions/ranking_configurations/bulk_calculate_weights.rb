class Avo::Actions::RankingConfigurations::BulkCalculateWeights < Avo::BaseAction
  self.name = "Recalculate List Weights"
  self.message = "This will recalculate weights for all ranked lists in the selected ranking configuration(s) in the background. This may take several minutes for configurations with many lists."
  self.confirm_button_label = "Recalculate Weights"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Validate that all records are RankingConfiguration instances (including STI subclasses)
    invalid_records = query.reject { |record| record.is_a?(RankingConfiguration) }

    if invalid_records.any?
      Rails.logger.warn "BulkCalculateWeights action received invalid record types: #{invalid_records.map(&:class).uniq}"
      return error "Invalid record types found. This action can only be used on Ranking Configurations."
    end

    # Extract ranking configuration IDs from the validated query
    config_ids = query.pluck(:id)

    return error "No ranking configurations selected." if config_ids.empty?

    # Enqueue a separate job for each ranking configuration
    config_ids.each do |config_id|
      BulkCalculateWeightsJob.perform_async(config_id)
    end

    # Return success message
    succeed "#{config_ids.length} ranking configuration(s) queued for weight recalculation. Each configuration will be processed in a separate background job. Monitor progress in the Sidekiq dashboard."
  end
end
