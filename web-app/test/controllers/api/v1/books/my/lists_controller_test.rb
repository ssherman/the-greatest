require "test_helper"

module Api
  module V1
    module Books
      module My
        class ListsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @user = users(:regular_user)
            @token = ApiTokenSecrets::LIBRARY_READ
          end

          def json = response.parsed_body.deep_symbolize_keys

          test "lists the four default lists first in default order, then custom lists by name, creating missing defaults" do
            assert_nil ::Books::UserList.find_by(user: @user, list_type: :reading)
            ::Books::UserList.create!(user: @user, name: "Cherry", list_type: :custom)
            ::Books::UserList.create!(user: @user, name: "banana", list_type: :custom)

            get "/api/v1/my/lists", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal %w[favorites read reading want_to_read custom custom], json[:data].map { |l| l[:list_type] }
            assert_equal ["banana", "Cherry"], json[:data].last(2).map { |l| l[:name] }
            assert_equal [true] * 4 + [false] * 2, json[:data].map { |l| l[:default] }
            assert_equal 6, json[:meta][:total_count]
            assert ::Books::UserList.exists?(user: @user, list_type: :reading)
            assert ::Books::UserList.exists?(user: @user, list_type: :want_to_read)
          end

          test "another user's lists and the user's music lists are absent" do
            ::Books::UserList.create!(user: users(:admin_user), name: "Not mine", list_type: :custom)

            get "/api/v1/my/lists", headers: bearer(@token)

            names = json[:data].map { |l| l[:name] }
            assert_not_includes names, "Not mine"
            assert_not_includes names, "Favorite Albums"
            assert_equal [@user.id], ::UserList.where(id: json[:data].map { |l| l[:id] }).pluck(:user_id).uniq
            assert_equal ["Books::UserList"], ::UserList.where(id: json[:data].map { |l| l[:id] }).pluck(:type).uniq
          end

          test "book_count counts catalogue books only" do
            read = ::Books::UserList.find_by!(user: @user, list_type: :read)
            UserListItem.create!(user_list: read, listable: books_books(:war_and_peace))
            # read already holds the clash fixture row, so the catalogue count is 2
            UserListItem.create!(user_list: read, listable: books_books(:got))
            books_books(:got).update!(provisional: true)

            get "/api/v1/my/lists", headers: bearer(@token)

            row = json[:data].find { |l| l[:id] == read.id }
            assert_equal 2, row[:book_count]
            assert_equal "https://dev-new.thegreatestbooks.org/api/v1/my/lists/#{read.id}/books", row[:books_api_url]
          end

          test "pages with the standard params" do
            get "/api/v1/my/lists?per_page=1&page=2", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal ["read"], json[:data].map { |l| l[:list_type] }
            assert_equal 4, json[:meta][:total_count]
          end

          test "a bad page is a 400" do
            get "/api/v1/my/lists?page=0", headers: bearer(@token)
            assert_api_response_conform(status: 400)
          end

          test "a token with books:read only is a 403 insufficient_scope" do
            get "/api/v1/my/lists", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 403)

            assert_equal "insufficient_scope", json[:code]
          end

          test "without a token it is a 401" do
            get "/api/v1/my/lists"
            assert_api_conform(status: 401)
          end
        end
      end
    end
  end
end
