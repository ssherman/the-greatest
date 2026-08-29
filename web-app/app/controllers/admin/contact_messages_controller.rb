# The contact inbox, scoped to one site. Split per domain rather than combined,
# following Admin::CorrectionsController: each admin reads its own site's queue.
class Admin::ContactMessagesController < Admin::BaseController
  STATUSES = %w[pending replied spam].freeze

  # The single source of truth for which route helper prefix each domain's admin
  # namespace uses. Music's has no domain infix.
  ADMIN_PATHS = {
    books: :admin_books_contact_messages_path,
    music: :admin_contact_messages_path,
    games: :admin_games_contact_messages_path
  }.freeze

  before_action :set_contact_message, only: [:show, :resolve]

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @contact_messages = pagy(domain_scope.where(status: @status).order(created_at: :desc))
  end

  def show
  end

  def resolve
    status = params[:status]
    return redirect_to contact_messages_index_path unless STATUSES.include?(status)

    @contact_message.update!(
      status: status,
      replied_at: (status == "replied") ? Time.current : @contact_message.replied_at
    )

    redirect_to contact_messages_index_path, notice: "Message marked #{status}."
  end

  private

  # find_by!(id:) inside the domain scope, so another site's message 404s here
  # rather than rendering under the wrong admin.
  def set_contact_message
    @contact_message = domain_scope.find_by!(id: params[:id])
  end

  def domain_scope
    ContactMessage.where(domain: current_domain)
  end

  def contact_messages_index_path(**options)
    public_send(ADMIN_PATHS.fetch(current_domain.to_sym), **options)
  end
  helper_method :contact_messages_index_path

  def contact_message_path_for(contact_message)
    helper = ADMIN_PATHS.fetch(current_domain.to_sym).to_s.sub("_messages_path", "_message_path")
    public_send(helper, contact_message)
  end
  helper_method :contact_message_path_for

  def resolve_path_for(contact_message)
    helper = "resolve_" + ADMIN_PATHS.fetch(current_domain.to_sym).to_s.sub("_messages_path", "_message_path")
    public_send(helper, contact_message)
  end
  helper_method :resolve_path_for
end
