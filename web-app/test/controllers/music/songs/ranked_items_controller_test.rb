require "test_helper"

module Music
  module Songs
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default global configuration" do
        get "/songs"
        assert_response :success
      end

      test "should get index with specific ranking configuration" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs"
        assert_response :success
      end

      test "should get index with page parameter" do
        get "/songs/page/2"
        assert_response :success
      end

      test "should get index with ranking configuration and page" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/page/2"
        assert_response :success
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/songs"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        get "/rc/#{ranking_configurations(:books_global).id}/songs"
        assert_response :not_found
      end
    end
  end
end
