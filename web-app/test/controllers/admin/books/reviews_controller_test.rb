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

      test "index accepts the written=all filter without error" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_reviews_path(written: "all")
        assert_response :success
      end

      test "destroy removes the review and purges the cached page" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).with("Books::Book", @review.reviewable_id).once
        assert_difference("Review.count", -1) do
          delete admin_books_review_path(@review)
        end
      end

      test "destroy is refused for a domain user without write access" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        ::Reviews::PurgeCachedPageJob.expects(:perform_async).never
        assert_no_difference("Review.count") do
          delete admin_books_review_path(@review)
        end
      end
    end
  end
end
