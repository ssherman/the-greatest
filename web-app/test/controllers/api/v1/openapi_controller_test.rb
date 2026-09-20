require "test_helper"

module Api
  module V1
    class OpenapiControllerTest < ActionDispatch::IntegrationTest
      test "serves the document publicly with the current host as its server" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_response :success
        assert_api_conform(status: 200)
        body = response.parsed_body
        assert_equal "3.1.0", body["openapi"]
        assert_equal [{"url" => "https://dev-new.thegreatestbooks.org"}], body["servers"]
        assert body["paths"].key?("/api/v1/books")
        assert_match(/public/, response.headers["Cache-Control"])
        assert_match(/max-age=3600/, response.headers["Cache-Control"])
        # What "edge-cacheable" actually depends on: Cloudflare bypasses cache
        # whenever a Set-Cookie header is present, regardless of Cache-Control.
        assert_nil response.headers["Set-Cookie"]
      end

      test "on the books host every books operation is present" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}"], response.parsed_body["paths"].keys
      end

      test "on the music and games hosts the document advertises only what those hosts serve" do
        %w[dev.thegreatestmusic.org dev.thegreatest.games].each do |hostname|
          host! hostname

          get "/api/v1/openapi.json"

          assert_response :success
          assert_api_conform(status: 200)
          body = response.parsed_body
          assert_equal "https://#{hostname}", body["servers"].first["url"]
          # /api/v1/books is routed on the books host alone; a client generated
          # from this document must not be sent to a route that 404s here.
          assert_equal ["/api/v1/openapi.json"], body["paths"].keys, hostname
          refute body["paths"].key?("/api/v1/authors"), hostname
        end
      end

      test "the x-domain tag is not leaked into the served document as an operation" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_equal "books", response.parsed_body.dig("paths", "/api/v1/books", "x-domain")
        assert_equal ["x-domain", "get"], response.parsed_body.dig("paths", "/api/v1/books").keys
      end

      test "a successful response carries no rate-limit headers, so the cached copy cannot mislead" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_response :success
        assert_nil response.headers["X-RateLimit-Limit"]
        assert_nil response.headers["X-RateLimit-Remaining"]
      end

      test "the document is behind the per-IP unauthenticated window" do
        host! "dev-new.thegreatestbooks.org"
        limit = Rails.application.config.x.api.unauthenticated_per_minute

        freeze_time do
          limit.times do
            get "/api/v1/openapi.json", headers: {"CF-Connecting-IP" => "203.0.113.42"}
            assert_response :success
          end

          get "/api/v1/openapi.json", headers: {"CF-Connecting-IP" => "203.0.113.42"}

          assert_response :too_many_requests
          assert_api_conform(status: 429)
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "rate_limited", response.parsed_body["code"]
          assert_match(/\A\d+\z/, response.headers["Retry-After"])
          assert_equal "0", response.headers["X-RateLimit-Remaining"]
          assert_nil response.headers["X-RateLimit-Daily-Limit"]
          refute_match(/public/, response.headers["Cache-Control"].to_s)

          get "/api/v1/openapi.json", headers: {"CF-Connecting-IP" => "203.0.113.43"}
          assert_response :success
        end
      end

      test "the document itself is valid enough to load" do
        assert_kind_of Hash, ::Api::OpenapiDocument.raw
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}", "/api/v1/authors", "/api/v1/authors/{slug}",
          "/api/v1/ranking_configurations", "/api/v1/ranking_configurations/{id}"], ::Api::OpenapiDocument.raw["paths"].keys
      end
    end
  end
end
