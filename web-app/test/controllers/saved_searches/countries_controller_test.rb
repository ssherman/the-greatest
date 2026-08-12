require "test_helper"

module SavedSearches
  class CountriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @user = users(:regular_user)
    end

    test "returns the autocomplete shape" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_countries_path(q: "fren"), as: :json

      assert_response :success
      row = response.parsed_body.find { |r| r["value"] == books_countries(:french).id }
      assert_equal "French", row["text"]
    end

    test "returns nothing for a blank query" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_countries_path(q: ""), as: :json

      assert_equal [], response.parsed_body
    end

    # JSON-only endpoint: ApplicationController#require_signed_in! renders a
    # 401 JSON body for a JSON-format request rather than redirecting (see its
    # own doc comment), the same contract CategoriesController's equivalent
    # test asserts.
    test "requires a signed-in user" do
      get saved_search_countries_path(q: "fren"), as: :json

      assert_response :unauthorized
    end

    # Every other saved-search endpoint calls prevent_caching, and
    # SavedSearchesController's header states the whole feature is never
    # cached. This is signed-in only, so it has to say so too.
    test "is never cached" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_countries_path(q: "fren"), as: :json

      assert_includes response.headers["Cache-Control"], "no-store"
    end

    test "404s on a host with no saved searches" do
      host! Rails.application.config.domains[:music]
      sign_in_as(@user, stub_auth: true)

      get saved_search_countries_path(q: "fren"), as: :json

      assert_response :not_found
    end
  end
end
