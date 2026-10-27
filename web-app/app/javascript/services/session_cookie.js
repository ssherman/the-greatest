// tg_uid is the page's one signal for signed-in vs signed-out presentation.
// AuthController sets it beside the HttpOnly tg_session cookie with the same
// expiry, /user_list_state renews both, and /auth/sign_out deletes both, so it
// mirrors the server session without a request per page view.
//
// It is presentation only. The server never trusts it: a forged tg_uid gets
// signed-in chrome on a cached page until the next state endpoint answers 401
// and clears it.

// The user id as a string, or null when this browser has no session.
export function signedInUid() {
  const match = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
  return match ? decodeURIComponent(match[1]) : null
}

// Must stay byte-for-byte the string user_list_state_controller.js writes in
// _clearCookieUid: a delete only matches a cookie with the same path.
export function clearUidCookie() {
  document.cookie = "tg_uid=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/; SameSite=Lax"
}
