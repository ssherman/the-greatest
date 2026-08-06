require "test_helper"

module Books
  class BrowseControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
    end

    test "genres renders and links to single-facet filter URLs" do
      get "/genres"

      assert_response :success
      assert_select "a[href='/the-greatest/fiction/books']"
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

    test "a bogus sort falls back rather than erroring" do
      get "/genres", params: {sort: "nonsense"}

      assert_response :success
    end

    test "a page past the last is a 404" do
      get "/genres/page/9999"

      assert_response :not_found
    end

    test "genres renders no N+1" do
      assert_queries_count 3 do
        get "/genres"
      end
    end

    test "countries renders and links to single-facet filter URLs" do
      get "/countries"

      assert_response :success
      assert_select "a[href='/the-greatest-books/written-by/french/authors']"
    end

    test "countries excludes the unknown bucket" do
      # book_count is a counter_cache target (Books::BookCountry belongs_to :country,
      # counter_cache: :book_count), so ActiveRecord silently drops it from a normal
      # update!/save -- update_column bypasses that and writes it directly.
      books_countries(:unknown).update_column(:book_count, 5)

      get "/countries"

      assert_select "a[href*='written-by/unknown']", false
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
  end
end
