class Admin::BaseController < ApplicationController
  include Pagy::Backend
  include Cacheable

  before_action :authenticate_admin!
  before_action :prevent_caching

  private

  def authenticate_admin!
    # Global admin or editor has full access
    # Domain-specific controllers should override this to allow domain roles
    unless current_user&.admin? || current_user&.editor?
      redirect_to domain_root_path, alert: "Access denied. Admin or editor role required."
    end
  end

  # Require admin role (for user management, cloudflare, etc.)
  def require_admin_role!
    unless current_user&.admin?
      redirect_to domain_root_path, alert: "Access denied. Admin role required."
    end
  end

  # Get current user's domain role for the current domain
  def current_domain_role
    return nil unless current_user && current_domain
    @current_domain_role ||= current_user.domain_role_for(current_domain.to_s)
  end
  helper_method :current_domain_role

  # Helper methods for views to check permissions
  def current_user_can_write?
    current_user&.admin? || current_user&.editor? || current_user&.can_write_in_domain?(current_domain.to_s)
  end
  helper_method :current_user_can_write?

  def current_user_can_delete?
    current_user&.admin? || current_user&.editor? || current_user&.can_delete_in_domain?(current_domain.to_s)
  end
  helper_method :current_user_can_delete?

  def current_user_can_manage?
    current_user&.admin? || current_user&.can_manage_domain?(current_domain.to_s)
  end
  helper_method :current_user_can_manage?

  def domain_root_path
    case current_domain
    when :music
      music_root_path
    when :movies
      movies_root_path
    when :games
      games_root_path
    else
      books_root_path
    end
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id].present?
  end
  helper_method :current_user
end
