# frozen_string_literal: true

class Admin::AddItemToListModalComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def autocomplete_url
    case @list.class.name
    when "Music::Albums::List"
      Rails.application.routes.url_helpers.search_admin_albums_path
    when "Music::Songs::List"
      Rails.application.routes.url_helpers.search_admin_songs_path
    end
  end

  def expected_listable_type
    case @list.class.name
    when "Music::Albums::List"
      "Music::Album"
    when "Music::Songs::List"
      "Music::Song"
    end
  end

  def item_label
    case @list.class.name
    when "Music::Albums::List"
      "Album"
    when "Music::Songs::List"
      "Song"
    else
      "Item"
    end
  end
end
