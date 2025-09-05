class Music::ImportAlbumReleasesJob
  include Sidekiq::Job

  def perform(album_id)
    album = Music::Album.find(album_id)

    # Ensure album has MusicBrainz release group ID - raise error to trigger retry if missing
    unless album.identifiers.exists?(identifier_type: :music_musicbrainz_release_group_id)
      raise StandardError, "Album #{album.title} has no MusicBrainz release group ID - cannot import releases"
    end

    result = DataImporters::Music::Release::Importer.call(album: album)

    if result.success?
      Rails.logger.info "Successfully imported releases for album #{album.title}"
    else
      Rails.logger.error "Failed to import releases for album #{album.title}: #{result.all_errors.join(", ")}"
      raise StandardError, "Release import failed: #{result.all_errors.join(", ")}"
    end
  end
end
