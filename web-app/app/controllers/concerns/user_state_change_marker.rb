# A cookie whose value changes on every write that alters this visitor's
# per-user state (lists, memberships). The browser keeps that state cached and
# re-checks it hourly; a changed marker tells it the copy is stale now, without
# a request. It is a presentation hint: nothing server-side trusts it.
module UserStateChangeMarker
  extend ActiveSupport::Concern

  COOKIE = :tg_state_mark

  private

  # Returns the new value (nil when skipped). JSON writes echo it back as
  # `state_mark` so the browser can tell whether the cookie it reads after the
  # response is still this write's, or was moved again by another tab.
  def mark_user_state_changed
    # An edge-cacheable response must carry no per-visitor byte or Set-Cookie.
    return if request.session_options[:skip]

    mark = SecureRandom.hex(8)
    cookies[COOKIE] = {
      value: mark,
      path: "/",
      same_site: :lax,
      secure: Rails.env.production?,
      expires: 1.year.from_now
    }
    mark
  end

  # The marker this request arrived with. JSON writes echo it as
  # `state_mark_was`: if it differs from the mark the browser held when it
  # started the write, another change landed before this one reached the
  # server, and the browser must not treat its entry as holding everything.
  def incoming_state_mark
    request.cookies[COOKIE.to_s]
  end
end
