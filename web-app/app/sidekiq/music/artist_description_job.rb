class Music::ArtistDescriptionJob
  include Sidekiq::Job

  def perform(artist_id)
    artist = Music::Artist.find(artist_id)

    result = Services::Ai::Tasks::ArtistDescriptionTask.new(parent: artist).call

    if result.success?
      Rails.logger.info "Artist description generated for #{artist.name} (ID: #{artist_id})"
    else
      Rails.logger.error "Failed to generate artist description for #{artist.name} (ID: #{artist_id}): #{result.error}"
    end
  end
end
