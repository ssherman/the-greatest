# frozen_string_literal: true

require "test_helper"

class UserLists::Dashboard::ListCardComponentTest < ViewComponent::TestCase
  Component = UserLists::Dashboard::ListCardComponent

  test "renders a default list with its type icon, count, and private indicator" do
    list = user_lists(:regular_user_music_albums_favorites)
    render_inline(Component.new(user_list: list, item_count: 3))

    assert_selector "a[href='#{Rails.application.routes.url_helpers.my_list_path(list)}']"
    assert_text "Favorite Albums"
    assert_text "3 items"
    assert_text "Private"
    assert_selector "svg" # the list_type icon
    assert_no_text "Custom"
  end

  test "renders a custom public list with the Custom tag and no icon" do
    list = user_lists(:regular_user_custom_albums)
    render_inline(Component.new(user_list: list, item_count: 1))

    assert_text "My Desert Island Picks"
    assert_text "Custom"
    assert_text "Public"
    assert_no_selector "svg" # custom lists have no list_type icon
  end
end
