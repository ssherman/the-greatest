require "test_helper"

module Api
  module V1
    module Admin
      class OpenapiControllerTest < ActionDispatch::IntegrationTest
        setup { host! "dev-new.thegreatestbooks.org" }

        test "serves the admin document to an admin read token, uncached" do
          get "/api/v1/admin/openapi.json", headers: bearer(ApiTokenSecrets::ADMIN_READ)
          assert_api_response_conform(status: 200, api: :admin)

          body = response.parsed_body
          assert_equal [{"url" => "https://dev-new.thegreatestbooks.org"}], body["servers"]
          assert_equal %w[/api/v1/admin/openapi.json /api/v1/admin/books /api/v1/admin/authors /api/v1/admin/duplicate_candidates /api/v1/admin/duplicate_candidates/{id} /api/v1/admin/duplicate_candidates/{id}/merge /api/v1/admin/duplicate_candidates/{id}/dismiss /api/v1/admin/match_decisions /api/v1/admin/match_decisions/{id} /api/v1/admin/match_decisions/{id}/review /api/v1/admin/match_decisions/{id}/reject_link /api/v1/admin/books/{id}/identifiers /api/v1/admin/books/{id}/identifiers/{identifier_id} /api/v1/admin/authors/{id}/identifiers /api/v1/admin/authors/{id}/identifiers/{identifier_id} /api/v1/admin/identifiers /api/v1/admin/categories /api/v1/admin/categories/{id} /api/v1/admin/categories/{id}/merge /api/v1/admin/books/{id}/merge /api/v1/admin/authors/{id}/merge /api/v1/admin/books/{id}/categories /api/v1/admin/books/{id}/categories/{category_id} /api/v1/admin/authors/{id}/categories /api/v1/admin/authors/{id}/categories/{category_id}], body["paths"].keys
          assert_match(/no-store/, response.headers["Cache-Control"])
        end

        test "refuses a public read token and no token" do
          get "/api/v1/admin/openapi.json", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 403, api: :admin)

          get "/api/v1/admin/openapi.json"
          assert_api_response_conform(status: 401, api: :admin)
        end

        test "the public document and the developers page never mention an admin path" do
          get "/api/v1/openapi.json"
          assert_empty response.parsed_body["paths"].keys.grep(%r{\A/api/v1/admin})
          refute_match(%r{books:admin|/api/v1/admin}, response.body)

          get "/developers"
          refute_match(%r{books:admin|/api/v1/admin}, response.body)
        end
      end
    end
  end
end
