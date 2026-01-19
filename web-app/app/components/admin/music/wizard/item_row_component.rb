# frozen_string_literal: true

# Base component for wizard review step item rows.
# Renders a single list item as a table row with status, data, and action menu.
#
# Subclasses must implement:
#   - matched_title_key: Metadata key for matched title (e.g., "mb_recording_name")
#   - matched_name_fallback_key: Fallback key (e.g., "song_name")
#   - matched_artists_fallback_keys: Array of fallback keys for artists
#   - supports_manual_link?: Whether to show manual_link badge
#   - menu_items: Array of menu item configurations
#   - modal_frame_id: SharedModalComponent::FRAME_ID constant
#   - verify_item_path: Path helper for verify action
#   - modal_item_path: Path helper for modal action
#   - destroy_item_path: Path helper for destroy action
#
class Admin::Music::Wizard::ItemRowComponent < ViewComponent::Base
  def initialize(item:)
    @item = item
  end

  private

  attr_reader :item

  # Status computation

  def item_status
    if item.verified?
      "valid"
    elsif item.metadata["ai_match_invalid"]
      "invalid"
    else
      "missing"
    end
  end

  def status_badge_class(status)
    case status
    when "valid"
      "badge badge-success badge-sm"
    when "invalid"
      "badge badge-error badge-sm"
    else
      "badge badge-ghost badge-sm"
    end
  end

  def status_badge_icon(status)
    case status
    when "valid"
      icon_check
    when "invalid"
      icon_x
    else
      icon_dash
    end
  end

  def row_background_class(status)
    case status
    when "invalid"
      "bg-error/10"
    when "missing"
      "bg-base-200"
    else
      ""
    end
  end

  # Data extraction

  def original_title
    item.metadata["title"].presence || "Unknown Title"
  end

  def original_artists
    Array(item.metadata["artists"]).join(", ").presence || "Unknown Artist"
  end

  def matched_title
    if item.listable.present?
      item.listable.title
    elsif item.metadata[matched_title_key].present?
      item.metadata[matched_title_key]
    elsif item.metadata[matched_name_fallback_key].present?
      item.metadata[matched_name_fallback_key]
    end
  end

  def matched_artists
    if item.listable.present? && item.listable.respond_to?(:artists)
      item.listable.artists.map(&:name).join(", ")
    else
      matched_artists_fallback_keys.each do |key|
        value = item.metadata[key]
        return Array(value).join(", ") if value.present?
      end
      nil
    end
  end

  # Source badge

  def source_badge
    if item.metadata["opensearch_match"]
      score = item.metadata["opensearch_score"]
      score_text = score ? " #{score.to_f.round(1)}" : ""
      {text: "OS#{score_text}", css_class: "badge badge-success badge-sm", title: "OpenSearch Match"}
    elsif item.metadata["musicbrainz_match"]
      {text: "MB", css_class: "badge badge-info badge-sm", title: "MusicBrainz Match"}
    elsif supports_manual_link? && item.metadata["manual_link"]
      {text: "Manual", css_class: "badge badge-primary badge-sm", title: "Manual Link"}
    else
      {text: "-", css_class: "badge badge-ghost badge-sm", title: "No Match"}
    end
  end

  # Icons

  def icon_check
    '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd" /></svg>'.html_safe
  end

  def icon_x
    '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" /></svg>'.html_safe
  end

  def icon_dash
    '<svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M3 10a1 1 0 011-1h12a1 1 0 110 2H4a1 1 0 01-1-1z" clip-rule="evenodd" /></svg>'.html_safe
  end

  def icon_dots_vertical
    '<svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor"><path d="M10 6a2 2 0 110-4 2 2 0 010 4zM10 12a2 2 0 110-4 2 2 0 010 4zM10 18a2 2 0 110-4 2 2 0 010 4z" /></svg>'.html_safe
  end

  # Menu helpers

  def popover_menu_id
    "item_menu_#{item.id}"
  end

  def popover_close_js
    "document.getElementById('#{popover_menu_id}').hidePopover();"
  end

  # Abstract methods - subclasses must implement

  def matched_title_key
    raise NotImplementedError, "Subclass must implement #matched_title_key"
  end

  def matched_name_fallback_key
    raise NotImplementedError, "Subclass must implement #matched_name_fallback_key"
  end

  def matched_artists_fallback_keys
    raise NotImplementedError, "Subclass must implement #matched_artists_fallback_keys"
  end

  def supports_manual_link?
    raise NotImplementedError, "Subclass must implement #supports_manual_link?"
  end

  def menu_items
    raise NotImplementedError, "Subclass must implement #menu_items"
  end

  def modal_frame_id
    raise NotImplementedError, "Subclass must implement #modal_frame_id"
  end

  def verify_item_path
    raise NotImplementedError, "Subclass must implement #verify_item_path"
  end

  def modal_item_path(modal_type)
    raise NotImplementedError, "Subclass must implement #modal_item_path"
  end

  def destroy_item_path
    raise NotImplementedError, "Subclass must implement #destroy_item_path"
  end
end
