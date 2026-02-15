# frozen_string_literal: true

class Games::CoverArtDownloadJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(game_id)
    game = ::Games::Game.find(game_id)

    Rails.logger.info "Starting IGDB Cover Art download for game: #{game.title}"

    # Skip if game already has a primary image
    if game.images.where(primary: true).exists?
      Rails.logger.info "Game #{game.title} already has a primary image, skipping"
      return
    end

    # Get IGDB game ID from identifier
    igdb_id = game.identifiers.find_by(identifier_type: :games_igdb_id)&.value&.to_i

    unless igdb_id
      Rails.logger.info "No IGDB ID found for game #{game.title}"
      return
    end

    # Fetch cover art info from IGDB
    cover_search = ::Games::Igdb::Search::CoverSearch.new
    result = cover_search.find_by_game_id(igdb_id)

    unless result[:success] && result[:data].present?
      Rails.logger.info "No cover art found in IGDB for game #{game.title}"
      return
    end

    cover_data = result[:data].first
    image_id = cover_data["image_id"]

    unless image_id
      Rails.logger.info "No image_id in cover data for game #{game.title}"
      return
    end

    # Build URL for highest resolution
    cover_url = cover_search.image_url(image_id, size: ::Games::Igdb::Search::CoverSearch::SIZE_1080P)

    Rails.logger.info "Downloading cover art from: #{cover_url}"

    begin
      tempfile = Down.download(cover_url)

      # Create Image record, attach file, then save
      image = game.images.build(primary: true)
      image.file.attach(
        io: tempfile,
        filename: "#{game.title.parameterize}-cover.jpg",
        content_type: "image/jpeg"
      )
      image.save!

      Rails.logger.info "Successfully downloaded and set cover art for game #{game.title}"
    rescue => e
      Rails.logger.info "Failed to download cover art for game #{game.title}: #{e.message}"
    ensure
      tempfile&.close
      tempfile&.unlink
    end
  end
end
