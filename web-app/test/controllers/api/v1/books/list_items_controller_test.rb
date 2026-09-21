require "test_helper"

module Api
  module V1
    module Books
      class ListItemsControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @got = books_books(:got)
          @mice = books_books(:of_mice_and_men)
          @list = ::Books::List.create!(name: "Ordered and not", status: :active)
          # Two positioned rows created out of order, two unpositioned rows
          # (served after them, by id), a row with no listable and a row whose
          # listable is a movie -- the last two are neither counted nor served.
          # The movie row is written without validation, which is exactly how
          # an importer would leave it.
          @second = ListItem.create!(list: @list, listable: @crime, position: 2)
          @first = ListItem.create!(list: @list, listable: @war_and_peace, position: 1)
          @unpositioned_a = ListItem.create!(list: @list, listable: @got, position: nil)
          @unpositioned_b = ListItem.create!(list: @list, listable: @mice, position: nil)
          ListItem.create!(list: @list, listable: nil, metadata: {title: "Unresolved"})
          ListItem.new(list: @list, listable: movies_movies(:matrix), position: 3).save!(validate: false)
          # Ranked on the primary: war_and_peace and crime; the other two are unranked.
          RankedItem.create!(item: @war_and_peace, ranking_configuration: @primary, rank: 1, score: 100)
          RankedItem.create!(item: @crime, ranking_configuration: @primary, rank: 2, score: 90)
          @approved = ::Books::List.create!(name: "Approved only", status: :approved)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "index orders by position with nulls last and id as the tiebreak" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[war-and-peace crime-and-punishment a-game-of-thrones of-mice-and-men], json[:data].map { |row| row[:book][:slug] }
          assert_equal [1, 2, nil, nil], json[:data].map { |row| row[:position] }
          assert_equal({page: 1, per_page: 50, total_count: 4, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items?page=1&per_page=50", json[:links][:self]
        end

        test "rows are {position, book} with the compact book and its rank on the primary" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          row = json[:data].first
          assert_equal %i[position book], row.keys
          assert_equal %i[id slug title subtitle first_published_year rank authors cover_url url api_url], row[:book].keys
          assert_equal [1, 2, nil, nil], json[:data].map { |r| r[:book][:rank] }, "rank is the primary's and null for an unranked book"
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace", row[:book][:api_url]
        end

        test "a row with no listable and a row whose listable is not a book are neither counted nor served" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 4, json[:meta][:total_count]
          assert_equal 4, json[:data].size
          refute_includes json[:data].map { |row| row[:position] }, 3, "the movie row"
        end

        test "a list's item_count on /lists/{id} equals this endpoint's total_count" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          total = json[:meta][:total_count]

          get "/api/v1/lists/#{@list.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 4, total
          assert_equal total, json[:data][:item_count]
        end

        test "index paginates with the list's links" do
          get "/api/v1/lists/#{@list.id}/items?page=2&per_page=3", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal ["of-mice-and-men"], json[:data].map { |row| row[:book][:slug] }
          assert_equal({page: 2, per_page: 3, total_count: 4, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@list.id}/items?page=1&per_page=3", json[:links][:prev]
        end

        test "rank lookups are batched: one ranked_items query whatever the page size" do
          get "/api/v1/lists/#{@list.id}/items?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/lists/#{@list.id}/items?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          four = capture_sql { get "/api/v1/lists/#{@list.id}/items?per_page=4", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, four.size, "query count grew with page size:\n#{four.join("\n")}"
          assert_equal 1, four.count { |sql| sql.include?("ranked_items") }, four.join("\n")
        end

        test "a page past the end is an empty 200 and runs no rank lookup" do
          get "/api/v1/lists/#{@list.id}/items?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/lists/#{@list.id}/items?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 4, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("ranked_items") }, "an empty page must not look ranks up:\n#{queries.join("\n")}"
        end

        test "with no primary ranking configuration every rank is null" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [nil, nil, nil, nil], json[:data].map { |row| row[:book][:rank] }
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/lists/#{@list.id}/items?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
        end

        test "a list that is not active is a 404 problem" do
          get "/api/v1/lists/#{@approved.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No list at that address", json[:detail]
        end

        test "an unknown list is a 404 even when the page is also bad" do
          get "/api/v1/lists/999999999/items?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
        end

        test "a non-numeric list id is a routing 404" do
          get "/api/v1/lists/best/items", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/lists/#{@list.id}/items"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "insufficient_scope", json[:code]
        end
      end
    end
  end
end
