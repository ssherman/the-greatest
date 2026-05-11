class AuthController < ApplicationController
  include Cacheable

  # Non-HttpOnly companion cookie carrying the signed-in user's id. JS reads it
  # to gate localStorage hydration of /user_list_state state on cached pages —
  # the HttpOnly session cookie isn't visible to JS and the cached HTML can't
  # carry per-user markers. Plain (not signed) since user_id is non-sensitive
  # and forging it doesn't grant access (the HttpOnly session is the real auth).
  TG_UID_COOKIE = :tg_uid

  skip_before_action :verify_authenticity_token, only: [:sign_in, :sign_out, :check_provider]
  before_action :prevent_caching

  def sign_in
    if params[:jwt].blank? || params[:provider].blank?
      render json: {success: false, error: "Missing jwt or provider parameter"}, status: :unauthorized
      return
    end

    # Log domain information for debugging
    Rails.logger.info "Authentication request from domain: #{params[:domain]} (current host: #{request.host})"

    result = Services::AuthenticationService.call(
      auth_token: params[:jwt],
      provider: params[:provider],
      user_data: params[:user_data]
    )

    if result[:success]
      session[:user_id] = result[:user].id
      session[:provider] = params[:provider]
      cookies[TG_UID_COOKIE] = {
        value: result[:user].id.to_s,
        secure: Rails.env.production?,
        same_site: :lax
      }

      render json: {
        success: true,
        user: {
          id: result[:user].id,
          email: result[:user].email,
          name: result[:user].name,
          provider: params[:provider]
        }
      }
    else
      render json: {
        success: false,
        error: result[:error]
      }, status: :unauthorized
    end
  rescue => e
    Rails.logger.error "Authentication error: #{e.message}"
    render json: {
      success: false,
      error: "Authentication failed"
    }, status: :internal_server_error
  end

  def sign_out
    session[:user_id] = nil
    session[:provider] = nil
    cookies.delete(TG_UID_COOKIE)

    render json: {success: true}
  end

  def check_provider
    email = params[:email]

    if email.blank?
      render json: {has_oauth_provider: false, provider: nil, message: nil}
      return
    end

    user = User.find_by("LOWER(email) = ?", email.downcase)

    # Only reveal OAuth providers, not password accounts (to avoid email enumeration)
    oauth_providers = %w[google apple facebook twitter]

    if user && oauth_providers.include?(user.external_provider)
      provider_name = user.external_provider.capitalize
      render json: {
        has_oauth_provider: true,
        provider: user.external_provider,
        message: "This email is associated with a #{provider_name} account. Please use 'Sign in with #{provider_name}' instead."
      }
    else
      render json: {has_oauth_provider: false, provider: nil, message: nil}
    end
  end
end
