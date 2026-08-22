require "test_helper"

module Admin
  module Music
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
        sign_in_as(users(:admin_user), stub_auth: true)

        # Task A wired News::PurgeCachedPagesJob into every admin write, and
        # test_helper.rb runs Sidekiq inline, so a create here would make a real
        # Cloudflare call on any machine whose .env carries a purge token. CI has
        # no .env and would pass either way, which is why this is explicit.
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      test "index lists only music posts" do
        get admin_news_posts_path

        assert_response :success
        assert_equal [news_posts(:music_launch).id],
          @controller.view_assigns["news_posts"].map(&:id)
      end

      test "create makes a music post, not a books one" do
        post admin_news_posts_path, params: {news_post: {title: "Music News", body: "x"}}

        assert_equal "music", NewsPost.find_by(slug: "music-news").domain
      end

      # R2: ApplicationController rescues RecordNotFound into a rendered 404, so
      # the exception never escapes and assert_raises would fail.
      test "show 404s for a books post" do
        get admin_news_post_path(news_posts(:books_december_update))

        assert_response :not_found
      end

      # The surface this PR newly exposed: a music editor could delete music
      # posts through a crafted request.
      test "destroy is refused for a music editor who cannot delete" do
        editor = users(:regular_user)
        editor.domain_roles.create!(domain: :music, permission_level: :editor)
        sign_in_as(editor, stub_auth: true)
        target = news_posts(:music_launch)

        assert_no_difference -> { NewsPost.count } do
          delete admin_news_post_path(target)
        end

        assert NewsPost.exists?(target.id)
      end

      test "topics index lists only music topics" do
        get admin_news_topics_path

        assert_equal [news_topics(:music_site_news).id],
          @controller.view_assigns["news_topics"].map(&:id)
      end
    end
  end
end
