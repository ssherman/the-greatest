# frozen_string_literal: true

require "test_helper"

module Games
  class SearchesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:games]
    end

    test "should get index with blank query" do
      get games_search_path
      assert_response :success
    end

    test "should get index with empty query parameter" do
      get games_search_path(q: "")
      assert_response :success
    end

    test "should handle no results without error" do
      ::Search::Games::Search::GameGeneral.stubs(:call).returns([])

      get games_search_path(q: "nonexistentgame")
      assert_response :success
    end

    test "should handle game results without error" do
      game = games_games(:breath_of_the_wild)
      game_results = [{id: game.id.to_s, score: 10.0, source: {title: game.title}}]

      ::Search::Games::Search::GameGeneral.stubs(:call).returns(game_results)

      get games_search_path(q: "Zelda")
      assert_response :success
    end

    test "should handle mixed results without error" do
      game1 = games_games(:breath_of_the_wild)
      game2 = games_games(:resident_evil_4)

      game_results = [
        {id: game1.id.to_s, score: 10.0, source: {title: game1.title}},
        {id: game2.id.to_s, score: 8.0, source: {title: game2.title}}
      ]

      ::Search::Games::Search::GameGeneral.stubs(:call).returns(game_results)

      get games_search_path(q: "game")
      assert_response :success
    end

    test "should call search with correct size parameter" do
      ::Search::Games::Search::GameGeneral.expects(:call).with("test", size: 50).returns([])

      get games_search_path(q: "test")
      assert_response :success
    end

    test "should handle special characters in query without error" do
      ::Search::Games::Search::GameGeneral.stubs(:call).returns([])

      get games_search_path(q: "AC/DC & More!")
      assert_response :success
    end

    test "should handle duplicate IDs without error" do
      game = games_games(:breath_of_the_wild)

      game_results = [
        {id: game.id.to_s, score: 10.0, source: {title: game.title}},
        {id: game.id.to_s, score: 9.0, source: {title: game.title}}
      ]

      ::Search::Games::Search::GameGeneral.stubs(:call).returns(game_results)

      get games_search_path(q: "Zelda")
      assert_response :success
    end
  end
end
