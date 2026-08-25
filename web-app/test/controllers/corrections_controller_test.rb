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

  test "sets no session cookie, so Cloudflare does not bypass the cache" do
    get books_book_correction_path(slug: @book.slug)

    assert_nil response.headers["Set-Cookie"]
  end

  test "is not indexable" do
    get books_book_correction_path(slug: @book.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end
end
