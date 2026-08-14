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
    assert_queries_count(12) do
      get my_reviews_path
    end
    assert_response :success
  end

  test "no link on the reviews index is trapped in a turbo frame" do
    sign_in_as(@user, stub_auth: true)
    assert_no_frame_trapped_links my_reviews_path
  end

  # Reviews::ModalComponent is a page-level singleton already rendered
  # unconditionally by the books layout -- the index view must not render it
  # again, or the page ships two elements with the same id, and two competing
  # reviews--modal Stimulus controllers.
  test "renders the review modal exactly once, not once from the layout and again from the view" do
    sign_in_as(@user, stub_auth: true)
    get my_reviews_path
    assert_select "#review_modal", count: 1
  end

  # `page` arrives as a PATH segment under PathBasedPagination
  # (/my/reviews/page/3), never as a query parameter -- see
  # PathBasedPagination#pagy_path_request. So the real proof that a link built
  # from a paged URL drops the page is generating one FROM a paged URL and
  # checking the page segment is gone from it, not just inspecting
  # filter_params' return value in isolation.
  test "a rating link generated on a paged URL preserves the other filter and drops the page" do
    sign_in_as(@user, stub_auth: true)
    seed_written_reviews(54) # plus the war_and_peace fixture review: 55 written, page 3 non-empty

    get my_reviews_page_path(page: 3, kind: "written")
    assert_response :success
    assert_select "a[data-testid='rating-bar-5'][href='/my/reviews?kind=written&rating=5']"
  end

  # `?rating[]=1` and `?rating[a]=1` both hand MyReviewsQuery#rating a
  # non-scalar; the model-level fix and its unit tests live in
  # test/lib/reviews/my_reviews_query_test.rb -- this pins the same shape at
  # the HTTP boundary, since a NoMethodError there is what turns into a 500.
  test "a crafted rating param does not 500" do
    sign_in_as(@user, stub_auth: true)

    get my_reviews_path(rating: ["1"])
    assert_response :success

    get my_reviews_path(rating: {"a" => "1"})
    assert_response :success
  end

  private

  def seed_written_reviews(count)
    count.times do |i|
      book = ::Books::Book.create!(title: "My Reviews Filler Book #{i}")
      Review.create!(user: @user, reviewable: book, rating: 5, body: "Great book #{i}.")
    end
  end
end
