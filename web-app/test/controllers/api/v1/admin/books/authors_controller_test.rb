require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class AuthorsControllerTest < ActionDispatch::IntegrationTest
          setup do
            host! "dev-new.thegreatestbooks.org"
            @tolstoy = books_authors(:tolstoy)
            @king = books_authors(:king)
          end

          def json = response.parsed_body.deep_symbolize_keys

          def hits(*authors) = authors.map { |author| {id: author.id.to_s, score: 1.0, source: {}} }

          test "results follow the search order and carry book_count" do
            ::Search::Books::Search::AuthorGeneral.expects(:call).with("t", size: 1000).returns(hits(@king, @tolstoy))

            get "/api/v1/admin/authors", params: {q: "t"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [[@king.id, 2], [@tolstoy.id, 1]], json[:data].map { |a| [a[:id], a[:book_count]] }
            assert_equal ["person", false, 1828, 1910], json[:data].last.values_at(:kind, :provisional, :birth_year, :death_year)
          end

          test "renders the primary author rank, null when unranked" do
            RankedItem.create!(item: @tolstoy, ranking_configuration: ranking_configurations(:books_authors_global), rank: 4, score: 1)
            ::Search::Books::Search::AuthorGeneral.stubs(:call).returns(hits(@tolstoy, @king))

            get "/api/v1/admin/authors", params: {q: "t"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [4, nil], json[:data].map { |a| a[:rank] }
          end

          test "pagination links carry q and can be followed" do
            ::Search::Books::Search::AuthorGeneral.stubs(:call).returns(hits(@king, @tolstoy))

            get "/api/v1/admin/authors", params: {q: "t", per_page: 1}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            next_link = json[:links][:next]

            assert_includes next_link, "q=t"
            get next_link, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal [@tolstoy.id], json[:data].map { |a| a[:id] }
          end

          test "includes provisional authors" do
            @king.update!(provisional: true)
            ::Search::Books::Search::AuthorGeneral.stubs(:call).returns(hits(@king))

            get "/api/v1/admin/authors", params: {q: "king"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [true], json[:data].map { |a| a[:provisional] }
          end

          test "no hits is an empty page" do
            ::Search::Books::Search::AuthorGeneral.stubs(:call).returns([])

            get "/api/v1/admin/authors", params: {q: "zzz"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            assert_equal [], json[:data]
          end

          test "a missing or blank q is a 400" do
            ::Search::Books::Search::AuthorGeneral.expects(:call).never

            get "/api/v1/admin/authors", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 400, api: :admin)
            get "/api/v1/admin/authors?q=%20", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "a public read token is refused with insufficient_scope" do
            get "/api/v1/admin/authors", params: {q: "t"}, headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)

            assert_equal "insufficient_scope", json[:code]
          end

          test "the route does not exist on the music host" do
            host! "dev.thegreatestmusic.org"

            get "/api/v1/admin/authors", params: {q: "t"}, headers: bearer(ApiTokenSecrets::ADMIN_READ)

            assert_response :not_found
          end

          test "show returns every editable field and the cleared field names" do
            author = books_authors(:tolstoy)
            ClearedField.create!(clearable: author, field_name: "death_year", cleared_via: :api)
            ClearedField.create!(clearable: author, field_name: "birth_year", cleared_via: :api)

            get "/api/v1/admin/authors/#{author.id}", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 200, api: :admin)

            data = response.parsed_body.deep_symbolize_keys[:data]
            assert_equal %i[id slug name sort_name kind birth_year death_year exclude_from_rankings alternate_names provisional cleared_fields], data.keys
            assert_equal [author.id, "Leo Tolstoy", "person", 1828, 1910, false, ["Lev Tolstoy", "Lev Nikolayevich Tolstoy"]],
              [data[:id], data[:name], data[:kind], data[:birth_year], data[:death_year], data[:exclude_from_rankings], data[:alternate_names]]
            assert_equal %w[birth_year death_year], data[:cleared_fields]
          end

          test "show of an unknown author is a 404" do
            get "/api/v1/admin/authors/999999999", headers: bearer(ApiTokenSecrets::ADMIN_READ)
            assert_api_response_conform(status: 404, api: :admin)
          end

          test "show refuses a non-admin token" do
            get "/api/v1/admin/authors/#{books_authors(:tolstoy).id}", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_response_conform(status: 403, api: :admin)
          end
        end
      end
    end
  end
end
