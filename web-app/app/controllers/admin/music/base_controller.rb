class Admin::Music::BaseController < Admin::BaseController
  layout "music/admin"

  private

  # Override to allow domain-scoped access for music domain
  def authenticate_admin!
    # Global admin or editor has full access
    return if current_user&.admin? || current_user&.editor?

    # Allow users with music domain role
    unless current_user&.can_access_domain?("music")
      redirect_to domain_root_path, alert: "Access denied. You need permission for music admin."
    end
  end
end
