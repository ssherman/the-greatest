require "test_helper"

class CorrectionTokenControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a csrf token anonymously" do
    get correction_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "is never cached" do
    get correction_token_path, as: :json

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "issues no database query" do
    assert_queries_count(0) do
      get correction_token_path, as: :json
    end
  end
end
