require "test_helper"

module Music
  class DefaultControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"
    end

    test "should get index for music domain" do
      get music_root_url
      assert_response :success
      assert_select "h1", "The Greatest Music"
      assert_select "title", /Greatest Songs & Albums Ranked/
    end

    test "should use music layout" do
      get music_root_url
      assert_response :success
      assert_select "title", /The Greatest Music/
    end

    test "should display hero section" do
      get music_root_url
      assert_response :success
      assert_select ".hero"
      assert_select "a[href=?]", albums_path, text: "Top Albums"
      assert_select "a[href=?]", songs_path, text: "Top Songs"
    end

    test "should display SEO meta description" do
      get music_root_url
      assert_response :success
      assert_select "meta[name='description'][content*='Discover definitive rankings']"
    end
  end
end
