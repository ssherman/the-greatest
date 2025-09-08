class BulkCalculateWeightsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    ranking_configuration = RankingConfiguration.find(ranking_configuration_id)

    Rails.logger.info "Starting bulk weight calculation for RankingConfiguration #{ranking_configuration.id}: #{ranking_configuration.name}"

    calculator = Rankings::BulkWeightCalculator.new(ranking_configuration)
    results = calculator.call

    Rails.logger.info "Completed bulk weight calculation for RankingConfiguration #{ranking_configuration.id}"
    Rails.logger.info "Results: Processed #{results[:processed]}, Updated #{results[:updated]}, Errors #{results[:errors].count}"

    # Log any errors that occurred
    if results[:errors].any?
      Rails.logger.error "Errors during bulk weight calculation: #{results[:errors].map { |e| "#{e[:list_name]}: #{e[:error]}" }.join(", ")}"
    end

    results
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "RankingConfiguration not found: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "Error in BulkCalculateWeightsJob: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end
