require "test_helper"

module Services
  module News
    class SavePostTest < ActiveSupport::TestCase
      setup do
        # Sidekiq runs inline in tests and this machine's .env holds a real
        # Cloudflare token; see Admin::Books::NewsPostsControllerTest.
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "a failed update leaves the topics as they were and enqueues nothing" do
        post = news_posts(:books_december_update)
        before = post.news_topic_ids.sort
        Sidekiq::Testing.fake! do
          ::News::PurgeCachedPagesJob.jobs.clear
          result = SavePost.call(news_post: post, attrs: {title: "", news_topic_ids: [news_topics(:books_new_lists).id]})
          assert_equal [false, :invalid], [result.success?, result.data[:code]]
          assert result.errors.any?
          assert_equal 0, ::News::PurgeCachedPagesJob.jobs.size
        end
        assert_equal before, NewsPost.find(post.id).news_topic_ids.sort
      end

      test "a guard refusal changes nothing and carries its code" do
        post = news_posts(:books_december_update)
        result = SavePost.call(news_post: post, attrs: {body: "new"}, guard: ->(_post) { [:stale, "read again"] })
        assert_equal [false, :stale, ["read again"]], [result.success?, result.data[:code], result.errors]
        assert_not_equal "new", post.reload.body
      end

      test "the guard sees the stored row, not the caller's copy" do
        post = news_posts(:books_december_update)
        NewsPost.find(post.id).update!(body: "changed elsewhere")
        seen = nil
        SavePost.call(news_post: post, attrs: {summary: "s"}, guard: ->(locked) {
          seen = locked.body
          nil
        })
        assert_equal "changed elsewhere", seen
      end

      test "changed names only what really changed" do
        post = news_posts(:books_december_update)
        result = SavePost.call(news_post: post, attrs: {title: post.title, body: "new", news_topic_ids: []})
        assert_equal %w[body news_topic_ids], result.data[:changed].sort
      end

      test "a successful save enqueues one purge, after the transaction commits" do
        post = news_posts(:books_december_update)
        base = ActiveRecord::Base.connection.open_transactions
        depth = nil
        ::News::PurgeCachedPagesJob.expects(:perform_async).once.with { |*| depth = ActiveRecord::Base.connection.open_transactions }
        SavePost.call(news_post: post, attrs: {body: "new"})
        assert_equal base, depth
      end

      test "an image attached to an otherwise unchanged post is stored once and uploaded" do
        post = news_posts(:books_december_update)
        upload = Rack::Test::UploadedFile.new(file_fixture("test_image.png"), "image/png")
        result = SavePost.call(news_post: post, attrs: {title: post.title}, body_images: [upload])
        assert result.success?
        images = NewsPost.find(post.id).body_images
        assert_equal 1, images.count
        assert images.first.blob.service.exist?(images.first.blob.key)
      end

      test "a new record is created and purged" do
        Sidekiq::Testing.fake! do
          ::News::PurgeCachedPagesJob.jobs.clear
          post = NewsPost.new(domain: :books, user: users(:admin_user))
          assert SavePost.call(news_post: post, attrs: {title: "Fresh", body: "x"}).success?
          assert_predicate post, :persisted?
          assert_equal 1, ::News::PurgeCachedPagesJob.jobs.size
        end
      end
    end
  end
end
