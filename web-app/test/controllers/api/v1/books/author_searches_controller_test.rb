require "test_helper"

module Api
  module V1
    module Books
      class AuthorSearchesControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @tolstoy = books_authors(:tolstoy)
          @king = books_authors(:king)
          @garnett = books_authors(:garnett)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def hits(*records) = records.map { |record| {id: record.id.to_s, score: 1.0, source: {}} }

        def search(params = {q: "tolstoy"}) = get("/api/v1/search/authors", params: params, headers: bearer(ApiTokenSecrets::MEMBER))

        test "returns the matches in hit order, in the Author shape, with the primary author rank" do
          RankedItem.create!(item: @tolstoy, ranking_configuration: ranking_configurations(:books_authors_global), rank: 4, score: 1)
          ::Search::Books::Search::AuthorGeneral.stubs(:call).returns(hits(@garnett, @tolstoy, @king))

          search
          assert_api_conform(status: 200)

          assert_equal [@garnett.id, @tolstoy.id, @king.id], json[:data].map { |a| a[:id] }
          assert_equal [nil, 4, nil], json[:data].map { |a| a[:rank] }
          assert_equal "leo-tolstoy", json[:data][1][:slug]
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
        end

        test "links carry q and the index is asked for at most 100 hits" do
          ::Search::Books::Search::AuthorGeneral.expects(:call).with("tolstoy", size: 100).returns(hits(@tolstoy))

          search

          assert_includes json[:links][:self], "/api/v1/search/authors?"
          assert_includes json[:links][:self], "q=tolstoy"
        end

        test "a provisional author and a stale id among the hits are left out, and total_count matches the rows" do
          @king.update!(provisional: true)
          stale = {id: "999999999", score: 1.0, source: {}}
          ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([stale, *hits(@king, @tolstoy, @garnett)])

          search
          assert_api_conform(status: 200)

          assert_equal [@tolstoy.id, @garnett.id], json[:data].map { |a| a[:id] }
          assert_equal [2, 1], [json[:meta][:total_count], json[:meta][:total_pages]]
        end

        test "a missing q is a 400 and never searches" do
          ::Search::Books::Search::AuthorGeneral.expects(:call).never

          get "/api/v1/search/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal ["invalid_parameter", "q is required"], [json[:code], json[:detail]]
        end

        test "an array q is a 400" do
          ::Search::Books::Search::AuthorGeneral.expects(:call).never

          get "/api/v1/search/authors?q[]=tolstoy", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal ["invalid_parameter", "q must be a single value"], [json[:code], json[:detail]]
        end

        test "q over 200 characters is a 400" do
          ::Search::Books::Search::AuthorGeneral.expects(:call).never

          search(q: "a" * 201)
          assert_api_response_conform(status: 400)

          assert_equal ["invalid_parameter", "q must be at most 200 characters"], [json[:code], json[:detail]]
        end

        test "an unreachable cluster is a 503 search_unavailable" do
          ::Search::Books::Search::AuthorGeneral.stubs(:call).raises(Faraday::ConnectionFailed, "down")

          search
          assert_api_response_conform(status: 503)

          assert_equal ["search_unavailable", 503], [json[:code], json[:status]]
        end

        test "an unrelated error is not dressed up as a 503" do
          ::Search::Books::Search::AuthorGeneral.stubs(:call).raises(NoMethodError, "bug")

          assert_raises(NoMethodError) { search }
        end

        test "a token without books:read is refused" do
          get "/api/v1/search/authors", params: {q: "tolstoy"}, headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_response_conform(status: 403)
        end

        test "an anonymous request is a 401" do
          get "/api/v1/search/authors", params: {q: "tolstoy"}
          assert_api_response_conform(status: 401)
        end
      end
    end
  end
end
