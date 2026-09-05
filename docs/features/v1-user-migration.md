# V1 User Migration (Devise → Firebase)

Brings users from the pre-Firebase era of `thegreatestbooks.org` into Firebase
Authentication with their existing passwords, so they sign in with the password
they already have rather than being forced through a reset.

## Why hashes rather than a reset

Their bcrypt hashes are intact and unpeppered, so importing them means those
users sign in through the ordinary Firebase flow. The legacy site instead had a
bespoke endpoint that decrypted the old password server-side and created a
Firebase account on the fly — an endpoint anyone who knew an email address
could drive. Importing removes the endpoint rather than reimplementing it more
carefully.

## The cohort

Measured 2026-09-05. Recount before every real run; these move.

| | count |
|---|---:|
| Legacy v1 cohort (unmigrated, no provider, has password, has email) | 30,463 |
| − already hold a Firebase uid | 30 |
| − malformed email (`@gmail` with no TLD, `@gmailcom`, `@123`) | 46 |
| **= exported, and given an `auth_uid`** | **30,387** |

The **30 already-linked** are excluded because Firebase's import API does not
check email duplication: importing them would create a *second* account for the
same address holding their 2014 password, and a password reset across two
identities is ambiguous. They already have a working way in. Note these are
active people — sign-in counts up to 120 — so the frequently repeated claim
that this cohort "has zero sign-ins in two years" is not literally true.

The **46 malformed** addresses are signup typos that were never deliverable.
They are skipped and reported, **never repaired**: inferring `gmail.com` from
`gmail` would create an account at an address the user does not control, which
is the exact takeover shape this project exists to remove.

`FirebasePasswordExport.exportable_ids` is the single definition of that set,
and `FirebaseUidBackfill` uses it as its cohort, so the file and the write-back
cannot disagree about who is being migrated.

## Running it

Order matters: **import before backfill**, so `auth_uid` never names a Firebase
identity that does not exist yet.

```bash
# 1. Export (path MUST be outside the repository -- it is 30,387 password hashes)
bin/rails "firebase:export_v1_passwords[$HOME/v1-firebase-import.json]"

# 2. Import (owner runs this locally; no service account belongs in the app)
npx firebase-tools auth:import "$HOME/v1-firebase-import.json" \
  --hash-algo=BCRYPT --project the-greatest-books

# 3. Backfill the derived uids
DRY_RUN=1 bin/rails firebase:backfill_v1_uids   # preview
bin/rails firebase:backfill_v1_uids

# 4. Delete the export file
shred -u "$HOME/v1-firebase-import.json"
```

`firebase-tools` needs `firebase login` first
(`curl -sL https://firebase.tools | bash` if the CLI is absent).

The export refuses any path inside this repository, and writes `0600` — it
chmods explicitly, because `File.open`'s creation mode is ignored when the file
already exists and these steps are re-run.

## Rehearsing it

Two canaries, and they prove different things. Both were run against the real
production Firebase project on 2026-09-05 and both passed.

```bash
# Proves the hash encoding and replace-in-place. Import it TWICE.
bin/rails "firebase:canary[$HOME/canary.json,you+v1@gmail.com,a-password-you-pick]"

# Proves the path real users take: uid matches an EXISTING row.
bin/rails "firebase:canary_for_user[$HOME/c.json,<a synthetic users.id>,a-password]"
```

`firebase:canary` uses the fixed uid `tgbv1-canary`. That is deliberate: the uid
must be *identical* across runs for "import twice, see one account" to prove
anything, and a non-numeric suffix cannot collide with any real `tgbv1-<id>`.

But it therefore matches no `users` row, so it can only exercise **account
creation**. `firebase:canary_for_user` covers the path the 30,387 actually take:
`auth_uid` pre-seeded on an existing row, so step 1 of
`UserAuthenticationService#find_user` matches by uid and the user lands on their
own data. It refuses any id in the legacy cohort, any row already holding a
different uid, and any path inside the repo.

What both canaries confirmed:

- `passwordHash` must be **base64url without padding** — this is what
  `auth:import --hash-algo=BCRYPT` accepts. Confirmed empirically, not from docs.
- A colliding `localId` **replaces** rather than duplicating.
- A pre-seeded `auth_uid` links to the existing row: one row, data intact, no
  new account. `emailVerified` is `false` on imported accounts, so the uid match
  is provably the only door — the email branch refuses an unverified address.

**Untested: scale.** One record is not 30,387.

## The uid

`tgbv1-<legacy_id>`, defined once in
`Services::BooksMigration::FirebasePasswordExport.uid_for`. The exported
`localId` and `users.auth_uid` both derive from it, so the backfill is
idempotent and environment-independent — it recomputes rather than reading the
export file.

This works only because `Services::BooksMigration::UserMigrator` upserts
`unique_by: :id`, so `LegacyBooks::User#id` and `User#id` are the same integer.
The backfill asserts this and **aborts** if any cohort id has no new-table row,
rather than skipping it — a skipped row is a user who silently cannot sign in.

## Re-running it

All of it is designed to be re-run, because the whole data migration is
rehearsed against production more than once before books launches. Truncating
resets `users.auth_uid`, so the backfill is re-run after **every** pass.

Two things about the Firebase import specifically:

1. **Replace is total**, so it overwrites whatever an account has become — a
   changed password, a verified email — back to the 2014 hash and
   `emailVerified: false`. **Once books is live and real people have used these
   accounts, the import must not be re-run.** Export and backfill stay safe.
2. **The accounts are reachable from the moment they are imported**, not from
   books launch. `firebase_auth_service.js` hardcodes
   `projectId: "the-greatest-books"` and varies only `authDomain`, and the auth
   widget renders in all four layouts — so a cohort member can sign in, or
   trigger a forgot-password email, on the **live** music and games sites. The
   owner weighed this and accepted it: an idempotent step that is never
   exercised is worth nothing, and a 30,387-row import performed for the first
   time at launch is the larger risk.

If id stability ever broke, the failure would be **silent** — the import API
skips email-duplication checks, so different ids would yield a second account
per user rather than an error.

## Domains

Reset and verification emails carry an `actionCodeSettings` continue URL derived
from `window.location.origin`, so a reader who resets on games is sent back to
games rather than to the project-wide default (a books URL).

**Every domain this can produce must be on Firebase's authorized-domains list**,
or the SDK rejects the call with `auth/unauthorized-continue-uri` — and because
the UI deliberately shows the same message on success and failure, that failure
is invisible to the user. `e2e/tests/books/email-auth.spec.ts` watches
`console.error` for exactly this, since the DOM cannot distinguish it.

## Who is not covered

| Cohort | Count | Why |
|---|---:|---|
| No email address at all | 20,063 | v1 Facebook/Twitter logins. Unreachable by any email flow; needs those providers implemented |
| Malformed email | 46 | Never deliverable, and repairing an address would create an account the user does not control |
| Already hold a Firebase uid | 30 | Already have a working sign-in; importing would give them a duplicate identity |

Anyone not imported still has a route: **Create account** with the same address
sets a password, sends a verification email, and links to their existing row
through the verified-email branch of the linking rule. The failed-sign-in
message points there, shown identically to everyone so it leaks nothing about
which addresses exist.
