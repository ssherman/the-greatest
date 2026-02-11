require "test_helper"

module Admin
  module Games
    class GamesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @editor_user = users(:editor_user)
        @regular_user = users(:regular_user)
        @game = games_games(:breath_of_the_wild)

        host! Rails.application.config.domains[:games]
      end

      # Authentication/Authorization Tests

      test "should redirect index to root for unauthenticated users" do
        get admin_games_games_path
        assert_redirected_to games_root_path
      end

      test "should redirect to root for regular users" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_games_path
        assert_redirected_to games_root_path
      end

      test "should allow admin users to access index" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_games_path
        assert_response :success
      end

      test "should allow editor users to access index" do
        sign_in_as(@editor_user, stub_auth: true)
        get admin_games_games_path
        assert_response :success
      end

      # Index Tests

      test "should get index without search" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_games_path
        assert_response :success
      end

      test "should get index with search query" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @game.id.to_s, score: 10.0, source: {title: @game.title}}]
        ::Search::Games::Search::GameGeneral.stubs(:call).returns(search_results)

        get admin_games_games_path(q: "Zelda")
        assert_response :success
      end

      test "should handle empty search results without error" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Games::Search::GameGeneral.stubs(:call).returns([])

        assert_nothing_raised do
          get admin_games_games_path(q: "nonexistentgame12345")
        end

        assert_response :success
      end

      test "should handle sorting by title" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_games_path(sort: "title")
        assert_response :success
      end

      test "should handle sorting by release_year" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_games_path(sort: "release_year")
        assert_response :success
      end

      test "should reject invalid sort parameters and default to title" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_nothing_raised do
          get admin_games_games_path(sort: "'; DROP TABLE games_games; --")
        end
        assert_response :success
      end

      # Show Tests

      test "should get show for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_game_path(@game)
        assert_response :success
      end

      test "should not get show for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_games_game_path(@game)
        assert_redirected_to games_root_path
      end

      # New Tests

      test "should get new for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get new_admin_games_game_path
        assert_response :success
      end

      test "should not get new for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get new_admin_games_game_path
        assert_redirected_to games_root_path
      end

      # Create Tests

      test "should create game for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Game.count", 1) do
          post admin_games_games_path, params: {
            games_game: {
              title: "New Game",
              release_year: 2024,
              game_type: "main_game"
            }
          }
        end

        assert_redirected_to admin_games_game_path(::Games::Game.last)
        assert_equal "Game created successfully.", flash[:notice]
      end

      test "should not create game with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_no_difference("::Games::Game.count") do
          post admin_games_games_path, params: {
            games_game: {
              title: "",
              game_type: "main_game"
            }
          }
        end

        assert_response :unprocessable_entity
      end

      test "should not create game for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Games::Game.count") do
          post admin_games_games_path, params: {
            games_game: {
              title: "New Game",
              game_type: "main_game"
            }
          }
        end

        assert_redirected_to games_root_path
      end

      # Edit Tests

      test "should get edit for admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get edit_admin_games_game_path(@game)
        assert_response :success
      end

      test "should not get edit for regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get edit_admin_games_game_path(@game)
        assert_redirected_to games_root_path
      end

      # Update Tests

      test "should update game for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_game_path(@game), params: {
          games_game: {
            title: "Updated Title"
          }
        }

        assert_redirected_to admin_games_game_path(@game)
        assert_equal "Game updated successfully.", flash[:notice]
        @game.reload
        assert_equal "Updated Title", @game.title
      end

      test "should not update game with invalid data" do
        sign_in_as(@admin_user, stub_auth: true)

        patch admin_games_game_path(@game), params: {
          games_game: {
            title: ""
          }
        }

        assert_response :unprocessable_entity
      end

      test "should not update game for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        patch admin_games_game_path(@game), params: {
          games_game: {
            title: "Updated Title"
          }
        }

        assert_redirected_to games_root_path
        @game.reload
        assert_not_equal "Updated Title", @game.title
      end

      # Destroy Tests

      test "should destroy game for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        assert_difference("::Games::Game.count", -1) do
          delete admin_games_game_path(@game)
        end

        assert_redirected_to admin_games_games_path
        assert_equal "Game deleted successfully.", flash[:notice]
      end

      test "should not destroy game for regular user" do
        sign_in_as(@regular_user, stub_auth: true)

        assert_no_difference("::Games::Game.count") do
          delete admin_games_game_path(@game)
        end

        assert_redirected_to games_root_path
      end

      # Search Endpoint Tests

      test "should return JSON search results for admin" do
        sign_in_as(@admin_user, stub_auth: true)

        search_results = [{id: @game.id.to_s, score: 10.0, source: {title: @game.title}}]
        ::Search::Games::Search::GameAutocomplete.stubs(:call).returns(search_results)

        get search_admin_games_games_path(q: "Zelda"), as: :json
        assert_response :success
      end

      test "should return empty JSON array when search has no results" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Games::Search::GameAutocomplete.stubs(:call).returns([])

        assert_nothing_raised do
          get search_admin_games_games_path(q: "nonexistentgame"), as: :json
        end

        assert_response :success
        json_response = JSON.parse(response.body)
        assert_equal [], json_response
      end

      test "should call search with size limit of 20 for autocomplete" do
        sign_in_as(@admin_user, stub_auth: true)

        ::Search::Games::Search::GameAutocomplete.expects(:call).with("test", size: 20).returns([])

        get search_admin_games_games_path(q: "test"), as: :json
        assert_response :success
      end
    end
  end
end
