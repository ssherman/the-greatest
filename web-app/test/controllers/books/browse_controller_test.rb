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

    test "genres accepts a type filter" do
      get "/genres", params: {filter: "subject"}

      assert_response :success
      assert_select "a[href='/the-greatest/politics/books']"
    end

    test "genres accepts a sort and its canonical omits it" do
      get "/genres", params: {sort: "name"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres']"
    end

    test "the canonical keeps the type because it is different content" do
      get "/genres", params: {filter: "subject"}

      assert_select "link[rel=canonical][href$='/genres?filter=subject']"
    end

    test "a genres page past the first canonicalizes to itself, not to page 1" do
      120.times { |i| rank_category_book("Bulk Genre #{i}", :genre, i + 100) }

      get "/genres/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/page/2']"
    end

    test "a paged genres canonical keeps the type filter" do
      120.times { |i| rank_category_book("Bulk Subject #{i}", :subject, i + 100) }

      get "/genres/page/2", params: {filter: "subject"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/genres/page/2?filter=subject']"
    end

    test "a countries page past the first canonicalizes to itself" do
      120.times { |i| rank_country_book("Bulk Country #{i}", i + 100) }

      get "/countries/page/2"

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries/page/2']"
    end

    test "a bogus sort falls back rather than erroring" do
      get "/genres", params: {sort: "nonsense"}

      assert_response :success
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

    test "countries accepts a sort" do
      get "/countries", params: {sort: "name"}

      assert_response :success
      assert_select "link[rel=canonical][href$='/countries']"
    end

    test "a countries page past the last is a 404" do
      get "/countries/page/9999"

      assert_response :not_found
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
