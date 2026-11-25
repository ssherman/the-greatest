require "test_helper"

module Services
  module News
    class DraftPostTest < ActiveSupport::TestCase
      setup do
        # Sidekiq runs inline and .env may hold a real Cloudflare token.
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "creates a draft by the given user" do
        result = DraftPost.call(domain: :books, user: users(:admin_user), attrs: {title: "Fresh News", body: "**hi**", summary: nil, news_topic_ids: [news_topics(:books_rankings).id]})
        post = result.data[:news_post]
        assert result.success?
        assert_equal ["fresh-news", "draft", "books", users(:admin_user)], [post.slug, post.status, post.domain, post.user]
        assert_equal [news_topics(:books_rankings).id], post.reload.news_topic_ids
      end

      test "refuses a title whose slug is taken on this site, whatever the punctuation or case" do
        ["December Update", "december, update!"].each do |title|
          result = nil
          assert_no_difference("NewsPost.count") { result = DraftPost.call(domain: :books, user: users(:admin_user), attrs: {title: title, body: "x"}) }
          assert_equal [:slug_taken, news_posts(:books_december_update)], [result.data[:code], result.data[:existing]]
        end
      end

      test "another site's slug does not block" do
        assert DraftPost.call(domain: :books, user: users(:admin_user), attrs: {title: news_posts(:music_launch).title, body: "x"}).success?
      end

      test "refuses a title with no usable or a reserved slug" do
        ["日本語", "!!!", "Topic", "page", "Admin"].each do |title|
          assert_equal :unusable_title, DraftPost.call(domain: :books, user: users(:admin_user), attrs: {title: title, body: "x"}).data[:code], title
        end
      end

      test "a missing title is unusable rather than an error" do
        result = DraftPost.call(domain: :books, user: users(:admin_user), attrs: {body: "x"})
        assert_equal [false, :unusable_title], [result.success?, result.data[:code]]
      end

      test "an invalid body is reported as invalid and creates nothing" do
        result = nil
        assert_no_difference("NewsPost.count") { result = DraftPost.call(domain: :books, user: users(:admin_user), attrs: {title: "Fine Title", body: ""}) }
        assert_equal [false, :invalid], [result.success?, result.data[:code]]
      end
    end
  end
end
