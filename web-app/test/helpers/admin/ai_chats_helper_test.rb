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

  test "ai_chat_parent_type_label returns Album List for Music::Albums::List parent" do
    assert_equal "Album List", ai_chat_parent_type_label(@music_albums_list_chat)
  end

  test "ai_chat_parent_type_label returns Song List for Music::Songs::List parent" do
    assert_equal "Song List", ai_chat_parent_type_label(@music_songs_list_chat)
  end

  test "ai_chat_parent_type_label returns nil for chat without parent_type" do
    chat = AiChat.new(parent_type: nil)
    assert_nil ai_chat_parent_type_label(chat)
  end

  test "ai_chat_parent_type_label covers books and games parents" do
    assert_equal "Book", ai_chat_parent_type_label(ai_chats(:books_book_chat))
    assert_equal "Book List", ai_chat_parent_type_label(ai_chats(:ranking_chat))
    assert_equal "Game", ai_chat_parent_type_label(ai_chats(:games_game_chat))
    assert_equal "Game List", ai_chat_parent_type_label(ai_chats(:games_list_chat))
  end

  test "ai_chat_parent_type_label falls back to the stored type when the parent is gone" do
    chat = AiChat.new(parent_type: "Games::Game", parent_id: 0)
    assert_equal "Game", ai_chat_parent_type_label(chat)
  end

  test "ai_chat_parent_type_label says List for a list type no domain registers" do
    list = List.new(name: "Unregistered")
    chat = AiChat.new(parent: list)
    assert_equal "List", ai_chat_parent_type_label(chat)
  end

  test "admin_ai_chat_parent_path resolves entity and list parents in every domain" do
    assert_equal "/admin/artists/#{@music_artist_chat.parent.to_param}", admin_ai_chat_parent_path(@music_artist_chat)
    assert_equal "/admin/books/#{books_books(:war_and_peace).to_param}", admin_ai_chat_parent_path(ai_chats(:books_book_chat))
    assert_equal "/admin/games/#{games_games(:breath_of_the_wild).to_param}", admin_ai_chat_parent_path(ai_chats(:games_game_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:books_list))[:path], admin_ai_chat_parent_path(ai_chats(:ranking_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:games_list))[:path], admin_ai_chat_parent_path(ai_chats(:games_list_chat))
    assert_equal Admin::DomainRouting.list_config(lists(:music_albums_list))[:path], admin_ai_chat_parent_path(@music_albums_list_chat)
  end

  test "admin_ai_chat_parent_path is nil without a parent or for an unregistered parent" do
    assert_nil admin_ai_chat_parent_path(@general_chat)
    assert_nil admin_ai_chat_parent_path(AiChat.new(parent_type: "Games::Game", parent_id: 0))
    assert_nil admin_ai_chat_parent_path(AiChat.new(parent: List.new(name: "x")))
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

  test "ai_chat_parent_display_name uses title or name for books and games parents" do
    assert_equal "War and Peace", ai_chat_parent_display_name(ai_chats(:books_book_chat))
    assert_equal "The Legend of Zelda: Breath of the Wild", ai_chat_parent_display_name(ai_chats(:games_game_chat))
    assert_equal "Books Test List", ai_chat_parent_display_name(ai_chats(:ranking_chat))
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
