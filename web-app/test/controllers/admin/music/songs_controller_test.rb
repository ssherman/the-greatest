require "test_helper"

module Admin
  module Music
    class SongsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @song = music_songs(:time)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:music]
      end

      test "should redirect index to root for unauthenticated users" do
        get admin_songs_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should redirect index to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_songs_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_songs_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_songs_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @song.id.to_s, score: 10.0, source: {title: @song.title}}]
        ::Search::Music::Search::SongGeneral.stubs(:call).returns(search_results)

        get admin_songs_path(q: "Time")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

        assert_nothing_raised do
          get admin_songs_path(q: "nonexistentsong")
        end

        assert_response :success
      end

      test "should sort songs by allowed columns" do
        sign_in_as(@admin_user, stub_auth: true)

        get admin_songs_path(sort: "title")
        assert_response :success

        get admin_songs_path(sort: "release_year")
        assert_response :success

        get admin_songs_path(sort: "duration_secs")
        assert_response :success

        get admin_songs_path(sort: "created_at")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to title" do
        sign_in_as(@admin_user, stub_auth: true)

        get admin_songs_path(sort: "invalid_column")
        assert_response :success
      end

      test "should show song for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        get admin_song_path(@song)
        assert_response :success
      end

      test "should get new for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        get new_admin_song_path
        assert_response :success
      end

      test "should create song for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Song.count", 1) do
          post admin_songs_path, params: {
            music_song: {
              title: "New Song",
              duration_secs: 240,
              release_year: 2024
            }
          }
        end

        assert_redirected_to admin_song_path(::Music::Song.last)
        assert_equal "Song created successfully.", flash[:notice]
      end

      test "should not create song with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Music::Song.count") do
          post admin_songs_path, params: {
            music_song: {
              title: ""
            }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should get edit for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        get edit_admin_song_path(@song)
        assert_response :success
      end

      test "should update song for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_song_path(@song), params: {
          music_song: {
            title: "Updated Song Title"
          }
        }

        assert_redirected_to admin_song_path(@song)
        assert_equal "Song updated successfully.", flash[:notice]
        assert_equal "Updated Song Title", @song.reload.title
      end

      test "should not update song with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        original_title = @song.title

        patch admin_song_path(@song), params: {
          music_song: {
            title: ""
          }
        }

        assert_response :unprocessable_entity
        assert_equal original_title, @song.reload.title
      end

      test "should destroy song for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Song.count", -1) do
          delete admin_song_path(@song)
        end

        assert_redirected_to admin_songs_path
        assert_equal "Song deleted successfully.", flash[:notice]
      end

      test "should execute action for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        source_song = music_songs(:money)

        post execute_action_admin_song_path(@song), params: {
          action_name: "MergeSong",
          source_song_id: source_song.id,
          confirm_merge: "1"
        }

        assert_redirected_to admin_song_path(@song)
      end

      test "should return JSON search results for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @song.id.to_s, score: 10.0, source: {title: @song.title}}]
        ::Search::Music::Search::SongAutocomplete.stubs(:call).returns(search_results)

        get search_admin_songs_path(q: "Time"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert json_response.is_a?(Array)
        assert_equal @song.id, json_response.first["value"]
      end

      test "should return empty array for empty search results" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::SongAutocomplete.stubs(:call).returns([])

        get search_admin_songs_path(q: "nonexistent"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end
    end
  end
end
