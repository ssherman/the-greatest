require "test_helper"
require "active_record/testing/query_assertions"

class FormTokenControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a csrf token anonymously" do
    get form_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "is never cached" do
    get form_token_path, as: :json

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "issues no database query" do
    assert_queries_count(0) do
      get form_token_path, as: :json
    end
  end

  # Correction form pages are edge-cached for 24 hours and already-cached copies
  # still fetch this path. Dropping it would make them fall back to null_session
  # -- which works, but silently loses attribution for signed-in submitters until
  # the cache turns over.
  test "the legacy correction_token path still works" do
    get correction_token_path, as: :json

    assert_response :success
    assert JSON.parse(response.body)["csrf_token"].present?
  end
end
