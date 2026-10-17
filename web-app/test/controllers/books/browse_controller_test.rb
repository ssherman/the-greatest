require "test_helper"

module Books
  class BrowseControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @rc = ranking_configurations(:books_global)
      @book = books_books(:war_and_peace)
      RankedItem.create!(item: @book, ranking_configuration: @rc, rank: 1, score: 100)
      CategoryItem.create!(category: categories(:books_politics_subject), item: @book)
      # These tests build one-book subjects and locations; the card minimum has
      # its own coverage in BrowseQueryTest.
      @original_browse_minimum = Rails.configuration.x.books.browse_min_category_books
      Rails.configuration.x.books.browse_min_category_books = 1
    end

    teardown do
      Rails.configuration.x.books.browse_min_category_books = @original_browse_minimum
    end

    test "categories renders and links to single-facet filter URLs" do
      get "/categories"

      assert_response :success
      assert_select "a[href='/the-greatest/novels/books']"
    end

    test "categories is edge cacheable" do
      get "/categories"

      assert_match "max-age", response.headers["Cache-Control"].to_s
      assert_match "public", response.headers["Cache-Control"].to_s
    end

    test "categories is indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/categories"

      assert_select "meta[name=robots][content^=index]"
    end

    test "a sorted categories variant is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/categories/sorted-by/name"

      assert_select "meta[name=robots][content^=noindex]"
    end

    test "a sorted countries variant is noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/countries/sorted-by/name"

      assert_select "meta[name=robots][content^=noindex]"
    end

    test "a non-default filter with the default sort is still indexable" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/categories/subjects"

      assert_select "meta[name=robots][content^=index]"
    end

    test "categories accepts a type filter" do
      get "/categories/subjects"

      assert_response :success
      assert_select "a[href='/the-greatest/politics/books']"
    end

    test "the canonical omits a sort even though the request accepts it" do
      get "/categories/sorted-by/name"

      assert_response :success
      assert_select "link[rel=canonical][href$='/categories']"
    end

    test "the canonical keeps the type because it is different content" do
      get "/categories/subjects"

      assert_select "link[rel=canonical][href$='/categories/subjects']"
    end

    test "a categories page past the first canonicalizes to itself, not to page 1" do
      120.times { |i| rank_category_book("Bulk Genre #{i}", :genre, i + 100) }

      get "/categories/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/categories/page/2']"
    end

    test "a paged categories canonical keeps the type filter" do
      120.times { |i| rank_category_book("Bulk Subject #{i}", :subject, i + 100) }

      get "/categories/subjects/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/categories/subjects/page/2']"
    end

    test "a countries page past the first canonicalizes to itself" do
      120.times { |i| rank_country_book("Bulk Country #{i}", i + 100) }

      get "/countries/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries/page/2']"
    end

    # The route constraint is what keeps /categories/sorted-by/<anything> from being
    # an unbounded space of indexable soft-duplicates of /categories.
    test "a bogus sort in the path is a 404, not a soft duplicate" do
      get "/categories/sorted-by/nonsense"

      assert_response :not_found
    end

    test "a page past the last is a 404" do
      get "/categories/page/9999"

      assert_response :not_found
    end

    test "categories renders no N+1" do
      assert_queries_count 4 do
        get "/categories"
      end
    end

    test "a category card reports its ranked count, not its catalog count" do
      get "/categories"

      card = css_select("a[href='/the-greatest/novels/books']").first.text

      assert_match(/\b1\b/, card)
      assert_no_match(/\b#{categories(:books_novels_genre).item_count}\b/, card)
    end

    test "a genre with catalog books but none of them ranked is not linked" do
      get "/categories"

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

    test "a default query value collapses to the bare path without looping" do
      get "/categories", params: {filter: "genre", sort: "book_count"}

      assert_response :moved_permanently
      assert_redirected_to "/categories"

      get "/categories"

      assert_response :success
    end

    test "a query sort on countries collapses too" do
      get "/countries", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/countries/sorted-by/name"
    end

    test "a query sort on an already-paged path keeps the page" do
      get "/categories/page/2", params: {sort: "name"}

      assert_response :moved_permanently
      assert_redirected_to "/categories/sorted-by/name/page/2"
    end

    # The guard must read request.query_parameters, NOT params -- on a routed
    # path the values arrive as path parameters, and reading params would make
    # every one of these redirect to itself forever.
    test "a routed path with the same values does not redirect" do
      get "/categories/subjects/sorted-by/name"

      assert_response :success
    end

    test "an unrelated query parameter does not trigger a redirect" do
      get "/categories", params: {utm_source: "newsletter"}

      assert_response :success
    end

    test "a page passed as an array does not raise" do
      get "/categories", params: {page: ["1"]}

      assert_response :moved_permanently
    end

    test "countries page 1 redirects to the bare path" do
      get "/countries/page/1"

      assert_response :moved_permanently
      assert_redirected_to "/countries"
    end

    test "countries sorted page 1 redirects to its own base" do
      get "/countries/sorted-by/name/page/1"

      assert_response :moved_permanently
      assert_redirected_to "/countries/sorted-by/name"
    end

    # Every /categories shape except /categories/:id is a route-level redirect straight
    # to the final /categories URL. BrowsePath never emits /page/1 and the
    # default sort and type never appear in a path, so a non-canonical request
    # to /categories itself folds in the same single hop.
    {
      "/genres" => "/categories",
      "/genres/page/2" => "/categories/page/2",
      "/genres/sorted-by/name" => "/categories/sorted-by/name",
      "/genres/filtered-by/genre" => "/categories",
      "/genres/filtered-by/location" => "/categories/settings",
      "/genres/filtered-by/subject/sorted-by/name/page/3" => "/categories/subjects/sorted-by/name/page/3",
      "/genres/filtered-by/location/page/1" => "/categories/settings",
      "/genres?filter=location&sort=name" => "/categories/settings/sorted-by/name",
      "/genres?filter=theme" => "/categories",
      "/categories?filter=subject" => "/categories/subjects",
      "/categories/page/1" => "/categories",
      "/categories/sorted-by/book_count" => "/categories",
      "/categories/settings/sorted-by/name/page/1" => "/categories/settings/sorted-by/name"
    }.each do |from, to|
      test "#{from} redirects permanently to #{to} in one hop" do
        get from

        assert_response :moved_permanently
        assert_equal "http://#{host}#{to}", response.location
        # The target must not redirect again. Paged targets past the fixtures' last
        # page 404 by design (pagy_path), so only an unpaged target is followed.
        unless to.include?("/page/")
          get to

          assert_response :success
        end
      end
    end

    test "a redirect carries no edge-cache headers" do
      get "/categories/page/1"

      assert_no_match "public", response.headers["Cache-Control"].to_s
    end

    test "page 2 is untouched by the page-one guard" do
      120.times { |i| rank_category_book("Bulk Guard #{i}", :subject, i + 100) }

      get "/categories/subjects/page/2"

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
