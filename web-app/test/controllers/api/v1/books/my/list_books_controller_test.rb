require "test_helper"

module Api
  module V1
    module Books
      module My
        class ListBooksControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @user = users(:regular_user)
            @token = ApiTokenSecrets::LIBRARY_READ
            @read = ::Books::UserList.find_by!(user: @user, list_type: :read)
            UserListItem.where(user_list: @read).delete_all # the fixture row would shift every position below
            @wp = books_books(:war_and_peace)
            @crime = books_books(:crime_and_punishment)
            @got = books_books(:got)
            # Position order, added order and completion order all differ.
            UserListItem.create!(user_list: @read, listable: @wp, position: 1, completed_on: Date.new(2026, 1, 5), created_at: 1.day.ago)
            UserListItem.create!(user_list: @read, listable: @crime, position: 2, completed_on: Date.new(2026, 3, 9), created_at: 3.days.ago)
            UserListItem.create!(user_list: @read, listable: @got, position: 3, completed_on: nil, created_at: 2.days.ago)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def count_queries(&block)
            count = 0
            counter = ->(_name, _start, _finish, _id, payload) {
              count += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION])
            }
            ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
            count
          end

          def ids = json[:data].map { |row| row[:book][:id] }

          test "the read name and the numeric id serve the same list in position order" do
            get "/api/v1/my/lists/read/books", headers: bearer(@token)
            assert_api_conform(status: 200)
            by_name = json

            get "/api/v1/my/lists/#{@read.id}/books", headers: bearer(@token)

            assert_equal by_name, json
            assert_equal [@wp.id, @crime.id, @got.id], ids
            assert_equal %i[position added_at completed_on book], json[:data].first.keys
            assert_equal "2026-01-05", json[:data].first[:completed_on]
            assert_nil json[:data].last[:completed_on]
            assert_includes json[:links][:self], "sort=position"
          end

          test "sort=added is newest added first" do
            get "/api/v1/my/lists/read/books?sort=added", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [@wp.id, @got.id, @crime.id], ids
            assert_includes json[:links][:self], "sort=added"
          end

          test "sort=completed_on is most recently finished first with undated last" do
            get "/api/v1/my/lists/read/books?sort=completed_on", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [@crime.id, @wp.id, @got.id], ids
          end

          test "sort=completed_on on a list without completion dates is a 400" do
            get "/api/v1/my/lists/favorites/books?sort=completed_on", headers: bearer(@token)
            assert_api_response_conform(status: 400)

            assert_equal "invalid_parameter", json[:code]
          end

          test "an unknown sort is a 400" do
            get "/api/v1/my/lists/read/books?sort=rank", headers: bearer(@token)
            assert_api_response_conform(status: 400)
          end

          test "a default list the user does not have yet is a 200 and is created" do
            assert_nil ::Books::UserList.find_by(user: @user, list_type: :reading)

            get "/api/v1/my/lists/reading/books", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [], json[:data]
            assert ::Books::UserList.exists?(user: @user, list_type: :reading)
          end

          test "another user's list id, a music list id and an unknown name are the same 404" do
            other = ::Books::UserList.create!(user: users(:admin_user), name: "Someone else's", list_type: :custom)
            music = UserList.find_by!(user: @user, type: "Music::Albums::UserList", list_type: 0)

            [other.id.to_s, music.id.to_s, "bogus", "custom"].each do |value|
              get "/api/v1/my/lists/#{value}/books", headers: bearer(@token)
              assert_api_response_conform(status: 404)
              assert_equal "not_found", json[:code], value
            end
          end

          test "a provisional book is absent" do
            @got.update!(provisional: true)

            get "/api/v1/my/lists/read/books", headers: bearer(@token)

            assert_equal [@wp.id, @crime.id], ids
            assert_equal 2, json[:meta][:total_count]
          end

          test "rank is the primary ranking's, null when unranked" do
            RankedItem.create!(item: @wp, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 90)

            get "/api/v1/my/lists/read/books", headers: bearer(@token)

            assert_equal [7, nil, nil], json[:data].map { |row| row[:book][:rank] }
          end

          test "the query count does not grow with the number of books on the page" do
            RankedItem.create!(item: @wp, ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 99)
            # Warm up: the first request pays one-off lookups (token, rate limiter) the later ones skip.
            get "/api/v1/my/lists/read/books?per_page=1", headers: bearer(@token)

            small = count_queries { get "/api/v1/my/lists/read/books?per_page=2", headers: bearer(@token) }
            assert_equal 2, json[:data].size

            large = count_queries { get "/api/v1/my/lists/read/books?per_page=3", headers: bearer(@token) }
            assert_equal 3, json[:data].size

            assert_equal small, large, "query count grew from #{small} to #{large} as books were added -- N+1 on my list books"
          end

          test "a token with books:read only is a 403 insufficient_scope" do
            get "/api/v1/my/lists/read/books", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 403)

            assert_equal "insufficient_scope", json[:code]
          end
        end
      end
    end
  end
end

module Api
  module V1
    module Books
      module My
        class ListBookWritesTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @user = users(:regular_user)
            @read = ::Books::UserList.find_by!(user: @user, list_type: :read)
            @favorites = ::Books::UserList.find_by!(user: @user, list_type: :favorites)
            UserListItem.where(user_list: [@read, @favorites]).delete_all
            @wp = books_books(:war_and_peace)
            @crime = books_books(:crime_and_punishment)
            @got = books_books(:got)
            @token = ApiTokenSecrets::LIBRARY
          end

          def json = response.parsed_body.deep_symbolize_keys

          def add(list, body, token: @token)
            post "/api/v1/my/lists/#{list}/books", params: body, as: :json, headers: bearer(token)
          end

          def book_ids_on(list) = UserListItem.where(user_list: list).order(:position).map(&:listable_id)

          test "adds books in order and reports the list and the budget" do
            add("read", {books: [@wp.slug, @crime.slug]})
            assert_api_conform(status: 200)

            assert_equal [{book: @wp.slug, outcome: "added"}, {book: @crime.slug, outcome: "added"}], json[:data]
            assert_equal 2, json[:meta][:list][:book_count]
            assert_equal @read.id, json[:meta][:list][:id]
            assert_equal 998, json[:meta][:library_changes_remaining]
            assert_equal [@wp.id, @crime.id], book_ids_on(@read)
          end

          test "duplicate slugs count once" do
            add("read", {books: [@wp.slug, @wp.slug]})

            assert_equal [{book: @wp.slug, outcome: "added"}], json[:data]
            assert_equal 999, json[:meta][:library_changes_remaining]
          end

          test "an add with completed_on dates the book" do
            add("read", {books: [@wp.slug], completed_on: "2024-03-01"})

            assert_response :ok
            assert_equal Date.new(2024, 3, 1), UserListItem.find_by!(user_list: @read, listable: @wp).completed_on
          end

          test "a batch over 50, an empty batch and a non-array are 400s" do
            add("read", {books: (1..51).map { |i| "book-#{i}" }})
            assert_response :bad_request
            add("read", {books: []})
            assert_response :bad_request
            add("read", {books: "x"})
            assert_response :bad_request
            add("read", {})
            assert_response :bad_request
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "a malformed body is a 400" do
            post "/api/v1/my/lists/read/books", params: "{nope", headers: bearer(@token).merge("CONTENT_TYPE" => "application/json")
            assert_response :bad_request
          end

          test "two unknown slugs are a 404 naming both, and nothing is written or spent" do
            add("read", {books: [@wp.slug, "nope-one", "nope-two"]})

            assert_response :not_found
            assert_includes json[:detail], "nope-one"
            assert_includes json[:detail], "nope-two"
            assert_empty book_ids_on(@read)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "a provisional book is unknown" do
            @crime.update_columns(provisional: true)
            add("read", {books: [@crime.slug]})

            assert_response :not_found
          end

          test "a future or malformed completed_on is a 400" do
            add("read", {books: [@wp.slug], completed_on: "2999-01-01"})
            assert_response :bad_request
            add("read", {books: [@wp.slug], completed_on: "03/01/2024"})
            assert_response :bad_request
          end

          test "an add with a null completed_on is the same as none" do
            add("read", {books: [@wp.slug], completed_on: nil})

            assert_response :ok
            assert_equal [{book: @wp.slug, outcome: "added"}], json[:data]
          end

          test "completed_on allows the date in the furthest-ahead zone and no later" do
            travel_to Time.utc(2026, 11, 17, 20, 0, 0) do
              add("read", {books: [@wp.slug], completed_on: "2026-11-18"})
              assert_response :ok
              add("read", {books: [@crime.slug], completed_on: "2026-11-19"})
              assert_response :bad_request
            end
          end

          test "update with a null completed_on on a list without dates is absent" do
            UserListItem.create!(user_list: @favorites, listable: @wp, position: 1)
            UserListItem.create!(user_list: @favorites, listable: @crime, position: 2)

            patch "/api/v1/my/lists/favorites/books/#{@wp.slug}", params: {completed_on: nil}, as: :json, headers: bearer(@token)
            assert_response :bad_request

            patch "/api/v1/my/lists/favorites/books/#{@crime.slug}", params: {completed_on: nil, position: 1}, as: :json, headers: bearer(@token)
            assert_response :ok
            assert_equal [@crime.id, @wp.id], book_ids_on(@favorites)
          end

          test "completed_on on favorites is a 422" do
            add("favorites", {books: [@wp.slug], completed_on: "2024-03-01"})

            assert_response :unprocessable_entity
            assert_empty book_ids_on(@favorites)
          end

          test "an unknown body key is a 422" do
            add("read", {books: [@wp.slug], color: "red"})

            assert_response :unprocessable_entity
            assert_includes json[:detail], "color"
          end

          test "an unknown list is a 404" do
            add("nonsense", {books: [@wp.slug]})
            assert_response :not_found
          end

          test "a read-only token is a 403" do
            add("read", {books: [@wp.slug]}, token: ApiTokenSecrets::LIBRARY_READ)
            assert_response :forbidden
          end

          test "a failing service is a 422 and gives the reserved budget back" do
            ::Services::UserLists::AddItems.stubs(:call).returns(::Services::UserLists::MutationResult.failure(["boom"]))

            add("read", {books: [@wp.slug]})

            assert_response :unprocessable_entity
            assert_includes json[:detail], "boom"
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "an exception in the service gives the budget back" do
            ::Services::UserLists::AddItems.stubs(:call).raises(RuntimeError, "kaboom")

            assert_raises(RuntimeError) { add("read", {books: [@wp.slug]}) }
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "a call over the remaining budget is a 429 with Retry-After and writes nothing" do
            assert ::Services::Api::LibraryBudget.reserve(@user, 990).ok?
            extra = Array.new(18) { |i| ::Books::Book.create!(title: "Budget book #{i}") }

            add("read", {books: ([@wp, @crime] + extra).map(&:slug)})

            assert_response :too_many_requests
            assert_equal "rate_limited", json[:code]
            assert_operator response.headers["Retry-After"].to_i, :>=, 1
            assert_includes json[:detail], "10 remaining"
            assert_empty book_ids_on(@read)
            assert_equal 10, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "a call that fits the remaining budget exactly succeeds" do
            assert ::Services::Api::LibraryBudget.reserve(@user, 990).ok?
            extra = Array.new(8) { |i| ::Books::Book.create!(title: "Fit book #{i}") }

            add("read", {books: ([@wp, @crime] + extra).map(&:slug)})

            assert_response :ok
            assert_equal 0, json[:meta][:library_changes_remaining]
          end

          test "update sets, clears and moves" do
            [@wp, @crime, @got].each_with_index do |book, i|
              UserListItem.create!(user_list: @read, listable: book, position: i + 1)
            end

            patch "/api/v1/my/lists/read/books/#{@wp.slug}", params: {completed_on: "2024-03-01"}, as: :json, headers: bearer(@token)
            assert_api_conform(status: 200)
            assert_equal [{book: @wp.slug, outcome: "updated"}], json[:data]
            assert_equal Date.new(2024, 3, 1), UserListItem.find_by!(user_list: @read, listable: @wp).completed_on
            assert_equal 999, json[:meta][:library_changes_remaining]

            patch "/api/v1/my/lists/read/books/#{@wp.slug}", params: {completed_on: nil}, as: :json, headers: bearer(@token)
            assert_response :ok
            assert_nil UserListItem.find_by!(user_list: @read, listable: @wp).completed_on

            patch "/api/v1/my/lists/read/books/#{@got.slug}", params: {position: 1}, as: :json, headers: bearer(@token)
            assert_response :ok
            assert_equal [@got.id, @wp.id, @crime.id], book_ids_on(@read)
          end

          test "update with a position past the end is a 422" do
            UserListItem.create!(user_list: @read, listable: @wp, position: 1)

            patch "/api/v1/my/lists/read/books/#{@wp.slug}", params: {position: 99}, as: :json, headers: bearer(@token)

            assert_response :unprocessable_entity
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "update with a bad position, or no fields, is a 400" do
            UserListItem.create!(user_list: @read, listable: @wp, position: 1)

            [{}, {position: 0}, {position: "1"}, {position: 1.5}].each do |body|
              patch "/api/v1/my/lists/read/books/#{@wp.slug}", params: body, as: :json, headers: bearer(@token)
              assert_response :bad_request, body.inspect
            end
          end

          test "update of a book that is not on the list is a 422, of an unknown book a 404" do
            patch "/api/v1/my/lists/read/books/#{@wp.slug}", params: {position: 1}, as: :json, headers: bearer(@token)
            assert_response :unprocessable_entity

            patch "/api/v1/my/lists/read/books/no-such-book", params: {position: 1}, as: :json, headers: bearer(@token)
            assert_response :not_found
          end

          test "update with completed_on on favorites is a 422" do
            UserListItem.create!(user_list: @favorites, listable: @wp, position: 1)

            patch "/api/v1/my/lists/favorites/books/#{@wp.slug}", params: {completed_on: "2024-03-01"}, as: :json, headers: bearer(@token)

            assert_response :unprocessable_entity
          end

          test "remove reports removed and not_present and spends both" do
            UserListItem.create!(user_list: @read, listable: @wp, position: 1)

            delete "/api/v1/my/lists/read/books?books=#{@wp.slug},#{@crime.slug}", headers: bearer(@token)
            assert_api_conform(status: 200)

            assert_equal [{book: @wp.slug, outcome: "removed"}, {book: @crime.slug, outcome: "not_present"}], json[:data]
            assert_equal 998, json[:meta][:library_changes_remaining]
            assert_equal 0, json[:meta][:list][:book_count]
            assert_empty book_ids_on(@read)
          end

          test "remove with an unknown slug is a 404 naming it, writes nothing and spends nothing" do
            UserListItem.create!(user_list: @read, listable: @wp, position: 1)

            delete "/api/v1/my/lists/read/books?books=#{@wp.slug},nope-one", headers: bearer(@token)

            assert_response :not_found
            assert_includes json[:detail], "nope-one"
            assert_equal [@wp.id], book_ids_on(@read)
            assert_equal 1_000, ::Services::Api::LibraryBudget.remaining(@user)
          end

          test "remove cleans the query slugs: whitespace, a duplicate and a trailing blank count one book" do
            UserListItem.create!(user_list: @read, listable: @wp, position: 1)

            delete "/api/v1/my/lists/read/books?books=#{CGI.escape("#{@wp.slug}, #{@wp.slug},")}", headers: bearer(@token)

            assert_response :ok
            assert_equal [{book: @wp.slug, outcome: "removed"}], json[:data]
            assert_equal 999, json[:meta][:library_changes_remaining]
          end

          test "a non-string entry in books is a 400 about slug strings" do
            add("read", {books: [@wp.slug, 5]})

            assert_response :bad_request
            assert_includes json[:detail], "slug strings"
          end

          test "remove without books, or with too many, is a 400" do
            delete "/api/v1/my/lists/read/books", headers: bearer(@token)
            assert_response :bad_request
            delete "/api/v1/my/lists/read/books?books=#{(1..51).map { |i| "b#{i}" }.join(",")}", headers: bearer(@token)
            assert_response :bad_request
          end
        end
      end
    end
  end
end
