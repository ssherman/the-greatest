# frozen_string_literal: true

class Admin::AddCategoryModalComponent < ViewComponent::Base
  def initialize(item:)
    @item = item
  end

  def form_url
    case @item.class.name
    when "Music::Artist"
      helpers.admin_artist_category_items_path(@item)
    when "Music::Album"
      helpers.admin_album_category_items_path(@item)
    when "Music::Song"
      helpers.admin_song_category_items_path(@item)
      # Future: when "Books::Book", "Movies::Movie", "Games::Game"
    end
  end

  def search_url
    # Currently only Music categories exist. When Books/Movies/Games are added,
    # this will need a case statement to route to domain-specific search endpoints.
    helpers.search_admin_categories_path
  end

  def item_type_label
    @item.class.name.demodulize.downcase
  end
end
