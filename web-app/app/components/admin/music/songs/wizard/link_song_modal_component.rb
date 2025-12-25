# frozen_string_literal: true

class Admin::Music::Songs::Wizard::LinkSongModalComponent < ViewComponent::Base
  def initialize(list_item:)
    @list_item = list_item
  end

  private

  attr_reader :list_item

  def modal_id
    "link_song_modal_#{list_item.id}"
  end

  def dialog_id
    "#{modal_id}_dialog"
  end

  def error_id
    "#{modal_id}_error"
  end

  def form_url
    manual_link_admin_songs_list_item_path(list_id: list_item.list_id, id: list_item.id)
  end

  def autocomplete_url
    search_admin_songs_path
  end

  def item_label
    title = list_item.metadata["title"].presence || "Unknown Title"
    artists = Array(list_item.metadata["artists"]).join(", ").presence || "Unknown Artist"
    "##{list_item.position} - \"#{title}\" by #{artists}"
  end
end
