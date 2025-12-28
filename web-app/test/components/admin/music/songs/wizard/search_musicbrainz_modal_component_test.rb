require "test_helper"

class Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponentTest < ViewComponent::TestCase
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
    @item_with_mb_artist = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 2,
      metadata: {
        "title" => "Yesterday",
        "artists" => ["The Beatles"],
        "rank" => 2,
        "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"]
      }
    )
  end

  test "renders modal with correct id" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item, list: @list))

    assert_selector "div#search_mb_modal_#{@item.id}"
    assert_selector "dialog#search_mb_modal_#{@item.id}_dialog"
  end

  test "renders modal title" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item, list: @list))

    assert_selector "h3", text: "Search MusicBrainz"
  end

  test "renders item label with position, title and artists" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item, list: @list))

    assert_text "#1 - \"Come Together\" by The Beatles"
  end

  # Tests for items WITHOUT mb_artist_ids (warning message)
  test "shows warning when item has no mb_artist_ids" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item, list: @list))

    assert_selector ".alert-warning"
    assert_text "MusicBrainz search requires an artist match first"
    assert_no_selector "form[action='#{link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id)}']"
    assert_no_selector "[data-controller='autocomplete']"
  end

  test "shows close button when item has no mb_artist_ids" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item, list: @list))

    assert_selector "button", text: "Close"
    assert_no_selector "input[type='submit'][value='Link']"
  end

  # Tests for items WITH mb_artist_ids (search form)
  test "renders form with correct action when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_selector "form[action='#{link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item_with_mb_artist.id)}']"
  end

  test "renders autocomplete component when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_selector "[data-controller='autocomplete']"
  end

  test "autocomplete points to musicbrainz search endpoint with item_id" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    expected_url = musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id, item_id: @item_with_mb_artist.id)
    assert_selector "[data-autocomplete-url-value='#{expected_url}']"
  end

  test "renders error container when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_selector "div#search_mb_modal_#{@item_with_mb_artist.id}_error"
  end

  test "renders cancel and link buttons when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_selector "button", text: "Cancel"
    assert_selector "input[type='submit'][value='Link']"
  end

  test "includes modal-form stimulus controller when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_selector "form[data-controller~='modal-form']"
  end

  test "includes helper text for search when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_text "Searching within artist's recordings"
  end

  test "does not show warning when mb_artist_ids present" do
    render_inline(Admin::Music::Songs::Wizard::SearchMusicbrainzModalComponent.new(list_item: @item_with_mb_artist, list: @list))

    assert_no_selector ".alert-warning"
    assert_no_text "MusicBrainz search requires an artist match first"
  end
end
