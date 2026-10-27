# frozen_string_literal: true

# Server-tracked sign-in. The browser holds a signed id for a row in `sessions`;
# the row is the only thing that says "signed in", so deleting it (logout,
# expiry, an admin) signs that browser out everywhere at once. The Rails
# cookie-store session carries no identity any more.
#
# tg_uid is the JS-readable companion: it only gates localStorage hydration on
# edge-cached pages and is never trusted server-side.
module SessionAuthentication
  extend ActiveSupport::Concern

  SESSION_COOKIE = :tg_session

  included do
    include VisitorIp
  end

  private

  def current_session
    return @current_session if defined?(@current_session)

    @current_session = find_current_session
  end

  def current_user
    current_session&.user
  end

  # reset_session first: a pre-authentication session id must not survive into
  # the authenticated state (fixation).
  def start_session_for(user)
    reset_session
    session = Session.create!(
      user: user,
      user_agent: request.user_agent,
      ip_address: visitor_ip,
      last_active_at: Time.current
    )
    write_session_cookies(session)
    @current_session = session
  end

  # Works with no current session so a stale cookie can still be cleared.
  def end_current_session
    current_session&.destroy
    delete_session_cookies
    reset_session
    @current_session = nil
  end

  def session_expires_at(session)
    [session.last_active_at + Session::IDLE_TIMEOUT, session.created_at + Session::MAX_LIFETIME].min
  end

  def write_session_cookies(session)
    expires = session_expires_at(session)
    cookies.signed[SESSION_COOKIE] = {
      value: session.id,
      expires: expires,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax
    }
    cookies[AuthController::TG_UID_COOKIE] = {
      value: session.user_id.to_s,
      expires: expires,
      secure: Rails.env.production?,
      same_site: :lax
    }
  end

  def delete_session_cookies
    cookies.delete(SESSION_COOKIE)
    cookies.delete(AuthController::TG_UID_COOKIE)
  end

  def find_current_session
    id = cookies.signed[SESSION_COOKIE]
    return nil if id.blank?

    # eager_load: one query for session and user, as the old User.find_by was.
    record = Session.eager_load(:user).find_by(id: id)
    return nil unless record

    if session_expires_at(record) <= Time.current
      record.destroy
      # An edge-cacheable response must carry no Set-Cookie, or Cloudflare
      # bypasses its cache. The stale cookie is cleared on the next uncached request.
      delete_session_cookies unless request.session_options[:skip]
      return nil
    end

    record
  end
end
