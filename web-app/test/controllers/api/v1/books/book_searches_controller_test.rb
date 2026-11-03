require "test_helper"

module Api
  module V1
    module Books
      class BookSearchesControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @war = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @mice = books_books(:of_mice_and_men)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def hits(*books) = books.map { |book| {id: book.id.to_s, score: 1.0, source: {}} }

        def search(params = {q: "war"}) = get("/api/v1/search/books", params: params, headers: bearer(ApiTokenSecrets::MEMBER))

        test "returns the matches in hit order, in the Book shape, with the primary rank" do
          RankedItem.create!(item: @war, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1)
          # A rank on another configuration must not show: `rank` is the primary's.
          RankedItem.create!(item: @crime, ranking_configuration: ranking_configurations(:books_user), rank: 3, score: 1)
          ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@mice, @war, @crime))

          search
          assert_api_conform(status: 200)

          assert_equal [@mice.id, @war.id, @crime.id], json[:data].map { |b| b[:id] }
          assert_equal [nil, 7, nil], json[:data].map { |b| b[:rank] }
          assert_equal "leo-tolstoy", json[:data][1][:authors].first[:slug]
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
        end

        test "links carry q and the index is asked for at most 100 hits" do
          ::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 100).returns(hits(@war))

          search

          assert_includes json[:links][:self], "/api/v1/search/books?"
          assert_includes json[:links][:self], "q=war"
        end

        test "q is stripped before it is searched" do
          ::Search::Books::Search::BookGeneral.expects(:call).with("war", size: 100).returns(hits(@war))

          search(q: "  war ")

          assert_response :success
        end

        test "a provisional book and a stale id among the hits are left out, and total_count matches the rows" do
          @crime.update!(provisional: true)
          stale = {id: "999999999", score: 1.0, source: {}}
          ::Search::Books::Search::BookGeneral.stubs(:call).returns([stale, *hits(@crime, @war, @mice)])

          search
          assert_api_conform(status: 200)

          assert_equal [@war.id, @mice.id], json[:data].map { |b| b[:id] }
          assert_equal [2, 1], [json[:meta][:total_count], json[:meta][:total_pages]]
        end

        test "hits that are all provisional or stale are an empty page, not an error" do
          @war.update!(provisional: true)
          ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: "999999999", score: 1.0, source: {}}, *hits(@war)])

          search
          assert_api_conform(status: 200)

          assert_equal [[], 0], [json[:data], json[:meta][:total_count]]
        end

        test "exactly 100 hits at per_page=100 is one page with no next link" do
          books = Array.new(100) { |i| ::Books::Book.create!(title: "Search hit #{i}") }
          ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(*books))

          search(q: "hit", per_page: 100)
          assert_api_conform(status: 200)

          assert_equal [100, 100, 1], [json[:data].size, json[:meta][:total_count], json[:meta][:total_pages]]
          assert_nil json[:links][:next]
        end

        test "a missing q is a 400 and never searches" do
          ::Search::Books::Search::BookGeneral.expects(:call).never

          get "/api/v1/search/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
        end

        test "a blank q is a 400 and never searches" do
          ::Search::Books::Search::BookGeneral.expects(:call).never

          get "/api/v1/search/books?q=%20", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
        end

        test "a bad page is a 400" do
          ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@war))

          search(q: "war", page: 0)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
        end

        test "an unreachable cluster is a 503 search_unavailable" do
          ::Search::Books::Search::BookGeneral.stubs(:call).raises(Faraday::ConnectionFailed, "down")

          search
          assert_api_response_conform(status: 503)

          assert_equal ["search_unavailable", 503], [json[:code], json[:status]]
        end

        test "a 503 from the cluster is a 503 search_unavailable" do
          ::Search::Books::Search::BookGeneral.stubs(:call)
            .raises(::OpenSearch::Transport::Transport::Errors::ServiceUnavailable, "overloaded")

          search
          assert_api_response_conform(status: 503)

          assert_equal "search_unavailable", json[:code]
        end

        test "an unrelated error is not dressed up as a 503" do
          ::Search::Books::Search::BookGeneral.stubs(:call).raises(NoMethodError, "bug")

          assert_raises(NoMethodError) { search }
        end

        test "a token without books:read is refused" do
          get "/api/v1/search/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_response_conform(status: 403)
        end

        test "an anonymous request is a 401" do
          get "/api/v1/search/books", params: {q: "war"}
          assert_api_response_conform(status: 401)
        end

        test "the route does not exist on the music host" do
          host! "dev.thegreatestmusic.org"

          search

          assert_response :not_found
        end
      end
    end
  end
end
