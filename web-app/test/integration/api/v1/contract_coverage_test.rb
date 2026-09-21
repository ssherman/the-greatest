require "test_helper"

module Api
  module V1
    # Every (method, path, status) the contract documents must be reachable
    # and must conform. EXERCISES is the map from documented response to the
    # request that produces it; the test fails if the document gains a response
    # this map does not exercise, or the map names one the document lacks. This
    # is the coverage gate -- openapi_first's built-in one is disabled because
    # it exits 2 on every scoped test run.
    class ContractCoverageTest < ActionDispatch::IntegrationTest
      EXERCISES = {
        ["GET", "/api/v1/openapi.json", "200"] => -> { get "/api/v1/openapi.json" },
        ["GET", "/api/v1/openapi.json", "429"] => -> { with_exhausted_ip_window { get "/api/v1/openapi.json" } },
        ["GET", "/api/v1/books", "200"] => -> { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books", "400"] => -> { get "/api/v1/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books", "401"] => -> { get "/api/v1/books" },
        ["GET", "/api/v1/books", "403"] => -> { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/books", "429"] => -> { with_exhausted_limit { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/books/{slug}", "200"] => -> { get "/api/v1/books/#{books_books(:war_and_peace).slug}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}", "401"] => -> { get "/api/v1/books/war-and-peace" },
        ["GET", "/api/v1/books/{slug}", "403"] => -> { get "/api/v1/books/war-and-peace", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/books/{slug}", "404"] => -> { get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}", "429"] => -> { with_exhausted_limit { get "/api/v1/books/war-and-peace", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/authors", "200"] => -> { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors", "400"] => -> { get "/api/v1/authors?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors", "401"] => -> { get "/api/v1/authors" },
        ["GET", "/api/v1/authors", "403"] => -> { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/authors", "429"] => -> { with_exhausted_limit { get "/api/v1/authors", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/authors/{slug}", "200"] => -> { get "/api/v1/authors/#{books_authors(:tolstoy).slug}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "401"] => -> { get "/api/v1/authors/leo-tolstoy" },
        ["GET", "/api/v1/authors/{slug}", "403"] => -> { get "/api/v1/authors/leo-tolstoy", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "404"] => -> { get "/api/v1/authors/no-such-author", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/authors/{slug}", "429"] => -> { with_exhausted_limit { get "/api/v1/authors/leo-tolstoy", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/ranking_configurations", "200"] => -> { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations", "400"] => -> { get "/api/v1/ranking_configurations?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations", "401"] => -> { get "/api/v1/ranking_configurations" },
        ["GET", "/api/v1/ranking_configurations", "403"] => -> { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/ranking_configurations", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/ranking_configurations/{id}", "200"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "401"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}" },
        ["GET", "/api/v1/ranking_configurations/{id}", "403"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "404"] => -> { get "/api/v1/ranking_configurations/999999999", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "200"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "400"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "401"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books" },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "403"] => -> { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "404"] => -> { get "/api/v1/ranking_configurations/999999999/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/ranking_configurations/{id}/books", "429"] => -> { with_exhausted_limit { get "/api/v1/ranking_configurations/#{ranking_configurations(:books_global).id}/books", headers: bearer(ApiTokenSecrets::MEMBER) } }
      }.freeze

      setup do
        host! "dev-new.thegreatestbooks.org"
        RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 100)
        RankedItem.create!(item: books_authors(:tolstoy), ranking_configuration: ranking_configurations(:books_authors_global), rank: 1, score: 100)
      end

      test "the map and the document describe the same responses" do
        # .to_a on both: openapi_first exposes routes and responses as lazy
        # enumerators, and request_method is already upcased ("GET").
        documented = OpenapiFirst::Test[:default].routes.to_a.flat_map do |route|
          route.responses.to_a.map { |resp| [route.request_method, route.path, resp.status.to_s] }
        end.uniq

        assert_equal documented.sort, EXERCISES.keys.sort,
          "documented responses and EXERCISES disagree -- add the missing entry to whichever side lacks it"
      end

      test "every documented response is reachable and conforms" do
        EXERCISES.each do |(_method, _path, status), exercise|
          instance_exec(&exercise)
          # Request validation would reject the deliberately bad page=0 request.
          assert_api_response_conform(status: Integer(status))
        end
      end

      private

      def with_exhausted_ip_window
        minute = Services::Api::RateLimiter::Window.new(limit: 60, remaining: 0, reset_at: 30.seconds.from_now, exceeded: true)
        Services::Api::RateLimiter.stubs(:hit_unauthenticated).returns(Services::Api::RateLimiter::Verdict.new(minute: minute, day: nil))
        yield
      ensure
        Services::Api::RateLimiter.unstub(:hit_unauthenticated)
      end

      def with_exhausted_limit
        minute = Services::Api::RateLimiter::Window.new(limit: 60, remaining: 0, reset_at: 30.seconds.from_now, exceeded: true)
        day = Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 10, reset_at: 1.day.from_now, exceeded: false)
        Services::Api::RateLimiter.stubs(:hit).returns(Services::Api::RateLimiter::Verdict.new(minute: minute, day: day))
        yield
      ensure
        Services::Api::RateLimiter.unstub(:hit)
      end
    end
  end
end
