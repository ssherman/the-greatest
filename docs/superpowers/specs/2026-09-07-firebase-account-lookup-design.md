# Server-side Firebase account lookup — design

**Status:** approved 2026-09-07
**Branch:** `enable-facebook-login`
**Does NOT supersede:** D10 of `2026-09-05-oauth-provider-registry-design.md` remains in
force — see D8 below, corrected 2026-09-07 after review found the fallback this design
still uses

## Summary

OAuth ID tokens from this Firebase project frequently carry no `email` claim. Every
Facebook token lacks one, as do a minority of X and Apple tokens. Account linking
reads that claim, so those sign-ins cannot be matched to an existing account and
create a duplicate row instead.

The address is not missing — Firebase holds it on the **provider record** and
declines to promote it to the **account record**, which is what mints ID tokens.
This design fetches it from the provider record server-to-server, at the one moment
it decides anything: when the `auth_uid` match misses.

It also makes the linking key more trustworthy when a provider-record address
exists — but it falls back to the same token claim when one doesn't (every
Facebook sign-in), so it does not retire the standing dependency on a Firebase
console setting. See D8, corrected below.

## Context

`Services::UserAuthenticationService#find_user` resolves a token to a user in three
steps: `auth_uid` exact match, then a trusted-email match, then create. The email
step exists because a V1 user imported under one uid who later signs in with Google
presents a different `sub`, and refusing to relink would lock them out of their own
data.

PR #300 shipped Sign in with X on this structure and left Facebook disabled pending
a replacement Meta app. That app now exists and passed App Review. Enabling the
button revealed that Facebook tokens carry no email at all.

## Findings

**F1 — The cause is a Firebase console setting, and it is documented.**
["Allow multiple accounts with the same email address"](https://support.google.com/firebase/answer/9134820?hl=en):

> When you allow only one account per email address, these functions retrieve user
> profile information from the identity providers, including the user's email
> address… If you change the default setting by allowing multiple accounts to have
> the same email address, these functions will not retrieve profile information; if
> you need this information, you must retrieve it from the identity provider
> yourself.

A Firebase engineer on
[firebase-talk](https://groups.google.com/d/topic/firebase-talk/DFECz9yGY5o), on this
exact symptom for Facebook and Twitter: *"The top level email is not set and only the
email for the relevant provider is available."*

That setting is deliberate here. It is what allows one person to hold separate
Firebase accounts per provider while Rails combines them into one user record.

**F2 — Measured, not inferred.** Four Facebook sign-ins on 2026-09-07 produced the
identical claim set:

```
aud, auth_time, exp, firebase, iat, iss, name, picture, sub, user_id
```

No `email`, no `email_verified`. The fourth was a fully clean test: the app revoked
from the Facebook profile, the Firebase account deleted, a fresh consent dialog
explicitly granting `public_profile` and `email`, against a **published** Meta app
with `email` granted. `providerData[0].email` carried the address every time.

Meta app mode, App Review status, and publishing were each eliminated as causes by
measurement. So was email enumeration protection: every Google and X row predates it.

**F3 — Suppression appears collision-scoped.** Inference, not documented; the design
does not depend on it. Firebase-era rows by provider:

| provider | total | with email | without |
|---|---|---|---|
| google | 14,096 | 14,096 | 0 |
| password | 3,287 | 3,287 | 0 |
| apple | 1,521 | 1,509 | 12 |
| twitter | 74 | 70 | 4 |

If suppression were unconditional these would be zero. The reading that fits is that
Firebase omits the account-record email when another account already holds that
address. Most Google and X users are the first account for their address; the test
account's address sits on six Firebase accounts and collides every time.

**F4 — `providerUserInfo` is the server-side original.** The account record carries a
`providerUserInfo[]` array; the client SDK's `providerData` is its mirror, which is
why the browser can see an address the token cannot. `accounts:lookup` returns it,
authenticated by a service account with `firebaseauth.users.get`, scope
`https://www.googleapis.com/auth/identitytoolkit`, looked up by `localId[]`.

**F5 — The email is only consulted after the uid match misses.** `find_user` returns
on `auth_uid` before touching email. Returning users therefore never need one, which
is what makes a lazy lookup cheap.

**F6 — A provider-record email is more trustworthy than the token claim.** The
token's `email` is the account record's email, which its holder can repoint via
Identity Toolkit `accounts:update` while `sign_in_provider` stays put. That is the C1
takeover found in PR #300's final review. `providerUserInfo[].email` is what the
identity provider asserted, refreshed from the IdP at sign-in, and not writable by
the account holder.

**F7 — Prior art exists for every moving part.** `Games::Igdb::Authentication`
mints and caches a third-party OAuth token behind a `Mutex` with an expiry buffer.
`Services::JwtValidationService` caches Google certs in-process with cooldown-gated
refetch, and documents why in-process rather than `Rails.cache`: production
configures no `cache_store`, so `Rails.cache` is a per-container file store anyway.
Faraday is the HTTP client throughout `app/lib`.

**F8 — Facebook's legacy cohort is not fixed by this work.** All 17,531 Facebook
rows have `NULL` email and none has ever authenticated through Firebase. The new
Meta app also reset the app-scoped ids — measured `10166754100896840` where
`users#42207` holds `10160972764671840` — so all 17,529 stored
`external_provider_uid` values match nothing a new-app token presents.

The cohort splits three ways:

- **12,683** have an address recoverable from `legacy_v1_data`; 398 of those collide
  with an existing row and need a merge rather than an update. Caveat: it is the
  address Facebook supplied between 2014 and 2020, so anyone who has since changed
  their Facebook email will not match.
- **4,848** have no address anywhere. Their only stored key is the old app's
  app-scoped id — but that may still be usable, see F9.
- Those 4,848 rows own **19,392 UserLists and 83,231 UserListItems**. All of them
  signed in at least once; 347 signed in repeatedly. This is a decade of reading
  lists, not dormant stubs.

**F9 — The old app-scoped ids may be recoverable through Meta's Business Mapping
API.** [`ids_for_business`](https://developers.facebook.com/docs/graph-api/reference/user/ids_for_business)
on the User node "returns the list of IDs that a user has in any of those other
apps", for apps claimed by the same Business Manager. On a sign-in through the new
app it would yield the same person's id in the old app, which is exactly what all
4,848 rows still hold in `external_provider_uid`.

Unverified, and two gates are undocumented: whether a **Meta-disabled** app can be
claimed by a Business Manager, and what permissions the edge requires. Both are
cheap to establish. **The old Meta app must not be deleted** — it is the only thing
that makes this path possible.

## Decisions

**D1 — Look up only when the `auth_uid` match misses.** The sole moment an email
decides anything. Returning users pay nothing. Rejected: looking up on every sign-in
(adds latency and an external dependency to all 14,096 Google users for no decision),
and looking up only when the token claim is absent (leaves the mutable account-record
email as the linking key for everyone else, keeping F6's exposure open).

**D2 — A failed lookup refuses the sign-in.** Without the email we cannot distinguish
a brand-new user from an existing one adding a provider. Proceeding risks silently
creating a duplicate of a real account — permanent, and undoable only by a merge that
has historically destroyed favorites. A refused sign-in is temporary and self-heals on
retry. Faraday open and read timeouts are 3 seconds each, set explicitly rather than
left to Faraday's defaults. It never falls back to client-supplied data and never
proceeds on a guessed address.

**D3 — Resolution rule, uniform across providers.** Take the `providerUserInfo` entry
whose `providerId` equals the token's `sign_in_provider`; use its `email`. If that
yields nothing, fall back to the token's `email` claim. This keeps `password` working
without a special case — those accounts carry the address on both — and means the
lookup can only ever improve on today's behaviour.

**D4 — `extract_provider_data` stays a pure function of the payload.** The network
call lives behind a resolver object passed into `UserAuthenticationService` and
invoked lazily. That preserves the property the class comment rests on — everything
returned derives from a signature-verified token, nothing from request params — and
makes the call stubbable without stubbing HTTP globally.

**D5 — Hand-roll the JWT-bearer grant with the `jwt` gem already present.** ~25
lines, no new dependency chain, and `Games::Igdb::Authentication` sets the precedent
for minting a third-party token in this codebase. Rejected `googleauth`: it pulls in
signet and transitive dependencies for a single well-documented grant.

**D6 — Cache the access token in-process, mutex-guarded, with an expiry buffer.**
Per F7. Not `Rails.cache`.

**D7 — `TRUSTED_EMAIL_PROVIDERS` is unchanged and `password` stays excluded.** The
question it answers — could someone register this address at this provider without
controlling it — is untouched by where we read the address. A password account can
still be created for any address without proving control.

**D8 — D10 of the OAuth provider registry design is NOT retired.** It still says
email enumeration protection must stay on because `TRUSTED_EMAIL_PROVIDERS` depends
on it, since `accounts:update` can repoint the account-record email the linking
rule reads. D3's resolver *prefers* the provider record, but `ProviderEmailResolver`
falls back to the token's `email` claim — the mutable account-record field —
whenever the provider record has no address (`provider_email_resolver.rb:28`), and
`AuthenticationService` wires that fallback from `payload["email"]`
(`authentication_service.rb:65`). Every Facebook token hits exactly this path: it
carries no provider-record email at all (F2), so linking there reads the token
claim precisely as before D3 shipped. Retiring D10 would mean removing the
fallback for trusted providers, which this design deliberately does not do: a nil
email would make `find_user` create a new row rather than refuse, trading a narrow,
console-mitigated takeover for guaranteed duplicate accounts. Keep the setting
enabled — it remains load-bearing.

**D9 — `users.email_verified` keeps recording the raw token claim.** Unchanged. It
is the provider's own assertion; the linking decision remains a separate key.

**D10 — Facebook ships enabled in this pass.** `config/auth_providers.json` and the
three pinned test assertions are already committed on this branch, with Playwright
green 15/15 across books, music and games.

**D11 — Legacy reconnection is out of scope and is a named gap.** Until it runs, a
returning legacy Facebook or X user still lands on a new row, because `find_user`
matches the resolved email against `users.email` and theirs is `NULL`. This design
fixes new sign-ups and existing users adding a provider. It does not reconnect F8's
cohort. That is its own spec, covering two distinct paths — the `legacy_v1_data`
email backfill for 12,683 rows, and the F9 Business Mapping route for the 4,848 that
have no address at all — and both end in a merge problem, not a lookup problem.

**D11a — Establish the F9 gates before that spec, not during it.** Whether the
disabled app can be claimed by a Business Manager decides whether the 4,848 are
recoverable at all, and it is a console question, not an engineering one. Answer it
early: it is the only finding that could change the shape of the recovery spec, and
84k list items ride on it.

**D12 — The service-account key is a SOPS-managed ENV var**, base64-encoded into a
single variable, per the project rule that secrets are ENV vars and never
`Rails.application.credentials`.

## Design

```
AuthController
  └── AuthenticationService.call(auth_token:, project_id:, signup_domain:)
        ├── JwtValidationService.call            → verified payload
        ├── extract_provider_data(payload)       → pure hash (unchanged)
        └── UserAuthenticationService.call(provider_data:, email_resolver:)
              └── find_user
                    ├── User.find_by(auth_uid:)  → hit: return, no network
                    └── miss: email_resolver.call
                          └── FirebaseAccountLookup.call(uid)
                                └── GoogleServiceAccountToken.access_token
```

**`Services::GoogleServiceAccountToken`** — builds a JWT-bearer assertion from the
service-account key, exchanges it at `oauth2.googleapis.com/token`, caches the
result in-process behind a `Mutex` until shortly before expiry.

**`Services::FirebaseAccountLookup`** — POSTs `{"localId": [uid]}` to
`identitytoolkit.googleapis.com/v1/projects/<project_id>/accounts:lookup` with the
bearer token, returns the `providerUserInfo` array. Raises a typed error on timeout,
non-200, or unparseable body.

**The resolver** — a small object closing over the uid and `sign_in_provider`,
implementing D3's rule. Injected into `UserAuthenticationService` with a default, so
existing call sites and tests that pass an email directly keep working.

**`AuthenticationService`** — maps the lookup's typed error to a new retriable
`error_code` and a user-facing "we couldn't complete sign-in, please try again"
message. It must not be swallowed by the existing catch-all `rescue`, which would
turn a refused sign-in into a generic failure.

## Tests

Minitest + Mocha, HTTP stubbed throughout. No E2E: reaching this path needs a real
Facebook round trip, so the existing Playwright spec continues to cover the button
and the redirect only.

- **uid hit performs zero lookups** — asserts the resolver is never called. This is
  the entire latency argument for D1; without it the design's cost claim is unproven.
- uid miss, provider entry carries the email → links to the existing row
- uid miss, provider entry has no email, token claim does → falls back per D3
- uid miss, neither has an email → creates, matching today's behaviour
- lookup raises → sign-in refused with the retriable code, **no user row created or
  modified**
- untrusted provider (`password`) with a resolved email still raises
  `UnverifiedEmailConflict` against an existing row
- token minting: cached hit issues no HTTP call; expired token refreshes; a failed
  exchange raises rather than returning nil

Every security-relevant guard carries a mutation check — revert the guard, confirm
the test fails, restore — per this branch's existing standard.

## Out of scope

- The 12,683-row `legacy_v1_data` email backfill and its 398 collisions (D11)
- The legacy books app's `users_controller.rb` vulnerabilities: the client-supplied
  email fallback at line 144, and the algorithm read from the unverified JWT header.
  That app retires in 2–3 weeks and has no CI, so merging is deploying.
- Changing the multiple-accounts-per-email setting. Switching to one-account-per-email
  would populate emails natively but inverts the model for 30,000+ existing users and
  forces an explicit link flow.
- Apple's private relay addresses, and `MembershipMailer`'s behaviour on an
  email-less member — both pre-existing and unchanged by this work.
