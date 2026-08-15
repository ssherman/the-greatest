require "test_helper"

module Admin
  module Books
    class ReviewsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! Rails.application.config.domains[:books]
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @review = reviews(:regular_user_war_and_peace)

        # test_helper.rb sets Sidekiq::Testing.inline!, so a real destroy would run
        # Reviews::PurgeCachedPageJob#perform synchronously and could reach the
        # network if CLOUDFLARE_CACHE_PURGE_TOKEN is set on this machine (see
        # ReviewsControllerTest's identical guard). The destroy tests below stub
        # perform_async directly, which bypasses Sidekiq::Testing entirely, but
        # clear it anyway so any test here that destroys stays deterministic.
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "index redirects unauthenticated users" do
        get admin_books_reviews_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_reviews_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path
        assert_response :success
      end

      test "index allows a books domain viewer" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_reviews_path
        assert_response :success
      end

      # Guards the search combinator specifically: apply_search builds two
      # branches -- a title/author EXISTS match and a reviewer email/display_name
      # match -- and joins them with `.or`, which raises ArgumentError if the two
      # relations end up structurally incompatible (different joins_values). A
      # regression there surfaces as a 500 here, not as wrong search results.
      test "index accepts a search query without error" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path(q: "war")
        assert_response :success
      end

      # The test above only proves apply_search doesn't 500 -- a version that
      # matched everything (e.g. an `.or` built from two structurally
      # incompatible branches that silently degrades to one side) would pass it
      # too. This proves the query actually narrows: crime_and_punishment's
      # title, author and reviewer identity all lack "war", so its row must be
      # absent from a q=war search. Identifies rows by the delete form's action,
      # same convention as the written-filter tests above.
      test "index search narrows to matching rows, not merely avoids a 500" do
        sign_in_as(@admin_user, stub_auth: true)
        matching_review = @review
        non_matching_review = reviews(:regular_user_crime_and_punishment)

        get admin_books_reviews_path(q: "war", written: "all")

        assert_select "form[action=?]", admin_books_review_path(matching_review)
        assert_select "form[action=?]", admin_books_review_path(non_matching_review), count: 0
      end

      test "index accepts the written=all filter without error" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path(written: "all")
        assert_response :success
      end

      # params[:q] arrives as an Array for ?q[]=war -- without a to_s guard this
      # reaches User.sanitize_sql_like and raises NoMethodError (Array has no
      # #strip). Reviews::MyReviewsQuery hit the identical shape via ?rating[]=1.
      test "index does not 500 when q is passed as an array" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path(q: ["war"])
        assert_response :success
      end

      # Default (written_only) view: only reviews with a body render. Identifies
      # rendered rows by the delete button's form action -- a URL, not copy --
      # the same way Task 7 pinned behaviour via an href rather than text.
      test "written filter shows only reviews with a body by default" do
        sign_in_as(@admin_user, stub_auth: true)
        written_review = @review
        rating_only_review = reviews(:admin_user_war_and_peace)

        get admin_books_reviews_path

        assert_select "form[action=?]", admin_books_review_path(written_review)
        assert_select "form[action=?]", admin_books_review_path(rating_only_review), count: 0
      end

      test "written=all includes rating-only reviews" do
        sign_in_as(@admin_user, stub_auth: true)
        rating_only_review = reviews(:admin_user_war_and_peace)

        get admin_books_reviews_path(written: "all")

        assert_select "form[action=?]", admin_books_review_path(rating_only_review)
      end

      test "destroy removes the review and purges the cached page" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).with("Books::Book", @review.reviewable_id).once
        assert_difference("Review.count", -1) do
          delete admin_books_review_path(@review)
        end
        assert_redirected_to admin_books_reviews_path
      end

      test "destroy is refused for a domain user without write access" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).never
        assert_no_difference("Review.count") do
          delete admin_books_review_path(@review)
        end
      end

      # require_domain_write! only proves write access to the domain this
      # controller is mounted under -- it says nothing about which reviewable a
      # given id actually belongs to. Without reviewable_type-scoping in
      # destroy, a books editor could delete another domain's review by id.
      # Not reachable through Reviews::Registry today (only Books::Book is
      # registered), but this base controller exists so other domains subclass
      # it, so the scope has to hold on its own.
      test "destroy 404s for a review whose reviewable is outside this domain" do
        sign_in_as(@admin_user, stub_auth: true)
        other_domain_review = @regular_user.reviews.create!(
          reviewable: music_albums(:dark_side_of_the_moon), rating: 3
        )
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).never

        assert_no_difference("Review.count") do
          delete admin_books_review_path(other_domain_review)
        end
        assert_response :not_found
      end

      # The entire multi-domain design rests on Rails resolving this controller's
      # templates from the BASE controller's prefix, so one shared view serves
      # every domain subclass. That prefix is derived from the base controller's
      # class name -- rename Admin::ReviewsBaseController and every reviews view
      # 500s with "missing template", far from the rename that caused it.
      test "view lookup falls back to the shared reviews_base prefix" do
        assert_includes Admin::Books::ReviewsController._prefixes, "admin/reviews_base"
      end
    end
  end
end
