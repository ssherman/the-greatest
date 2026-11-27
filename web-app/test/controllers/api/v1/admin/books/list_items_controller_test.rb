require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class ListItemsControllerTest < ActionDispatch::IntegrationTest
          include BookSubmissionReviewHelper

          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @list = ::Books::List.create!(name: "Item Order List", status: :approved)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def fetch(list = @list)
            get "/api/v1/admin/lists/#{list.id}/items", headers: bearer(READ)
          end

          test "rows come in position order, nulls last, then id" do
            unpositioned = ListItem.create!(list: @list, metadata: {"title" => "Loose", "author" => "Anon"})
            second = ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 2)
            first = ListItem.create!(list: @list, metadata: {"title" => "First"}, position: 1)
            fetch
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [first.id, second.id, unpositioned.id], json[:data].map { |row| row[:id] }
          end

          test "a linked row carries its book and an unlinked row its text" do
            ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)
            ListItem.create!(list: @list, metadata: {"title" => "Loose", "authors" => ["A", "B"]}, position: 2)
            fetch
            assert_api_response_conform(status: 200, api: :admin)

            linked, unlinked = json[:data]
            assert_equal books_books(:war_and_peace).id, linked[:book][:id]
            assert_nil linked[:text]
            assert_nil unlinked[:book]
            assert_equal({title: "Loose", author: "A, B"}, unlinked[:text])
          end

          test "a list outside books is a 404" do
            fetch(lists(:music_albums_list))

            assert_response :not_found
          end

          test "a member token is forbidden" do
            get "/api/v1/admin/lists/#{@list.id}/items", headers: bearer(ApiTokenSecrets::MEMBER)

            assert_response :forbidden
          end

          WRITE = ApiTokenSecrets::ADMIN

          def post_item(body, list: @list, headers: bearer(WRITE))
            post "/api/v1/admin/lists/#{list.id}/items", params: body.to_json, headers: headers.merge("Content-Type" => "application/json")
          end

          def patch_item(item, body, headers: bearer(WRITE))
            patch "/api/v1/admin/list_items/#{item.id}", params: body.to_json, headers: headers.merge("Content-Type" => "application/json")
          end

          def delete_item(item, headers: bearer(WRITE))
            delete "/api/v1/admin/list_items/#{item.id}", headers: headers
          end

          def generated_list
            ::Books::List.create!(name: "Generated Items", status: :approved, auto_generated_kind: :year_top, auto_generated_year: 1999)
          end

          test "create adds a verified row at the position" do
            book = books_books(:war_and_peace)
            post_item({book_id: book.id, position: 3})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [book.id, 3, false], [json[:data][:book][:id], json[:data][:position], json[:promoted]]
            assert ListItem.find(json[:data][:id]).verified
          end

          test "create promotes a provisional book" do
            stub_review_side_effects
            book = ::Books::Book.create!(title: "Provisional Item Book", provisional: true)
            post_item({book_id: book.id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal true, json[:promoted]
            assert_not book.reload.provisional?
          end

          test "create with a read token is forbidden" do
            post_item({book_id: books_books(:war_and_peace).id}, headers: bearer(READ))

            assert_response :forbidden
          end

          test "create on a music list or a missing list is a 404" do
            post_item({book_id: books_books(:war_and_peace).id}, list: lists(:music_albums_list))
            assert_response :not_found

            post "/api/v1/admin/lists/0/items", params: {book_id: 1}.to_json, headers: bearer(WRITE).merge("Content-Type" => "application/json")
            assert_response :not_found
          end

          test "create refuses an unknown key and names the accepted ones" do
            post_item({book_id: books_books(:war_and_peace).id, note: "x"})

            assert_response :unprocessable_content
            assert_includes json[:detail], "Accepted: book_id, position"
          end

          test "create with a missing or mistyped book_id or position is a 400" do
            [{}, {book_id: "5"}, {book_id: 1.5}, {book_id: true}, {book_id: books_books(:war_and_peace).id, position: "2"},
              {book_id: books_books(:war_and_peace).id, position: 2.5}, {book_id: books_books(:war_and_peace).id, position: false}].each do |body|
              post_item(body)

              assert_response :bad_request, body.inspect
            end
          end

          test "create with no such book or a non-positive position is a 422" do
            post_item({book_id: 0})
            assert_response :unprocessable_content
            assert_includes json[:detail], "No book 0."

            post_item({book_id: books_books(:war_and_peace).id, position: 0})
            assert_response :unprocessable_content

            post_item({book_id: books_books(:war_and_peace).id, position: -1})
            assert_response :unprocessable_content
          end

          test "create of a book already on the list is a 422" do
            ListItem.create!(list: @list, listable: books_books(:war_and_peace))
            post_item({book_id: books_books(:war_and_peace).id})

            assert_response :unprocessable_content
          end

          test "a book deleted during promotion is a 409" do
            ::Services::Books::PromoteProvisionalBook.stubs(:call).returns(
              ::Services::Books::BookSubmissions::Lease::Result.new(success?: false, data: {conflict: true}, errors: ["the book no longer exists"])
            )
            provisional = ::Books::Book.create!(title: "Unreviewed", provisional: true)
            assert_no_difference "ListItem.count" do
              post_item({book_id: provisional.id})
            end

            assert_response :conflict
          end

          test "update clears the position" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 4)
            patch_item(item, {position: nil})
            assert_api_response_conform(status: 200, api: :admin)

            assert_nil json[:data][:position]
            assert_nil item.reload.position
          end

          test "update relinks to another book" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 4, verified: false)
            patch_item(item, {book_id: books_books(:crime_and_punishment).id})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal books_books(:crime_and_punishment).id, json[:data][:book][:id]
            assert item.reload.verified
          end

          test "update with an empty body is a 422" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace))
            patch_item(item, {})

            assert_response :unprocessable_content
            assert_includes json[:detail], "Nothing to change: send book_id and/or position."
          end

          test "update with a mistyped value is a 400" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace))
            patch_item(item, {position: "2"})
            assert_response :bad_request

            patch_item(item, {book_id: "2"})
            assert_response :bad_request
          end

          test "update of a row on a music list is a 404" do
            item = ListItem.create!(list: lists(:music_albums_list), metadata: {"title" => "Loose"}, position: 1)
            patch_item(item, {position: 2})

            assert_response :not_found
            assert_includes json[:detail], "No books list item #{item.id}."
          end

          test "destroy removes the row and returns it" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)
            delete_item(item)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal item.id, json[:data][:id]
            assert_not ListItem.exists?(item.id)
            assert ::Books::Book.exists?(books_books(:war_and_peace).id)
          end

          test "writes to an auto-generated list are 422" do
            list = generated_list
            item = ListItem.new(list: list, listable: books_books(:war_and_peace), position: 1)
            item.save!(validate: false)

            post_item({book_id: books_books(:crime_and_punishment).id}, list: list)
            assert_response :unprocessable_content
            patch_item(item, {position: 2})
            assert_response :unprocessable_content
            delete_item(item)
            assert_response :unprocessable_content
            assert ListItem.exists?(item.id)
          end

          test "update and destroy with a read token are forbidden" do
            item = ListItem.create!(list: @list, listable: books_books(:war_and_peace), position: 1)
            patch_item(item, {position: 2}, headers: bearer(READ))
            assert_response :forbidden
            delete_item(item, headers: bearer(READ))
            assert_response :forbidden
          end
        end
      end
    end
  end
end
