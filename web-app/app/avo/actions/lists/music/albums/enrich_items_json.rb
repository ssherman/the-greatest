class Avo::Actions::Lists::Music::Albums::EnrichItemsJson < Avo::BaseAction
  self.name = "Enrich items_json with MusicBrainz data"
  self.message = "This will enrich the items_json field with MusicBrainz metadata for the selected list(s) in the background."
  self.confirm_button_label = "Enrich items json"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_album_list = list.is_a?(::Music::Albums::List)
      has_items_json = list.items_json.present? && list.items_json["albums"].is_a?(Array)

      unless is_album_list
        Rails.logger.warn "Skipping non-album list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_items_json
        Rails.logger.warn "Skipping list without items_json: #{list.name} (ID: #{list.id})"
      end

      is_album_list && has_items_json
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List with populated items_json."
    end

    valid_lists.each do |list|
      Music::Albums::EnrichListItemsJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for items_json enrichment. Each list will be processed in a separate background job."
  end
end
