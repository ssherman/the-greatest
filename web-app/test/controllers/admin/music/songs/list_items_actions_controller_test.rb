# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::ListItemsActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music]
    @list = lists(:music_songs_list)
    @admin_user = users(:admin_user)
    sign_in_as(@admin_user, stub_auth: true)

    @list.list_items.destroy_all
    @song = music_songs(:time)
    @item = @list.list_items.create!(
      listable_type: "Music::Song",
      verified: false,
      position: 1,
      metadata: {"title" => "Come Together", "artists" => ["The Beatles"], "rank" => 1}
    )
  end

  # verify action tests
  test "verify marks item as verified" do
    assert_not @item.verified?

    post verify_admin_songs_list_item_path(list_id: @list.id, id: @item.id)

    assert_response :redirect
    @item.reload
    assert @item.verified?
  end

  test "verify accepts turbo stream format" do
    post verify_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert @item.verified?
  end

  # metadata action tests
  test "metadata updates item metadata with valid JSON" do
    new_metadata = {"title" => "Fixed Title", "artists" => ["Fixed Artist"], "rank" => 1}

    patch metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate(new_metadata)}}

    assert_response :redirect
    @item.reload
    assert_equal "Fixed Title", @item.metadata["title"]
    assert_equal ["Fixed Artist"], @item.metadata["artists"]
  end

  test "metadata returns error for invalid JSON" do
    patch metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: "not valid json {"}}

    assert_response :redirect
    @item.reload
    assert_equal "Come Together", @item.metadata["title"]
  end

  test "metadata accepts turbo stream format" do
    new_metadata = {"title" => "Updated", "artists" => ["Artist"]}

    patch metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate(new_metadata)}},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal "Updated", @item.metadata["title"]
  end

  # manual_link action tests
  test "manual_link links song to item" do
    post manual_link_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {song_id: @song.id}

    assert_response :redirect
    @item.reload
    assert_equal @song.id, @item.listable_id
    assert @item.verified?
    assert_equal @song.id, @item.metadata["song_id"]
    assert_equal @song.title, @item.metadata["song_name"]
    assert @item.metadata["manual_link"]
  end

  test "manual_link returns error when song_id missing" do
    post manual_link_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {song_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.listable_id
    assert_not @item.verified?
  end

  test "manual_link returns error when song not found" do
    post manual_link_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {song_id: 999999}

    assert_response :redirect
    @item.reload
    assert_nil @item.listable_id
    assert_not @item.verified?
  end

  test "manual_link accepts turbo stream format" do
    post manual_link_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {song_id: @song.id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal @song.id, @item.listable_id
  end

  # link_musicbrainz_recording action tests
  test "link_musicbrainz_recording links recording to item" do
    mb_recording_id = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"
    mock_response = {
      success: true,
      data: {
        "recordings" => [{
          "id" => mb_recording_id,
          "title" => "Come Together",
          "artist-credit" => [{"artist" => {"name" => "The Beatles"}}],
          "first-release-date" => "1969-09-26"
        }]
      }
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_recording_id)
      .returns(mock_response)

    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: mb_recording_id}

    assert_response :redirect
    @item.reload
    assert @item.verified?, "Item should be verified after linking MusicBrainz recording"
    assert_equal mb_recording_id, @item.metadata["mb_recording_id"]
    assert_equal "Come Together", @item.metadata["mb_recording_name"]
    assert_equal "The Beatles", @item.metadata["mb_artist_names"]
    assert_equal 1969, @item.metadata["mb_release_year"]
    assert @item.metadata["musicbrainz_match"]
    assert @item.metadata["manual_musicbrainz_link"]
  end

  test "link_musicbrainz_recording returns error when mb_recording_id missing" do
    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_recording_id"]
  end

  test "link_musicbrainz_recording returns error when recording not found" do
    mb_recording_id = "nonexistent-mbid"
    mock_response = {
      success: false,
      data: nil,
      errors: ["Recording not found"]
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_recording_id)
      .returns(mock_response)

    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: mb_recording_id}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_recording_id"]
  end

  test "link_musicbrainz_recording accepts turbo stream format" do
    mb_recording_id = "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc"
    mock_response = {
      success: true,
      data: {
        "recordings" => [{
          "id" => mb_recording_id,
          "title" => "Come Together",
          "artist-credit" => [{"artist" => {"name" => "The Beatles"}}],
          "first-release-date" => "1969"
        }]
      }
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:lookup_by_mbid)
      .returns(mock_response)

    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: mb_recording_id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal mb_recording_id, @item.metadata["mb_recording_id"]
  end

  test "link_musicbrainz_recording clears stale listable when no local song matches the recording" do
    # Setup: Item already has a listable (from OpenSearch or manual link)
    @item.update!(
      listable: @song,
      verified: true,
      metadata: @item.metadata.merge(
        "song_id" => @song.id,
        "song_name" => @song.title
      )
    )
    assert_equal @song.id, @item.listable_id, "Precondition: item should have existing listable"

    # Admin links a MusicBrainz recording that has NO matching local song
    mb_recording_id = "new-recording-no-local-song"
    mock_response = {
      success: true,
      data: {
        "recordings" => [{
          "id" => mb_recording_id,
          "title" => "Different Song",
          "artist-credit" => [{"artist" => {"name" => "Different Artist"}}],
          "first-release-date" => "2020"
        }]
      }
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_recording_id)
      .returns(mock_response)

    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: mb_recording_id}

    assert_response :redirect
    @item.reload

    # The MusicBrainz metadata should be updated
    assert_equal mb_recording_id, @item.metadata["mb_recording_id"]
    assert_equal "Different Song", @item.metadata["mb_recording_name"]
    assert @item.metadata["manual_musicbrainz_link"]

    # The stale listable should be cleared since no local song matches the new recording
    assert_nil @item.listable_id, "Stale listable_id should be cleared when no local song matches"
    assert_nil @item.metadata["song_id"], "Stale song_id in metadata should be cleared"
    assert_nil @item.metadata["song_name"], "Stale song_name in metadata should be cleared"
  end

  test "link_musicbrainz_recording updates listable when local song matches the recording" do
    # Setup: Item has one song linked
    @item.update!(
      listable: @song,
      verified: true,
      metadata: @item.metadata.merge(
        "song_id" => @song.id,
        "song_name" => @song.title
      )
    )

    # Create a different song that has the MusicBrainz recording ID we'll link
    different_song = Music::Song.create!(title: "Different Song")
    mb_recording_id = "matching-recording-id"
    Identifier.create!(
      identifiable: different_song,
      identifier_type: :music_musicbrainz_recording_id,
      value: mb_recording_id
    )

    mock_response = {
      success: true,
      data: {
        "recordings" => [{
          "id" => mb_recording_id,
          "title" => "Different Song",
          "artist-credit" => [{"artist" => {"name" => "Different Artist"}}],
          "first-release-date" => "2020"
        }]
      }
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_recording_id)
      .returns(mock_response)

    post link_musicbrainz_recording_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_recording_id: mb_recording_id}

    assert_response :redirect
    @item.reload

    # The listable should be updated to the new matching song
    assert_equal different_song.id, @item.listable_id
    assert_equal different_song.id, @item.metadata["song_id"]
    assert_equal different_song.title, @item.metadata["song_name"]
  end

  # musicbrainz_recording_search action tests
  test "musicbrainz_recording_search returns empty array when item_id missing" do
    get musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id), params: {q: "Come Together"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_recording_search returns empty array when item has no mb_artist_ids" do
    get musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Come Together"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_recording_search returns empty array for blank query" do
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"]))

    get musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: ""}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_recording_search returns formatted results using artist MBID" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => [artist_mbid]))

    mock_response = {
      success: true,
      data: {
        "recordings" => [
          {
            "id" => "abc-123",
            "title" => "Come Together",
            "artist-credit" => [{"artist" => {"name" => "The Beatles"}}],
            "first-release-date" => "1969-09-26"
          },
          {
            "id" => "def-456",
            "title" => "Come Together (Remaster)",
            "artist-credit" => [{"artist" => {"name" => "The Beatles"}}],
            "first-release-date" => "2009"
          }
        ]
      }
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:search_by_artist_mbid_and_title)
      .with(artist_mbid, "Come Together", limit: 10)
      .returns(mock_response)

    get musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Come Together"}

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json.length
    assert_equal "abc-123", json[0]["value"]
    assert_equal "Come Together - The Beatles (1969)", json[0]["text"]
    assert_equal "def-456", json[1]["value"]
    assert_equal "Come Together (Remaster) - The Beatles (2009)", json[1]["text"]
  end

  test "musicbrainz_recording_search returns empty array on api failure" do
    artist_mbid = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => [artist_mbid]))

    mock_response = {
      success: false,
      data: nil,
      errors: ["API error"]
    }

    Music::Musicbrainz::Search::RecordingSearch.any_instance
      .stubs(:search_by_artist_mbid_and_title)
      .returns(mock_response)

    get musicbrainz_recording_search_admin_songs_list_wizard_path(list_id: @list.id),
      params: {item_id: @item.id, q: "Come Together"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # modal action tests
  test "modal returns edit_metadata content" do
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :edit_metadata)

    assert_response :success
    assert_match "Edit Metadata", response.body
    assert_match "turbo-frame", response.body
    assert_match Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID, response.body
  end

  test "modal returns link_song content" do
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :link_song)

    assert_response :success
    assert_match "Link to Existing Song", response.body
    assert_match "turbo-frame", response.body
  end

  test "modal returns search_musicbrainz_recordings content with warning when no artist match" do
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_recordings)

    assert_response :success
    assert_match "Search MusicBrainz Recordings", response.body
    assert_match "requires an artist match first", response.body
  end

  test "modal returns search_musicbrainz_recordings content with form when artist match exists" do
    @item.update!(metadata: @item.metadata.merge("mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"]))

    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_recordings)

    assert_response :success
    assert_match "Search MusicBrainz Recordings", response.body
    assert_match "Search MusicBrainz for recordings", response.body
    assert_no_match(/requires an artist match first/, response.body)
  end

  test "modal returns search_musicbrainz_artists content" do
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_musicbrainz_artists)

    assert_response :success
    assert_match "Search MusicBrainz Artists", response.body
    assert_match "Search MusicBrainz for artists", response.body
  end

  test "modal returns error for invalid modal type" do
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :invalid_type)

    assert_response :success
    assert_match "Invalid modal type", response.body
  end

  test "modal error preserves turbo-frame element for subsequent requests" do
    # First request with invalid type
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :invalid_type)

    assert_response :success
    # Verify the turbo-frame element is preserved in the response
    assert_match "turbo-frame", response.body
    assert_match Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID, response.body

    # Subsequent request with valid type should still work
    get modal_admin_songs_list_item_path(list_id: @list.id, id: @item.id, modal_type: :edit_metadata)

    assert_response :success
    assert_match "Edit Metadata", response.body
    assert_match "turbo-frame", response.body
  end

  # link_musicbrainz_artist action tests
  test "link_musicbrainz_artist links artist to item" do
    mb_artist_id = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    mock_response = {
      success: true,
      data: {
        "artists" => [{
          "id" => mb_artist_id,
          "name" => "The Beatles",
          "type" => "Group",
          "country" => "GB"
        }]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_artist_id)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id}

    assert_response :redirect
    @item.reload
    assert_equal [mb_artist_id], @item.metadata["mb_artist_ids"]
    assert_equal ["The Beatles"], @item.metadata["mb_artist_names"]
  end

  test "link_musicbrainz_artist clears stale recording metadata when changing artist" do
    # Setup: Item has existing MusicBrainz recording match from a different artist
    @item.update!(
      listable: @song,
      verified: true,
      metadata: @item.metadata.merge(
        "mb_artist_ids" => ["old-artist-mbid"],
        "mb_artist_names" => ["Old Artist"],
        "mb_recording_id" => "old-recording-mbid",
        "mb_recording_name" => "Old Recording",
        "mb_release_year" => 1990,
        "musicbrainz_match" => true,
        "manual_musicbrainz_link" => true,
        "song_id" => @song.id,
        "song_name" => @song.title
      )
    )

    # Admin changes to a different artist
    new_artist_id = "new-artist-mbid"
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

    post link_musicbrainz_artist_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: new_artist_id}

    assert_response :redirect
    @item.reload

    # New artist should be set
    assert_equal [new_artist_id], @item.metadata["mb_artist_ids"]
    assert_equal ["New Artist"], @item.metadata["mb_artist_names"]

    # Stale recording metadata should be cleared
    assert_nil @item.metadata["mb_recording_id"], "Stale mb_recording_id should be cleared"
    assert_nil @item.metadata["mb_recording_name"], "Stale mb_recording_name should be cleared"
    assert_nil @item.metadata["mb_release_year"], "Stale mb_release_year should be cleared"
    assert_nil @item.metadata["musicbrainz_match"], "Stale musicbrainz_match should be cleared"
    assert_nil @item.metadata["manual_musicbrainz_link"], "Stale manual_musicbrainz_link should be cleared"

    # Stale song link should be cleared
    assert_nil @item.listable_id, "Stale listable should be cleared"
    assert_nil @item.metadata["song_id"], "Stale song_id should be cleared"
    assert_nil @item.metadata["song_name"], "Stale song_name should be cleared"

    # Item should no longer be verified (needs re-review after artist change)
    assert_not @item.verified?, "Item should not be verified after artist change"
  end

  test "link_musicbrainz_artist returns error when mb_artist_id missing" do
    post link_musicbrainz_artist_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: ""}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_artist_ids"]
  end

  test "link_musicbrainz_artist returns error when artist not found" do
    mb_artist_id = "nonexistent-mbid"
    mock_response = {
      success: false,
      data: nil,
      errors: ["Artist not found"]
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .with(mb_artist_id)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id}

    assert_response :redirect
    @item.reload
    assert_nil @item.metadata["mb_artist_ids"]
  end

  test "link_musicbrainz_artist accepts turbo stream format" do
    mb_artist_id = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"
    mock_response = {
      success: true,
      data: {
        "artists" => [{
          "id" => mb_artist_id,
          "name" => "The Beatles",
          "type" => "Group"
        }]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:lookup_by_mbid)
      .returns(mock_response)

    post link_musicbrainz_artist_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {mb_artist_id: mb_artist_id},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal [mb_artist_id], @item.metadata["mb_artist_ids"]
  end

  # musicbrainz_artist_search action tests
  test "musicbrainz_artist_search returns empty array for blank query" do
    get musicbrainz_artist_search_admin_songs_list_wizard_path(list_id: @list.id), params: {q: ""}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_artist_search returns empty array for short query" do
    get musicbrainz_artist_search_admin_songs_list_wizard_path(list_id: @list.id), params: {q: "a"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "musicbrainz_artist_search returns formatted results" do
    mock_response = {
      success: true,
      data: {
        "artists" => [
          {
            "id" => "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d",
            "name" => "The Beatles",
            "type" => "Group",
            "country" => "GB",
            "disambiguation" => "Liverpool"
          },
          {
            "id" => "4d5bbb57-8c4c-4a7f-a3ab-8b6e6c9c8e4c",
            "name" => "Beatles",
            "type" => "Group",
            "country" => nil,
            "disambiguation" => "São Paulo"
          }
        ]
      }
    }

    Music::Musicbrainz::Search::ArtistSearch.any_instance
      .stubs(:search_by_name)
      .with("beatles", limit: 10)
      .returns(mock_response)

    get musicbrainz_artist_search_admin_songs_list_wizard_path(list_id: @list.id), params: {q: "beatles"}

    assert_response :success
    json = JSON.parse(response.body)

    assert_equal 2, json.length
    assert_equal "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d", json[0]["value"]
    assert_equal "The Beatles (Group from Liverpool)", json[0]["text"]
    assert_equal "4d5bbb57-8c4c-4a7f-a3ab-8b6e6c9c8e4c", json[1]["value"]
    assert_equal "Beatles (Group from São Paulo)", json[1]["text"]
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

    get musicbrainz_artist_search_admin_songs_list_wizard_path(list_id: @list.id), params: {q: "beatles"}

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Authorization tests
  test "requires admin authentication" do
    sign_out

    patch metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: "{}"}}

    assert_response :redirect
  end

  test "regular user cannot access actions" do
    regular_user = users(:regular_user)
    sign_in_as(regular_user, stub_auth: true)

    patch metadata_admin_songs_list_item_path(list_id: @list.id, id: @item.id),
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
