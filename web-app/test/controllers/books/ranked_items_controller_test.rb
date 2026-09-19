require "test_helper"
require "csv"

module Books
  class RankedItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
    end

    test "root renders the ranked grid" do
      get "/"
      assert_response :success
    end

    test "path-based pagination resolves the page" do
      seed_ranked_books(100)

      get "/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "query-string pagination still resolves the page" do
      seed_ranked_books(100)

      get "/?page=2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
    end

    test "page one redirects to the canonical root" do
      get "/page/1"
      assert_redirected_to "/"
      assert_response :moved_permanently
    end

    test "the-greatest-books redirects to the canonical root" do
      get "/the-greatest-books"
      assert_redirected_to "/"
      assert_response :moved_permanently
    end

    test "renders an explicit ranking configuration" do
      get "/rc/#{@rc.id}"
      assert_response :success
    end

    test "renders an explicit ranking configuration with a page" do
      seed_ranked_books(100)

      get "/rc/#{@rc.id}/page/2"

      assert_response :success
    end

    test "404s for a missing ranking configuration" do
      get "/rc/99999"
      assert_response :not_found
    end

    test "404s for a ranking configuration of the wrong type" do
      get "/rc/#{ranking_configurations(:games_global).id}"
      assert_response :not_found
    end

    test "404s for a page past the last page" do
      get "/page/999999"
      assert_response :not_found
    end

    test "renders page one when the configuration has no ranked books" do
      get "/rc/#{ranking_configurations(:books_inherited).id}"
      assert_response :success
    end

    test "marks the grid indexable" do
      get "/"
      assert @controller.view_assigns["indexable"]
    end

    test "pagination links are path-based, not query strings" do
      seed_ranked_books(100)

      get "/"

      assert_select "nav.pagy a[href='/page/2']"
    end

    test "rc-scoped pagination links do not leak ranking_configuration_id into the query string" do
      seed_ranked_books(200)

      get "/rc/#{@rc.id}/page/2"

      assert_select "nav.pagy a[href='/rc/#{@rc.id}/page/3']"
      assert_select "nav.pagy a[href*='ranking_configuration_id']", count: 0
    end

    test "a category filter renders" do
      get "/the-greatest/novels/books"

      assert_response :success
    end

    test "a country filter renders" do
      get "/the-greatest-books/written-by/french/authors"

      assert_response :success
    end

    test "a combined filter renders" do
      get "/the-greatest/novels/books/written-by/french/authors/from/1800/to/1900"

      assert_response :success
    end

    test "an unknown category slug is a 404" do
      get "/the-greatest/no-such-genre/books"

      assert_response :not_found
    end

    test "an unknown country slug is a 404" do
      get "/the-greatest-books/written-by/atlantean/authors"

      assert_response :not_found
    end

    test "a soft-deleted category slug is a 404" do
      get "/the-greatest/retired-genre/books"

      assert_response :not_found
    end

    test "a non-integer year is a 404" do
      get "/the-greatest-books/since/not-a-year"

      assert_response :not_found
    end

    test "an out-of-range year is a 404, not a 500" do
      get "/the-greatest-books/since/2147483648"

      assert_response :not_found
    end

    test "emits a canonical link at the sorted-slug form" do
      get "/the-greatest/novels,fiction/books"

      assert_response :success
      assert_select "link[rel=canonical][href$='/the-greatest/fiction,novels/books']"
    end

    test "a filtered page is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/the-greatest/novels/books"

      assert_select "meta[name=robots][content='index, follow']"
    end

    test "a filtered page with zero results is not indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/the-greatest-books/written-by/algerian/authors"

      assert_response :success
      assert_select "meta[name=robots][content='noindex, follow']"
    end

    test "a ranking-configuration page is not indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/rc/#{@rc.id}/the-greatest/novels/books"

      assert_response :success
      assert_select "meta[name=robots][content='noindex, follow']"
    end

    test "a ranking-configuration page emits no canonical link" do
      get "/rc/#{@rc.id}/the-greatest/novels/books"

      assert_response :success
      assert_select "link[rel=canonical]", false
    end

    test "an alternate ranking-configuration page emits no canonical link" do
      alternate = ranking_configurations(:books_inherited)

      get "/rc/#{alternate.id}/the-greatest/novels/books"

      assert_response :success
      assert_select "link[rel=canonical]", false
    end

    test "pagination past the last page is a 404" do
      get "/the-greatest/novels/books/page/99"

      assert_response :not_found
    end

    test "a filtered page does not N+1 on authors or covers" do
      assert_queries_count(9) { get "/the-greatest/novels/books" }
    end

    test "the index renders the filter bar and modal" do
      get "/"

      assert_response :success
      assert_select "button[onclick='books_filter_modal.showModal()']"
      assert_select "dialog#books_filter_modal"
    end

    test "a filtered index renders a chip per active filter" do
      get "/the-greatest/novels/books"

      assert_response :success
      assert_select "[data-testid=filter-chip]", 1
    end

    test "the modal category pane carries the current filter state as a deferred source" do
      get "/the-greatest/novels/books"

      assert_select "turbo-frame#books_filter_pane_category[data-pane-src]" do |frame|
        assert_match "category_slugs", frame.first["data-pane-src"]
        assert_match "novels", frame.first["data-pane-src"]
      end
    end

    test "a multi-category filter URL is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/the-greatest/fiction,novels/books"

      assert_response :success
      assert_select "meta[name=robots][content*=noindex]"
    end

    test "a single-category filter URL is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/the-greatest/novels/books"

      assert_response :success
      assert_select "meta[name=robots][content^=index]"
    end

    # --- user-owned configurations at /rc/:id (spec §9) ---

    test "a shared user-owned configuration renders for an anonymous visitor and is never cached" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
      refute_match "public", response.headers["Cache-Control"].to_s
      assert_equal config, @controller.view_assigns["custom_ranking_configuration"]
    end

    test "a private user-owned configuration 404s for anonymous visitors and non-owners" do
      config = ranking_configurations(:books_user)

      get "/rc/#{config.id}"
      assert_response :not_found

      sign_in_as users(:editor_user), stub_auth: true
      get "/rc/#{config.id}"
      assert_response :not_found
    end

    test "a private user-owned configuration renders for its owner without caching" do
      config = ranking_configurations(:books_user)
      sign_in_as users(:regular_user), stub_auth: true

      get "/rc/#{config.id}"

      assert_response :success
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_equal config, @controller.view_assigns["custom_ranking_configuration"]
    end

    test "a global configuration is still edge-cached and sets no custom banner" do
      get "/rc/#{@rc.id}"

      assert_response :success
      assert_match "public", response.headers["Cache-Control"].to_s
      assert_match "max-age=21600", response.headers["Cache-Control"].to_s
      assert_nil @controller.view_assigns["custom_ranking_configuration"]
    end

    test "book cards under a custom configuration keep the /rc/ prefix; the primary's do not" do
      config = ranking_configurations(:books_user_shared)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: config, rank: 1, score: 100)

      get "/rc/#{config.id}"
      assert_select "a[href=?]", "/rc/#{config.id}/book/war-and-peace"

      get "/"
      assert_select "a[href=?]", "/book/war-and-peace"
      assert_select "a[href^=?]", "/rc/", count: 0
    end

    test "a shared user-owned configuration's page carries the custom-ranking banner" do
      config = ranking_configurations(:books_user_shared)

      get "/rc/#{config.id}"

      assert_select "#custom-ranking-banner", count: 1
      assert_select "#custom-ranking-banner a[href=?]", "/"
    end

    test "a global configuration's page carries no custom-ranking banner" do
      get "/"
      assert_select "#custom-ranking-banner", count: 0
    end

    test "the books nav links to My Rankings" do
      get "/"
      assert_select "#navbar_my_books a[href=?]", "/my/rankings", minimum: 1
    end

    # --- CSV export (spec §9) ---

    BOM = CsvExports::Writer::BOM

    def parsed_csv
      CSV.parse(response.body.delete_prefix(BOM))
    end

    def generate_ok
      Services::CsvExports::RequestGenerate::Result.new(success?: true, data: {}, errors: [])
    end

    test "export requires sign-in" do
      get "/export.csv"

      assert_redirected_to "/"
    end

    test "export without the csv format is not routable" do
      get "/export"

      assert_response :not_found
    end

    test "a non-member gets the top 500 rows on demand, uncached" do
      seed_ranked_books(600)
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      get "/export.csv"

      assert_response :success
      assert_includes response.media_type, "text/csv"
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_equal "noindex", response.headers["X-Robots-Tag"]
      assert_includes response.headers["Content-Disposition"], "the-greatest-books-rankings-#{Date.current.iso8601}.csv"
      assert response.body.start_with?(BOM)
      rows = parsed_csv
      assert_equal CsvExports::Books::RankedBookRow::HEADERS, rows.first
      assert_equal 500, rows.size - 1
      assert_equal "War and Peace", rows[1][3]
    end

    test "a member's unfiltered export is served from the pre-built file" do
      export = CsvExport.create!(ranking_configuration: @rc, status: :ready, generated_at: Time.current)
      export.file.attach(io: StringIO.new("#{BOM}Rank,Title\n1,Prebuilt\n"),
        filename: "the-greatest-books-rankings-2026-09-18.csv", content_type: "text/csv")
      Services::CsvExports::RequestGenerate.expects(:call).never
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv"

      assert_response :success
      assert_equal "#{BOM}Rank,Title\n1,Prebuilt\n", response.body
      assert_includes response.headers["Content-Disposition"], "the-greatest-books-rankings-2026-09-18.csv"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "a member's unfiltered export with no file requests one and shows the preparing page" do
      Services::CsvExports::RequestGenerate.expects(:call).with(ranking_configuration: @rc).once.returns(generate_ok)
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv"

      assert_response :accepted
      assert_equal "text/html", response.media_type
      assert_equal "15", response.headers["Refresh"]
      assert_match "no-store", response.headers["Cache-Control"].to_s
      assert_select "[data-testid=csv-export-preparing]"
    end

    # Both fixture books carry the novels category; the 600 filler books carry
    # none, so the filter is what keeps them out of a member's uncapped export.
    test "a member's filtered export is generated on demand without a cap" do
      seed_ranked_books(600)
      Services::CsvExports::RequestGenerate.expects(:call).never
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?category_id=novels"

      assert_response :success
      rows = parsed_csv
      assert_equal ["War and Peace", "Crime and Punishment"], rows.drop(1).map { |row| row[3] }
    end

    test "every filter the page accepts applies to the export" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?country_id=french&published_start=1800&published_end=1900"

      assert_response :success
      assert_equal ["War and Peace"], parsed_csv.drop(1).map { |row| row[3] }
    end

    test "a collection filter applies to the export" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?collection=#{Collections::Registry.slugs(:books).first}"

      assert_response :success
      assert_includes response.media_type, "text/csv"
    end

    test "an unknown collection 404s" do
      sign_in_as users(:regular_user), stub_auth: true

      get "/export.csv?collection=nope"

      assert_response :not_found
    end

    test "an explicit ranking configuration exports its own ranks" do
      other = ranking_configurations(:books_inherited)
      RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: other, rank: 1, score: 1)
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      get "/rc/#{other.id}/export.csv"

      assert_response :success
      assert_equal ["Crime and Punishment"], parsed_csv.drop(1).map { |row| row[3] }
    end

    test "a private user-owned configuration's export 404s for a non-owner" do
      sign_in_as users(:editor_user), stub_auth: true

      get "/rc/#{ranking_configurations(:books_user).id}/export.csv"

      assert_response :not_found
    end

    test "the export is rate limited per user" do
      sign_in_as users(:user_with_expired_membership), stub_auth: true

      20.times { get "/export.csv" }
      assert_response :success

      get "/export.csv"
      assert_response :too_many_requests
    end

    # Rails appends an optional (.:format) to every route, so /.csv does reach
    # the cached index action -- and must come back as an error (406, no
    # template for csv), never as a CSV body carrying public cache headers.
    test "the cached index never answers with a csv body" do
      get "/.csv"
      refute_equal 200, response.status
      refute_equal "text/csv", response.media_type

      get "/index.csv"
      assert_response :not_found
    end

    test "the index carries the export link with the current filters" do
      get "/the-greatest/novels/books"

      assert_response :success
      assert_equal "/export.csv?category_id=novels", @controller.view_assigns["csv_export_path"]
    end

    test "the index on a configuration carries an rc export link" do
      get "/rc/#{@rc.id}"

      assert_equal "/rc/#{@rc.id}/export.csv", @controller.view_assigns["csv_export_path"]
    end

    private

    # Bulk-inserts filler so tests can reach page 2+ against the controller's
    # limit of 100. insert_all skips callbacks deliberately: creating these
    # row-by-row also enqueues a SearchIndexRequest per book, which dominated
    # the runtime of these tests.
    def seed_ranked_books(count)
      now = Time.current
      rows = Array.new(count) do |i|
        {title: "Filler Book #{i}", slug: "filler-book-#{i}", created_at: now, updated_at: now}
      end
      ids = Books::Book.insert_all(rows, returning: :id).rows.flatten

      RankedItem.insert_all(
        ids.each_with_index.map do |id, i|
          {item_id: id, item_type: "Books::Book", ranking_configuration_id: @rc.id,
           rank: i + 3, score: 10, created_at: now, updated_at: now}
        end
      )
    end
  end
end
