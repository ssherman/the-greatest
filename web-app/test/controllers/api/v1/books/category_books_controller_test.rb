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
      end
    end
  end
end
