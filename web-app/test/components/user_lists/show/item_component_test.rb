# frozen_string_literal: true

require "test_helper"

class UserLists::Show::ItemComponentTest < ViewComponent::TestCase
  Component = UserLists::Show::ItemComponent

  test "table_layout? is false for card-capable listables outside table_view" do
    refute Component.table_layout?(listable_class: "Music::Album", view_mode: "default_view")
    refute Component.table_layout?(listable_class: "Games::Game", view_mode: "grid_view")
  end

  test "table_layout? is true in table_view for every listable" do
    assert Component.table_layout?(listable_class: "Music::Album", view_mode: "table_view")
    assert Component.table_layout?(listable_class: "Games::Game", view_mode: "table_view")
  end

  test "table_layout? is true for cardless listables in any view_mode" do
    assert Component.table_layout?(listable_class: "Music::Song", view_mode: "default_view")
    assert Component.table_layout?(listable_class: "Movies::Movie", view_mode: "grid_view")
  end

  test "renders a generic table row for an album in table_view" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_selector "tr td", text: item.listable.title
    assert_selector "tr[data-listable-id='#{item.listable_id}']"
  end

  test "renders the completed_on badge on a completed_on_enabled list" do
    item = user_list_items(:regular_user_listened_album_1)
    render_inline(Component.new(item: item, view_mode: "table_view", position: 1))

    assert_text "February 01, 2026"
  end

  test "renders an album card (not a row) in grid_view" do
    item = user_list_items(:regular_user_fav_album_1)
    render_inline(Component.new(item: item, view_mode: "grid_view", position: 1))

    assert_no_selector "tr"
    assert_selector "div.card[data-listable-id='#{item.listable_id}']"
  end

  test "renders a list row with the description in default_view for an album" do
    item = user_list_items(:regular_user_fav_album_1)
    album = item.listable
    album.update!(description: "A landmark concept album about madness and time.")
    render_inline(Component.new(item: item, view_mode: "default_view", position: 4))

    assert_no_selector "tr"
    assert_no_selector "div.card"
    assert_text "A landmark concept album about madness and time."
    assert_text "4." # the position number in the heading
    assert_selector "[data-listable-id='#{album.id}']"
  end
end
