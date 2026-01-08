# == Schema Information
#
# Table name: ai_chats
#
#  id              :bigint           not null, primary key
#  chat_type       :integer          default("general"), not null
#  json_mode       :boolean          default(FALSE), not null
#  messages        :jsonb
#  model           :string           not null
#  parameters      :jsonb
#  parent_type     :string
#  provider        :integer          default("openai"), not null
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
require "test_helper"

class AiChatTest < ActiveSupport::TestCase
  def setup
    @ai_chat = ai_chats(:general_chat)
  end

  test "should be valid" do
    assert @ai_chat.valid?
  end

  test "should require chat_type" do
    @ai_chat.chat_type = nil
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:chat_type], "can't be blank"
  end

  test "should require model" do
    @ai_chat.model = nil
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:model], "can't be blank"
  end

  test "should require provider" do
    @ai_chat.provider = nil
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:provider], "can't be blank"
  end

  test "should require temperature" do
    @ai_chat.temperature = nil
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:temperature], "can't be blank"
  end

  test "should validate temperature range" do
    @ai_chat.temperature = 2.5
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:temperature], "must be less than or equal to 2"

    @ai_chat.temperature = -0.1
    assert_not @ai_chat.valid?
    assert_includes @ai_chat.errors[:temperature], "must be greater than or equal to 0"
  end

  test "should belong to polymorphic parent" do
    assert_respond_to @ai_chat, :parent
  end

  test "should belong to user" do
    assert_respond_to @ai_chat, :user
  end

  test "should have valid chat_type enum values" do
    assert AiChat.chat_types.key?("general")
    assert AiChat.chat_types.key?("ranking")
    assert AiChat.chat_types.key?("recommendation")
    assert AiChat.chat_types.key?("analysis")
  end

  test "should have valid provider enum values" do
    assert AiChat.providers.key?("openai")
    assert AiChat.providers.key?("anthropic")
    assert AiChat.providers.key?("gemini")
    assert AiChat.providers.key?("local")
  end

  # Tests for with_list_parent_types scope
  test "with_list_parent_types returns AiChats with Music::Albums::List parents" do
    result = AiChat.with_list_parent_types(["Music::Albums::List"])

    assert_includes result, ai_chats(:music_albums_list_chat)
    assert_not_includes result, ai_chats(:music_songs_list_chat)
    assert_not_includes result, ai_chats(:games_list_chat)
    assert_not_includes result, ai_chats(:ranking_chat) # Books::List
  end

  test "with_list_parent_types returns AiChats with Music::Songs::List parents" do
    result = AiChat.with_list_parent_types(["Music::Songs::List"])

    assert_includes result, ai_chats(:music_songs_list_chat)
    assert_not_includes result, ai_chats(:music_albums_list_chat)
    assert_not_includes result, ai_chats(:games_list_chat)
  end

  test "with_list_parent_types returns AiChats with multiple List STI types" do
    result = AiChat.with_list_parent_types(["Music::Albums::List", "Music::Songs::List"])

    assert_includes result, ai_chats(:music_albums_list_chat)
    assert_includes result, ai_chats(:music_songs_list_chat)
    assert_not_includes result, ai_chats(:games_list_chat)
    assert_not_includes result, ai_chats(:ranking_chat) # Books::List
  end

  test "with_list_parent_types returns empty relation for empty array" do
    result = AiChat.with_list_parent_types([])

    assert_empty result
  end

  test "with_list_parent_types returns empty relation for nil" do
    result = AiChat.with_list_parent_types(nil)

    assert_empty result
  end

  test "with_list_parent_types returns empty relation for invalid types" do
    result = AiChat.with_list_parent_types(["NonExistent::List"])

    assert_empty result
  end

  test "with_list_parent_types is chainable with includes" do
    result = AiChat.with_list_parent_types(["Music::Albums::List"]).includes(:parent)

    assert_includes result, ai_chats(:music_albums_list_chat)
    # Verify the result is still a relation (can be iterated)
    assert_kind_of ActiveRecord::Relation, result
  end

  test "with_list_parent_types is chainable with where" do
    # Test that the scope can be further filtered with additional conditions
    result = AiChat.with_list_parent_types(["Music::Albums::List", "Music::Songs::List"])
      .where(provider: :openai)

    assert_includes result, ai_chats(:music_albums_list_chat)
    assert_not_includes result, ai_chats(:music_songs_list_chat) # uses anthropic provider
  end
end
