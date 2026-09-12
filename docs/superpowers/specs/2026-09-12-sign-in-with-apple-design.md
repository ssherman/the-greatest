# Sign in with Apple — design

**Date:** 2026-09-12
**Status:** Approved
**Branch:** `worktree-sign-in-with-apple`
**Builds on:** `2026-09-05-oauth-provider-registry-design.md` (D9 deferred Apple) and
`2026-09-07-firebase-account-lookup-design.md` (the resolver Apple depends on)

## Summary

Apple is the last of the four social providers. The registry design left it disabled
because nothing had been verified against Apple; that verification is now done, and the
result is that **the code change is one word**. Everything else Apple needs was built for
X and Facebook: the factory, the provider map, the trust allowlist, the enum, the icon,
and the server-side email lookup that Facebook forced into existence.

What remained was console work in the Apple Developer portal, which is complete, and a
set of measurements that this document records so nobody has to re-derive them. The
headline: Apple tokens carry **no `email` claim**, exactly like Facebook's, and 64% of
existing Apple users use Hide My Email.

## Context

### Apple is already live — on the legacy site

The legacy books app signs users in with Apple through this same Firebase project, using
the identical construction this app's registry produces:

```javascript
const provider = new OAuthProvider('apple.com');
provider.addScope('email');
provider.addScope('name');
signInWithRedirect(auth, provider);
```

So the Firebase side — Services ID, Team ID, key ID, private key — has been configured
for years and needs nothing. Measured against the development database (a production
restore) on 2026-09-12:

| | count |
|---|---:|
| Apple users | 1,521 |
| with a Firebase `auth_uid` | 1,521 (all) |
| with an email in `users.email` | 1,509 |
| of those, `@privaterelay.appleid.com` | **966 (64%)** |
| with a `display_name` | 49 |
| sign-ins by year | 2024: 187 · 2025: 893 · 2026: 441 |

Every Apple user is Firebase-era with a uid, so every returning one takes `find_user`'s
first branch and never touches the email path.

### What this app already has for Apple

| Piece | Location | State |
|---|---|---|
| Registry entry, scopes `["email", "name"]` | `config/auth_providers.json` | present, `enabled: false` |
| Icon partial | `app/views/shared/auth_icons/_apple.html.erb` | present |
| JS factory `'apple.com': () => new OAuthProvider('apple.com')` | `oauth_provider.js` | present, lint-pinned |
| `"apple.com" => "apple"` | `AuthenticationService::PROVIDER_MAP` | present |
| `apple.com` in `TRUSTED_EMAIL_PROVIDERS` | `AuthenticationService` | present (registry D9) |
| `apple` in `external_provider` enum (value 3) | `User` | present |
| Provider-record email lookup on a uid miss | `ProviderEmailResolver` → `FirebaseAccountLookup` | shipped in #301 |

## Findings

**F1 — Apple's return URLs are per host, and an individual Services ID holds ten entries.**
Firebase's return URL is `https://<authDomain>/__/auth/handler`, and this app's
`authDomain` is the page's own hostname (`firebase_auth_service.js#getDomainConfig`;
Caddy and nginx proxy `/__/auth/*` to Firebase on every host). Apple validates the
`redirect_uri` exactly — "domains, subdomains, and return URLs are considered separate
values and should be explicitly registered", no wildcards, https only, no localhost
(Apple DTS, forums thread 120760). So every host that renders the widget needs its own
entry.

Apple's stated cap is "up to 10 website URLs" for an individual enrollment and 100 for an
organization. This account is an individual enrollment. **Measured 2026-09-12: the cap is
a joint count across both boxes.** An earlier draft of this finding said eight domains
plus eight return URLs had saved; they had not — the dialog accepted the paste, the outer
page silently discarded it, and a later attempt with the outer save surfaced the real
error: "Limit exceeded for 'Website URLs'. Maximum limit : '10'." Until then Apple's
production behaviour was the giveaway: the Services ID Firebase uses,
`org.thegreatestbooks.beta`, accepted only `https://thegreatestbooks.org/__/auth/handler`
and rejected the other seven with "invalid_request — Invalid web redirect url".

Two things make ten enough. Apple validates the OAuth `redirect_uri` against the Return
URLs box alone; the Domains box serves its JS popup flow and the email relay, neither of
which this app uses, so it needs only the three apex domains. And the legacy dev host
was already rejected, so dropping it loses nothing. Registered on
`org.thegreatestbooks.beta` — 3 domains + 7 return URLs = 10:

| entry | box | role |
|---|---|---|
| `thegreatestbooks.org` | domain | apex |
| `thegreatestmusic.org` | domain | apex |
| `thegreatest.games` | domain | apex |
| `https://thegreatestbooks.org/__/auth/handler` | return URL | legacy books today; this app at launch |
| `https://new.thegreatestbooks.org/__/auth/handler` | return URL | this app, books, pre-launch |
| `https://dev-new.thegreatestbooks.org/__/auth/handler` | return URL | this app, books, dev |
| `https://thegreatestmusic.org/__/auth/handler` | return URL | this app, live |
| `https://dev.thegreatestmusic.org/__/auth/handler` | return URL | this app, dev |
| `https://thegreatest.games/__/auth/handler` | return URL | this app, live |
| `https://dev.thegreatest.games/__/auth/handler` | return URL | this app, dev |

Not registered, by choice: `dev.thegreatestbooks.org` (the legacy dev site, retiring).
Any future host costs a slot; the next one to give up is `new.thegreatestbooks.org` once
books launches on the apex.

`www.` variants are not needed: nginx 301s them to the apex before any page renders.

**The registration can be checked without a browser.** `accounts:createAuthUri` returns
the exact `appleid.apple.com/auth/authorize` URL Firebase would redirect to for a given
`continueUri`; fetching it shows Apple's "invalid_request" page for an unregistered host
and the sign-in page for a registered one. That is what verified all seven, production
hosts included, before deploy — see Measured. Apple propagates a Services ID save across
its edge over several minutes, during which the same URL alternates between accepted and
rejected; two consecutive clean passes is the bar.

The configuration lives under Certificates, Identifiers & Profiles → **Identifiers** →
filter "Services IDs" → the Services ID → Sign in with Apple → Configure → Website URLs.
It is not under the sidebar's "Services" page, which is the email relay (F4). The dialog's
contents are discarded unless the outer Services ID page is then saved with
Continue → Save.

**F2 — Apple tokens carry no `email` claim. Measured, not inferred.** `accounts:lookup`
against 36 Apple Firebase accounts (six chosen, thirty random) on 2026-09-12:

| | present |
|---|---:|
| account-record `email` | **0 / 36** |
| account-record `emailVerified` | 0 / 36 |
| provider-record (`providerUserInfo[apple.com]`) `email` | **36 / 36** |
| provider-record email equals `users.email` | 7 / 7 (checked on the chosen six plus one) |
| account-record `displayName` | 35 / 36 |
| Apple is the account's only provider | 36 / 36 |

The Firebase ID token's `email` claim is the account record's, so it will be absent on
every Apple sign-in — the same shape as Facebook (account-lookup design F2), and the
resolver built for Facebook handles it: on a uid miss it reads the provider record, which
holds the address every time.

This corrects the account-lookup design's F3. That table counted `users.email` and read
"apple: 1,521 total, 1,509 with, 12 without" as evidence that Firebase's suppression is
collision-scoped. Those 1,509 addresses were posted by the **legacy client** from
`providerData`, not read from a token, so they say nothing about the claim. On the token,
Apple's suppression is unconditional, like Facebook's. The inference in F3 was already
marked as one the design does not depend on; it is now known to be wrong for Apple.

**F3 — The scope list is load-bearing under this project's settings.** Firebase's Apple
docs: "By default, Firebase requests email and name scopes when *One account per email
address* is enabled. If changed to *Multiple accounts per email address*, Firebase
requests no scopes unless you specify them." This project runs multiple-accounts. Without
`email` in the registry entry, Apple would issue a token with no address on the provider
record either, and every new Apple user would land on an email-less row (registry D4)
with no key to ever link them. The scopes are present in the config today; the test in
this design pins them so a tidy-up cannot remove them.

**F4 — The email relay is already registered.** Hide My Email addresses only receive mail
from senders registered under Certificates, Identifiers & Profiles → Services → *Sign in
with Apple for Email Communication*, with SPF or DKIM passing. All of this app's mail is
sent from `MAIL_FROM_ADDRESS`, one address at `thegreatestbooks.org` for every site
(`MailBranding#from`). That domain is registered with SPF green, as is
`contact@thegreatestbooks.org`. Nothing else sends mail, so the other rows on that page
— including four `dev.*`/`new.*` subdomains showing SPF red — are inert. They can be
deleted or ignored.

**F5 — Name arrives once, but Firebase keeps it.** Apple sends the user's name only on the
first authorization (or after the user revokes and re-grants). Firebase persists it on the
account record — F2 found `displayName` on 35 of 36 — so the token's `name` claim is
present on later sign-ins too. `UserAuthenticationService#update_existing` writes
`display_name: provider_data[:name].presence || user.display_name`, so the first sign-in
through this app fills the 1,472 Apple rows that have no name today. There is no public
edit form for `display_name`, so nothing user-entered is at risk of being overwritten.

The exception is real, and the measured sign-in (D3) hit it: an account whose first
authorization did not leave a `displayName` on the Firebase record never gets one — Apple
will not resend the name, and the token has no `name` claim at all. `presence ||` keeps
whatever the row already holds, so those accounts lose nothing; they just do not gain a
name either.

**F6 — Relay addresses cannot link across providers, and nothing can change that.** A
`@privaterelay.appleid.com` address is unique per Apple user per developer team. It
matches no Google or password row, so an Apple user who also holds another account here
gets — and keeps — two rows. Registry D9 accepted this; it is restated because it is now
the majority case (F1's 64%), not an edge.

## Decisions

**D1 — Enable the button.** `apple.enabled: true`. No other Ruby or JavaScript changes.

**D2 — The E2E stops at the Firebase handler, matching the other providers.** The
Playwright assertion is that clicking the button navigates to
`/__/auth/handler?…providerId=apple.com` on the same host. It proves the config reached
the button and the factory built the right provider; it does not prove Apple's console
accepts that host. The alternative — following the redirect to `appleid.apple.com` and
asserting Apple did not render "invalid_request / Invalid web redirect url" — was
considered and declined in favour of uniformity. The per-host check is manual (D4).

**D3 — Measure the token on dev before it reaches production.** One real Apple sign-in on
`dev-new.thegreatestbooks.org`, recording the claim set, which `find_user` branch it took,
and the resulting row — the same discipline as registry D6 for X and account-lookup F2 for
Facebook. Expected: no `email`, `name` present, uid hit (the tester's Apple ID already
holds a Firebase account from the legacy site). The uid-miss path is not forced by
deleting that Firebase account: the resolver is unit-tested and has been live for
Facebook in production since #301.

**D4 — Verify every host, once.** As written, six clicks: the Apple button on each of
`dev-new.thegreatestbooks.org`, `dev.thegreatestmusic.org`, `dev.thegreatest.games`, and
after deploy `new.thegreatestbooks.org`, `thegreatestmusic.org`, `thegreatest.games`.
Pass is Apple rendering its sign-in form; fail is Apple's "invalid_request" page, which
means that host's return URL is missing from the Services ID. This is the only check of
the one thing that can actually be wrong, and D2 deliberately does not automate it.

**Amended during implementation:** the `createAuthUri` probe described under F1 checks
the same thing — Apple's verdict on the exact `redirect_uri` Firebase builds for a host —
and was run for all seven registered hosts, production included, before deploy. One real
browser click on `dev-new.thegreatestbooks.org` confirmed the probe agrees with a browser.
The post-deploy clicks are therefore confirmation, not the first evidence.

**D5 — Leave the "does not render a disabled provider" test standing, on a stub.** With
Apple enabled there is no disabled provider left in the real config. The test keeps its
purpose — the widget honours `enabled` — by stubbing `AuthProviderRegistry.all` with a
config containing one disabled entry, rather than being deleted or left depending on
whichever provider happens to be off this month.

**D6 — The docs get corrected, not just extended.** `docs/features/authentication.md`'s
"Supported Providers" table still lists X and Facebook as "Enum defined, not implemented".
It is refreshed alongside the Apple entry. `docs/features/oauth-providers.md` gains an
Apple section carrying F1–F6. The account-lookup design's F3 gets a dated correction
note pointing here.

## Design

### Code

`web-app/config/auth_providers.json`:

```json
"apple": { "firebase_id": "apple.com", "label": "Apple", "scopes": ["email", "name"], "enabled": true }
```

That is the entire production change.

### Tests

`test/components/authentication/widget_component_test.rb`:

- "the enabled registry reaches the client as a Stimulus value": the id list becomes
  `%w[google twitter facebook apple]`, and a new pin
  `assert_equal %w[email name], by_id["apple"]["scopes"]` with a comment citing F3 — this
  is the assertion that would have caught a scope removal before it created email-less
  users. The existing comment claiming Facebook is "the only enabled provider with a
  non-empty scope list" becomes false and is rewritten.
- "does not render a button for a disabled provider": stubs `Services::AuthProviderRegistry.all`
  (Mocha; the memoised `@all` is bypassed by the stub) with a hash holding one enabled and
  one disabled entry, and asserts only the enabled one renders (D5).
- "renders a button for every enabled provider" iterates the registry and needs no change;
  it now covers four.

`e2e/tests/books/oauth-providers.spec.ts`: `ENABLED` gains
`{ id: 'apple', label: 'Apple', firebaseId: 'apple.com' }`; `DISABLED` becomes empty and
its loop becomes a no-op, kept so the next disabled provider has somewhere to go. Runs
across all three dev hosts as today.

`test/lint/auth_provider_registry_test.rb` already pins Apple's factory, `PROVIDER_MAP`
entry and enum value regardless of `enabled`; unchanged.

### Docs

- `docs/features/oauth-providers.md`: new section "Apple" — no token email (F2), 64%
  relay and the linking consequence (F6), scopes are load-bearing (F3), name-once (F5),
  return URL per host with the registered list and the individual-enrollment measurement
  (F1), email relay registration state (F4).
- `docs/features/authentication.md`: Supported Providers table → all five "Implemented".
- `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`: a dated note
  under F3 that the Apple row was client-posted data, per this document's F2.

### Manual verification (D3, D4)

Recorded back into this document under **Measured** before the branch is finished:

1. Claim set of one real Apple token on dev; branch taken; row before/after.
2. One click per host, six hosts, pass/fail each.

## Out of scope

- **Cross-provider linking for relay addresses** (F6). There is no key; registry D9
  stands.
- **The four red SPF rows** on the email-communication page (F4). They never send mail.
- **Apple token revocation on account deletion.** Apple requires it of App Store apps;
  the web has no such requirement, and this app has no iOS app.
- **The legacy site's Apple flow.** It shares the Services ID and gains nothing and loses
  nothing from the added return URLs.
- **`display_name` overwrite semantics** for every provider — `update_existing` prefers
  the token's name on every sign-in. Pre-existing, provider-agnostic, and harmless while
  there is no user-facing edit form.

## Measured

**Hosts (D4), 2026-09-12.** `createAuthUri` probe against `org.thegreatestbooks.beta`,
two consecutive passes after propagation settled:

| host | Apple's verdict |
|---|---|
| `thegreatestbooks.org` | accepted |
| `new.thegreatestbooks.org` | accepted |
| `dev-new.thegreatestbooks.org` | accepted — and confirmed by a real browser click |
| `thegreatestmusic.org` | accepted |
| `dev.thegreatestmusic.org` | accepted |
| `thegreatest.games` | accepted |
| `dev.thegreatest.games` | accepted |
| `dev.thegreatestbooks.org` | rejected — not registered, by choice (F1) |

Before the Services ID save landed, the same probe returned accepted for
`thegreatestbooks.org` only and rejected for all seven others, matching the user's
"invalid_request" click on dev-new. During propagation the probe alternated verdicts on
the same URL between runs.

**Token (D3), one real sign-in on `dev-new.thegreatestbooks.org`, 2026-09-12 18:42 UTC.**

Claims: `aud, auth_time, exp, firebase, iat, iss, sub, user_id`. `alg: RS256`,
`sign_in_provider: apple.com`, `identities: {apple.com}`. **No `email`** (F2 confirmed on
a live token, not just the account record) and **no `name`** — the tester's Firebase
Apple account, created 2024-03-26, holds no `displayName` on either the account or the
provider record, so it is the 1-in-36 case F5's exception paragraph describes.

Branch: **uid miss → `ProviderEmailResolver` → provider-record email → match → relink.**
The tester's row (`users#1141`, created 2014, `sign_in_count` 136 → 137) had been relinked
to the Facebook uid by the 2026-09-07 measurement; this sign-in rewrote `auth_uid` to the
Apple uid and `external_provider` to `apple`, the documented single-`auth_uid` eviction.
The provider record carried the real address (relay: no — the tester shared it with
Apple), which is what matched. `email` on the row was not rewritten; `display_name` was
not touched (`presence ||`). `POST /auth/sign_in` completed 200 in 355 ms with six
queries, and the page loaded signed in.

This exercised the resolver path rather than the uid-hit path D3 expected, because the
Facebook test had already moved the tester's uid. Both paths are now measured live for
Apple: the uid-hit path is what every one of the 1,521 legacy Apple users takes.

**Production hosts (D4): probed accepted before deploy (table above); browser confirmation
after deploy is a formality.**
