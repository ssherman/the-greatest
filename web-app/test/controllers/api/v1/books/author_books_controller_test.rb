require "test_helper"

module Api
  module V1
    module Books
      class AuthorBooksControllerTest < ActionDispatch::IntegrationTest
        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          @king = books_authors(:king)
          @got = books_books(:got)
          @clash = books_books(:clash)
        end

        def json = response.parsed_body.deep_symbolize_keys

        def write_king_book(title, year: nil, role: :author, provisional: false)
          book = ::Books::Book.create!(title: title, first_published_year: year, provisional: provisional)
          ::Books::BookAuthor.create!(book: book, author: @king, role: role)
          book
        end

        def rank(book, position, config: @rc)
          RankedItem.create!(item: book, ranking_configuration: config, rank: position, score: 100 - position)
        end

        def count_queries(&block)
          count = 0
          counter = ->(_name, _start, _finish, _id, payload) {
            count += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION])
          }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
          count
        end

        test "returns the author's books, ranked first in rank order then unranked with a null rank" do
          rank(@clash, 1)
          rank(@got, 2)
          older = write_king_book("An Older Unranked", year: 1800)
          undated = write_king_book("Undated Unranked")

          get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@clash, @got, older, undated].map(&:slug), json[:data].map { |b| b[:slug] }
          assert_equal [1, 2, nil, nil], json[:data].map { |b| b[:rank] }
          assert_equal %i[api_url authors cover_url first_published_year id rank slug subtitle title url],
            json[:data].first.keys.sort
          assert_equal 4, json[:meta][:total_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors/#{@king.slug}/books?page=1&per_page=50", json[:links][:self]
        end

        test "leaves out edited and provisional books, and total_count matches" do
          authored = write_king_book("Authored")
          edited = write_king_book("Edited Anthology", role: :editor)
          provisional = write_king_book("Unapproved", provisional: true)
          rank(edited, 3)
          rank(provisional, 4)

          get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          slugs = json[:data].map { |b| b[:slug] }
          assert_includes slugs, authored.slug
          assert_not_includes slugs, edited.slug
          assert_not_includes slugs, provisional.slug
          assert_equal 3, json[:meta][:total_count]
          assert_equal slugs.size, json[:meta][:total_count]
        end

        test "under a configuration, rank is relative to it and links stay nested" do
          year = ranking_configurations(:books_year_2025)
          rank(@clash, 1)
          rank(@got, 2)
          rank(@got, 1, config: year)
          rank(@clash, 2, config: year)

          get "/api/v1/ranking_configurations/#{year.id}/authors/#{@king.slug}/books?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@got.slug], json[:data].map { |b| b[:slug] }
          assert_equal [1], json[:data].map { |b| b[:rank] }
          assert_equal 2, json[:meta][:total_count]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{year.id}/authors/#{@king.slug}/books?page=1&per_page=1",
            json[:links][:self]
          assert json[:links][:next].start_with?("https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{year.id}/authors/#{@king.slug}/books"),
            json[:links][:next]

          get json[:links][:next], headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)
          assert_equal [@clash.slug], json[:data].map { |b| b[:slug] }
          assert_equal [2], json[:data].map { |b| b[:rank] }
        end

        test "an unknown author is a 404, and so is a provisional one" do
          get "/api/v1/authors/no-such-author/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
          assert_equal "not_found", json[:code]

          @king.update!(provisional: true)

          get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 404)
        end

        test "an archived or unknown configuration is a 404 even for a known author" do
          archived = ranking_configurations(:books_inherited)
          archived.update!(archived: true)

          [archived.id, ranking_configurations(:books_user).id, ranking_configurations(:books_authors_global).id, 999_999_999].each do |id|
            get "/api/v1/ranking_configurations/#{id}/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
            assert_api_conform(status: 404)

            assert_equal "No ranking configuration at that address", json[:detail], id
          end
        end

        test "a missing configuration beats an unknown author and a bad page" do
          get "/api/v1/ranking_configurations/999999999/authors/no-such-author/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 404)

          assert_equal "No ranking configuration at that address", json[:detail]
        end

        test "an unknown author beats a bad page" do
          get "/api/v1/authors/no-such-author/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_response :not_found
        end

        test "a bad page is a 400" do
          get "/api/v1/authors/#{@king.slug}/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_response_conform(status: 400)

          assert_response :bad_request
        end

        test "with no primary configuration every rank is null" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          assert_equal [@clash, @got].map(&:slug).sort, json[:data].map { |b| b[:slug] }.sort
          assert_equal [nil, nil], json[:data].map { |b| b[:rank] }
        end

        test "the bare path ignores a ranking_configuration_id query parameter" do
          year = ranking_configurations(:books_year_2025)
          rank(@got, 1, config: year)

          get "/api/v1/authors/#{@king.slug}/books?ranking_configuration_id=#{year.id}", headers: bearer(ApiTokenSecrets::MEMBER)
          # Response-only: the parameter is deliberately undocumented.
          assert_api_response_conform(status: 200)

          assert_equal [nil, nil], json[:data].map { |b| b[:rank] }
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/authors/#{@king.slug}/books?page=1&per_page=50", json[:links][:self]
        end

        test "query count does not grow with the number of books" do
          seed = lambda do |count, from|
            count.times do |i|
              book = write_king_book("Seeded Book #{from + i}", year: 1900 + i)
              rank(book, from + i + 10) if i.even?
            end
          end

          seed.call(3, 0)
          # Warm up: the first request pays one-off lookups (token, rate limiter) the later ones skip.
          get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER)
          small = count_queries { get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_response :ok

          seed.call(12, 100)
          large = count_queries { get "/api/v1/authors/#{@king.slug}/books", headers: bearer(ApiTokenSecrets::MEMBER) }
          assert_response :ok

          assert_equal small, large,
            "query count grew from #{small} to #{large} as books were added -- N+1 on the author books endpoint"
        end
      end
    end
  end
end
