class Music::AlbumDescriptionJob
  include Sidekiq::Job

  def perform(album_id)
    album = Music::Album.find(album_id)

    result = Services::Ai::Tasks::AlbumDescriptionTask.new(parent: album).call

    if result.success?
      Rails.logger.info "Album description generated for #{album.title} (ID: #{album_id})"
    else
      Rails.logger.error "Failed to generate album description for #{album.title} (ID: #{album_id}): #{result.error}"
    end
  end
end
