require "test_helper"

# == Schema Information
#
# Table name: news_post_topics
#
#  id            :bigint           not null, primary key
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  news_post_id  :bigint           not null
#  news_topic_id :bigint           not null
#
# Indexes
#
#  index_news_post_topics_on_news_post_id                    (news_post_id)
#  index_news_post_topics_on_news_post_id_and_news_topic_id  (news_post_id,news_topic_id) UNIQUE
#  index_news_post_topics_on_news_topic_id                   (news_topic_id)
#
# Foreign Keys
#
#  fk_rails_...  (news_post_id => news_posts.id)
#  fk_rails_...  (news_topic_id => news_topics.id)
#
class NewsPostTopicTest < ActiveSupport::TestCase
  test "the same topic cannot be attached to a post twice" do
    duplicate = NewsPostTopic.new(
      news_post: news_posts(:books_december_update),
      news_topic: news_topics(:books_rankings)
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:news_topic_id], "has already been taken"
  end

  test "a topic may be attached to a different post" do
    link = NewsPostTopic.new(
      news_post: news_posts(:books_draft),
      news_topic: news_topics(:books_rankings)
    )

    assert link.valid?
  end

  test "destroying a post destroys its topic links but not the topics" do
    post = news_posts(:books_december_update)

    assert_difference -> { NewsPostTopic.count }, -1 do
      assert_no_difference -> { NewsTopic.count } do
        post.destroy!
      end
    end
  end

  test "a post's topics are reachable through the join" do
    assert_equal [news_topics(:books_rankings).id],
      news_posts(:books_december_update).news_topics.pluck(:id)
  end
end
