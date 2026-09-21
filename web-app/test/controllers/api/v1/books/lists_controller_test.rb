require "test_helper"

module Api
  module V1
    module Books
      class ListsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @primary = ranking_configurations(:books_global)
          @year = ranking_configurations(:books_year_2025)
          # No Books::List fixture is active, and the ones that carry items point
          # at a book that does not exist or at a movie, so every list here is
          # created rather than reshaped from a fixture other suites depend on.
          # On the primary: three active (90, 50, 50 -- the tie breaks on id) and
          # one approved-not-active; one active on the year configuration only;
          # one active on no configuration at all.
          @heavy = create_list("Heavy", weight: 90)
          @mid_a = create_list("Mid A", weight: 50)
          @mid_b = create_list("Mid B", weight: 50)
          @approved = create_list("Approved", weight: 99, status: :approved)
          @year_only = create_list("Year only", weight: 70, ranking_configuration: @year)
          @orphan = ::Books::List.create!(name: "On no configuration", status: :active)
          # Heavy has two served items and one row with no listable, which is
          # neither counted here nor served by /items. Positions include a null:
          # 38k of the 56k real items have none.
          ListItem.create!(list: @heavy, listable: books_books(:war_and_peace), position: 1)
          ListItem.create!(list: @heavy, listable: books_books(:crime_and_punishment), position: nil)
          ListItem.create!(list: @heavy, listable: nil, metadata: {title: "Unresolved"})
          ListItem.create!(list: @mid_a, listable: books_books(:crime_and_punishment), position: 1)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists the primary's active lists heaviest first, id as the tiebreak, with meta and links" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal [90, 50, 50], json[:data].map { |row| row[:weight] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the compact shape with batched item counts" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          heavy = json[:data].first
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url], heavy.keys
          assert_equal 2, heavy[:item_count], "item_count must exclude the row with no listable"
          assert_equal "https://dev-new.thegreatestbooks.org/lists/#{@heavy.id}", heavy[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@heavy.id}", heavy[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists/#{@heavy.id}/items", heavy[:items_api_url]
          assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, heavy[:activated_at])
          assert_equal [2, 1, 0], json[:data].map { |row| row[:item_count] }
        end

        test "index excludes active lists off the configuration and inactive lists on it" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          ids = json[:data].map { |row| row[:id] }
          refute_includes ids, @approved.id, "approved, not active, though weighted on the primary"
          refute_includes ids, @year_only.id, "active, but weighted on the year configuration only"
          refute_includes ids, @orphan.id, "active, on no configuration"
        end

        test "index paginates" do
          get "/api/v1/lists?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200 and runs no item-count lookup" do
          get "/api/v1/lists?page=9", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up
          queries = capture_sql { get "/api/v1/lists?page=9", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
          refute queries.any? { |sql| sql.include?("list_items") },
            "an empty page must not count items:\n#{queries.join("\n")}"
        end

        test "invalid pagination parameters are a 400 problem" do
          get "/api/v1/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "invalid_parameter", json[:code]
        end

        test "index with no primary ranking configuration is an empty 200" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index query count does not grow with page size" do
          get "/api/v1/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/lists?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/lists?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full list with its weight on the primary" do
          get "/api/v1/lists/#{@heavy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal %i[id name source year_published yearly_award number_of_voters item_count weight activated_at url api_url items_api_url description source_url], json[:data].keys
          assert_equal @heavy.id, json[:data][:id]
          assert_equal 90, json[:data][:weight]
          assert_equal 2, json[:data][:item_count]
          assert_equal "About Heavy", json[:data][:description]
          assert_equal "https://example.com/heavy", json[:data][:source_url]
        end

        test "show answers for an active list off the primary with a null weight" do
          [@year_only, @orphan].each do |list|
            get "/api/v1/lists/#{list.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 200)

            assert_response :success, list.name
            assert json[:data].key?(:weight), list.name
            assert_nil json[:data][:weight]
          end
        end

        test "show with no primary ranking configuration has a null weight" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/lists/#{@heavy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_nil json[:data][:weight]
        end

        test "show of a list that is not active is a 404 problem" do
          get "/api/v1/lists/#{@approved.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_equal "No list at that address", json[:detail]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "show of an unknown id is a 404 problem" do
          get "/api/v1/lists/999999999", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_equal "not_found", json[:code]
        end

        test "show never serves a list of another medium" do
          get "/api/v1/lists/#{lists(:music_albums_list).id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "a non-numeric id is a routing 404" do
          get "/api/v1/lists/best", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations ---------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/lists"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers and is not cacheable" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end

        private

        def create_list(name, weight:, ranking_configuration: @primary, status: :active)
          list = ::Books::List.create!(
            name: name, source: "#{name} Source", url: "https://example.com/#{name.parameterize}",
            description: "About #{name}", year_published: 2020, number_of_voters: 100, yearly_award: false, status: status
          )
          RankedList.create!(list: list, ranking_configuration: ranking_configuration, weight: weight)
          list
        end
      end
    end
  end
end
