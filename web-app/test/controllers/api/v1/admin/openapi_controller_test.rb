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
          assert_equal %w[/api/v1/admin/openapi.json /api/v1/admin/books /api/v1/admin/authors /api/v1/admin/books/{id} /api/v1/admin/authors/{id} /api/v1/admin/duplicate_candidates /api/v1/admin/duplicate_candidates/{id} /api/v1/admin/duplicate_candidates/{id}/merge /api/v1/admin/duplicate_candidates/{id}/dismiss /api/v1/admin/match_decisions /api/v1/admin/match_decisions/{id} /api/v1/admin/match_decisions/{id}/review /api/v1/admin/match_decisions/{id}/reject_link /api/v1/admin/repair_verdicts /api/v1/admin/repair_verdicts/{id} /api/v1/admin/repair_verdicts/{id}/approve /api/v1/admin/repair_verdicts/{id}/reject /api/v1/admin/repair_verdicts/{id}/correct /api/v1/admin/repair_verdicts/bulk_approve /api/v1/admin/enrichment_queues /api/v1/admin/enrichment_queues/{type} /api/v1/admin/enrichment_queues/{type}/claims /api/v1/admin/enrichment_items/{id}/submit /api/v1/admin/enrichment_items/{id}/skip /api/v1/admin/book_submissions /api/v1/admin/book_submissions/{id} /api/v1/admin/book_submissions/claims /api/v1/admin/book_submissions/{id}/details /api/v1/admin/book_submissions/{id}/skip /api/v1/admin/book_submissions/{id}/approve /api/v1/admin/book_submissions/{id}/merge /api/v1/admin/book_submissions/{id}/reject /api/v1/admin/books/{id}/identifiers /api/v1/admin/books/{id}/identifiers/{identifier_id} /api/v1/admin/authors/{id}/identifiers /api/v1/admin/authors/{id}/identifiers/{identifier_id} /api/v1/admin/identifiers /api/v1/admin/books/{id}/descriptions /api/v1/admin/authors/{id}/descriptions /api/v1/admin/descriptions/{id} /api/v1/admin/descriptions/{id}/prefer /api/v1/admin/categories /api/v1/admin/categories/{id} /api/v1/admin/categories/{id}/merge /api/v1/admin/series /api/v1/admin/series/{id} /api/v1/admin/series/{id}/merge /api/v1/admin/series/{id}/books /api/v1/admin/series/{id}/books/{book_id} /api/v1/admin/books/{id}/merge /api/v1/admin/authors/{id}/merge /api/v1/admin/books/{id}/categories /api/v1/admin/books/{id}/categories/{category_id} /api/v1/admin/authors/{id}/categories /api/v1/admin/authors/{id}/categories/{category_id} /api/v1/admin/books/{id}/authors /api/v1/admin/books/{id}/authors/{author_id} /api/v1/admin/lists /api/v1/admin/lists/{id} /api/v1/admin/lists/{id}/penalties /api/v1/admin/lists/{id}/penalties/{penalty_id} /api/v1/admin/fetch_page /api/v1/admin/list_audits /api/v1/admin/list_audits/{id}/finish /api/v1/admin/list_audits/{id}/release /api/v1/admin/lists/{id}/items /api/v1/admin/list_items/{id} /api/v1/admin/penalties /api/v1/admin/news_posts /api/v1/admin/news_posts/{id} /api/v1/admin/news_posts/{id}/publish /api/v1/admin/news_posts/{id}/unpublish /api/v1/admin/news_topics], body["paths"].keys
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
