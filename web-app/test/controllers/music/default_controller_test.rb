require "test_helper"

class Music::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "should get index for music domain" do
    host! "dev.thegreatestmusic.org"
    get music_root_url
    assert_response :success
    assert_select "h1", "Welcome to The Greatest Music!"
    assert_select "title", /The Greatest Music/
  end

  test "should use music layout" do
    host! "dev.thegreatestmusic.org"
    get music_root_url
    assert_response :success
    assert_select "title", /The Greatest Music/
  end
end
