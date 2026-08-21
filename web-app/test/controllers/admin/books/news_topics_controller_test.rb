require "test_helper"

module Admin
  module Books
    class NewsTopicsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev-new.thegreatestbooks.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists only this domain's topics" do
        get admin_books_news_topics_path

        assert_response :success
        assert_equal(
          NewsTopic.books.sorted_by_name.pluck(:id),
          @controller.view_assigns["news_topics"].map(&:id)
        )
      end

      test "index does not list another domain's topics" do
        get admin_books_news_topics_path

        assert_not_includes @controller.view_assigns["news_topics"].map(&:id),
          news_topics(:music_site_news).id
      end

      test "create makes a topic in this domain" do
        assert_difference -> { NewsTopic.books.count }, 1 do
          post admin_books_news_topics_path, params: {news_topic: {name: "Data Updates"}}
        end

        assert_equal "data-updates", NewsTopic.books.order(:id).last.slug
      end

      test "create re-renders the form on a validation failure" do
        post admin_books_news_topics_path, params: {news_topic: {name: ""}}

        assert_response :unprocessable_entity
      end

      test "update renames without moving the slug" do
        topic = news_topics(:books_rankings)

        patch admin_books_news_topic_path(topic), params: {news_topic: {name: "Ranking News"}}

        assert_equal "Ranking News", topic.reload.name
        assert_equal "rankings", topic.slug
      end

      test "destroy removes the topic" do
        assert_difference -> { NewsTopic.books.count }, -1 do
          delete admin_books_news_topic_path(news_topics(:books_feature_launch))
        end
      end

      test "edit refuses another domain's topic" do
        get edit_admin_books_news_topic_path(news_topics(:music_site_news))

        assert_response :not_found
      end

      test "update refuses another domain's topic and leaves it unchanged" do
        topic = news_topics(:music_site_news)

        patch admin_books_news_topic_path(topic), params: {news_topic: {name: "Hijacked"}}

        assert_response :not_found
        assert_equal "Site News", topic.reload.name
      end

      test "destroy refuses another domain's topic and does not remove it" do
        topic = news_topics(:music_site_news)

        assert_no_difference -> { NewsTopic.count } do
          delete admin_books_news_topic_path(topic)
        end

        assert_response :not_found
        assert NewsTopic.exists?(topic.id)
      end

      test "a signed-out visitor is turned away" do
        reset!
        host! "dev-new.thegreatestbooks.org"

        get admin_books_news_topics_path

        assert_redirected_to "/"
      end
    end
  end
end
