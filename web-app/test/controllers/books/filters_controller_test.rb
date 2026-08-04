require "test_helper"

module Books
  class FiltersControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @rc = ranking_configurations(:books_global)
    end

    test "redirects to the canonical path for a genre selection" do
      get "/filters", params: {category_slugs: ["novels"]}

      assert_response :see_other
      assert_redirected_to "/the-greatest/novels/books"
    end

    test "sorts slugs so the redirect target is canonical" do
      get "/filters", params: {category_slugs: ["novels", "fiction"]}

      assert_redirected_to "/the-greatest/fiction,novels/books"
    end

    test "combines genre, country and years" do
      get "/filters", params: {
        category_slugs: ["novels"],
        country_slugs: ["french"],
        year_start: "1900",
        year_end: "2000"
      }

      assert_redirected_to "/the-greatest/novels/books/written-by/french/authors/from/1900/to/2000"
    end

    test "an empty selection redirects to the root" do
      get "/filters"

      assert_redirected_to "/"
    end

    test "normalizes a zero-padded year" do
      get "/filters", params: {year_start: "0001900"}

      assert_redirected_to "/the-greatest-books/since/1900"
    end

    test "keeps a non-primary ranking configuration in the redirect" do
      alternate = ranking_configurations(:books_inherited)

      get "/filters", params: {category_slugs: ["novels"], ranking_configuration_id: alternate.id}

      assert_redirected_to "/rc/#{alternate.id}/the-greatest/novels/books"
    end

    test "adds no rc prefix for the primary ranking configuration" do
      get "/filters", params: {category_slugs: ["novels"], ranking_configuration_id: @rc.id}

      assert_redirected_to "/the-greatest/novels/books"
    end

    test "an unknown category slug is a 404" do
      get "/filters", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end

    test "an unknown country slug is a 404" do
      get "/filters", params: {country_slugs: ["atlantean"]}

      assert_response :not_found
    end

    test "a malformed year is a 404" do
      get "/filters", params: {year_start: "not-a-year"}

      assert_response :not_found
    end

    test "an unknown ranking configuration is a 404" do
      get "/filters", params: {ranking_configuration_id: 999_999}

      assert_response :not_found
    end

    test "the redirect is not cacheable" do
      get "/filters", params: {category_slugs: ["novels"]}

      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "options renders the facet frame" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/options"

      assert_response :success
      assert_select "turbo-frame#books_filter_options"
      assert_select "form[action='/filters']"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "options reflects the current selection as checked" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/options", params: {category_slugs: ["novels"]}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=novels][checked]"
    end

    test "options 404s on an unknown slug" do
      get "/filters/options", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end
  end
end
