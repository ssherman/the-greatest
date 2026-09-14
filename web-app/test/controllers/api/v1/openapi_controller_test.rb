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

        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}"], response.parsed_body["paths"].keys
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
        end
      end

      test "the x-domain tag is not leaked into the served document as an operation" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_equal "books", response.parsed_body.dig("paths", "/api/v1/books", "x-domain")
        assert_equal ["x-domain", "get"], response.parsed_body.dig("paths", "/api/v1/books").keys
      end

      test "the document itself is valid enough to load" do
        assert_kind_of Hash, ::Api::OpenapiDocument.raw
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}"], ::Api::OpenapiDocument.raw["paths"].keys
      end
    end
  end
end
