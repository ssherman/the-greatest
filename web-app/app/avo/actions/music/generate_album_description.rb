class Avo::Actions::Music::GenerateAlbumDescription < Avo::BaseAction
  self.name = "Generate AI Description"
  self.message = "This will generate AI descriptions for the selected album(s) in the background."
  self.confirm_button_label = "Generate Descriptions"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Extract album IDs from the query
    album_ids = query.pluck(:id)

    # Enqueue a separate job for each album
    album_ids.each do |album_id|
      Music::AlbumDescriptionJob.perform_async(album_id)
    end

    # Return success message
    succeed "#{album_ids.length} album(s) queued for AI description generation. Each album will be processed in a separate background job."
  end
end
