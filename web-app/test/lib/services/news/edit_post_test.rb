require "test_helper"

module Services
  module News
    class EditPostTest < ActiveSupport::TestCase
      setup do
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
        @post = news_posts(:books_december_update)
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "a stale expected_updated_at is refused and changes nothing" do
        stale = @post.updated_at - 1.minute
        result = EditPost.call(news_post: @post, attrs: {body: "changed"}, expected_updated_at: stale)
        assert_equal [false, :stale], [result.success?, result.data[:code]]
        assert_not_equal "changed", @post.reload.body
      end

      # The held instance still carries the old stamp, so only a check made on
      # the row as locked can see the other writer.
      test "a change made through another instance is detected under the lock" do
        old_stamp = @post.updated_at
        ::NewsPost.find(@post.id).update!(body: "other writer")
        result = EditPost.call(news_post: @post, attrs: {body: "mine"}, expected_updated_at: old_stamp)
        assert_equal [false, :stale], [result.success?, result.data[:code]]
        assert_equal "other writer", ::NewsPost.find(@post.id).body
      end

      test "the current expected_updated_at saves" do
        result = EditPost.call(news_post: @post, attrs: {body: "changed"}, expected_updated_at: @post.updated_at)
        assert result.success?
        assert_equal "changed", @post.reload.body
      end

      test "a nil expected_updated_at skips the check" do
        assert EditPost.call(news_post: @post, attrs: {body: "changed"}).success?
        assert_equal "changed", @post.reload.body
      end

      test "a timestamp round-tripped through microsecond ISO 8601 still counts as current" do
        expected = Time.iso8601(@post.reload.updated_at.utc.iso8601(6))
        assert EditPost.call(news_post: @post, attrs: {body: "changed"}, expected_updated_at: expected).success?
      end

      test "date and slug in attrs are ignored" do
        was = [@post.published_at, @post.slug]
        assert EditPost.call(news_post: @post, attrs: {body: "changed", published_at: nil, slug: "moved"}).success?
        assert_equal was, [@post.reload.published_at, @post.slug]
        assert_equal "changed", @post.body
      end

      test "an invalid edit is reported as invalid" do
        result = EditPost.call(news_post: @post, attrs: {title: ""})
        assert_equal [false, :invalid], [result.success?, result.data[:code]]
      end
    end
  end
end
