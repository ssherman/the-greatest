class Music::AmazonProductEnrichmentJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(album_id)
    album = Music::Album.find(album_id)

    Rails.logger.info "Starting Amazon product enrichment for album: #{album.title}"

    # Use service object to handle all Amazon processing
    result = ::Services::Music::AmazonProductService.call(album: album)

    if result[:success]
      Rails.logger.info "Successfully enriched album #{album.title} with Amazon data"
    else
      error_message = result[:error] || result[:errors]&.join(", ") || "Unknown error"
      Rails.logger.error "Failed to enrich album #{album.title}: #{error_message}"
      raise StandardError, "Amazon enrichment failed: #{error_message}"
    end
  end
end
