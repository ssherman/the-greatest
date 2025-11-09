require "test_helper"

module Admin
  module Music
    class AlbumsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @album = music_albums(:dark_side_of_the_moon)
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)

        host! Rails.application.config.domains[:music]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_albums_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_albums_path
        assert_redirected_to music_root_path
        assert_equal "Access denied. Admin or editor role required.", flash[:alert]
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_albums_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_albums_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_albums_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @album.id.to_s, score: 10.0, source: {title: @album.title}}]
        ::Search::Music::Search::AlbumGeneral.stubs(:call).returns(search_results)

        get admin_albums_path(q: "Dark Side")
        assert_response :success
      end

      test "should call OpenSearch with correct parameters on search" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::AlbumGeneral.expects(:call).with("Abbey Road", size: 1000).returns([])

        get admin_albums_path(q: "Abbey Road")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])

        assert_nothing_raised do
          get admin_albums_path(q: "nonexistentalbum")
        end

        assert_response :success
      end

      test "should handle sorting by title" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_albums_path(sort: "title")
        assert_response :success
      end

      test "should handle sorting by release_year" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_albums_path(sort: "release_year")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to title" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_nothing_raised do
          get admin_albums_path(sort: "invalid_column")
        end

        assert_response :success
      end

      # Show Tests

      test "should show album" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_album_path(@album)
        assert_response :success
      end

      test "should show album with external links" do
        sign_in_as(@admin_user, stub_auth: true)

        # Album should have external link from fixture
        assert @album.external_links.any?, "Album should have external links for this test"

        get admin_album_path(@album)
        assert_response :success
      end

      # New Tests

      test "should get new" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_album_path
        assert_response :success
      end

      # Create Tests

      test "should create album" do
        sign_in_as(@admin_user, stub_auth: true)

        # Stub background jobs that would be triggered on create
        ::Music::ImportAlbumReleasesJob.stubs(:perform_async)

        assert_difference("::Music::Album.count") do
          post admin_albums_path, params: {
            music_album: {
              title: "New Album",
              description: "A great album",
              release_year: 2020
            }
          }
        end

        assert_redirected_to admin_album_path(::Music::Album.last)
      end

      test "should not create album with invalid attributes" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Music::Album.count") do
          post admin_albums_path, params: {
            music_album: {
              title: "",
              description: "Missing title"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      # Edit Tests

      test "should get edit" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_album_path(@album)
        assert_response :success
      end

      # Update Tests

      test "should update album" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_album_path(@album), params: {
          music_album: {
            title: "Updated Title",
            release_year: 1974
          }
        }

        assert_redirected_to admin_album_path(@album)
        @album.reload
        assert_equal "Updated Title", @album.title
        assert_equal 1974, @album.release_year
      end

      test "should not update album with invalid attributes" do
        sign_in_as(@admin_user, stub_auth: true)

        original_title = @album.title

        patch admin_album_path(@album), params: {
          music_album: {
            title: ""
          }
        }

        assert_response :unprocessable_entity
        @album.reload
        assert_equal original_title, @album.title
      end

      # Destroy Tests

      test "should destroy album" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Music::Album.count", -1) do
          delete admin_album_path(@album)
        end

        assert_redirected_to admin_albums_path
      end

      # Search Autocomplete Tests

      test "should return json for autocomplete endpoint" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @album.id.to_s, score: 10.0, source: {title: @album.title}}]
        ::Search::Music::Search::AlbumGeneral.stubs(:call).returns(search_results)

        get search_admin_albums_path(q: "Dark"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal 1, json_response.length
        assert_equal @album.id, json_response.first["value"]
        assert_includes json_response.first["text"], @album.title
      end

      test "should return empty json for autocomplete with no results" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])

        get search_admin_albums_path(q: "nonexistent"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert_equal 0, json_response.length
      end

      test "should call OpenSearch with correct size limit for autocomplete" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Music::Search::AlbumGeneral.expects(:call).with("test", size: 10).returns([])

        get search_admin_albums_path(q: "test"), as: :json
        assert_response :success
      end

      # Action Execution Tests

      test "should execute single record action" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)

        post execute_action_admin_album_path(@album, action_name: "GenerateAlbumDescription")
        assert_redirected_to admin_album_path(@album)
      end

      test "should execute bulk action" do
        sign_in_as(@admin_user, stub_auth: true)
        album2 = music_albums(:wish_you_were_here)

        ::Music::AlbumDescriptionJob.expects(:perform_async).with(@album.id)
        ::Music::AlbumDescriptionJob.expects(:perform_async).with(album2.id)

        post bulk_action_admin_albums_path(
          action_name: "GenerateAlbumDescription",
          album_ids: [@album.id, album2.id]
        )

        assert_redirected_to admin_albums_path
      end

      test "should handle action errors gracefully" do
        sign_in_as(@admin_user, stub_auth: true)

        post execute_action_admin_album_path(@album, action_name: "MergeAlbum")

        assert_redirected_to admin_album_path(@album)
      end
    end
  end
end
