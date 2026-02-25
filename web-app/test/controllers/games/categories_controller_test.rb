require "test_helper"

module Games
  class CategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    test "should get show for valid category" do
      get "/categories/action"
      assert_response :success
    end

    test "should get show with specific ranking configuration" do
      get "/rc/#{ranking_configurations(:games_global).id}/categories/action"
      assert_response :success
    end

    test "should return 404 for non-existent category" do
      get "/categories/nonexistent"
      assert_response :not_found
    end

    test "should return 404 for non-existent ranking configuration" do
      get "/rc/99999/categories/action"
      assert_response :not_found
    end

    test "should return 404 for wrong ranking configuration type" do
      get "/rc/#{ranking_configurations(:books_global).id}/categories/action"
      assert_response :not_found
    end

    test "should return 404 when no ranking configuration exists" do
      Games::RankingConfiguration.stubs(:default_primary).returns(nil)
      get "/categories/action"
      assert_response :not_found
    end
  end
end
