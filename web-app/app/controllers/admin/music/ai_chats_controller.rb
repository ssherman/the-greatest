class Admin::Music::AiChatsController < Admin::Music::BaseController
  before_action :set_ai_chat, only: [:show]

  # Direct music parent types (non-STI models)
  MUSIC_DIRECT_PARENT_TYPES = %w[
    Music::Artist
    Music::Album
    Music::Song
  ].freeze

  # Music List STI subclass types (stored in lists.type, not ai_chats.parent_type)
  MUSIC_LIST_STI_TYPES = %w[
    Music::Albums::List
    Music::Songs::List
  ].freeze

  def index
    @ai_chats = music_scoped_ai_chats
      .includes(:parent, :user)
      .order(created_at: :desc)

    @pagy, @ai_chats = pagy(@ai_chats, limit: 25)
  end

  def show
  end

  private

  def set_ai_chat
    @ai_chat = music_scoped_ai_chats.find(params[:id])
  end

  def music_scoped_ai_chats
    # Get IDs from the JOIN-based list query, then combine with simple WHERE conditions
    # This avoids the ".or() incompatible with joins" issue
    list_chat_ids = AiChat.with_list_parent_types(MUSIC_LIST_STI_TYPES).pluck(:id)

    AiChat.where(parent_type: MUSIC_DIRECT_PARENT_TYPES)
      .or(AiChat.where(parent_type: nil))
      .or(AiChat.where(id: list_chat_ids))
  end
end
