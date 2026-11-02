require "test_helper"

module Api
  module V1
    # The admin document's twin of ContractCoverageTest: every documented
    # response of config/api/v1/admin_openapi.yaml must be reachable and
    # conform. The merge operations are exercised with a dry run for 200, so the shared fixtures survive.
    class AdminContractCoverageTest < ActionDispatch::IntegrationTest
      READ = ApiTokenSecrets::ADMIN_READ
      MEMBER = ApiTokenSecrets::MEMBER
      MERGE = ApiTokenSecrets::ADMIN

      EXERCISES = {
        ["GET", "/api/v1/admin/openapi.json", "200"] => -> { get "/api/v1/admin/openapi.json", headers: bearer(READ) },
        ["GET", "/api/v1/admin/openapi.json", "401"] => -> { get "/api/v1/admin/openapi.json" },
        ["GET", "/api/v1/admin/openapi.json", "403"] => -> { get "/api/v1/admin/openapi.json", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/openapi.json", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/openapi.json", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/books", "200"] => -> { get "/api/v1/admin/books?q=war", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books", "400"] => -> { get "/api/v1/admin/books?q=", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books", "401"] => -> { get "/api/v1/admin/books?q=war" },
        ["GET", "/api/v1/admin/books", "403"] => -> { get "/api/v1/admin/books?q=war", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/books", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/books?q=war", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/authors", "200"] => -> { get "/api/v1/admin/authors?q=tol", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors", "400"] => -> { get "/api/v1/admin/authors?q=", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors", "401"] => -> { get "/api/v1/admin/authors?q=tol" },
        ["GET", "/api/v1/admin/authors", "403"] => -> { get "/api/v1/admin/authors?q=tol", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/authors", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/authors?q=tol", headers: bearer(READ) } },
        ["POST", "/api/v1/admin/books/{id}/merge", "200"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: books_books(:crime_and_punishment).id, dry_run: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/merge", "400"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: "abc"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/merge", "401"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: books_books(:crime_and_punishment).id}, as: :json },
        ["POST", "/api/v1/admin/books/{id}/merge", "403"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: books_books(:crime_and_punishment).id}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/books/{id}/merge", "404"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: 999_999_999}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/merge", "422"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: books_books(:war_and_peace).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/merge", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/merge", params: {source_id: books_books(:crime_and_punishment).id}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/authors/{id}/merge", "200"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: books_authors(:king).id, dry_run: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/merge", "400"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: "abc"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/merge", "401"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: books_authors(:king).id}, as: :json },
        ["POST", "/api/v1/admin/authors/{id}/merge", "403"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: books_authors(:king).id}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/authors/{id}/merge", "404"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: 999_999_999}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/merge", "422"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: books_authors(:tolstoy).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/merge", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/merge", params: {source_id: books_authors(:king).id}, as: :json, headers: bearer(MERGE) } }
      }.freeze

      setup do
        host! "dev-new.thegreatestbooks.org"
        ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:war_and_peace).id.to_s, score: 1.0, source: {}}])
        ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([{id: books_authors(:tolstoy).id.to_s, score: 1.0, source: {}}])
      end

      test "the map and the document describe the same responses" do
        documented = OpenapiFirst::Test[:admin].routes.to_a.flat_map do |route|
          route.responses.to_a.map { |resp| [route.request_method, route.path, resp.status.to_s] }
        end.uniq

        assert_equal documented.sort, EXERCISES.keys.sort,
          "documented responses and EXERCISES disagree -- add the missing entry to whichever side lacks it"
      end

      test "every documented response is reachable and conforms" do
        EXERCISES.each do |(_method, _path, status), exercise|
          instance_exec(&exercise)
          assert_api_response_conform(status: Integer(status), api: :admin)
        end
      end
    end
  end
end
