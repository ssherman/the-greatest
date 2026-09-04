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
class NewsPostTopic < ApplicationRecord
  belongs_to :news_post
  belongs_to :news_topic

  # Mirrors the unique index. The index is the real guarantee; this turns a
  # duplicate into a validation error rather than a RecordNotUnique from the
  # admin form's checkbox list.
  validates :news_topic_id, uniqueness: {scope: :news_post_id}
end
