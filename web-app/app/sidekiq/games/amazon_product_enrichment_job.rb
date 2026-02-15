# frozen_string_literal: true

class Games::AmazonProductEnrichmentJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(game_id)
    game = ::Games::Game.find(game_id)

    Rails.logger.info "Starting Amazon product enrichment for game: #{game.title}"

    result = ::Services::Games::AmazonProductService.call(game: game)

    if result[:success]
      Rails.logger.info "Amazon enrichment completed: #{result[:data]}"
    else
      Rails.logger.error "Amazon enrichment failed: #{result[:error]}"
    end
  end
end
