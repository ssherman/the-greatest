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
        seed_ranked_songs(150)

        get "/songs?page=2"
        assert_response :success
      end

      test "should get index with ranking configuration and page" do
        seed_ranked_songs(150)

        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs?page=2"
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

      test "should get index with decade year filter" do
        get "/songs/1990s"
        assert_response :success
      end

      test "should get index with year range filter" do
        get "/songs/1980-2000"
        assert_response :success
      end

      test "should get index with single year filter" do
        get "/songs/1994"
        assert_response :success
      end

      test "should get index with year filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/1990s"
        assert_response :success
      end

      test "should get index with year filter and page" do
        seed_ranked_songs(150, release_year: 1995)

        get "/songs/1990s?page=2"
        assert_response :success
      end

      test "should get index with since year filter" do
        get "/songs/since/1980"
        assert_response :success
      end

      test "should get index with through year filter" do
        get "/songs/through/1980"
        assert_response :success
      end

      test "should get index with since filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/since/1980"
        assert_response :success
      end

      test "should get index with through filter and ranking configuration" do
        get "/rc/#{ranking_configurations(:music_songs_global).id}/songs/through/1980"
        assert_response :success
      end

      test "path-based pagination resolves the page" do
        seed_ranked_songs(150)

        get "/songs/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "query-string pagination still resolves the page" do
        seed_ranked_songs(150)

        get "/songs?page=2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "404s for a page past the last page" do
        get "/songs/page/999999"

        assert_response :not_found
      end

      test "the year filter does not leak into the query string" do
        get "/songs/since/1990"

        url = @controller.view_assigns["pagy"].page_url(2)

        assert_equal "/songs/since/1990/page/2", url
        refute_includes url, "year="
      end

      private

      # Bulk-inserts filler so tests can reach page 2+ against the
      # controller's limit of 100. insert_all skips callbacks deliberately
      # (avoids search indexing per row).
      def seed_ranked_songs(count, release_year: nil)
        now = Time.current
        rows = Array.new(count) do |i|
          {title: "Filler Song #{i}", slug: "filler-song-#{i}", release_year: release_year,
           created_at: now, updated_at: now}
        end
        ids = Music::Song.insert_all(rows, returning: :id).rows.flatten

        RankedItem.insert_all(
          ids.each_with_index.map do |id, i|
            {item_id: id, item_type: "Music::Song",
             ranking_configuration_id: ranking_configurations(:music_songs_global).id,
             rank: i + 1000, score: 10, created_at: now, updated_at: now}
          end
        )
      end
    end
  end
end
