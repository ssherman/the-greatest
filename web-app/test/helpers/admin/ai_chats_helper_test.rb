require "test_helper"

class Admin::AiChatsHelperTest < ActionView::TestCase
  include Admin::AiChatsHelper

  setup do
    @music_artist_chat = ai_chats(:music_artist_chat)
    @music_album_chat = ai_chats(:music_album_chat)
    @music_albums_list_chat = ai_chats(:music_albums_list_chat)
    @music_songs_list_chat = ai_chats(:music_songs_list_chat)
    @general_chat = ai_chats(:general_chat)
  end

  # ai_chat_parent_type_label tests
  test "ai_chat_parent_type_label returns Artist for Music::Artist parent" do
    assert_equal "Artist", ai_chat_parent_type_label(@music_artist_chat)
  end

  test "ai_chat_parent_type_label returns Album for Music::Album parent" do
    assert_equal "Album", ai_chat_parent_type_label(@music_album_chat)
  end

  test "ai_chat_parent_type_label returns Albums List for Music::Albums::List parent" do
    assert_equal "Albums List", ai_chat_parent_type_label(@music_albums_list_chat)
  end

  test "ai_chat_parent_type_label returns Songs List for Music::Songs::List parent" do
    assert_equal "Songs List", ai_chat_parent_type_label(@music_songs_list_chat)
  end

  test "ai_chat_parent_type_label returns nil for chat without parent_type" do
    chat = AiChat.new(parent_type: nil)
    assert_nil ai_chat_parent_type_label(chat)
  end

  # ai_chat_parent_display_name tests
  test "ai_chat_parent_display_name returns artist name" do
    assert_equal @music_artist_chat.parent.name, ai_chat_parent_display_name(@music_artist_chat)
  end

  test "ai_chat_parent_display_name returns album title" do
    assert_equal @music_album_chat.parent.title, ai_chat_parent_display_name(@music_album_chat)
  end

  test "ai_chat_parent_display_name returns list name for albums list" do
    assert_equal @music_albums_list_chat.parent.name, ai_chat_parent_display_name(@music_albums_list_chat)
  end

  test "ai_chat_parent_display_name returns nil for chat without parent" do
    assert_nil ai_chat_parent_display_name(@general_chat)
  end

  # Badge class tests
  test "ai_chat_type_badge_class returns correct classes" do
    assert_equal "badge-ghost", ai_chat_type_badge_class("general")
    assert_equal "badge-primary", ai_chat_type_badge_class("ranking")
    assert_equal "badge-secondary", ai_chat_type_badge_class("recommendation")
    assert_equal "badge-accent", ai_chat_type_badge_class("analysis")
  end

  test "ai_chat_provider_badge_class returns correct classes" do
    assert_equal "badge-success", ai_chat_provider_badge_class("openai")
    assert_equal "badge-warning", ai_chat_provider_badge_class("anthropic")
    assert_equal "badge-info", ai_chat_provider_badge_class("gemini")
    assert_equal "badge-ghost", ai_chat_provider_badge_class("local")
  end
end
