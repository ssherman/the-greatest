require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class BooksControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @war = books_books(:war_and_peace)
            @crime = books_books(:crime_and_punishment)
            @mice = books_books(:of_mice_and_men)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def hits(*books) = books.map { |book| {id: book.id.to_s, score: 1.0, source: {}} }

          test "results follow the search order, not id order" do
            ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@mice, @war, @crime))

            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [@mice.id, @war.id, @crime.id], json[:data].map { |b| b[:id] }
            assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          end

          test "searches every kind and includes provisional books" do
            ::Search::Books::Search::BookGeneral.expects(:call)
              .with("war", size: 1000, book_kind: nil, include_provisional: true).returns(hits(@war))
            @war.update!(provisional: true)

            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [true], json[:data].map { |b| b[:provisional] }
          end

          test "renders rank, kind and authors" do
            RankedItem.create!(item: @war, ranking_configuration: ranking_configurations(:books_global), rank: 7, score: 1)
            ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@war))

            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            row = json[:data].first
            assert_equal [7, "standalone", [{id: books_authors(:tolstoy).id, slug: "leo-tolstoy", name: "Leo Tolstoy"}]],
              [row[:rank], row[:book_kind], row[:authors]]
          end

          test "pagination links carry q and can be followed" do
            ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@mice, @war, @crime))

            get "/api/v1/admin/books", params: {q: "war & peace", per_page: 2}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)
            next_link = json[:links][:next]

            assert_includes next_link, "q=war+%26+peace"
            get next_link, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [2, [@crime.id]], [json[:meta][:page], json[:data].map { |b| b[:id] }]
          end

          test "no hits is an empty page" do
            ::Search::Books::Search::BookGeneral.stubs(:call).returns([])

            get "/api/v1/admin/books", params: {q: "zzz"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [[], 0], [json[:data], json[:meta][:total_count]]
          end

          test "a missing q is a 400 and never searches" do
            ::Search::Books::Search::BookGeneral.expects(:call).never

            get "/api/v1/admin/books", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 400, api: :admin)

            assert_equal ["invalid_parameter", "q is required"], [json[:code], json[:detail]]
          end

          test "a blank q is a 400" do
            ::Search::Books::Search::BookGeneral.expects(:call).never

            get "/api/v1/admin/books?q=%20", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "a public read token is refused with insufficient_scope" do
            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "insufficient_scope", json[:code]
          end

          test "an admin merge token implies read" do
            ::Search::Books::Search::BookGeneral.stubs(:call).returns(hits(@war))

            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::ADMIN)

            assert_response :success
          end

          test "the route does not exist on the music host" do
            host! "dev.thegreatestmusic.org"

            get "/api/v1/admin/books", params: {q: "war"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)

            assert_response :not_found
          end

          test "show returns every editable field, the authors and the cleared field names" do
            ClearedField.create!(clearable: @war, field_name: "subtitle", cleared_via: :api)
            ClearedField.create!(clearable: @war, field_name: "first_published_year", cleared_via: :api)

            get "/api/v1/admin/books/#{@war.id}", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            data = json[:data]
            assert_equal %i[id slug title subtitle sort_title first_published_year book_kind original_language alternate_titles provisional authors cleared_fields], data.keys
            assert_equal [@war.id, "War and Peace", 1869, "standalone", ["Voyna i mir"], false],
              [data[:id], data[:title], data[:first_published_year], data[:book_kind], data[:alternate_titles], data[:provisional]]
            assert_equal({id: @war.original_language_id, name: @war.original_language.name}, data[:original_language])
            assert_equal @war.authors.map(&:id).sort, data[:authors].map { |a| a[:id] }.sort
            assert_equal %w[first_published_year subtitle], data[:cleared_fields]
          end

          test "show gives a null original_language and no cleared fields when there are none" do
            @war.update!(original_language: nil)

            get "/api/v1/admin/books/#{@war.id}", headers: bearer(ApiTokenSecrets::ADMIN_READ)

            assert_nil json[:data][:original_language]
            assert_equal [], json[:data][:cleared_fields]
          end

          test "show of an unknown book is a 404" do
            get "/api/v1/admin/books/999999999", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "show refuses a non-admin token" do
            get "/api/v1/admin/books/#{@war.id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end

          # -- update ------------------------------------------------------

          def patch_book(body, book: @war, token: ApiTokenSecrets::ADMIN)
            patch "/api/v1/admin/books/#{book.id}", params: body, as: :json, headers: bearer(token)
          end

          test "update changes only the fields sent and lists them in changed" do
            before = @war.slice(:title, :first_published_year, :alternate_titles)

            patch_book({subtitle: "A novel of 1812"})
            assert_api_response_conform(status: 200, api: :admin)

            @war.reload
            assert_equal "A novel of 1812", @war.subtitle
            assert_equal before, @war.slice(:title, :first_published_year, :alternate_titles)
            assert_equal ["subtitle"], json[:changed]
            assert_equal "A novel of 1812", json[:data][:subtitle]
            assert_equal [], json[:data][:cleared_fields]
          end

          test "update accepts every editable field and resolves enum names and the language" do
            french = languages(:french)

            patch_book({title: "Guerre", sort_title: "Guerre", first_published_year: 1870, book_kind: "collection",
                        original_language_id: french.id, alternate_titles: ["  La guerre ", "", "Krieg"]})
            assert_api_response_conform(status: 200, api: :admin)

            @war.reload
            assert_equal ["Guerre", 1870, "collection", french.id, ["La guerre", "Krieg"]],
              [@war.title, @war.first_published_year, @war.book_kind, @war.original_language_id, @war.alternate_titles]
            assert_equal "collection", json[:data][:book_kind]
          end

          test "null on a year clears it, writes an api row and enrichment then leaves it blank" do
            assert_difference -> { ClearedField.where(clearable: @war).count }, 1 do
              patch_book({first_published_year: nil})
            end
            assert_api_response_conform(status: 200, api: :admin)

            row = ClearedField.find_by!(clearable: @war, field_name: "first_published_year")
            assert_equal ["api", users(:admin_user).id], [row.cleared_via, row.cleared_by_id]
            assert_nil @war.reload.first_published_year
            assert_includes json[:data][:cleared_fields], "first_published_year"

            facts = {first_published_year: {value: 1869, confidence: "high"}}
            Services::Books::ApplyBookFacts.call(book: @war, facts: facts, citations: [], description: nil)
            assert_nil @war.reload.first_published_year
          end

          test "an empty string clears a clearable scalar like null" do
            @war.update!(subtitle: "Old")

            patch_book({subtitle: ""})
            assert_api_response_conform(status: 200, api: :admin)

            assert_nil @war.reload.subtitle
            assert ClearedField.exists?(clearable: @war, field_name: "subtitle")
          end

          test "whitespace only on an already blank subtitle writes a row" do
            @war.update!(subtitle: nil)

            assert_difference -> { ClearedField.where(clearable: @war).count }, 1 do
              patch_book({subtitle: "   "})
            end
            assert_response :ok
            assert_nil @war.reload.subtitle
          end

          test "null on an already blank year writes a row" do
            @war.update!(first_published_year: nil)

            assert_difference -> { ClearedField.where(clearable: @war).count }, 1 do
              patch_book({first_published_year: nil})
            end
            assert_api_response_conform(status: 200, api: :admin)
          end

          test "setting a value again deletes the row" do
            ClearedField.create!(clearable: @war, field_name: "first_published_year", cleared_via: :api)
            @war.update!(first_published_year: nil)

            patch_book({first_published_year: 1869})

            assert_not ClearedField.exists?(clearable: @war, field_name: "first_published_year")
            assert_equal [], json[:data][:cleared_fields]
          end

          test "zero is a year, not a blank" do
            patch_book({first_published_year: 0})

            assert_equal 0, @war.reload.first_published_year
            assert_not ClearedField.exists?(clearable: @war, field_name: "first_published_year")
          end

          test "a failed save writes nothing" do
            before = @war.slice(:title, :first_published_year, :alternate_titles)

            assert_no_difference "ClearedField.count" do
              patch_book({title: "", first_published_year: nil, alternate_titles: ["x"]})
            end
            assert_api_response_conform(status: 422, api: :admin)

            assert_equal before, @war.reload.slice(:title, :first_published_year, :alternate_titles)
          end

          test "an unknown key is a 422 naming it" do
            patch_book({subtitle: "x", slug: "nope"})
            assert_api_response_conform(status: 422, api: :admin)

            assert_includes json[:detail], "slug"
            assert_not_equal "x", @war.reload.subtitle
          end

          test "wrong JSON types are a 400" do
            [{first_published_year: "abc"}, {first_published_year: 5000}, {first_published_year: -3001}, {first_published_year: 1.5},
              {title: 5}, {title: nil}, {subtitle: 5}, {alternate_titles: "x"}, {alternate_titles: [1]}, {original_language_id: "x"},
              {book_kind: 1}].each do |body|
              patch_book(body)
              assert_response :bad_request, body.inspect
            end
          end

          test "year bounds are inclusive" do
            patch_book({first_published_year: -3000})
            assert_response :ok
            patch_book({first_published_year: 3000})
            assert_response :ok
          end

          test "an empty body is a 400" do
            patch_book({})
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "an unknown enum name and an unknown language are a 422" do
            language_id = @war.original_language_id

            patch_book({book_kind: "bogus"})
            assert_api_response_conform(status: 422, api: :admin)

            patch_book({original_language_id: 999_999_999})
            assert_api_response_conform(status: 422, api: :admin)
            assert_equal language_id, @war.reload.original_language_id
          end

          test "update of an unknown book is a 404" do
            patch "/api/v1/admin/books/999999999", params: {subtitle: "x"}, as: :json, headers: bearer(ApiTokenSecrets::ADMIN)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "update refuses a non-admin token and a read-only token" do
            patch_book({subtitle: "x"}, token: ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)

            patch_book({subtitle: "x"}, token: ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 403, api: :admin)
            assert_not_equal "x", @war.reload.subtitle
          end
        end
      end
    end
  end
end
