class Music::ImportAlbumReleasesJob
  include Sidekiq::Job

  def perform(album_id)
    album = Music::Album.find(album_id)
    result = DataImporters::Music::Release::Importer.call(album: album)

    if result.success?
      Rails.logger.info "Successfully imported releases for album #{album.title}"
    else
      Rails.logger.error "Failed to import releases for album #{album.title}: #{result.all_errors.join(", ")}"
      raise StandardError, "Release import failed: #{result.all_errors.join(", ")}"
    end
  end
end
