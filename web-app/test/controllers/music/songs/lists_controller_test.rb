require "test_helper"

module Music
  module Songs
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default ranking configuration" do
        get "/songs/lists"
        assert_response :success
      end

      test "should get index with specific ranking configuration" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/lists"
        assert_response :success
      end

      test "should render index with lists" do
        get "/songs/lists"
        assert_response :success
        assert_select "h1", text: "Greatest Song Lists"
      end

      test "should handle sort parameter" do
        get "/songs/lists?sort=created_at"
        assert_response :success
      end

      test "should get show with list id" do
        list = lists(:music_songs_list)
        get "/songs/lists/#{list.id}"
        assert_response :success
      end

      test "should get show with specific ranking configuration" do
        list = lists(:music_songs_list)
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/lists/#{list.id}"
        assert_response :success
      end

      test "should render show with list details" do
        list = lists(:music_songs_list)
        get "/songs/lists/#{list.id}"
        assert_response :success
        assert_select "h1", text: list.name
      end

      test "should return 404 for non-existent list" do
        get "/songs/lists/99999"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        get "/rc/#{ranking_configurations(:books_global).id}/songs/lists"
        assert_response :not_found
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/songs/lists"
        assert_response :not_found
      end
    end
  end
end
