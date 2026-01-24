require "test_helper"

module Admin
  module Music
    class ArtistsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @artist = music_artists(:david_bowie)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        # Set the host to match the music domain constraint
        host! Rails.application.config.domains[:music]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_artists_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. You need permission for music admin.", flash[:alert]
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_artists_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. You need permission for music admin.", flash[:alert]
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_artists_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_artists_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_artists_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock OpenSearch call
        search_results = [{id: @artist.id.to_s, score: 10.0, source: {name: @artist.name}}]
        ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(search_results)

        get admin_artists_path(q: "Bowie")
        assert_response :success
      end

      test "should call OpenSearch with correct parameters on search" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::ArtistGeneral.expects(:call).with("Beatles", size: 1000).returns([])

        get admin_artists_path(q: "Beatles")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock OpenSearch returning empty results
        ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])

        # Should not raise ArgumentError from in_order_of
        assert_nothing_raised do
          get admin_artists_path(q: "nonexistentartist")
        end

        assert_response :success
      end

      test "should handle sorting by name" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_artists_path(sort: "name")
        assert_response :success
      end

      test "should handle sorting by id" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_artists_path(sort: "id")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to name" do
        sign_in_as(@admin_user, stub_auth: true)

        # Should not raise an error, should default to sorting by name
        assert_nothing_raised do
          get admin_artists_path(sort: "'; DROP TABLE music_artists; --")
        end
        assert_response :success

        # Verify artists table still exists by querying it
        assert ::Music::Artist.count > 0
      end

      test "should only allow whitelisted sort columns" do
        sign_in_as(@admin_user, stub_auth: true)

        # Valid columns should work
        ["id", "name", "kind", "created_at"].each do |column|
          get admin_artists_path(sort: column)
          assert_response :success
        end

        # Invalid columns should default to name (no error)
        ["country", "description", "invalid", "music_artists.id; --"].each do |column|
          get admin_artists_path(sort: column)
          assert_response :success
        end
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_artist_path(@artist)
        assert_response :success
      end

      test "should get show for editor" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_artist_path(@artist)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_artist_path(@artist)
        assert_redirected_to music_root_path
      end

      test "should render show page with song_artists without error" do
        sign_in_as(@admin_user, stub_auth: true)
        artist_with_songs = music_artists(:pink_floyd)

        get admin_artist_path(artist_with_songs)
        assert_response :success
      end

      # New Tests

      test "should get new for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_artist_path
        assert_response :success
      end

      test "should not get new for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get new_admin_artist_path
        assert_redirected_to music_root_path
      end

      # Create Tests

      test "should create artist for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Artist.count", 1) do
          post admin_artists_path, params: {
            music_artist: {
              name: "New Artist",
              kind: "person",
              country: "US"
            }
          }
        end

        assert_redirected_to admin_artist_path(::Music::Artist.last)
        assert_equal "Artist created successfully.", flash[:notice]
      end

      test "should not create artist with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Music::Artist.count") do
          post admin_artists_path, params: {
            music_artist: {
              name: "",
              kind: "person"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should not create artist for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Music::Artist.count") do
          post admin_artists_path, params: {
            music_artist: {
              name: "New Artist",
              kind: "person"
            }
          }
        end

        assert_redirected_to music_root_path
      end

      # Edit Tests

      test "should get edit for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_artist_path(@artist)
        assert_response :success
      end

      test "should not get edit for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get edit_admin_artist_path(@artist)
        assert_redirected_to music_root_path
      end

      # Update Tests

      test "should update artist for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_artist_path(@artist), params: {
          music_artist: {
            name: "Updated Name"
          }
        }

        assert_redirected_to admin_artist_path(@artist)
        assert_equal "Artist updated successfully.", flash[:notice]
        @artist.reload
        assert_equal "Updated Name", @artist.name
      end

      test "should not update artist with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_artist_path(@artist), params: {
          music_artist: {
            name: ""
          }
        }

        assert_response :unprocessable_entity
      end

      test "should not update artist for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        patch admin_artist_path(@artist), params: {
          music_artist: {
            name: "Updated Name"
          }
        }

        assert_redirected_to music_root_path
        @artist.reload
        assert_not_equal "Updated Name", @artist.name
      end

      # Destroy Tests

      test "should destroy artist for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Artist.count", -1) do
          delete admin_artist_path(@artist)
        end

        assert_redirected_to admin_artists_path
        assert_equal "Artist deleted successfully.", flash[:notice]
      end

      test "should not destroy artist for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Music::Artist.count") do
          delete admin_artist_path(@artist)
        end

        assert_redirected_to music_root_path
      end

      # Search Endpoint Tests

      test "should return JSON search results for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @artist.id.to_s, score: 10.0, source: {name: @artist.name}}]
        ::Search::Music::Search::ArtistAutocomplete.stubs(:call).returns(search_results)

        get search_admin_artists_path(q: "Bowie"), as: :json
        assert_response :success
      end

      test "should return empty JSON array when search has no results" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock OpenSearch returning empty results
        ::Search::Music::Search::ArtistAutocomplete.stubs(:call).returns([])

        # Should not raise ArgumentError from in_order_of
        assert_nothing_raised do
          get search_admin_artists_path(q: "nonexistentartist"), as: :json
        end

        assert_response :success
        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should call search with size limit of 20 for autocomplete" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::ArtistAutocomplete.expects(:call).with("test", size: 20).returns([])

        get search_admin_artists_path(q: "test"), as: :json
        assert_response :success
      end

      # Action Execution Tests

      test "should execute action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock the job
        ::Music::CalculateArtistRankingJob.expects(:perform_async).with(@artist.id)

        post execute_action_admin_artist_path(@artist, action_name: "RefreshArtistRanking")
        assert_redirected_to admin_artist_path(@artist)
      end

      test "should not execute action for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        ::Music::CalculateArtistRankingJob.expects(:perform_async).never

        post execute_action_admin_artist_path(@artist, action_name: "RefreshArtistRanking")
        assert_redirected_to music_root_path
      end

      test "should execute index action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock the ranking configuration and job
        ranking_config = mock("ranking_config")
        ranking_config.stubs(:id).returns(1)
        ::Music::Artists::RankingConfiguration.stubs(:default_primary).returns(ranking_config)
        ::Music::CalculateAllArtistsRankingsJob.expects(:perform_async).with(1)

        post index_action_admin_artists_path(action_name: "RefreshAllArtistsRankings")
        assert_redirected_to admin_artists_path
      end

      test "should execute bulk action for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        artist2 = music_artists(:the_beatles)

        ::Music::ArtistDescriptionJob.expects(:perform_async).with(@artist.id)
        ::Music::ArtistDescriptionJob.expects(:perform_async).with(artist2.id)

        post bulk_action_admin_artists_path(
          action_name: "GenerateArtistDescription",
          artist_ids: [@artist.id, artist2.id]
        )
        assert_redirected_to admin_artists_path
      end

      # Merge Artist Tests

      test "should execute merge artist action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        source_artist = music_artists(:beatles_tribute_band)
        target_artist = music_artists(:the_beatles)

        post execute_action_admin_artist_path(target_artist), params: {
          action_name: "MergeArtist",
          source_artist_id: source_artist.id,
          confirm_merge: "1"
        }

        assert_redirected_to admin_artist_path(target_artist)
      end

      test "should handle merge action errors gracefully" do
        sign_in_as(@admin_user, stub_auth: true)

        post execute_action_admin_artist_path(@artist, action_name: "MergeArtist")

        assert_redirected_to admin_artist_path(@artist)
      end

      # Search with exclude_id Tests

      test "should filter out excluded artist id from search results" do
        sign_in_as(@admin_user, stub_auth: true)

        artist2 = music_artists(:the_beatles)
        search_results = [
          {id: @artist.id.to_s, score: 10.0},
          {id: artist2.id.to_s, score: 9.0}
        ]
        ::Search::Music::Search::ArtistAutocomplete.stubs(:call).returns(search_results)

        get search_admin_artists_path(q: "artist", exclude_id: @artist.id), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        artist_ids = json_response.map { |a| a["value"] }

        assert_not_includes artist_ids, @artist.id
        assert_includes artist_ids, artist2.id
      end

      test "should return empty array when exclude_id filters out all results" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @artist.id.to_s, score: 10.0}]
        ::Search::Music::Search::ArtistAutocomplete.stubs(:call).returns(search_results)

        get search_admin_artists_path(q: "artist", exclude_id: @artist.id), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should not filter when exclude_id is not provided" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @artist.id.to_s, score: 10.0}]
        ::Search::Music::Search::ArtistAutocomplete.stubs(:call).returns(search_results)

        get search_admin_artists_path(q: "artist"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal 1, json_response.length
      end

      # Import from MusicBrainz Tests

      test "should import artist from musicbrainz for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        new_artist = ::Music::Artist.new(id: 99999, name: "New Imported Artist")
        new_artist.stubs(:to_param).returns("99999")

        provider_result = DataImporters::ProviderResult.success(
          provider: "DataImporters::Music::Artist::Providers::MusicBrainz",
          data_populated: [:name, :kind, :country]
        )

        import_result = DataImporters::ImportResult.new(
          item: new_artist,
          provider_results: [provider_result],
          success: true
        )

        DataImporters::Music::Artist::Importer.stubs(:call)
          .with(musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47")
          .returns(import_result)

        post import_from_musicbrainz_admin_artists_path, params: {
          musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
        }

        assert_redirected_to admin_artist_path(new_artist)
        assert_equal "Artist imported successfully", flash[:notice]
      end

      test "should redirect to existing artist when already imported" do
        sign_in_as(@admin_user, stub_auth: true)

        import_result = DataImporters::ImportResult.new(
          item: @artist,
          provider_results: [],
          success: true
        )

        DataImporters::Music::Artist::Importer.stubs(:call)
          .with(musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47")
          .returns(import_result)

        post import_from_musicbrainz_admin_artists_path, params: {
          musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
        }

        assert_redirected_to admin_artist_path(@artist)
        assert_equal "Artist already exists", flash[:notice]
      end

      test "should show error when import fails" do
        sign_in_as(@admin_user, stub_auth: true)

        provider_result = DataImporters::ProviderResult.failure(
          provider: "DataImporters::Music::Artist::Providers::MusicBrainz",
          errors: ["MusicBrainz API error"]
        )

        import_result = DataImporters::ImportResult.new(
          item: nil,
          provider_results: [provider_result],
          success: false
        )

        DataImporters::Music::Artist::Importer.stubs(:call)
          .with(musicbrainz_id: "invalid-mbid")
          .returns(import_result)

        post import_from_musicbrainz_admin_artists_path, params: {
          musicbrainz_id: "invalid-mbid"
        }

        assert_redirected_to admin_artists_path
        assert_match(/Import failed/, flash[:alert])
      end

      test "should not allow import from musicbrainz for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        DataImporters::Music::Artist::Importer.expects(:call).never

        post import_from_musicbrainz_admin_artists_path, params: {
          musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47"
        }

        assert_redirected_to music_root_path
      end

      test "should show error when musicbrainz_id is missing" do
        sign_in_as(@admin_user, stub_auth: true)

        DataImporters::Music::Artist::Importer.expects(:call).never

        post import_from_musicbrainz_admin_artists_path, params: {}

        assert_redirected_to admin_artists_path
        assert_equal "Please select an artist from MusicBrainz", flash[:alert]
      end
    end
  end
end
