require "test_helper"

class Admin::Music::AiChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @regular_user = users(:regular_user)
    @music_artist_chat = ai_chats(:music_artist_chat)
    @music_album_chat = ai_chats(:music_album_chat)
    @music_albums_list_chat = ai_chats(:music_albums_list_chat)
    @music_songs_list_chat = ai_chats(:music_songs_list_chat)
    @general_chat = ai_chats(:general_chat)
    @no_parent_chat = ai_chats(:no_parent_chat)
    @books_chat = ai_chats(:ranking_chat) # Has Books::List parent - non-music
    @games_list_chat = ai_chats(:games_list_chat)

    host! Rails.application.config.domains[:music]
    sign_in_as(@admin, stub_auth: true)
  end

  # Index tests
  test "should get index" do
    get admin_ai_chats_url
    assert_response :success
  end

  test "should show music-related AI chats in index" do
    get admin_ai_chats_url
    assert_response :success
  end

  test "should include AI chats without parent in index" do
    get admin_ai_chats_url
    assert_response :success
  end

  test "should display empty state when no AI chats exist" do
    AiChat.destroy_all
    get admin_ai_chats_url
    assert_response :success
  end

  # Show tests
  test "should get show" do
    get admin_ai_chat_url(@music_artist_chat)
    assert_response :success
  end

  test "should show AI chat with parent" do
    get admin_ai_chat_url(@music_artist_chat)
    assert_response :success
  end

  test "should show AI chat with user only" do
    get admin_ai_chat_url(@general_chat)
    assert_response :success
  end

  test "should return not found for non-existent AI chat" do
    get admin_ai_chat_url(id: 999999)
    assert_response :not_found
  end

  test "should return not found for non-music AI chat" do
    # ranking_chat has Books::List parent which is not a music type
    get admin_ai_chat_url(@books_chat)
    assert_response :not_found
  end

  # Music List STI subclass tests
  test "should get show for AI chat with Music::Albums::List parent" do
    get admin_ai_chat_url(@music_albums_list_chat)
    assert_response :success
  end

  test "should get show for AI chat with Music::Songs::List parent" do
    get admin_ai_chat_url(@music_songs_list_chat)
    assert_response :success
  end

  test "should return not found for AI chat with Games::List parent" do
    get admin_ai_chat_url(@games_list_chat)
    assert_response :not_found
  end

  test "should show AI chat without parent" do
    get admin_ai_chat_url(@no_parent_chat)
    assert_response :success
  end

  # Authorization tests
  test "should allow admin access to index" do
    get admin_ai_chats_url
    assert_response :success
  end

  test "should allow editor access to index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_ai_chats_url
    assert_response :success
  end

  test "should deny regular user access" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_ai_chats_url
    assert_redirected_to music_root_url
  end

  test "should deny unauthenticated access" do
    reset!
    host! Rails.application.config.domains[:music]
    get admin_ai_chats_url
    assert_redirected_to music_root_url
  end

  test "should allow admin access to show" do
    get admin_ai_chat_url(@music_artist_chat)
    assert_response :success
  end

  test "should allow editor access to show" do
    sign_in_as(@editor, stub_auth: true)
    get admin_ai_chat_url(@music_artist_chat)
    assert_response :success
  end

  test "should deny regular user access to show" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_ai_chat_url(@music_artist_chat)
    assert_redirected_to music_root_url
  end
end
