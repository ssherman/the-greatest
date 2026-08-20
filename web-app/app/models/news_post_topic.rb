class NewsPostTopic < ApplicationRecord
  belongs_to :news_post
  belongs_to :news_topic

  # Mirrors the unique index. The index is the real guarantee; this turns a
  # duplicate into a validation error rather than a RecordNotUnique from the
  # admin form's checkbox list.
  validates :news_topic_id, uniqueness: {scope: :news_post_id}
end
