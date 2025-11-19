require "test_helper"

class Admin::AddItemToListModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @album_list = lists(:music_albums_list)
    @song_list = lists(:music_songs_list)
    @album = music_albums(:dark_side_of_the_moon)
    @song = music_songs(:time)

    @album_list.list_items.destroy_all
    @song_list.list_items.destroy_all
  end

  test "renders modal with form for album list" do
    render_inline(Admin::AddItemToListModalComponent.new(list: @album_list))

    assert_selector "dialog#add_item_to_list_modal_dialog"
    assert_selector "h3", text: "Add Album"
    assert_selector "form[action='#{admin_list_list_items_path(@album_list)}']"
  end

  test "renders modal with form for song list" do
    render_inline(Admin::AddItemToListModalComponent.new(list: @song_list))

    assert_selector "dialog#add_item_to_list_modal_dialog"
    assert_selector "h3", text: "Add Song"
    assert_selector "form[action='#{admin_list_list_items_path(@song_list)}']"
  end

  test "autocomplete_url returns correct endpoint for album list" do
    component = Admin::AddItemToListModalComponent.new(list: @album_list)
    assert_equal search_admin_albums_path, component.autocomplete_url
  end

  test "autocomplete_url returns correct endpoint for song list" do
    component = Admin::AddItemToListModalComponent.new(list: @song_list)
    assert_equal search_admin_songs_path, component.autocomplete_url
  end

  test "expected_listable_type returns correct type for album list" do
    component = Admin::AddItemToListModalComponent.new(list: @album_list)
    assert_equal "Music::Album", component.expected_listable_type
  end

  test "expected_listable_type returns correct type for song list" do
    component = Admin::AddItemToListModalComponent.new(list: @song_list)
    assert_equal "Music::Song", component.expected_listable_type
  end

  test "item_label returns Album for album list" do
    component = Admin::AddItemToListModalComponent.new(list: @album_list)
    assert_equal "Album", component.item_label
  end

  test "item_label returns Song for song list" do
    component = Admin::AddItemToListModalComponent.new(list: @song_list)
    assert_equal "Song", component.item_label
  end

  test "includes position input" do
    render_inline(Admin::AddItemToListModalComponent.new(list: @album_list))
    assert_selector "input[name='list_item[position]'][type='number']"
  end

  test "includes metadata textarea" do
    render_inline(Admin::AddItemToListModalComponent.new(list: @album_list))
    assert_selector "textarea[name='list_item[metadata]']"
  end

  test "includes verified checkbox" do
    render_inline(Admin::AddItemToListModalComponent.new(list: @album_list))
    assert_selector "input[name='list_item[verified]'][type='checkbox']"
  end
end
