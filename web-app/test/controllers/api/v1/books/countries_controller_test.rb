require "test_helper"

module Api
  module V1
    module Books
      class CountriesControllerTest < ActionDispatch::IntegrationTest
        # Ranked counts: french 2 (war_and_peace, got), japanese 2 (of_mice_and_men,
        # crime_and_punishment), algerian 1 (crime_and_punishment). So the default
        # order is french, japanese, algerian and the name order is algerian,
        # french, japanese: the two differ, and a dropped `sort` shows.
        #
        # The catalog counter columns are set to values that disagree with those
        # counts (and with their order), so a book_count read from the counter
        # shows too.
        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          [:war_and_peace, :got, :of_mice_and_men, :crime_and_punishment].each_with_index do |book, i|
            RankedItem.create!(item: books_books(book), ranking_configuration: @rc, rank: i + 1, score: 100 - i)
          end
          ::Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))
          ::Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:algerian))
          books_countries(:algerian).update_column(:book_count, 99)
          books_countries(:french).update_column(:book_count, 5)
          books_countries(:japanese).update_column(:book_count, 6)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "returns countries with ranked books, most first, with slug, name, book_count and url" do
          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[french japanese algerian], json[:data].map { |c| c[:slug] }
          assert_equal [2, 2, 1], json[:data].map { |c| c[:book_count] }
          french = json[:data].first
          assert_equal %i[slug name book_count url], french.keys
          assert_equal "French", french[:name]
          assert_equal "https://dev-new.thegreatestbooks.org#{::Books::FilterPath.call(countries: [books_countries(:french)])}", french[:url]
          assert_equal 3, json[:meta][:total_count]
        end

        test "a country whose books are all unranked is not listed" do
          unranked = ::Books::Country.create!(name: "Peruvian")
          ::Books::BookCountry.create!(book: books_books(:cannery_row), country: unranked)

          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_not_includes json[:data].map { |c| c[:slug] }, "peruvian"
        end

        test "sort=name orders by name" do
          get "/api/v1/countries?sort=name", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[algerian french japanese], json[:data].map { |c| c[:slug] }
          assert_equal [1, 2, 2], json[:data].map { |c| c[:book_count] }
        end

        test "sort rides on the paging links, and following next continues the same list" do
          get "/api/v1/countries?sort=name&per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          next_link = json[:links][:next]
          assert_includes next_link, "sort=name"
          assert_equal %w[algerian], json[:data].map { |c| c[:slug] }

          get URI.parse(next_link).request_uri, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          assert_equal %w[french], json[:data].map { |c| c[:slug] }
        end

        test "paging links omit sort when the request did not send it" do
          get "/api/v1/countries?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_not_includes json[:links][:next], "sort="
        end

        test "the unknown country is never listed" do
          ::Books::BookCountry.create!(book: books_books(:war_and_peace), country: books_countries(:unknown))

          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_not_includes json[:data].map { |c| c[:slug] }, "unknown"
        end

        test "an unknown sort is a 400 naming sort" do
          get "/api/v1/countries?sort=popularity", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
          assert_includes json[:detail], "sort"
        end

        test "with no primary configuration data is empty" do
          ::Books::RankingConfiguration.update_all(primary: false)

          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "page=0 is a 400" do
          get "/api/v1/countries?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
        end

        test "without a token it is a 401" do
          get "/api/v1/countries"
          assert_api_conform(status: 401)
          assert_response :unauthorized
        end

        test "a token without books:read is a 403" do
          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)
          assert_response :forbidden
        end
      end
    end
  end
end
