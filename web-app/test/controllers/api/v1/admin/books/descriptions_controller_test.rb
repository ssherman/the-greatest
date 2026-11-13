require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class DescriptionsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @book = books_books(:war_and_peace)
            @author = books_authors(:tolstoy)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def get_json(path, token: ApiTokenSecrets::ADMIN_READ)
            get path, headers: bearer(token)
          end

          test "a book's descriptions list every kind and locale, ranked then by source, with the shown one named" do
            get_json "/api/v1/admin/books/#{@book.id}/descriptions"
            assert_api_response_conform(status: 200, api: :admin)

            ids = json[:data].map { |row| row[:id] }
            assert_equal @book.descriptions.reorder(rank: :desc, source: :asc).pluck(:id), ids
            assert_includes ids, descriptions(:war_and_peace_fr).id
            assert_includes ids, descriptions(:war_and_peace_long).id
            assert_equal descriptions(:war_and_peace_ai).id, json[:shown_description_id]
          end

          test "a row carries the documented fields" do
            get_json "/api/v1/admin/books/#{@book.id}/descriptions"

            row = json[:data].find { |r| r[:id] == descriptions(:war_and_peace_wikipedia).id }
            assert_equal %i[id kind locale rank source source_name source_url license content retrieved_at created_at updated_at], row.keys
            assert_equal ["summary", "en", "normal", "wikipedia", "cc_by_sa_4", "https://en.wikipedia.org/wiki/War_and_Peace"],
              [row[:kind], row[:locale], row[:rank], row[:source], row[:license], row[:source_url]]
            assert_nil row[:source_name]
          end

          test "a preferred description is the shown one" do
            get_json "/api/v1/admin/books/#{books_books(:crime_and_punishment).id}/descriptions"

            assert_equal descriptions(:crime_preferred).id, json[:shown_description_id]
          end

          test "a deprecated description is listed but never shown" do
            get_json "/api/v1/admin/books/#{books_books(:combo_steinbeck).id}/descriptions"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [descriptions(:lonely_deprecated).id], json[:data].map { |row| row[:id] }
            assert_equal "deprecated", json[:data].first[:rank]
            assert_nil json[:shown_description_id]
          end

          test "deleting the shown description moves shown_description_id to the next by the resolver" do
            descriptions(:war_and_peace_ai).destroy!

            get_json "/api/v1/admin/books/#{@book.id}/descriptions"

            assert_equal descriptions(:war_and_peace_wikipedia).id, json[:shown_description_id]
          end

          test "a book with no descriptions is an empty list and a null shown id" do
            @book.descriptions.destroy_all

            get_json "/api/v1/admin/books/#{@book.id}/descriptions"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [], json[:data]
            assert_nil json[:shown_description_id]
          end

          test "an author's descriptions list the same way" do
            get_json "/api/v1/admin/authors/#{@author.id}/descriptions"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [descriptions(:tolstoy_google).id], json[:data].map { |row| row[:id] }
            assert_equal "Google Books", json[:data].first[:source_name]
            assert_equal descriptions(:tolstoy_google).id, json[:shown_description_id]
          end

          test "an unknown book or author is a 404" do
            get_json "/api/v1/admin/books/999999999/descriptions"
            assert_api_response_conform(status: 404, api: :admin)

            get_json "/api/v1/admin/authors/999999999/descriptions"
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "no token is 401 and a member is 403" do
            get "/api/v1/admin/books/#{@book.id}/descriptions"
            assert_api_response_conform(status: 401, api: :admin)

            get_json "/api/v1/admin/books/#{@book.id}/descriptions", token: ApiTokenSecrets::MEMBER
            assert_api_response_conform(status: 403, api: :admin)

            get_json "/api/v1/admin/authors/#{@author.id}/descriptions", token: ApiTokenSecrets::MEMBER
            assert_api_response_conform(status: 403, api: :admin)
          end
        end
      end
    end
  end
end
