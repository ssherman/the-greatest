require "test_helper"

class Admin::AiChatsControllerTest < ActionDispatch::IntegrationTest
  DOMAIN_CHATS = {
    music: %i[music_artist_chat music_album_chat music_albums_list_chat music_songs_list_chat],
    books: %i[books_book_chat ranking_chat],
    games: %i[games_game_chat games_list_chat]
  }.freeze

  setup do
    @admin = users(:admin_user)
  end

  def visit_domain(domain, as: @admin)
    host! Rails.application.config.domains[domain]
    sign_in_as(as, stub_auth: true) if as
  end

  def index_url_for(domain)
    public_send(:"#{(domain == :music) ? "admin" : "admin_#{domain}"}_ai_chats_url")
  end

  def show_url_for(domain, chat)
    public_send(:"#{(domain == :music) ? "admin" : "admin_#{domain}"}_ai_chat_url", chat)
  end

  def show_path_for(domain, chat)
    public_send(:"#{(domain == :music) ? "admin" : "admin_#{domain}"}_ai_chat_path", chat)
  end

  %i[music books games].each do |domain|
    test "#{domain}: index lists only this domain's chats plus parentless ones" do
      visit_domain(domain)
      get index_url_for(domain)
      assert_response :success

      # Which records the index lists is behavior: each listed chat carries a
      # link to its own show path. Fixture ids are large hashes, so one id's path
      # is never a prefix of another's closing quote-delimited href.
      DOMAIN_CHATS.fetch(domain).each { |name| assert_includes response.body, %(href="#{show_path_for(domain, ai_chats(name))}"), name }
      assert_includes response.body, %(href="#{show_path_for(domain, ai_chats(:no_parent_chat))}")
      DOMAIN_CHATS.except(domain).values.flatten.each do |name|
        assert_not_includes response.body, %(href="#{show_path_for(domain, ai_chats(name))}"), name
      end
    end

    test "#{domain}: shows each of its own chats" do
      visit_domain(domain)
      DOMAIN_CHATS.fetch(domain).each do |name|
        get show_url_for(domain, ai_chats(name))
        assert_response :success, name
      end
    end

    test "#{domain}: shows a parentless chat" do
      visit_domain(domain)
      get show_url_for(domain, ai_chats(:no_parent_chat))
      assert_response :success
    end

    test "#{domain}: shows a chat with a user and no parent" do
      visit_domain(domain)
      get show_url_for(domain, ai_chats(:general_chat))
      assert_response :success
    end

    test "#{domain}: another domain's chat is not found" do
      visit_domain(domain)
      DOMAIN_CHATS.except(domain).values.flatten.each do |name|
        get show_url_for(domain, ai_chats(name))
        assert_response :not_found, name
      end
    end

    test "#{domain}: an unknown id is not found" do
      visit_domain(domain)
      get show_url_for(domain, 999_999_999)
      assert_response :not_found
    end

    test "#{domain}: index renders the empty state" do
      AiChat.delete_all
      visit_domain(domain)
      get index_url_for(domain)
      assert_response :success
    end

    test "#{domain}: editor is allowed" do
      visit_domain(domain, as: users(:editor_user))
      get index_url_for(domain)
      assert_response :success
    end

    test "#{domain}: regular user is redirected to the domain root" do
      visit_domain(domain, as: users(:regular_user))
      get index_url_for(domain)
      assert_redirected_to public_send(:"#{domain}_root_url")
    end

    test "#{domain}: signed-out visitor is redirected to the domain root" do
      visit_domain(domain, as: nil)
      get index_url_for(domain)
      assert_redirected_to public_send(:"#{domain}_root_url")
    end
  end

  test "a chat whose parent record is gone still renders" do
    chat = AiChat.create!(model: "gpt-5-mini", provider: :openai, chat_type: :analysis,
      parent_type: "Games::Game", parent_id: 0)
    visit_domain(:games)
    get admin_games_ai_chats_url
    assert_response :success
    get admin_games_ai_chat_url(chat)
    assert_response :success
  end

  test "a books domain role reaches books AI chats but not games" do
    visit_domain(:books, as: users(:books_viewer_user))
    get admin_books_ai_chats_url
    assert_response :success

    visit_domain(:games, as: users(:books_viewer_user))
    get admin_games_ai_chats_url
    assert_redirected_to games_root_url
  end

  test "a games domain role reaches games AI chats but not books" do
    visit_domain(:games, as: users(:games_editor_user))
    get admin_games_ai_chats_url
    assert_response :success

    visit_domain(:books, as: users(:games_editor_user))
    get admin_books_ai_chats_url
    assert_redirected_to books_root_url
  end

  test "a chat whose parent is a type no domain registers appears on no domain and 404s everywhere" do
    category_chat = AiChat.create!(model: "gpt-5-mini", provider: :openai, chat_type: :analysis,
      parent: categories(:music_rock_genre))

    %i[music books games].each do |domain|
      visit_domain(domain)
      get index_url_for(domain)
      assert_response :success
      assert_not_includes response.body, %(href="#{show_path_for(domain, category_chat)}"), domain

      get show_url_for(domain, category_chat)
      assert_response :not_found, domain
    end
  end
end
