require "test_helper"

class Games::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "root redirects to ranked games for games domain" do
    host! "dev.thegreatest.games"
    get games_root_url
    assert_response :success
  end
end
