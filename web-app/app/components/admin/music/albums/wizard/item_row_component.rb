# frozen_string_literal: true

# Album-specific item row component for wizard review step.
# Inherits music-specific logic from Admin::Music::Wizard::ItemRowComponent.
#
class Admin::Music::Albums::Wizard::ItemRowComponent < Admin::Music::Wizard::ItemRowComponent
  private

  def matched_title_key
    "mb_release_group_name"
  end

  def matched_name_fallback_key
    "album_name"
  end

  def matched_artists_fallback_keys
    ["mb_artist_names", "opensearch_artist_names"]
  end

  def supports_manual_link?
    true
  end

  def modal_frame_id
    Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID
  end

  def menu_items
    [
      {type: :verify, text: "Verify"},
      {type: :link, text: "Edit Metadata", modal_type: :edit_metadata},
      {type: :link, text: "Link Existing Album", modal_type: :link_album},
      {type: :link, text: "Search MusicBrainz Releases", modal_type: :search_musicbrainz_releases},
      {type: :link, text: "Search MusicBrainz Artists", modal_type: :search_musicbrainz_artists},
      {type: :delete, text: "Delete", css_class: "text-error"}
    ]
  end

  def verify_item_path
    helpers.verify_admin_albums_list_item_path(list_id: item.list_id, id: item.id)
  end

  def modal_item_path(modal_type)
    helpers.modal_admin_albums_list_item_path(list_id: item.list_id, id: item.id, modal_type: modal_type)
  end

  def destroy_item_path
    helpers.admin_albums_list_item_path(list_id: item.list_id, id: item.id)
  end
end
