require "test_helper"

module Api
  module V1
    # The admin document's twin of ContractCoverageTest: every documented
    # response of config/api/v1/admin_openapi.yaml must be reachable and
    # conform. The merge operations are exercised with a dry run for 200, so the shared fixtures survive.
    class AdminContractCoverageTest < ActionDispatch::IntegrationTest
      include BookSubmissionReviewHelper

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
        ["DELETE", "/api/v1/admin/authors/{id}", "200"] => -> { delete "/api/v1/admin/authors/#{::Books::Author.create!(name: "Coverage Empty").id}?dry_run=true", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/authors/{id}", "400"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}?dry_run=maybe", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/authors/{id}", "401"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}" },
        ["DELETE", "/api/v1/admin/authors/{id}", "403"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/authors/{id}", "404"] => -> { delete "/api/v1/admin/authors/999999999", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/authors/{id}", "422"] => -> { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/authors/{id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(MERGE) } },
        ["PATCH", "/api/v1/admin/books/{id}", "200"] => -> { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {subtitle: "A novel"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/books/{id}", "400"] => -> { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {first_published_year: "abc"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/books/{id}", "401"] => -> { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {subtitle: "A novel"}, as: :json },
        ["PATCH", "/api/v1/admin/books/{id}", "403"] => -> { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {subtitle: "A novel"}, as: :json, headers: bearer(READ) },
        ["PATCH", "/api/v1/admin/books/{id}", "404"] => -> { patch "/api/v1/admin/books/999999999", params: {subtitle: "A novel"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/books/{id}", "422"] => -> { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {book_kind: "bogus"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/books/{id}", "429"] => -> { with_exhausted_limit { patch "/api/v1/admin/books/#{books_books(:war_and_peace).id}", params: {subtitle: "A novel"}, as: :json, headers: bearer(MERGE) } },
        ["PATCH", "/api/v1/admin/authors/{id}", "200"] => -> { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {birth_year: 1828}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/authors/{id}", "400"] => -> { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {birth_year: "abc"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/authors/{id}", "401"] => -> { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {birth_year: 1828}, as: :json },
        ["PATCH", "/api/v1/admin/authors/{id}", "403"] => -> { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {birth_year: 1828}, as: :json, headers: bearer(READ) },
        ["PATCH", "/api/v1/admin/authors/{id}", "404"] => -> { patch "/api/v1/admin/authors/999999999", params: {birth_year: 1828}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/authors/{id}", "422"] => -> { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {kind: "bogus"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/authors/{id}", "429"] => -> { with_exhausted_limit { patch "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", params: {birth_year: 1828}, as: :json, headers: bearer(MERGE) } },
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
        ["GET", "/api/v1/admin/repair_verdicts", "200"] => -> { get "/api/v1/admin/repair_verdicts", headers: bearer(READ) },
        ["GET", "/api/v1/admin/repair_verdicts", "400"] => -> { get "/api/v1/admin/repair_verdicts?kind=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/repair_verdicts", "401"] => -> { get "/api/v1/admin/repair_verdicts" },
        ["GET", "/api/v1/admin/repair_verdicts", "403"] => -> { get "/api/v1/admin/repair_verdicts", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/repair_verdicts", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/repair_verdicts", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/repair_verdicts/{id}", "200"] => -> { get "/api/v1/admin/repair_verdicts/#{repair_verdict.id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/repair_verdicts/{id}", "401"] => -> { get "/api/v1/admin/repair_verdicts/#{repair_verdict.id}" },
        ["GET", "/api/v1/admin/repair_verdicts/{id}", "403"] => -> { get "/api/v1/admin/repair_verdicts/#{repair_verdict.id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/repair_verdicts/{id}", "404"] => -> { get "/api/v1/admin/repair_verdicts/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/repair_verdicts/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/repair_verdicts/#{repair_verdict.id}", headers: bearer(READ) } },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "200"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/approve", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "401"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/approve", as: :json },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "403"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/approve", as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "404"] => -> { post "/api/v1/admin/repair_verdicts/999999999/approve", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "422"] => -> { post "/api/v1/admin/repair_verdicts/#{superseded_verdict.id}/approve", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/approve", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/approve", as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "200"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/reject", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "401"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/reject", as: :json },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "403"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/reject", as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "404"] => -> { post "/api/v1/admin/repair_verdicts/999999999/reject", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "422"] => -> { post "/api/v1/admin/repair_verdicts/#{superseded_verdict.id}/reject", as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/reject", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/reject", as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "200"] => -> { post "/api/v1/admin/repair_verdicts/#{match_verdict.id}/correct", params: {create: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "400"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/correct", params: {book_id: "x"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "401"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/correct", as: :json },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "403"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/correct", params: {create: true}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "404"] => -> { post "/api/v1/admin/repair_verdicts/999999999/correct", params: {create: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "422"] => -> { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/correct", params: {create: true}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/{id}/correct", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/repair_verdicts/#{repair_verdict.id}/correct", params: {create: true}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/repair_verdicts/bulk_approve", "200"] => -> { post "/api/v1/admin/repair_verdicts/bulk_approve", params: {ids: [repair_verdict.id]}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/bulk_approve", "400"] => -> { post "/api/v1/admin/repair_verdicts/bulk_approve", params: {ids: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/repair_verdicts/bulk_approve", "401"] => -> { post "/api/v1/admin/repair_verdicts/bulk_approve", params: {ids: [1]}, as: :json },
        ["POST", "/api/v1/admin/repair_verdicts/bulk_approve", "403"] => -> { post "/api/v1/admin/repair_verdicts/bulk_approve", params: {ids: [1]}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/repair_verdicts/bulk_approve", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/repair_verdicts/bulk_approve", params: {ids: [1]}, as: :json, headers: bearer(MERGE) } },
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
        ["GET", "/api/v1/admin/lists", "200"] => -> { get "/api/v1/admin/lists?audit=verified", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists", "400"] => -> { get "/api/v1/admin/lists?status=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists", "401"] => -> { get "/api/v1/admin/lists" },
        ["GET", "/api/v1/admin/lists", "403"] => -> { get "/api/v1/admin/lists", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/lists", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/lists", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/lists/{id}", "200"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists/{id}", "401"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}" },
        ["GET", "/api/v1/admin/lists/{id}", "403"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/lists/{id}", "404"] => -> { get "/api/v1/admin/lists/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/lists/#{lists(:books_list).id}", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/lists/{id}/items", "200"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}/items", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists/{id}/items", "400"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}/items?per_page=0", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists/{id}/items", "401"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}/items" },
        ["GET", "/api/v1/admin/lists/{id}/items", "403"] => -> { get "/api/v1/admin/lists/#{lists(:books_list).id}/items", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/lists/{id}/items", "404"] => -> { get "/api/v1/admin/lists/999999999/items", headers: bearer(READ) },
        ["GET", "/api/v1/admin/lists/{id}/items", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/lists/#{lists(:books_list).id}/items", headers: bearer(READ) } },
        ["PATCH", "/api/v1/admin/lists/{id}", "200"] => -> { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {number_of_voters: 12}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/lists/{id}", "400"] => -> { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {number_of_voters: "12"}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/lists/{id}", "401"] => -> { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {number_of_voters: 12}, as: :json },
        ["PATCH", "/api/v1/admin/lists/{id}", "403"] => -> { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {number_of_voters: 12}, as: :json, headers: bearer(READ) },
        ["PATCH", "/api/v1/admin/lists/{id}", "404"] => -> { patch "/api/v1/admin/lists/999999999", params: {number_of_voters: 12}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/lists/{id}", "422"] => -> { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {num_years_covered: 0}, as: :json, headers: bearer(MERGE) },
        ["PATCH", "/api/v1/admin/lists/{id}", "429"] => -> { with_exhausted_limit { patch "/api/v1/admin/lists/#{lists(:books_list).id}", params: {number_of_voters: 12}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "200"] => -> { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {penalty_id: penalties(:books_one_year_penalty).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "400"] => -> { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "401"] => -> { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {penalty_id: penalties(:books_one_year_penalty).id}, as: :json },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "403"] => -> { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {penalty_id: penalties(:books_one_year_penalty).id}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "404"] => -> { post "/api/v1/admin/lists/999999999/penalties", params: {penalty_id: penalties(:books_one_year_penalty).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "422"] => -> { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {penalty_id: penalties(:dynamic_penalty).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/lists/{id}/penalties", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/lists/#{lists(:books_list).id}/penalties", params: {penalty_id: penalties(:books_one_year_penalty).id}, as: :json, headers: bearer(MERGE) } },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "200"] => -> { delete "/api/v1/admin/lists/#{lists(:books_list).id}/penalties/#{penalties(:books_one_year_penalty).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "400"] => -> { delete "/api/v1/admin/lists/#{lists(:books_list).id}/penalties/0", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "401"] => -> { delete "/api/v1/admin/lists/#{lists(:books_list).id}/penalties/#{penalties(:books_one_year_penalty).id}" },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "403"] => -> { delete "/api/v1/admin/lists/#{lists(:books_list).id}/penalties/#{penalties(:books_one_year_penalty).id}", headers: bearer(READ) },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "404"] => -> { delete "/api/v1/admin/lists/999999999/penalties/#{penalties(:books_one_year_penalty).id}", headers: bearer(MERGE) },
        ["DELETE", "/api/v1/admin/lists/{id}/penalties/{penalty_id}", "429"] => -> { with_exhausted_limit { delete "/api/v1/admin/lists/#{lists(:books_list).id}/penalties/#{penalties(:books_one_year_penalty).id}", headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/fetch_page", "200"] => -> {
          stub_fetch_page
          post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json, headers: bearer(READ)
        },
        ["POST", "/api/v1/admin/fetch_page", "400"] => -> { post "/api/v1/admin/fetch_page", params: {}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/fetch_page", "401"] => -> { post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json },
        ["POST", "/api/v1/admin/fetch_page", "403"] => -> { post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json, headers: bearer(MEMBER) },
        ["POST", "/api/v1/admin/fetch_page", "422"] => -> { post "/api/v1/admin/fetch_page", params: {url: "ftp://example.org/x"}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/fetch_page", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json, headers: bearer(READ) } },
        ["POST", "/api/v1/admin/fetch_page", "502"] => -> {
          stub_fetch_page(PageFetcher::Exceptions::UpstreamError.new("upstream_unreachable", 502, nil, error_code: "upstream_unreachable"))
          post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json, headers: bearer(READ)
        },
        ["POST", "/api/v1/admin/fetch_page", "503"] => -> {
          stub_fetch_page(PageFetcher::Exceptions::CircuitOpenError.new("open"))
          post "/api/v1/admin/fetch_page", params: {url: "https://example.org/x"}, as: :json, headers: bearer(READ)
        },
        ["POST", "/api/v1/admin/list_audits", "200"] => -> { post "/api/v1/admin/list_audits", params: {list_id: coverage_list.id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits", "400"] => -> { post "/api/v1/admin/list_audits", params: {list_id: "x"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits", "401"] => -> { post "/api/v1/admin/list_audits", params: {}, as: :json },
        ["POST", "/api/v1/admin/list_audits", "403"] => -> { post "/api/v1/admin/list_audits", params: {}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/list_audits", "404"] => -> { post "/api/v1/admin/list_audits", params: {list_id: 999999999}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits", "409"] => -> { post "/api/v1/admin/list_audits", params: {list_id: coverage_list(held_by: users(:regular_user)).id}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits", "422"] => -> { post "/api/v1/admin/list_audits", params: {extra: 1}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/list_audits", params: {}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "200"] => -> { post "/api/v1/admin/list_audits/#{coverage_audit.id}/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "400"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/finish", params: {}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "401"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "403"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "404"] => -> { post "/api/v1/admin/list_audits/999999999/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "409"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "422"] => -> { post "/api/v1/admin/list_audits/#{coverage_audit.id}/finish", params: {verdict: "verified", note: "Checked", sources: []}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/finish", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/finish", params: {verdict: "unverifiable", note: "Checked", sources: []}, as: :json, headers: bearer(MERGE) } },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "200"] => -> { post "/api/v1/admin/list_audits/#{coverage_audit.id}/release", params: {note: "later"}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "400"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {note: 3}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "401"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {}, as: :json },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "403"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {}, as: :json, headers: bearer(READ) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "404"] => -> { post "/api/v1/admin/list_audits/999999999/release", params: {}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "409"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "422"] => -> { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {extra: 1}, as: :json, headers: bearer(MERGE) },
        ["POST", "/api/v1/admin/list_audits/{id}/release", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/list_audits/#{list_audits(:books_verified_audit).id}/release", params: {}, as: :json, headers: bearer(MERGE) } },
        ["GET", "/api/v1/admin/penalties", "200"] => -> { get "/api/v1/admin/penalties", headers: bearer(READ) },
        ["GET", "/api/v1/admin/penalties", "401"] => -> { get "/api/v1/admin/penalties" },
        ["GET", "/api/v1/admin/penalties", "403"] => -> { get "/api/v1/admin/penalties", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/penalties", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/penalties", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/series", "200"] => -> { get "/api/v1/admin/series?q=song", headers: bearer(READ) },
        ["GET", "/api/v1/admin/series", "400"] => -> { get "/api/v1/admin/series?sort=bogus", headers: bearer(READ) },
        ["GET", "/api/v1/admin/series", "401"] => -> { get "/api/v1/admin/series" },
        ["GET", "/api/v1/admin/series", "403"] => -> { get "/api/v1/admin/series", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/series", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/series", headers: bearer(READ) } },
        ["GET", "/api/v1/admin/series/{id}", "200"] => -> { get "/api/v1/admin/series/#{books_series(:asoiaf).id}", headers: bearer(READ) },
        ["GET", "/api/v1/admin/series/{id}", "401"] => -> { get "/api/v1/admin/series/#{books_series(:asoiaf).id}" },
        ["GET", "/api/v1/admin/series/{id}", "403"] => -> { get "/api/v1/admin/series/#{books_series(:asoiaf).id}", headers: bearer(MEMBER) },
        ["GET", "/api/v1/admin/series/{id}", "404"] => -> { get "/api/v1/admin/series/999999999", headers: bearer(READ) },
        ["GET", "/api/v1/admin/series/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/series/#{books_series(:asoiaf).id}", headers: bearer(READ) } },
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
      ).merge(
        {
          ["POST", "/api/v1/admin/books/{id}/authors", "200"] => -> { post author_rows_path, params: {author_id: books_authors(:king).id}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/books/{id}/authors", "400"] => -> { post author_rows_path, params: {author_id: "abc"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/books/{id}/authors", "401"] => -> { post author_rows_path, params: {author_id: books_authors(:king).id}, as: :json },
          ["POST", "/api/v1/admin/books/{id}/authors", "403"] => -> { post author_rows_path, params: {author_id: books_authors(:king).id}, as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/books/{id}/authors", "404"] => -> { post author_rows_path(999_999_999), params: {author_id: books_authors(:king).id}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/books/{id}/authors", "422"] => -> { post author_rows_path, params: {author_id: books_authors(:tolstoy).id}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/books/{id}/authors", "429"] => -> { with_exhausted_limit { post author_rows_path, params: {author_id: books_authors(:king).id}, as: :json, headers: bearer(MERGE) } },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "200"] => -> { patch author_row_path, params: {role: "editor"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "400"] => -> { patch author_row_path, params: {role: 0}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "401"] => -> { patch author_row_path, params: {role: "editor"}, as: :json },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "403"] => -> { patch author_row_path, params: {role: "editor"}, as: :json, headers: bearer(READ) },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "404"] => -> { patch author_row_path(author_id: 999_999_999), params: {role: "editor"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "422"] => -> { patch author_row_path, params: {role: "translator"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/books/{id}/authors/{author_id}", "429"] => -> { with_exhausted_limit { patch author_row_path, params: {role: "editor"}, as: :json, headers: bearer(MERGE) } },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "200"] => -> { delete author_row_path, headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "400"] => -> { delete author_row_path(author_id: 0), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "401"] => -> { delete author_row_path },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "403"] => -> { delete author_row_path, headers: bearer(READ) },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "404"] => -> { delete author_row_path(author_id: 999_999_999), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/books/{id}/authors/{author_id}", "429"] => -> { with_exhausted_limit { delete author_row_path, headers: bearer(MERGE) } }
        }
      ).merge(
        {
          ["POST", "/api/v1/admin/authors", "201"] => -> { post "/api/v1/admin/authors", params: {name: "Coverage Author"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/authors", "400"] => -> { post "/api/v1/admin/authors", params: {birth_year: 1900}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/authors", "401"] => -> { post "/api/v1/admin/authors", params: {name: "X"}, as: :json },
          ["POST", "/api/v1/admin/authors", "403"] => -> { post "/api/v1/admin/authors", params: {name: "X"}, as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/authors", "409"] => -> {
            books_authors(:tolstoy).identifiers.create!(identifier_type: :books_author_wikidata_qid, value: "Q9000001", source: :admin)
            post "/api/v1/admin/authors", params: {name: "Coverage Twin", wikidata_qid: "Q9000001"}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/authors", "422"] => -> { post "/api/v1/admin/authors", params: {name: "   "}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/authors", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/authors", params: {name: "X"}, as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/series", "201"] => -> { post "/api/v1/admin/series", params: {title: "Coverage Saga", goodreads_series_id: "9000001"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series", "400"] => -> { post "/api/v1/admin/series", params: {title: 5}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series", "401"] => -> { post "/api/v1/admin/series", params: {title: "X"}, as: :json },
          ["POST", "/api/v1/admin/series", "403"] => -> { post "/api/v1/admin/series", params: {title: "X"}, as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/series", "422"] => -> {
            Identifier.create!(identifiable: books_series(:junk_deleted), identifier_type: :books_series_goodreads_id, value: "9000002", source: :admin)
            post "/api/v1/admin/series", params: {title: "Claims A Deleted Id", goodreads_series_id: "9000002"}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/series", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/series", params: {title: "X"}, as: :json, headers: bearer(MERGE) } },
          ["PATCH", "/api/v1/admin/series/{id}", "200"] => -> { patch series_path, params: {title: "Renamed Saga"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}", "400"] => -> { patch series_path, params: {}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}", "401"] => -> { patch series_path, params: {title: "X"}, as: :json },
          ["PATCH", "/api/v1/admin/series/{id}", "403"] => -> { patch series_path, params: {title: "X"}, as: :json, headers: bearer(READ) },
          ["PATCH", "/api/v1/admin/series/{id}", "404"] => -> { patch series_path(999_999_999), params: {title: "X"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}", "422"] => -> { patch series_path(books_series(:junk_deleted).id), params: {title: "X"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}", "429"] => -> { with_exhausted_limit { patch series_path, params: {title: "X"}, as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/series/{id}/merge", "200"] => -> { post "#{series_path}/merge", params: {source_ids: [books_series(:live_target).id], dry_run: true}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/merge", "400"] => -> { post "#{series_path}/merge", params: {source_ids: []}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/merge", "401"] => -> { post "#{series_path}/merge", params: {source_ids: [1]}, as: :json },
          ["POST", "/api/v1/admin/series/{id}/merge", "403"] => -> { post "#{series_path}/merge", params: {source_ids: [1]}, as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/series/{id}/merge", "404"] => -> { post "#{series_path}/merge", params: {source_ids: [999_999_999]}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/merge", "422"] => -> { post "#{series_path}/merge", params: {source_ids: [books_series(:junk_deleted).id]}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/merge", "429"] => -> { with_exhausted_limit { post "#{series_path}/merge", params: {source_ids: [1]}, as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/series/{id}/books", "200"] => -> { post "#{series_path}/books", params: {book_id: books_books(:war_and_peace).id, position: 3.5}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/books", "400"] => -> { post "#{series_path}/books", params: {}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/books", "401"] => -> { post "#{series_path}/books", params: {book_id: 1}, as: :json },
          ["POST", "/api/v1/admin/series/{id}/books", "403"] => -> { post "#{series_path}/books", params: {book_id: 1}, as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/series/{id}/books", "404"] => -> { post "#{series_path(999_999_999)}/books", params: {book_id: 1}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/books", "422"] => -> { post "#{series_path}/books", params: {book_id: books_books(:got).id}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/series/{id}/books", "429"] => -> { with_exhausted_limit { post "#{series_path}/books", params: {book_id: 1}, as: :json, headers: bearer(MERGE) } },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "200"] => -> { patch series_book_path, params: {position: 2, position_label: "Book Two"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "400"] => -> { patch series_book_path, params: {position: "2"}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "401"] => -> { patch series_book_path, params: {position: 2}, as: :json },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "403"] => -> { patch series_book_path, params: {position: 2}, as: :json, headers: bearer(READ) },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "404"] => -> { patch series_book_path(book_id: books_books(:of_mice_and_men).id), params: {position: 2}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "422"] => -> { patch series_book_path(books_series(:junk_deleted).id), params: {position: 2}, as: :json, headers: bearer(MERGE) },
          ["PATCH", "/api/v1/admin/series/{id}/books/{book_id}", "429"] => -> { with_exhausted_limit { patch series_book_path, params: {position: 2}, as: :json, headers: bearer(MERGE) } },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "200"] => -> { delete series_book_path, headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "400"] => -> { delete series_book_path(book_id: 0), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "401"] => -> { delete series_book_path },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "403"] => -> { delete series_book_path, headers: bearer(READ) },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "404"] => -> { delete series_book_path(book_id: books_books(:of_mice_and_men).id), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "422"] => -> { delete series_book_path(books_series(:junk_deleted).id), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}/books/{book_id}", "429"] => -> { with_exhausted_limit { delete series_book_path, headers: bearer(MERGE) } },
          ["DELETE", "/api/v1/admin/series/{id}", "200"] => -> { delete "#{series_path}?dry_run=true", headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}", "400"] => -> { delete "#{series_path}?dry_run=maybe", headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}", "401"] => -> { delete series_path },
          ["DELETE", "/api/v1/admin/series/{id}", "403"] => -> { delete series_path, headers: bearer(READ) },
          ["DELETE", "/api/v1/admin/series/{id}", "404"] => -> { delete series_path(999_999_999), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}", "422"] => -> { delete series_path(books_series(:junk_deleted).id), headers: bearer(MERGE) },
          ["DELETE", "/api/v1/admin/series/{id}", "429"] => -> { with_exhausted_limit { delete series_path, headers: bearer(MERGE) } }
        }
      ).merge(
        {
          ["GET", "/api/v1/admin/enrichment_queues", "200"] => -> { get "/api/v1/admin/enrichment_queues", headers: bearer(READ) },
          ["GET", "/api/v1/admin/enrichment_queues", "401"] => -> { get "/api/v1/admin/enrichment_queues" },
          ["GET", "/api/v1/admin/enrichment_queues", "403"] => -> { get "/api/v1/admin/enrichment_queues", headers: bearer(MEMBER) },
          ["GET", "/api/v1/admin/enrichment_queues", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/enrichment_queues", headers: bearer(READ) } },
          ["GET", "/api/v1/admin/enrichment_queues/{type}", "200"] => -> { get "/api/v1/admin/enrichment_queues/origin", headers: bearer(READ) },
          ["GET", "/api/v1/admin/enrichment_queues/{type}", "401"] => -> { get "/api/v1/admin/enrichment_queues/origin" },
          ["GET", "/api/v1/admin/enrichment_queues/{type}", "403"] => -> { get "/api/v1/admin/enrichment_queues/origin", headers: bearer(MEMBER) },
          ["GET", "/api/v1/admin/enrichment_queues/{type}", "404"] => -> { get "/api/v1/admin/enrichment_queues/nope", headers: bearer(READ) },
          ["GET", "/api/v1/admin/enrichment_queues/{type}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/enrichment_queues/origin", headers: bearer(READ) } },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "200"] => -> {
            enrichment_row
            post "/api/v1/admin/enrichment_queues/origin/claims", params: {limit: 1}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "400"] => -> { post "/api/v1/admin/enrichment_queues/origin/claims", params: {limit: 26}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "401"] => -> { post "/api/v1/admin/enrichment_queues/origin/claims", as: :json },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "403"] => -> { post "/api/v1/admin/enrichment_queues/origin/claims", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "404"] => -> { post "/api/v1/admin/enrichment_queues/nope/claims", as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/enrichment_queues/{type}/claims", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/enrichment_queues/origin/claims", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "202"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/submit", params: enrichment_submission(token), as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "400"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/submit", params: enrichment_submission(token).merge(answer: "x"), as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "401"] => -> { post "/api/v1/admin/enrichment_items/1/submit", as: :json },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "403"] => -> { post "/api/v1/admin/enrichment_items/1/submit", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "404"] => -> { post "/api/v1/admin/enrichment_items/999999999/submit", params: enrichment_submission("t"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "409"] => -> {
            row, = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/submit", params: enrichment_submission("not-the-token"), as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "422"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/submit", params: enrichment_submission(token).merge(sources: []), as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/submit", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/enrichment_items/1/submit", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "200"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/skip", params: {lease_token: token, reason: "Nothing found"}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "400"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/skip", params: {lease_token: token, reason: 5}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "401"] => -> { post "/api/v1/admin/enrichment_items/1/skip", as: :json },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "403"] => -> { post "/api/v1/admin/enrichment_items/1/skip", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "404"] => -> { post "/api/v1/admin/enrichment_items/999999999/skip", params: {lease_token: "t", reason: "r"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "409"] => -> {
            row, = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/skip", params: {lease_token: "not-the-token", reason: "r"}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "422"] => -> {
            row, token = enrichment_row
            post "/api/v1/admin/enrichment_items/#{row.id}/skip", params: {lease_token: token, reason: " "}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/enrichment_items/{id}/skip", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/enrichment_items/1/skip", as: :json, headers: bearer(MERGE) } },
          ["GET", "/api/v1/admin/book_submissions", "200"] => -> { get "/api/v1/admin/book_submissions", headers: bearer(READ) },
          ["GET", "/api/v1/admin/book_submissions", "400"] => -> { get "/api/v1/admin/book_submissions?review_status=bogus", headers: bearer(READ) },
          ["GET", "/api/v1/admin/book_submissions", "401"] => -> { get "/api/v1/admin/book_submissions" },
          ["GET", "/api/v1/admin/book_submissions", "403"] => -> { get "/api/v1/admin/book_submissions", headers: bearer(MEMBER) },
          ["GET", "/api/v1/admin/book_submissions", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/book_submissions", headers: bearer(READ) } },
          ["GET", "/api/v1/admin/book_submissions/{id}", "200"] => -> { get "/api/v1/admin/book_submissions/#{submission_row.id}", headers: bearer(READ) },
          ["GET", "/api/v1/admin/book_submissions/{id}", "401"] => -> { get "/api/v1/admin/book_submissions/1" },
          ["GET", "/api/v1/admin/book_submissions/{id}", "403"] => -> { get "/api/v1/admin/book_submissions/1", headers: bearer(MEMBER) },
          ["GET", "/api/v1/admin/book_submissions/{id}", "404"] => -> { get "/api/v1/admin/book_submissions/999999999", headers: bearer(READ) },
          ["GET", "/api/v1/admin/book_submissions/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/admin/book_submissions/1", headers: bearer(READ) } },
          ["POST", "/api/v1/admin/book_submissions/claims", "200"] => -> {
            submission_row(leased: false)
            post "/api/v1/admin/book_submissions/claims", params: {limit: 1}, as: :json, headers: bearer(MERGE)
          },
          ["POST", "/api/v1/admin/book_submissions/claims", "400"] => -> { post "/api/v1/admin/book_submissions/claims", params: {limit: 26}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/claims", "401"] => -> { post "/api/v1/admin/book_submissions/claims", as: :json },
          ["POST", "/api/v1/admin/book_submissions/claims", "403"] => -> { post "/api/v1/admin/book_submissions/claims", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/claims", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/claims", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "200"] => -> { post "/api/v1/admin/book_submissions/#{details_row.id}/details", params: {lease_token: BookSubmissionReviewHelper::TOKEN, title: "Coverage Book", author_names: ["Coverage Author"], note: "Found it"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "400"] => -> { post "/api/v1/admin/book_submissions/#{details_row.id}/details", params: {lease_token: BookSubmissionReviewHelper::TOKEN, title: 5, author_names: [], note: "n"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "401"] => -> { post "/api/v1/admin/book_submissions/1/details", as: :json },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "403"] => -> { post "/api/v1/admin/book_submissions/1/details", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "404"] => -> { post "/api/v1/admin/book_submissions/999999999/details", params: {lease_token: BookSubmissionReviewHelper::TOKEN, title: "Coverage Book", author_names: ["Coverage Author"], note: "Found it"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "409"] => -> { post "/api/v1/admin/book_submissions/#{details_row.id}/details", params: {lease_token: BookSubmissionReviewHelper::TOKEN, title: "Coverage Book", author_names: ["Coverage Author"], note: "Found it"}.merge(lease_token: "not-the-token"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "422"] => -> { post "/api/v1/admin/book_submissions/#{details_row.id}/details", params: {lease_token: BookSubmissionReviewHelper::TOKEN, title: "Coverage Book", author_names: ["Coverage Author"], note: "Found it"}.merge({title: " "}), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/details", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/1/details", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "200"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/skip", params: {lease_token: BookSubmissionReviewHelper::TOKEN, reason: "Cannot show it is real"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "400"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/skip", params: {lease_token: BookSubmissionReviewHelper::TOKEN, reason: 5}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "401"] => -> { post "/api/v1/admin/book_submissions/1/skip", as: :json },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "403"] => -> { post "/api/v1/admin/book_submissions/1/skip", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "404"] => -> { post "/api/v1/admin/book_submissions/999999999/skip", params: {lease_token: BookSubmissionReviewHelper::TOKEN, reason: "Cannot show it is real"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "409"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/skip", params: {lease_token: BookSubmissionReviewHelper::TOKEN, reason: "Cannot show it is real"}.merge(lease_token: "not-the-token"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "422"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/skip", params: {lease_token: BookSubmissionReviewHelper::TOKEN, reason: "Cannot show it is real"}.merge({reason: " "}), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/skip", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/1/skip", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "200"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/approve", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"]}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "400"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/approve", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "n", sources: "x"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "401"] => -> { post "/api/v1/admin/book_submissions/1/approve", as: :json },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "403"] => -> { post "/api/v1/admin/book_submissions/1/approve", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "404"] => -> { post "/api/v1/admin/book_submissions/999999999/approve", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"]}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "409"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/approve", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"]}.merge(lease_token: "not-the-token"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "422"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/approve", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"]}.merge({sources: []}), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/approve", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/1/approve", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "200"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/merge", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], target_id: ::Books::Book.create!(title: "Coverage Catalog Copy").id, dry_run: true}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "400"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/merge", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], target_id: 1, dry_run: "yes"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "401"] => -> { post "/api/v1/admin/book_submissions/1/merge", as: :json },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "403"] => -> { post "/api/v1/admin/book_submissions/1/merge", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "404"] => -> { post "/api/v1/admin/book_submissions/999999999/merge", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], target_id: ::Books::Book.create!(title: "Coverage Catalog Copy").id, dry_run: true}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "409"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/merge", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], target_id: ::Books::Book.create!(title: "Coverage Catalog Copy").id, dry_run: true}.merge(lease_token: "not-the-token"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "422"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/merge", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], target_id: ::Books::Book.create!(title: "Coverage Catalog Copy").id, dry_run: true}.merge({target_id: 999_999_999}), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/merge", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/1/merge", as: :json, headers: bearer(MERGE) } },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "200"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/reject", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], dry_run: true}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "400"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/reject", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], dry_run: "yes"}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "401"] => -> { post "/api/v1/admin/book_submissions/1/reject", as: :json },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "403"] => -> { post "/api/v1/admin/book_submissions/1/reject", as: :json, headers: bearer(READ) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "404"] => -> { post "/api/v1/admin/book_submissions/999999999/reject", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], dry_run: true}, as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "409"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/reject", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], dry_run: true}.merge(lease_token: "not-the-token"), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "422"] => -> { post "/api/v1/admin/book_submissions/#{submission_row.id}/reject", params: {lease_token: BookSubmissionReviewHelper::TOKEN, note: "Found it", sources: ["https://example.org/proof"], dry_run: true}.merge({sources: []}), as: :json, headers: bearer(MERGE) },
          ["POST", "/api/v1/admin/book_submissions/{id}/reject", "429"] => -> { with_exhausted_limit { post "/api/v1/admin/book_submissions/1/reject", as: :json, headers: bearer(MERGE) } }
        }
      ).freeze

      # A countryless book with a pending books.origin row, claimed under a fresh lease: [row, lease_token].
      def enrichment_row
        book = ::Books::Book.create!(title: "Coverage Countryless")
        row = ::EnrichmentRequest.create!(enrichable: book, kind: "books.origin", reason: "missing")
        token = Services::EnrichmentQueue::Claim.call(kind: "books.origin", user: users(:admin_user), limit: 25).data[:lease_token]
        [row, token]
      end

      def enrichment_submission(token)
        {lease_token: token, sources: ["https://example.org/a"],
         answer: {recognized: true, original_language: "Japanese", nationality: "Japanese", confidence: "high", reason: "Stated by a source"}}
      end

      # A reviewable user-added book (provisional, one provisional author) of the reader, leased to the admin the
      # MERGE token belongs to under BookSubmissionReviewHelper::TOKEN, or unleased for a claim. The purge jobs a
      # promotion, merge or delete would queue are stubbed: they reach for the Cloudflare zone.
      def submission_row(leased: true)
        stub_review_side_effects
        row = reviewable_submission(user: users(:regular_user))
        leased ? lease(row) : row
      end

      # A request that found no book, leased the same way.
      def details_row
        stub_review_side_effects
        ::Books::BookSubmission.create!(
          user: users(:regular_user), user_list: user_lists(:regular_user_books_read), input_method: :title_authors, typed_title: "Coverage Lost Book",
          typed_author_names: ["Nobody"], status: :needs_details, review_status: :not_needed,
          lease_token: BookSubmissionReviewHelper::TOKEN, lease_expires_at: 30.minutes.from_now, claimed_by_id: users(:admin_user).id
        )
      end

      def series_path(id = books_series(:asoiaf).id) = "/api/v1/admin/series/#{id}"

      def series_book_path(id = books_series(:asoiaf).id, book_id: books_books(:got).id) = "#{series_path(id)}/books/#{book_id}"

      def author_rows_path(id = books_books(:war_and_peace).id) = "/api/v1/admin/books/#{id}/authors"

      def author_row_path(author_id: books_authors(:tolstoy).id) = "#{author_rows_path}/#{author_id}"

      def tag_item(segment) = (segment == "books") ? books_books(:war_and_peace) : books_authors(:tolstoy)

      def tag_path(segment, id = tag_item(segment).id) = "/api/v1/admin/#{segment}/#{id}/categories"

      def politics_id = categories(:books_politics_subject).id

      def superseded_verdict
        ::Books::RepairVerdict.find_or_create_by!(kind: :relink, subject_key: "coverage:superseded") do |verdict|
          verdict.decided_by = :rule
          verdict.superseded_at = Time.current
        end
      end

      def match_verdict
        ::Books::RepairVerdict.find_or_create_by!(kind: :reimport_match, subject_key: "coverage:match") do |verdict|
          verdict.decided_by = :ai
          verdict.payload = {"outcome" => "matched", "book_id" => books_books(:war_and_peace).id}
        end
      end

      def repair_verdict
        ::Books::RepairVerdict.find_or_create_by!(kind: :merge_books, subject_key: "coverage:merge") do |verdict|
          verdict.decided_by = :rule
          verdict.payload = {"source_id" => books_books(:crime_and_punishment).id, "target_id" => books_books(:war_and_peace).id}
        end
      end

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

      # The page fetcher is never called for real: a Page, or the error to raise.
      def stub_fetch_page(error = nil)
        if error
          PageFetcher::Client.any_instance.stubs(:fetch).raises(error)
        else
          page = PageFetcher::Page.new(url: "https://example.org/x", final_url: "https://example.org/x", status: 200, title: "T",
            html: "<html><body><h2>Hi</h2></body></html>", selector_found: nil, elapsed_ms: 1, fetched_at: Time.current)
          PageFetcher::Client.any_instance.stubs(:fetch).returns(page)
        end
      end

      # A books list nobody has audited, optionally already held by someone else.
      def coverage_list(held_by: nil)
        list = ::Books::List.create!(name: "Coverage Audit #{SecureRandom.hex(4)}", status: :active)
        if held_by
          ListAudit.create!(list: list, user: held_by, status: :in_progress, started_at: Time.current, lease_expires_at: 1.hour.from_now)
        end
        list
      end

      # An open audit held by the admin the MERGE token belongs to.
      def coverage_audit
        ListAudit.create!(list: (list = coverage_list), before: ::Services::Lists::Audits::Snapshot.call(list), user: users(:admin_user), status: :in_progress, started_at: Time.current, lease_expires_at: 1.hour.from_now)
      end

      test "the map and the document describe the same responses" do
        documented = OpenapiFirst::Test[:admin].routes.to_a.flat_map do |route|
          route.responses.to_a.map { |resp| [route.request_method, route.path, resp.status.to_s] }
        end.uniq

        assert_equal documented.sort, EXERCISES.keys.sort,
          "documented responses and EXERCISES disagree -- add the missing entry to whichever side lacks it"
      end

      test "every documented response is reachable and conforms" do
        EXERCISES.each_with_index do |((_method, _path, status), exercise), index|
          # The admin tier allows 600 requests a minute per user and the map now
          # sends more than that; start a fresh window every 100 exercises.
          Rails.application.config.x.rate_limit_store.clear if (index % 100).zero?
          instance_exec(&exercise)
          assert_api_response_conform(status: Integer(status), api: :admin)
        end
      end
    end
  end
end
