# == Schema Information
#
# Table name: ai_chats
#
#  id              :bigint           not null, primary key
#  chat_type       :integer          default(0), not null
#  json_mode       :boolean          default(FALSE), not null
#  messages        :jsonb
#  model           :string           not null
#  parent_type     :string
#  provider        :integer          default(0), not null
#  raw_responses   :jsonb
#  response_schema :jsonb
#  temperature     :decimal(3, 2)    default(0.2), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  parent_id       :bigint
#  user_id         :bigint
#
# Indexes
#
#  index_ai_chats_on_parent   (parent_type,parent_id)
#  index_ai_chats_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class AiChat < ApplicationRecord
  belongs_to :parent, polymorphic: true, optional: true
  belongs_to :user, optional: true

  enum :chat_type, {
    general: 0,
    ranking: 1,
    recommendation: 2,
    analysis: 3
  }

  enum :provider, {
    openai: 0,
    anthropic: 1,
    gemini: 2,
    local: 3
  }

  validates :chat_type, presence: true
  validates :model, presence: true
  validates :provider, presence: true
  validates :temperature, presence: true, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 2}
end
