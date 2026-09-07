# OAuth Provider Registry, and Sign In With X

**Date:** 2026-09-05
**Status:** Approved, ready for implementation planning
**Branch:** `worktree-facebook-login`

## Summary

Adding a social login to this app currently takes five edits across five files, four of
which are boilerplate. This design replaces that with one declarative config shared by
Ruby and JavaScript, so a new provider is a JSON entry plus an icon.

It then ships **Twitter/X** as the first provider on that registry, and fixes one thing
that would otherwise make every OAuth provider hostile: the account-linking guard refuses
to combine accounts unless the token carries `email_verified: true`, which X does not
send. Left alone, a returning X user with an existing account is told to go verify their
email — the exact behaviour this project set out to avoid.

Facebook was the original request. It is designed for but **not shipped here**: the Meta
app is disabled and can only run in development mode. It becomes a one-word config change
once that is resolved.

## Context

### What already exists (do not rebuild)

The Rails side is already provider-agnostic. Nothing below needs to change to accept a new
provider:

| Piece | Location |
|---|---|
| `facebook.com` / `twitter.com` / `apple.com` → provider mapping | `Services::AuthenticationService::PROVIDER_MAP` |
| `external_provider` enum with all five providers | `app/models/user.rb:76` |
| OAuth provider list for conflict messaging | `AuthController#check_provider` |
| Firebase OAuth redirect handler, per hostname | `Caddyfile:7` (dev), `deployment/nginx/the-greatest.conf.template` (prod, 4 server blocks) |
| Redirect-result handling, pending-redirect bookkeeping | `app/javascript/services/auth_handlers/redirect_handler.js`, `firebase_loader.js` |
| JWT validation, session exchange, find-or-create | `jwt_validation_service.rb`, `auth_controller.rb`, `user_authentication_service.rb` |

`email_provider.js` is also finished and stays untouched. It is a different shape from an
OAuth provider — no redirect, plus signup, password reset and verification — and pulling
it into the same abstraction would make both worse.

### What is not modular

Adding a provider today means:

1. a new singleton class in `app/javascript/services/auth_providers/`
2. a named export added to `window.__tgFirebase` in `entrypoints/firebase_auth.js`
3. a `signInWithX()` action in `authentication_controller.js` (already 688 lines)
4. a hand-written button with inline SVG in `widget_component.html.erb`
5. provider-specific error plumbing

Only (1)'s Firebase-class choice and (4)'s icon are genuinely per-provider. The rest is
copied.

### One Firebase project serves everything

`firebase_auth_service.js` hardcodes `projectId: "the-greatest-books"` and varies only
`authDomain`. The widget renders in all four domain layouts. Consequences that bear on
this design:

- A token minted on the **legacy** site validates against `/auth/sign_in` on the new app —
  same `aud`. Apple tokens can therefore already reach this code path even though the new
  app ships no Apple button.
- Anything enabled in Firebase is immediately reachable on **live** music and games,
  regardless of books' launch state.

See `one-firebase-project-serves-all-domains` and `social-login-is-the-next-feature`.

## Findings

### F1 — The linking guard asks the wrong question (blocks the whole feature)

`UserAuthenticationService#find_user` links a token to an existing account by email only
when `provider_data[:email_verified] == true`; otherwise it raises `UnverifiedEmailConflict`
and the user is shown "Please verify your email address, then sign in again."

The guard exists to stop a real attack: anyone can create a **Firebase password** account
for `victim@example.com` without proving control, and linking on that would be account
takeover. That reasoning is sound and must be preserved.

But it generalises wrongly to OAuth. The question that matters is not *"did the token say
verified"* — it is *"could someone have registered this address at this provider without
controlling it?"* For Google, Apple, Facebook and X the answer is no; the provider already
required ownership. X in particular verifies by confirmation mail but exposes no flag for
it, so Firebase passes `email_verified: false` for a fully verified address.

Left as-is, a returning X user whose email matches an existing account hits a verification
wall instead of their account. For the 70-of-73 X users who have an email, that is the
main path, not an edge case.

### F2 — No OAuth `email_verified` claim has ever been observed under the current code

The database appears to say Google is unverified for 14,081 of 14,096 users, which cannot
be true. The cause: the pre-hardening code read `email_verified` (snake_case) from a
client-supplied blob in which the JS sent `emailVerified` (camelCase), so the value was
`nil` → `false` for everyone, always.

PR #288 deployed 2026-09-03. The newest non-canary OAuth sign-in in this snapshot is
2026-08-29. **This snapshot therefore contains zero observations of any OAuth token under
the hardened pipeline**, Google included. Production may hold a few since the restore, but
nothing here can be read as evidence. The X claim must be measured during implementation,
not assumed. See D6.

### F3 — `validates :email, presence: true` refuses email-less OAuth accounts

3 of the 73 X users who reached Firebase have no email. Under the current model a
Firebase-era sign-in for such a user raises `ActiveRecord::RecordInvalid`, surfacing as
"Failed to create user account" — a dead end with no route forward.

The database already holds 20,063 nil-email rows; they migrated via `upsert_all`, which
bypasses validations. The validation and the data already disagree.

### F4 — The Meta app is disabled and cannot self-service recover

The Facebook app dashboard reports "disabled for violating the Meta Platform Terms and
Developer Policies… you can continue to use it in development mode." The appeal page
reports no restricted apps; the recovery page reports no recoverable apps. Development
mode restricts sign-in to people holding a role on the app, which matches the data
exactly: the owner can sign in, and no other Facebook user has since 2020-09-23.

**Do not delete the app.** Deletion is irreversible, breaks the one working Facebook login
(the owner's, and therefore the only test account), and forecloses any future
business-scoped ID mapping between the old app and a replacement.

### F5 — Facebook IDs are app-scoped; X IDs are global

Facebook has issued app-scoped IDs since Graph API v2.0 (2014), so a replacement Meta app
issues different IDs and `users.external_provider_uid` stops being a usable key for the
~4,800 Facebook rows that have no email anywhere.

X has always used one global numeric ID per account. **Verified against the data**: 49
groups of rows share an `external_provider_uid`, and the X ones pair a low-id V1 row
holding no email with a high-id Firebase-era row holding one — the same person, same X ID,
two accounts.

```
uid=201226493   ids={25155, 53129}   emails={—, willikito_sexy@hotmail.com}
uid=190231430   ids={1082,  58228}   emails={—, twitter@itaudit.co.za}
uid=2870369721  ids={12860, 39008}   emails={—, maciej.markowski@outlook.com}
uid=34363443    ids={435,   55211}   emails={—, pslim94@gmail.com}
uid=41763645    ids={44539, 56840}   emails={—, robert.seaton.sumner@gmail.com}
```

These people already returned, signed in with X, and silently got a duplicate account:
X supplied an email, the email branch matched nothing (the V1 row has none), and a new row
was created. Their V1 lists are orphaned in the old row.

### F6 — A uid match cannot take precedence over an email match

Tempting, and wrong. For the repository owner's own rows, the Facebook ID matches `42207`
(an empty V1 stub) while the email matches `1141` (the real account, 134 sign-ins).
Checking uid first signs him into the stub.

Where both match and they disagree, the correct resolution is a **merge**, not a lookup.
That is a data-migration problem with real blast radius and it is out of scope here (D7).

### F7 — Legacy emails exist, buried in `legacy_v1_data`

12,719 of the 20,049 no-email Facebook/Twitter rows carry a recoverable address at
`legacy_v1_data → provider_data.info.email`. The legacy app's `User.populate_auth_data`
was written to hoist exactly this into `users.email` and evidently never completed —
`external_provider_uid` is populated for all of them, but `email` is not.

This matters beyond social login: if one of those users returns via **Google** on that
address, `find_user`'s email branch would reconnect them — but only if the address is in
`users.email`. Today it is in a JSON blob, so they silently get a new empty account. Out
of scope here; recorded for the recovery spec (D7).

## Data

Measured against the development database (a recent production restore; the newest
migrated legacy row is 2026-09-03) on 2026-09-05.

### Provider populations

| provider | rows | reached Firebase (`auth_uid`) | with an email | last sign-in |
|---|---:|---:|---:|---|
| google | 14,096 | 14,096 | 14,096 | 2026-09-04 |
| password | 3,287 | 3,287 | 3,287 | 2026-09-05 |
| apple | 1,521 | 1,521 | 1,509 | 2026-09-03 |
| twitter | 2,586 | 73 | 70 | 2026-08-19 |
| **facebook** | **17,531** | **0** | **0** | **2020-09-23** |

Facebook sign-ins by year: 2014: 1,524 · 2015: 4,216 · 2016: 6,899 · 2017: 1,750 ·
2018: 1,641 · 2019: 844 · 2020: 657 · then nothing. The button is still rendered in the
legacy modal alongside the other three, so this is not a UI removal (F4).

### What is at stake behind the email-less rows

| | lists | list items |
|---|---:|---:|
| facebook users | 70,124 | 437,039 |
| twitter users | — | 98,478 |

### Email recoverability from `legacy_v1_data` (F7)

| | count |
|---|---:|
| rows examined (facebook + twitter, blob present) | 20,049 |
| recoverable email in blob | 12,719 (12,683 facebook, 36 twitter) |
| no email in the blob either | 7,330 |
| recovered address already held by another row | 404 |
| duplicated within the cohort | 3 |

### Age of the email-less X cohort

Last sign-in by year: 2015: 461 · 2016: 551 · 2017: 567 · 2018: 319 · 2019: 77 ·
2020: 88 · 2021: 98 · 2022: 98 · 2023: 76 · 2025: 2. Predominantly old, with a tail of
roughly 270 in 2021–2023.

## Decisions

**D1 — Trust the provider, not the claim.** Account linking keys off `sign_in_provider`
from the signed token against an explicit allowlist, not off `email_verified`.

**D2 — `password` stays excluded from that allowlist, permanently.** It is the actual
takeover vector (F1). The allowlist is enumerated, never "anything that is not password":
a future provider that does not require email ownership must not become trusted merely by
existing.

**D3 — Keep the `email_verified` column honest.** It records the raw claim. The trust
inference is a separate value used only for the linking decision, so the admin user page
and any future consumer still see what the provider actually asserted. Only
`admin/users/show.html.erb` and `UserAuthenticationService` read the column today.

**D4 — Allow a nil email on OAuth accounts** (F3). Refusing the sign-in is worse, and a
synthesised placeholder is worse still — it pollutes the column, risks mail being sent to
it, and reads as genuine in the admin UI. Accepted cost, stated plainly: those users
cannot be combined across providers, because there is no key to combine on.

**D5 — Fill a blank email, never overwrite one.** `update_existing` deliberately does not
write `email`, because a sign-in must not rewrite the address an account is known by.
Filling a blank is not rewriting.

**D6 — Measure the X `email_verified` claim; do not model it** (F2). One real sign-in on
dev during implementation, with the observed claim recorded back into this document.

**Measured 2026-09-06:** a real X sign-in on `dev-new.thegreatestbooks.org` produced
`email_verified: false` in the token, for an account X had confirmed. F1 is confirmed
empirically: `TRUSTED_EMAIL_PROVIDERS` is **load-bearing** for X, and without it every
returning X user with an existing account would hit a verification wall.

Two things the measurement also settled, neither of which the design anticipated:

- **X supplies no email for a minority of sign-ins.** The test account was one: it produced
  a row with `email: nil`, which succeeded only because of D4. Measured base rate across
  Firebase-era X accounts is roughly 94% with an email (2024: 38/38, 2025: 20/22,
  2026: 8/9). So D4 is not an edge case allowance — it is load-bearing for about one X
  sign-in in eighteen.
- **X's callback allowlist is per-hostname and separate from Firebase's authorized
  domains.** `createAuthUri` returned X error 415 "Callback URL not approved for this
  client application" while `google.com` and `facebook.com` both built valid auth URLs for
  the same `continueUri`. Each host needs `https://<host>/__/auth/handler` registered in the
  X app. X is OAuth 1.0a, so it fails early at `createAuthUri`; OAuth 2.0 providers build a
  URL regardless and fail later at their own dialog — so a successful `createAuthUri` for
  Facebook proves nothing about whether Facebook would work.

**D7 — Legacy identity recovery is a separate spec.** The `legacy_v1_data` email backfill
(F7), uid-based claiming, and the 404 collisions are one coherent piece of work that is
independent of this one, helps Google and email sign-in equally, and is a merge problem
rather than a lookup problem (F6). It gets its own review.

**D8 — Facebook ships disabled.** The registry entry exists with `enabled: false`. Turning
it on is a one-word change once the Meta app is resolved (F4).

**D8a — A brand-new Meta app will be created; the old one is kept, not deleted.** Decided
by Shane 2026-09-05, after Meta's self-service recovery turned out to offer nothing. Creating
it goes through Meta's new app-creation flow and is **separate work, not part of this spec**.

Two consequences for the recovery spec (D7), not for this one:

- A new app issues fresh app-scoped ids, so `external_provider_uid` is **not** a usable key
  for Facebook. Facebook recovery rests on the `legacy_v1_data` email backfill (F7), which
  reaches 12,683 of the 17,531 rows. The ~4,800 with no email anywhere lose their only key.
- Keeping the old app alive preserves the one theoretical route to those ~4,800 — a
  business-scoped id mapping between two apps in the same Business Manager. It is likely
  impractical (it needs each user to authenticate against the old app, which only app-role
  holders can do), but deleting the app would foreclose it outright.

X is unaffected: its ids are global, not app-scoped (F5).

**D9 — Apple is not shipped in this pass.** It is listed as trusted (its relay addresses
are genuinely Apple-verified and user-controlled) and it needs to be, because legacy-site
Apple tokens already validate here. Its `@privaterelay.appleid.com` addresses match no
existing row, which is a matching problem for the recovery spec, not a trust problem.

**D10 — Firebase's Email enumeration protection is ON, and the trust model depends on it.**
Enabled in the console 2026-09-06.

A whole-branch review established that D1's trust model has a gap the F1 framing missed: the
token's `email` claim is the **Firebase account record's** email, not the address the
provider asserted, and the account holder can change it. With the setting off, an attacker
could sign in with their own Google account, call Identity Toolkit `accounts:update` to set
their email to a victim's address — `emailVerified` becomes false but `sign_in_provider`
stays `google.com` — and be linked to the victim's row. The pre-D1 guard blocked that
because it read `email_verified`; D1's guard would not have.

Email enumeration protection closes it by disabling `updateEmail` outright: an email change
must go through `verifyBeforeUpdateEmail`, which requires clicking a link at the new
address. **Do not disable this setting while `TRUSTED_EMAIL_PROVIDERS` exists.** The two are
a pair.

It required no code change: this app does not use `fetchSignInMethodsForEmail`, and
`email_provider.js` already maps `auth/invalid-credential` to "Invalid email or password",
which is the error both wrong-password and unknown-account now return.

F1's sentence "the provider already required ownership" remains true of the provider's
assertion and false of the claim the code reads. It is corrected here rather than in F1 so
the finding's original wording stays legible.

## Design

### Shared provider config

`web-app/config/auth_providers.json`, read by both the JS registry and the ViewComponent.
This mirrors `config/asset_bundles.json`, which `rollup.config.js` and
`test/lint/asset_bundle_coverage_test.rb` already share for the same reason.

```json
{
  "google":   { "firebase_id": "google.com",   "label": "Google",   "scopes": ["profile", "email"],           "enabled": true  },
  "twitter":  { "firebase_id": "twitter.com",  "label": "X",        "scopes": [],                             "enabled": true  },
  "facebook": { "firebase_id": "facebook.com", "label": "Facebook", "scopes": ["public_profile", "email"],    "enabled": false }
}
```

`enabled` gates the button only. A provider that is disabled here but enabled in Firebase
can still authenticate if a token arrives from elsewhere — which is exactly the legacy-site
situation, and why `PROVIDER_MAP` stays broader than this file.

### JavaScript

- **`services/auth_providers/oauth_provider.js`** — one class replacing
  `google_provider.js`. Built from a config entry: constructs the Firebase provider, adds
  scopes, calls `signInWithRedirect`. Error dispatch carries the provider id.
- **`services/auth_providers/registry.js`** — imports the JSON, and holds the only
  irreducibly per-provider JavaScript: a map from `firebase_id` to Firebase constructor
  (`GoogleAuthProvider`, `TwitterAuthProvider`, `FacebookAuthProvider`, with
  `OAuthProvider` as the id-based fallback Apple needs). Exports `signInWith(providerId)`.
- **`entrypoints/firebase_auth.js`** — exposes the registry instead of one named singleton
  per provider. `emailProvider` stays as it is.
- **`controllers/authentication_controller.js`** — `signInWithGoogle` becomes
  `signInWithOauth(event)`, reading the provider from a Stimulus action param
  (`data-authentication-provider-param`). The existing `markPendingRedirect()` /
  `clearPendingRedirect()` bookkeeping and the bundle-load error handling are already
  provider-agnostic and are inherited unchanged.

### Ruby

`Services::AuthenticationService`:

```ruby
# Providers that require email ownership at signup, so their address assertion
# is trusted for account linking even when Firebase sends no email_verified
# flag -- X verifies by confirmation mail but exposes no flag for it.
#
# "password" is deliberately absent and must stay absent: a Firebase password
# account can be created for any address without proving control, which is the
# takeover route UnverifiedEmailConflict exists to block. This list is
# enumerated, not derived: a future provider that does not require email
# ownership must not become trusted just by not being "password".
TRUSTED_EMAIL_PROVIDERS = %w[google.com apple.com facebook.com twitter.com].freeze
```

`extract_provider_data` gains `email_trusted:`, computed from `sign_in_provider` — which
comes out of the verified token, never from params. `email_verified:` continues to carry
the raw claim (D3).

`Services::UserAuthenticationService`:

- `find_user`'s guard becomes `raise UnverifiedEmailConflict unless email_trusted?`
- `update_existing` gains `email: user.email.presence || email` (D5)
- `build_new` is unchanged; a nil email is now permitted to persist

`User`: `validates :email, presence: true` becomes conditional on the **provider**, not on
`auth_uid`:

```ruby
OAUTH_PROVIDERS = %w[google twitter facebook apple].freeze

validates :email, presence: true, unless: :external_oauth_account?
validates :email, uniqueness: {allow_nil: true}

def external_oauth_account? = OAUTH_PROVIDERS.include?(external_provider)
```

Keying on `auth_uid` would be wrong in both directions: password users hold an `auth_uid`
too, so it would exempt exactly the accounts that must have an email, while the 20,063
email-less legacy rows hold none and would stay invalid.

`allow_nil` on uniqueness is not optional. Verified on `users#1` (a V1 twitter row):

```
valid? false
errors: ["Email can't be blank", "Email has already been taken"]
```

Both fire. Rails compares `email IS NULL`, so the second nil-email row collides with the
first even though Postgres permits any number of NULLs.

Those rows are therefore invalid today under the unconditional rule, and any `update!`
touching one raises — the same failure mode as `books-lists-have-malformed-urls`. This
change makes the validation agree with data that is already in the table. Measured effect:
**20,059 of the 20,063 email-less rows become valid**; the remaining 4 have a nil
`external_provider` and stay invalid, which is correct — nothing identifies them.

`AuthController#check_provider` reads the shared config instead of its hardcoded
`%w[google apple facebook twitter]`, so the server's idea of which providers exist cannot
drift from the client's.

### Widget

`Authentication::WidgetComponent` loops the enabled providers and renders one button each,
with an icon partial keyed by provider id, above the existing `or` divider and email form.
Markup follows the current Google button (`btn btn-outline btn-primary w-full`). daisyUI 5
applies — see `daisyui-5-not-4`; the removed-class lint covers the new markup
automatically.

## Tests

**Minitest.** `AuthenticationService`: each trusted provider yields `email_trusted: true`
regardless of the raw claim; `password` never does; an unknown `sign_in_provider` still
raises `UnsupportedProviderError`. `UserAuthenticationService`: a trusted provider with
`email_verified: false` links to an existing row rather than raising; `password` with the
same claim still raises; a nil-email token creates a row; a token with an email fills a
blank but never overwrites a populated one. `User`: nil email permitted for an OAuth
provider, still refused for `password` and for a nil provider, and two nil-email rows both
valid — that last one fails without `allow_nil` and is the test that pins it.

**Lint** (`test/lint/`, matching the existing style): the JSON config, the JS registry's
constructor map, and the widget cannot drift apart; every enabled provider has an icon
partial; `TRUSTED_EMAIL_PROVIDERS` does not contain `password`.

**Playwright.** A full X OAuth round trip cannot be automated — bot detection and 2FA.
But `signInWithRedirect` navigates to `https://<authDomain>/__/auth/handler?…providerId=
twitter.com` *before* reaching X, so the spec asserts that navigation with the right
`providerId`. That proves the config reached the button, the registry built the right
Firebase provider, and Firebase accepted it. Per `e2e-specs-exist-per-domain`, the widget
is shared, so the button-rendering assertion runs in each domain's suite.

**Manual, once, during implementation (D6).** Sign in with X on dev; record the observed
`email_verified` claim in this document. If `true`, `TRUSTED_EMAIL_PROVIDERS` is
belt-and-braces for X. If `false`, it is load-bearing and F1 is confirmed empirically.

## Out of scope

- **Legacy identity recovery** (D7): the `legacy_v1_data` email backfill, uid-based
  claiming, and the 404 collisions. Its own spec. Two findings carry forward: X uids are
  globally stable and safe to match on (F5), and 49 duplicate groups already exist, so it
  begins as a merge problem, not a prevention problem (F6).
- **Enabling Facebook** (D8) — blocked on the Meta app, not on code.
- **Creating the replacement Meta app** (D8a) — Meta's own flow, separate work.
- **Apple sign-in** (D9).
- **Movies.** Out of scope permanently.
