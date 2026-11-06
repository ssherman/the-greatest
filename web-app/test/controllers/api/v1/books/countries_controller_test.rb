require "test_helper"

module Api
  module V1
    module Books
      class CountriesControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "returns countries with ranked books, most first, with slug, name, book_count and url" do
          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[french japanese], json[:data].map { |c| c[:slug] }
          french = json[:data].first
          assert_equal %i[slug name book_count url], french.keys
          assert_equal "French", french[:name]
          assert_equal 2, french[:book_count]
          assert_equal 1, json[:data].last[:book_count]
          assert_equal "https://dev-new.thegreatestbooks.org#{::Books::FilterPath.call(countries: [books_countries(:french)])}", french[:url]
          assert_equal 2, json[:meta][:total_count]
        end

        test "a country whose books are all unranked is not listed" do
          assert_not_includes json_slugs, "algerian"
        end

        test "sort=name orders by name" do
          get "/api/v1/countries?sort=name", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          expected = ::Books::BrowseQuery.countries(ranking_configuration: @rc, sort: "name").map(&:name)
          assert_equal expected, json[:data].map { |c| c[:name] }
          assert_equal expected.sort, expected
        end

        test "sort rides on the paging links, and following next continues the same list" do
          get "/api/v1/countries?sort=name&per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          next_link = json[:links][:next]
          assert_includes next_link, "sort=name"
          assert_equal %w[french], json[:data].map { |c| c[:slug] }

          get URI.parse(next_link).request_uri, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          assert_equal %w[japanese], json[:data].map { |c| c[:slug] }
        end

        test "paging links omit sort when the request did not send it" do
          get "/api/v1/countries?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_not_includes json[:links][:next], "sort="
        end

        test "the unknown country is never listed" do
          ::Books::BookCountry.create!(book: books_books(:war_and_peace), country: books_countries(:unknown))

          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_not_includes json_slugs, "unknown"
        end

        test "an unknown sort is a 400 naming sort" do
          get "/api/v1/countries?sort=popularity", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_includes response.body, "sort must be one of book_count, name"
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

        private

        def json_slugs
          get "/api/v1/countries", headers: bearer(ApiTokenSecrets::MEMBER)
          json[:data].map { |c| c[:slug] }
        end
      end
    end
  end
end
