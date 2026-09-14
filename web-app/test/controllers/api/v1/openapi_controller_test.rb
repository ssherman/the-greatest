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
      end

      test "stamps the music host when fetched there" do
        host! "dev.thegreatestmusic.org"

        get "/api/v1/openapi.json"

        assert_response :success
        assert_equal "https://dev.thegreatestmusic.org", response.parsed_body["servers"].first["url"]
      end

      test "the document itself is valid enough to load" do
        assert_kind_of Hash, ::Api::OpenapiDocument.raw
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}"], ::Api::OpenapiDocument.raw["paths"].keys
      end
    end
  end
end
