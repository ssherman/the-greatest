class Music::CalculateAllArtistsRankingsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id)
    config = Music::Artists::RankingConfiguration.find(ranking_configuration_id)

    result = config.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated all artists rankings for configuration #{ranking_configuration_id}"
    else
      Rails.logger.error "Failed to calculate all artists rankings: #{result.errors}"
      raise "All artists ranking calculation failed: #{result.errors.join(", ")}"
    end
  end
end
