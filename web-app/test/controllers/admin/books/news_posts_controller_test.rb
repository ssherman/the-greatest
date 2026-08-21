require "test_helper"

module Admin
  module Books
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev-new.thegreatestbooks.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists this domain's posts, drafts included" do
        get admin_books_news_posts_path

        assert_response :success
        ids = @controller.view_assigns["news_posts"].map(&:id)
        assert_includes ids, news_posts(:books_december_update).id
        assert_includes ids, news_posts(:books_draft).id
      end

      test "index excludes another domain's posts" do
        get admin_books_news_posts_path

        assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
          news_posts(:music_launch).id
      end

      # The plain fixtures alone cannot discriminate published_at-order from
      # id-order: hashed fixture ids happen to fall in the same relative order
      # as the intended publish order (see task-10-brief.md, correction 2). So
      # this test builds two extra published books posts IN the test, where the
      # one created FIRST (lower id, because Rails resets the pk sequence above
      # every fixture id after loading fixtures on Postgres) is published LATER.
      # Under `published_at DESC NULLS FIRST, id DESC` the two sort by publish
      # date; under plain `id DESC` they sort in the opposite order AND the
      # draft is no longer first, because both new rows outrank it on id. So the
      # full expected sequence discriminates the ordering twice over.
      test "index orders drafts first, then newest published" do
        published_later = NewsPost.create!(
          domain: :books, title: "Ordering Probe Later", body: "later",
          published_at: 1.day.ago, user: users(:admin_user)
        )
        published_earlier = NewsPost.create!(
          domain: :books, title: "Ordering Probe Earlier", body: "earlier",
          published_at: 2.days.ago, user: users(:admin_user)
        )
        # published_earlier was created AFTER published_later, so it has the
        # higher id despite the earlier publish date.
        assert_operator published_earlier.id, :>, published_later.id

        get admin_books_news_posts_path

        ids = @controller.view_assigns["news_posts"].map(&:id)
        # books_scheduled's published_at is 7 days FROM NOW, which is the
        # largest timestamp of all -- it sorts ahead of the in-test posts too.
        expected = [
          news_posts(:books_draft).id,
          news_posts(:books_scheduled).id,
          published_later.id,
          published_earlier.id,
          news_posts(:books_december_update).id
        ]
        assert_equal expected, ids
      end

      test "show renders a post" do
        get admin_books_news_post_path(news_posts(:books_december_update))

        assert_response :success
        assert_select "h1", text: /December Update/
      end

      test "show renders a draft" do
        get admin_books_news_post_path(news_posts(:books_draft))

        assert_response :success
      end

      test "show 404s for another domain's post" do
        get admin_books_news_post_path(news_posts(:music_launch))

        assert_response :not_found
      end
    end
  end
end
