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
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_artists_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
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
        ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(search_results)

        get search_admin_artists_path(q: "Bowie"), as: :json
        assert_response :success
      end

      test "should return empty JSON array when search has no results" do
        sign_in_as(@admin_user, stub_auth: true)

        # Mock OpenSearch returning empty results
        ::Search::Music::Search::ArtistGeneral.stubs(:call).returns([])

        # Should not raise ArgumentError from in_order_of
        assert_nothing_raised do
          get search_admin_artists_path(q: "nonexistentartist"), as: :json
        end

        assert_response :success
        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should call search with size limit of 10 for autocomplete" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::ArtistGeneral.expects(:call).with("test", size: 10).returns([])

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
    end
  end
end
