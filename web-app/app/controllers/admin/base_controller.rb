class Admin::BaseController < ApplicationController
  include Pagy::Backend
  include Cacheable

  before_action :authenticate_admin!
  before_action :prevent_caching

  private

  def authenticate_admin!
    unless current_user&.admin? || current_user&.editor?
      redirect_to domain_root_path, alert: "Access denied. Admin or editor role required."
    end
  end

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
