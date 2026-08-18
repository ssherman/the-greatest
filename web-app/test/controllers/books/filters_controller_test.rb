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

    test "the category pane renders its frame with facet rows" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/categories"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_category"
      assert_select "turbo-frame#books_filter_results_category"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "the country pane renders its own frame" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/countries"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_country"
      assert_select "turbo-frame#books_filter_results_country"
    end

    test "no link on a filter pane is trapped in a pane frame" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      assert_no_frame_trapped_links "/filters/categories"
    end

    test "the pane excludes an already-applied category from the browse list" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)

      get "/filters/categories", params: {category_slugs: ["novels"]}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=novels]", false
    end

    test "searching returns only the results frame" do
      get "/filters/categories", params: {q: "fict"}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_category"
      assert_select "turbo-frame#books_filter_pane_category", false
      assert_select "input[name='category_slugs[]'][value=fiction]"
    end

    test "search reaches subjects and locations, not only genres" do
      get "/filters/categories", params: {q: "politics"}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=politics]"
    end

    test "country search returns the country results frame" do
      get "/filters/countries", params: {q: "fren"}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_country"
      assert_select "input[name='country_slugs[]'][value=french]"
    end

    test "a blank search returns an empty results frame" do
      get "/filters/categories", params: {q: ""}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_category"
      assert_select "input[name='category_slugs[]']", false
    end

    test "a category search result row tags its category type" do
      get "/filters/categories", params: {q: "americ"}

      assert_response :success
      assert_select "label[data-option-value=americana] .badge", text: "Genre"
    end

    # The Category axis spans genres, subjects and settings deliberately.
    # Scoping it here would break e2e/tests/books/filters.spec.ts.
    test "a category search still returns every category type, each tagged" do
      get "/filters/categories", params: {q: "americ"}

      assert_select "label[data-option-value=american-history] .badge", text: "Subject"
      assert_select "label[data-option-value=american-setting] .badge", text: "Setting"
    end

    test "a country search result row is not tagged with a category type" do
      get "/filters/countries", params: {q: "fren"}

      assert_response :success
      assert_select "label[data-option-value=french]"
      assert_select "label[data-option-value=french] .badge", false
    end

    test "the pane 404s on an unknown slug" do
      get "/filters/categories", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end

    test "the superseded options endpoint is gone" do
      get "/filters/options"

      assert_response :not_found
    end

    test "apply redirects back into the collection" do
      get "/filters", params: {collection: "africa", category_slugs: ["fiction"]}

      assert_redirected_to "/africa/the-greatest/fiction/books"
      assert_response :see_other
    end

    test "apply with no filters returns to the bare collection" do
      get "/filters", params: {collection: "africa"}

      assert_redirected_to "/africa"
    end

    test "an unknown collection on apply is not found" do
      get "/filters", params: {collection: "antarctica"}

      assert_response :not_found
    end

    test "the category pane's facet counts are scoped to the collection" do
      # war_and_peace -> french (western), categorized novels + classics.
      # of_mice_and_men -> made african here, categorized classics only.
      # Under collection: "africa" only of_mice_and_men's books count, so the
      # facet should offer classics but not novels; unscoped, both show up.
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      books_countries(:algerian).update!(labels: ["african"])
      Books::BookCountry.create!(book: books_books(:of_mice_and_men), country: books_countries(:algerian))
      CategoryItem.create!(category: categories(:books_classics_genre), item: books_books(:of_mice_and_men))
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 2, score: 90)

      get "/filters/categories", params: {collection: "africa"}

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=classics]"
      assert_select "input[name='category_slugs[]'][value=novels]", false

      get "/filters/categories"

      assert_response :success
      assert_select "input[name='category_slugs[]'][value=novels]"
    end
  end
end
