require "test_helper"

module Api
  module V1
    module Books
      class CategoriesControllerTest < ActionDispatch::IntegrationTest
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

        def merged_category(slug: "old-novels")
          target = categories(:books_novels_genre)
          source = ::Books::Category.create!(name: "Old Novels", slug: slug, category_type: :genre)
          source.update_columns(deleted: true, merged_into_id: target.id)
          source
        end

        # --- index ---------------------------------------------------------------

        test "index with type=subject returns BrowseQuery's categories in order" do
          get "/api/v1/categories?type=subject", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          expected = ::Books::BrowseQuery.categories(ranking_configuration: @rc, type: "subject", sort: nil).map(&:id)
          assert_response :success
          assert_not_empty expected
          assert_equal expected, json[:data].map { |c| c[:id] }
          assert_equal "subject", json[:data].first[:category_type]
        end

        test "index defaults to the first type and carries book_count and parent" do
          get "/api/v1/categories", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          novels = json[:data].find { |c| c[:slug] == "novels" }
          assert_equal 2, novels[:book_count]
          assert_nil novels[:parent]
          assert_equal %w[genre], json[:data].map { |c| c[:category_type] }.uniq
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/categories?page=1&per_page=50", json[:links][:self]
        end

        test "type=location returns locations" do
          get "/api/v1/categories?type=location", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[france], json[:data].map { |c| c[:slug] }
          assert_equal %w[location], json[:data].map { |c| c[:category_type] }.uniq
        end

        test "type=settings is a 400 naming the accepted types" do
          get "/api/v1/categories?type=settings", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_includes response.body, "type must be one of genre, audience, location, subject"
        end

        test "an unknown sort is a 400" do
          get "/api/v1/categories?sort=popularity", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_includes response.body, "sort must be one of book_count, name"
        end

        test "sort=name orders by name" do
          get "/api/v1/categories?sort=name", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          names = json[:data].map { |c| c[:name] }
          assert_operator names.size, :>, 1
          assert_equal names.sort, names
        end

        test "index is empty without a primary configuration" do
          ::Books::RankingConfiguration.update_all(primary: false)

          get "/api/v1/categories", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index page=0 is a 400" do
          get "/api/v1/categories?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)
          assert_response :bad_request
        end

        # --- show ----------------------------------------------------------------

        test "show by current slug counts ranked books carrying the category" do
          get "/api/v1/categories/novels", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal categories(:books_novels_genre).id, json[:data][:id]
          assert_equal "genre", json[:data][:category_type]
          # got also carries novels but is unranked.
          assert_equal 2, json[:data][:book_count]
        end

        test "show by a friendly_id history slug returns the live category" do
          category = ::Books::Category.create!(name: "Washington DC", category_type: :location)
          old_slug = category.slug
          category.update!(name: "Washington, D.C.")
          assert_not_equal old_slug, category.reload.slug

          get "/api/v1/categories/#{old_slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal category.id, json[:data][:id]
        end

        test "show by a merged category's slug returns the target" do
          source = merged_category

          get "/api/v1/categories/#{source.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal categories(:books_novels_genre).id, json[:data][:id]
        end

        test "show of a deleted, unmerged category is a 404" do
          get "/api/v1/categories/#{categories(:books_deleted_genre).slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "show of an unknown slug is a 404" do
          get "/api/v1/categories/no-such-category", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "show accepts any active books category, a theme included" do
          theme = ::Books::Category.create!(name: "Redemption", slug: "redemption", category_type: :theme)

          get "/api/v1/categories/redemption", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal theme.id, json[:data][:id]
          assert_equal "theme", json[:data][:category_type]
          assert_equal 0, json[:data][:book_count]
        end

        test "show does not resolve another domain's category" do
          get "/api/v1/categories/#{categories(:music_rock_genre).slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          assert_response :not_found
        end

        test "requires the books:read scope" do
          get "/api/v1/categories", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)
          assert_response :forbidden
        end
      end
    end
  end
end
