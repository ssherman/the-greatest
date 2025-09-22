require "test_helper"

module Music
  module Albums
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default global configuration" do
        get "/albums"
        assert_response :success
      end

      test "should get index with specific ranking configuration" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums"
        assert_response :success
      end

      test "should get index with page parameter" do
        get "/albums/page/2"
        assert_response :success
      end

      test "should get index with ranking configuration and page" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/page/2"
        assert_response :success
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/albums"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        get "/rc/#{ranking_configurations(:books_global).id}/albums"
        assert_response :not_found
      end
    end
  end
end
