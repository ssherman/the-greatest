module Admin::AiChatsHelper
  # Returns the admin path for an AI chat's parent, or nil if no path available
  def admin_ai_chat_parent_path(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    case parent
    when Music::Artist
      admin_artist_path(parent)
    when Music::Album
      admin_album_path(parent)
    when Music::Song
      admin_song_path(parent)
    when Music::Albums::List
      admin_albums_list_path(parent)
    when Music::Songs::List
      admin_songs_list_path(parent)
    end
  end

  # Returns a display name for the parent
  def ai_chat_parent_display_name(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    case parent
    when Music::Artist
      parent.name
    when Music::Album, Music::Song
      parent.title
    when List
      parent.name
    else
      "#{parent.class.name} ##{parent.id}"
    end
  end

  # Returns the human-readable parent type
  def ai_chat_parent_type_label(ai_chat)
    return nil unless ai_chat.parent_type.present?

    case ai_chat.parent_type
    when "Music::Artist"
      "Artist"
    when "Music::Album"
      "Album"
    when "Music::Song"
      "Song"
    when "Music::Albums::List"
      "Albums List"
    when "Music::Songs::List"
      "Songs List"
    when /List$/
      "List"
    else
      ai_chat.parent_type.demodulize
    end
  end

  # Returns badge class for chat type
  def ai_chat_type_badge_class(chat_type)
    case chat_type
    when "general"
      "badge-ghost"
    when "ranking"
      "badge-primary"
    when "recommendation"
      "badge-secondary"
    when "analysis"
      "badge-accent"
    else
      "badge-ghost"
    end
  end

  # Returns badge class for provider
  def ai_chat_provider_badge_class(provider)
    case provider
    when "openai"
      "badge-success"
    when "anthropic"
      "badge-warning"
    when "gemini"
      "badge-info"
    when "local"
      "badge-ghost"
    else
      "badge-ghost"
    end
  end
end
