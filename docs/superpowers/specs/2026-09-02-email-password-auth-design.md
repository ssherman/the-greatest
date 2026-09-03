# Email/Password Authentication: Hardening and Legacy V1 Migration

**Date:** 2026-09-02
**Status:** Approved, ready for implementation planning
**Branch:** `worktree-email-password-auth`

## Summary

Email/password authentication already works in the new app. This project does two things
it does not do: it closes three live vulnerabilities in the shared sign-in path, and it
brings 30,463 users from the v1 Devise era into Firebase with their existing passwords
intact.

The work ships as two pull requests. PR 1 is a self-contained security fix that merges
and deploys on its own. PR 2 is the migration, built on the hardened base.

## Context

### What already exists (do not rebuild)

Email/password auth is implemented and in daily use — the Playwright admin setup at
`web-app/e2e/auth/books-auth.setup.ts:12-24` signs in with it on every run. The
following are done and stay:

| Piece | Location |
|---|---|
| Two-step email → password UI, sign-up toggle, forgot-password, resend-verification | `app/components/authentication/widget_component/widget_component.html.erb` |
| Stimulus controller driving that UI, lazy Firebase bundle load | `app/javascript/controllers/authentication_controller.js` |
| Firebase email/password calls | `app/javascript/services/auth_providers/email_provider.js` |
| JWT → session exchange | `app/controllers/auth_controller.rb` |
| JWT signature validation | `app/lib/services/jwt_validation_service.rb` |
| Find-or-create user | `app/lib/services/user_authentication_service.rb` |

The widget renders in every domain layout, `users` is a global (non-namespaced) model,
and all domains share one Firebase project. Cross-domain sign-in therefore already works
architecturally: an old books user signing in on `thegreatest.games` reaches the same
`/auth/sign_in` and lands on the same row.

### The repository is public

`ssherman/the-greatest` is a public repository. Every defect below is readable on GitHub
today, and the Firebase web API key is in the source (correctly — web API keys are public
by design, but it tells an attacker exactly which project to create an account in). Every
guarantee in this design must be structural. Nothing may rely on an attacker not knowing
how the code works.

## Findings

### F1 — The audience check is dead code (live, music and games)

`Services::JwtValidationService.call(token, project_id: nil)` only validates `aud` when
`project_id` is truthy (`app/lib/services/jwt_validation_service.rb:17`). `AuthController`
never passes one. There is no `iss` check at all.

**Impact:** a token minted by any Firebase project on earth validates. An attacker creates
a free project, signs up as any email, and presents that token. The `nil` default is the
defect — the check itself is correct and simply never runs.

### F2 — The email is taken from the client (live, music and games)

`Services::AuthenticationService.extract_provider_data` prefers
`user_data["providerData"][…]["email"]` — raw, unsigned `params` — over the JWT's own
`email` claim. `Services::UserAuthenticationService` then does
`User.find_by("LOWER(email) = ?", email.downcase)` and calls `update!` on whatever it
finds, reassigning `auth_uid` and `external_provider`.

**Impact:** an attacker holding a valid token for their own account posts
`user_data: {providerData: [{providerId: "password", email: "victim@example.com"}]}` and
takes over the victim's account. `params[:provider]` is client-supplied too and is written
straight to `user.external_provider`.

This is the same class of bug the owner remembered from the legacy site, alive in the new
one by a different route.

### F3 — No session reset on sign-in or sign-out (live, music and games)

`AuthController#sign_in` assigns `session[:user_id]` without `reset_session`; `#sign_out`
nils the keys without one either. Session fixation on both ends.

### F4 — Google's certificates are fetched on every sign-in

`JwtValidationService.fetch_google_cert` issues a synchronous `Faraday.get` per
authentication. This makes Google an availability dependency of every login and adds a
round trip to each one. The response's `Cache-Control: max-age` is ignored.

### F5 — Identity payloads are logged at info level

`AuthenticationService` writes `"JWT Payload: #{payload.inspect}"` and
`"User Data: #{user_data.inspect}"` to production logs — full identity payloads including
email addresses.

### F6 — `original_signup_domain` is never written

`app/views/admin/users/show.html.erb:142` displays it and fixtures set it, but no code
path assigns it. A dead column.

### F7 — Reset and verification emails ignore the calling domain

`email_provider.js` calls `sendPasswordResetEmail(auth, email)` and
`sendEmailVerification(result.user)` with no `actionCodeSettings`, so Firebase uses the
project-wide default action URL. A games user who resets their password is emailed a link
that lands on books.

### F8 — Legacy app: `alg: "none"` is accepted (live, **out of scope by decision**)

The legacy books app computes `validate_firebase_data` and then discards the result unless
the caller is *already* signed in, which the sign-in path never is. It then passes the
attacker-controlled `alg` header straight into `JWT.decode`. Verified empirically against
its own bundle (ruby-jwt 3.1.2):

```
ATTACK 1  (HS256, PKey object key): blocked -> JWT::DecodeError: HMAC key expected to be a String
ATTACK 2  (alg=none):               SUCCEEDED -> victim@example.com
```

RS256→HS256 confusion is blocked by the gem, but `alg: "none"` with any real Google `kid`
(both public) yields unauthenticated takeover of any account on the live production site.
The owner has decided to leave this: `thegreatestbooks.org` is being retired. Recorded
here so the decision is deliberate and traceable.

## Data

Measured against the development database on 2026-09-02. The books data exists only in
development; production does not yet hold these rows.

**New `users` table — 69,495 rows**

| Cohort | Count | Notes |
|---|---:|---|
| Has an email | 49,432 | |
| — V1 Devise cohort (unmigrated, no provider) | 30,463 | holds 1,392,939 list items |
| — Already in Firebase (`legacy_migrated`) | 18,932 | |
| — Residual: email, no Firebase identity | 37 | 24 google, 13 password; 12 with list data |
| No email at all | 20,063 | 17,531 facebook, 2,516 twitter, 12 apple, 4 nil |

The V1 cohort has **zero** sign-ins in the last two years; every row has signed in at some
point. Accounts span 2014-07-01 to 2023-12-29. There are no admin or editor rows in it.

The no-email cohort holds 527,441 list items across 14,668 users but has 16 sign-ins in two
years, zero reviews and zero memberships. It is unreachable by any email flow and — having
no email to match on — is not hijackable through one either.

33 email addresses are duplicated case-insensitively across 69 rows.

**Legacy password hashes**

All 30,463 V1 hashes conform to the exact bcrypt grammar
`^\$2a\$10\$[./A-Za-z0-9]{53}$` — 30,463 of 30,463, with 30,463 distinct salts. A 2,000-row
sample found zero malformed values.

The hashes carry no pepper. 520 legacy users hold *both* a v1 bcrypt hash and a completed
password migration, a state reachable only through legacy's
`DeviseEncrypt.compare` → `BCrypt::Engine.hash_secret(password, salt)`, which applies no
pepper. Those migrations run from 2025-02-10 to 2026-07-03. Had a pepper existed, that
comparison could never have matched anyone and the count would be zero.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Bulk-import bcrypt hashes into Firebase | Users sign in with the password they already have. No bespoke migration endpoint exists to be attacked. |
| D2 | Security fix ships first, as its own PR | Three defects are live and publicly readable. Keeps the security diff reviewable. |
| D3 | Identity is the Firebase uid, pre-seeded at import | The value matched comes from a signed token, not a text field anyone can type. |
| D4 | Import runs locally via `firebase-tools` | No service-account credential enters the app or the deployed environment for a one-time job. |
| D5 | Legacy app's `alg: "none"` hole left unfixed | Site is being retired; see F8. |
| D6 | No-email cohort out of scope | Unreachable without implementing Facebook/Twitter login. |

**Firebase cost:** billing is on monthly active users, not stored accounts. Importing
30,463 dormant records costs nothing. Classic Firebase Authentication is unlimited at no
cost for email/password; Identity Platform's free tier is 50,000 MAU. Confirm the project's
tier in the console before the run.

## Design — PR 1: harden `/auth/sign_in`

### JwtValidationService

- `project_id` becomes a **required** keyword argument with no default, sourced from a
  `FIREBASE_PROJECT_ID` environment variable. Removing the default is the fix; a required
  argument makes the check structurally impossible to skip, which matters more than the
  check's contents. (F1)
- Validate `iss == "https://securetoken.google.com/#{project_id}"`. (F1)
- Validate `sub` is present and non-empty.
- Keep `RS256` hardcoded — never read the algorithm from the token header.
- Cache the Google certificate bundle honouring its `Cache-Control: max-age`. (F4)

### AuthenticationService

- Source `email`, `email_verified`, `name` and `picture` from the verified payload only.
  Delete the `user_data` path entirely. (F2)
- Source the provider from `payload["firebase"]["sign_in_provider"]`, not `params[:provider]`. (F2)
- Delete both identity-payload log lines. (F5)
- The frontend stops sending `user_data`, which now carries nothing authoritative.

### AuthController

- `reset_session` before establishing the session, and again on sign-out. (F3)
- `rate_limit` on `sign_in` and `check_provider`, using the existing
  `Rails.application.config.x.rate_limit_store` pattern from `corrections_controller.rb:63`.
  `check_provider` is unauthenticated and confirms whether an address has an account.

### Tests

`test/controllers/auth_controller_test.rb` currently stubs `Services::AuthenticationService.call`
wholesale and so asserts nothing about any of the above. Add tests that build real signed
JWTs against a locally generated key and assert each attack is refused:

- wrong `aud`; wrong `iss`; `alg: "none"`; expired; unknown `kid`
- a client-supplied `user_data` email naming another user's row leaves that row untouched
- the session id changes across sign-in and across sign-out

Every test carries mutation evidence: revert the fix, watch it go red.

## Design — PR 2: V1 cohort migration

### Export

A rake task reads `LegacyBooks::User` for the cohort — unmigrated, no `external_provider`,
email present, hash present — and writes Firebase's import JSON.

- Each record gets a **deterministic** `localId` of `tgbv1-<legacy_id>`. Determinism is
  load-bearing: export and write-back derive the same uid independently and cannot drift,
  re-running changes nothing, and dev and production produce identical results with no file
  shipped between them.
- This only works because `Services::BooksMigration::UserMigrator` preserves ids
  (`unique_by :id`), so `LegacyBooks::User#id` and `User#id` are the same integer for the
  same person. The export derives the uid from the legacy row and the write-back derives it
  from the new row; they agree because of that invariant. The write-back task must assert it
  — a cohort row whose new-table counterpart is missing or mismatched is a hard failure, not
  a skip.
- Assert every hash matches `^\$2a\$10\$[./A-Za-z0-9]{53}$` before including it. Reject and
  report anything that does not.
- Normalise emails (strip, downcase) and validate format. A malformed address would occupy
  a Firebase account the user could never claim.
- Resolve the 33 duplicate addresses: keep the row with the most recent `last_sign_in_at`,
  skip and log the others.
- **Refuse to write output anywhere inside the repository working tree.** The file is
  30,463 password hashes and the repository is public. Add a gitignore entry as a second
  line of defence.

### Import

Run locally by the owner:

```
npx firebase-tools auth:import <file> --hash-algo=BCRYPT --project the-greatest-books
```

No service account enters the app or the deployed environment.

### Write-back

A second rake task sets `users.auth_uid = "tgbv1-<id>"` for the same cohort. It recomputes
rather than reading the export file, so it is idempotent and environment-independent.
Run against development now; production picks it up whenever phase 4 of the data migration
runs, with no coordination required.

### The linking rule

`UserAuthenticationService` is rewritten around this. It is the piece that makes the
original vulnerability structurally impossible:

```
1. auth_uid == payload["sub"]        → that user. Exact, from a signed token.
2. elsif payload["email_verified"]   → match LOWER(email):
     - found                         → link this uid to that row
     - none                          → create
3. elsif an email match exists       → refuse: "verify your email, then sign in again"
4. else                              → create
```

Step 2 links rather than refuses on a uid mismatch. A verified email *is* proof of control
of that address, and refusing would lock out the person the rule protects: a V1 user
imported as `tgbv1-123` who later signs in with Google presents a different `sub`, misses
step 1, and must be allowed to reach her own data through step 2.

Step 3 is the original bug inverted. Today an unverified Firebase signup for
`victim@example.com` silently claims the victim's row. Here it cannot link, cannot create a
second row (the uniqueness validation would reject it), and is told to verify.

On user creation, populate `original_signup_domain` from `request.host`. (F6)

### Coverage after the import

Of 49,432 users with an email, 49,395 will hold a Firebase identity. The remaining 37 are
covered by the rule: a Google sign-in carries `email_verified: true` and links through step
2; an unverified password signup cannot.

### Recovery paths

Two failure modes, both already recovering:

- **Imported, hash rejected at sign-in.** The Firebase account exists, so "Forgot password"
  works. They set a new password, sign in, and because `auth_uid` was pre-seeded, step 1
  matches immediately. Data intact.
- **Never imported** (the 37, plus any row the import errors on). No Firebase account
  exists, so `sendPasswordResetEmail` fails `auth/user-not-found` and the UI's deliberately
  vague "if an account exists…" message hides it. These users recover through **Create
  account**: they set a password, Firebase sends a verification email, they click it, and
  step 2 links them to their existing row with everything on it. This requires no service
  account and no new endpoint.

To steer them there without adding an endpoint that confirms an address has an account —
a clean enumeration oracle against a public repository — change the failed-sign-in message,
shown identically to everyone, to:

> Invalid email or password. If you had an account on the old site and haven't set a
> password here yet, choose Create account with this address.

### Cross-domain

Pass domain-aware `actionCodeSettings` to `sendPasswordResetEmail` and
`sendEmailVerification`, derived from the current hostname, so a games user's reset link
lands on games. (F7) Every domain used there must be on Firebase's authorized-domains list.

Firebase's email templates are per-project and cannot vary by domain; make them
brand-neutral ("The Greatest") in the console.

## Testing

**Rails.** `JwtValidationService` against real signed JWTs for every rejection case above.
`UserAuthenticationService` gets one test per branch of the linking rule, with the
unverified-collision case asserting that no row is created **and** no row is modified.
Export and write-back get tests on determinism (same input twice → identical uids), on
malformed-hash rejection, and on duplicate-email resolution. Mutation evidence on every one.

**E2E.** A Playwright spec covering sign-in, wrong password, and the OAuth-conflict message.
Not sign-up — real signups would litter the shared Firebase project with junk accounts.

**Canary before the bulk import.** Generate a bcrypt hash from a chosen password, attach it
to a plus-address not present in Firebase, import that single record, and sign in.

An ancient hash cannot be tested directly: doing so requires the plaintext, and nobody
remembers a 2014 password — true for all 30,463, so this is not a gap specific to any one
account. It does not matter. Devise produced those hashes with
`BCrypt::Password.create(password, cost: 10)`, byte-for-byte the same construction as one
generated today; a 2014 hash and a fresh one are the same 60-byte structure with different
random bytes. The synthetic canary exercises exactly the code path Firebase will run
against the ancient hashes. The one thing it cannot rule out — that some of the 30,463 are
subtly corrupted — is closed by the whole-cohort grammar assertion.

Below all of it sits a floor: any user whose hash fails clicks "Forgot password" and gets a
Firebase reset that works regardless. The import can only improve a user's position.

## Rollout

1. PR 1 merges and deploys. Confirm music and games sign-in still works.
2. Confirm the Firebase project's billing tier in the console.
3. Confirm **"one account per email address"** is enabled. If Firebase allows multiple
   accounts per address, a second identity can exist for one email and step 2 weakens.
4. Add every domain to Firebase's authorized-domains list.
5. Make the Firebase email templates brand-neutral.
6. Run the canary import; verify sign-in on `dev-new.thegreatestbooks.org`.
7. Run the full 30,463-record import. Export a sample back and diff to confirm nothing was
   mangled at scale.
8. Run the write-back against development.
9. PR 2 merges and deploys.

## Out of scope

- The 20,063 users with no email address (D6).
- Facebook, Twitter and Apple login.
- The legacy app's `alg: "none"` vulnerability (D5, F8).
- Any tuning UI. Configuration goes in Rails config and environment variables.

## Open items

- The exact encoding `--hash-algo=BCRYPT` expects for `passwordHash` (base64 form) is
  confirmed by the canary, not by this document.
- Whether "one account per email address" is currently enabled is a console setting the
  repository cannot observe. Step 3 of rollout resolves it.
