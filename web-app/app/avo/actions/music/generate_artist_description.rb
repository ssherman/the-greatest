class Avo::Actions::Music::GenerateArtistDescription < Avo::BaseAction
  self.name = "Generate AI Description"
  self.message = "This will generate AI descriptions for the selected artist(s) in the background."
  self.confirm_button_label = "Generate Descriptions"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Extract artist IDs from the query
    artist_ids = query.pluck(:id)

    # Enqueue a separate job for each artist
    artist_ids.each do |artist_id|
      Music::ArtistDescriptionJob.perform_async(artist_id)
    end

    # Return success message
    succeed "#{artist_ids.length} artist(s) queued for AI description generation. Each artist will be processed in a separate background job."
  end
end
