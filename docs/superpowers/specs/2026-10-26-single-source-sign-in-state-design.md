# Single source of sign-in state

Date: 2026-10-26
Status: design, awaiting approval

## Why

On production books, Shane saw a page that disagreed with itself. The navbar showed **Login**, the
mobile menu showed the signed-in "My Books" links, and `/my/rankings` rendered his own rankings.
Firebase's console log read `Firebase auth state changed: no user` and nothing else: no error, no
sign-in attempt.

The site holds two independent records of "signed in" and nothing reconciles them:

| Record | Where it lives | Lifetime today | Who reads it |
|---|---|---|---|
| Rails session (`session[:user_id]`) | encrypted cookie, HttpOnly | until the browser closes | every server-side check: `current_user`, `/my/*`, `require_signed_in!`, the state endpoints |
| `tg_uid` | plain cookie, readable by JS, set by `AuthController#sign_in` | until the browser closes | `user_list_state_controller` (and the My Books nav links it reveals), `membership_state_controller`, `reading_goal_state_controller`, `csv_export_controller`, `reviews/widget_controller`, `user_list_widget_controller`, `firebase_loader.likelySignedIn()` |
| Firebase user | IndexedDB on the page's origin | until the refresh token is revoked or storage is cleared | **only** the navbar Login/Logout button (`authentication_controller.js#updateNavbarButton`) and the sign-in widget |

Firebase forgetting a user is routine: cleared site data, a revoked or failed token refresh, a
private window. The reverse also happens: after a normal browser restart the Rails session and
`tg_uid` are gone while Firebase still has the user, and nothing re-establishes the server session
(`handleAuthStateChange` marks the UI signed in without calling Rails). Either way, the page shows
two answers.

Shane's requirement: **the server and the client must always agree.**

## Goals

- Every part of every page agrees on whether the visitor is signed in.
- The Rails session is the single source of truth. Firebase is a credential exchange used only at
  the moment of sign-in, plus a sign-out step at logout.
- Sign-ins last 90 days, renewed by use, up to a hard limit of one year, and survive browser
  restarts.
- Logout ends the session server-side, so a copied session cookie stops working.
- Holds on all three live sites (books, music, games) and the admin layout, which share the
  sign-in widget.

## Non-goals

- Cloudflare rate limits (the 429s Shane also saw). Separate, later.
- Reducing the per-page state requests (`/user_list_state`, `/membership_state`, and on books
  `/my/reading-goals`, each fetched on every page view by a signed-in visitor). Shane is concerned
  about this and it is the **next** design, but it is not this one.
- A "log out of all devices" button or an admin session list. The new table makes them cheap later.
- Changing which providers exist or how Firebase verifies them.

## Anti-goals (would make this a failure even if it works)

- **Any new request to Rails per page view**, for anyone. Edge caching is the reason the site is
  fast and cheap; sign-in state must be readable locally in the browser.
- **A `Set-Cookie` header on an edge-cacheable response.** Cloudflare bypasses the cache when one is
  present (`Cacheable#skip_session_for_caching` exists for exactly this). Session renewal and
  conversion must happen only on uncached responses.
- **Trusting `tg_uid` for anything but presentation.** It is readable and forgeable by design.

## Constraints

- The repository is public. Assume an attacker has read every line of this design and the code.
- Edge-cached pages are byte-identical for every visitor; per-user state is hydrated client-side
  from uncached endpoints (`UserListStateController` and friends).
- Rails 8 conventions apply (generators, `bin/rails generate model`, annotaterb, standardrb).
- One Firebase project serves every domain (`firebase_auth_service.js`). This design does not
  change that.

## Design (decided)

### 1. Server-tracked sessions, Rails 8 style

Adopt the pattern from the Rails 8 authentication generator (`bin/rails generate authentication`),
adapted to this app. Use the generator's output as the reference, not as code to keep wholesale:
it ships password controllers and mailers this app does not want.

- A `sessions` table: `user_id` (FK, indexed), `user_agent`, `ip_address`, timestamps, plus
  whatever the builder needs to enforce expiry server-side (see below). `User has_many :sessions,
  dependent: :destroy`. Any user-merge code must move or drop the rows, as it does for other
  user-owned tables.
- Sign-in (`AuthController#sign_in`) keeps its existing verification and `reset_session`, then
  creates a `Session` row and sets an HttpOnly, Secure (production), `SameSite=Lax` **signed** cookie
  pointing at it, expiring in 90 days.
- `current_user` (both `ApplicationController` and `Admin::BaseController`, ideally one shared
  concern) resolves the user through that cookie and its `Session` row instead of
  `session[:user_id]`.
- Sign-out destroys the row, deletes both cookies, and calls `reset_session`.
- **Expiry is enforced on the server**, not only by the cookie's `expires`. A copied cookie can be
  replayed with any expiry the attacker likes, so a row whose last activity is more than 90 days
  old is treated as no session (and destroyed).
- Expired rows are cleaned up by a scheduled job (`sidekiq-cron` and `config/schedule.yml` already
  exist).

### 2. `tg_uid` mirrors the server session exactly

- Same lifetime as the session cookie (90 days), set and renewed and deleted in the same places.
- Still a plain, JS-readable cookie holding only the user id; still never trusted server-side.
  Add a comment where it is set saying so, because the repo is public and the next reader will ask.
- It is the **only** signal the page uses to decide signed-in vs signed-out presentation.

### 3. Renewal and conversion happen only on uncached responses

- "Renewed by use" means: when an uncached request resolves a valid session whose last renewal is
  older than some threshold (builder's call, e.g. a day), bump the row and re-issue both cookies
  with a fresh 90-day expiry. Doing it on every request would write a row per request.
- The natural carrier is `/user_list_state`, which every signed-in page view already fetches and
  which already backfills `tg_uid` (`UserListStateController#ensure_uid_cookie`). No new request.
- Edge-cacheable responses never set cookies and never create or renew sessions. Prefer that
  cacheable actions do not resolve the session at all.

### 4. Existing sign-ins end on deploy

Shane decided: everyone signed in today signs in again once after this ships. All three sites have
little traffic, so a one-time sign-out costs less than carrying a conversion path. `session[:user_id]`
is no longer read anywhere. A leftover `tg_uid` from the old scheme has no session behind it, so the
first state endpoint that returns 401 clears it and every widget falls back to signed out.

### 5. The navbar and every widget read `tg_uid`

- `authentication_controller.js#updateNavbarButton` (and the rest of the widget's signed-in
  presentation: sign-in vs sign-out controls) decides from `tg_uid`, not from Firebase's auth state.
- The user-info block inside the login modal (`userInfo` target, filled from the Firebase user's
  name and photo by `buildUserInfo`) is dropped. A signed-in visitor sees Logout in the navbar and
  rarely opens the modal, and keeping it would mean either reading Firebase again or adding fields to
  `/user_list_state`.
- Firebase's `onAuthStateChanged` no longer drives what the page shows.
- When `tg_uid` changes during a page's life (sign-in succeeds, sign-out, a state endpoint returns
  401 and clears it), every widget updates. The existing `auth:success` / `auth:signout` /
  `user-list-state:cleared` events are the likely mechanism.

### 6. Firebase only signs in and signs out

- Sign-in: unchanged. Firebase produces an ID token, Rails verifies it and creates the session.
- Sign-out: ends the Rails session first (that is the one that matters), then signs Firebase out.
  Both always run; a Firebase failure must not leave the Rails session alive.
- **Disagreements resolve themselves, without new requests:**
  - Rails session present, Firebase has forgotten the user: nothing happens. The visitor is signed
    in; Firebase is not needed until sign-out.
  - Firebase has a user, Rails does not (`tg_uid` absent): present as signed out, and sign the
    Firebase user out quietly the next time Firebase is loaded anyway. This must **not** fire during
    an in-flight sign-in (the OAuth redirect round trip, or the window between Firebase signing in
    and `/auth/sign_in` answering). The existing pending-redirect marker in `firebase_loader.js`
    is the starting point.
  - **Exception: an email/password user awaiting verification.** Rails refuses an unverified
    address (`email_verification_required`) and today the Firebase user is deliberately kept so
    `resendVerification()` has someone to send to (`pendingVerification` in
    `authentication_controller.js`). That must keep working across a reload: when Rails returns
    that code, set a browser marker; while it is set, do not sign the Firebase user out, and show the
    verification message rather than signed-in chrome. Clear it on successful sign-in, on sign-out,
    and when Firebase no longer has a user. This state is never "signed in": no session, no
    `tg_uid`.
- The localStorage "signed-in hint" in `firebase_loader.js` existed because `tg_uid` died on browser
  restart. With a 90-day `tg_uid` it is likely unnecessary; the builder decides whether lazy-loading
  Firebase still needs it.

### 7. Remove the per-visitor byte from music, games and movies layouts

`layouts/{music,games,movies}/application.html.erb` stamp `data-signed-in="<%= signed_in? %>"` on
`<body>`. Nothing reads it, it puts per-visitor state into edge-cached HTML, and under this design it
would force a session lookup on every cacheable render. Remove it.

## Security notes (the repo is public)

Kept as-is: Firebase ID-token verification on the server, `reset_session` on sign-in (session
fixation), JSON-only sign-in/sign-out as the CSRF defence (`require_json_request`), the `auth-sign-in`
rate limit.

New or changed:
- The session cookie is signed (tamper-evident) and HttpOnly; its value is a row reference whose
  validity the server checks on every use. Forging or replaying an old one gets nothing once the row
  is gone.
- Logout destroys **this browser's** row only, so it ends every copy of that cookie wherever it
  was copied to; the user's sessions on other devices stay signed in ("log out of all devices" is a
  non-goal). Account deletion destroys all of the user's rows through `dependent: :destroy`. There is
  no user-merge code in the app today; if some is added, it must handle `sessions`.
- Server-side expiry (above), not cookie expiry, is what bounds a stolen cookie. Two limits apply:
  90 days of inactivity, and a **hard limit of one year from sign-in** that renewal never extends.
  The row records when the session was created and renewal never moves it. Past either limit the
  row is destroyed and the visitor is signed out. Shane chose to have a hard limit; one year is
  Claude's call.
- `tg_uid` grants nothing. A visitor who forges it sees signed-in chrome on cached pages until the
  next state endpoint returns 401 and clears it.
- Store `ip_address` and `user_agent` as the generator does; they are personal data and get
  destroyed with the row.

## Testing

- Minitest for the session lifecycle: create on sign-in, resolve, renew past the threshold, server-
  side expiry (both the 90-day inactivity limit and the one-year hard limit, which renewal must
  not extend), destroy on sign-out and on user destroy/merge, no `Set-Cookie` on a cacheable
  response for a signed-in visitor, and a legacy `session[:user_id]` cookie no longer signs anyone
  in.
- Playwright on books, music and games (specs exist per domain, see `e2e/tests/<domain>/`):
  - sign in, reload, every auth indicator agrees (navbar button, mobile menu links, a `/my/*` page);
  - sign out, every indicator agrees, and replaying the old session cookie is rejected;
  - **Firebase forgot me:** clear Firebase's IndexedDB with the server session intact, reload,
    still consistently signed in;
  - **server forgot me:** destroy the server session with Firebase intact, reload, consistently
    signed out after the next state fetch, and Firebase is signed out.
- Existing auth E2E specs (`email-auth.spec.ts`, `oauth-providers.spec.ts`,
  `firebase-lazy-load.spec.ts`) must keep passing or be updated deliberately.

## Calls made without Shane (check these)

- 90-day lifetime, renewed by use. Shane said "a month or 3 months or something".
- One-year hard limit. Shane wanted a hard limit but did not name a length. The cookies' `expires`
  should never run past it either.
- "Firebase forgot me" leaves the visitor signed in; "server forgot me" signs Firebase out.
- Logout ends only this browser's session, not the user's other devices.
- The signed-in user-info block in the login modal is dropped rather than re-sourced.
- Unverified email/password users keep their Firebase sign-in across reloads via a browser marker,
  so "resend verification" keeps working.
- Removing the unused `data-signed-in` attribute is folded into this work because the new session
  lookup makes it actively harmful, not just noise.

## Left to the builder

- Renewal threshold, cleanup job cadence, column names, and whether the session cookie holds the
  row id (generator default) or a random token.
- How widgets subscribe to `tg_uid` changes.
- Whether `firebase_loader.js`'s localStorage hint survives.
