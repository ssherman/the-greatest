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
            assert_equal @book.descriptions.pluck(:id).sort, ids.sort
            assert_includes ids, descriptions(:war_and_peace_fr).id
            assert_includes ids, descriptions(:war_and_peace_long).id
            assert_equal descriptions(:war_and_peace_ai).id, json[:shown_description_id]
          end

          test "a preferred description is listed first and a deprecated one last" do
            get_json "/api/v1/admin/books/#{books_books(:crime_and_punishment).id}/descriptions"

            ranks = json[:data].map { |row| row[:rank] }
            assert_equal "preferred", ranks.first
            assert_equal "deprecated", ranks.last
            assert_equal descriptions(:crime_preferred).id, json[:data].first[:id]
            assert_equal descriptions(:crime_deprecated).id, json[:data].last[:id]
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
            Description.where(describable: @book).destroy_all

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

          def write_token
            @write_token ||= Services::Api::Tokens.generate(
              user: users(:admin_user), name: "write", scopes: ["books:admin:write"], expires_at: 1.day.from_now
            ).data[:secret]
          end

          def send_json(method, path, body = nil, token: ApiTokenSecrets::ADMIN)
            public_send(method, path, params: body, as: :json, headers: bearer(token))
          end

          # -- add ---------------------------------------------------------

          test "adding a description to a book is a 201 with the row and the shown id" do
            Description.where(describable: @book).destroy_all

            assert_difference -> { @book.descriptions.count }, 1 do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "Napoleon's wars.", source: "ai_generated"}
            end
            assert_api_response_conform(status: 201, api: :admin)

            row = @book.descriptions.reload.last
            assert_equal ["summary", "en", "normal", "ai_generated"], [row.kind, row.locale, row.rank, row.source]
            assert_equal row.id, json[:data][:id]
            assert_equal row.id, json[:shown_description_id]
          end

          test "adding to an author works with a write-scope token" do
            assert_difference -> { @author.descriptions.count }, 1 do
              send_json :post, "/api/v1/admin/authors/#{@author.id}/descriptions",
                {content: "A novelist.", source: "other", source_name: "Penguin"}, token: write_token
            end
            assert_api_response_conform(status: 201, api: :admin)
            assert_equal "Penguin", json[:data][:source_name]
          end

          test "a source that is not one of the known sources is a 400" do
            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x", source: "bogus"}
            end
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "a missing source or content is a 400" do
            send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x"}
            assert_api_response_conform(status: 400, api: :admin)

            send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {source: "manual"}
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "source other without a source_name is a 400" do
            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x", source: "other"}
            end
            assert_api_response_conform(status: 400, api: :admin)
            assert_match(/source name/i, json[:detail])
          end

          test "source wikipedia without a source_url is a 400" do
            Description.where(describable: @book).destroy_all

            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x", source: "wikipedia"}
            end
            assert_api_response_conform(status: 400, api: :admin)
            assert_match "source_url", json[:detail]
          end

          test "source wikipedia defaults the license to CC BY-SA 4 and keeps one that is given" do
            Description.where(describable: @book).destroy_all
            send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions",
              {content: "x", source: "wikipedia", source_url: "https://en.wikipedia.org/wiki/War_and_Peace"}
            assert_api_response_conform(status: 201, api: :admin)
            assert_equal "cc_by_sa_4", json[:data][:license]

            Description.where(describable: @book).destroy_all
            send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions",
              {content: "x", source: "wikipedia", source_url: "https://en.wikipedia.org/wiki/War_and_Peace", license: "cc0"}
            assert_equal "cc0", json[:data][:license]
          end

          test "a second description with the same source is a 422 naming the existing one and creates nothing" do
            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "Again", source: "ai_generated"}
            end
            assert_api_response_conform(status: 422, api: :admin)
            assert_match descriptions(:war_and_peace_ai).id.to_s, json[:detail]
          end

          test "content over the cap is a 400" do
            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions",
                {content: "a" * (Correction::MAX_TEXT_VALUE_LENGTH + 1), source: "manual"}
            end
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "adding to an unknown book is a 404" do
            send_json :post, "/api/v1/admin/books/999999999/descriptions", {content: "x", source: "manual"}
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "an owner the policy may not let change the book is refused and nothing is added" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x", source: "manual"}
            end
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
          end

          test "a read-scope token cannot add" do
            assert_no_difference "Description.count" do
              send_json :post, "/api/v1/admin/books/#{@book.id}/descriptions", {content: "x", source: "manual"}, token: ApiTokenSecrets::ADMIN_READ
            end
            assert_api_response_conform(status: 403, api: :admin)
          end

          # -- update ------------------------------------------------------

          test "a partial update changes only the fields sent" do
            row = descriptions(:war_and_peace_ai)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {content: "Corrected."}, token: write_token
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "Corrected.", json[:data][:content]
            assert_equal ["Corrected.", "ai_generated"], [row.reload.content, row.source]
          end

          test "updating the source to a non-other source clears a stale source_name" do
            row = descriptions(:tolstoy_google)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {source: "manual"}
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ["manual", nil], [row.reload.source, row.source_name]
          end

          test "an update that fails validation is a 400 and changes nothing" do
            row = descriptions(:war_and_peace_ai)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {source: "other"}
            assert_api_response_conform(status: 400, api: :admin)
            assert_equal "ai_generated", row.reload.source

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {content: nil}
            assert_api_response_conform(status: 400, api: :admin)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {license: "bogus"}
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "an update to a source another description holds is a 422" do
            send_json :patch, "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", {source: "wikipedia", source_url: "https://en.wikipedia.org/wiki/War_and_Peace"}
            assert_api_response_conform(status: 422, api: :admin)
            assert_match descriptions(:war_and_peace_wikipedia).id.to_s, json[:detail]
          end

          test "updating a description to wikipedia needs a source_url" do
            row = descriptions(:tolstoy_google)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {source: "wikipedia"}
            assert_api_response_conform(status: 400, api: :admin)
            assert_equal "other", row.reload.source
          end

          test "clearing the source_url of a wikipedia description is a 400 and keeps it" do
            row = descriptions(:war_and_peace_wikipedia)

            [nil, ""].each do |blank|
              send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {source_url: blank}
              assert_api_response_conform(status: 400, api: :admin)
            end
            assert_equal "https://en.wikipedia.org/wiki/War_and_Peace", row.reload.source_url
          end

          test "a content-only update of a wikipedia description without a url is allowed" do
            row = descriptions(:war_and_peace_wikipedia)
            row.update_columns(source_url: nil)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {content: "Fixed."}
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["Fixed.", nil], [row.reload.content, row.source_url]
          end

          test "moving a wikipedia description to another source may clear its url" do
            row = descriptions(:war_and_peace_wikipedia)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {source: "publisher", source_url: nil}
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["publisher", nil], [row.reload.source, row.source_url]
          end

          test "license and source_url can be cleared on a non-wikipedia description" do
            row = descriptions(:tolstoy_google)
            row.update_columns(license: ::Description.licenses[:cc0], source_url: "https://example.com/x")

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {license: nil, source_url: nil}
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [nil, nil], [row.reload.license, row.source_url]
          end

          test "an update the policy refuses is a 403 and changes nothing" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)
            row = descriptions(:war_and_peace_ai)

            send_json :patch, "/api/v1/admin/descriptions/#{row.id}", {content: "Nope"}
            assert_api_response_conform(status: 403, api: :admin)
            refute_equal "Nope", row.reload.content
          end

          # -- prefer ------------------------------------------------------

          test "preferring a description leaves exactly one preferred and the shown id follows it" do
            crime = books_books(:crime_and_punishment)

            send_json :post, "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer", nil, token: write_token
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "preferred", json[:data][:rank]
            assert_equal descriptions(:crime_ai).id, json[:shown_description_id]
            assert_equal [descriptions(:crime_ai).id], crime.descriptions.where(rank: :preferred).pluck(:id)
            assert_equal "normal", descriptions(:crime_preferred).reload.rank
          end

          test "a refused prefer changes nothing" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            send_json :post, "/api/v1/admin/descriptions/#{descriptions(:crime_ai).id}/prefer"
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "normal", descriptions(:crime_ai).reload.rank
          end

          # -- delete ------------------------------------------------------

          test "deleting the shown description removes it and the shown id falls back by the resolver" do
            send_json :delete, "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}"
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal descriptions(:war_and_peace_ai).id, json[:data][:id]
            refute Description.exists?(descriptions(:war_and_peace_ai).id)
            assert_equal descriptions(:war_and_peace_wikipedia).id, json[:shown_description_id]
          end

          test "deleting needs the merge scope" do
            send_json :delete, "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}", nil, token: write_token
            assert_api_response_conform(status: 403, api: :admin)
            assert Description.exists?(descriptions(:war_and_peace_ai).id)
          end

          test "a delete the policy refuses is a 403 and the row stays" do
            ::Books::BookPolicy.any_instance.stubs(:destroy?).returns(false)

            send_json :delete, "/api/v1/admin/descriptions/#{descriptions(:war_and_peace_ai).id}"
            assert_api_response_conform(status: 403, api: :admin)
            assert Description.exists?(descriptions(:war_and_peace_ai).id)
          end

          # -- other domains and missing rows ------------------------------

          test "a music or games description, or a missing one, is a 404 on every by-id action" do
            [descriptions(:dark_side_ai).id, descriptions(:botw_igdb).id, 999_999_999].each do |id|
              send_json :patch, "/api/v1/admin/descriptions/#{id}", {content: "Hijack"}
              assert_api_response_conform(status: 404, api: :admin)

              send_json :post, "/api/v1/admin/descriptions/#{id}/prefer"
              assert_api_response_conform(status: 404, api: :admin)

              send_json :delete, "/api/v1/admin/descriptions/#{id}"
              assert_api_response_conform(status: 404, api: :admin)
            end

            assert Description.exists?(descriptions(:dark_side_ai).id)
            assert Description.exists?(descriptions(:botw_igdb).id)
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
