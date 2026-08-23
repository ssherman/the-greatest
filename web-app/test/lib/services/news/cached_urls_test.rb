require "test_helper"

module Services
  module News
    class CachedUrlsTest < ActiveSupport::TestCase
      setup do
        @post = news_posts(:books_december_update)
        @books_host = Rails.application.config.domains[:books]
      end

      test "includes the post's own canonical url" do
        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news/december-update"
      end

      test "includes the rss feed, which every write changes" do
        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news.rss"
      end

      test "includes every index page for the domain, not only page one" do
        # books_december_update is the only published books fixture, so one page.
        # Eleven more published posts push the index to two pages: the assertion
        # is that page 2 appears, which page-1-only code cannot satisfy.
        11.times do |i|
          NewsPost.create!(
            domain: :books, title: "Filler #{i}", body: "x",
            published_at: (i + 10).days.ago, user: users(:admin_user)
          )
        end

        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news"
        assert_includes urls, "https://#{@books_host}/news/page/2"
      end

      test "does not invent index pages that do not exist" do
        # One published books post -> exactly one page. A page/2 URL here would
        # mean the page count is padded rather than derived.
        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news"
        assert_not_includes urls, "https://#{@books_host}/news/page/2"
      end

      test "includes /news even when the domain has no published posts left" do
        # The destroy path computes URLs before the row is gone, but a domain
        # can still reach zero published posts. /news is served regardless.
        NewsPost.where(domain: :books).update_all(published_at: nil)

        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news"
      end

      test "includes every topic index for the domain, not just the post's own topics" do
        # books_december_update is linked only to books_rankings. books_new_lists
        # and books_feature_launch are unlinked -- an update that removed a topic
        # would leave that topic's index stale unless all of them are purged.
        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news/topic/rankings"
        assert_includes urls, "https://#{@books_host}/news/topic/new-lists"
        assert_includes urls, "https://#{@books_host}/news/topic/feature-launch"
      end

      test "includes a topic's deep index pages" do
        topic = news_topics(:books_rankings)
        11.times do |i|
          post = NewsPost.create!(
            domain: :books, title: "Topic filler #{i}", body: "x",
            published_at: (i + 10).days.ago, user: users(:admin_user)
          )
          post.news_topics << topic
        end

        urls = CachedUrls.call(@post)

        assert_includes urls, "https://#{@books_host}/news/topic/rankings/page/2"
      end

      test "excludes another domain's topics" do
        urls = CachedUrls.call(@post)

        assert_not_includes urls, "https://#{@books_host}/news/topic/site-news"
        assert_not_includes urls, "https://#{Rails.application.config.domains[:music]}/news/topic/site-news"
      end

      test "builds urls on the post's own domain, not always books" do
        music_host = Rails.application.config.domains[:music]

        urls = CachedUrls.call(news_posts(:music_launch))

        assert_includes urls, "https://#{music_host}/news/the-greatest-music-is-live"
        assert_includes urls, "https://#{music_host}/news"
        assert_not_includes urls, "https://#{@books_host}/news"
      end

      test "builds urls for every configured host when the domain holds a comma-separated list" do
        # config.domains values come from ENV and each may hold a list --
        # DomainConstraint and detect_current_domain both split on ",". Cloudflare
        # keys its cache by host, so a second host purged only on the first would
        # keep serving stale news.
        with_books_domain("primary.example.com,secondary.example.com") do
          urls = CachedUrls.call(@post)

          assert_includes urls, "https://primary.example.com/news/december-update"
          assert_includes urls, "https://secondary.example.com/news/december-update"
          assert_includes urls, "https://secondary.example.com/news"
        end
      end

      test "never emits a host built from the raw comma-separated string" do
        with_books_domain("primary.example.com,secondary.example.com") do
          urls = CachedUrls.call(@post)

          assert_empty urls.grep(/primary\.example\.com,/),
            "a URL was built from the unsplit list: #{urls.inspect}"
        end
      end

      # A single host cannot produce a duplicate, so asserting uniqueness against
      # the plain fixtures passes whether or not the service dedupes -- verified
      # by deleting the .uniq and watching that version of this test still pass.
      # A repeated entry in the ENV list is the case that discriminates.
      test "returns no duplicates when a host is repeated in the configured list" do
        with_books_domain("dup.example.com,dup.example.com") do
          urls = CachedUrls.call(@post)

          assert_equal urls.uniq, urls
          assert_includes urls, "https://dup.example.com/news"
        end
      end

      test "returns nothing for a post with no slug" do
        @post.slug = ""

        assert_empty CachedUrls.call(@post)
      end

      private

      def with_books_domain(value)
        original = Rails.application.config.domains[:books]
        Rails.application.config.domains[:books] = value
        yield
      ensure
        Rails.application.config.domains[:books] = original
      end
    end
  end
end
