require "test_helper"

class ReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @user = users(:regular_user)
    @book = books_books(:got)
    @own_review = reviews(:regular_user_war_and_peace)

    # test_helper.rb sets Sidekiq::Testing.inline!, so every purge_cached_page
    # call in these tests (other than the two wrapped in fake! below) runs
    # Reviews::PurgeCachedPageJob#perform synchronously, in-process. That job
    # only skips Cloudflare::PurgeService -- and therefore the network -- when
    # CLOUDFLARE_CACHE_PURGE_TOKEN is blank. This machine's own .env carries a
    # real token (see test/sidekiq/reviews/purge_cached_page_job_test.rb's
    # identical guard), so clear it here rather than trust ambient state.
    # WebMock's disable_net_connect! would catch a real call and error the
    # test either way, but this keeps every non-fake! test deterministic and
    # makes the guard explicit instead of accidental.
    @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
    ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
  end

  teardown do
    ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
  end

  def valid_params(overrides = {})
    {review: {reviewable_type: "Books::Book", reviewable_id: @book.id, rating: 4}.merge(overrides)}
  end

  test "creates a rating with no text" do
    sign_in_as(@user, stub_auth: true)

    assert_difference "Review.count", 1 do
      post reviews_path, params: valid_params, as: :turbo_stream
    end

    assert_response :success
    assert_equal 4, Review.last.rating
    assert_nil Review.last.body
  end

  test "creates a review with a body" do
    sign_in_as(@user, stub_auth: true)

    post reviews_path, params: valid_params(body: "<p>Superb.</p>"), as: :turbo_stream

    assert_response :success
    assert_equal "<p>Superb.</p>", Review.last.body
  end

  # test_helper.rb sets Sidekiq::Testing.inline! globally, which runs the job
  # instead of recording it -- `.jobs` would always be empty. Assert inside a
  # fake! block, the pattern the existing job tests in test/sidekiq/ use.
  test "enqueues a cache purge for the reviewed page" do
    sign_in_as(@user, stub_auth: true)

    Sidekiq::Testing.fake! do
      Reviews::PurgeCachedPageJob.jobs.clear

      post reviews_path, params: valid_params, as: :turbo_stream

      assert_equal 1, Reviews::PurgeCachedPageJob.jobs.size
      assert_equal ["Books::Book", @book.id], Reviews::PurgeCachedPageJob.jobs.first["args"]
    end
  end

  test "rejects a rating outside one to five" do
    sign_in_as(@user, stub_auth: true)

    assert_no_difference "Review.count" do
      post reviews_path, params: valid_params(rating: 9), as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "rejects an unknown reviewable type" do
    sign_in_as(@user, stub_auth: true)

    assert_no_difference "Review.count" do
      post reviews_path, params: {review: {reviewable_type: "User", reviewable_id: @user.id, rating: 4}}, as: :turbo_stream
    end

    assert_response :bad_request
  end

  test "401s for an anonymous visitor" do
    post reviews_path, params: valid_params, as: :turbo_stream

    assert_response :unauthorized
  end

  test "updates the owner's own review" do
    sign_in_as(@user, stub_auth: true)

    patch review_path(@own_review), params: {review: {rating: 2}}, as: :turbo_stream

    assert_response :success
    assert_equal 2, @own_review.reload.rating
  end

  test "403s when updating someone else's review" do
    sign_in_as(users(:password_user), stub_auth: true)

    patch review_path(@own_review), params: {review: {rating: 1}}, as: :turbo_stream

    assert_response :forbidden
    assert_equal 5, @own_review.reload.rating
  end

  test "destroys the owner's own review" do
    sign_in_as(@user, stub_auth: true)

    assert_difference "Review.count", -1 do
      delete review_path(@own_review), as: :turbo_stream
    end

    assert_response :success
  end

  test "enqueues a cache purge when a review is destroyed" do
    sign_in_as(@user, stub_auth: true)

    Sidekiq::Testing.fake! do
      Reviews::PurgeCachedPageJob.jobs.clear

      delete review_path(@own_review), as: :turbo_stream

      assert_equal 1, Reviews::PurgeCachedPageJob.jobs.size
    end
  end

  test "403s when destroying someone else's review" do
    sign_in_as(users(:password_user), stub_auth: true)

    assert_no_difference "Review.count" do
      delete review_path(@own_review), as: :turbo_stream
    end

    assert_response :forbidden
  end

  # ApplicationController's inherited RecordNotFound handler serves
  # public/404.html, an HTML body on a non-2xx status -- the same
  # page-destroying response shape as `head`. reviews_controller.rb overrides
  # it with an empty turbo stream so a stale id (the review was deleted from
  # another tab) reaches the modal's submitted() as a real turbo:submit-end
  # with fetchResponse.statusCode 404, which errorMessageFor special-cases.
  test "404s updating a review that no longer exists" do
    sign_in_as(@user, stub_auth: true)
    missing_id = @own_review.id
    @own_review.destroy

    patch review_path(missing_id), params: {review: {rating: 3}}, as: :turbo_stream

    assert_response :not_found
  end

  test "404s destroying a review that no longer exists" do
    sign_in_as(@user, stub_auth: true)
    missing_id = @own_review.id
    @own_review.destroy

    delete review_path(missing_id), as: :turbo_stream

    assert_response :not_found
  end

  test "a user cannot review the same book twice" do
    sign_in_as(@user, stub_auth: true)
    post reviews_path, params: valid_params, as: :turbo_stream

    assert_no_difference "Review.count" do
      post reviews_path, params: valid_params(rating: 5), as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end
end
