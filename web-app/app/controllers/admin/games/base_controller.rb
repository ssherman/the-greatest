class Admin::Games::BaseController < Admin::BaseController
  layout "games/admin"

  private

  # Override to allow domain-scoped access for games domain
  def authenticate_admin!
    # Global admin or editor has full access
    return if current_user&.admin? || current_user&.editor?

    # Allow users with games domain role
    unless current_user&.can_access_domain?("games")
      redirect_to domain_root_path, alert: "Access denied. You need permission for games admin."
    end
  end
end
