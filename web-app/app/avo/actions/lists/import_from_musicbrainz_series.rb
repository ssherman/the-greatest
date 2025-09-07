class Avo::Actions::Lists::ImportFromMusicbrainzSeries < Avo::BaseAction
  self.name = "Import from MusicBrainz Series"
  self.message = "This will import albums from the MusicBrainz series associated with the selected list(s) in the background."
  self.confirm_button_label = "Import from Series"

  def handle(query:, fields:, current_user:, resource:, **args)
    # Extract list IDs from the query
    query.pluck(:id)

    # Filter to only album lists with series IDs
    valid_lists = query.select do |list|
      is_album_list = list.is_a?(Music::Albums::List)
      has_series_id = list.musicbrainz_series_id.present?

      unless is_album_list
        Rails.logger.warn "Skipping non-album list: #{list.name} (ID: #{list.id})"
      end

      unless has_series_id
        Rails.logger.warn "Skipping list without series ID: #{list.name} (ID: #{list.id})"
      end

      is_album_list && has_series_id
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List with a MusicBrainz series ID."
    end

    # Enqueue a separate job for each valid list
    valid_lists.each do |list|
      ImportListFromMusicbrainzSeriesJob.perform_async(list.id)
    end

    # Return success message
    succeed "#{valid_lists.length} list(s) queued for MusicBrainz series import. Each list will be processed in a separate background job."
  end
end
