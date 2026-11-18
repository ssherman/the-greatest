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

          # --- writes ---

          def write_headers = bearer(ApiTokenSecrets::LIBRARY)

          def custom_list(name = "Mine", user: @user)
            ::Books::UserList.create!(user: user, name: name, list_type: :custom)
          end

          test "create makes a private custom list" do
            post "/api/v1/my/lists", params: {name: "Summer 2027"}, as: :json, headers: write_headers
            assert_api_conform(status: 201)

            assert_equal "custom", json[:data][:list_type]
            assert_equal false, json[:data][:public]
            assert_equal "Summer 2027", json[:data][:name]
            assert_equal [], json[:meta][:results]
            assert_equal 1_000, json[:meta][:library_changes_remaining]
            assert_equal @user.id, ::Books::UserList.find(json[:data][:id]).user_id
          end

          test "create treats a null public and a null books as absent" do
            post "/api/v1/my/lists", params: {name: "Nulls", public: nil, books: nil}, as: :json, headers: write_headers

            assert_response :created
            assert_equal false, json[:data][:public]
            assert_equal [], json[:meta][:results]
          end

          test "create with books adds them and spends budget" do
            slugs = [books_books(:war_and_peace).slug, books_books(:got).slug]
            post "/api/v1/my/lists", params: {name: "Pair", description: "two", public: true, books: slugs}, as: :json, headers: write_headers
            assert_api_conform(status: 201)

            list = ::Books::UserList.find(json[:data][:id])
            assert_equal [books_books(:war_and_peace).id, books_books(:got).id].sort, list.user_list_items.pluck(:listable_id).sort
            assert_equal 998, json[:meta][:library_changes_remaining]
            assert_equal 2, json[:data][:book_count]
            assert_equal slugs.map { |s| {book: s, outcome: "added"} }, json[:meta][:results]
            assert_equal true, json[:data][:public]
          end

          test "create with an unknown slug is a 404 and makes no list" do
            assert_no_difference -> { ::Books::UserList.count } do
              post "/api/v1/my/lists", params: {name: "Nope", books: ["no-such-book"]}, as: :json, headers: write_headers
            end
            assert_api_conform(status: 404)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "create rolls the list back when adding the books fails" do
            ::Services::UserLists::AddItems.stubs(:call).returns(::Services::UserLists::MutationResult.failure(["boom"]))

            assert_no_difference -> { ::Books::UserList.count } do
              post "/api/v1/my/lists", params: {name: "Doomed", books: [books_books(:got).slug]}, as: :json, headers: write_headers
            end
            assert_api_conform(status: 422)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "create refuses bad names, descriptions, flags and bodies with a 400" do
            [
              {name: "x" * 101}, {name: "   "}, {}, {name: 5}, {name: "a\u0000b"},
              {name: "ok", public: "yes"}, {name: "ok", public: "true"},
              {name: "ok", description: "d" * 1_001}, {name: "ok", description: 3},
              {name: "ok", books: "slug"}, {name: "ok", books: []}
            ].each do |body|
              assert_no_difference -> { ::Books::UserList.count } do
                post "/api/v1/my/lists", params: body, as: :json, headers: write_headers
              end
              assert_api_response_conform(status: 400)
            end
          end

          test "create with an unknown field is a 422" do
            post "/api/v1/my/lists", params: {name: "ok", list_type: "favorites"}, as: :json, headers: write_headers
            assert_api_response_conform(status: 422)
          end

          test "create at the custom list cap is a 422, before any budget is spent" do
            now = Time.current
            ::UserList.insert_all(Array.new(500) { |i|
              {user_id: @user.id, type: "Books::UserList", name: "L#{i}", list_type: 4, created_at: now, updated_at: now}
            })

            post "/api/v1/my/lists", params: {name: "One too many", books: [books_books(:got).slug]}, as: :json, headers: write_headers
            assert_api_conform(status: 422)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "create with an over-budget books batch is a 429 and makes no list" do
            assert ::Services::Api::LibraryBudget.reserve(@user, 999).ok?

            assert_no_difference -> { ::Books::UserList.count } do
              post "/api/v1/my/lists", params: {name: "Pricey", books: [books_books(:got).slug, books_books(:clash).slug]}, as: :json, headers: write_headers
            end
            assert_api_conform(status: 429)
          end

          test "update renames a custom list and edits description and public" do
            list = custom_list("Before")

            patch "/api/v1/my/lists/#{list.id}", params: {name: "After", description: "d", public: true}, as: :json, headers: write_headers
            assert_api_conform(status: 200)

            assert_equal ["After", "d", true], [json[:data][:name], json[:data][:description], json[:data][:public]]
            assert_equal "After", list.reload.name
          end

          test "update lets a default list change public but not its name" do
            patch "/api/v1/my/lists/favorites", params: {public: true}, as: :json, headers: write_headers
            assert_api_conform(status: 200)
            assert_equal true, ::Books::UserList.find_by!(user: @user, list_type: :favorites).public

            patch "/api/v1/my/lists/read", params: {name: "Renamed"}, as: :json, headers: write_headers
            assert_api_conform(status: 422)
            assert_not_equal "Renamed", ::Books::UserList.find_by!(user: @user, list_type: :read).name
          end

          test "update with an empty or malformed body is a 400" do
            list = custom_list
            [{}, {public: "yes"}, {name: ""}, {description: "d" * 1_001}].each do |body|
              patch "/api/v1/my/lists/#{list.id}", params: body, as: :json, headers: write_headers
              assert_api_response_conform(status: 400)
            end
          end

          test "update can change a default list's description and clear one with null or blank" do
            patch "/api/v1/my/lists/favorites", params: {description: "Best"}, as: :json, headers: write_headers
            assert_api_conform(status: 200)
            assert_equal "Best", json[:data][:description]

            patch "/api/v1/my/lists/favorites", params: {description: nil}, as: :json, headers: write_headers
            assert_api_conform(status: 200)
            assert_nil json[:data][:description]

            patch "/api/v1/my/lists/favorites", params: {description: "x"}, as: :json, headers: write_headers
            patch "/api/v1/my/lists/favorites", params: {description: "   "}, as: :json, headers: write_headers
            assert_nil json[:data][:description]
          end

          test "update with a null byte is a 400" do
            list = custom_list
            patch "/api/v1/my/lists/#{list.id}", params: {name: "a\u0000b"}, as: :json, headers: write_headers
            assert_api_response_conform(status: 400)
            patch "/api/v1/my/lists/#{list.id}", params: {description: "a\u0000b"}, as: :json, headers: write_headers
            assert_api_response_conform(status: 400)
          end

          test "a description is measured after trimming" do
            post "/api/v1/my/lists", params: {name: "Padded", description: "#{"d" * 1_000}   "}, as: :json, headers: write_headers
            assert_response :created
          end

          test "create re-checks the cap inside the owner lock" do
            Api::V1::Books::My::ListsController.any_instance.stubs(:custom_list_count).returns(0, 500)

            assert_no_difference -> { ::Books::UserList.count } do
              post "/api/v1/my/lists", params: {name: "Raced", books: [books_books(:got).slug]}, as: :json, headers: write_headers
            end
            assert_api_conform(status: 422)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "update on another member's list is a 404" do
            theirs = custom_list("Theirs", user: users(:admin_user))

            patch "/api/v1/my/lists/#{theirs.id}", params: {name: "Mine now"}, as: :json, headers: write_headers
            assert_api_conform(status: 404)
            assert_equal "Theirs", theirs.reload.name
          end

          test "destroy removes a custom list and its items and returns it as it was" do
            list = custom_list("Doomed")
            UserListItem.create!(user_list: list, listable: books_books(:war_and_peace))
            UserListItem.create!(user_list: list, listable: books_books(:got))

            delete "/api/v1/my/lists/#{list.id}", headers: write_headers
            assert_api_conform(status: 200)

            assert_equal [list.id, "Doomed", 2], [json[:data][:id], json[:data][:name], json[:data][:book_count]]
            assert_not ::UserList.exists?(list.id)
            assert_not UserListItem.exists?(user_list_id: list.id)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "destroy removes dated items without a per-row callback or goal purge" do
            list = custom_list("Dated")
            UserListItem.create!(user_list: list, listable: books_books(:war_and_peace), completed_on: Date.new(2026, 1, 5))
            ::Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call).never

            delete "/api/v1/my/lists/#{list.id}", headers: write_headers

            assert_response :success
            assert_not UserListItem.exists?(user_list_id: list.id)
          end

          test "destroy refuses the four default lists with a 422" do
            %w[favorites read reading want_to_read].each do |name|
              delete "/api/v1/my/lists/#{name}", headers: write_headers
              assert_api_conform(status: 422)
            end
            assert ::Books::UserList.exists?(user: @user, list_type: :read)
          end

          test "destroy on another member's list is a 404" do
            theirs = custom_list("Theirs", user: users(:admin_user))
            delete "/api/v1/my/lists/#{theirs.id}", headers: write_headers
            assert_api_conform(status: 404)
            assert ::UserList.exists?(theirs.id)
          end

          test "writes need the library write scope" do
            list = custom_list
            post "/api/v1/my/lists", params: {name: "x"}, as: :json, headers: bearer(ApiTokenSecrets::LIBRARY_READ)
            assert_api_conform(status: 403)
            patch "/api/v1/my/lists/#{list.id}", params: {name: "x"}, as: :json, headers: bearer(ApiTokenSecrets::LIBRARY_READ)
            assert_api_conform(status: 403)
            delete "/api/v1/my/lists/#{list.id}", headers: bearer(ApiTokenSecrets::LIBRARY_READ)
            assert_api_conform(status: 403)
            assert ::UserList.exists?(list.id)
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
