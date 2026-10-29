# A cookie whose value changes on every write that alters this visitor's
# per-user state (lists, memberships). The browser keeps that state cached and
# re-checks it hourly; a changed marker tells it the copy is stale now, without
# a request. It is a presentation hint: nothing server-side trusts it.
module UserStateChangeMarker
  extend ActiveSupport::Concern

  COOKIE = :tg_state_mark

  private

  def mark_user_state_changed
    # An edge-cacheable response must carry no per-visitor byte or Set-Cookie.
    return if request.session_options[:skip]

    cookies[COOKIE] = {
      value: SecureRandom.hex(8),
      path: "/",
      same_site: :lax,
      secure: Rails.env.production?,
      expires: 1.year.from_now
    }
  end
end
