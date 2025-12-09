require "test_helper"

class Admin::Music::Songs::Wizard::LinkSongModalComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @list = lists(:music_songs_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Come Together", "artists" => ["The Beatles"], "rank" => 1}
    )
  end

  test "renders modal with correct id" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "div#link_song_modal_#{@item.id}"
    assert_selector "dialog#link_song_modal_#{@item.id}_dialog"
  end

  test "renders modal title" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "h3", text: "Link to Existing Song"
  end

  test "renders item label with position, title and artists" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_text "#1 - \"Come Together\" by The Beatles"
  end

  test "renders form with correct action" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "form[action='#{manual_link_admin_songs_list_item_path(list_id: @list.id, id: @item.id)}']"
  end

  test "renders autocomplete component" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "[data-controller='autocomplete']"
  end

  test "autocomplete points to song search endpoint" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "[data-autocomplete-url-value='#{search_admin_songs_path}']"
  end

  test "renders error container" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "div#link_song_modal_#{@item.id}_error"
  end

  test "renders cancel and link buttons" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "button", text: "Cancel"
    assert_selector "input[type='submit'][value='Link']"
  end

  test "includes modal-form stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "form[data-controller~='modal-form']"
  end

  test "autocomplete_url returns search_admin_songs_path" do
    render_inline(Admin::Music::Songs::Wizard::LinkSongModalComponent.new(list_item: @item))

    assert_selector "[data-autocomplete-url-value='#{search_admin_songs_path}']"
  end
end
