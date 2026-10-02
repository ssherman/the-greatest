require "test_helper"

module Api
  module V1
    module Books
      class BookListsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @book = books_books(:war_and_peace)
          # Created in an order that differs from the weight order, so the two
          # orderings (weighted first on the primary; by id with no primary)
          # are distinguishable. Two weighted on the primary, one active on no
          # configuration, one active on the year configuration only, one
          # approved-not-active, and one the book is not on at all.
          @weighted_low = list_with(@book, "Weighted low", position: nil, weight: 20)
          @weighted_high = list_with(@book, "Weighted high", position: 3, weight: 80)
          @unweighted = list_with(@book, "Unweighted", position: 7, weight: nil)
          @year_only = list_with(@book, "Year only", position: 1, weight: nil)
          RankedList.create!(list: @year_only, ranking_configuration: ranking_configurations(:books_year_2025), weight: 60)
          @approved = list_with(@book, "Approved", position: 1, weight: 50, status: :approved)
          @other = list_with(books_books(:crime_and_punishment), "Another book's list", position: 1, weight: 99)
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "index lists the active lists the book is on, weighted first, with its position on each" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal [@weighted_high.id, @weighted_low.id, @unweighted.id, @year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal [80, 20, nil, nil], json[:data].map { |row| row[:list][:weight] }, "weight is the primary's; null off it, ordered after the weighted rows"
          assert_equal [3, nil, 7, 1], json[:data].map { |row| row[:position] }
          assert_equal({page: 1, per_page: 50, total_count: 4, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace/lists?page=1&per_page=50", json[:links][:self]
        end

        test "rows are {position, list} with the compact list and a batched item_count" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          row = json[:data].first
          assert_equal %i[position list], row.keys
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url], row[:list].keys
          assert_equal [1, 1, 1, 1], json[:data].map { |r| r[:list][:item_count] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@weighted_high.id}/items", row[:list][:items_api_url]
        end

        test "index excludes a list that is not active and lists the book is not on" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:list][:id] }
          refute_includes ids, @approved.id, "approved, not active"
          refute_includes ids, @other.id, "another book's list"
        end

        test "index paginates" do
          get "/api/v1/books/#{@book.slug}/lists?page=2&per_page=3", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal({page: 2, per_page: 3, total_count: 4, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace/lists?page=1&per_page=3", json[:links][:prev]
        end

        test "with no primary ranking configuration every weight is null and the order is by list id" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@weighted_low.id, @weighted_high.id, @unweighted.id, @year_only.id], json[:data].map { |row| row[:list][:id] }
          assert_equal [nil, nil, nil, nil], json[:data].map { |row| row[:list][:weight] }
          assert_equal 4, json[:meta][:total_count]
        end

        test "a book on no list is an empty 200" do
          get "/api/v1/books/#{books_books(:got).slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/books/#{@book.slug}/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/books/#{@book.slug}/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          four = capture_sql { get "/api/v1/books/#{@book.slug}/lists?per_page=4", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, four.size, "query count grew with page size:\n#{four.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/books/#{@book.slug}/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
        end

        test "an unknown slug is a 404 problem" do
          get "/api/v1/books/no-such-book/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No book at that address", json[:detail]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "a missing book is a 404 even when the page is also bad" do
          get "/api/v1/books/no-such-book/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
        end

        test "the lookup does not fall back to a primary key" do
          get "/api/v1/books/#{@book.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/books/#{@book.slug}/lists"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "insufficient_scope", json[:code]
        end

        private

        def list_with(book, name, position:, weight:, status: :active)
          list = ::Books::List.create!(name: name, status: status)
          ListItem.create!(list: list, listable: book, position: position)
          RankedList.create!(list: list, ranking_configuration: @primary, weight: weight) if weight
          list
        end
      end
    end
  end
end
