module Admin::AiChatsHelper
  # Returns the admin path for an AI chat's parent, or nil if no path available
  def admin_ai_chat_parent_path(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    if parent.is_a?(List)
      Admin::DomainRouting.list_config(parent)&.dig(:path)
    else
      Admin::DomainRouting.path_for(parent)
    end
  end

  # Returns a display name for the parent. Every registered parent model has
  # exactly one of a name or a title column.
  def ai_chat_parent_display_name(ai_chat)
    parent = ai_chat.parent
    return nil unless parent

    parent.try(:name).presence || parent.try(:title).presence || "#{parent.class.name} ##{parent.id}"
  end

  # Returns the human-readable parent type.
  # Lists are STI and Rails stores the base class ("List") in parent_type, so a
  # list's label comes from the loaded record's own class.
  def ai_chat_parent_type_label(ai_chat)
    return nil if ai_chat.parent_type.blank?

    parent = ai_chat.parent
    return ai_chat.parent_type.demodulize if parent.nil?
    return parent.class.name.demodulize unless parent.is_a?(List)

    item_label = Admin::DomainRouting::LISTS.dig(parent.class.name, :item_label)
    item_label ? "#{item_label} List" : "List"
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
