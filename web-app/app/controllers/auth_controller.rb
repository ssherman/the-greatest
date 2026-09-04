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

  include VisitorIp

  # Both endpoints are unauthenticated, and the repository is public, so an
  # attacker knows exactly what to hit. sign_in is a credential-stuffing target;
  # check_provider confirms whether an address has an account and names its
  # provider, which is an enumeration oracle.
  #
  # by: goes through visitor_ip, never request.remote_ip -- in production
  # remote_ip is the Cloudflare edge IP, so keying on it would put every visitor
  # in one bucket and lock out the whole site.
  #
  # with: is not optional. Rails' default raises TooManyRequests, which renders
  # an HTML error body to a caller that asked for JSON.
  SIGN_IN_RATE = 30
  CHECK_PROVIDER_RATE = 20
  RATE_WINDOW = 1.minute

  rate_limit to: SIGN_IN_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "auth-sign-in",
    only: [:sign_in]

  rate_limit to: CHECK_PROVIDER_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "auth-check-provider",
    only: [:check_provider]

  def sign_in
    if params[:jwt].blank?
      render json: {success: false, error: "Missing jwt parameter"}, status: :unauthorized
      return
    end

    result = Services::AuthenticationService.call(
      auth_token: params[:jwt],
      project_id: Rails.application.config.x.firebase_project_id,
      signup_domain: request.host
    )

    unless result[:success]
      render json: {
        success: false,
        error: result[:error],
        error_code: result[:error_code]
      }, status: :unauthorized
      return
    end

    user = result[:user]

    # Session fixation: a pre-authentication session id must not survive into
    # the authenticated session. reset_session discards it, so the id an
    # attacker could have planted is worthless.
    reset_session
    session[:user_id] = user.id
    session[:provider] = user.external_provider
    cookies[TG_UID_COOKIE] = {
      value: user.id.to_s,
      secure: Rails.env.production?,
      same_site: :lax
    }

    render json: {
      success: true,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        provider: user.external_provider
      }
    }
  rescue => e
    Rails.logger.error "Authentication error: #{e.class}: #{e.message}"
    render json: {success: false, error: "Authentication failed"}, status: :internal_server_error
  end

  def sign_out
    cookies.delete(TG_UID_COOKIE)
    # Same reasoning as sign_in: leaving the id intact lets a captured
    # pre-logout session id be reused against the next sign-in on this browser.
    reset_session

    render json: {success: true}
  end

  def check_provider
    email = params[:email]

    if email.blank?
      render json: {has_oauth_provider: false, provider: nil, message: nil}
      return
    end

    # .order(:id).first mirrors UserAuthenticationService#find_user: the table
    # holds case-insensitively duplicate email rows, so an unordered lookup
    # lets Postgres pick the row, and this endpoint would then advertise a
    # provider the sign-in path will not bind to.
    user = User.where("LOWER(email) = ?", email.downcase).order(:id).first

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

  private

  def render_rate_limited
    render json: {
      success: false,
      error: "Too many attempts. Please wait a moment and try again."
    }, status: :too_many_requests
  end
end
