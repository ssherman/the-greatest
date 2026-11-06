require "test_helper"

module Api
  module V1
    module Books
      class SimilarBooksControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @book = books_books(:crime_and_punishment)
          @war = books_books(:war_and_peace)
          @got = books_books(:got)
          @clash = books_books(:clash)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def hits(*books) = books.map { |book| {id: book.id.to_s, score: 1.0, source: {}} }

        def similar(book = @book, params = {}) = get("/api/v1/books/#{book.slug}/similar", params: params, headers: bearer(ApiTokenSecrets::MEMBER))

        def count_queries(&block)
          count = 0
          counter = ->(_name, _start, _finish, _id, payload) {
            count += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION])
          }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
          count
        end

        # n books, each by its own author and each ranked, so every per-book read
        # the resource makes has something to find.
        def write_similar_books(n)
          Array.new(n) do |i|
            book = ::Books::Book.create!(title: "Similar #{i}")
            author = ::Books::Author.create!(name: "Similar Author #{i}")
            ::Books::BookAuthor.create!(book: book, author: author, role: :author)
            RankedItem.create!(item: book, ranking_configuration: ranking_configurations(:books_global), rank: 100 + i, score: 1)
            book
          end
        end

        test "returns the similar books with their primary rank and more_available" do
          RankedItem.create!(item: @war, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1)
          # A rank on another configuration must not show: `rank` is the primary's.
          RankedItem.create!(item: @got, ranking_configuration: ranking_configurations(:books_user), rank: 3, score: 1)
          ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits(@got, @war))

          similar
          assert_api_conform(status: 200)

          assert_equal [@got.id, @war.id], json[:data].map { |b| b[:id] }
          assert_equal [nil, 7], json[:data].map { |b| b[:rank] }
          assert_equal "leo-tolstoy", json[:data][1][:authors].first[:slug]
          assert_equal({more_available: false}, json[:meta])
          refute json.key?(:links)
        end

        test "an empty similarity result is an empty list, not an error" do
          ::Search::Books::Search::BookSimilar.stubs(:call).returns([])

          similar
          assert_api_conform(status: 200)

          assert_equal [[], false], [json[:data], json[:meta][:more_available]]
        end

        test "limit defaults to 10" do
          ::Services::Books::SimilarBooks.expects(:call).with(@book, limit: 10, raise_on_failure: true)
            .returns(::Services::Books::SimilarBooks::Result.new(success?: true, data: {books: [], more_available: false}, errors: []))

          similar
          assert_api_conform(status: 200)
        end

        test "limit caps the result and says when more is available" do
          books = write_similar_books(5)
          ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits(*books))

          similar(@book, limit: 3)
          assert_api_conform(status: 200)

          assert_equal books.first(3).map(&:id), json[:data].map { |b| b[:id] }
          assert json[:meta][:more_available]
        end

        test "limit 25 is accepted" do
          ::Services::Books::SimilarBooks.expects(:call).with(@book, limit: 25, raise_on_failure: true)
            .returns(::Services::Books::SimilarBooks::Result.new(success?: true, data: {books: [], more_available: false}, errors: []))

          similar(@book, limit: 25)
          assert_api_conform(status: 200)
        end

        test "limit 0, 26, abc, 10.5 and -1 are each a 400 naming limit" do
          ::Search::Books::Search::BookSimilar.expects(:call).never

          ["0", "26", "abc", "10.5", "-1"].each do |bad|
            similar(@book, limit: bad)
            assert_api_response_conform(status: 400)

            assert_equal "invalid_parameter", json[:code], bad
            assert_includes json[:detail], "limit", bad
          end
        end

        test "an unknown or provisional book is a 404, and beats a bad limit" do
          get "/api/v1/books/no-such-book/similar?limit=abc", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)
          assert_equal "not_found", json[:code]

          @book.update!(provisional: true)

          similar
          assert_api_conform(status: 404)
        end

        test "a provisional book among the hits is left out" do
          @got.update!(provisional: true)
          ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits(@got, @war))

          similar
          assert_api_conform(status: 200)

          assert_equal [@war.id], json[:data].map { |b| b[:id] }
        end

        test "an unreachable cluster is a 503 search_unavailable" do
          ::Search::Books::Search::BookSimilar.stubs(:call).raises(Faraday::ConnectionFailed, "down")

          similar
          assert_api_response_conform(status: 503)

          assert_equal ["search_unavailable", 503], [json[:code], json[:status]]
        end

        test "an unrelated error is not dressed up as a 503" do
          ::Search::Books::Search::BookSimilar.stubs(:call).raises(NoMethodError, "bug")

          assert_raises(NoMethodError) { similar }
        end

        test "query count does not grow with the number of similar books" do
          few = write_similar_books(2)
          ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits(*few))
          similar # warm per-process caches
          few_queries = count_queries { similar }

          many = write_similar_books(8)
          ::Search::Books::Search::BookSimilar.stubs(:call).returns(hits(*few, *many))
          many_queries = count_queries { similar }
          assert_equal 10, json[:data].size

          assert_equal few_queries, many_queries
        end

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/books/#{@book.slug}/similar"
          assert_api_conform(status: 401)

          assert_equal "Bearer", response.headers["WWW-Authenticate"]
        end

        test "a token without books:read is a 403 insufficient_scope" do
          get "/api/v1/books/#{@book.slug}/similar", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_equal "insufficient_scope", json[:code]
        end
      end
    end
  end
end
