require "test_helper"

module Games
  class GamesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    test "should get show with default ranking configuration" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
      assert_select "title", /The Legend of Zelda: Breath of the Wild/
    end

    test "should get show with specific ranking configuration" do
      get game_path(games_games(:breath_of_the_wild), ranking_configuration_id: ranking_configurations(:games_global).id)
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
    end

    test "should get show by slug" do
      get game_path("the-legend-of-zelda-breath-of-the-wild")
      assert_response :success
      assert_select "h1", "The Legend of Zelda: Breath of the Wild"
    end

    test "should display release year" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_match "2017", response.body
    end

    test "should return 404 for non-existent game" do
      get game_path("non-existent-game")
      assert_response :not_found
    end

    test "should display non-main game type" do
      get game_path(games_games(:resident_evil_4_remake))
      assert_response :success
      assert_match "Remake", response.body
    end

    test "should show platforms section" do
      get game_path(games_games(:resident_evil_4_remake))
      assert_response :success
      assert_select "h2", /Platforms/
    end

    test "should show series section for games in a series" do
      get game_path(games_games(:breath_of_the_wild))
      assert_response :success
      assert_select "h2", /Zelda Series/
    end
  end
end
