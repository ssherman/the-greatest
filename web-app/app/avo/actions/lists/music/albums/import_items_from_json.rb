class Avo::Actions::Lists::Music::Albums::ImportItemsFromJson < Avo::BaseAction
  self.name = "Import albums from items_json"
  self.message = "This will import albums from MusicBrainz based on enriched items_json data and create list_items. Albums flagged as invalid by AI will be skipped."
  self.confirm_button_label = "Import albums"

  def handle(query:, fields:, current_user:, resource:, **args)
    query.pluck(:id)

    valid_lists = query.select do |list|
      is_album_list = list.is_a?(::Music::Albums::List)
      has_enriched_items = list.items_json.present? &&
        list.items_json["albums"].is_a?(Array) &&
        list.items_json["albums"].any? { |a| a["mb_release_group_id"].present? }

      unless is_album_list
        Rails.logger.warn "Skipping non-album list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
      end

      unless has_enriched_items
        Rails.logger.warn "Skipping list without enriched items_json: #{list.name} (ID: #{list.id})"
      end

      is_album_list && has_enriched_items
    end

    if valid_lists.empty?
      return error "No valid lists found. Lists must be Music::Albums::List with enriched items_json data (albums with mb_release_group_id)."
    end

    valid_lists.each do |list|
      Music::Albums::ImportListItemsFromJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for album import. Each list will be processed in a separate background job."
  end
end
