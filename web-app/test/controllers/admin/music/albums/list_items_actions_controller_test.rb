# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::ListItemsActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music]
    @list = lists(:music_albums_list)
    @admin_user = users(:admin_user)
    sign_in_as(@admin_user, stub_auth: true)

    @list.list_items.destroy_all
    @album = music_albums(:dark_side_of_the_moon)
    @item = @list.list_items.create!(
      listable_type: "Music::Album",
      verified: false,
      position: 1,
      metadata: {"title" => "The Dark Side of the Moon", "artists" => ["Pink Floyd"], "rank" => 1}
    )
  end

  # verify action tests
  test "verify marks item as verified" do
    assert_not @item.verified?

    post verify_admin_albums_list_item_path(list_id: @list.id, id: @item.id)

    assert_response :redirect
    @item.reload
    assert @item.verified?
  end

  test "verify accepts turbo stream format" do
    post verify_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert @item.verified?
  end

  # metadata action tests
  test "metadata updates item metadata with valid JSON" do
    new_metadata = {"title" => "Fixed Title", "artists" => ["Fixed Artist"], "rank" => 1}

    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate(new_metadata)}}

    assert_response :redirect
    @item.reload
    assert_equal "Fixed Title", @item.metadata["title"]
    assert_equal ["Fixed Artist"], @item.metadata["artists"]
  end

  test "metadata returns error for invalid JSON" do
    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: "not valid json {"}}

    assert_response :redirect
    @item.reload
    assert_equal "The Dark Side of the Moon", @item.metadata["title"]
  end

  test "metadata accepts turbo stream format" do
    new_metadata = {"title" => "Updated", "artists" => ["Artist"]}

    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate(new_metadata)}},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal "Updated", @item.metadata["title"]
  end

  # manual_link action tests
  test "manual_link links album to item" do
    post manual_link_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {album_id: @album.id}

    assert_response :redirect
    @item.reload
    assert_equal @album.id, @item.listable_id
    assert @item.verified?
    assert_equal @album.id, @item.metadata["album_id"]
    assert_equal @album.title, @item.metadata["album_name"]
    assert @item.metadata["manual_link"]
  end

  test "manual_link returns error when album_id missing" do
    post manual_link_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {album_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.listable_id
    assert_not @item.verified?
  end

  test "manual_link returns error when album not found" do
    post manual_link_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {album_id: 999999}

    assert_response :redirect
    @item.reload
    assert_nil @item.listable_id
    assert_not @item.verified?
  end

  test "manual_link accepts turbo stream format" do
    post manual_link_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {album_id: @album.id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal @album.id, @item.listable_id
  end

  # link_musicbrainz_release action tests
  test "link_musicbrainz_release links release group to item" do
    mb_release_group_id = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"
    mock_response = {
      success: true,
      data: {
        "release-groups" => [{
          "id" => mb_release_group_id,
          "title" => "The Dark Side of the Moon",
          "artist-credit" => [{"artist" => {"name" => "Pink Floyd"}}],
          "first-release-date" => "1973-03-01",
          "primary-type" => "Album"
        }]
      }
    }

    Music::Musicbrainz::Search::ReleaseGroupSearch.any_instance
      .stubs(:lookup_by_release_group_mbid)
      .with(mb_release_group_id)
      .returns(mock_response)

    post link_musicbrainz_release_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_release_group_id: mb_release_group_id}

    assert_response :redirect
    @item.reload
    assert @item.verified?, "Item should be verified after linking MusicBrainz release group"
    assert_equal mb_release_group_id, @item.metadata["mb_release_group_id"]
    assert_equal "The Dark Side of the Moon", @item.metadata["mb_release_group_name"]
    assert_equal ["Pink Floyd"], @item.metadata["mb_artist_names"]
    assert_equal 1973, @item.metadata["mb_release_year"]
    assert @item.metadata["musicbrainz_match"]
    assert @item.metadata["manual_musicbrainz_link"]
  end

  test "link_musicbrainz_release returns error when mb_release_group_id missing" do
    post link_musicbrainz_release_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_release_group_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_release_group_id"]
  end

  test "link_musicbrainz_release returns error when release group not found" do
    mb_release_group_id = "nonexistent-mbid"
    mock_response = {
      success: false,
      data: nil,
      errors: ["Release group not found"]
    }

    Music::Musicbrainz::Search::ReleaseGroupSearch.any_instance
      .stubs(:lookup_by_release_group_mbid)
      .with(mb_release_group_id)
      .returns(mock_response)

    post link_musicbrainz_release_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_release_group_id: mb_release_group_id}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_release_group_id"]
  end

  test "link_musicbrainz_release accepts turbo stream format" do
    mb_release_group_id = "a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d"
    mock_response = {
      success: true,
      data: {
        "release-groups" => [{
          "id" => mb_release_group_id,
          "title" => "The Dark Side of the Moon",
          "artist-credit" => [{"artist" => {"name" => "Pink Floyd"}}],
          "first-release-date" => "1973"
        }]
      }
    }

    Music::Musicbrainz::Search::ReleaseGroupSearch.any_instance
      .stubs(:lookup_by_release_group_mbid)
      .returns(mock_response)

    post link_musicbrainz_release_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_release_group_id: mb_release_group_id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal mb_release_group_id, @item.metadata["mb_release_group_id"]
  end

  # musicbrainz_release_search action tests
  test "musicbrainz_release_search returns empty array when item_id missing" do
    get musicbrainz_release_search_admin_albums_list_wizard_path(list_id: @list.id), params: {q: "Dark Side"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_release_search returns empty array when item has no mb_artist_ids" do
    get musicbrainz_release_search_admin_albums_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Dark Side"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_release_search returns empty array for blank query" do
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => ["83d91898-7763-47d7-b03b-b92132375c47"]))

    get musicbrainz_release_search_admin_albums_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: ""}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_release_search returns formatted results using artist MBID" do
    artist_mbid = "83d91898-7763-47d7-b03b-b92132375c47"
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => [artist_mbid]))

    mock_response = {
      success: true,
      data: {
        "release-groups" => [
          {
            "id" => "abc-123",
            "title" => "The Dark Side of the Moon",
            "artist-credit" => [{"artist" => {"name" => "Pink Floyd"}}],
            "first-release-date" => "1973-03-01",
            "primary-type" => "Album"
          },
          {
            "id" => "def-456",
            "title" => "The Dark Side of the Moon (Remaster)",
            "artist-credit" => [{"artist" => {"name" => "Pink Floyd"}}],
            "first-release-date" => "2011",
            "primary-type" => "Album"
          }
        ]
      }
    }

    Music::Musicbrainz::Search::ReleaseGroupSearch.any_instance
      .stubs(:search_by_artist_mbid_and_title)
      .with(artist_mbid, "Dark Side", limit: 10)
      .returns(mock_response)

    get musicbrainz_release_search_admin_albums_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Dark Side"}

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json.length
    assert_equal "abc-123", json[0]["value"]
    assert_equal "The Dark Side of the Moon - Pink Floyd (1973) [Album]", json[0]["text"]
    assert_equal "def-456", json[1]["value"]
    assert_equal "The Dark Side of the Moon (Remaster) - Pink Floyd (2011) [Album]", json[1]["text"]
  end

  test "musicbrainz_release_search returns empty array on api failure" do
    artist_mbid = "83d91898-7763-47d7-b03b-b92132375c47"
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => [artist_mbid]))

    mock_response = {
      success: false,
      data: nil,
      errors: ["API error"]
    }

    Music::Musicbrainz::Search::ReleaseGroupSearch.any_instance
      .stubs(:search_by_artist_mbid_and_title)
      .returns(mock_response)

    get musicbrainz_release_search_admin_albums_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Dark Side"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # modal action tests
  test "modal returns edit_metadata content" do
    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :edit_metadata)

    assert_response :success
    assert_match "Edit Metadata", response.body
    assert_match "turbo-frame", response.body
    assert_match Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID, response.body
  end

  test "modal returns link_album content" do
    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :link_album)

    assert_response :success
    assert_match "Link to Existing Album", response.body
    assert_match "turbo-frame", response.body
  end

  test "modal returns search_musicbrainz_releases content with warning when no artist match" do
    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_releases)

    assert_response :success
    assert_match "Search MusicBrainz Releases", response.body
    assert_match "requires an artist match first", response.body
  end

  test "modal returns search_musicbrainz_releases content with form when artist match exists" do
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => ["83d91898-7763-47d7-b03b-b92132375c47"]))

    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_releases)

    assert_response :success
    assert_match "Search MusicBrainz Releases", response.body
    assert_match "Search MusicBrainz for release groups", response.body
    assert_no_match(/requires an artist match first/, response.body)
  end

  test "modal returns search_musicbrainz_artists content" do
    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_artists)

    assert_response :success
    assert_match "Search MusicBrainz Artists", response.body
    assert_match "Search MusicBrainz for artists", response.body
  end

  test "modal returns error for invalid modal type" do
    get modal_admin_albums_list_item_path(list_id: @list.id, id: @item.id, modal_type: :invalid_type)

    assert_response :success
    assert_match "Invalid modal type", response.body
  end

  # link_musicbrainz_artist action tests
  test "link_musicbrainz_artist links artist to item" do
    mb_artist_id = "83d91898-7763-47d7-b03b-b92132375c47"
    mock_response = {
      success: true,
      data: {
        "artists" => [{
          "id" => mb_artist_id,
          "name" => "Pink Floyd",
          "type" => "Group",
          "country" => "GB"
        }]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_artist_id)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id}

    assert_response :redirect
    @item.reload
    assert_equal [mb_artist_id], @item.metadata["mb_artist_ids"]
    assert_equal ["Pink Floyd"], @item.metadata["mb_artist_names"]
  end

  test "link_musicbrainz_artist clears stale release group metadata when changing artist" do
    # Setup: Item has existing MusicBrainz release group match from a different artist
    @item.update!(
      listable: @album,
      verified: true,
      metadata: @item.metadata.merge(
        "mb_artist_ids" => ["old-artist-mbid"],
        "mb_artist_names" => ["Old Artist"],
        "mb_release_group_id" => "old-release-group-mbid",
        "mb_release_group_name" => "Old Album",
        "mb_release_year" => 1990,
        "musicbrainz_match" => true,
        "manual_musicbrainz_link" => true,
        "album_id" => @album.id,
        "album_name" => @album.title
      )
    )

    # Admin changes to a different artist
    new_artist_id = "83d91898-7763-47d7-b03b-b92132375c48"
    mock_response = {
      success: true,
      data: {
        "artists" => [{
          "id" => new_artist_id,
          "name" => "New Artist",
          "type" => "Person",
          "country" => "US"
        }]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(new_artist_id)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: new_artist_id}

    assert_response :redirect
    @item.reload

    # New artist should be set
    assert_equal [new_artist_id], @item.metadata["mb_artist_ids"]
    assert_equal ["New Artist"], @item.metadata["mb_artist_names"]

    # Stale release group metadata should be cleared
    assert_nil @item.metadata["mb_release_group_id"], "Stale mb_release_group_id should be cleared"
    assert_nil @item.metadata["mb_release_group_name"], "Stale mb_release_group_name should be cleared"
    assert_nil @item.metadata["mb_release_year"], "Stale mb_release_year should be cleared"
    assert_nil @item.metadata["musicbrainz_match"], "Stale musicbrainz_match should be cleared"
    assert_nil @item.metadata["manual_musicbrainz_link"], "Stale manual_musicbrainz_link should be cleared"

    # Stale album link should be cleared
    assert_nil @item.listable_id, "Stale listable should be cleared"
    assert_nil @item.metadata["album_id"], "Stale album_id should be cleared"
    assert_nil @item.metadata["album_name"], "Stale album_name should be cleared"

    # Item should no longer be verified (needs re-review after artist change)
    assert_not @item.verified?, "Item should not be verified after artist change"
  end

  test "link_musicbrainz_artist returns error when mb_artist_id missing" do
    post link_musicbrainz_artist_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_artist_ids"]
  end

  test "link_musicbrainz_artist returns error when artist not found" do
    mb_artist_id = "83d91898-7763-47d7-b03b-b92132375c49"
    mock_response = {
      success: false,
      data: nil,
      errors: ["Artist not found"]
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_artist_id)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_artist_ids"]
  end

  test "link_musicbrainz_artist accepts turbo stream format" do
    mb_artist_id = "83d91898-7763-47d7-b03b-b92132375c47"
    mock_response = {
      success: true,
      data: {
        "artists" => [{
          "id" => mb_artist_id,
          "name" => "Pink Floyd",
          "type" => "Group"
        }]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal [mb_artist_id], @item.metadata["mb_artist_ids"]
  end

  # musicbrainz_artist_search action tests
  test "musicbrainz_artist_search returns empty array for blank query" do
    get musicbrainz_artist_search_admin_albums_list_wizard_path(list_id: @list.id), params: {q: ""}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_artist_search returns empty array for short query" do
    get musicbrainz_artist_search_admin_albums_list_wizard_path(list_id: @list.id), params: {q: "a"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_artist_search returns formatted results" do
    mock_response = {
      success: true,
      data: {
        "artists" => [
          {
            "id" => "83d91898-7763-47d7-b03b-b92132375c47",
            "name" => "Pink Floyd",
            "type" => "Group",
            "country" => "GB",
            "disambiguation" => "English rock band"
          },
          {
            "id" => "other-artist-id",
            "name" => "Pink",
            "type" => "Person",
            "country" => "US",
            "disambiguation" => nil
          }
        ]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:search_by_name)
      .with("pink", limit: 10)
      .returns(mock_response)

    get musicbrainz_artist_search_admin_albums_list_wizard_path(list_id: @list.id), params: {q: "pink"}

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json.length
    assert_equal "83d91898-7763-47d7-b03b-b92132375c47", json[0]["value"]
    assert_equal "Pink Floyd (Group from English rock band)", json[0]["text"]
    assert_equal "other-artist-id", json[1]["value"]
    assert_equal "Pink (Person from US)", json[1]["text"]
  end

  test "musicbrainz_artist_search returns empty array on api failure" do
    mock_response = {
      success: false,
      data: nil,
      errors: ["API error"]
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:search_by_name)
      .returns(mock_response)

    get musicbrainz_artist_search_admin_albums_list_wizard_path(list_id: @list.id), params: {q: "pink"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Authorization tests
  test "requires admin authentication" do
    sign_out

    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: "{}"}}

    assert_response :redirect
  end

  test "regular user cannot access actions" do
    regular_user = users(:regular_user)
    sign_in_as(regular_user, stub_auth: true)

    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: "{}"}}

    assert_response :redirect
    assert_match(/Access denied/, flash[:alert])
  end

  private

  def sign_out
    delete "/auth/sign_out"
  rescue ActionController::RoutingError
    session.delete(:user_id) if defined?(session)
  end
end
