require "test_helper"

class Games::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "should get index for games domain" do
    host! "dev.thegreatest.games"
    get games_root_url
    assert_response :success
    assert_select "h1", "Welcome to The Greatest Games!"
    assert_select "title", /The Greatest Games/
  end

  test "should use games layout" do
    host! "dev.thegreatest.games"
    get games_root_url
    assert_response :success
    assert_select "title", /The Greatest Games/
  end
end
