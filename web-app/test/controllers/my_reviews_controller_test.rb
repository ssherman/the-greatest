require "test_helper"

class MyReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
    @user = users(:regular_user)
  end

  test "requires sign in" do
    get my_reviews_path
    assert_response :redirect
  end

  test "renders for a signed-in user on a domain with reviewable types" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_response :success
  end

  test "404s on a domain with no reviewable types" do
    host! Rails.application.config.domains[:music]
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_response :not_found
  end

  test "is never cached" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_match(/no-store/, response.headers["Cache-Control"].to_s)
  end

  test "a page past the last one 404s rather than serving an empty 200" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_page_path(page: 999)
    assert_response :not_found
  end

  test "legacy review URLs redirect permanently" do
    get "/reviews"
    assert_response :moved_permanently
    assert_redirected_to "/my/reviews"

    get "/reviews/account_required"
    assert_response :moved_permanently
    assert_redirected_to "/my/reviews"
  end

  test "an unknown reviewable param falls back instead of erroring" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path(reviewable: "User")
    assert_response :success
  end

  test "renders a page of rows without an N+1" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path # warm any per-request memoization
    assert_response :success

    ActiveRecord::Base.connection.clear_query_cache
    assert_queries_count(11) do
      get my_reviews_path
    end
    assert_response :success
  end

  test "no link on the reviews index is trapped in a turbo frame" do
    sign_in_as(@user, stub_auth: true)
    assert_no_frame_trapped_links my_reviews_path
  end
end
