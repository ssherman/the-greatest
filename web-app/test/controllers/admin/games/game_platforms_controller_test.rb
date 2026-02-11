require "test_helper"

module Admin
  module Games
    class GamePlatformsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @game = games_games(:breath_of_the_wild)
        @game_platform = games_game_platforms(:botw_switch)
        @another_platform = games_platforms(:ps5)

        host! Rails.application.config.domains[:games]
        sign_in_as(@admin_user, stub_auth: true)
      end

      test "should create game_platform" do
        assert_difference("::Games::GamePlatform.count") do
          post admin_games_game_game_platforms_path(@game),
            params: {games_game_platform: {game_id: @game.id, platform_id: @another_platform.id}}
        end

        assert_redirected_to admin_games_game_path(@game)
      end

      test "should not create duplicate game_platform" do
        platform = games_platforms(:switch)

        assert_no_difference("::Games::GamePlatform.count") do
          post admin_games_game_game_platforms_path(@game),
            params: {games_game_platform: {game_id: @game.id, platform_id: platform.id}}
        end

        assert_redirected_to admin_games_game_path(@game)
      end

      test "should destroy game_platform" do
        assert_difference("::Games::GamePlatform.count", -1) do
          delete admin_games_game_platform_path(@game_platform)
        end

        assert_redirected_to admin_games_game_path(@game)
      end

      test "should require admin or editor role for create" do
        sign_in_as(@regular_user, stub_auth: true)

        post admin_games_game_game_platforms_path(@game),
          params: {games_game_platform: {game_id: @game.id, platform_id: @another_platform.id}}

        assert_redirected_to games_root_path
      end

      test "should require admin or editor role for destroy" do
        sign_in_as(@regular_user, stub_auth: true)

        delete admin_games_game_platform_path(@game_platform)

        assert_redirected_to games_root_path
      end
    end
  end
end
