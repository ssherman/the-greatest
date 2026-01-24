require "test_helper"

module Admin
  module Music
    class MusicbrainzSearchControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        # Set the host to match the music domain constraint
        host! Rails.application.config.domains[:music]
      end

      # Authentication/Authorization Tests

      test "should redirect to root for unauthenticated users" do
        get admin_musicbrainz_artists_path
        assert_redirected_to music_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_musicbrainz_artists_path
        assert_redirected_to music_root_path
      end

      test "should allow admin users to access artists" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Music::Musicbrainz::Search::ArtistSearch.any_instance.stubs(:search_by_name).returns({success: true, data: {"artists" => []}})

        get admin_musicbrainz_artists_path(q: "test")
        assert_response :success
      end

      test "should allow editor users to access artists" do
        sign_in_as(@editor_user, stub_auth: true)
        ::Music::Musicbrainz::Search::ArtistSearch.any_instance.stubs(:search_by_name).returns({success: true, data: {"artists" => []}})

        get admin_musicbrainz_artists_path(q: "test")
        assert_response :success
      end

      # Artists Search Tests

      test "should return empty array when query is blank" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_musicbrainz_artists_path, as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should return empty array when query is too short" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_musicbrainz_artists_path(q: "a"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should call MusicBrainz search with query" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .expects(:search_by_name)
          .with("Pink Floyd", limit: 20)
          .returns({success: true, data: {"artists" => []}})

        get admin_musicbrainz_artists_path(q: "Pink Floyd"), as: :json
        assert_response :success
      end

      test "should return formatted artist results" do
        sign_in_as(@admin_user, stub_auth: true)

        mock_artists = [
          {
            "id" => "83d91898-7763-47d7-b03b-b92132375c47",
            "name" => "Pink Floyd",
            "type" => "Group",
            "country" => "GB",
            "disambiguation" => nil
          }
        ]

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => mock_artists}})

        get admin_musicbrainz_artists_path(q: "Pink Floyd"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal 1, json_response.length
        assert_equal "83d91898-7763-47d7-b03b-b92132375c47", json_response.first["value"]
        assert_equal "Pink Floyd (Group from GB)", json_response.first["text"]
      end

      test "should format artist with disambiguation instead of country" do
        sign_in_as(@admin_user, stub_auth: true)

        mock_artists = [
          {
            "id" => "test-id",
            "name" => "The Beatles",
            "type" => "Group",
            "country" => "GB",
            "disambiguation" => "Liverpool rock band"
          }
        ]

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => mock_artists}})

        get admin_musicbrainz_artists_path(q: "Beatles"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal "The Beatles (Group from Liverpool rock band)", json_response.first["text"]
      end

      test "should format artist with only type" do
        sign_in_as(@admin_user, stub_auth: true)

        mock_artists = [
          {
            "id" => "test-id",
            "name" => "Test Artist",
            "type" => "Person",
            "country" => nil,
            "disambiguation" => nil
          }
        ]

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => mock_artists}})

        get admin_musicbrainz_artists_path(q: "Test"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal "Test Artist (Person)", json_response.first["text"]
      end

      test "should format artist with only location" do
        sign_in_as(@admin_user, stub_auth: true)

        mock_artists = [
          {
            "id" => "test-id",
            "name" => "Test Artist",
            "type" => nil,
            "country" => "US",
            "disambiguation" => nil
          }
        ]

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => mock_artists}})

        get admin_musicbrainz_artists_path(q: "Test"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal "Test Artist (US)", json_response.first["text"]
      end

      test "should format artist with only name" do
        sign_in_as(@admin_user, stub_auth: true)

        mock_artists = [
          {
            "id" => "test-id",
            "name" => "Test Artist",
            "type" => nil,
            "country" => nil,
            "disambiguation" => nil
          }
        ]

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => mock_artists}})

        get admin_musicbrainz_artists_path(q: "Test"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal "Test Artist", json_response.first["text"]
      end

      test "should return empty array when MusicBrainz search fails" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: false, errors: ["Network error"]})

        get admin_musicbrainz_artists_path(q: "Test"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should return empty array when MusicBrainz returns no artists" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Music::Musicbrainz::Search::ArtistSearch.any_instance
          .stubs(:search_by_name)
          .returns({success: true, data: {"artists" => nil}})

        get admin_musicbrainz_artists_path(q: "Test"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end
    end
  end
end
