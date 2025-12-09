# frozen_string_literal: true

class Admin::Music::Songs::Wizard::EditMetadataModalComponent < ViewComponent::Base
  def initialize(list_item:)
    @list_item = list_item
  end

  private

  attr_reader :list_item

  def modal_id
    "edit_metadata_modal_#{list_item.id}"
  end

  def dialog_id
    "#{modal_id}_dialog"
  end

  def error_id
    "#{modal_id}_error"
  end

  def form_url
    metadata_admin_songs_list_item_path(list_id: list_item.list_id, id: list_item.id)
  end

  def item_label
    title = list_item.metadata["title"].presence || "Unknown Title"
    artists = Array(list_item.metadata["artists"]).join(", ").presence || "Unknown Artist"
    "##{list_item.position} - \"#{title}\" by #{artists}"
  end

  def formatted_metadata
    JSON.pretty_generate(list_item.metadata || {})
  end
end
