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
