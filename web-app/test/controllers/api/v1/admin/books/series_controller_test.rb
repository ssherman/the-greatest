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

          # --- writes ---

          MERGE = ApiTokenSecrets::ADMIN

          def write_secret
            @write_secret ||= Services::Api::Tokens.generate(
              user: users(:admin_user), name: "series-write", scopes: ["books:admin:write"], expires_at: 1.day.from_now
            ).data[:secret]
          end

          def raw(verb, path, body, token: MERGE)
            send(verb, path, params: body, headers: bearer(token).merge("CONTENT_TYPE" => "application/json"))
          end

          def create_series(body, token: MERGE) = raw(:post, "/api/v1/admin/series", body.is_a?(String) ? body : body.to_json, token: token)

          def change(series, body, token: MERGE) = raw(:patch, "/api/v1/admin/series/#{series.id}", body.is_a?(String) ? body : body.to_json, token: token)

          def merge(target, body, token: MERGE) = raw(:post, "/api/v1/admin/series/#{target.id}/merge", body.to_json, token: token)

          test "create makes a series with no Goodreads id" do
            assert_difference -> { ::Books::Series.count }, 1 do
              create_series({title: "Brand New Saga"})
            end
            assert_api_response_conform(status: 201, api: :admin)

            assert_equal ["Brand New Saga", nil, 0], [json[:data][:title], json[:data][:goodreads_series_id], json[:data][:book_count]]
          end

          test "create with a Goodreads id stores it" do
            create_series({title: "Brand New Saga", goodreads_series_id: "55555"})
            assert_api_response_conform(status: 201, api: :admin)

            assert_equal "55555", json[:data][:goodreads_series_id]
          end

          test "create refuses a Goodreads id another series holds and creates nothing" do
            Identifier.create!(identifiable: @asoiaf, identifier_type: :books_series_goodreads_id, value: "777", source: :admin)

            assert_no_difference -> { ::Books::Series.count } do
              create_series({title: "Another", goodreads_series_id: "777"})
            end
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "create with a blank title is 422 and a non-string or missing title is 400" do
            create_series({title: "  "})
            assert_api_response_conform(status: 422, api: :admin)

            create_series({title: 5})
            assert_api_response_conform(status: 400, api: :admin)

            create_series({})
            assert_api_response_conform(status: 400, api: :admin)

            create_series("not json")
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "create with an unknown key is 422" do
            create_series({title: "X", bogus: 1})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "update renames the series" do
            change(@asoiaf, {title: "ASOIAF"})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal "ASOIAF", @asoiaf.reload.title
            assert_equal "ASOIAF", json[:data][:title]
          end

          test "update with an empty body is 400 and an unknown key is 422" do
            change(@asoiaf, {})
            assert_api_response_conform(status: 400, api: :admin)

            change(@asoiaf, {bogus: 1})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "update with wrong JSON types is 400" do
            change(@asoiaf, {title: 5})
            assert_response :bad_request
            change(@asoiaf, {representative_book_id: "x"})
            assert_response :bad_request
            change(@asoiaf, {goodreads_series_id: 12})
            assert_response :bad_request
          end

          test "update sets and clears the representative book" do
            change(@asoiaf, {representative_book_id: books_books(:got).id})
            assert_equal books_books(:got).id, @asoiaf.reload.representative_book_id

            change(@asoiaf, {representative_book_id: nil})
            assert_response :success
            assert_nil @asoiaf.reload.representative_book_id
          end

          test "update refuses a representative book that is not in the series" do
            change(@asoiaf, {representative_book_id: books_books(:war_and_peace).id})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "update of a merged or deleted series is 422" do
            change(books_series(:merged_into_live), {title: "Nope"})
            assert_api_response_conform(status: 422, api: :admin)

            change(books_series(:junk_deleted), {title: "Nope"})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "update of an unknown series is 404" do
            raw(:patch, "/api/v1/admin/series/999999999", {title: "x"}.to_json)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "delete soft-deletes the series and reports the book count" do
            delete "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(MERGE)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [@asoiaf.id, true, 3], [json[:data][:id], json[:data][:deleted], json[:data][:book_count]]
            assert_nil json[:meta]
            assert @asoiaf.reload.deleted?
            assert_equal 0, @asoiaf.series_books.count
          end

          test "delete dry run changes nothing" do
            delete "/api/v1/admin/series/#{@asoiaf.id}", params: {dry_run: "true"}, headers: bearer(MERGE)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [3, true], [json[:data][:book_count], json[:meta][:dry_run]]
            assert_not @asoiaf.reload.deleted?
            assert_equal 3, @asoiaf.series_books.count
          end

          test "delete with a bad dry_run is 400 and of a deleted series is 422" do
            delete "/api/v1/admin/series/#{@asoiaf.id}", params: {dry_run: "maybe"}, headers: bearer(MERGE)
            assert_api_response_conform(status: 400, api: :admin)

            delete "/api/v1/admin/series/#{books_series(:junk_deleted).id}", headers: bearer(MERGE)
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "merge dry run reports moved and dropped and changes nothing" do
            target = books_series(:live_target)
            merge(target, {source_ids: [@asoiaf.id], dry_run: true})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [{id: @asoiaf.id, title: @asoiaf.title, moved: 3, dropped: 0}], json[:data][:sources]
            assert_equal true, json[:meta][:dry_run]
            assert_not @asoiaf.reload.deleted?
            assert_equal 0, target.series_books.count
          end

          test "merge moves the books and soft-deletes the source" do
            target = books_series(:live_target)
            merge(target, {source_ids: [@asoiaf.id]})
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal 3, json[:data][:target][:books].size
            assert_nil json[:meta]
            assert_equal [true, target.id], [@asoiaf.reload.deleted?, @asoiaf.merged_into_id]
          end

          test "merge with a source equal to the target or a bad source_ids is 400" do
            merge(@asoiaf, {source_ids: [@asoiaf.id]})
            assert_api_response_conform(status: 400, api: :admin)

            [[], "x", [1, 1], ["a"], (1..51).to_a].each do |bad|
              merge(@asoiaf, {source_ids: bad})
              assert_response :bad_request
            end
            merge(@asoiaf, {source_ids: [books_series(:live_target).id], dry_run: "yes"})
            assert_response :bad_request
          end

          test "merge refusal is 422 and unknown ids are 404" do
            merge(books_series(:live_target), {source_ids: [books_series(:junk_deleted).id]})
            assert_api_response_conform(status: 422, api: :admin)

            merge(books_series(:live_target), {source_ids: [999_999_999]})
            assert_api_response_conform(status: 404, api: :admin)

            merge(books_series(:merged_into_live), {source_ids: [@asoiaf.id]})
            assert_api_response_conform(status: 422, api: :admin)
          end

          test "a failure part way reports merged, failed and not_attempted" do
            target = books_series(:live_target)
            second = ::Books::Series.create!(title: "Second")
            third = ::Books::Series.create!(title: "Third")
            ::Services::Books::SeriesEdits::Merge.stubs(:call).returns(
              ::Services::Books::SeriesEdits::Result.new(success?: true, data: {moved: 1, dropped: 0}, errors: []),
              ::Services::Books::SeriesEdits::Result.new(success?: false, errors: ["boom"], code: :unprocessable)
            )

            merge(target, {source_ids: [@asoiaf.id, second.id, third.id]})
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal [@asoiaf.id], json[:merged]
            assert_equal second.id, json[:failed][:id]
            assert_equal [third.id], json[:not_attempted]
          end

          test "read and write tokens are refused on delete and merge, a read token on create and update" do
            delete "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(write_secret)
            assert_response :forbidden
            merge(books_series(:live_target), {source_ids: [@asoiaf.id]}, token: write_secret)
            assert_response :forbidden
            merge(books_series(:live_target), {source_ids: [@asoiaf.id]}, token: READ)
            assert_response :forbidden
            create_series({title: "x"}, token: READ)
            assert_response :forbidden
            change(@asoiaf, {title: "x"}, token: READ)
            assert_response :forbidden
          end

          test "a write token can create and update" do
            create_series({title: "Written"}, token: write_secret)
            assert_response :created
            change(@asoiaf, {title: "Rewritten"}, token: write_secret)
            assert_response :success
          end

          test "an account the policy refuses gets 403" do
            ::Books::SeriesPolicy.any_instance.stubs(:create?).returns(false)
            ::Books::SeriesPolicy.any_instance.stubs(:update?).returns(false)
            ::Books::SeriesPolicy.any_instance.stubs(:destroy?).returns(false)

            create_series({title: "x"})
            assert_response :forbidden
            change(@asoiaf, {title: "x"})
            assert_response :forbidden
            delete "/api/v1/admin/series/#{@asoiaf.id}", headers: bearer(MERGE)
            assert_response :forbidden
            merge(books_series(:live_target), {source_ids: [@asoiaf.id]})
            assert_response :forbidden
          end
        end
      end
    end
  end
end
