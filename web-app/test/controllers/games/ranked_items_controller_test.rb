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
      seed_ranked_games(150)

      get "/video-games?page=2"
      assert_response :success
    end

    test "should get index with ranking configuration and page" do
      seed_ranked_games(150)

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
      seed_ranked_games(150, release_year: 1995)

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

    test "root should render hero section when no filters" do
      get "/"
      assert_response :success
      assert_match(/What makes a video game truly great/i, response.body)
    end

    test "root should not render hero section with year filter" do
      get "/video-games/1990s"
      assert_response :success
      assert_no_match(/What makes a video game truly great/i, response.body)
    end

    test "root should not render hero section with page param" do
      seed_ranked_games(150)

      get "/?page=2"
      assert_response :success
      assert_no_match(/What makes a video game truly great/i, response.body)
    end

    test "root should not render hero section with ranking_configuration_id param" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games"
      assert_response :success
      assert_no_match(/What makes a video game truly great/i, response.body)
    end

    test "root should render coming soon when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/"
      assert_response :success
      assert_match(/coming soon/i, response.body)
    end

    test "coming soon page 1 still renders when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/video-games"
      assert_response :success
      assert_match(/coming soon/i, response.body)
    end

    test "high page number 404s when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/video-games/page/2"
      assert_response :not_found
    end

    test "path-based pagination resolves the page" do
      seed_ranked_games(150)

      get "/video-games/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      seed_ranked_games(150)

      get "/video-games?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "404s for a page past the last page" do
      get "/video-games/page/999999"

      assert_response :not_found
    end

    test "generated page urls are path-based" do
      get "/video-games"

      assert_equal "/video-games/page/2", @controller.view_assigns["pagy"].page_url(2)
    end

    test "page one links to the bare path, never /page/1" do
      seed_ranked_games(150)

      get "/video-games/page/2"

      assert_equal "/video-games", @controller.view_assigns["pagy"].page_url(1)
    end

    test "year filter segments do not leak into the query string" do
      get "/video-games/1990s"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/video-games/1990s/page/2", url
      refute_includes url, "year="
    end

    test "ranking configuration scope is preserved in generated page urls" do
      get "/rc/#{ranking_configurations(:games_global).id}/video-games"

      url = @controller.view_assigns["pagy"].page_url(2)

      assert_equal "/rc/#{ranking_configurations(:games_global).id}/video-games/page/2", url
      refute_includes url, "ranking_configuration_id="
    end

    private

    # Bulk-inserts filler so tests can reach page 2+ against the controller's
    # limit of 100. insert_all skips callbacks deliberately (avoids search
    # indexing per row).
    def seed_ranked_games(count, release_year: nil)
      now = Time.current
      rows = Array.new(count) do |i|
        {title: "Filler Game #{i}", slug: "filler-game-#{i}", release_year: release_year,
         created_at: now, updated_at: now}
      end
      ids = Games::Game.insert_all(rows, returning: :id).rows.flatten

      RankedItem.insert_all(
        ids.each_with_index.map do |id, i|
          {item_id: id, item_type: "Games::Game",
           ranking_configuration_id: ranking_configurations(:games_global).id,
           rank: i + 1000, score: 10, created_at: now, updated_at: now}
        end
      )
    end
  end
end
