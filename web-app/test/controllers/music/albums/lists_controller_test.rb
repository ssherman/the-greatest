require "test_helper"
require "active_record/testing/query_assertions"

module Music
  module Albums
    class ListsControllerTest < ActionDispatch::IntegrationTest
      include ActiveRecord::Assertions::QueryAssertions

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

      test "should handle page parameter on show" do
        list = lists(:music_albums_list)
        get "/albums/lists/#{list.id}?page=1"
        assert_response :success
      end

      test "should return 404 for a page parameter beyond the last page" do
        list = lists(:music_albums_list)
        get "/albums/lists/#{list.id}?page=9999"
        assert_response :not_found
      end

      test "pagination links are path-based" do
        get "/albums/lists"

        assert_equal "/albums/lists/page/2", @controller.view_assigns["pagy"].page_url(2)
      end

      test "list show pagination is path-based and does not leak the id" do
        list = lists(:music_albums_list)

        get "/albums/lists/#{list.id}"

        url = @controller.view_assigns["pagy"].page_url(2)

        assert_equal "/albums/lists/#{list.id}/page/2", url
        refute_includes url, "id="
      end

      test "show renders each album's primary description" do
        list = lists(:music_albums_list)

        get "/albums/lists/#{list.id}"

        assert_response :success
        assert_includes response.body, descriptions(:dark_side_ai).content
      end

      test "show preloads descriptions rather than querying per row" do
        list = lists(:music_albums_list)

        assert_queries_match(/FROM "descriptions"/, count: 1) do
          get "/albums/lists/#{list.id}"
        end

        assert_response :success
      end

      test "no link on a list page is trapped in the list_items frame" do
        list = lists(:music_albums_list)

        assert_no_frame_trapped_links "/albums/lists/#{list.id}"
      end
    end
  end
end
