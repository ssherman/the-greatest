require "test_helper"

module Admin
  class ReviewsHelperTest < ActionView::TestCase
    include Admin::ReviewsHelper

    setup do
      @review = reviews(:regular_user_war_and_peace)
    end

    # The admin user page answers on every hostname; /admin/reviews answers only
    # on the books host. A path-only link is therefore broken for any admin who
    # happens to be browsing on music or games, and is invisible in development
    # where every host resolves to localhost.
    test "cross_domain_review_url carries the books host" do
      books_host = Rails.application.config.domains[:books]
      assert_includes cross_domain_review_url(@review), books_host
      assert_match %r{\Ahttps?://}, cross_domain_review_url(@review)
      assert_includes cross_domain_review_url(@review), "/admin/reviews/#{@review.id}"
    end

    # The test above runs under ActionView::TestCase's default request (host
    # "test.host", plain http, port 80), so request.port_string is always "" there
    # and the comment's claim that a non-default port shows up in the generated
    # URL was never actually exercised. Pin it directly by giving the request a
    # non-default port.
    test "cross_domain_review_url includes a non-default port" do
      request.host = "example.com:3000"

      assert_match(/:3000\/admin\/reviews\/#{@review.id}\z/, cross_domain_review_url(@review))
    end

    # Same gap as above for scheme: the default test request is plain http, so the
    # comment's claim that production (https) produces an https:// URL was never
    # exercised either.
    test "cross_domain_review_url is https when the request is" do
      request.set_header("HTTPS", "on")

      assert_match(%r{\Ahttps://}, cross_domain_review_url(@review))
    end

    # A user page must not 500 because one of its reviews points at a class no
    # domain claims. The card renders such a row unlinked instead.
    test "cross_domain_review_url returns nil for an unregistered reviewable type" do
      orphan = Review.new(reviewable_type: "Nope::Thing", reviewable_id: 1, rating: 3)
      assert_nil cross_domain_review_url(orphan)
    end

    test "registry maps a reviewable type to its domain" do
      assert_equal "books", ::Reviews::Registry.domain_for_type("Books::Book")
      assert_nil ::Reviews::Registry.domain_for_type("Nope::Thing")
    end
  end
end
