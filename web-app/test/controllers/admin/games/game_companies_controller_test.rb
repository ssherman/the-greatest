require "test_helper"

module Admin
  module Games
    class GameCompaniesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @game = games_games(:breath_of_the_wild)
        @company = games_companies(:nintendo)
        @game_company = games_game_companies(:botw_nintendo_dev)
        @another_company = games_companies(:capcom)

        host! Rails.application.config.domains[:games]
        sign_in_as(@admin_user, stub_auth: true)
      end

      test "should create game_company" do
        game = games_games(:half_life_2)

        assert_difference("::Games::GameCompany.count") do
          post admin_games_game_game_companies_path(game),
            params: {games_game_company: {game_id: game.id, company_id: @another_company.id, developer: true, publisher: false}}
        end

        assert_redirected_to admin_games_game_path(game)
      end

      test "should not create duplicate game_company" do
        assert_no_difference("::Games::GameCompany.count") do
          post admin_games_game_game_companies_path(@game),
            params: {games_game_company: {game_id: @game.id, company_id: @company.id, developer: true, publisher: false}}
        end

        assert_redirected_to admin_games_game_path(@game)
      end

      test "should update game_company roles" do
        patch admin_games_game_company_path(@game_company),
          params: {games_game_company: {developer: false, publisher: true}}

        @game_company.reload
        assert_not @game_company.developer?
        assert @game_company.publisher?
        assert_redirected_to admin_games_game_path(@game)
      end

      test "should destroy game_company" do
        assert_difference("::Games::GameCompany.count", -1) do
          delete admin_games_game_company_path(@game_company)
        end

        assert_redirected_to admin_games_game_path(@game)
      end

      test "should require admin or editor role for create" do
        sign_in_as(@regular_user, stub_auth: true)

        post admin_games_game_game_companies_path(@game),
          params: {games_game_company: {game_id: @game.id, company_id: @another_company.id, developer: true, publisher: false}}

        assert_redirected_to games_root_path
      end

      test "should require admin or editor role for update" do
        sign_in_as(@regular_user, stub_auth: true)

        patch admin_games_game_company_path(@game_company),
          params: {games_game_company: {developer: false, publisher: true}}

        assert_redirected_to games_root_path
      end

      test "should require admin or editor role for destroy" do
        sign_in_as(@regular_user, stub_auth: true)

        delete admin_games_game_company_path(@game_company)

        assert_redirected_to games_root_path
      end
    end
  end
end
