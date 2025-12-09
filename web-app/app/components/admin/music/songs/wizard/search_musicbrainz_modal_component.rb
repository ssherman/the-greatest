# frozen_string_literal: true

class Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent < ViewComponent::Base
  def initialize(list_item:, list:)
    @list_item = list_item
    @list = list
  end

  private

  attr_reader :list_item, :list

  def modal_id
    "search_mb_modal_#{list_item.id}"
  end

  def dialog_id
    "#{modal_id}_dialog"
  end

  def error_id
    "#{modal_id}_error"
  end

  def form_url
    link_musicbrainz_admin_songs_list_item_path(list_id: list.id, id: list_item.id)
  end

  def autocomplete_url
    musicbrainz_search_admin_songs_list_wizard_path(list_id: list.id, item_id: list_item.id)
  end

  def musicbrainz_available?
    Array(list_item.metadata["mb_artist_ids"]).any?
  end

  def item_label
    title = list_item.metadata["title"].presence || "Unknown Title"
    artists = Array(list_item.metadata["artists"]).join(", ").presence || "Unknown Artist"
    "##{list_item.position} - \"#{title}\" by #{artists}"
  end

  def default_search_text
    title = list_item.metadata["title"].presence || ""
    artists = Array(list_item.metadata["artists"]).first.presence || ""
    "#{artists} #{title}".strip
  end
end
