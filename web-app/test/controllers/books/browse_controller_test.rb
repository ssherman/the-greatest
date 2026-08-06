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
  end
end
