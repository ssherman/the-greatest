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
end
