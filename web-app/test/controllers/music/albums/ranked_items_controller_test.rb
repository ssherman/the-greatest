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
        get "/albums?page=2"
        assert_response :success
      end

      test "should get index with ranking configuration and page" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums?page=2"
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

      test "should get index with decade year filter" do
        get "/albums/1990s"
        assert_response :success
      end

      test "should get index with year range filter" do
        get "/albums/1980-2000"
        assert_response :success
      end

      test "should get index with single year filter" do
        get "/albums/1994"
        assert_response :success
      end

      test "should get index with year filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/1990s"
        assert_response :success
      end

      test "should get index with year filter and page" do
        get "/albums/1990s?page=2"
        assert_response :success
      end

      test "should get index with since year filter" do
        get "/albums/since/1980"
        assert_response :success
      end

      test "should get index with through year filter" do
        get "/albums/through/1980"
        assert_response :success
      end

      test "should get index with since filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/since/1980"
        assert_response :success
      end

      test "should get index with through filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/through/1980"
        assert_response :success
      end

      test "path-based pagination resolves the page" do
        get "/albums/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "query-string pagination still resolves the page" do
        get "/albums?page=2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "generated page urls are path-based" do
        get "/albums"

        assert_equal "/albums/page/2", @controller.view_assigns["pagy"].page_url(2)
      end

      test "the year filter does not leak into the query string" do
        get "/albums/since/1990"

        url = @controller.view_assigns["pagy"].page_url(2)

        assert_equal "/albums/since/1990/page/2", url
        refute_includes url, "year="
      end

      test "ranking configuration scope is preserved without leaking into the query string" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums"

        url = @controller.view_assigns["pagy"].page_url(2)

        assert_includes url, "/albums/page/2"
        refute_includes url, "ranking_configuration_id="
      end
    end
  end
end
