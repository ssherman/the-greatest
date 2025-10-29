require "test_helper"

module Music
  class DefaultControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get index for music domain" do
      get music_root_url
      assert_response :success
    end

    test "should have page title" do
      get music_root_url
      assert_response :success
      assert_select "title"
    end

    test "should have SEO meta description" do
      get music_root_url
      assert_response :success
      assert_select "meta[name='description']"
    end
  end
end
