class Avo::Actions::Lists::Music::Albums::ValidateItemsJson < Avo::BaseAction
  self.name = "Validate items_json matches with AI"
  self.message = "This will use AI to validate that MusicBrainz matches in items_json are correct. Invalid matches will be flagged in the data."
  self.confirm_button_label = "Validate matches"

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
      return error "No valid lists found. Lists must be Music::Albums::List with enriched items_json data."
    end

    valid_lists.each do |list|
      Music::Albums::ValidateListItemsJsonJob.perform_async(list.id)
    end

    succeed "#{valid_lists.length} list(s) queued for AI validation. Each list will be processed in a separate background job."
  end
end
