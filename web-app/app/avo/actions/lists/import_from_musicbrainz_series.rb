class Avo::Actions::Lists::ImportFromMusicbrainzSeries < Avo::BaseAction
  self.name = "Import from MusicBrainz Series"
  self.message = "This will import albums or songs from the MusicBrainz series associated with the selected list(s) in the background."
  self.confirm_button_label = "Import from Series"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_supported_type = list.is_a?(Music::Albums::List) || list.is_a?(Music::Songs::List)
      has_series_id = list.musicbrainz_series_id.present?

      unless is_supported_type
        Rails.logger.warn "Skipping unsupported list type: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_series_id
        Rails.logger.warn "Skipping list without series ID: #{list.name} (ID: #{list.id})"
      end

      is_supported_type && has_series_id
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List or Music::Songs::List with a MusicBrainz series ID."
    end

    valid_lists.each do |list|
      if list.is_a?(Music::Albums::List)
        ImportListFromMusicbrainzSeriesJob.perform_async(list.id)
      elsif list.is_a?(Music::Songs::List)
        Music::ImportSongListFromMusicbrainzSeriesJob.perform_async(list.id)
      end
    end

    succeed "#{valid_lists.length} list(s) queued for MusicBrainz series import. Each list will be processed in a separate background job."
  end
end
