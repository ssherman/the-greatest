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
    when "Games::Game"
      helpers.admin_games_game_category_items_path(@item)
    end
  end

  def search_url
    case @item.class.name
    when "Games::Game"
      helpers.search_admin_games_categories_path
    else
      helpers.search_admin_categories_path
    end
  end

  def item_type_label
    @item.class.name.demodulize.downcase
  end
end
