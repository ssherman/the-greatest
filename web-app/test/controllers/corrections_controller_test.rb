require "test_helper"

class CorrectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @book = books_books(:war_and_peace)
  end

  test "renders the form for a book" do
    get books_book_correction_path(slug: @book.slug)

    assert_response :success
  end

  test "404s for an unknown slug" do
    get books_book_correction_path(slug: "no-such-book")

    assert_response :not_found
  end

  # The whole point of caching this page: it is the surface that took the live
  # site down when it was uncached.
  test "is publicly cacheable" do
    get books_book_correction_path(slug: @book.slug)

    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  # allow_forgery_protection is off for the whole test environment (config/environments/test.rb),
  # so csrf_meta_tags renders nothing and never writes a session token -- this request would
  # never touch session, and the assertion below could never fail, with or without
  # skip_session_for_caching doing its job. Flipping protection on for the duration of this one
  # request (same pattern as reviews_controller_test.rb's "422s and stays a turbo stream when the
  # csrf token is invalid") makes csrf_meta_tags actually generate and store a real token, which
  # is exactly the write skip_session_for_caching exists to keep out of the response. Restored in
  # an ensure -- the suite runs parallel, and this is a global class attribute. Do not "simplify"
  # this back to a plain get: without the flip this test cannot go red, ever.
  test "sets no session cookie, so Cloudflare does not bypass the cache" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    get books_book_correction_path(slug: @book.slug)

    assert_nil response.headers["Set-Cookie"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "is not indexable" do
    get books_book_correction_path(slug: @book.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  def submit(params = {})
    post corrections_path, params: {
      correctable_type: "Books::Book",
      correctable_id: @book.id,
      correction: {notes: "The year is wrong"}
    }.deep_merge(params)
  end

  test "creates a correction anonymously and redirects to the book" do
    assert_difference -> { Correction.count }, 1 do
      submit
    end

    assert_redirected_to book_path(slug: @book.slug)
    assert_nil Correction.last.user
  end

  test "attaches the signed-in user" do
    sign_in_as(users(:regular_user), stub_auth: true)
    submit

    assert_equal users(:regular_user), Correction.last.user
  end

  test "records the Cloudflare connecting ip, not the edge ip" do
    post corrections_path,
      params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
      headers: {"CF-Connecting-IP" => "198.51.100.4"}

    assert_equal "198.51.100.4", Correction.last.submitter_ip
  end

  test "creates field rows for moved values" do
    submit(correction: {fields: {first_published_year: "1867"}})

    assert_equal %w[first_published_year], Correction.last.correction_fields.map(&:field_name)
  end

  test "rejects an unknown correctable type without constantizing it" do
    post corrections_path, params: {
      correctable_type: "Kernel", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  test "rejects a correctable type that is not correctable" do
    post corrections_path, params: {
      correctable_type: "Books::Edition", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  # Accept-and-discard: a bot that gets a 200 stops retrying, and one that gets a
  # 422 comes back.
  test "silently discards a submission with the honeypot filled" do
    assert_no_difference -> { Correction.count } do
      submit(website: "http://spam.example")
    end

    assert_redirected_to book_path(slug: @book.slug)
  end

  test "re-renders with an error when nothing was submitted" do
    post corrections_path, params: {
      correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: ""}
    }

    assert_response :unprocessable_entity
  end

  test "never caches the create response" do
    submit

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "rate limits by ip and redirects rather than raising" do
    Rails.application.config.x.rate_limit_store.clear

    6.times do
      post corrections_path,
        params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end

    assert_redirected_to book_path(slug: @book.slug)
    assert_equal "Thanks — you've sent us several corrections just now. Please try again shortly.", flash[:alert]
  end

  # The cached page ships no usable token. null_session must accept the write as
  # anonymous rather than 422 the submitter, who can do nothing about it.
  test "accepts a submission with no csrf token instead of raising" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_difference -> { Correction.count }, 1 do
      post corrections_path, params: {
        correctable_type: "Books::Book", correctable_id: @book.id,
        correction: {notes: "wrong"}, authenticity_token: "stale"
      }
    end

    assert_redirected_to book_path(slug: @book.slug)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
