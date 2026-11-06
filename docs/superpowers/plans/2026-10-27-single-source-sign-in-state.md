# Single Source of Sign-In State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Rails session the only record of "signed in", backed by a `sessions` table, and make every widget on every page (navbar button included) read it through the `tg_uid` cookie, with no new per-page requests.

**Architecture:** A Rails 8 style `Session` model plus a `SessionAuthentication` controller concern replace `session[:user_id]`. A signed HttpOnly `tg_session` cookie points at the row; the plain `tg_uid` cookie mirrors it with the same expiry for JavaScript. `authentication_controller.js` stops rendering from Firebase's auth state and renders from `tg_uid`; Firebase is loaded only to sign in, to sign out, or to finish a redirect/verification flow.

**Tech Stack:** Rails 8, Minitest + Mocha + fixtures, Sidekiq + sidekiq-cron, Stimulus, Firebase JS SDK, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-26-single-source-sign-in-state-design.md`

## Global Constraints

- Run Rails/yarn commands from `web-app/`. Lint with `bundle exec standardrb`, never `bin/rubocop`.
- Use generators: `bin/rails generate model`, `bin/rails generate sidekiq:job`. `bin/rails db:migrate` runs annotaterb; never set `ANNOTATERB_SKIP_ON_DB_TASKS`, never hand-write a schema block. The dev DB is shared across worktrees: drop annotation lines for columns this branch's `schema.rb` lacks.
- Session lifetime: **90 days of inactivity** (`Session::IDLE_TIMEOUT = 90.days`), **hard limit one year from sign-in** (`Session::MAX_LIFETIME = 1.year`) that renewal never extends. Renew at most once a day (`Session::RENEW_AFTER = 1.day`).
- Cookies: `tg_session` (signed, HttpOnly, `SameSite=Lax`, Secure in production) and `tg_uid` (plain, JS-readable, `SameSite=Lax`, Secure in production), both with `expires` = the session's expiry. `tg_uid` holds only the user id and is never trusted server-side.
- **No `Set-Cookie` on an edge-cacheable response** (one where `request.session_options[:skip]` is true). **No new request to Rails per page view.**
- Logout destroys only this browser's `Session` row.
- Existing sign-ins are not converted: `session[:user_id]` is no longer read anywhere; everyone signs in again once.
- Minitest 6: `assert_nil`, never `assert_equal nil`. Controller tests assert behaviour, not markup.
- Never commit to `main`. This branch is `worktree-auth-state-single-source`.

## Review Focus

1. **A signed-in visitor on an edge-cached page whose session has expired** must not cause a `Set-Cookie` on that cached response (it would poison or bypass the Cloudflare cache). Pinned in Task 2.
2. **An in-flight email/password sign-in**: Firebase reports the user before `/auth/sign_in` answers, while `tg_uid` is still absent. The reconcile rule must not sign Firebase out in that window. Pinned in Task 5 (E2E sign-in still succeeds for email/password on every domain).
3. **Renewal never moves the hard limit**: a session used daily for a year still expires at `created_at + 1.year`, and the cookie `expires` never runs past it. Pinned in Task 3.
4. **Sign-out when the Firebase bundle fails to load** must still end the Rails session. Pinned in Task 5 (Rails call goes first; the existing best-effort Firebase step comes after).
5. **A forged `tg_uid` with no `tg_session`** shows signed-in chrome only until `/user_list_state` answers 401, which clears it, and every widget, navbar included, flips to signed out. Pinned in Task 6.

---

### Task 1: `Session` model, table, cleanup job

**Files:**
- Create (generator): `web-app/db/migrate/*_create_sessions.rb`, `web-app/app/models/session.rb`, `web-app/test/models/session_test.rb`, `web-app/test/fixtures/sessions.yml`
- Create (generator): `web-app/app/sidekiq/sessions/prune_expired_job.rb`, `web-app/test/sidekiq/sessions/prune_expired_job_test.rb`
- Modify: `web-app/app/models/user.rb` (add association near `api_tokens`), `web-app/config/schedule.yml`

**Interfaces:**
- Produces: `Session` (`belongs_to :user`; columns `user_id`, `user_agent`, `ip_address`, `last_active_at` (null: false), timestamps); constants `Session::IDLE_TIMEOUT`, `Session::MAX_LIFETIME`, `Session::RENEW_AFTER`; scope `Session.expired(now = Time.current)`; `User#sessions` (`dependent: :destroy`); `Sessions::PruneExpiredJob#perform`.

- [ ] **Step 1: Generate** `bin/rails generate model Session user:references user_agent:string ip_address:string last_active_at:datetime`. Edit the migration so `last_active_at` is `null: false`. Run `bin/rails db:migrate` and check the annotation diff.
- [ ] **Step 2: Write failing tests** in `test/models/session_test.rb`:
  - `"expired scope includes a session idle for longer than IDLE_TIMEOUT"`: `last_active_at: 91.days.ago, created_at: 100.days.ago` is in `Session.expired`.
  - `"expired scope includes a session past MAX_LIFETIME even if active today"`: `last_active_at: 1.minute.ago, created_at: (1.year + 1.day).ago` is in `Session.expired`.
  - `"expired scope excludes a live session"`: `last_active_at: 1.day.ago, created_at: 30.days.ago` is not.
  - `"destroying a user destroys their sessions"`: `assert_difference -> { Session.count }, -1 { user.destroy }`.
  Add two fixtures in `sessions.yml`: `regular_user_session` (`user: regular_user`, recent) and `stale_session` (idle > 90 days). Check the real user fixture names first.
- [ ] **Step 3: Run** `bin/rails test test/models/session_test.rb`. Expected: FAIL (no scope/constants/association).
- [ ] **Step 4: Implement** the constants and `scope :expired, ->(now = Time.current) { where("last_active_at < ? OR created_at < ?", now - IDLE_TIMEOUT, now - MAX_LIFETIME) }` on `Session`; `has_many :sessions, dependent: :destroy` on `User`. The model holds nothing else (skinny models).
- [ ] **Step 5: Run** the model test. Expected: PASS.
- [ ] **Step 6: Generate** `bin/rails generate sidekiq:job sessions/prune_expired`. Test `"deletes expired sessions and keeps live ones"` using the two fixtures. Implement `perform` as `Session.expired.delete_all` (no callbacks, nothing depends on them). Add to `config/schedule.yml`:
  ```yaml
  sessions_prune_expired:
    class: Sessions::PruneExpiredJob
    cron: "15 3 * * *"
    description: "Delete sign-in sessions past their idle timeout or hard limit"
  ```
- [ ] **Step 7: Run** `bin/rails test test/models/session_test.rb test/sidekiq/sessions test/models/user_test.rb`. Expected: PASS.
- [ ] **Step 8: Commit** `Add Session model and nightly prune job`.

### Task 2: `SessionAuthentication` concern; sign-in, sign-out and `current_user` use it

**Files:**
- Create: `web-app/app/controllers/concerns/session_authentication.rb`, `web-app/test/controllers/session_authentication_test.rb`
- Modify: `web-app/app/controllers/application_controller.rb:16-21` (`current_user`), `web-app/app/controllers/admin/base_controller.rb:63-66` (delete its `current_user` override and `helper_method` line; it inherits from `ApplicationController`), `web-app/app/controllers/auth_controller.rb:73-107`, `web-app/test/controllers/auth_controller_test.rb` (every `session[:user_id]` assertion)

**Interfaces:**
- Consumes: `Session`, its constants (Task 1); `VisitorIp#visitor_ip`.
- Produces (private controller methods, included into `ApplicationController`):
  - `SessionAuthentication::SESSION_COOKIE = :tg_session`
  - `current_session -> Session | nil`: reads `cookies.signed[SESSION_COOKIE]`, finds the row, memoised. An expired row is destroyed and treated as nil; its cookies are deleted **only if** `request.session_options[:skip]` is not true.
  - `current_user -> User | nil` = `current_session&.user` (stays a `helper_method`).
  - `start_session_for(user) -> Session`: `reset_session`, creates the row (`user_agent: request.user_agent`, `ip_address: visitor_ip`, `last_active_at: Time.current`), writes both cookies.
  - `end_current_session -> void`: destroys the row if any, deletes `tg_session` and `tg_uid`, `reset_session`.
  - `session_expires_at(session) -> Time` = `[session.last_active_at + Session::IDLE_TIMEOUT, session.created_at + Session::MAX_LIFETIME].min`.
  - `write_session_cookies(session) -> void`: sets both cookies per Global Constraints with `expires: session_expires_at(session)`.
  - `AuthController::TG_UID_COOKIE` stays where it is; the concern uses it.

- [ ] **Step 1: Write failing tests** in `test/controllers/session_authentication_test.rb` (integration tests through real endpoints; sign in with `sign_in_as(user, stub_auth: true)`):
  - `"sign in creates one Session row for the user and sets tg_session and tg_uid"`.
  - `"tg_uid and tg_session expire at the session's expiry"`: parse `Set-Cookie` headers from the sign-in response; `expires` ≈ now + 90 days.
  - `"a request with a valid tg_session resolves current_user"`: `get "/user_list_state", as: :json` → 200.
  - `"deleting the Session row signs the browser out"`: sign in, `Session.delete_all`, request `/user_list_state` → 401 even though the Rails cookie-store session still exists. After Step 3, `grep -rn "session\[:user_id\]" app` must find nothing.
  - `"sign out destroys only this browser's session"`: create a second `Session` for the same user directly; sign out; the second row still exists, this one is gone.
  - `"an old tg_session cookie replayed after sign out is rejected"`: capture `cookies[:tg_session]` before sign out, set it back after, `/user_list_state` → 401.
  - `"an expired session is destroyed and treated as signed out"`: travel past 90 days of idle (`travel 91.days`), `/user_list_state` → 401, row gone.
  - `"a cacheable page sets no cookie for a visitor whose session has expired"`: sign in, travel 91 days, `get` a books page that uses `cache_for_show_page` or `cache_for_index_page` (pick a real cacheable route from `config/routes.rb`); assert `response.headers["Set-Cookie"]` is blank and `Cache-Control` includes `public`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/session_authentication_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement** the concern; `include SessionAuthentication` in `ApplicationController`, replacing its `current_user` body; remove the admin override. In `AuthController#sign_in` replace lines 73-85 (`reset_session` through the `tg_uid` write) with `start_session_for(user)`, keeping the fixation comment; drop `session[:provider]`. `#sign_out` becomes `end_current_session` plus the existing JSON render. Rewrite the existing `auth_controller_test.rb` assertions on `session[:user_id]` to assert on `Session.count` / `cookies[:tg_session]` instead, keeping each test's intent (the L3 tests: no session row is created; sign-out refused leaves the row).
- [ ] **Step 4: Run** `bin/rails test test/controllers/` then the full `bin/rails test`. Expected: PASS, no new warnings.
- [ ] **Step 5: Commit** `Server-tracked sessions replace session[:user_id]`.

### Task 3: Renewal on `/user_list_state`

**Files:**
- Modify: `web-app/app/controllers/concerns/session_authentication.rb`, `web-app/app/controllers/user_list_state_controller.rb:30,59-69` (replace `ensure_uid_cookie`), `web-app/test/controllers/user_list_state_controller_test.rb:108-114`, `web-app/test/controllers/session_authentication_test.rb`

**Interfaces:**
- Produces: `renew_current_session -> void` in the concern. If `current_session.last_active_at < Time.current - Session::RENEW_AFTER`, update `last_active_at` and call `write_session_cookies`. Otherwise, if `cookies[TG_UID_COOKIE]` differs from the user id, call `write_session_cookies` (this is what `ensure_uid_cookie` did). Never touches `created_at`.

- [ ] **Step 1: Write failing tests:**
  - `"user_list_state renews a session last active more than a day ago"`: travel 2 days, fetch, `last_active_at` moved, `Set-Cookie` contains `tg_session` and `tg_uid` with a fresh 90-day expiry.
  - `"user_list_state does not renew a session active within the last day"`: fetch twice within an hour; `last_active_at` unchanged and no `tg_session` in the second response's `Set-Cookie`.
  - `"renewal never extends past the one-year hard limit"`: sign in; loop travelling 80 days and fetching until past 1 year; each response's cookie `expires` ≤ `created_at + 1.year`; after 1 year + 1 day the fetch is 401.
  - Keep the existing backfill test (line 108) passing unchanged.
- [ ] **Step 2: Run** the two test files. Expected: FAIL.
- [ ] **Step 3: Implement** `renew_current_session`; call it in `UserListStateController#show` where `ensure_uid_cookie` was; delete `ensure_uid_cookie`.
- [ ] **Step 4: Run** `bin/rails test test/controllers/`. Expected: PASS.
- [ ] **Step 5: Commit** `Renew sessions from /user_list_state, capped at one year`.

### Task 4: Remove `data-signed-in` from cached layouts

**Files:**
- Modify: `web-app/app/views/layouts/music/application.html.erb:54`, `web-app/app/views/layouts/games/application.html.erb:38`, `web-app/app/views/layouts/movies/application.html.erb:16`

- [ ] **Step 1:** Confirm nothing reads it: `grep -rn "signedIn\|signed-in\|dataset.signed" app/javascript` finds no consumer of `body.dataset.signedIn`.
- [ ] **Step 2:** Remove the `data-signed-in="<%= signed_in? %>"` attribute from the three `<body>` tags.
- [ ] **Step 3: Run** `bin/rails test`. Expected: PASS.
- [ ] **Step 4: Commit** `Drop the per-visitor data-signed-in byte from cached layouts`.

### Task 5: The sign-in widget renders from `tg_uid`; Firebase only signs in and out

**Files:**
- Create: `web-app/app/javascript/services/session_cookie.js`
- Modify: `web-app/app/javascript/controllers/authentication_controller.js`, `web-app/app/javascript/services/firebase_loader.js`, `web-app/app/components/authentication/widget_component/widget_component.html.erb:134` (remove the `userInfo` block)
- Test: covered by Task 6's E2E plus the existing `test/lint/auth_provider_registry_test.rb`, which must keep passing (`signInWithOauth` still calls `markPendingRedirect()`/`clearPendingRedirect()`).

**Interfaces:**
- Produces in `session_cookie.js`: `export function signedInUid() -> string | null` (reads `tg_uid` from `document.cookie`); `export function clearUidCookie() -> void` (same string `user_list_state_controller.js#_clearCookieUid` writes).
- Produces in `firebase_loader.js`: `markPendingVerification()`, `clearPendingVerification()`, `pendingVerification() -> boolean`, localStorage key `"tg:auth:pending-verification"`, try/catch like the existing helpers. Remove `likelySignedIn`, `markSignedIn`, `clearSignedInHint` and `SIGNED_IN_KEY` (no other callers; `grep -rn` to confirm).
- Produces in `authentication_controller.js`: `renderSignInState()` (reads `signedInUid()`; shows sign-in or sign-out controls and calls `updateNavbarButton(signedIn: boolean)`, which keeps writing `data-auth-state`).
- Consumes: the window events `auth:success`, `auth:error`, `auth:signout`, `user-list-state:cleared`.

Behaviour, in place of the current Firebase-driven rendering:

- [ ] **Step 1: `connect()`** calls `renderSignInState()`. Firebase loads eagerly only if `pendingRedirect() || pendingVerification()`; otherwise only when the modal opens (existing observer) or at sign-out. If `pendingVerification()`, show `verificationMessage`.
- [ ] **Step 2: `handleAuthStateChange(user)`** no longer renders. Keep the pending-redirect clearing exactly as it is (same replay guard). If it's a real notification with `user` null, `clearPendingVerification()`. If `user` and `!signedInUid()` and not `this.signInInFlight` and not `pendingRedirect()` and not `pendingVerification()`, sign Firebase out quietly (`firebaseAuthService.signOut()`, caught and logged).
- [ ] **Step 3: In-flight guard.** Set `this.signInInFlight = true` at the start of `signInWithOauth` and `submitEmailForm`; clear it in `handleAuthSuccess`, `handleAuthError`, and their own `catch` paths.
- [ ] **Step 4: `handleAuthSuccess`** calls `renderSignInState()` before the existing close/reload. **`handleAuthError`**: the `email_verification_required` branch calls `markPendingVerification()` (and drops `clearSignedInHint`); `account_lookup_failed` keeps its Firebase sign-out. Listen for `user-list-state:cleared`: `renderSignInState()`, and if Firebase is already loaded and has a user, sign it out quietly.
- [ ] **Step 5: `signOut()`**: POST `/auth/sign_out` **first** (unchanged request shape); on success `clearUidCookie()` defensively, `clearPendingVerification()`, then the existing best-effort Firebase load + sign-out, then dispatch `auth:signout` and `renderSignInState()`. A Firebase failure must not show an error once Rails succeeded.
- [ ] **Step 6:** Delete `showAuthenticatedState(user)`, `buildUserInfo`, the `userInfo` target and `currentUser` value, and the `getCurrentUser`/`isAuthenticated` helpers at the bottom if nothing calls them (`grep -rn` first; `firebase_auth_service.js` has its own, which stay). Fix comments that still say `tg_uid` is a session cookie.
- [ ] **Step 7: Build and run** `yarn build:all` then `bin/rails test test/lint/`. Expected: build succeeds, PASS.
- [ ] **Step 8: Commit** `Sign-in widget renders from tg_uid; Firebase only signs in and out`.

### Task 6: E2E on books, music and games

**Files:**
- Modify: `web-app/e2e/support/sign-in.ts:17-45` (wait for `tg_uid` **and** `tg_session`; update the comment)
- Create: `web-app/e2e/support/sign-in-state.ts`, `web-app/e2e/tests/books/auth/sign-in-state.spec.ts`, `web-app/e2e/tests/music/auth/sign-in-state.spec.ts`, `web-app/e2e/tests/games/auth/sign-in-state.spec.ts`
- Modify as needed: `web-app/e2e/tests/books/firebase-lazy-load.spec.ts`, `web-app/e2e/tests/music/auth/{login,logout}.spec.ts`, `web-app/e2e/tests/books/email-auth.spec.ts`, `web-app/e2e/tests/books/oauth-providers.spec.ts`

**Interfaces:**
- Produces in `sign-in-state.ts`: `expectSignedIn(page)` / `expectSignedOut(page)`. Each asserts `#navbar_login_button` has `data-auth-state` `signed-in`/`signed-out`, **and** the signed-in nav links (books `#navbar_my_books`, music/games `#navbar_my_lists`) are visible/hidden. `firebaseUserCount(page) -> Promise<number>` counts records in IndexedDB `firebaseLocalStorageDb` → store `firebaseLocalStorage`.
- Each domain spec uses `test.use({ storageState: { cookies: [], origins: [] } })` (Firebase's IndexedDB is not in storage state) and `credentials('ADMIN')` on music/games, `credentials('USER')` on books.

- [ ] **Step 1: Write the four tests** in each domain spec:
  - `"every indicator agrees after sign in and reload"`: `signIn`, `page.goto('/')`, `expectSignedIn`; then `page.goto('/my/lists')` (global route, signed-in only) and assert the response status is 200 and the URL is still `/my/lists` (signed-out visitors are redirected).
  - `"sign out flips every indicator and the old session cookie is rejected"`: capture the `tg_session` cookie, click Logout, `expectSignedOut`; `context.addCookies([old])`; `page.request.get('/user_list_state', { headers: { Accept: 'application/json' } })` → 401.
  - `"Firebase forgetting the user leaves the visitor signed in"`: `signIn`; `page.evaluate(() => indexedDB.deleteDatabase('firebaseLocalStorageDb'))`; reload; `expectSignedIn`.
  - `"the server forgetting the user signs the browser out everywhere"`: `signIn`; `context.clearCookies({ name: 'tg_session' })`; reload; `expectSignedOut` (after `/user_list_state` 401s); open the login modal; `expect.poll(() => firebaseUserCount(page)).toBe(0)`.
- [ ] **Step 2: Confirm port 3000 is this worktree's** with the `ss`/`readlink` check from AGENTS.md; if another checkout holds it, stop and tell Shane. Then `yarn build:all`, `bin/rails server`, and `yarn test:e2e`. Expected: the new specs pass on all three domains, and the existing auth specs pass or were updated deliberately (the lazy-load spec's "signed-in reader loads Firebase eagerly" case, if any, now expects the opposite).
- [ ] **Step 3: Commit** `E2E: sign-in state agrees on books, music and games`.

### Task 7: Documentation

**Files:**
- Modify: `docs/features/authentication.md`

- [ ] **Step 1:** Describe the model: Rails session is truth (`sessions` table, `tg_session`), `tg_uid` mirrors it for JS and is never trusted, lifetimes (90 days idle, 1 year hard, renewal via `/user_list_state` at most daily), Firebase's role (sign in, sign out, redirect and verification flows only), the no-`Set-Cookie`-on-cacheable rule, and that logout ends only this browser. Remove anything describing `session[:user_id]` or the localStorage signed-in hint.
- [ ] **Step 2: Run** `bin/rails test` and `bundle exec standardrb`. Expected: PASS, no new warnings.
- [ ] **Step 3: Commit** `Document server-tracked sessions`.
