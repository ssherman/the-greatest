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
        end
      end
    end
  end
end
