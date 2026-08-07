require "test_helper"

module Books
  class BrowseControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @rc = ranking_configurations(:books_global)
      @book = books_books(:war_and_peace)
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)
      CategoryItem.create!(category: categories(:books_politics_subject), item: @book)
    end

    test "genres renders and links to single-facet filter URLs" do
      get "/genres"

      assert_response :success
      assert_select "a[href='/the-greatest/novels/books']"
    end

    test "genres is edge cacheable" do
      get "/genres"

      assert_match "max-age", response.headers["Cache-Control"].to_s
      assert_match "public", response.headers["Cache-Control"].to_s
    end

    test "genres is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/genres"

      assert_select "meta[name=robots][content^=index]"
    end

    test "a sorted genres variant is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/genres/sorted-by/name"

      assert_select "meta[name=robots][content^=noindex]"
    end

    test "a sorted countries variant is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/countries/sorted-by/name"

      assert_select "meta[name=robots][content^=noindex]"
    end

    test "a non-default filter with the default sort is still indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/genres/filtered-by/subject"

      assert_select "meta[name=robots][content^=index]"
    end

    test "genres accepts a type filter" do
      get "/genres/filtered-by/subject"

      assert_response :success
      assert_select "a[href='/the-greatest/politics/books']"
    end

    test "the canonical omits a sort even though the request accepts it" do
      get "/genres/sorted-by/name"

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres']"
    end

    test "the canonical keeps the type because it is different content" do
      get "/genres/filtered-by/subject"

      assert_select "link[rel=canonical][href$='/genres/filtered-by/subject']"
    end

    test "a genres page past the first canonicalizes to itself, not to page 1" do
      120.times { |i| rank_category_book("Bulk Genre #{i}", :genre, i + 100) }

      get "/genres/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/page/2']"
    end

    test "a paged genres canonical keeps the type filter" do
      120.times { |i| rank_category_book("Bulk Subject #{i}", :subject, i + 100) }

      get "/genres/filtered-by/subject/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/filtered-by/subject/page/2']"
    end

    test "a countries page past the first canonicalizes to itself" do
      120.times { |i| rank_country_book("Bulk Country #{i}", i + 100) }

      get "/countries/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries/page/2']"
    end

    # The route constraint is what keeps /genres/sorted-by/<anything> from being
    # an unbounded space of indexable soft-duplicates of /genres.
    test "a bogus sort in the path is a 404, not a soft duplicate" do
      get "/genres/sorted-by/nonsense"

      assert_response :not_found
    end

    test "a page past the last is a 404" do
      get "/genres/page/9999"

      assert_response :not_found
    end

    test "genres renders no N+1" do
      assert_queries_count 4 do
        get "/genres"
      end
    end

    test "a genre card reports its ranked count, not its catalog count" do
      get "/genres"

      card = css_select("a[href='/the-greatest/novels/books']").first.text

      assert_match(/\b1\b/, card)
      assert_no_match(/\b#{categories(:books_novels_genre).item_count}\b/, card)
    end

    test "a genre with catalog books but none of them ranked is not linked" do
      get "/genres"

      assert_operator categories(:books_fiction_genre).item_count, :>, 0
      assert_select "a[href='/the-greatest/fiction/books']", false
    end

    test "countries renders and links to single-facet filter URLs" do
      get "/countries"

      assert_response :success
      assert_select "a[href='/the-greatest-books/written-by/french/authors']"
    end

    test "countries excludes the unknown bucket even when it holds ranked books" do
      Books::BookCountry.create!(book: @book, country: books_countries(:unknown))

      get "/countries"

      assert_select "a[href*='written-by/unknown']", false
    end

    test "a country with catalog books but none of them ranked is not linked" do
      get "/countries"

      assert_operator books_countries(:algerian).book_count, :>, 0
      assert_select "a[href*='written-by/algerian']", false
    end

    test "countries is edge cacheable and indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/countries"

      assert_match "public", response.headers["Cache-Control"].to_s
      assert_select "meta[name=robots][content^=index]"
    end

    test "the countries canonical omits a sort even though the request accepts it" do
      get "/countries/sorted-by/name"

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries']"
    end

    test "a countries page past the last is a 404" do
      get "/countries/page/9999"

      assert_response :not_found
    end

    test "the query string form redirects permanently to the path form" do
      get "/genres", params: {filter: "subject"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/filtered-by/subject"
    end

    test "both query axes collapse into one path" do
      get "/genres", params: {filter: "location", sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/filtered-by/location/sorted-by/name"
    end

    test "a query sort on countries collapses too" do
      get "/countries", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/countries/sorted-by/name"
    end

    test "a query page collapses to a path page" do
      get "/genres", params: {page: "2"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/page/2"
    end

    # A path page plus a query sort has to keep the page, which arrives as a
    # PATH parameter rather than a query one.
    test "a query sort on an already-paged path keeps the page" do
      get "/genres/page/2", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/genres/sorted-by/name/page/2"
    end

    # Junk normalizes away rather than 301ing to another junk URL.
    test "an unknown query value collapses to the bare path" do
      get "/genres", params: {filter: "nonsense", sort: "nonsense"}

      assert_response :moved_permanently
      assert_redirected_to "/genres"
    end

    test "a default query value collapses to the bare path without looping" do
      get "/genres", params: {filter: "genre", sort: "book_count"}

      assert_response :moved_permanently
      assert_redirected_to "/genres"

      get "/genres"

      assert_response :success
    end

    # The guard must read request.query_parameters, NOT params -- on a routed
    # path the values arrive as path parameters, and reading params would make
    # every one of these redirect to itself forever.
    test "a routed path with the same values does not redirect" do
      get "/genres/filtered-by/subject/sorted-by/name"

      assert_response :success
    end

    test "an unrelated query parameter does not trigger a redirect" do
      get "/genres", params: {utm_source: "newsletter"}

      assert_response :success
    end

    test "a page passed as an array does not raise" do
      get "/genres", params: {page: ["1"]}

      assert_response :moved_permanently
    end

    test "genres page 1 redirects to the bare path" do
      get "/genres/page/1"

      assert_response :moved_permanently
      assert_redirected_to "/genres"
    end

    test "countries page 1 redirects to the bare path" do
      get "/countries/page/1"

      assert_response :moved_permanently
      assert_redirected_to "/countries"
    end

    # BrowsePath never emits /page/1, so a .../page/1 URL on ANY of the eight
    # paginated shapes is a crawler-constructed duplicate of its own base. The
    # bare two above were once literal redirect routes; these six were not, and
    # served 200 with a canonical pointing elsewhere until the guard covered
    # every shape at once.
    {
      "/genres/sorted-by/name/page/1" => "/genres/sorted-by/name",
      "/genres/filtered-by/subject/page/1" => "/genres/filtered-by/subject",
      "/genres/filtered-by/location/page/1" => "/genres/filtered-by/location",
      "/genres/filtered-by/subject/sorted-by/name/page/1" => "/genres/filtered-by/subject/sorted-by/name",
      "/countries/sorted-by/name/page/1" => "/countries/sorted-by/name"
    }.each do |path, target|
      test "page 1 of #{path} redirects to its own base" do
        get path

        assert_response :moved_permanently
        assert_redirected_to target
      end
    end

    # The redirect strips only the page, never the facets -- a sorted URL keeps
    # its sort. Only the CANONICAL drops the sort; the URL identity does not.
    test "page 1 of a faceted path keeps its facets and lands on a 200" do
      get "/genres/filtered-by/subject/sorted-by/name/page/1"
      follow_redirect!

      assert_response :success
      assert_equal "/genres/filtered-by/subject/sorted-by/name", request.path
    end

    test "page 2 is untouched by the page-one guard" do
      120.times { |i| rank_category_book("Bulk Guard #{i}", :subject, i + 100) }

      get "/genres/filtered-by/subject/page/2"

      assert_response :success
    end

    private

    def ranked_book(name, rank)
      book = Books::Book.create!(title: name)
      RankedItem.create!(item: book, ranking_configuration: @rc, rank: rank, score: 1)
      book
    end

    def rank_category_book(name, type, rank)
      book = ranked_book(name, rank)
      CategoryItem.create!(category: Books::Category.create!(name: name, category_type: type), item: book)
    end

    def rank_country_book(name, rank)
      book = ranked_book(name, rank)
      Books::BookCountry.create!(book: book, country: Books::Country.create!(name: name))
    end
  end
end
