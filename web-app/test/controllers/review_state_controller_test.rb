require "test_helper"

class ReviewStateControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @user = users(:regular_user)
    @book = books_books(:war_and_peace)
    @review = reviews(:regular_user_war_and_peace)
  end

  test "returns the signed-in user's own review" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal @review.id, body["review"]["id"]
    assert_equal 5, body["review"]["rating"]
    assert_equal "A monumental achievement", body["review"]["title"]
  end

  test "returns a null review when the user has not reviewed the item" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: books_books(:got).id), as: :json

    assert_response :success
    assert_nil response.parsed_body["review"]
  end

  test "does not return another user's review" do
    sign_in_as(users(:password_user), stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    assert_response :success
    assert_nil response.parsed_body["review"]
  end

  # Without this the first save from a cached page 422s in production.
  test "returns a usable csrf token" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    token = response.parsed_body["csrf_token"]
    assert token.present?
    assert_kind_of String, token
  end

  test "is never cached" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    assert_match(/no-store/, response.headers["Cache-Control"])
    assert_match(/private/, response.headers["Cache-Control"])
  end

  test "401s for an anonymous visitor" do
    get review_state_path(reviewable_type: "Books::Book", reviewable_id: @book.id), as: :json

    assert_response :unauthorized
  end

  test "rejects a reviewable type that is not allowlisted" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "User", reviewable_id: @user.id), as: :json

    assert_response :bad_request
  end

  test "rejects a missing reviewable id" do
    sign_in_as(@user, stub_auth: true)

    get review_state_path(reviewable_type: "Books::Book"), as: :json

    assert_response :bad_request
  end
end
