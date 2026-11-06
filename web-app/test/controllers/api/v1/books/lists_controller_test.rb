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

        test "index puts a list with no weight yet last, with a null weight" do
          # Admin attaches a list with only a list_id; its weight is nil until
          # the next refresh. It must not sort ahead of the heaviest lists.
          just_attached = create_list("Just attached", weight: nil)

          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@heavy.id, @mid_a.id, @mid_b.id, just_attached.id], json[:data].map { |row| row[:id] }
          assert_nil json[:data].last[:weight]
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

        # --- sort and q ----------------------------------------------------------

        test "sort=newest orders by activation date, newest first" do
          @heavy.update_columns(activated_at: Time.utc(2024, 1, 1))
          @mid_a.update_columns(activated_at: Time.utc(2023, 1, 1))
          @mid_b.update_columns(activated_at: Time.utc(2025, 1, 1))

          get "/api/v1/lists?sort=newest", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@mid_b.id, @heavy.id, @mid_a.id], json[:data].map { |row| row[:id] }
          assert_equal [50, 90, 50], json[:data].map { |row| row[:weight] }
        end

        test "sort=weight is the default order" do
          get "/api/v1/lists?sort=weight", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
        end

        test "q narrows to lists whose name, source or url contains it, case-insensitively" do
          @mid_b.update_columns(source: "Reading Circle")

          {"HEAVY" => [@heavy], "circle" => [@mid_b], "EXAMPLE.com/mid-a" => [@mid_a],
           "  mid  " => [@mid_a, @mid_b], "nothing matches this" => []}.each do |q, expected|
            get "/api/v1/lists", params: {q: q}, headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 200)

            assert_equal expected.map(&:id), json[:data].map { |row| row[:id] }, q
            assert_equal expected.size, json[:meta][:total_count], q
          end
        end

        test "q does not reach lists off the configuration" do
          get "/api/v1/lists", params: {q: "Year only"}, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [], json[:data]
        end

        test "sort and q ride on the paging links, and under a configuration the links stay nested" do
          @heavy.update_columns(activated_at: Time.utc(2024, 1, 1))
          @mid_a.update_columns(activated_at: Time.utc(2023, 1, 1))
          @mid_b.update_columns(activated_at: Time.utc(2025, 1, 1))

          [["/api/v1/lists", "/api/v1/lists"],
            ["/api/v1/ranking_configurations/#{@primary.id}/lists", "/api/v1/ranking_configurations/#{@primary.id}/lists"]].each do |request_path, link_path|
            get request_path, params: {sort: "newest", q: "mid", per_page: 1}, headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 200)

            assert_equal [@mid_b.id], json[:data].map { |row| row[:id] }
            assert_equal 2, json[:meta][:total_count]
            nxt = URI.parse(json[:links][:next])
            assert_equal link_path, nxt.path
            assert_equal({"sort" => "newest", "q" => "mid", "page" => "2", "per_page" => "1"}, Rack::Utils.parse_query(nxt.query))
            assert_equal "newest", Rack::Utils.parse_query(URI.parse(json[:links][:self]).query)["sort"]

            get json[:links][:next], headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 200)

            assert_equal [@mid_a.id], json[:data].map { |row| row[:id] }
            prev = URI.parse(json[:links][:prev])
            assert_equal link_path, prev.path
            assert_equal "newest", Rack::Utils.parse_query(prev.query)["sort"]
            assert_equal "mid", Rack::Utils.parse_query(prev.query)["q"]
          end
        end

        test "an unknown sort is a 400 naming sort" do
          get "/api/v1/lists?sort=oldest", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "invalid_parameter", json[:code]
          assert_equal "sort must be one of weight, newest", json[:detail]
        end

        test "a blank q is a 400 naming q" do
          ["/api/v1/lists?q=", "/api/v1/lists?q=%20", "/api/v1/ranking_configurations/#{@primary.id}/lists?q=%20%20"].each do |path|
            get path, headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 400)

            assert_response :bad_request, path
            assert_equal "invalid_parameter", json[:code]
            assert_equal "q must not be blank", json[:detail]
          end
        end

        test "an array q is a 400" do
          get "/api/v1/lists?q[]=war", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "q must be a single value", json[:detail]
        end

        test "q over 200 characters is a 400" do
          get "/api/v1/lists", params: {q: "a" * 201}, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
          assert_equal "q must be at most 200 characters", json[:detail]

          get "/api/v1/lists", params: {q: "a" * 200}, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
        end

        test "no sort and no q returns exactly today's body" do
          get "/api/v1/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=50", json[:links][:self]
          json[:links].each_value { |link| refute_match(/sort=|q=/, link.to_s) }
        end

        test "an unknown configuration is a 404 even when sort is bad" do
          get "/api/v1/ranking_configurations/999999999/lists?sort=bogus&q=", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_equal "not_found", json[:code]
        end

        # --- nested under a ranking configuration --------------------------------

        test "the nested index on the primary returns the same rows with nested links" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal [90, 50, 50], json[:data].map { |row| row[:weight] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=50", json[:links][:self]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=50", json[:links][:first]
        end

        test "the nested index reads the named configuration, and weight is relative to it" do
          RankedList.create!(list: @heavy, ranking_configuration: @year, weight: 5)

          get "/api/v1/ranking_configurations/#{@year.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@year_only.id, @heavy.id], json[:data].map { |row| row[:id] }
          assert_equal [70, 5], json[:data].map { |row| row[:weight] }
          assert_equal 2, json[:meta][:total_count]
        end

        test "the nested total_count equals the configuration's list_count, which links here" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          total = json[:meta][:total_count]

          get "/api/v1/ranking_configurations/#{@primary.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal 3, total
          assert_equal total, json[:data][:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists", json[:data][:lists_api_url]
        end

        test "the nested index paginates with nested links" do
          get "/api/v1/ranking_configurations/#{@primary.id}/lists?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@primary.id}/lists?page=1&per_page=2", json[:links][:prev]
        end

        test "the nested index never serves a user-owned, archived or author configuration" do
          archived = ranking_configurations(:books_inherited)
          archived.update!(archived: true)

          [archived, ranking_configurations(:books_user), ranking_configurations(:books_user_shared),
            ranking_configurations(:books_authors_global)].each do |configuration|
            get "/api/v1/ranking_configurations/#{configuration.id}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_response :not_found, configuration.name
            assert_equal "not_found", json[:code]
          end
        end

        test "a missing parent is a 404 even when the page is also bad" do
          get "/api/v1/ranking_configurations/999999999/lists?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_response :not_found
          assert_equal "not_found", json[:code]
          assert_equal "No ranking configuration at that address", json[:detail]
        end

        test "a non-numeric configuration id is a routing 404" do
          get "/api/v1/ranking_configurations/primary/lists", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "the bare index ignores a ranking_configuration_id query parameter" do
          get "/api/v1/lists?ranking_configuration_id=#{@year.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          # Response-only: the parameter is deliberately undocumented, and
          # request validation would reject it -- which is the point.
          assert_api_response_conform(status: 200)

          assert_equal [@heavy.id, @mid_a.id, @mid_b.id], json[:data].map { |row| row[:id] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/lists?page=1&per_page=50", json[:links][:self]
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
