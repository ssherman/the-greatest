require "test_helper"

module Admin
  module Games
    class PlatformsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @platform = games_platforms(:ps5)

        host! Rails.application.config.domains[:games]
      end

      test "should redirect index to root for unauthenticated users" do
        get admin_games_platforms_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_platforms_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_platforms_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_platforms_path(q: "PlayStation")
        assert_response :success
      end

      test "should handle sorting" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_platforms_path(sort: "name")
        assert_response :success
      end

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_platform_path(@platform)
        assert_response :success
      end

      test "should create platform for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Platform.count", 1) do
          post admin_games_platforms_path, params: {
            games_platform: {
              name: "New Console",
              abbreviation: "NC",
              platform_family: "other"
            }
          }
        end

        assert_redirected_to admin_games_platform_path(::Games::Platform.last)
      end

      test "should not create platform with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Platform.count") do
          post admin_games_platforms_path, params: {
            games_platform: { name: "" }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should update platform for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_platform_path(@platform), params: {
          games_platform: { name: "Updated PS5" }
        }

        assert_redirected_to admin_games_platform_path(@platform)
        @platform.reload
        assert_equal "Updated PS5", @platform.name
      end

      test "should destroy platform for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Platform.count", -1) do
          delete admin_games_platform_path(@platform)
        end

        assert_redirected_to admin_games_platforms_path
      end

      test "should return JSON search results" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_games_platforms_path(q: "Play"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert json_response.any? { |r| r["text"].include?("PlayStation") }
      end
    end
  end
end
