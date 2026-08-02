class Books::CalculateAuthorRankingsJob
  include Sidekiq::Job

  def perform
    config = Books::Authors::RankingConfiguration.default_primary

    if config.nil?
      Rails.logger.error "No primary Books::Authors::RankingConfiguration; author rankings not calculated"
      raise "No primary Books::Authors::RankingConfiguration"
    end

    result = config.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated author rankings for configuration #{config.id}"
    else
      Rails.logger.error "Failed to calculate author rankings: #{result.errors}"
      raise "Author ranking calculation failed: #{result.errors.join(", ")}"
    end
  end
end
