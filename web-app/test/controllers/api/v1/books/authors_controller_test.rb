require "test_helper"

module Api
  module V1
    module Books
      class AuthorsControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_authors_global)
          @tolstoy = books_authors(:tolstoy)
          @king = books_authors(:king)
          @bachman = books_authors(:bachman)
          RankedItem.create!(item: @tolstoy, ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: @king, ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: @bachman, ranking_configuration: @rc, rank: 3, score: 80)
          # No author fixture has an image. Attach one to rank 1 AND rank 2 so the
          # nested image -> attachment -> blob preload runs for per_page=1 and
          # per_page=3 alike; with only rank 2 pictured, per_page=1 would skip the
          # nested preloads entirely and the N+1 test would fail for the wrong reason.
          attach_primary_image(@tolstoy)
          attach_primary_image(@king)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def attach_primary_image(author)
          image = Image.new(parent: author, primary: true)
          image.file.attach(io: StringIO.new("fake image data"), filename: "#{author.slug}.jpg", content_type: "image/jpeg")
          image.save!
        end

        # --- index ---------------------------------------------------------------

        test "index lists ranked authors best first with meta and links" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[leo-tolstoy stephen-king richard-bachman], json[:data].map { |a| a[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |a| a[:rank] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index rows are the compact shape with a CDN image URL where one exists" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          tolstoy, _king, bachman = json[:data]
          assert_equal %i[id slug name sort_name birth_year death_year rank image_url url api_url], tolstoy.keys
          assert_match %r{\Ahttps://images-dev\.thegreatestbooks\.org/}, tolstoy[:image_url]
          assert_nil bachman[:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", tolstoy[:url]
        end

        test "index excludes unranked authors" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute_includes json[:data].map { |a| a[:slug] }, books_authors(:garnett).slug
        end

        test "index reads the primary author ranking, not another author ranking" do
          RankedItem.create!(item: books_authors(:garnett), ranking_configuration: ranking_configurations(:books_authors_secondary), rank: 1, score: 100)

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute_includes json[:data].map { |a| a[:slug] }, "constance-garnett"
          assert_equal 3, json[:meta][:total_count]
        end

        test "index paginates" do
          get "/api/v1/authors?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal ["richard-bachman"], json[:data].map { |a| a[:slug] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200" do
          get "/api/v1/authors?page=9", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
        end

        test "invalid pagination parameters are a 400 problem" do
          {"page=0" => /page/, "per_page=101" => /per_page/}.each do |query, detail|
            get "/api/v1/authors?#{query}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 400)

            assert_response :bad_request, query
            assert_equal "application/problem+json; charset=utf-8", response.content_type
            assert_equal "invalid_parameter", json[:code]
            assert_match detail, json[:detail]
          end
        end

        test "index with no primary author ranking configuration is an empty 200" do
          ::Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal({page: 1, per_page: 50, total_count: 0, total_pages: 1}, json[:meta])
        end

        test "index with no primary author ranking still validates the page" do
          ::Books::Authors::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/authors?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
        end

        test "index does not N+1 on images" do
          get "/api/v1/authors?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/authors?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/authors?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full author" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_equal(
            %i[id slug name sort_name birth_year death_year rank image_url url api_url alternate_names kind description],
            json[:data].keys
          )
          assert_equal "leo-tolstoy", json[:data][:slug]
          assert_equal 1, json[:data][:rank]
          assert_equal ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"], json[:data][:alternate_names]
          assert_equal "person", json[:data][:kind]
          assert_equal "Russian writer widely regarded as one of the greatest novelists.", json[:data][:description]
          assert_match %r{\Ahttps://images-dev\.thegreatestbooks\.org/}, json[:data][:image_url]
          assert_equal "https://dev-new.thegreatestbooks.org/author/leo-tolstoy", json[:data][:url]
        end

        test "show does not embed books" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          refute json[:data].key?(:books)
        end

        test "show of an unranked author has a null rank" do
          get "/api/v1/authors/#{books_authors(:garnett).slug}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_response :success
          assert_nil json[:data][:rank]
          assert_nil json[:data][:description]
        end

        test "show of an unknown slug is a 404 problem" do
          get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
          assert_match(/author/, json[:detail])
        end

        test "show does not fall back to a primary-key lookup" do
          get "/api/v1/authors/#{@tolstoy.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "show does not answer to an alternate name" do
          get "/api/v1/authors/lev-tolstoy", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)

          assert_response :not_found
        end

        test "a non-JSON format is a routing 404" do
          get "/api/v1/authors.xml", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "this route only exists on the books host" do
          host! "dev.thegreatestmusic.org"

          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- framework confirmations that depend on THIS controller ---------------
        # The full auth / rate-limit matrix lives in BooksControllerTest; these
        # prove the authors controller inherits the books base (scope), and
        # that its errors pass through the same rendering.

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/authors"
          assert_api_conform(status: 401)

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "unauthenticated", json[:code]
        end

        test "a non-member's token is a 403 membership_required" do
          get "/api/v1/authors/#{@tolstoy.slug}", headers: bearer(ApiTokenSecrets::NON_MEMBER)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal "membership_required", json[:code]
        end

        test "a token without books:read is a 403 insufficient_scope naming books:read" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        test "every authenticated response carries the six rate-limit headers" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }

          get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "responses are never cacheable by a shared cache" do
          get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_includes response.headers["Cache-Control"], "no-store"
          assert_includes response.headers["Cache-Control"], "private"
        end
      end
    end
  end
end
