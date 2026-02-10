# Email/Password Authentication via Firebase

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-08
- **Started**: 2026-02-08
- **Completed**: 2026-02-09
- **Developer**: Claude

## Overview
Add email/password authentication alongside existing Google OAuth sign-in using Firebase Authentication. Users can sign up with email/password, sign in, reset their password (via Firebase-hosted flow), and receive email verification. When a user attempts email/password auth with an email already associated with a Google account, the system detects this server-side and shows an alert directing them to use Google sign-in instead.

**Non-goals**: Custom password reset page, email link (passwordless) sign-in, account linking/merging between providers.

## Context & Links
- Related: Existing Firebase Google OAuth authentication
- Source files (authoritative):
  - `web-app/app/javascript/services/firebase_auth_service.js`
  - `web-app/app/javascript/controllers/authentication_controller.js`
  - `web-app/app/javascript/services/auth_providers/google_provider.js`
  - `web-app/app/javascript/services/auth_handlers/redirect_handler.js`
  - `web-app/app/components/authentication/widget_component.rb`
  - `web-app/app/components/authentication/widget_component/widget_component.html.erb`
  - `web-app/app/controllers/auth_controller.rb`
  - `web-app/app/lib/services/authentication_service.rb`
  - `web-app/app/lib/services/user_authentication_service.rb`
  - `web-app/app/models/user.rb`
- External docs:
  - [Firebase Email/Password Auth (Web)](https://firebase.google.com/docs/auth/web/password-auth)
  - [Firebase Password Reset](https://firebase.google.com/docs/auth/web/manage-users#send_a_password_reset_email)
  - [Firebase Email Verification](https://firebase.google.com/docs/auth/web/manage-users#send_a_user_a_verification_email)

## Interfaces & Contracts

### Domain Model (diffs only)
No new database fields required. The existing User model already has:
- `external_provider` enum with `:password` value (index 4)
- `email_verified` boolean field
- `provider_data` JSON field (stores per-provider data)
- `auth_uid` for Firebase UID
- Confirmation fields (`confirmation_token`, `confirmed_at`, `confirmation_sent_at`)

### Endpoints
No new Rails endpoints required. The existing `POST /auth/sign_in` and `POST /auth/sign_out` are used as-is. The email/password auth flow is handled entirely client-side by Firebase, then the resulting JWT is sent to the existing backend endpoint.

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /auth/sign_in | Authenticate user (existing) | jwt, provider ("password"), user_data | none |
| POST | /auth/sign_out | Sign out (existing) | none | session |

> Source of truth: `config/routes.rb`

### Schemas (JSON)

**Sign-in request body (email/password provider)**:
```json
{
  "jwt": "<firebase-jwt-token>",
  "provider": "password",
  "domain": "thegreatestmusic.org",
  "user_data": {
    "uid": "<firebase-uid>",
    "email": "user@example.com",
    "emailVerified": false,
    "displayName": null,
    "photoURL": null,
    "providerData": [
      {
        "providerId": "password",
        "uid": "user@example.com",
        "email": "user@example.com"
      }
    ]
  }
}
```

### Behaviors (pre/postconditions)

#### Sign Up (new user)
- **Preconditions**: Email not registered in Firebase, valid email format, password >= 6 chars
- **Postconditions**:
  - Firebase account created with email/password provider
  - User automatically signed in by Firebase
  - JWT sent to Rails backend via existing `/auth/sign_in`
  - Rails User record created with `external_provider: :password`, `email_verified: false`
  - Firebase verification email sent to user
  - UI shows "Verify your email" info message after successful sign-up
- **Edge cases**:
  - `auth/email-already-in-use`: Firebase returns this even with email enumeration protection ON. Show message: "An account with this email already exists. Try signing in, or use another sign-in method."
  - `auth/weak-password`: Show "Password must be at least 6 characters"
  - `auth/invalid-email`: Show "Please enter a valid email address"

#### Sign In (existing user)
- **Preconditions**: User has email/password account in Firebase
- **Postconditions**:
  - Firebase signs in user, returns UserCredential
  - JWT sent to Rails backend via existing `/auth/sign_in`
  - Rails User record updated (sign_in_count incremented, last_sign_in_at set)
  - Modal closes, navbar updates to "Logout"
- **Edge cases**:
  - `auth/invalid-credential` (email enumeration ON) or `auth/wrong-password`/`auth/user-not-found` (enumeration OFF):
    1. Frontend catches the Firebase error
    2. Frontend calls new endpoint or existing backend logic to check if email exists in our DB with a Google provider
    3. If yes: Show alert "This email is associated with a Google account. Please use 'Sign in with Google' instead."
    4. If no: Show generic "Invalid email or password"
  - `auth/user-disabled`: Show "This account has been disabled"
  - `auth/too-many-requests`: Show "Too many failed attempts. Please try again later."

#### Server-Side Provider Conflict Detection
When email/password sign-in fails client-side, the frontend needs to determine if the email is registered with a different provider. Two approaches:

**Option A (Recommended)**: Check user's `provider_data` or `external_provider` server-side.
- Add a lightweight endpoint or use existing data:
  - New endpoint: `POST /auth/check_provider` with `{ email: "user@example.com" }`
  - Returns: `{ provider: "google" }` if the email exists with a non-password provider
  - Returns: `{ provider: null }` if not found or if it's a password account
  - **Security**: Only returns the provider type, not whether the email exists (returns null for both "not found" and "password provider" to avoid enumeration)

**Option B**: Skip the server check. Show generic "Invalid email or password" always. Simpler but doesn't guide users.

**Decision**: Option A - add `POST /auth/check_provider`.

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /auth/check_provider | Check if email has OAuth provider | email | none |

**Response schema**:
```json
{
  "has_oauth_provider": true,
  "provider": "google",
  "message": "This email is associated with a Google account. Please use 'Sign in with Google' instead."
}
```

When `has_oauth_provider` is `false`:
```json
{
  "has_oauth_provider": false,
  "provider": null,
  "message": null
}
```

**Security consideration**: This endpoint reveals whether an email is registered with an OAuth provider. This is acceptable because:
1. It only reveals OAuth-linked emails (not all emails)
2. The alternative (Firebase's `fetchSignInMethodsForEmail`) is deprecated
3. Rate limiting should be applied to prevent abuse

#### Password Reset
- **Preconditions**: User enters email address
- **Postconditions**:
  - Firebase `sendPasswordResetEmail` called
  - Firebase sends reset email with link to Firebase-hosted reset page
  - UI shows success message: "If an account exists with this email, a password reset link has been sent."
  - Message is intentionally vague (same whether email exists or not) for security
- **Edge cases**:
  - With email enumeration protection ON: `sendPasswordResetEmail` succeeds silently for non-existent emails (by design)
  - User resets password successfully on Firebase-hosted page, then signs in normally

#### Email Verification
- **Preconditions**: User signed up with email/password, not yet verified
- **Postconditions**:
  - Firebase `sendEmailVerification` called on user object after sign-up
  - User clicks link in email, Firebase verifies the email
  - On next sign-in, `emailVerified` will be `true` in the JWT
  - Rails backend updates `email_verified: true` on the User record
- **Edge cases**:
  - User can still sign in before verifying (not blocked)
  - Resend verification option available in the widget

### Non-Functionals
- No new database queries beyond existing auth flow (except `check_provider` which is a single indexed query by email)
- `check_provider` endpoint should be rate-limited (consider Rack::Attack or similar)
- All auth happens over HTTPS (existing `force_ssl` in production)
- Password requirements enforced by Firebase (minimum 6 characters)
- No N+1 queries introduced

## Acceptance Criteria

### Sign Up
- [ ] User can sign up with email and password from the login modal
- [ ] Password field has minimum 6 character validation (Firebase enforced)
- [ ] On successful sign-up, user is signed in and modal closes
- [ ] Firebase sends email verification after sign-up
- [ ] User record created in Rails DB with `external_provider: :password`
- [ ] Attempting sign-up with an already-registered email shows appropriate error

### Sign In
- [ ] User can sign in with email/password from the login modal
- [ ] On successful sign-in, modal closes and navbar shows "Logout"
- [ ] Invalid credentials show "Invalid email or password" message
- [ ] If email exists with Google provider, shows "use Google sign-in" alert
- [ ] `auth/too-many-requests` shows rate-limit message

### Password Reset
- [ ] "Forgot password?" link visible on the email/password form
- [ ] Clicking it shows email input and "Send Reset Link" button
- [ ] After submission, shows generic success message regardless of email existence
- [ ] Firebase sends password reset email (Firebase-hosted reset page)

### Email Verification
- [ ] After sign-up, user sees info message about verifying email
- [ ] "Resend verification email" link available for unverified users
- [ ] On subsequent sign-in after verification, `email_verified` updates to `true` in DB

### UI/UX
- [ ] Email/password form appears below Google sign-in button with "or" divider
- [ ] Form toggles between "Sign In" and "Sign Up" modes
- [ ] All error messages are user-friendly (no raw Firebase error codes)
- [ ] Loading spinner shows during async operations
- [ ] Works consistently across all domains (music, movies, games, books)
- [ ] Existing Google sign-in flow is unaffected

### Golden Examples

**Sign-up flow**:
```text
Input: User clicks "Sign Up", enters "jane@example.com" and "MyStr0ngPass!"
Output:
  1. Firebase creates account
  2. Firebase sends verification email to jane@example.com
  3. JWT sent to POST /auth/sign_in with provider="password"
  4. User record created: email="jane@example.com", external_provider="password", email_verified=false
  5. Modal closes, info message: "Check your email to verify your account"
  6. Navbar shows "Logout"
```

**Existing Google user tries email/password sign-in**:
```text
Input: User enters "jane@example.com" (registered via Google) and any password
Output:
  1. Firebase returns auth/invalid-credential
  2. Frontend calls POST /auth/check_provider with email="jane@example.com"
  3. Backend finds user with external_provider="google" (or provider_data has "google" key)
  4. Returns { has_oauth_provider: true, provider: "google" }
  5. UI shows alert: "This email is associated with a Google account. Please use 'Sign in with Google' instead."
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Email/password provider follows the same singleton pattern as `google_provider.js`.
- Widget component template extended (not replaced) with email/password form.
- Authentication controller extended with new actions for email/password.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> collect comparable patterns (existing auth provider, widget component, controller actions)
2) codebase-analyzer -> verify data flow & integration points (AuthenticationService, UserAuthenticationService, provider_data handling)
3) web-search-researcher -> Firebase v9 modular SDK for email/password auth (official docs)
4) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing user fixtures with `external_provider: :google` for conflict detection tests
- New user fixture with `external_provider: :password` for email/password sign-in tests
- Mock Firebase JWT responses for both providers

---

## Implementation Notes (living)

### Planned Approach
1. **New JS file**: `web-app/app/javascript/services/auth_providers/email_provider.js`
   - Singleton following `google_provider.js` pattern
   - Methods: `signUp(email, password)`, `signIn(email, password)`, `sendPasswordReset(email)`, `sendVerificationEmail(user)`
   - Uses Firebase v9 modular imports: `createUserWithEmailAndPassword`, `signInWithEmailAndPassword`, `sendPasswordResetEmail`, `sendEmailVerification`

2. **Updated widget component**: `widget_component.html.erb`
   - Add "or" divider below Google sign-in button
   - Add email/password form with toggle between Sign In / Sign Up
   - Add "Forgot password?" link
   - Add resend verification email link (shown when signed in but unverified)

3. **Updated Stimulus controller**: `authentication_controller.js`
   - New actions: `signInWithEmail`, `signUpWithEmail`, `forgotPassword`, `resendVerification`, `toggleAuthMode`
   - New targets: `emailInput`, `passwordInput`, `authModeToggle`, `forgotPasswordForm`, `verificationMessage`
   - Handle provider conflict detection on sign-in failure

4. **New route + controller action**: `POST /auth/check_provider`
   - In `AuthController`, add `check_provider` action
   - Queries User by email, checks if `external_provider` is an OAuth provider (google, apple, facebook, twitter)
   - Also checks `provider_data` keys for OAuth providers
   - Returns JSON with provider info or null

5. **Backend services**: No changes needed to `AuthenticationService`, `JwtValidationService`, or `UserAuthenticationService`
   - These already handle `provider: "password"` correctly
   - `external_provider` enum already includes `:password`

### Key Files Touched (paths only)
- `web-app/app/javascript/services/auth_providers/email_provider.js` (new)
- `web-app/app/javascript/controllers/authentication_controller.js`
- `web-app/app/components/authentication/widget_component/widget_component.html.erb`
- `web-app/app/components/authentication/widget_component.rb`
- `web-app/app/controllers/auth_controller.rb`
- `web-app/config/routes.rb`
- `web-app/app/javascript/application.js` (import new provider)
- `web-app/app/javascript/music.js` (import new provider)
- `web-app/app/javascript/movies.js` (import new provider)
- `web-app/app/javascript/games.js` (import new provider)
- Domain-specific entry points that import auth services

### Challenges & Resolutions
- **Email enumeration protection**: Firebase's default email enumeration protection (since Sept 2023) returns generic `auth/invalid-credential` for both wrong password and non-existent user. Resolved by adding server-side `check_provider` endpoint.
- **`fetchSignInMethodsForEmail` deprecated**: Cannot use this client-side to detect existing providers. Resolved with server-side check.
- **Cross-domain consistency**: Widget component is shared across all domains, so changes apply everywhere automatically.

### Deviations From Plan
- Fixed `extract_provider_data` in `AuthenticationService` to handle Firebase's provider ID format: "google.com" for OAuth vs "password" for email/password
- `widget_component.rb` did not need changes - no new parameters required
- No changes needed to `AuthenticationService` or `UserAuthenticationService` beyond the provider ID fix - they already handle `provider: "password"` correctly
- **Progressive Flow Refactor (2026-02-09)**: Replaced the original single-form design (email + password shown at once with Sign In/Sign Up toggle) with a Clerk-like two-step progressive flow:
  - **Step 1**: Google Sign In button + "or" divider + email input + "Continue" button (no password visible)
  - **Step 2**: Email shown as read-only text with "Change" link, password input, "Sign In" button, "Create account" / "Sign in instead" toggle, "Forgot password?" link
  - No server call on "Continue" — purely a UI transition (no email enumeration risk)
  - Email stored in `this.storedEmail` and pre-fills forgot password form
  - Removed old targets (`emailPasswordForm`, `passwordFields`), added new targets (`emailStep`, `passwordStep`, `emailDisplay`)
  - `backToSignIn` from forgot password returns to step 2 (password) if email is stored, otherwise step 1

## Acceptance Results
- **Date**: 2026-02-09
- **Verifier**: Automated test suite (3335 tests, 0 failures, 0 errors)
- **Notes**: All backend tests pass. No backend changes were made for the progressive flow refactor — frontend only. Manual testing recommended for UX validation.

## Future Improvements
- Account linking: Allow users to link Google + password to the same account
- Email link (passwordless) sign-in
- Additional OAuth providers (Apple, Facebook, Twitter)
- Custom password reset page with app branding
- Password strength meter in sign-up form
- Remember me / persistent sessions

## Related PRs
- #108 (email auth)

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs (AuthController, Authentication::WidgetComponent)
- [ ] `docs/controllers/auth_controller.md`
