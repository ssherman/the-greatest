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
        ["GET", "/api/v1/admin/books/{id}", "200"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}", "401"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}" },
        ["GET", "/api/v1/admin/books/{id}", "403"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/books/{id}", "404"] => -> { get "/api/v1/admin/books/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/authors/{id}", "200"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}", "401"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}" },
        ["GET", "/api/v1/admin/authors/{id}", "403"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/authors/{id}", "404"] => -> { get "/api/v1/admin/authors/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/duplicate_candidates", "200"] => -> { get "/api/v1/admin/duplicate_candidates", headers: bearer(READ) },
        ["GET", "/api/v1/admin/duplicate_candidates", "400"] => -> { get "/api/v1/admin/duplicate_candidates?status=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/duplicate_candidates", "401"] => -> { get "/api/v1/admin/duplicate_candidates" },
        ["GET", "/api/v1/admin/duplicate_candidates", "403"] => -> { get "/api/v1/admin/duplicate_candidates", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/duplicate_candidates", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/duplicate_candidates", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/duplicate_candidates/{id}", "200"] => -> { get "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/duplicate_candidates/{id}", "401"] => -> { get "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}" },
        ["GET", "/api/v1/admin/duplicate_candidates/{id}", "403"] => -> { get "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/duplicate_candidates/{id}", "404"] => -> { get "/api/v1/admin/duplicate_candidates/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/duplicate_candidates/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}", headers: bearer(READ) } },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "200"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: duplicate_candidates(:books_pending_pair).item_a_id, source_id: duplicate_candidates(:books_pending_pair).item_b_id, dry_run: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "400"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: "abc", source_id: 1}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "401"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: duplicate_candidates(:books_pending_pair).item_a_id, source_id: duplicate_candidates(:books_pending_pair).item_b_id}, as: :json },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "403"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: duplicate_candidates(:books_pending_pair).item_a_id, source_id: duplicate_candidates(:books_pending_pair).item_b_id}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "404"] => -> { post "/api/v1/admin/duplicate_candidates/999999999/merge", params: {target_id: 1, source_id: 2}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "422"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: 999_999_999, source_id: 999_999_998}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/merge", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/merge", params: {target_id: duplicate_candidates(:books_pending_pair).item_a_id, source_id: duplicate_candidates(:books_pending_pair).item_b_id}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "200"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/dismiss", params: {note: "Different books.", record_ids: [duplicate_candidates(:books_pending_pair).item_a_id, duplicate_candidates(:books_pending_pair).item_b_id]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "400"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/dismiss", params: {note: ["x"], record_ids: [duplicate_candidates(:books_pending_pair).item_a_id, duplicate_candidates(:books_pending_pair).item_b_id]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "401"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/dismiss", as: :json },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "403"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/dismiss", params: {record_ids: [duplicate_candidates(:books_pending_pair).item_a_id, duplicate_candidates(:books_pending_pair).item_b_id]}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "404"] => -> { post "/api/v1/admin/duplicate_candidates/999999999/dismiss", params: {record_ids: [1, 2]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "422"] => -> { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_dismissed_pair).id}/dismiss", params: {record_ids: [duplicate_candidates(:books_dismissed_pair).item_a_id, duplicate_candidates(:books_dismissed_pair).item_b_id]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/duplicate_candidates/{id}/dismiss", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/duplicate_candidates/#{duplicate_candidates(:books_pending_pair).id}/dismiss", params: {record_ids: [duplicate_candidates(:books_pending_pair).item_a_id, duplicate_candidates(:books_pending_pair).item_b_id]}, as: :json, headers: bearer(MERGE) } },
        ["GET", "/api/v1/admin/match_decisions", "200"] => -> { get "/api/v1/admin/match_decisions", headers: bearer(READ) },
        ["GET", "/api/v1/admin/match_decisions", "400"] => -> { get "/api/v1/admin/match_decisions?outcome=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/match_decisions", "401"] => -> { get "/api/v1/admin/match_decisions" },
        ["GET", "/api/v1/admin/match_decisions", "403"] => -> { get "/api/v1/admin/match_decisions", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/match_decisions", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/match_decisions", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/match_decisions/{id}", "200"] => -> { get "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/match_decisions/{id}", "401"] => -> { get "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}" },
        ["GET", "/api/v1/admin/match_decisions/{id}", "403"] => -> { get "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/match_decisions/{id}", "404"] => -> { get "/api/v1/admin/match_decisions/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/match_decisions/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "200"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "400"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers?scope=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "401"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers" },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "403"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "404"] => -> { get "/api/v1/admin/books/999999999/identifiers", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}/identifiers", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "200"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "400"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers?page=0", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "401"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers" },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "403"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "404"] => -> { get "/api/v1/admin/authors/999999999/identifiers", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}/identifiers", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/identifiers", "200"] => -> { get "/api/v1/admin/identifiers?type=books_author_viaf&value=123", headers: bearer(READ) },
        ["GET", "/api/v1/admin/identifiers", "400"] => -> { get "/api/v1/admin/identifiers?type=bogus&value=1", headers: bearer(READ) },
        ["GET", "/api/v1/admin/identifiers", "401"] => -> { get "/api/v1/admin/identifiers?type=books_author_viaf&value=123" },
        ["GET", "/api/v1/admin/identifiers", "403"] => -> { get "/api/v1/admin/identifiers?type=books_author_viaf&value=123", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/identifiers", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/identifiers?type=books_author_viaf&value=123", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/books/{id}/descriptions", "200"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}/descriptions", "401"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions" },
        ["GET", "/api/v1/admin/books/{id}/descriptions", "403"] => -> { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/books/{id}/descriptions", "404"] => -> { get "/api/v1/admin/books/999999999/descriptions", headers: bearer(READ) },
        ["GET", "/api/v1/admin/books/{id}/descriptions", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/authors/{id}/descriptions", "200"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}/descriptions", "401"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions" },
        ["GET", "/api/v1/admin/authors/{id}/descriptions", "403"] => -> { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/authors/{id}/descriptions", "404"] => -> { get "/api/v1/admin/authors/999999999/descriptions", headers: bearer(READ) },
        ["GET", "/api/v1/admin/authors/{id}/descriptions", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", headers: bearer(READ) } },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "201"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "A novel.", source: "manual"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "400"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "A novel.", source: "bogus"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "401"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "A novel.", source: "manual"}, as: :json },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "403"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "A novel.", source: "manual"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "404"] => -> { post "/api/v1/admin/books/999999999/descriptions", params: {content: "A novel.", source: "manual"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "422"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "Again.", source: "ai_generated"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/descriptions", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/descriptions", params: {content: "A novel.", source: "manual"}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "201"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "A novelist.", source: "manual"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "400"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "A novelist.", source: "other"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "401"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "A novelist.", source: "manual"}, as: :json },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "403"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "A novelist.", source: "manual"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "404"] => -> { post "/api/v1/admin/authors/999999999/descriptions", params: {content: "A novelist.", source: "manual"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "422"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "Again.", source: "other", source_name: "Google Books"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/descriptions", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/descriptions", params: {content: "A novelist.", source: "manual"}, as: :json, headers: bearer(MERGE) } },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "200"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {content: "Corrected."}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "400"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {license: "bogus"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "401"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {content: "Corrected."}, as: :json },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "403"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {content: "Corrected."}, as: :json, headers: bearer(READ) },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "404"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:dark_side_ai).id}", params: {content: "Corrected."}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "422"] => -> { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {source: "wikipedia", source_url: "https://en.wikipedia.org/wiki/War_and_Peace"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/descriptions/{id}", "429"] => -> { with_exhausted_limit { patch "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", params: {content: "Corrected."}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/descriptions/{id}/prefer", "200"] => -> { post "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/descriptions/{id}/prefer", "401"] => -> { post "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer", as: :json },
        ["POST", "/api/v1/admin/descriptions/{id}/prefer", "403"] => -> { post "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer", as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/descriptions/{id}/prefer", "404"] => -> { post "/api/v1/admin/descriptions/#{descriptions(:dark_side_ai).id}/prefer", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/descriptions/{id}/prefer", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer", as: :json, headers: bearer(MERGE) } },
        ["DELETE", "/api/v1/admin/descriptions/{id}", "200"] => -> { delete "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/descriptions/{id}", "401"] => -> { delete "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}" },
        ["DELETE", "/api/v1/admin/descriptions/{id}", "403"] => -> { delete "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/descriptions/{id}", "404"] => -> { delete "/api/v1/admin/descriptions/#{descriptions(:dark_side_ai).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/descriptions/{id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "200"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_isbn13", value: identifiers(:war_and_peace_isbn13).value}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "201"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_isbn10", value: "0306406152"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "400"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_isbn10", value: "0306406153"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "401"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_asin", value: "B0"}, as: :json },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "403"] => -> { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_asin", value: "B0"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "404"] => -> { post "/api/v1/admin/books/999999999/identifiers", params: {identifier_type: "books_work_asin", value: "B0"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/books/{id}/identifiers", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers", params: {identifier_type: "books_work_asin", value: "B0"}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "200"] => -> { 2.times { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_isni", value: "0000000081226987"}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "201"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_isni", value: "0000000120960218"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "400"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_viaf", value: "abc"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "401"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_viaf", value: "1"}, as: :json },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "403"] => -> { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_viaf", value: "1"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "404"] => -> { post "/api/v1/admin/authors/999999999/identifiers", params: {identifier_type: "books_author_viaf", value: "1"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "422"] => -> {
          Identifier.find_or_create_by!(identifiable: books_authors(:tolstoy), identifier_type: :books_author_viaf, value: "111")
          post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_viaf", value: "222"}, as: :json, headers: bearer(MERGE)
        },
        ["POST", "/api/v1/admin/authors/{id}/identifiers", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers", params: {identifier_type: "books_author_viaf", value: "1"}, as: :json, headers: bearer(MERGE) } },
        ["DELETE", "/api/v1/admin/books/{id}/identifiers/{identifier_id}", "200"] => -> {
          row = Identifier.create!(identifiable: books_books(:war_and_peace), identifier_type: :books_work_goodreads_id, value: "coverage-delete")
          delete "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers/#{row.id}", headers: bearer(MERGE)
        },
        ["DELETE", "/api/v1/admin/books/{id}/identifiers/{identifier_id}", "401"] => -> { delete "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers/#{identifiers(:war_and_peace_asin).id}" },
        ["DELETE", "/api/v1/admin/books/{id}/identifiers/{identifier_id}", "403"] => -> { delete "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers/#{identifiers(:war_and_peace_asin).id}", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/books/{id}/identifiers/{identifier_id}", "404"] => -> { delete "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers/999999999", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/books/{id}/identifiers/{identifier_id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/books/#{books_books(:war_and_peace).id}/identifiers/#{identifiers(:war_and_peace_asin).id}", headers: bearer(MERGE) } },
        ["DELETE", "/api/v1/admin/authors/{id}/identifiers/{identifier_id}", "200"] => -> {
          row = Identifier.create!(identifiable: books_authors(:tolstoy), identifier_type: :books_author_goodreads_id, value: "coverage-delete")
          delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers/#{row.id}", headers: bearer(MERGE)
        },
        ["DELETE", "/api/v1/admin/authors/{id}/identifiers/{identifier_id}", "401"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers/1" },
        ["DELETE", "/api/v1/admin/authors/{id}/identifiers/{identifier_id}", "403"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers/1", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/authors/{id}/identifiers/{identifier_id}", "404"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers/999999999", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/authors/{id}/identifiers/{identifier_id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}/identifiers/1", headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "200"] => -> { post "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}/review", params: {verdict: "confirmed", note: "Same book."}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "400"] => -> { post "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}/review", params: {note: ["x"]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "401"] => -> { post "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}/review", as: :json },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "403"] => -> { post "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}/review", as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "404"] => -> { post "/api/v1/admin/match_decisions/999999999/review", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "422"] => -> { post "/api/v1/admin/match_decisions/#{match_decisions(:reviewed_book_match).id}/review", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/review", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/match_decisions/#{match_decisions(:low_confidence_book_match).id}/review", as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "200"] => -> { post "/api/v1/admin/match_decisions/#{link_decision.id}/reject_link", params: {note: "Wrong person."}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "400"] => -> { post "/api/v1/admin/match_decisions/#{link_decision.id}/reject_link", params: {note: ["x"]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "401"] => -> { post "/api/v1/admin/match_decisions/#{link_decision.id}/reject_link", as: :json },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "403"] => -> { post "/api/v1/admin/match_decisions/#{link_decision.id}/reject_link", as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "404"] => -> { post "/api/v1/admin/match_decisions/999999999/reject_link", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "422"] => -> { post "/api/v1/admin/match_decisions/#{link_decision(outcome: :unmatched).id}/reject_link", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/match_decisions/{id}/reject_link", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/match_decisions/#{link_decision.id}/reject_link", as: :json, headers: bearer(MERGE) } },
        ["GET", "/api/v1/admin/categories", "200"] => -> { get "/api/v1/admin/categories?q=nov", headers: bearer(READ) },
        ["GET", "/api/v1/admin/categories", "400"] => -> { get "/api/v1/admin/categories?status=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/categories", "401"] => -> { get "/api/v1/admin/categories" },
        ["GET", "/api/v1/admin/categories", "403"] => -> { get "/api/v1/admin/categories", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/categories", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/categories", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/categories/{id}", "200"] => -> { get "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/categories/{id}", "401"] => -> { get "/api/v1/admin/categories/#{categories(:books_novels_genre).id}" },
        ["GET", "/api/v1/admin/categories/{id}", "403"] => -> { get "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/categories/{id}", "404"] => -> { get "/api/v1/admin/categories/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/categories/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", headers: bearer(READ) } },
        ["POST", "/api/v1/admin/categories", "201"] => -> { post "/api/v1/admin/categories", params: {name: "Coverage Genre", category_type: "genre"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories", "400"] => -> { post "/api/v1/admin/categories", params: {name: "X", category_type: "bogus"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories", "401"] => -> { post "/api/v1/admin/categories", params: {name: "X"}, as: :json },
        ["POST", "/api/v1/admin/categories", "403"] => -> { post "/api/v1/admin/categories", params: {name: "X"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/categories", "422"] => -> { post "/api/v1/admin/categories", params: {name: "Novels"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/categories", params: {name: "X"}, as: :json, headers: bearer(MERGE) } },
        ["PATCH", "/api/v1/admin/categories/{id}", "200"] => -> { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {description: "Prose"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/categories/{id}", "400"] => -> { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {parent_id: "abc"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/categories/{id}", "401"] => -> { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {description: "x"}, as: :json },
        ["PATCH", "/api/v1/admin/categories/{id}", "403"] => -> { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {description: "x"}, as: :json, headers: bearer(READ) },
        ["PATCH", "/api/v1/admin/categories/{id}", "404"] => -> { patch "/api/v1/admin/categories/999999999", params: {description: "x"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/categories/{id}", "422"] => -> { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {parent_id: categories(:books_novels_genre).id}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/categories/{id}", "429"] => -> { with_exhausted_limit { patch "/api/v1/admin/categories/#{categories(:books_novels_genre).id}", params: {description: "x"}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/categories/{id}/merge", "200"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [categories(:books_classics_genre).id], dry_run: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories/{id}/merge", "400"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories/{id}/merge", "401"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [categories(:books_classics_genre).id]}, as: :json },
        ["POST", "/api/v1/admin/categories/{id}/merge", "403"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [categories(:books_classics_genre).id]}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/categories/{id}/merge", "404"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [999_999_999]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories/{id}/merge", "422"] => -> { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [categories(:books_deleted_genre).id]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/categories/{id}/merge", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/categories/#{categories(:books_novels_genre).id}/merge", params: {source_ids: [categories(:books_classics_genre).id]}, as: :json, headers: bearer(MERGE) } },
        ["DELETE", "/api/v1/admin/categories/{id}", "200"] => -> { delete "/api/v1/admin/categories/#{categories(:books_classics_genre).id}?dry_run=true", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/categories/{id}", "401"] => -> { delete "/api/v1/admin/categories/#{categories(:books_classics_genre).id}" },
        ["DELETE", "/api/v1/admin/categories/{id}", "403"] => -> { delete "/api/v1/admin/categories/#{categories(:books_classics_genre).id}", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/categories/{id}", "404"] => -> { delete "/api/v1/admin/categories/999999999", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/categories/{id}", "422"] => -> { delete "/api/v1/admin/categories/#{categories(:books_deleted_genre).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/categories/{id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/categories/#{categories(:books_classics_genre).id}", headers: bearer(MERGE) } },
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
      }.merge(
        %w[books authors].flat_map do |segment|
          tag = "/api/v1/admin/#{segment}/{id}/categories"
          untag = "#{tag}/{category_id}"
          entries = [
            [["POST", tag, "200"], -> { post tag_path(segment), params: {category_id: politics_id}, as: :json, headers: bearer(MERGE) }],
            [["POST", tag, "400"], -> { post tag_path(segment), params: {category_id: "abc"}, as: :json, headers: bearer(MERGE) }],
            [["POST", tag, "401"], -> { post tag_path(segment), params: {category_id: politics_id}, as: :json }],
            [["POST", tag, "403"], -> { post tag_path(segment), params: {category_id: politics_id}, as: :json, headers: bearer(READ) }],
            [["POST", tag, "404"], -> { post tag_path(segment, 999_999_999), params: {category_id: politics_id}, as: :json, headers: bearer(MERGE) }],
            [["POST", tag, "422"], -> { post tag_path(segment), params: {category_id: categories(:music_rock_genre).id}, as: :json, headers: bearer(MERGE) }],
            [["POST", tag, "429"], -> { with_exhausted_limit { post tag_path(segment), params: {category_id: politics_id}, as: :json, headers: bearer(MERGE) } }],
            [["DELETE", untag, "200"], -> {
              CategoryItem.find_or_create_by!(item: tag_item(segment), category: categories(:books_politics_subject)) { |row| row.source = :admin }
              delete "#{tag_path(segment)}/#{politics_id}", headers: bearer(MERGE)
            }],
            [["DELETE", untag, "400"], -> { delete "#{tag_path(segment)}/0", headers: bearer(MERGE) }],
            [["DELETE", untag, "401"], -> { delete "#{tag_path(segment)}/#{politics_id}" }],
            [["DELETE", untag, "403"], -> { delete "#{tag_path(segment)}/#{politics_id}", headers: bearer(READ) }],
            [["DELETE", untag, "404"], -> { delete "#{tag_path(segment)}/999999999", headers: bearer(MERGE) }],
            [["DELETE", untag, "429"], -> { with_exhausted_limit { delete "#{tag_path(segment)}/#{politics_id}", headers: bearer(MERGE) } }]
          ]
          # Only books have inherited links (ancestor locations), so only books can answer 422.
          if segment == "books"
            entries << [["DELETE", untag, "422"], -> {
              parent = ::Books::Category.create!(name: "Coverage Land", category_type: :location)
              child = ::Books::Category.create!(name: "Coverage Town", category_type: :location, parent: parent)
              ::Categories::ItemLinker.link(item: tag_item(segment), category: child)
              delete "#{tag_path(segment)}/#{parent.id}", headers: bearer(MERGE)
            }]
          end
          entries
        end.to_h
      ).freeze

      def tag_item(segment) = (segment == "books") ? books_books(:war_and_peace) : books_authors(:tolstoy)

      def tag_path(segment, id = tag_item(segment).id) = "/api/v1/admin/#{segment}/#{id}/categories"

      def politics_id = categories(:books_politics_subject).id

      def link_decision(outcome: :matched)
        MatchDecision.create!(
          finder: "Services::Books::Authors::ResolveWikidata", subject: books_authors(:tolstoy), outcome: outcome,
          confidence: :medium, decided_by: :ai, needs_review: true, query: {"name" => "Leo Tolstoy"},
          candidates: [{"external_source" => "wikidata", "external_key" => "Q7243"}],
          selected_index: (outcome == :matched) ? 1 : nil
        )
      end

      setup do
        host! "dev-new.thegreatestbooks.org"
        stub_workflow_dispatch
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
