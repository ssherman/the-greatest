class Admin::Music::AiChatsController < Admin::Music::BaseController
  before_action :set_ai_chat, only: [:show]

  # Music-related parent types for scoping
  MUSIC_PARENT_TYPES = %w[
    Music::Artist
    Music::Album
    Music::Song
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
    AiChat.where(parent_type: MUSIC_PARENT_TYPES)
      .or(AiChat.where(parent_type: nil))
  end
end
