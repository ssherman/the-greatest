class Music::CoverArtDownloadJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(album_id)
    album = Music::Album.find(album_id)

    Rails.logger.info "Starting MusicBrainz Cover Art download for album: #{album.title}"

    # Skip if album already has a primary image
    if album.images.where(primary: true).exists?
      Rails.logger.info "Album #{album.title} already has a primary image, skipping"
      return
    end

    # Get MusicBrainz release group ID
    musicbrainz_id = album.identifiers
      .find_by(identifier_type: :music_musicbrainz_release_group_id)
      &.value

    unless musicbrainz_id
      Rails.logger.info "No MusicBrainz release group ID found for album #{album.title}"
      return
    end

    # Download cover art from MusicBrainz Cover Art Archive
    cover_art_url = "https://coverartarchive.org/release-group/#{musicbrainz_id}/front"

    Rails.logger.info "Downloading cover art from: #{cover_art_url}"

    begin
      tempfile = Down.download(cover_art_url)

      # Create Image record, attach file, then save
      image = album.images.build(primary: true)
      image.file.attach(
        io: tempfile,
        filename: "#{album.title.parameterize}-cover.jpg",
        content_type: "image/jpeg"
      )
      image.save!

      Rails.logger.info "Successfully downloaded and set cover art for album #{album.title}"
    rescue => e
      Rails.logger.info "No cover art found for album #{album.title}: #{e.message}"
    ensure
      tempfile&.close
      tempfile&.unlink
    end
  end
end
