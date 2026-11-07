require "test_helper"

module Api
  module V1
    module Books
      class CategorySearchesControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)
          @original_minimum = Rails.configuration.x.books.browse_min_category_books
          Rails.configuration.x.books.browse_min_category_books = 1
        end

        teardown do
          Rails.configuration.x.books.browse_min_category_books = @original_minimum
        end

        def json = response.parsed_body.deep_symbolize_keys

        def search(params = {q: "novel"}) = get("/api/v1/search/categories", params: params, headers: bearer(ApiTokenSecrets::MEMBER))

        test "returns name matches before alias-only matches, with ranked book_count" do
          # Classics matches "novel" only through an alias; Novels matches by name.
          categories(:books_classics_genre).update!(alternative_names: ["Novels of old"])

          search
          assert_api_conform(status: 200)

          assert_equal %w[novels classics], json[:data].map { |c| c[:slug] }
          # got also carries novels but is unranked; clash carries classics and is unranked.
          assert_equal [2, 1], json[:data].map { |c| c[:book_count] }
          assert_equal "genre", json[:data].first[:category_type]
          assert_nil json[:data].first[:parent]
          assert_equal({page: 1, per_page: 50, total_count: 2, total_pages: 1}, json[:meta])
        end

        test "type orders that type first" do
          ::Books::Category.create!(name: "Frontier Tales", category_type: :genre).tap do |c|
            CategoryItem.create!(category: c, item: books_books(:war_and_peace))
          end
          ::Books::Category.create!(name: "Frontier Studies", category_type: :subject).tap do |c|
            CategoryItem.create!(category: c, item: books_books(:war_and_peace))
          end

          search(q: "frontier")
          assert_api_conform(status: 200)
          assert_equal %w[genre subject], json[:data].map { |c| c[:category_type] }

          search(q: "frontier", type: "subject")
          assert_api_conform(status: 200)
          assert_equal %w[subject genre], json[:data].map { |c| c[:category_type] }
        end

        test "links carry q and type" do
          search(q: "novel", type: "subject")
          assert_api_conform(status: 200)

          assert_includes json[:links][:self], "/api/v1/search/categories?"
          assert_includes json[:links][:self], "q=novel"
          assert_includes json[:links][:self], "type=subject"
        end

        test "links omit type when the request did not send one" do
          search
          refute_includes json[:links][:self], "type="
        end

        test "more than 60 matches cap total_count at 60" do
          ids = 61.times.map { |i| ::Books::Category.create!(name: "Bulk Match #{i}", category_type: :genre).id }
          capped = ::Books::Category.where(id: ids).select("categories.*, 1 AS ranked_count").order(:id).limit(::Books::BrowseQuery::SEARCH_LIMIT)
          ::Books::BrowseQuery.stubs(:search).returns(capped)

          search(q: "bulk", per_page: 50)
          assert_api_conform(status: 200)
          assert_equal [60, 2], [json[:meta][:total_count], json[:meta][:total_pages]]
          assert_equal 50, json[:data].size

          search(q: "bulk", per_page: 50, page: 2)
          assert_api_conform(status: 200)
          assert_equal 10, json[:data].size
          assert_equal ids.first(60).last(10), json[:data].map { |c| c[:id] }
        end

        test "a 1-character q is a 400 naming q" do
          search(q: "n")
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "q must be at least 2 characters"], [json[:code], json[:detail]]
        end

        test "a 101-character q is a 400 naming q" do
          search(q: "n" * 101)
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "q must be at most 100 characters"], [json[:code], json[:detail]]
        end

        test "an array q is a 400 naming q" do
          get "/api/v1/search/categories?q[]=novel", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "q must be a single value"], [json[:code], json[:detail]]
        end

        test "a q containing a null byte is a 400 naming q" do
          get "/api/v1/search/categories?q=no%00vel", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "q must not contain a null byte"], [json[:code], json[:detail]]
        end

        test "a missing q is a 400 naming q" do
          get "/api/v1/search/categories", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "q is required"], [json[:code], json[:detail]]
        end

        test "an unknown type is a 400 naming type" do
          search(q: "novel", type: "settings")
          assert_api_response_conform(status: 400)
          assert_equal ["invalid_parameter", "type must be one of genre, audience, location, subject"], [json[:code], json[:detail]]
        end

        test "with no primary configuration the result is empty" do
          ::Books::RankingConfiguration.update_all(primary: false)

          search
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "a token without books:read is a 403" do
          get "/api/v1/search/categories?q=novel", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_response_conform(status: 403)
        end

        test "no token is a 401" do
          get "/api/v1/search/categories?q=novel"
          assert_api_response_conform(status: 401)
        end
      end
    end
  end
end
