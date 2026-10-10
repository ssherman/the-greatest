# The nightly safety net for The Greatest Authors (config/schedule.yml, 04:00),
# and what an operator runs by hand. It claims the authors primary through
# RequestRefresh rather than calculating inline, so it can never run alongside
# a refresh that a books recalculation or an author merge already queued.
class Books::CalculateAuthorRankingsJob
  include Sidekiq::Job

  def perform
    config = Books::Authors::RankingConfiguration.default_primary

    if config.nil?
      Rails.logger.error "No primary Books::Authors::RankingConfiguration; author rankings not calculated"
      raise "No primary Books::Authors::RankingConfiguration"
    end

    result = ::Services::RankingConfigurations::RequestRefresh.call(config: config)
    return if result.success?

    Rails.logger.info "Author rankings refresh not requested for configuration #{config.id}: #{result.errors.join(", ")}"
  end
end
