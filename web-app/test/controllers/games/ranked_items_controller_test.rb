require "test_helper"

module Games
  class RankedItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    test "should get index with default global configuration" do
      get "/video-games"
      assert_response :success
    end

    test "should get index with specific ranking configuration" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games"
      assert_response :success
    end

    test "should get index with page parameter" do
      get "/video-games?page=2"
      assert_response :success
    end

    test "should get index with ranking configuration and page" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games?page=2"
      assert_response :success
    end

    test "should return 404 for non-existent ranking configuration" do
      get "/rc/99999/video-games"
      assert_response :not_found
    end

    test "should return 404 for wrong ranking configuration type" do
      get "/rc/#{ranking_configurations(:books_global).id}/video-games"
      assert_response :not_found
    end

    test "should get index with decade year filter" do
      get "/video-games/1990s"
      assert_response :success
    end

    test "should get index with year range filter" do
      get "/video-games/1990-2010"
      assert_response :success
    end

    test "should get index with single year filter" do
      get "/video-games/2017"
      assert_response :success
    end

    test "should get index with year filter and ranking configuration" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games/1990s"
      assert_response :success
    end

    test "should get index with year filter and page" do
      get "/video-games/1990s?page=2"
      assert_response :success
    end

    test "should get index with since year filter" do
      get "/video-games/since/2000"
      assert_response :success
    end

    test "should get index with through year filter" do
      get "/video-games/through/2010"
      assert_response :success
    end

    test "should get index with since filter and ranking configuration" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games/since/2000"
      assert_response :success
    end

    test "should get index with through filter and ranking configuration" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games/through/2010"
      assert_response :success
    end

    test "root should render ranked games" do
      get "/"
      assert_response :success
    end

    test "should render coming soon when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/video-games"
      assert_response :success
      assert_match(/coming soon/i, response.body)
    end

    test "root should render coming soon when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/"
      assert_response :success
      assert_match(/coming soon/i, response.body)
    end
  end
end
