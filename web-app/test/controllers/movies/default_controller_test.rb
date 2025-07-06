require "test_helper"

class Movies::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "should get index for movies domain" do
    host! "dev.thegreatestmovies.org"
    get movies_root_url
    assert_response :success
    assert_select "h1", "Welcome to The Greatest Movies!"
    assert_select "title", /The Greatest Movies/
  end

  test "should use movies layout" do
    host! "dev.thegreatestmovies.org"
    get movies_root_url
    assert_response :success
    assert_select "title", /The Greatest Movies/
  end
end
