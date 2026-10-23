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

    def rank_book(book, rank = 1)
      RankedItem.create!(item: book, ranking_configuration: @rc, rank: rank, score: 100 - rank)
    end

    test "the genre pane renders its frame with facet rows" do
      rank_book(books_books(:war_and_peace))

      get "/filters/categories"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_genre"
      assert_select "input[data-type='genre'][data-slug='novels']"
      assert_match "no-store", response.headers["Cache-Control"].to_s
    end

    test "categories without a type renders genres" do
      rank_book(books_books(:war_and_peace))

      get "/filters/categories"

      assert_select "turbo-frame#books_filter_pane_genre"
      assert_select "input[data-type='genre']"
    end

    test "categories with an unknown type is a 404" do
      get "/filters/categories", params: {type: "bogus"}

      assert_response :not_found
    end

    test "categories with type=subject renders only subject rows" do
      book = books_books(:war_and_peace)
      rank_book(book)
      CategoryItem.find_or_create_by!(category: categories(:books_politics_subject), item: book)

      get "/filters/categories", params: {type: "subject"}

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_subject"
      assert_select "input[data-type='subject'][data-slug='politics']"
      assert_select "input[data-type='genre']", false
    end

    test "the subject pane's results frame carries a source that keeps the type and applied filters" do
      rank_book(books_books(:war_and_peace))

      get "/filters/categories", params: {type: "subject", category_slugs: ["novels"], year_start: "1900"}

      assert_response :success
      src = css_select("turbo-frame#books_filter_results_subject").first["data-results-src"]
      uri = URI.parse(src)
      query = Rack::Utils.parse_nested_query(uri.query)
      assert_equal "/filters/categories", uri.path
      assert_equal ["subject", ["novels"], "1900"], [query["type"], query["category_slugs"], query["year_start"]]
      assert_nil query["q"]
    end

    test "the genre pane is not capped" do
      rank_book(books_books(:war_and_peace))

      get "/filters/categories", params: {type: "genre"}

      assert_select "turbo-frame[id^='books_filter_results_']", false
    end

    test "the country pane renders its own frame" do
      rank_book(books_books(:war_and_peace))

      get "/filters/countries"

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_country"
      assert_select "input[data-axis='country'][data-slug='french']"
    end

    test "countries renders every country with ranked books" do
      rank_book(books_books(:war_and_peace))
      expected = Books::FilterFacetsQuery.countries(ranking_configuration: @rc).size

      get "/filters/countries"

      assert_select "input[data-axis='country']", expected
    end

    test "countries ignores q: origin filters in the browser" do
      rank_book(books_books(:war_and_peace))

      get "/filters/countries", params: {q: "zzz"}

      assert_select "turbo-frame#books_filter_pane_country"
    end

    test "no link on a filter pane is trapped in a pane frame" do
      rank_book(books_books(:war_and_peace))

      assert_no_frame_trapped_links "/filters/categories"
      assert_no_frame_trapped_links "/filters/categories?type=subject"
      assert_no_frame_trapped_links "/filters/countries"
    end

    test "the pane keeps an already-applied category in the browse list" do
      rank_book(books_books(:war_and_peace))

      get "/filters/categories", params: {category_slugs: ["novels"]}

      assert_response :success
      assert_select "input[data-slug='novels']"
    end

    # The public threshold counts book links, not item_count, so a fixture's
    # item_count alone no longer makes a subject or setting findable.
    def link_a_book(*category_fixtures)
      book = books_books(:war_and_peace)
      category_fixtures.each { |name| CategoryItem.find_or_create_by!(category: categories(name), item: book) }
      original = Rails.configuration.x.books.browse_min_category_books
      Rails.configuration.x.books.browse_min_category_books = 1
      @restore_minimum = -> { Rails.configuration.x.books.browse_min_category_books = original }
    end

    teardown { @restore_minimum&.call }

    test "a subject search returns name matches scoped to subjects" do
      link_a_book(:books_politics_subject)
      rank_book(books_books(:war_and_peace))

      get "/filters/categories", params: {q: "politics", type: "subject"}

      assert_response :success
      assert_select "turbo-frame#books_filter_results_subject"
      assert_select "turbo-frame#books_filter_pane_subject", false
      assert_select "input[data-slug='politics']"
    end

    test "a search does not return other types" do
      link_a_book(:books_american_history_subject, :books_american_location)
      rank_book(books_books(:war_and_peace))

      get "/filters/categories", params: {q: "americ", type: "subject"}

      assert_select "input[data-slug='american-history']"
      assert_select "input[data-slug='american-setting']", false
    end

    test "a search hides a location whose links are authors, not books" do
      place = ::Books::Category.create!(name: "Authorland", category_type: :location)
      5.times { |n| CategoryItem.create!(category: place, item: ::Books::Author.create!(name: "Writer #{n}")) }

      get "/filters/categories", params: {q: "authorland", type: "location"}

      assert_response :success
      assert_select "input[data-slug=?]", place.slug, false
    end

    test "a blank search returns the pane, not an empty results frame" do
      get "/filters/categories", params: {q: ""}

      assert_response :success
      assert_select "turbo-frame#books_filter_pane_genre"
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

    test "count returns the number of ranked books for a selection" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)

      get "/filters/count", params: {category_slugs: ["classics"]}, as: :json

      assert_response :success
      assert_equal({"count" => 1}, response.parsed_body)
    end

    test "count is a 404 for an unknown slug" do
      get "/filters/count", params: {category_slugs: ["no-such-genre"]}

      assert_response :not_found
    end

    test "count respects a collection" do
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      books_countries(:algerian).update!(labels: ["african"])
      Books::BookCountry.create!(book: books_books(:of_mice_and_men), country: books_countries(:algerian))
      CategoryItem.create!(category: categories(:books_classics_genre), item: books_books(:of_mice_and_men))
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 2, score: 90)

      get "/filters/count", params: {category_slugs: ["classics"]}, as: :json
      assert_equal 2, response.parsed_body["count"]

      get "/filters/count", params: {category_slugs: ["classics"], collection: "africa"}, as: :json
      assert_equal 1, response.parsed_body["count"]
    end

    test "count is not cacheable" do
      get "/filters/count", as: :json

      assert_match(/no-store|no-cache/, response.headers["Cache-Control"])
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
      assert_select "input[data-slug='classics']"
      assert_select "input[data-slug='novels']", false

      get "/filters/categories"

      assert_response :success
      assert_select "input[data-slug='novels']"
    end

    test "the filter modal for a private user-owned configuration 404s for a non-owner" do
      get "/filters", params: {ranking_configuration_id: ranking_configurations(:books_user).id}
      assert_response :not_found
    end

    test "the filter modal for a shared user-owned configuration renders" do
      config = ranking_configurations(:books_user_shared)

      get "/filters", params: {ranking_configuration_id: config.id}

      # #show always redirects (Books::FilterPath.call, status: :see_other) --
      # with no category/country/year params it redirects to the rc-prefixed
      # root. Asserting the redirect target (rather than :success, which a 303
      # can never satisfy) is what proves the gate let the request through
      # instead of 404ing it.
      assert_redirected_to "/rc/#{config.id}"
    end

    test "the public category search hides locations under the browse minimum" do
      ::Books::Category.create!(name: "Zzyzx Springs", category_type: :location, item_count: 1)

      get "/filters/categories", params: {q: "Zzyzx", type: "location"}

      assert_response :success
      assert_no_match "Zzyzx Springs", response.body
    end
  end
end
