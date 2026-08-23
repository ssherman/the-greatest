require "test_helper"

module Admin
  module Games
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatest.games"
        sign_in_as(users(:admin_user), stub_auth: true)

        # See the music sibling: Task A made every admin write enqueue a purge,
        # and Sidekiq runs inline in tests.
        @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
        ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
      end

      teardown do
        ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
      end

      # The plan asserted `assert_empty` here, because no games fixture post
      # exists. That is satisfied by a working domain filter AND by no filter at
      # all reaching a table that happens to hold nothing for games -- it cannot
      # fail. A games post created in the test makes the assertion discriminate:
      # without scoping, the books and music fixtures come back too.
      test "index lists only games posts" do
        games_post = NewsPost.create!(
          domain: :games, title: "Games News Exists", body: "x",
          published_at: 1.day.ago, user: users(:admin_user)
        )

        get admin_games_news_posts_path

        assert_response :success
        assert_equal [games_post.id], @controller.view_assigns["news_posts"].map(&:id)
      end

      test "create makes a games post, not a books one" do
        post admin_games_news_posts_path, params: {news_post: {title: "Games News", body: "x"}}

        assert_equal "games", NewsPost.find_by(slug: "games-news").domain
      end

      test "show 404s for a books post" do
        get admin_games_news_post_path(news_posts(:books_december_update))

        assert_response :not_found
      end

      # Same correction as the index: there is no games topic fixture, so an
      # empty-list assertion would hold with the domain scope deleted.
      test "topics index lists only games topics" do
        topic = NewsTopic.create!(domain: :games, name: "Games Site News")

        get admin_games_news_topics_path

        assert_equal [topic.id], @controller.view_assigns["news_topics"].map(&:id)
      end
    end
  end
end
