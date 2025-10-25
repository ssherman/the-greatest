class Music::CalculateArtistRankingJob
  include Sidekiq::Job

  def perform(artist_id)
    Music::Artist.find(artist_id)
    config = Music::Artists::RankingConfiguration.default_primary

    return unless config

    result = config.calculate_rankings

    if result.success?
      Rails.logger.info "Successfully calculated artist rankings (triggered by artist #{artist_id})"
    else
      Rails.logger.error "Failed to calculate artist rankings: #{result.errors}"
      raise "Artist ranking calculation failed: #{result.errors.join(", ")}"
    end
  end
end
