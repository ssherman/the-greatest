class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include ApplicationHelper

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  before_action :set_current_domain

  private

  def set_current_domain
    @current_domain = detect_current_domain
    @domain_settings = Rails.application.config.domain_settings[@current_domain]

    # Debug logging
    Rails.logger.info "Host: #{request.host}"
    Rails.logger.info "Detected domain: #{@current_domain}"
    Rails.logger.info "Domain settings: #{@domain_settings}"
  end

  def detect_current_domain
    host = request.host

    case host
    when Rails.application.config.domains[:music]
      :music
    when Rails.application.config.domains[:movies]
      :movies
    when Rails.application.config.domains[:games]
      :games
    else
      :books # default
    end
  end

  attr_reader :current_domain

  attr_reader :domain_settings

  helper_method :current_domain, :domain_settings

  def render_not_found
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end
end
