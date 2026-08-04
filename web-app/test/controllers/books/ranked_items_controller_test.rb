require "test_helper"

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

    test "the modal frame is lazy and carries the current filter state" do
      get "/the-greatest/novels/books"

      assert_select "turbo-frame#books_filter_options[loading=lazy]" do |frame|
        assert_match "category_slugs", frame.first["src"]
        assert_match "novels", frame.first["src"]
      end
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
