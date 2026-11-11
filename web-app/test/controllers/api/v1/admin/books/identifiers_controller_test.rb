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

          test "the type constants are the books types by level" do
            assert_includes IdentifiersController::BOOK_TYPES, "books_work_isbn13"
            assert_includes IdentifiersController::AUTHOR_TYPES, "books_author_viaf"
            assert_includes IdentifiersController::IDENTIFIER_TYPES, "books_edition_isbn13"
            assert(IdentifiersController::IDENTIFIER_TYPES.all? { |type| type.start_with?("books_") })
          end

          test "a token without admin scope is refused" do
            get_json "/api/v1/admin/books/#{@book.id}/identifiers", {}, token: ApiTokenSecrets::MEMBER
            assert_response :forbidden
          end
        end
      end
    end
  end
end
