require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class BookAuthorsControllerTest < ActionDispatch::IntegrationTest
          WRITE = ApiTokenSecrets::ADMIN
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            stub_workflow_dispatch
            host! "dev-new.thegreatestbooks.org"
            @book = books_books(:war_and_peace)
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def add(body, token: WRITE, id: @book.id)
            post "/api/v1/admin/books/#{id}/authors", params: body, as: :json, headers: bearer(token)
          end

          def change(author_id, raw, token: WRITE, id: @book.id)
            patch "/api/v1/admin/books/#{id}/authors/#{author_id}", params: raw, headers: bearer(token).merge("CONTENT_TYPE" => "application/json")
          end

          def remove(author_id, token: WRITE, id: @book.id)
            delete "/api/v1/admin/books/#{id}/authors/#{author_id}", headers: bearer(token)
          end

          test "add appends the author last with the next position" do
            add({author_id: @king.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [@tolstoy.id, @king.id], json[:data].map { |a| a[:id] }
            entry = json[:data].last
            assert_equal %w[id slug name role position credited_as], entry.keys.map(&:to_s)
            assert_equal ["author", 2, nil], [entry[:role], entry[:position], entry[:credited_as]]
          end

          test "add without position on a book whose rows have no position goes last" do
            @book.book_authors.update_all(position: nil)
            add({author_id: @king.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal @king.id, json[:data].last[:id]
          end

          test "add with an unknown key is 422" do
            add({author_id: @king.id, bogus: 1})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "add keeps a given role and credited_as" do
            add({author_id: @king.id, role: "editor", credited_as: "X"})
            assert_api_response_conform(status: 200, api: :admin)

            row = @book.book_authors.find_by(author_id: @king.id)
            assert_equal ["editor", "X"], [row.role, row.credited_as]
          end

          test "add of an author already on the book is 422 pointing at update" do
            add({author_id: @tolstoy.id})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "update_book_author"
            assert_equal 1, @book.book_authors.count
          end

          test "add of an unknown author is 422" do
            add({author_id: 999_999_999})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "add with a missing or non-integer author_id is 400" do
            add({})
            assert_api_response_conform(status: 400, api: :admin)

            add({author_id: "abc"})
            assert_response :bad_request
          end

          test "add with a wrong-type role is 400 and an unknown role is 422" do
            add({author_id: @king.id, role: 0})
            assert_response :bad_request

            add({author_id: @king.id, role: "translator"})
            assert_response :unprocessable_entity
          end

          test "update changes the role" do
            change(@tolstoy.id, {role: "editor"}.to_json)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "editor", json[:data].first[:role]
            assert_equal "editor", @book.book_authors.find_by(author_id: @tolstoy.id).role
          end

          test "update clears credited_as and position with null" do
            change(@tolstoy.id, {credited_as: nil, position: nil}.to_json)
            assert_api_response_conform(status: 200, api: :admin)

            row = @book.book_authors.find_by(author_id: @tolstoy.id)
            assert_nil row.credited_as
            assert_nil row.position
          end

          test "update with an empty body is 400" do
            change(@tolstoy.id, "{}")
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "update with an unknown key is 422" do
            change(@tolstoy.id, {nickname: "x"}.to_json)
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "unknown role is 422" do
            change(@tolstoy.id, {role: "translator"}.to_json)
            assert_api_response_conform(status: 422, api: :admin)
            assert_equal "author", @book.book_authors.find_by(author_id: @tolstoy.id).role
          end

          test "wrong-type role is 400" do
            change(@tolstoy.id, {role: 0}.to_json)
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "position must be a positive integer" do
            change(@tolstoy.id, {position: 0}.to_json)
            assert_api_response_conform(status: 400, api: :admin)

            change(@tolstoy.id, {position: "2"}.to_json)
            assert_response :bad_request

            change(@tolstoy.id, {credited_as: 5}.to_json)
            assert_response :bad_request
          end

          test "a zero author id in the path is 400" do
            change(0, {role: "editor"}.to_json)
            assert_response :bad_request

            remove(0)
            assert_response :bad_request
          end

          test "update of an author not on the book is 404" do
            change(@king.id, {role: "editor"}.to_json)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "remove deletes the row and returns the rest" do
            remove(@tolstoy.id)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [], json[:data]
            assert_not @book.book_authors.exists?(author_id: @tolstoy.id)
            assert ::Books::Author.exists?(@tolstoy.id)
          end

          test "remove of an author not on the book is 404" do
            remove(@king.id)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "an unknown book is 404 for all three" do
            add({author_id: @king.id}, id: 999_999_999)
            assert_api_response_conform(status: 404, api: :admin)
            change(@tolstoy.id, {role: "editor"}.to_json, id: 999_999_999)
            assert_response :not_found
            remove(@tolstoy.id, id: 999_999_999)
            assert_response :not_found
          end

          test "a read-only token is refused with insufficient_scope on all three" do
            add({author_id: @king.id}, token: READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "insufficient_scope", json[:code]
            change(@tolstoy.id, {role: "editor"}.to_json, token: READ)
            assert_equal "insufficient_scope", json[:code]
            remove(@tolstoy.id, token: READ)
            assert_equal "insufficient_scope", json[:code]
            assert @book.book_authors.exists?(author_id: @tolstoy.id)
          end

          test "an owner the book policy refuses gets forbidden" do
            ::Books::BookPolicy.any_instance.stubs(:update?).returns(false)

            add({author_id: @king.id})
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
            remove(@tolstoy.id)
            assert_response :forbidden
            change(@tolstoy.id, {role: "editor"}.to_json)
            assert_response :forbidden
            assert_equal [@tolstoy.id], @book.book_authors.reload.map(&:author_id)
          end

          test "each change is logged with its action" do
            Rails.logger.stubs(:info)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_book_author action=add .*book_id=#{@book.id} author_id=#{@king.id}/)).once
            add({author_id: @king.id})
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_book_author action=update /)).once
            change(@king.id, {role: "editor"}.to_json)
            Rails.logger.expects(:info).with(regexp_matches(/event=api_admin_book_author action=remove /)).once
            remove(@king.id)
          end
        end
      end
    end
  end
end
