require "test_helper"

module Api
  module V1
    module Books
      class LanguagesControllerTest < ActionDispatch::IntegrationTest
        # Catalogue counts: english 3 (got, clash, of_mice_and_men), russian 2
        # (war_and_peace, crime_and_punishment, from the fixtures), french 1
        # (cannery_row). Default order is english, russian, french; name order is
        # english, french, russian, so a dropped `sort` shows. Latin is only the
        # language of a provisional book, so it is absent.
        setup do
          host! "dev-new.thegreatestbooks.org"
          [:got, :clash, :of_mice_and_men].each { |b| books_books(b).update_column(:original_language_id, languages(:english).id) }
          books_books(:cannery_row).update_column(:original_language_id, languages(:french).id)
          ::Books::Book.create!(title: "Provisional Latin Work", provisional: true, book_kind: :standalone, original_language: languages(:latin))
        end

        def json = response.parsed_body.deep_symbolize_keys

        test "lists languages of catalogue books, most books first, with slug, name and book_count" do
          get "/api/v1/languages", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[english russian french], json[:data].map { |l| l[:slug] }
          assert_equal [3, 2, 1], json[:data].map { |l| l[:book_count] }
          assert_equal %i[slug name book_count], json[:data].first.keys
          assert_equal "English", json[:data].first[:name]
          assert_equal 3, json[:meta][:total_count]
        end

        test "a language only a provisional book has is not listed" do
          get "/api/v1/languages", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_not_includes json[:data].map { |l| l[:slug] }, "latin"
        end

        test "sort=name orders by name" do
          get "/api/v1/languages?sort=name", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal %w[english french russian], json[:data].map { |l| l[:slug] }
          assert_equal [3, 1, 2], json[:data].map { |l| l[:book_count] }
        end

        test "sort rides on the paging links, and following next continues the same list" do
          get "/api/v1/languages?sort=name&per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          next_link = json[:links][:next]
          assert_includes next_link, "sort=name"
          assert_equal %w[english], json[:data].map { |l| l[:slug] }

          get URI.parse(next_link).request_uri, headers: bearer(ApiTokenSecrets::MEMBER)
          assert_equal %w[french], json[:data].map { |l| l[:slug] }
        end

        test "an unknown sort is a 400 naming sort" do
          get "/api/v1/languages?sort=popularity", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_equal "invalid_parameter", json[:code]
          assert_includes json[:detail], "sort"
        end

        test "without a token it is a 401" do
          get "/api/v1/languages"
          assert_api_conform(status: 401)
        end

        test "a token without books:read is a 403" do
          get "/api/v1/languages", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_api_conform(status: 403)
        end
      end
    end
  end
end
