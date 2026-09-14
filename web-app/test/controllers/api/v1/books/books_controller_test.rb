require "test_helper"

module Api
  module V1
    module Books
      class BooksControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @mice = books_books(:of_mice_and_men)
          RankedItem.create!(item: @war_and_peace, ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: @crime, ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: @mice, ranking_configuration: @rc, rank: 3, score: 80)
          # Only war_and_peace's fixtures carry a book_authors row -- without these,
          # per_page=1 vs per_page=3 exercise identical (empty) nested author
          # preloads and the N+1 test below can't tell an included association from
          # a dropped one.
          ::Books::BookAuthor.create!(book: @crime, author: books_authors(:king), position: 1, role: 0)
          ::Books::BookAuthor.create!(book: @mice, author: books_authors(:bachman), position: 1, role: 0)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists ranked books best first with meta and links" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[war-and-peace crime-and-punishment of-mice-and-men], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |b| b[:rank] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index excludes unranked books" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute_includes json[:data].map { |b| b[:slug] }, books_books(:got).slug
        end

        test "index paginates" do
          get "/api/v1/books?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal ["of-mice-and-men"], json[:data].map { |b| b[:slug] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200" do
          get "/api/v1/books?page=9", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
        end

        test "invalid pagination parameters are a 400 problem" do
          {"page=0" => /page/, "page=abc" => /page/, "per_page=101" => /per_page/, "per_page=0" => /per_page/}.each do |query, detail|
            get "/api/v1/books?#{query}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 400)

            assert_response :bad_request, query
            assert_equal "application/problem+json; charset=utf-8", response.content_type
            assert_equal "invalid_parameter", json[:code]
            assert_match detail, json[:detail]
          end
        end

        test "index with no primary ranking configuration is an empty 200" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index does not N+1 on authors or covers" do
          get "/api/v1/books?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/books?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/books?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full book" do
          get "/api/v1/books/#{@war_and_peace.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "war-and-peace", json[:data][:slug]
          assert_equal 1, json[:data][:rank]
          assert json[:data].key?(:description)
          assert json[:data].key?(:categories)
          assert_equal "https://dev-new.thegreatestbooks.org/book/war-and-peace", json[:data][:url]
        end

        test "show of an unranked book has a null rank" do
          get "/api/v1/books/#{books_books(:got).slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_nil json[:data][:rank]
        end

        test "show of an unknown slug is a 404 problem" do
          get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
        end

        test "show does not fall back to a primary-key lookup" do
          get "/api/v1/books/#{@war_and_peace.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "a non-JSON format is a routing 404" do
          get "/api/v1/books.xml", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- authentication ------------------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/books"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "unauthenticated", json[:code]
          assert_equal 401, json[:status]
        end

        test "a token in a query parameter is not honoured -- still a 401" do
          get "/api/v1/books?access_token=#{ApiTokenSecrets::MEMBER}"
          # Response-only: access_token is deliberately an undocumented query
          # parameter -- request validation raises UnknownQueryParameterError
          # on exactly the input this test exists to send.
          assert_api_response_conform(status: 401)

          assert_response :unauthorized
        end

        test "an unknown token is a 401 invalid_token" do
          get "/api/v1/books", headers: bearer("tg_#{"z" * 40}")
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal %(Bearer error="invalid_token"), response.headers["WWW-Authenticate"]
          assert_equal "invalid_token", json[:code]
        end

        test "an expired token is a 401 invalid_token" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::EXPIRED)
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "invalid_token", json[:code]
        end

        test "a session cookie without a bearer token is still a 401" do
          sign_in_as(users(:regular_user), stub_auth: true)

          get "/api/v1/books"
          assert_api_conform(status: 401)

          assert_response :unauthorized
        end

        test "a non-member's token is a 403 membership_required with no challenge" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::NON_MEMBER)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_nil response.headers["WWW-Authenticate"]
          assert_equal "membership_required", json[:code]
        end

        test "a service account needs no membership and gets the system limits" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::SERVICE)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal Rails.application.config.x.api.rate_limits[:system][:per_minute].to_s, response.headers["X-RateLimit-Limit"]
        end

        # --- scopes --------------------------------------------------------------

        test "a token without books:read is a 403 insufficient_scope with a scope challenge" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        # --- rate limiting -------------------------------------------------------

        test "every authenticated response carries the six rate-limit headers" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          limits = Rails.application.config.x.api.rate_limits[:member]
          assert_equal limits[:per_minute].to_s, response.headers["X-RateLimit-Limit"]
          assert_equal (limits[:per_minute] - 1).to_s, response.headers["X-RateLimit-Remaining"]
          assert_equal limits[:per_day].to_s, response.headers["X-RateLimit-Daily-Limit"]
        end

        test "error responses after authentication carry the headers too" do
          get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "a 401 carries only the minute triple, describing the IP window" do
          get "/api/v1/books"
          assert_api_conform(status: 401)

          assert_equal Rails.application.config.x.api.unauthenticated_per_minute.to_s, response.headers["X-RateLimit-Limit"]
          assert response.headers["X-RateLimit-Remaining"].present?
          assert response.headers["X-RateLimit-Reset"].present?
          assert_nil response.headers["X-RateLimit-Daily-Limit"]
        end

        test "exceeding a window is a 429 with Retry-After and the headers" do
          reset_at = 30.seconds.from_now
          minute = Services::Api::RateLimiter::Window.new(limit: 60, remaining: 0, reset_at: reset_at, exceeded: true)
          day = Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 100, reset_at: 1.day.from_now, exceeded: false)
          Services::Api::RateLimiter.stubs(:hit).returns(Services::Api::RateLimiter::Verdict.new(minute: minute, day: day))

          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 429)

          assert_response :too_many_requests
          assert_match(/\A\d+\z/, response.headers["Retry-After"])
          assert_equal "0", response.headers["X-RateLimit-Remaining"]
          assert_equal "rate_limited", json[:code]
          assert_match(/Per-minute limit of 60/, json[:detail])
        end

        test "too many unauthenticated requests from one address is a 429 before any lookup" do
          limit = Rails.application.config.x.api.unauthenticated_per_minute
          # A well-formed but unknown token, not a bare request: a blank
          # Authorization header never reaches ApiToken.authenticate's DB lookup
          # regardless of ordering, so it can't tell a correctly-ordered peek
          # (skip the lookup once over the limit) from a regression that runs
          # the lookup first and checks the limit after.
          headers = bearer("tg_#{"z" * 40}").merge("CF-Connecting-IP" => "203.0.113.7")
          limit.times { get "/api/v1/books", headers: headers }

          assert_no_queries do
            get "/api/v1/books", headers: headers
          end
          assert_api_conform(status: 429)

          assert_response :too_many_requests
          assert_equal "rate_limited", json[:code]
          assert response.headers["Retry-After"].present?

          get "/api/v1/books", headers: bearer("tg_#{"z" * 40}").merge("CF-Connecting-IP" => "203.0.113.8")
          assert_response :unauthorized
        end

        # --- caching -------------------------------------------------------------

        test "responses are never cacheable by a shared cache" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"

          get "/api/v1/books"
          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end
      end
    end
  end
end
