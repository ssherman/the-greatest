# frozen_string_literal: true

# Games-specific item row component for wizard review step.
# Inherits shared logic from Admin::Music::Wizard::ItemRowComponent.
#
class Admin::Games::Wizard::ItemRowComponent < Admin::Music::Wizard::ItemRowComponent
  private

  def matched_title_key
    "igdb_name"
  end

  def matched_name_fallback_key
    "game_name"
  end

  def matched_artists_fallback_keys
    ["igdb_developer_names"]
  end

  def supports_manual_link?
    true
  end

  def modal_frame_id
    Admin::Games::Wizard::SharedModalComponent::FRAME_ID
  end

  # Override to show developers instead of artists
  def original_artists
    Array(item.metadata["developers"]).join(", ").presence || "Unknown Developer"
  end

  # Override to show developers for matched games
  def matched_artists
    if item.listable.present? && item.listable.respond_to?(:developers)
      item.listable.developers.map(&:name).join(", ")
    else
      matched_artists_fallback_keys.each do |key|
        value = item.metadata[key]
        return Array(value).join(", ") if value.present?
      end
      nil
    end
  end

  # Override source badge for IGDB instead of MusicBrainz
  def source_badge
    if item.metadata["opensearch_match"]
      score = item.metadata["opensearch_score"]
      score_text = score ? " #{score.to_f.round(1)}" : ""
      {text: "OS#{score_text}", css_class: "badge badge-success badge-sm", title: "OpenSearch Match"}
    elsif item.metadata["igdb_match"]
      {text: "IGDB", css_class: "badge badge-info badge-sm", title: "IGDB Match"}
    elsif supports_manual_link? && item.metadata["manual_link"]
      {text: "Manual", css_class: "badge badge-primary badge-sm", title: "Manual Link"}
    else
      {text: "-", css_class: "badge badge-ghost badge-sm", title: "No Match"}
    end
  end

  def menu_items
    [
      {type: :verify, text: "Verify"},
      {type: :link, text: "Edit Metadata", modal_type: :edit_metadata},
      {type: :link, text: "Link Existing Game", modal_type: :link_game},
      {type: :link, text: "Search IGDB Games", modal_type: :search_igdb_games},
      {type: :link, text: "Link by IGDB ID", modal_type: :link_igdb_id},
      {type: :delete, text: "Delete", css_class: "text-error"}
    ]
  end

  def verify_item_path
    helpers.verify_admin_games_list_item_path(list_id: item.list_id, id: item.id)
  end

  def modal_item_path(modal_type)
    helpers.modal_admin_games_list_item_path(list_id: item.list_id, id: item.id, modal_type: modal_type)
  end

  def destroy_item_path
    helpers.admin_games_list_item_path(list_id: item.list_id, id: item.id)
  end
end
