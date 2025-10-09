require "test_helper"

module Music
  module Albums
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default ranking configuration" do
        get "/albums/lists"
        assert_response :success
      end

      test "should get index with specific ranking configuration" do
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/lists"
        assert_response :success
      end

      test "should render index with lists" do
        get "/albums/lists"
        assert_response :success
        assert_select "h1", text: "Greatest Album Lists"
      end

      test "should handle sort parameter" do
        get "/albums/lists?sort=created_at"
        assert_response :success
      end

      test "should get show with list id" do
        list = lists(:music_albums_list)
        get "/albums/lists/#{list.id}"
        assert_response :success
      end

      test "should get show with specific ranking configuration" do
        list = lists(:music_albums_list)
        get "/rc/#{ranking_configurations(:music_albums_global).id}/albums/lists/#{list.id}"
        assert_response :success
      end

      test "should render show with list details" do
        list = lists(:music_albums_list)
        get "/albums/lists/#{list.id}"
        assert_response :success
        assert_select "h1", text: list.name
      end

      test "should return 404 for non-existent list" do
        get "/albums/lists/99999"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        get "/rc/#{ranking_configurations(:books_global).id}/albums/lists"
        assert_response :not_found
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/albums/lists"
        assert_response :not_found
      end
    end
  end
end
