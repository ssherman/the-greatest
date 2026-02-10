require "test_helper"

module Admin
  module Games
    class SeriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @series = games_series(:zelda)

        host! Rails.application.config.domains[:games]
      end

      test "should redirect index to root for unauthenticated users" do
        get admin_games_series_index_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_series_index_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_series_index_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_series_index_path(q: "Zelda")
        assert_response :success
      end

      test "should handle sorting" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_series_index_path(sort: "name")
        assert_response :success
      end

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_series_path(@series)
        assert_response :success
      end

      test "should create series for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Series.count", 1) do
          post admin_games_series_index_path, params: {
            games_series: {
              name: "New Series"
            }
          }
        end

        assert_redirected_to admin_games_series_path(::Games::Series.last)
      end

      test "should not create series with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Series.count") do
          post admin_games_series_index_path, params: {
            games_series: { name: "" }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should update series for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_series_path(@series), params: {
          games_series: { name: "Updated Zelda" }
        }

        assert_redirected_to admin_games_series_path(@series)
        @series.reload
        assert_equal "Updated Zelda", @series.name
      end

      test "should destroy series for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Series.count", -1) do
          delete admin_games_series_path(@series)
        end

        assert_redirected_to admin_games_series_index_path
      end

      test "should return JSON search results" do
        sign_in_as(@admin_user, stub_auth: true)
        get search_admin_games_series_index_path(q: "Zel"), as: :json
        assert_response :success

        json_response = JSON.parse(response.body)
        assert json_response.any? { |r| r["text"].include?("Zelda") }
      end
    end
  end
end
