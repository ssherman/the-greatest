# frozen_string_literal: true

require "test_helper"

class UserLists::Show::AddItemComponentTest < ViewComponent::TestCase
  Component = UserLists::Show::AddItemComponent

  test "renders the typeahead search box for a searchable album list" do
    list = user_lists(:regular_user_music_albums_favorites)
    render_inline(Component.new(list: list))

    assert_selector "[data-testid='add-item-search'][data-controller='user-list-add-item']"
    assert_selector "[data-user-list-add-item-user-list-id-value='#{list.id}']"
    assert_selector "input[type='search']"
  end

  test "renders for songs and games lists too" do
    [user_lists(:regular_user_music_songs_favorites), user_lists(:regular_user_games_favorites)].each do |list|
      render_inline(Component.new(list: list))
      assert_selector "[data-testid='add-item-search']"
    end
  end

  test "renders nothing for a non-searchable movies list" do
    list = user_lists(:regular_user_movies_favorites)
    render_inline(Component.new(list: list))

    assert_no_selector "[data-testid='add-item-search']"
  end

  test "scopes the search url to the list's listable type" do
    list = user_lists(:regular_user_music_albums_favorites)
    render_inline(Component.new(list: list))

    assert_selector "[data-autocomplete-url-value*='Music%3A%3AAlbum']"
  end
end
