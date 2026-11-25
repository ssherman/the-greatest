require "test_helper"

module Services
  module News
    class PublicationTest < ActiveSupport::TestCase
      setup do
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "publish makes a draft live now" do
        freeze_time do
          assert Publication.publish(news_post: news_posts(:books_draft)).success?
          assert_equal ["published", Time.current], [news_posts(:books_draft).reload.status, news_posts(:books_draft).published_at]
        end
      end

      test "publish reschedules a scheduled post, or publishes it early" do
        post = news_posts(:books_scheduled)
        at = 3.days.from_now.change(usec: 0)
        assert Publication.publish(news_post: post, at: at).success?
        assert_equal at, post.reload.published_at
        assert Publication.publish(news_post: post).success?
        assert_equal "published", post.reload.status
      end

      test "publish refuses a past time and leaves the post a draft" do
        assert_equal :past, Publication.publish(news_post: news_posts(:books_draft), at: 1.minute.ago).data[:code]
        assert_equal "draft", news_posts(:books_draft).reload.status
      end

      test "publishing a live post is refused and keeps its date" do
        post = news_posts(:books_december_update)
        was = post.reload.published_at
        assert_equal :already_published, Publication.publish(news_post: post, at: 1.day.from_now).data[:code]
        assert_equal was, post.reload.published_at
      end

      test "publishing a live post with no time is refused and keeps its date" do
        post = news_posts(:books_december_update)
        was = post.reload.published_at
        assert_equal :already_published, Publication.publish(news_post: post).data[:code]
        assert_equal was, post.reload.published_at
      end

      test "publish judges the row as locked, not the held instance" do
        post = news_posts(:books_draft)
        live_at = 1.day.ago.change(usec: 0)
        ::NewsPost.find(post.id).update!(published_at: live_at)
        assert_equal :already_published, Publication.publish(news_post: post).data[:code]
        assert_equal live_at, post.reload.published_at
      end

      test "unpublish judges the row as locked, not the held instance" do
        post = news_posts(:books_december_update)
        ::NewsPost.find(post.id).update!(published_at: nil)
        assert_equal :already_draft, Publication.unpublish(news_post: post).data[:code]
      end

      test "unpublish clears a live or scheduled date and refuses a draft" do
        %i[books_december_update books_scheduled].each do |name|
          assert Publication.unpublish(news_post: news_posts(name)).success?
          assert_equal "draft", news_posts(name).reload.status
        end
        assert_equal :already_draft, Publication.unpublish(news_post: news_posts(:books_draft)).data[:code]
      end
    end
  end
end
