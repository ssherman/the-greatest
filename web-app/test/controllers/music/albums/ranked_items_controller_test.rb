require "test_helper"
require "csv"

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
        seed_ranked_albums(150)

        get "/albums?page=2"
        assert_response :success
      end

      test "should get index with ranking configuration and page" do
        seed_ranked_albums(150)

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
        seed_ranked_albums(150, release_year: 1995)

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
        seed_ranked_albums(150)

        get "/albums/page/2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "query-string pagination still resolves the page" do
        seed_ranked_albums(150)

        get "/albums?page=2"

        assert_response :success
        assert_equal 2, @controller.view_assigns["pagy"].page
      end

      test "404s for a page past the last page" do
        get "/albums/page/999999"

        assert_response :not_found
      end

      test "generated page urls are path-based" do
        get "/albums"

        assert_equal "/albums/page/2", @controller.view_assigns["pagy"].page_url(2)
      end

      test "generated page urls keep the format suffix at the end" do
        get "/albums.html"

        assert_equal "/albums/page/2.html", @controller.view_assigns["pagy"].page_url(2)
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

      # --- CSV export (spec §9) ---

      test "export requires sign-in" do
        get "/albums/export.csv"

        assert_redirected_to "/"
      end

      test "a non-member exports the ranked albums on demand" do
        RankedItem.create!(item: music_albums(:dark_side_of_the_moon),
          ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 100)
        sign_in_as users(:user_with_expired_membership), stub_auth: true

        get "/albums/export.csv"

        assert_response :success
        assert_includes response.media_type, "text/csv"
        assert_match "no-store", response.headers["Cache-Control"].to_s
        assert_equal "noindex", response.headers["X-Robots-Tag"]
        rows = CSV.parse(response.body.delete_prefix(CsvExports::Writer::BOM))
        assert_equal CsvExports::Music::RankedAlbumRow::HEADERS, rows.first
        assert_equal ["The Dark Side of the Moon"], rows.drop(1).map { |row| row[3] }
      end

      test "a year filter applies to the export" do
        RankedItem.create!(item: music_albums(:dark_side_of_the_moon),
          ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 100)
        sign_in_as users(:regular_user), stub_auth: true

        get "/albums/export.csv?year=1990&year_mode=since"

        assert_response :success
        assert_equal 1, CSV.parse(response.body.delete_prefix(CsvExports::Writer::BOM)).size
      end

      test "a member's unfiltered export with no file shows the preparing page" do
        Services::CsvExports::RequestGenerate.expects(:call)
          .with(ranking_configuration: ranking_configurations(:music_albums_global)).once
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))
        sign_in_as users(:regular_user), stub_auth: true

        get "/albums/export.csv"

        assert_response :accepted
        assert_equal "15", response.headers["Refresh"]
        assert_select "a[href='/albums']", text: "Back to the rankings"
      end

      test "export without the csv format is not routable" do
        get "/albums/export"

        assert_response :not_found
      end

      test "the index carries the export link" do
        get "/albums/since/1980"

        assert_equal "/albums/export.csv?year=1980&year_mode=since", @controller.view_assigns["csv_export_path"]
      end

      test "an explicit ranking configuration exports its own ranks" do
        secondary = ranking_configurations(:music_albums_secondary)
        RankedItem.create!(item: music_albums(:dark_side_of_the_moon), ranking_configuration: secondary, rank: 1, score: 50)
        sign_in_as users(:user_with_expired_membership), stub_auth: true

        get "/rc/#{secondary.id}/albums/export.csv"

        assert_response :success
        rows = CSV.parse(response.body.delete_prefix(CsvExports::Writer::BOM))
        assert_equal ["1", "50.00"], rows[1][0..1]
      end

      test "a shared user-owned configuration's export is reachable by a non-owner member" do
        config = ranking_configurations(:music_albums_user_shared)
        Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: config).once
          .returns(Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: []))
        sign_in_as users(:editor_user), stub_auth: true

        get "/rc/#{config.id}/albums/export.csv"

        assert_response :accepted
        assert_select "a[href='/rc/#{config.id}/albums']", text: "Back to the rankings"
      end

      # scope: :csv_export in CsvExportable -- one bucket per user across every
      # export controller. This is the only test that fails if scope: is dropped.
      test "the rate limit bucket is shared with the other domains' exports" do
        user = users(:user_with_expired_membership)
        host! Rails.application.config.domains[:books]
        sign_in_as user, stub_auth: true
        20.times { get "/export.csv" }
        assert_response :success

        host! "dev.thegreatestmusic.org"
        sign_in_as user, stub_auth: true
        get "/albums/export.csv"

        assert_response :too_many_requests
      end

      private

      # Bulk-inserts filler so tests can reach page 2+ against the
      # controller's limit of 100. insert_all skips callbacks deliberately
      # (avoids search indexing per row).
      def seed_ranked_albums(count, release_year: nil)
        now = Time.current
        rows = Array.new(count) do |i|
          {title: "Filler Album #{i}", slug: "filler-album-#{i}", release_year: release_year,
           created_at: now, updated_at: now}
        end
        ids = Music::Album.insert_all(rows, returning: :id).rows.flatten

        RankedItem.insert_all(
          ids.each_with_index.map do |id, i|
            {item_id: id, item_type: "Music::Album",
             ranking_configuration_id: ranking_configurations(:music_albums_global).id,
             rank: i + 1000, score: 10, created_at: now, updated_at: now}
          end
        )
      end
    end
  end
end
