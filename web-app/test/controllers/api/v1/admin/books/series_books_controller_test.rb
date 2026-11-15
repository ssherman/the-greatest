require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class SeriesBooksControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @series = books_series(:asoiaf)
            @book = books_books(:war_and_peace)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def path(book_id = nil) = ["/api/v1/admin/series/#{@series.id}/books", book_id].compact.join("/")

          def send_raw(verb, url, body = nil, token: WRITE)
            send(verb, url, params: body.is_a?(String) ? body : body&.to_json, headers: bearer(token).merge("CONTENT_TYPE" => "application/json"))
          end

          def entry(book) = json[:data][:books].find { |row| row[:id] == book.id }

          test "add links the book with defaults and returns the series" do
            send_raw(:post, path, {book_id: @book.id})
            assert_api_response_conform(status: 200, api: :admin)

            link = ::Books::SeriesBook.find_by!(series: @series, book: @book)
            assert_nil link.position
            assert link.numbered
            assert_equal 4, json[:data][:books].size
          end

          test "add stores position, numbered and label" do
            send_raw(:post, path, {book_id: @book.id, position: 4, numbered: false, position_label: "Omnibus"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [4.0, false, "Omnibus"], entry(@book).values_at(:position, :numbered, :position_label)
          end

          test "position accepts a decimal" do
            send_raw(:post, path, {book_id: @book.id, position: 1.5})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 1.5, entry(@book)[:position]
            assert_equal BigDecimal("1.5"), ::Books::SeriesBook.find_by!(series: @series, book: @book).position
          end

          test "position rejects strings, booleans, 3 decimals and out of range" do
            [{position: "3"}, {position: 1.234}, {position: true}, {position: 1_000_000}, {position: -1_000_000.5}].each do |bad|
              send_raw(:post, path, {book_id: @book.id}.merge(bad))
              assert_response :bad_request, bad.inspect
            end
            assert_not ::Books::SeriesBook.exists?(series: @series, book: @book)
          end

          test "numbered must be a boolean and position_label a string or null" do
            send_raw(:post, path, {book_id: @book.id, numbered: "yes"})
            assert_response :bad_request
            send_raw(:post, path, {book_id: @book.id, position_label: 3})
            assert_response :bad_request
          end

          test "add with a missing or bad book_id is 400 and an unknown book 422" do
            send_raw(:post, path, {})
            assert_api_response_conform(status: 400, api: :admin)
            send_raw(:post, path, {book_id: "abc"})
            assert_response :bad_request
            send_raw(:post, path, "[1]")
            assert_response :bad_request

            send_raw(:post, path, {book_id: 999_999_999})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "add of a book already in the series is 422 and an unknown key is 422" do
            send_raw(:post, path, {book_id: books_books(:got).id})
            assert_api_response_conform(status: 422, api: :admin)

            send_raw(:post, path, {book_id: @book.id, bogus: 1})
            assert_response :unprocessable_entity
          end

          test "add to a deleted or unknown series" do
            @series = books_series(:junk_deleted)
            send_raw(:post, path, {book_id: @book.id})
            assert_response :unprocessable_entity

            send_raw(:post, "/api/v1/admin/series/999999999/books", {book_id: @book.id})
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "update changes only the keys sent and null clears position" do
            got = books_books(:got)
            send_raw(:patch, path(got.id), {position_label: "Book One"})
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [1.0, "Book One"], entry(got).values_at(:position, :position_label)

            send_raw(:patch, path(got.id), "{\"position\": null}")
            assert_api_response_conform(status: 200, api: :admin)
            assert_nil entry(got)[:position]
            assert_equal "Book One", entry(got)[:position_label]

            send_raw(:patch, path(got.id), {position_label: ""})
            assert_nil entry(got)[:position_label]
          end

          test "update with an empty body is 400, unknown key 422, bad type 400" do
            got = books_books(:got)
            send_raw(:patch, path(got.id), {})
            assert_api_response_conform(status: 400, api: :admin)
            send_raw(:patch, path(got.id), {bogus: 1})
            assert_response :unprocessable_entity
            send_raw(:patch, path(got.id), {position: "1"})
            assert_response :bad_request
          end

          test "update and remove of a book not in the series are 404" do
            send_raw(:patch, path(@book.id), {position: 1})
            assert_api_response_conform(status: 404, api: :admin)

            send_raw(:delete, path(@book.id))
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "remove unlinks the book and clears the representative" do
            got = books_books(:got)
            @series.update!(representative_book: got)

            send_raw(:delete, path(got.id))
            assert_api_response_conform(status: 200, api: :admin)

            assert_not ::Books::SeriesBook.exists?(series: @series, book: got)
            assert_nil @series.reload.representative_book_id
            assert_equal 2, json[:data][:books].size
          end

          test "a book id of 0 is 400" do
            send_raw(:delete, path(0))
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "a read token is refused and the policy is enforced" do
            send_raw(:post, path, {book_id: @book.id}, token: READ)
            assert_response :forbidden

            ::Books::SeriesPolicy.any_instance.stubs(:update?).returns(false)
            send_raw(:delete, path(books_books(:got).id))
            assert_response :forbidden
          end
        end
      end
    end
  end
end
