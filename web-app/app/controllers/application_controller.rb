class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  include ApplicationHelper
  include Pundit::Authorization
  include Cacheable
  include RankingConfigurationGating
  include CurrentDomain

  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  helper_method :current_user, :signed_in?

  def current_user
    user_id = session[:user_id]
    return nil if user_id.blank?

    @current_user ||= User.find_by(id: user_id)
  end

  def signed_in?
    !!current_user
  end

  # Halts the action with a 401 (JSON) or redirect (HTML) when no user is signed in.
  # JSON-only controllers can call this in a before_action; the JsonErrorResponses
  # concern provides the matching error body shape.
  def require_signed_in!
    return if current_user

    if request.format.json?
      render json: {error: {code: "unauthenticated", message: "Sign in required"}},
        status: :unauthorized
    else
      respond_to do |format|
        format.json { render json: {error: {code: "unauthenticated", message: "Sign in required"}}, status: :unauthorized }
        format.any { redirect_to "/", alert: "Please sign in to continue." }
      end
    end
  end

  private

  def render_not_found
    prevent_caching
    render file: "#{Rails.root}/public/404.html", status: :not_found, layout: false
  end

  def user_not_authorized
    flash[:alert] = "You are not authorized to perform this action."
    fallback = respond_to?(:domain_root_path, true) ? domain_root_path : "/"
    redirect_back(fallback_location: fallback)
  end

  # Load ranking configuration based on controller class configuration
  # Controllers should define self.ranking_configuration_class to use this
  #
  # @param config_class [Class] Override the ranking configuration class (useful for multi-config controllers)
  # @param instance_var [Symbol] Instance variable name to store the config (defaults to @ranking_configuration)
  def load_ranking_configuration(config_class: nil, instance_var: :@ranking_configuration)
    # Use provided class or fall back to controller's ranking_configuration_class
    config_class ||= begin
      return unless respond_to?(:ranking_configuration_class, true) || self.class.respond_to?(:ranking_configuration_class)
      self.class.ranking_configuration_class
    end

    return unless config_class

    ranking_config = if params[:ranking_configuration_id].present?
      RankingConfiguration.find(params[:ranking_configuration_id])
    else
      config_class.default_primary
    end

    raise ActiveRecord::RecordNotFound unless ranking_config

    # Validate the ranking configuration is of the expected type
    unless config_class == RankingConfiguration || ranking_config.is_a?(config_class)
      raise ActiveRecord::RecordNotFound
    end

    gate_ranking_configuration!(ranking_config)
    instance_variable_set(instance_var, ranking_config)
  end
end
