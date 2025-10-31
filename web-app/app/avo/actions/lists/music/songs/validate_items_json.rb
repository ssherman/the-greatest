class Avo::Actions::Lists::Music::Songs::ValidateItemsJson < Avo::BaseAction
  self.name = "Validate items_json matches with AI"
  self.message = "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
  self.confirm_button_label = "Validate matches"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_song_list = list.is_a?(::Music::Songs::List)
      has_enriched_items = list.items_json.present? &&
        list.items_json["songs"].is_a?(Array) &&
        list.items_json["songs"].any? { |s| s["mb_recording_id"].present? }

      unless is_song_list
        Rails.logger.warn "Skipping non-song list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_enriched_items
        Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
      end

      is_song_list && has_enriched_items
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Songs::List with enriched items_json data."
    end

    valid_lists.each do |list|
      Music::Songs::ValidateListItemsJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for AI validation. Each list will be processed in a separate background job."
  end
end
