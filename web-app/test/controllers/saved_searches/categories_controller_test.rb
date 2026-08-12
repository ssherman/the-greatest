require "test_helper"

module SavedSearches
  class CategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! Rails.application.config.domains[:books]
      @user = users(:regular_user)
    end

    test "returns the autocomplete shape with the type in the text" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "fict"), as: :json

      assert_response :success
      row = response.parsed_body.find { |r| r["value"] == categories(:books_fiction_genre).id }
      assert_equal "Fiction (Genre)", row["text"]
    end

    # The picker spans every type, exactly as the filter modal's does.
    test "is not scoped to any category_type" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "americ"), as: :json

      texts = response.parsed_body.map { |r| r["text"] }
      assert_includes texts, "Americana (Genre)"
      assert_includes texts, "American History (Subject)"
    end

    test "returns only this domain's categories" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "rock"), as: :json

      assert_equal [], response.parsed_body
    end

    test "returns nothing for a blank query" do
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: ""), as: :json

      assert_equal [], response.parsed_body
    end

    # JSON-only endpoint: ApplicationController#require_signed_in! renders a
    # 401 JSON body for a JSON-format request rather than redirecting (see its
    # own doc comment), the same contract ListableSearchesController's
    # equivalent test asserts. A redirect only happens for an HTML request,
    # which this endpoint never serves.
    test "requires a signed-in user" do
      get saved_search_categories_path(q: "fict"), as: :json

      assert_response :unauthorized
    end

    test "404s on a host with no saved searches" do
      host! Rails.application.config.domains[:music]
      sign_in_as(@user, stub_auth: true)

      get saved_search_categories_path(q: "rock"), as: :json

      assert_response :not_found
    end
  end
end
