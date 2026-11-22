require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class ListItemsControllerTest < ActionDispatch::IntegrationTest
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
        end
      end
    end
  end
end
