require "test_helper"

module Api
  module V1
    module Books
      module My
        class BookListsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @user = users(:regular_user)
            @token = ApiTokenSecrets::LIBRARY_READ
            @book = books_books(:crime_and_punishment)
          end

          def json = response.parsed_body.deep_symbolize_keys

          test "a book on the read list and a custom list returns both, defaults first, with completed_on" do
            read = ::Books::UserList.find_by!(user: @user, list_type: :read)
            custom = ::Books::UserList.create!(user: @user, name: "Doorstops", list_type: :custom)
            UserListItem.create!(user_list: custom, listable: @book, position: 1)
            UserListItem.create!(user_list: read, listable: @book, position: 1, completed_on: Date.new(2026, 2, 3))
            # Another user's list holding the same book is not shown.
            elsewhere = ::Books::UserList.create!(user: users(:admin_user), name: "Someone else's", list_type: :custom)
            UserListItem.create!(user_list: elsewhere, listable: @book)

            get "/api/v1/my/books/#{@book.slug}/lists", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [read.id, custom.id], json[:data].map { |row| row[:list][:id] }
            assert_equal %i[list position added_at completed_on], json[:data].first.keys
            assert_equal ["2026-02-03", nil], json[:data].map { |row| row[:completed_on] }
            assert_equal 2, json[:data].first[:list][:book_count] # the clash fixture row plus this one
            assert_equal 2, json[:meta][:total_count]
          end

          test "a book on none of the lists is an empty page" do
            get "/api/v1/my/books/#{books_books(:cannery_row).slug}/lists", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [], json[:data]
          end

          test "an unknown slug and a provisional book are a 404" do
            get "/api/v1/my/books/no-such-book/lists", headers: bearer(@token)
            assert_api_response_conform(status: 404)

            @book.update!(provisional: true)
            get "/api/v1/my/books/#{@book.slug}/lists", headers: bearer(@token)
            assert_api_response_conform(status: 404)
          end

          test "a token with books:read only is a 403 insufficient_scope" do
            get "/api/v1/my/books/#{@book.slug}/lists", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 403)

            assert_equal "insufficient_scope", json[:code]
          end
        end
      end
    end
  end
end
