# OAuth providers

Social sign-in is driven by one file: `web-app/config/auth_providers.json`.

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
4. If it requires email ownership at signup, add its `firebase_id` to
   `Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS`.

`test/lint/auth_provider_registry_test.rb` fails if 1 and 3 disagree;
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

## Facebook is off

The Meta app is disabled by Meta and runs in development mode only, so only accounts
holding a role on the app can sign in. A replacement app is separate work; note that
it will issue fresh app-scoped ids, so `users.external_provider_uid` will not match
for Facebook. X ids are global and unaffected.

## Email-less accounts

X supplies no email for a minority of sign-ins, and 20,063 legacy rows have none.
Those accounts are valid (`User#external_oauth_account?` relaxes the presence rule)
but cannot be linked across providers. A later sign-in that does supply an address
fills the blank — `UserAuthenticationService#update_existing` never overwrites one.
