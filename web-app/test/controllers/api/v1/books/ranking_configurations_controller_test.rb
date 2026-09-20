require "test_helper"

module Api
  module V1
    module Books
      class RankingConfigurationsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @inherited = ranking_configurations(:books_inherited)
          @year_2025 = ranking_configurations(:books_year_2025)
          # Two ranked books and one unranked RankedItem row on the primary: item_count
          # must count the ranked ones only.
          RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @primary, rank: 1, score: 100)
          RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @primary, rank: 2, score: 90)
          RankedItem.create!(item: books_books(:got), ranking_configuration: @primary, rank: nil, score: 0)
          # The fixture ranked list points at an approved (not active) list; activate
          # it so list_count sees one, and add a second RankedList whose list stays
          # approved so the status predicate is exercised.
          lists(:books_list).update!(status: :active)
          RankedList.create!(list: lists(:approved_list), ranking_configuration: @primary, weight: 5)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists the global book configurations, primary first" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal @primary.id, json[:data].first[:id]
          rest = [@inherited, @year_2025].map(&:id).sort.reverse
          assert_equal rest, json[:data].drop(1).map { |row| row[:id] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the documented shape with batched counts" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          primary = json[:data].first
          assert_equal %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url], primary.keys
          assert_equal "books", primary[:kind]
          assert_equal true, primary[:primary]
          assert_equal 2, primary[:item_count], "item_count must exclude the RankedItem with a nil rank"
          assert_equal 1, primary[:list_count], "list_count must exclude the ranked list whose list is not active"
          assert_equal "2025-07-09T23:38:50Z", primary[:published_at]
          assert_equal "https://dev-new.thegreatestbooks.org/rc/#{@primary.id}", primary[:url]

          year = json[:data].find { |row| row[:id] == @year_2025.id }
          assert_equal 2025, year[:year]
          assert_equal 0, year[:item_count]
          assert_equal 0, year[:list_count]
        end

        test "index excludes user-owned, archived and author configurations" do
          @inherited.update!(archived: true)

          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:id] }
          refute_includes ids, @inherited.id, "archived"
          refute_includes ids, ranking_configurations(:books_user).id, "private user-owned"
          refute_includes ids, ranking_configurations(:books_user_shared).id, "shared user-owned"
          refute_includes ids, ranking_configurations(:books_authors_global).id, "authors configuration"
          assert_equal 2, json[:meta][:total_count]
        end

        test "index paginates" do
          get "/api/v1/ranking_configurations?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 1, json[:data].size
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200 and runs no count lookups" do
          get "/api/v1/ranking_configurations?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/ranking_configurations?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("ranked_items") || sql.include?("ranked_lists") },
            "an empty page must not run the count lookups:\n#{queries.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/ranking_configurations?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "invalid_parameter", json[:code]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/ranking_configurations?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/ranking_configurations?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/ranking_configurations?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders one configuration with its counts" do
          get "/api/v1/ranking_configurations/#{@primary.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal @primary.id, json[:data][:id]
          assert_equal 2, json[:data][:item_count]
          assert_equal 1, json[:data][:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/books", json[:data][:books_api_url]
        end

        test "show of a non-primary configuration" do
          get "/api/v1/ranking_configurations/#{@year_2025.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal false, json[:data][:primary]
          assert_equal 2025, json[:data][:year]
        end

        test "show of an unknown id is a 404 problem" do
          get "/api/v1/ranking_configurations/999999999", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "show never serves a user-owned, archived or author configuration" do
          @inherited.update!(archived: true)

          [@inherited, ranking_configurations(:books_user), ranking_configurations(:books_user_shared),
            ranking_configurations(:books_authors_global)].each do |configuration|
            get "/api/v1/ranking_configurations/#{configuration.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_response :not_found, configuration.name
            assert_equal "not_found", json[:code]
          end
        end

        test "a non-numeric id is a routing 404" do
          get "/api/v1/ranking_configurations/primary", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations ---------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/ranking_configurations"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers and is not cacheable" do
          get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end
      end
    end
  end
end
