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

          def create_series_sorting_first
            ::Books::Series.create!(title: "AAA Short Run").tap do |series|
              ::Books::SeriesBook.create!(series: series, book: books_books(:war_and_peace), position: 1)
            end
          end

          test "sort=book_count orders by count descending, then id, unlike the title order" do
            short = create_series_sorting_first
            live = books_series(:live_target)

            list
            assert_equal [short.id, @asoiaf.id, live.id], json[:data].map { |row| row[:id] }

            list(sort: "book_count")
            assert_equal [@asoiaf.id, short.id, live.id], json[:data].map { |row| row[:id] }
            assert_equal [3, 1, 0], json[:data].map { |row| row[:book_count] }
          end

          test "equal book counts fall back to id" do
            first = create_series_sorting_first
            second = ::Books::Series.create!(title: "ZZZ Short Run")
            ::Books::SeriesBook.create!(series: second, book: books_books(:of_mice_and_men), position: 1)

            list(sort: "book_count", max_books: 1, min_books: 1)

            assert_equal [first.id, second.id].sort, json[:data].map { |row| row[:id] }
          end

          test "paging with sort=book_count returns the right row on each page" do
            short = create_series_sorting_first

            list(sort: "book_count", per_page: 1, page: 2)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [short.id], json[:data].map { |row| row[:id] }
            assert_equal 3, json[:meta][:total_count]
          end

          test "min_books 1 with max_books 1 returns single-book series and not empty ones" do
            short = create_series_sorting_first

            list(min_books: 1, max_books: 1)

            assert_equal [short.id], json[:data].map { |row| row[:id] }
            list(max_books: 1)
            assert_includes json[:data].map { |row| row[:id] }, books_series(:live_target).id
          end

          test "a row carries the count and the goodreads id" do
            @asoiaf.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "45")

            list(q: "ice and fire")

            assert_equal [{id: @asoiaf.id, slug: @asoiaf.slug, title: @asoiaf.title, book_count: 3, goodreads_series_id: "45", deleted: false, merged_into_id: nil}],
              json[:data]
          end

          test "show carries the goodreads id, or null when there is none" do
            @asoiaf.identifiers.create!(identifier_type: :books_series_goodreads_id, value: "45")

            get "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(READ)
            assert_equal "45", json[:data][:goodreads_series_id]

            get "/api/v1/admin/series/#{books_series(:live_target).id}", headers: bearer(READ)
            assert_nil json[:data][:goodreads_series_id]
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
