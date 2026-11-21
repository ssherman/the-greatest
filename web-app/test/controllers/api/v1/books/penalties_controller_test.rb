require "test_helper"

module Api
  module V1
    module Books
      class PenaltiesControllerTest < ActionDispatch::IntegrationTest
        setup { host! "dev-new.thegreatestbooks.org" }

        def json = response.parsed_body.deep_symbolize_keys

        test "lists the books catalogue with only the public fields" do
          get "/api/v1/penalties", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_api_conform(status: 200)

          names = json[:data].map { |p| p[:name] }
          assert_includes names, penalties(:books_penalty).name
          assert_includes names, penalties(:global_penalty).name
          assert_not_includes names, penalties(:movies_penalty).name
          assert_not_includes names, penalties(:user_penalty).name
          assert_equal %i[name category category_title description], json[:data].first.keys
        end

        test "needs a token with books:read" do
          get "/api/v1/penalties"
          assert_response :unauthorized

          get "/api/v1/penalties", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)
          assert_response :forbidden
        end
      end
    end
  end
end
