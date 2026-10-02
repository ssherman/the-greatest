class Admin::AiChatsController < Admin::BaseController
  include Admin::DomainScopedAuth

  # Each domain's admin namespace names its own `resources :ai_chats`: music's
  # `namespace :admin, module: "admin/music"` carries no `as:`, so its helpers
  # are the bare `admin_ai_chats_path` family; books and games add their prefix.
  ROUTE_PREFIXES = {
    music: "admin",
    books: "admin_books",
    games: "admin_games"
  }.freeze

  before_action :set_ai_chat, only: [:show]

  def index
    @pagy, @ai_chats = pagy(
      domain_scope.includes(:parent, :user).order(created_at: :desc),
      limit: 25
    )
  end

  def show
  end

  def ai_chats_index_path(**options)
    public_send(:"#{route_prefix}_ai_chats_path", **options)
  end
  helper_method :ai_chats_index_path

  def ai_chat_path_for(ai_chat)
    public_send(:"#{route_prefix}_ai_chat_path", ai_chat)
  end
  helper_method :ai_chat_path_for

  private

  def route_prefix
    ROUTE_PREFIXES.fetch(current_domain.to_sym)
  end

  def domain_scope
    AiChat.for_parent_types(
      Admin::DomainRouting.entity_types_for(current_domain),
      Admin::DomainRouting.list_types_for(current_domain)
    )
  end

  def set_ai_chat
    @ai_chat = domain_scope.find(params[:id])
  end
end
