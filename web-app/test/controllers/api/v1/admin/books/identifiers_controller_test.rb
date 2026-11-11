require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class IdentifiersControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @book = books_books(:war_and_peace)
            @other_book = books_books(:crime_and_punishment)
            @edition = books_editions(:wp_maude)
            @author = books_authors(:tolstoy)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def get_json(path, params = {}, token: ApiTokenSecrets::ADMIN_READ)
            get path, params: params, headers: bearer(token)
          end

          def rows = json[:data]

          def add(holder, type, value, source: nil)
            Identifier.create!(identifiable: holder, identifier_type: type, value: value, source: source)
          end

          test "a book's identifiers list its own rows first, then its editions' by edition id" do
            later_edition = books_editions(:wp_volume_one)
            late = add(later_edition, :books_edition_isbn13, "9780000000002")
            early = add(@edition, :books_edition_isbn13, "9780000000001", source: :open_library)
            own = Identifier.where(identifiable: @book).order(:id).pluck(:id)
            expected_tail = [early, late].sort_by { |row| row.identifiable_id }.map(&:id)

            get_json "/api/v1/admin/books/#{@book.id}/identifiers"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal own + expected_tail, rows.map { |row| row[:id] }
            assert_nil rows.first[:edition]
            edition_row = rows.find { |row| row[:id] == early.id }
            assert_equal({id: @edition.id, title: "War and Peace", edition_type: "standard", publication_year: 1990}, edition_row[:edition])
            assert_equal "books_edition_isbn13", edition_row[:identifier_type]
            assert_equal "open_library", edition_row[:source]
          end

          test "scope=work returns only the book's own rows" do
            add(@edition, :books_edition_isbn13, "9780000000001")

            get_json "/api/v1/admin/books/#{@book.id}/identifiers", {scope: "work"}
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal Identifier.where(identifiable: @book).count, rows.size
            assert(rows.all? { |row| row[:edition].nil? })
          end

          test "a bad scope is a 400" do
            get_json "/api/v1/admin/books/#{@book.id}/identifiers", {scope: "everything"}
            assert_response :bad_request
          end

          test "rows page across own and edition identifiers without repeats or gaps" do
            3.times { |i| add(@edition, :books_edition_isbn13, "97800000010#{i}") }
            expected = Identifier.where(identifiable: @book).order(:id).pluck(:id) +
              Identifier.where(identifiable: @edition).order(:id).pluck(:id)
            seen = []
            (1..4).each do |page|
              get_json "/api/v1/admin/books/#{@book.id}/identifiers", {per_page: 2, page: page}
              assert_response :success
              seen.concat(rows.map { |row| row[:id] })
            end

            assert_equal expected.size, json[:meta][:total_count]
            assert_equal expected, seen
          end

          test "an author's identifiers" do
            qid = add(@author, :books_author_wikidata_qid, "Q7243", source: :wikidata)

            get_json "/api/v1/admin/authors/#{@author.id}/identifiers"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [qid.id], rows.map { |row| row[:id] }
            assert_equal "Q7243", rows.first[:value]
            assert_nil rows.first[:edition]
          end

          test "an unknown book or author is a 404" do
            get_json "/api/v1/admin/books/999999999/identifiers"
            assert_api_response_conform(status: 404, api: :admin)
            get_json "/api/v1/admin/authors/999999999/identifiers"
            assert_response :not_found
          end

          test "find returns every holder of an ISBN with its book" do
            other_edition = books_editions(:wp_volume_one)
            other_edition.update_columns(book_id: @other_book.id)
            first = add(@edition, :books_edition_isbn13, "9781111111111")
            second = add(other_edition, :books_edition_isbn13, "9781111111111")

            get_json "/api/v1/admin/identifiers", {type: "books_edition_isbn13", value: " 9781111111111 "}
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [first.identifiable_id, second.identifiable_id], rows.map { |row| row[:id] }
            assert_equal %w[edition edition], rows.map { |row| row[:record_type] }
            assert_equal [{id: @book.id, title: @book.title}, {id: @other_book.id, title: @other_book.title}],
              rows.map { |row| row[:book] }
            assert_equal "War and Peace", rows.first[:label]
          end

          test "find by an author QID" do
            add(@author, :books_author_wikidata_qid, "Q7243")

            get_json "/api/v1/admin/identifiers", {type: "books_author_wikidata_qid", value: "Q7243"}

            assert_equal [{record_type: "author", id: @author.id, label: @author.name, book: nil}], rows
          end

          test "find with no match is an empty list" do
            get_json "/api/v1/admin/identifiers", {type: "books_author_viaf", value: "nope"}
            assert_response :success
            assert_empty rows
          end

          test "find refuses a non-books type, a missing type and a missing value" do
            get_json "/api/v1/admin/identifiers", {type: "music_discogs_release_id", value: "1"}
            assert_api_response_conform(status: 400, api: :admin)
            get_json "/api/v1/admin/identifiers", {value: "1"}
            assert_response :bad_request
            get_json "/api/v1/admin/identifiers", {type: "books_author_viaf"}
            assert_response :bad_request
            get_json "/api/v1/admin/identifiers", {type: "books_author_viaf", value: "  "}
            assert_response :bad_request
          end

          test "find caps its holders at 100 and says so" do
            101.times { |i| add(::Books::Author.create!(name: "Holder #{i}"), :books_author_viaf, "4242") }

            get_json "/api/v1/admin/identifiers", {type: "books_author_viaf", value: "4242"}
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 100, rows.size
            assert json[:truncated]
          end

          test "find under the cap is not truncated" do
            add(@author, :books_author_viaf, "4242")

            get_json "/api/v1/admin/identifiers", {type: "books_author_viaf", value: "4242"}

            assert_equal 1, rows.size
            assert_equal false, json[:truncated]
          end

          test "the documented identifier_type enums are the books identifier types in code" do
            document = ::Api::OpenapiDocument.raw(:admin)
            schemas = document.dig("components", "schemas")
            lookup_type = document.dig("paths", "/api/v1/admin/identifiers", "get", "parameters")
              .find { |parameter| parameter["name"] == "type" }.dig("schema", "enum")

            assert_equal ::Services::Books::Identifiers::AdminWrite::IDENTIFIER_TYPES, lookup_type
            assert_equal ::Services::Books::Identifiers::AdminWrite::IDENTIFIER_TYPES, schemas.dig("AdminIdentifier", "properties", "identifier_type", "enum")
            assert_equal ::Services::Books::Identifiers::AdminWrite::BOOK_TYPES, schemas.dig("BookIdentifierRequest", "properties", "identifier_type", "enum")
            assert_equal ::Services::Books::Identifiers::AdminWrite::AUTHOR_TYPES, schemas.dig("AuthorIdentifierRequest", "properties", "identifier_type", "enum")
          end

          test "a token without admin scope is refused" do
            get_json "/api/v1/admin/books/#{@book.id}/identifiers", {}, token: ApiTokenSecrets::MEMBER
            assert_response :forbidden
          end

          # ---- writes -------------------------------------------------------

          def write_token
            @write_token ||= begin
              user = User.create!(email: "identifier-editor@example.com", name: "Identifier Editor")
              user.domain_roles.create!(domain: :books, permission_level: :editor)
              ::Services::Api::Tokens.generate(user: user, name: "writer", scopes: ["books:admin:write"], expires_at: 30.days.from_now).data[:secret]
            end
          end

          def post_identifier(path, body, token: write_token) = post(path, params: body, as: :json, headers: bearer(token))

          def delete_identifier(path, token: ApiTokenSecrets::ADMIN) = delete(path, headers: bearer(token))

          test "adding a book identifier is 201 with the admin row" do
            post_identifier "/api/v1/admin/books/#{@book.id}/identifiers", {identifier_type: "books_work_isbn10", value: "0-306-40615-2"}
            assert_api_response_conform(status: 201, api: :admin)

            row = Identifier.find(json[:data][:id])
            assert_equal [@book, "books_work_isbn10", "0306406152", "admin"], [row.identifiable, row.identifier_type, row.value, row.source]
            assert_equal "0306406152", json[:data][:value]
            assert_equal [], json[:also_held_by]
            assert_equal false, json[:truncated]
          end

          test "adding a value the book already holds is 200 with the existing row" do
            existing = identifiers(:war_and_peace_isbn13)

            assert_no_difference -> { Identifier.count } do
              post_identifier "/api/v1/admin/books/#{@book.id}/identifiers", {identifier_type: "books_work_isbn13", value: existing.value}
            end
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal existing.id, json[:data][:id]
          end

          test "the response lists other records holding the same value" do
            add(@other_book, :books_work_isbn10, "0306406152")

            post_identifier "/api/v1/admin/books/#{@book.id}/identifiers", {identifier_type: "books_work_isbn10", value: "0306406152"}
            assert_response :created

            assert_equal [{record_type: "book", id: @other_book.id, label: @other_book.title, book: nil}], json[:also_held_by]
          end

          test "adding an author QID is 201 and starts the enrichment re-run" do
            ::Workflows::Books::AuthorEnrichment.expects(:start)
              .with(@author, initiated_by: "admin_identifier", options: {refresh: true}, supersede: true).once

            post_identifier "/api/v1/admin/authors/#{@author.id}/identifiers", {identifier_type: "books_author_wikidata_qid", value: "q7243"}
            assert_api_response_conform(status: 201, api: :admin)
            assert_equal "Q7243", json[:data][:value]
          end

          test "a bad type or value is a 400 naming the expected form" do
            post_identifier "/api/v1/admin/books/#{@book.id}/identifiers", {identifier_type: "books_author_viaf", value: "1"}
            assert_api_response_conform(status: 400, api: :admin)
            assert_match "books_work_", json[:detail]

            post_identifier "/api/v1/admin/authors/#{@author.id}/identifiers", {identifier_type: "books_author_wikidata_qid", value: "7243"}
            assert_response :bad_request
            assert_match "Q followed by digits", json[:detail]

            post_identifier "/api/v1/admin/authors/#{@author.id}/identifiers", {identifier_type: "books_author_viaf", value: ["1"]}
            assert_response :bad_request
            post_identifier "/api/v1/admin/authors/#{@author.id}/identifiers", {value: "1"}
            assert_response :bad_request
          end

          test "a second author QID is a 422 that says to remove the first" do
            add(@author, :books_author_wikidata_qid, "Q1", source: :wikidata)
            ::Workflows::Books::AuthorEnrichment.expects(:start).never

            post_identifier "/api/v1/admin/authors/#{@author.id}/identifiers", {identifier_type: "books_author_wikidata_qid", value: "Q7243"}
            assert_api_response_conform(status: 422, api: :admin)
            assert_match "remove Q1 first", json[:detail]
          end

          test "adding to a record that does not exist is a 404" do
            post_identifier "/api/v1/admin/books/999999999/identifiers", {identifier_type: "books_work_asin", value: "B0"}
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "adding needs the write scope" do
            post_identifier "/api/v1/admin/books/#{@book.id}/identifiers", {identifier_type: "books_work_asin", value: "B0"},
              token: ApiTokenSecrets::ADMIN_READ
            assert_api_response_conform(status: 403, api: :admin)
          end

          test "removing an author identifier is 200 with the deleted row and re-runs enrichment" do
            row = add(@author, :books_author_viaf, "96987389", source: :viaf)
            ::Workflows::Books::AuthorEnrichment.expects(:start)
              .with(@author, initiated_by: "admin_identifier", options: {refresh: true}, supersede: true).once

            delete_identifier "/api/v1/admin/authors/#{@author.id}/identifiers/#{row.id}"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [row.id, "96987389", "viaf"], json[:data].values_at(:id, :value, :source)
            assert_not Identifier.exists?(row.id)
          end

          test "removing a book identifier is 200" do
            row = identifiers(:war_and_peace_asin)

            delete_identifier "/api/v1/admin/books/#{@book.id}/identifiers/#{row.id}"
            assert_api_response_conform(status: 200, api: :admin)
            assert_not Identifier.exists?(row.id)
          end

          test "removing another record's identifier is a 404 and deletes nothing" do
            row = identifiers(:war_and_peace_asin)

            delete_identifier "/api/v1/admin/books/#{@other_book.id}/identifiers/#{row.id}"
            assert_api_response_conform(status: 404, api: :admin)
            delete_identifier "/api/v1/admin/authors/#{@author.id}/identifiers/#{row.id}"
            assert_response :not_found
            assert Identifier.exists?(row.id)
          end

          test "removing needs the merge scope" do
            row = identifiers(:war_and_peace_asin)

            delete_identifier "/api/v1/admin/books/#{@book.id}/identifiers/#{row.id}", token: write_token
            assert_api_response_conform(status: 403, api: :admin)
            assert Identifier.exists?(row.id)
          end
        end
      end
    end
  end
end
