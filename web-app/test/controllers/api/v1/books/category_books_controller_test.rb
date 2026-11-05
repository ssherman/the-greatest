require "test_helper"

module Api
  module V1
    module Books
      class CategoryBooksControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "returns only the category's ranked books in rank order with the books shape" do
          get "/api/v1/categories/novels/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          # got is in novels too but unranked; of_mice_and_men is ranked but not in novels.
          assert_equal %w[war-and-peace crime-and-punishment], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2], json[:data].map { |b| b[:rank] }
          assert_equal %i[api_url authors cover_url first_published_year id rank slug subtitle title url],
            json[:data].first.keys.sort
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/categories/novels/books?page=1&per_page=50", json[:links][:self]
          assert_equal 2, json[:meta][:total_count]
        end

        test "resolves a merged category's slug to the target's books" do
          target = categories(:books_novels_genre)
          source = ::Books::Category.create!(name: "Old Novels", slug: "old-novels", category_type: :genre)
          source.update_columns(deleted: true, merged_into_id: target.id)

          get "/api/v1/categories/old-novels/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[war-and-peace crime-and-punishment], json[:data].map { |b| b[:slug] }
          assert_includes json[:links][:self], "/api/v1/categories/novels/books"
        end

        test "an unknown slug is a 404" do
          get "/api/v1/categories/no-such-category/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          assert_response :not_found
        end

        test "a deleted, unmerged category is a 404" do
          get "/api/v1/categories/#{categories(:books_deleted_genre).slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          assert_response :not_found
        end

        test "page=0 is a 400" do
          get "/api/v1/categories/novels/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
          assert_response :bad_request
        end

        test "an unknown slug beats a bad page" do
          get "/api/v1/categories/no-such-category/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_response :not_found
        end

        test "country_id narrows the category to books that are also from that country" do
          # Unfiltered novels is war-and-peace + crime-and-punishment; only war-and-peace is French.
          get "/api/v1/categories/novels/books?country_id=french", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal 1, json[:meta][:total_count]
          assert_equal({country_id: "french"}, json[:meta][:filters])
        end

        test "a second category intersects with the path category, which stays out of meta.filters" do
          get "/api/v1/categories/novels/books?category_id=classics", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          # War and Peace is the only ranked book in both novels and classics.
          assert_equal %w[war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal({category_id: "classics"}, json[:meta][:filters])
        end

        test "the path category repeated in category_id changes nothing and is not echoed" do
          get "/api/v1/categories/novels/books?category_id=novels", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[war-and-peace crime-and-punishment], json[:data].map { |b| b[:slug] }
          assert_not json[:meta].key?(:filters)
        end

        test "a merged slug of the path category in category_id is the path category itself" do
          target = categories(:books_novels_genre)
          source = ::Books::Category.create!(name: "Old Novels", slug: "old-novels", category_type: :genre)
          source.update_columns(deleted: true, merged_into_id: target.id)

          get "/api/v1/categories/novels/books?category_id=old-novels", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[war-and-peace crime-and-punishment], json[:data].map { |b| b[:slug] }
          assert_not json[:meta].key?(:filters)
        end

        test "the path category plus six more category slugs is a 400" do
          get "/api/v1/categories/novels/books?category_id=a,b,c,d,e,f", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
          assert_includes json[:detail], "category_id"
        end

        test "the path category plus five more category slugs is within the limit" do
          get "/api/v1/categories/novels/books?category_id=classics,fiction,nonfiction,politics,americana", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_response :ok
        end

        test "an unknown country_id is a 404 naming the parameter" do
          get "/api/v1/categories/novels/books?country_id=atlantis", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_equal "not_found", json[:code]
          assert_includes json[:detail], "country_id"
        end

        test "links.next carries the filter, and following it gives page 2 of the same filtered list" do
          year = ranking_configurations(:books_year_2025)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: year, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:got), ranking_configuration: year, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: year, rank: 3, score: 80)

          get "/api/v1/ranking_configurations/#{year.id}/categories/novels/books?country_id=french&per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          assert_equal %w[a-game-of-thrones], json[:data].map { |b| b[:slug] }
          assert_equal 2, json[:meta][:total_count]

          get json[:links][:next], headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          assert_equal %w[war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal({country_id: "french"}, json[:meta][:filters])
        end

        test "the nested path reads that configuration, ranks relative to it, and links nested on the canonical slug" do
          year = ranking_configurations(:books_year_2025)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: year, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:got), ranking_configuration: year, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: year, rank: 3, score: 80)
          target = categories(:books_novels_genre)
          source = ::Books::Category.create!(name: "Old Novels", slug: "old-novels", category_type: :genre)
          source.update_columns(deleted: true, merged_into_id: target.id)

          get "/api/v1/ranking_configurations/#{year.id}/categories/old-novels/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          # The primary ranks war-and-peace first and has no game of thrones; this one reverses it.
          assert_equal %w[crime-and-punishment a-game-of-thrones war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |b| b[:rank] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{year.id}/categories/novels/books?page=1&per_page=50", json[:links][:self]
        end

        test "the nested path applies filters to that configuration" do
          year = ranking_configurations(:books_year_2025)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: year, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:got), ranking_configuration: year, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: year, rank: 3, score: 80)

          get "/api/v1/ranking_configurations/#{year.id}/categories/novels/books?country_id=french", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[a-game-of-thrones war-and-peace], json[:data].map { |b| b[:slug] }
          assert_equal [2, 3], json[:data].map { |b| b[:rank] }
          assert_equal({country_id: "french"}, json[:meta][:filters])
          assert_includes json[:links][:self], "/ranking_configurations/#{year.id}/categories/novels/books?"
          assert_includes json[:links][:self], "country_id=french"
        end

        test "the nested path never serves an archived, user-owned or unknown configuration" do
          archived = ranking_configurations(:books_inherited)
          archived.update!(archived: true)

          [archived.id, ranking_configurations(:books_user).id, ranking_configurations(:books_authors_global).id, 999_999_999].each do |id|
            get "/api/v1/ranking_configurations/#{id}/categories/novels/books", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_equal "not_found", json[:code], id
          end
        end

        test "a missing configuration beats an unknown category and a bad page" do
          get "/api/v1/ranking_configurations/999999999/categories/no-such-category/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_equal "No ranking configuration at that address", json[:detail]
        end

        test "the bare path ignores a ranking_configuration_id query parameter" do
          year = ranking_configurations(:books_year_2025)
          RankedItem.create!(item: books_books(:got), ranking_configuration: year, rank: 1, score: 100)

          get "/api/v1/categories/novels/books?ranking_configuration_id=#{year.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          # Response-only: the parameter is deliberately undocumented.
          assert_api_response_conform(status: 200)

          assert_equal %w[war-and-peace crime-and-punishment], json[:data].map { |b| b[:slug] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/categories/novels/books?page=1&per_page=50", json[:links][:self]
        end
      end
    end
  end
end
