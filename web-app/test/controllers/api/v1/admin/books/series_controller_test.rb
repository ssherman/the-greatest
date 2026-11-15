require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class SeriesControllerTest < ActionDispatch::IntegrationTest
          READ = ApiTokenSecrets::ADMIN_READ

          setup do
            host! "dev-new.thegreatestbooks.org"
            @asoiaf = books_series(:asoiaf)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def titles = json[:data].map { |row| row[:title] }

          def list(params = {})
            get "/api/v1/admin/series", params: {per_page: 100}.merge(params), headers: bearer(READ)
          end

          test "the default list excludes deleted and merged series" do
            list
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal ::Books::Series.active.order(:title).pluck(:title), titles
            assert_not_includes titles, "Junk Deleted Series"
          end

          test "include_deleted lists the deleted and merged ones too" do
            list(include_deleted: "true")

            assert_equal ::Books::Series.order(:title).pluck(:title), titles
            assert_includes titles, "Merged Into Live"
          end

          test "q matches the title case-insensitively" do
            list(q: "SONG of ice")

            assert_equal ["A Song of Ice and Fire"], titles
          end

          test "max_books and min_books filter on the book count in SQL" do
            list(max_books: 1)
            assert_not_includes titles, @asoiaf.title
            assert_includes titles, "Live Merge Target"

            list(min_books: 2)
            assert_equal [@asoiaf.title], titles
          end

          test "sort=book_count orders by count descending, then id" do
            list(sort: "book_count")

            assert_equal @asoiaf.id, json[:data].first[:id]
            rest = json[:data].drop(1)
            assert_equal rest.map { |row| row[:id] }.sort, rest.map { |row| row[:id] }
            assert_equal [3, 0], [json[:data].first[:book_count], json[:data].last[:book_count]]
          end

          test "paging works with a book_count filter and sort" do
            list(min_books: 0, sort: "book_count", per_page: 1, page: 2)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [2, 1], [json[:meta][:page], json[:data].size]
            assert_equal ::Books::Series.active.count, json[:meta][:total_count]
          end

          test "a row carries the count and the goodreads id" do
            @asoiaf.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "45")

            list(q: "ice and fire")

            assert_equal [{id: @asoiaf.id, slug: @asoiaf.slug, title: @asoiaf.title, book_count: 3, goodreads_series_id: "45", deleted: false, merged_into_id: nil}],
              json[:data]
          end

          test "bad sort or a non-integer bound is a 400" do
            [{sort: "rank"}, {min_books: "two"}, {max_books: "-1"}, {include_deleted: "maybe"}].each do |bad|
              list(bad)
              assert_api_response_conform(status: 400, api: :admin)
            end
          end

          test "a member token is forbidden" do
            get "/api/v1/admin/series", headers: bearer(ApiTokenSecrets::MEMBER)

            assert_response :forbidden
          end

          test "show orders books by position with unpositioned last and emits position as a number" do
            ::Books::SeriesBook.create!(series: @asoiaf, book: books_books(:war_and_peace), position: nil, numbered: false)

            get "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            books = json[:data][:books]
            assert_equal [books_books(:got).id, books_books(:crime_and_punishment).id, books_books(:clash).id, books_books(:war_and_peace).id],
              books.map { |b| b[:id] }
            assert_equal [1.0, 1.5, 2.0, nil], books.map { |b| b[:position] }
            assert_kind_of Float, books[1][:position]
            assert_equal [true, false], [books[0][:numbered], books[1][:numbered]]
            assert_equal %w[id title slug first_published_year authors position numbered position_label].sort, books.first.keys.map(&:to_s).sort
            assert_nil json[:data][:representative_book]
          end

          test "show carries the representative book" do
            @asoiaf.update!(representative_book: books_books(:got))

            get "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(READ)

            assert_equal({id: books_books(:got).id, title: books_books(:got).title}, json[:data][:representative_book])
          end

          test "show answers for a merged series with deleted and merged_into_id" do
            merged = books_series(:merged_into_live)

            get "/api/v1/admin/series/#{merged.id}", headers: bearer(READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [true, books_series(:live_target).id], [json[:data][:deleted], json[:data][:merged_into_id]]
          end

          test "show of an unknown id is 404" do
            get "/api/v1/admin/series/999999999", headers: bearer(READ)

            assert_response :not_found
          end
        end
      end
    end
  end
end
