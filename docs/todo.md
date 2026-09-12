# Todo

## Auth

**login with apple**
The last provider not yet enabled. `config/auth_providers.json` already carries the entry
with `enabled: false`, and the registry, `PROVIDER_MAP`, the `external_provider` enum and
the icon partial are all in place — so this is a flag flip plus whatever Apple's console
requires. Watch for private-relay addresses (`@privaterelay.appleid.com`), and for the
fact that Apple sends the address only on the *first* authorization.

**fix the legacy app's client-supplied email fallback** — *time-boxed*
`the-greatest-books/admin/app/controllers/users_controller.rb:144` reads
`decoded_user_data[:email] || provider_data[:email]`, and the second half is the browser's
own form post, bound to nothing. A genuine token plus an edited `providerData[0].email`
relinks any account to the attacker's uid. Publishing the new Meta app made this easy to
reach, because every Facebook token now lacks the `email` claim the fallback keys on.
The same file also picks its JWT algorithm from the token's *unverified* header, and acts
on validation errors only when the visitor is already signed in.
Retires with the legacy site, so this is only worth doing if that slips. No CI there —
merging is deploying.

## Legacy account recovery

Both routes below serve the Facebook cohort orphaned when the old Meta app died: 17,531
rows, not one with an email on the row, none signed in since **2020-09-23**. Full detail
is in `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md` (F8, F9, D11,
D11a) — these entries are pointers, not the design.

**backfill emails from `legacy_v1_data`** — larger, simpler, no Meta involvement
12,683 addresses are recoverable from the stored V1 blob. 398 collide with an existing row
and need a merge rather than an update. Until this runs, a returning Facebook or X user
from the old cohort still lands on a new row even though the sign-in path now resolves
their address correctly — `find_user` matches against `users.email`, and theirs is NULL.

**recover the email-less cohort via Meta's Business Mapping API** — smaller, harder
**Confirmed working 2026-09-07.** Both apps are claimed by the same Business Manager, and
`GET /me?fields=ids_for_business` returns both ids — `10166754100896840` (The Greatest)
and `10160972764671840` (The Greatest (Old)), the latter being exactly what `users#42207`
holds. 4,848 rows have no address anywhere; **3,139 of them hold real saved content**
(83,231 list items between them — the remainder is empty default scaffolding).

Design constraints for whoever writes this:

- The Facebook user access token comes from `FacebookAuthProvider.credentialFromResult()`
  on the client, so it is attacker-controlled. Verify it against Facebook's `/debug_token`
  and **require the `user_id` it resolves to equal the ASID inside the Google-signed
  Firebase ID token**. That binding is what stops someone claiming a stranger's account.
- **A uid match must never outrank an email match.** Shane's own rows prove why: the
  Facebook uid matches `42207`, an empty V1 stub, while the email matches `1141`, the real
  account. Uid is a fallback, used only when the email finds nothing.
- **Do not delete the old Meta app.** It is the only thing keeping this possible.

## Data importers

- books DataImporter
- authors DataImporter
- google books integration
- goodreads import

## API

- API framework
- books admin api
- books public api
- authors admin api
- authors public api

## Books data quality

- Books Duplicate fixer
- Authors Duplicate fixer
- Invalid Book Finder
- old archived ranking configurations

## Product

- recommendations
- add list wizard
- custom user ranking configurations (paid feature)

## Growth and infra

- google ads
- google analytics
- productize cloudflare rules
- move worker to a new server
