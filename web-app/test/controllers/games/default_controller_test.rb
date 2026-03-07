require "test_helper"

module Games
  class DefaultControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatest.games"
    end

    test "root redirects to ranked games for games domain" do
      get games_root_url
      assert_response :success
    end

    test "should get rankings page" do
      get games_rankings_url
      assert_response :success
    end

    test "rankings page should have page title" do
      get games_rankings_url
      assert_response :success
      assert_select "title"
    end

    test "rankings page should have SEO meta description" do
      get games_rankings_url
      assert_response :success
      assert_select "meta[name='description']"
    end
  end
end
