require "test_helper"

module Music
  module Artists
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default global configuration" do
        get "/artists"
        assert_response :success
      end

      test "should get index with page parameter" do
        seed_ranked_artists(150)

        get "/artists?page=2"
        assert_response :success
      end

      test "should handle missing ranking configuration gracefully" do
        Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

        get "/artists"
        assert_response :success
      end

      test "high page number 404s when no ranking configuration exists" do
        Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

        get "/artists/page/2"
        assert_response :not_found
      end

      test "path-based pagination resolves the page" do
        seed_ranked_artists(150)

        get "/artists/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "generated page urls are path-based" do
        get "/artists"

        assert_equal "/artists/page/2", @controller.view_assigns["pagy"].page_url(2)
      end

      test "404s for a page past the last page" do
        get "/artists/page/999999"

        assert_response :not_found
      end

      private

      # Bulk-inserts filler so tests can reach page 2+ against the
      # controller's limit of 100. insert_all skips callbacks deliberately
      # (avoids search indexing per row).
      def seed_ranked_artists(count)
        now = Time.current
        rows = Array.new(count) do |i|
          {name: "Filler Artist #{i}", slug: "filler-artist-#{i}", kind: 0, created_at: now, updated_at: now}
        end
        ids = Music::Artist.insert_all(rows, returning: :id).rows.flatten

        RankedItem.insert_all(
          ids.each_with_index.map do |id, i|
            {item_id: id, item_type: "Music::Artist",
             ranking_configuration_id: Music::Artists::RankingConfiguration.default_primary.id,
             rank: i + 1000, score: 10, created_at: now, updated_at: now}
          end
        )
      end
    end
  end
end
