# OAuth providers

`web-app/config/auth_providers.json` is the single source of truth for the
provider's id, label, scopes, and whether its button renders — but that file
alone is not enough to add a working provider. Adding one touches several
files across Ruby and JS; see below for all of them.

## Adding a provider

1. Add an entry: `id`, `firebase_id`, `label`, `scopes`, `enabled`.
2. Add `web-app/app/views/shared/auth_icons/_<id>.html.erb`.
3. Add it to `PROVIDER_FACTORIES` in
   `app/javascript/services/auth_providers/oauth_provider.js`. Every configured
   provider gets an explicit factory there, even ones the generic
   `OAuthProvider(firebase_id)` fallback would construct correctly on its own —
   Apple included. The fallback still works if an entry is missing; only the
   explicit entry is checked by the lint test below, so a mismatch is caught by
   `bin/rails test` instead of only surfacing when someone clicks the button.
4. Add `firebase_id => id` to `Services::AuthenticationService::PROVIDER_MAP`.
   Without this, the button renders, the redirect works, and Firebase returns
   a valid token — but `/auth/sign_in` answers "This sign-in method is not
   supported". The button looks live and isn't.
5. Add `id` to `User`'s `external_provider` enum. `PROVIDER_MAP`'s value has
   to be a real enum value, or the first sign-in raises when it tries to save
   the user.
6. If it requires email ownership at signup, add its `firebase_id` to
   `Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS`.

`test/lint/auth_provider_registry_test.rb` fails if 1, 3, 4, or 5 disagree;
`test/components/authentication/widget_component_test.rb` fails if 2 is missing.

## `enabled` gates the button, nothing else

A disabled provider can still authenticate. One Firebase project serves the legacy
site as well, so its tokens validate against `/auth/sign_in` regardless of what this
app renders. `Services::AuthenticationService::PROVIDER_MAP` is a separate hardcoded
map of every Firebase provider this app can decode a token for, and it is not
filtered by this file's `enabled` flag; `check_provider` reads
`Services::AuthProviderRegistry.all` rather than `.enabled`, for the same reason. The
widget is the only place `enabled_for_view` is used, so it is the only place a
disabled provider disappears.

## Trust is not configuration

`TRUSTED_EMAIL_PROVIDERS` is a hardcoded constant on `Services::AuthenticationService`,
deliberately not read from the JSON: turning a button on must never widen a security
decision as a side effect.

It answers "could someone register this address at this provider without controlling
it?", not "did the token say verified". X verifies addresses by confirmation mail but
sends no flag, so gating on the flag would send every returning X user to a
verification wall. `password` is excluded permanently — a Firebase password account
can be created for any address without proof, which is the account-takeover route
`UserAuthenticationService::UnverifiedEmailConflict` exists to block.

Linking *prefers* the address on the account's **provider record** over the token's
`email` claim, which narrows the exposure: most sign-ins never touch the mutable
claim at all. But `Services::ProviderEmailResolver` falls back to the token's
`email` when the provider record has none — see
`provider_email_resolver.rb:28` — and `Services::AuthenticationService` supplies
that fallback from `payload["email"]`, the same account-record claim an account
holder can repoint via `accounts:update`. A Facebook user who declines the
optional `email` permission at Meta's consent dialog is exactly this case: no
provider-record email, so linking reads the token claim as before. Email
enumeration protection must stay enabled — it is still the only thing blocking
that takeover, exactly as D10 of the provider registry design requires.

## Facebook runs on a replacement Meta app

The original app was disabled by Meta. A new one replaced it, and two consequences
follow that do not apply to any other provider.

**The app-scoped ids reset.** Facebook has issued per-app ids since Graph API v2.0,
so the new app returns different numbers for the same people. Measured 2026-09-07:
the new app returned `10166754100896840` where `users#42207` still holds
`10160972764671840` from the old one. All 17,529 stored Facebook
`external_provider_uid` values are dead keys. For the 4,848 Facebook rows with no
email anywhere — not on the row, not in `legacy_v1_data` — nothing is left to
match on. X ids are global and unaffected; see the design doc's F5.

**Every Facebook row has a NULL email.** All 17,531 of them, and none has ever
authenticated through Firebase. `find_user` matches on `users.email`, so a
returning Facebook user matches nothing and gets a new row rather than their
account. 12,683 of those emails are recoverable from `legacy_v1_data` (398 collide
with an existing row and need a merge, not an update). Until that backfill runs,
enabling the button converts a lookup problem into a merge problem for anyone who
comes back.

**Facebook tokens carry no `email` claim, and that is permanent.** It is not a Meta
setting: Firebase keeps a provider-supplied address on the provider record and, under
this project's "allow multiple accounts with the same email address" setting, does not
promote it to the account record that mints ID tokens. Measured four times on
2026-09-07, including against a published app with a revoked grant and a deleted
Firebase account. `Services::ProviderEmailResolver` fetches it server-to-server
instead; see `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`.

## Meta Platform Data must never reach ad targeting

Meta's Platform Terms prohibit using Platform Data for advertising or ad targeting
and prohibit sharing it with ad networks. The sites serve Google Ads to non-members,
so the constraint is live: the Facebook-derived email and user id must not be passed
to gtag, used for hashed-email audience matching, or built into custom audiences.
Nothing does this today. Conversion tracking is the likely place someone would break
it by accident.

## Email-less accounts

X supplies no email for a minority of sign-ins, and 20,063 legacy rows have none.
Those accounts are valid (`User#external_oauth_account?` relaxes the presence rule)
but cannot be linked across providers. A later sign-in that does supply an address
fills the blank — `UserAuthenticationService#update_existing` never overwrites one.
