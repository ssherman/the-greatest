require "test_helper"

module Books
  class IconsTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
    end

    test "the web manifest is served as application/manifest+json" do
      get "/icons/books/site.webmanifest"

      assert_response :success
      assert_equal "application/manifest+json", response.media_type
    end

    test "every icon the web manifest lists is served" do
      get "/icons/books/site.webmanifest"
      icons = JSON.parse(response.body).fetch("icons")

      assert_not_empty icons
      icons.each do |icon|
        get "/icons/books/#{icon.fetch("src")}"
        assert_response :success, "manifest icon #{icon["src"]} is missing"
        assert_equal icon.fetch("type"), response.media_type
      end
    end
  end
end
