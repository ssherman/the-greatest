class CalculateRankingsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    ranking_configuration = RankingConfiguration.find(ranking_configuration_id)

    result = ranking_configuration.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated rankings for configuration #{ranking_configuration_id}"
    else
      Rails.logger.error "Failed to calculate rankings for configuration #{ranking_configuration_id}: #{result.errors}"
      raise "Ranking calculation failed: #{result.errors.join(", ")}"
    end
  end
end
