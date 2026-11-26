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

      test "a live post with a past time is already_published, naming its date, not past" do
        post = news_posts(:books_december_update)
        was = post.reload.published_at
        result = Publication.publish(news_post: post, at: 1.minute.ago)
        assert_equal :already_published, result.data[:code]
        assert_includes result.errors.first, was.utc.iso8601(6)
        assert_equal was, post.reload.published_at
      end

      test "the past-time refusal says how to publish now" do
        result = Publication.publish(news_post: news_posts(:books_draft), at: 1.minute.ago)
        assert_match(/omit published_at to publish now/, result.errors.first)
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
        result = Publication.publish(news_post: post)
        assert_equal :already_published, result.data[:code]
        assert_includes result.errors.first, was.utc.iso8601(6)
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

      test "unpublish reports the date it cleared, read from the locked row" do
        post = news_posts(:books_december_update)
        was = post.reload.published_at
        stale = ::NewsPost.find(post.id)
        post.update_columns(published_at: 2.days.ago.change(usec: 0))
        locked_was = post.reload.published_at

        result = Publication.unpublish(news_post: stale)
        assert_equal locked_was, result.data[:was_published_at]
        assert_not_equal was, result.data[:was_published_at]
      end

      def purges
        ::Sidekiq::Testing.fake! do
          ::News::PurgeCachedPagesJob.jobs.clear
          yield
          ::News::PurgeCachedPagesJob.jobs.dup
        end
      end

      test "a refused already_published or already_draft call purges the post's pages again" do
        live = news_posts(:books_december_update)
        draft = news_posts(:books_draft)
        [[live, -> { Publication.publish(news_post: live) }, :already_published],
          [draft, -> { Publication.unpublish(news_post: draft) }, :already_draft]].each do |post, call, code|
          result = nil
          jobs = purges { result = call.call }
          assert_equal code, result.data[:code]
          assert_equal 1, jobs.size
          assert_includes jobs.first["args"].last.join(" "), post.slug
        end
      end

      # The first unpublish committed and its enqueue was lost. By the retry the
      # post no longer counts, so a page count taken then misses the last index
      # page the post's removal made disappear, and that page stays cached with
      # the retracted post on it.
      test "a retried unpublish purges the index and topic pages the post's removal made disappear" do
        topic = news_topics(:books_rankings)
        10.times do |i|
          NewsPost.create!(domain: :books, title: "Retry Filler #{i}", body: "x",
            published_at: (i + 10).days.ago, user: users(:admin_user)).news_topics << topic
        end
        post = news_posts(:books_december_update)
        assert_includes post.news_topic_ids, topic.id
        assert_equal 11, NewsPost.books.published.count

        ::News::PurgeCachedPagesJob.stubs(:perform_async).raises(RuntimeError, "redis down")
        assert_raises(RuntimeError) { Publication.unpublish(news_post: post) }
        ::News::PurgeCachedPagesJob.unstub(:perform_async)
        assert_equal "draft", post.reload.status

        Sidekiq::Testing.fake! do
          ::News::PurgeCachedPagesJob.jobs.clear
          assert_equal :already_draft, Publication.unpublish(news_post: post).data[:code]
          urls = ::News::PurgeCachedPagesJob.jobs.sole["args"].last
          host = Rails.application.config.domains[:books]
          assert_includes urls, "https://#{host}/news/page/2"
          assert_includes urls, "https://#{host}/news/topic/rankings/page/2"
        end
      end

      test "a past or invalid refusal purges nothing" do
        jobs = purges { Publication.publish(news_post: news_posts(:books_draft), at: 1.minute.ago) }
        assert_empty jobs
      end
    end
  end
end
