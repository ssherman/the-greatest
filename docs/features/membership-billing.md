# Membership & Stripe Billing

**Setting up the live Stripe account is a separate document:** `docs/guides/stripe-account-setup.md`
covers the by-hand Dashboard and Cloudflare steps — registering the two webhook endpoints,
labelling the live prices, activating the Billing Portal, and the post-deploy verification and
rollback plan. This document covers how the shipped subsystem itself works.

## 1. What it is

One membership, sold through Stripe, that unlocks paid features across all three active domains
(books, music, games — movies is out of scope for this feature). A user has at most one *active*
paid relationship per domain concept, but the underlying data model allows several rows per user
(see [The three membership sources](#3-the-three-membership-sources) below).

Four tables carry the whole feature:

| Table | What it holds |
|---|---|
| `memberships` | The single source of truth for "is this person a member?" — one row per grant, `source` = `stripe` / `comped` / `legacy`. Replaces the legacy app's `Subscription` model and its `users.paid` boolean. |
| `stripe_events` | The raw webhook inbox. Forensic evidence only — see the core idea below. Never read to decide state. |
| `billing_plans` | The price catalogue (`key`, `stripe_price_id`, `amount_cents`, `interval`, `kind`: `membership` or `donation`). Replaces the legacy app's hand-edited `config/stripe_products.yml`. |
| `donations` | One-time payments, recorded from `checkout.session.completed` / `checkout.session.async_payment_succeeded` in payment mode or imported from the legacy database. |

Admin screens for all four live under `/admin` (books-admin-only in the sidebar's Billing
section, gated on `current_user.admin?` — editors do not see it):

- `/admin/memberships` — list, filter, comp a new one, view/edit/revoke/attach
- `/admin/donations` — read-only list (donations are payment history; nothing about a completed
  payment is editable from a form)
- `/admin/stripe_events` — list, filter by status, view a full payload, re-run
- `/admin/billing_plans` — edit display fields only (`name`, `position`, `active`); the Stripe-owned
  fields (`stripe_price_id`, `stripe_lookup_key`, `amount_cents`, `key`, `interval`) are not in the
  form at all

## 2. The core idea: webhooks are signals, never data

The design decision that everything else follows from: **a Stripe webhook event is never read for
state.** It is read for exactly one thing — a customer id — which triggers a full re-read of that
customer's subscriptions from the Stripe API.

```
Stripe  --POST-->  Webhooks::StripeController#create
                      1. verify the signature (Stripe::Webhook.construct_event)
                      2. insert the raw event as a StripeEvent row (status: received)
                      3. return 200
                      4. enqueue Billing::ProcessStripeEventJob

Billing::ProcessStripeEventJob#perform
  1. extract ONLY event.stripe_customer_id_from_payload  <-- the one thing read from the payload
  2. Services::Billing::ReconcileCustomer.call(stripe_customer_id:)

Services::Billing::ReconcileCustomer#call
  1. BEGIN a transaction
  2. pg_advisory_xact_lock(hashtext(customer_id))   -- serializes concurrent reconciles for
                                                         this one customer; auto-releases on
                                                         commit or rollback
  3. Stripe::Subscription.list(customer: customer_id, status: "all")   -- re-read from Stripe,
                                                                           not from the event
  4. upsert a Membership row per subscription, matched on stripe_subscription_id
  5. COMMIT
  6. (outside the transaction, once committed) notify: enqueue whichever membership
     email, if any, each transition earns -- see below and docs/features/email.md
```

Because no event payload is ever written as membership state, **delivery order cannot matter.** A
`customer.subscription.created` that arrives after the `invoice.paid` that superseded it just
triggers a redundant reconcile that converges on the same rows Stripe currently reports. There is
no "last write wins" bug to have, because nothing is written from an event body in the first
place.

**`upsert` returns a `Services::Billing::MembershipTransition`, not a bare `Membership`, on every
path — including the comped-row collision guard's early return.** `Membership#status` gets
overwritten by `assign_attributes`, so `upsert` captures it first (`nil` for a brand-new row) and
wraps the saved `Membership` together with that `previous_status` in a `MembershipTransition`
value object. `previous_status` is captured because `assign_attributes` is about to overwrite it —
that's the entire reason the class exists. It is **not**, any more, how
`Services::Billing::MembershipNotifier` decides whether an email is owed:
`MembershipTransition#became_active?`, `#became_canceled?` and `#status_changed?` were deleted
outright (`membership-email-recovery` branch), because a status transition is observable exactly
once, and `upsert` commits the new `status` before the notifier ever runs — so a failed mail
enqueue (Redis unavailable, say) could roll the once-only stamp back while the status stayed
committed, leaving the email owed forever with nothing left able to see that it was owed. The
notifier now reads the membership's own `welcome_email_sent_at`/`ended_email_sent_at` columns
instead, which are durable; see `docs/features/email.md`'s "Durable eligibility, not
transition-driven" for the full mechanism. `MembershipTransition` itself survives, `previous_status`
and all, purely as the **uniform return type** every caller can rely on: `ReconcileCustomer#call`
collects one per subscription into `Result#data` and runs each through the notifier after its own
transaction has committed, never inside it; the comped-row guard's early return yields a **no-op**
`MembershipTransition` (`previous_status` set to the row's own current `status`) rather than a bare
`Membership`, specifically so a caller that calls `#membership` on every element of `Result#data` —
which the notifier's `initialize` does, and so does `ReconcileCustomer#call`'s own per-transition
error log — never has to special-case the one path where nothing actually changed. That path is not
theoretical: 127 rows in production predate the `stripe_subscription_id` absence validation (§8)
and can reach it.

**`current_period_end` and `cancel_at_period_end` are each read from more than one Stripe field, and
both learned that the hard way.** Basil (2025-03-31) moved `current_period_end` off the subscription
onto the subscription item; `upsert` reads `subscription.items.data.first.current_period_end`, not
the deprecated subscription-level accessor, which still resolves today but will stop working
without warning. `cancel_at_period_end` moved too, more recently: Stripe's Billing Portal stopped
setting `subscription.cancel_at_period_end` for a period-end cancellation and now expresses the
same fact only as a `cancel_at` timestamp. **Verified live on 2026-08-22** — a real portal
cancellation returned `cancel_at_period_end: false`, `cancel_at` equal to `current_period_end`, and
`canceled_at` at the moment the member clicked cancel. `upsert` now writes
`cancel_at_period_end: subscription.cancel_at_period_end.present? || subscription.cancel_at.present?`
— reading both signals, since either one establishes that a cancellation is scheduled; reading only
the boolean had left the column permanently `false`, so `/membership` told a member who had just
cancelled that their membership renews. **This is the second time a Stripe field has moved under
this subsystem, and no offline test can catch the next one** — the test suite stubs the shape
Stripe is expected to return, so a further silent change would pass every existing test while
writing the wrong column in production. The guard against a third occurrence is operational, not
automated: see `docs/guides/stripe-account-setup.md`'s post-deploy verification, which cancels a
real sandbox subscription and reads `/membership`'s copy back to confirm it changed.

The same `ReconcileCustomer` call is reused for three purposes with one implementation:

1. the webhook path above (one customer, triggered by an event)
2. the initial legacy data migration (`data_migration:memberships` seeds `source: :legacy` rows
   separately, but `billing:reconcile_all` is what builds every `source: :stripe` row from scratch)
3. the nightly drift-check sweep (`Billing::ReconcileAllCustomersJob`, scheduled for 05:00 UTC),
   and the manual recovery path if the webhook endpoint is ever down past Stripe's 72-hour retry
   window, after which the events themselves are gone for good

**`test/sidekiq/billing/process_stripe_event_job_test.rb` contains a permutation test** —
`"every permutation of subscribe-time events converges on the same state"` — that feeds every
possible ordering of a subscription's create/checkout/invoice events through the real job and
asserts the resulting `Membership` row is identical regardless of order. This test is the thing
that guards the "webhooks are signals, never data" design claim. **It must never be "optimised
away"** — if a future change makes it slow or seems redundant with a narrower unit test, the fix
is to make it faster, not to delete it. It is the one test in the suite that would catch a
regression back to "write state from the payload."

## 3. The three membership sources

`Membership#source` is an enum: `stripe: 0`, `comped: 1`, `legacy: 2`.

- **`stripe`** — owned by the reconciler. Every field is rewritten by `ReconcileCustomer` on every
  webhook and every nightly sweep. **Never hand-edit a `source: stripe` row** — the admin UI
  refuses to render an edit form for one (`Admin::MembershipsController#editable?` returns false),
  and even if you patched the database directly, the next sweep (at most 24 hours later, or
  immediately on the next webhook for that customer) would overwrite it back to whatever Stripe
  says. To change a Stripe-sourced membership, change it in the Stripe dashboard and let the
  reconciler pick it up — or trigger it immediately by re-running the relevant event
  (§7) or `rake billing:reconcile_all`.
- **`comped`** — an admin grant, created at `/admin/memberships/new`. Has no `stripe_subscription_id`
  (the model's `absence` validation enforces this for any non-`stripe` row), which is what makes a
  comped membership *structurally* unreachable from the reconciler: `ReconcileCustomer#upsert` finds
  rows by `stripe_subscription_id`, so a row that can never hold one can never be found there. This
  is enforced by a model validation on every write path in `app/` — **not** a database `CHECK`
  constraint — see the comment above the `absence` validation in `app/models/membership.rb`, and
  "Known limits" (§8) below for what that means for a write path outside `app/`, such as raw SQL.
- **`legacy`** — imported early supporters (`users.paid == true` in the legacy books database, none
  with a Stripe row of their own at the time of import). Never expires — a legacy grant is
  permanent by design, distinct from a comp's optional expiry date.

**A user may legitimately hold both a `stripe` row and a `legacy` row.** In production, 6 early
supporters also pay through Stripe today. This is expected, not a bug: a legacy grant doesn't get
revoked just because the same person later subscribes for real. If you see two membership rows for
one user in the admin — one `legacy`, never-expiring, one `stripe`, actively syncing — that is the
overlap case working as designed, not data corruption. `billing:verify_migration` reports the full
list of such users under "Early supporters who also pay through Stripe" every time it runs, so it
is always visible rather than something you have to go looking for.

## 4. Rake tasks

| Task | What it does | When to run it |
|---|---|---|
| `billing:reconcile_all` | Runs `Services::Billing::ReconcileAllCustomers` — lists every subscription in the Stripe account, dedupes to distinct customer ids, and reconciles each one. One customer failing never aborts the rest; failures are collected and printed. | The initial build of every `source: :stripe` membership row, and the manual recovery path if the webhook endpoint was down long enough that Stripe stopped retrying (>72 hours). Safe to re-run any time — it's the same idempotent reconcile the nightly sweep runs. |
| `billing:replay_failed` | Re-enqueues `Billing::ProcessStripeEventJob` for every `stripe_events` row currently in the `failed` state, oldest first. | After you've fixed whatever made a batch of events fail (a Stripe outage, a bad deploy) and want to clear the backlog in bulk instead of re-running events one at a time from the admin UI. |
| `billing:verify_migration` | Runs `Services::Billing::VerifyMigration` — checks four invariants between the legacy books database and the new one: every legacy `stripe_subscription_id` has a matching `Membership`, every legacy `paid: true` user with a row in the new `users` table has a `source: :legacy` grant, every legacy donation was imported, and reports (never fails on) unattached memberships and stripe+legacy overlap users. **Exits non-zero if any of the first three invariants has a gap.** | After running the two `data_migration:` tasks below, and any time you want to sanity-check that the legacy and new data agree. Read below for what a non-zero exit means. |
| `billing:verify_migration` (`unmigrated_users`) | The separate, never-failing category: a legacy `paid: true` user with **no row at all** in the new `users` table yet. This is expected drift from the live legacy database, not a migration gap — `MembershipMigrator` skips these users by design, so counting them against `missing_grants` would make the task cry wolf on every run. | Reported every run; remedy is `data_migration:users`, then re-run `billing:verify_migration` to confirm the gap closed. |
| `data_migration:memberships` | Runs `Services::BooksMigration::MembershipMigrator` — imports every legacy `users.paid: true` row as a `source: :legacy` Membership. `find_or_initialize_by`-based, so it never creates a duplicate row — but re-running is **not** consequence-free: every run converges the row onto the current legacy `paid` flag, so if an admin revoked a legacy grant in `/admin/memberships` and the legacy flag is still `true`, re-running restores it. See §5 for the remedy. | Once, as part of the legacy-history import (§5). |
| `data_migration:donations` | Runs `Services::BooksMigration::DonationMigrator` — imports the legacy `donations`-equivalent table into `donations`. Idempotent, safe to re-run. | Once, as part of the legacy-history import (§5), immediately after `data_migration:memberships`. |
| `stripe:bootstrap` | Runs `Services::Billing::BootstrapPlans` — creates a sandbox membership product with monthly/yearly prices plus a donation price, and seeds/updates the matching `billing_plans` rows. **Refuses hard when `STRIPE_LIVEMODE=true`** — production sells through legacy's existing prices, never products this task would create. | Local dev and disaster recovery in a **sandbox** only. Never run against the live account — see §11. |
| `stripe:sync_plans` | Runs `Services::Billing::SyncPlans` — re-resolves every `billing_plans` row's `stripe_price_id`/`amount_cents`/`currency`/`interval` from its `stripe_lookup_key`, against whichever Stripe account this environment's keys point at. Fails loudly (and leaves the existing id alone) for a lookup key that resolves to nothing. | After bootstrapping a sandbox, after labelling a live price (`stripe:label_price`) or creating the donation price (`stripe:create_donation_price`), or any time you want to confirm the catalogue still resolves. |
| `stripe:label_price[price_id,lookup_key]` | Runs `Services::Billing::LabelPrice` — writes a `lookup_key` onto an **existing** Stripe price via `Stripe::Price.update`, without `transfer_lookup_key`, so it refuses rather than silently moving a key already in use elsewhere. Requires `CONFIRM=label-price` — it writes to whatever account the keys point at, live included. Prints the amount/currency/active state before and after so the "label-only, nothing else changed" claim is verifiable, not asserted. | Once per live membership price, as part of `docs/guides/stripe-account-setup.md`. Safe to re-run (idempotent on the same key). |
| `stripe:create_donation_price` | Runs `Services::Billing::CreateDonationPrice` — creates a **new** product and a custom-amount price (`donation_custom`), purely additive. Requires `CONFIRM=create-donation-price`. | Once, live and in the sandbox, as part of `docs/guides/stripe-account-setup.md`. Running it again creates a second product+price — it is not idempotent, unlike the tasks above. |

See `docs/guides/stripe-account-setup.md` for the full, in-order production runbook these four
tasks are part of — including why `stripe:bootstrap` must never run against the live account, and
what the two live-price and one live-donation-price writes actually change.

## 5. Runbook: importing legacy history

This is a one-time operation, run once in production after the code is deployed.

**Schema migrates itself — for the `web` container only.** `bin/docker-entrypoint` runs
`db:prepare` whenever the command it's given contains `rails server`, so the `web` container
migrates the schema (including the `memberships` uniqueness index) automatically on every deploy.
The `worker` container runs `bundle exec sidekiq`, which does not match that check, so it never
runs `db:prepare` itself. `docker-compose.prod.yml` gives `worker` a plain `depends_on: [redis,
web]` with no health-check condition, so `docker compose up -d` starts both containers at roughly
the same time with nothing guaranteeing the web container's `db:prepare` has finished before
Sidekiq starts pulling jobs off the queue. In practice this means there is a window during every
deploy where a Sidekiq job can run against a schema mid-migration. For this feature set the
exposure is small — the only migration in play adds an index and no new column, and
`ReconcileCustomer` does not depend on that index existing — but any future change that adds a
column a job reads inherits this same window, and is worth remembering when planning a deploy.

**The three data tasks are manual.** Run them by hand, in the web container, in this exact order:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails data_migration:memberships
docker compose -f docker-compose.prod.yml exec web bin/rails data_migration:donations
docker compose -f docker-compose.prod.yml exec web bin/rails billing:verify_migration
```

Order matters: `verify_migration` reports on both memberships and donations, so running it before
the imports just tells you what you already knew was missing.

On a first, clean run, expect roughly 28 legacy memberships imported and 21 donations. Note that
`data_migration:memberships` also prints `legacy_paid_minus_legacy_memberships`, which is
informational, not a gap count: it goes positive for a legacy paid user with no `users` row yet
(expected drift, not an error) and goes negative once a legacy `paid` flag is later cleared after
import. Don't chase it toward zero — `billing:verify_migration` below is the authoritative,
by-id breakdown of what's actually missing, if anything.

**`billing:verify_migration` exits non-zero if any legacy record has no counterpart.** Do not treat
a non-zero exit as "run it again and hope." The task prints the actual list of offending ids under
each failing category (`missing_subscriptions`, `missing_grants`, `missing_donations`) — the
signal is to **read those ids** and find out why each one didn't migrate. For `missing_grants`
specifically, a user missing from the new `users` table is **not** the cause — that case is split
out into `unmigrated_users`, which is reported separately and never fails the run (§4). A non-zero
exit on `missing_grants` means the opposite: the user **does** exist in `users`, but the importer
still created no `source: :legacy` row for them — a genuine migration gap worth investigating, not
expected drift. Re-running never creates a duplicate row (both importers are
`find_or_initialize_by`-based) and will reproduce the exact same gap if the underlying cause hasn't
changed. For `data_migration:memberships` specifically, re-running is not otherwise
consequence-free: see the table above — it also restores any legacy grant an admin revoked in
`/admin/memberships`, as long as the legacy `paid` flag is still `true`. The remedy for a revoke
that must survive a re-run is to clear `paid` on the legacy user, not to run the importer again.

Unattached memberships, `unmigrated_users`, and the legacy/Stripe overlap are reported by the same
task but never cause the non-zero exit — they're expected outcomes, not errors. Work through
unattached ones with the runbook in §6; `unmigrated_users`' remedy is `data_migration:users` (§4);
the overlap list is informational only (§3).

## 6. Runbook: an unattached membership

An **unattached membership** is a `Membership` row with `user_id: nil` — Stripe reports a customer
and a subscription, but `ReconcileCustomer#resolve_user` could not match it to anyone in the
`users` table (neither by `users.stripe_customer_id` nor by an `app_user_id` value in the Stripe
customer's metadata). This happens for subscriptions created outside the app's own checkout flow —
by the legacy books app before the cutover, or by hand in the Stripe dashboard.

**Find them:** `/admin/memberships?attached=false`, or follow the "Review them" link in the banner
that appears at the top of `/admin/memberships` whenever `@unattached_count > 0`.

**Attach one:**

1. Open the membership's detail page (`/admin/memberships/:id`). It shows the Stripe customer id,
   subscription id, status and plan — everything you have to work with to figure out who this is.
2. **Confirm the person's identity yourself** — look them up on the users page, cross-reference
   whatever out-of-band information you have (a support ticket, a name on the Stripe dashboard,
   etc.).
3. Enter their **user id** (not their email) into the "Attach to a user" form and submit.

**This flow is never matched by email, on purpose — enter a user id, not an email address.**
Inferring identity from an email address is exactly how one person gets handed another person's
paid membership: email addresses can be typo'd, reused, or simply wrong in Stripe's copy of the
data, and a program that "helpfully" auto-matches on it has no way to know when it just merged two
different people. Requiring a human to look at both records and type a specific numeric id is the
deliberate friction that prevents that failure mode. The controller (`Admin::MembershipsController
#attach`) enforces this structurally too: it only ever reads `params[:user_id]`, does a hard
`User.find_by(id: ...)`, and refuses (redirects with an alert) if the membership is already
attached — an admin cannot use `attach` to move a membership from one user to another, only to fill
in a blank.

Once attached, if the user's own `stripe_customer_id` column was blank, it gets backfilled from the
membership's Stripe customer id (only when blank — never overwriting an existing value). That makes
the fix durable: the next reconcile for that customer will resolve the user directly via
`User.find_by(stripe_customer_id:)` without needing the metadata fallback or another manual attach.

## 7. Runbook: a failed Stripe event

A `stripe_events` row moves to `status: failed` when `Billing::ProcessStripeEventJob` raised —
most often because `ReconcileCustomer` hit a `Stripe::StripeError` (a transient API problem, rate
limiting, or a genuine "no such customer"/auth error) or because reconciling produced a record that
failed a model validation.

**Find them:** `/admin/stripe_events?status=failed`, or the "Review them" banner on
`/admin/stripe_events` whenever `@failed_count > 0`.

**Diagnose one:** open the event's detail page (`/admin/stripe_events/:id`). The **Error** field
holds the exception class and message (`StripeEvent#mark_failed!` deliberately stores only that —
never the payload — because a payload carries customer email, name, address and card last-four,
and this repository is public). The rest of the page shows the event type, customer id, live/test
mode, and attempt count, which is usually enough to tell whether this is "Stripe was briefly down,
just retry" or something that needs an actual code fix.

**Re-run it:**

- One at a time, from the detail page: the "Re-run this event" button
  (`POST /admin/stripe_events/:id/reprocess`) re-enqueues the job. Available for any event in
  `received` or `failed` status; the controller refuses (with a message naming the current status)
  for anything else, because re-running a `processed` or `ignored` event is meaningless.
- In bulk: `rake billing:replay_failed` re-enqueues every currently-`failed` event, oldest first.

Either way, re-running just re-triggers a `ReconcileCustomer` call for that event's customer id —
it does not replay the original payload as data, consistent with the core design in §2. If the
underlying cause was transient (Stripe was briefly unreachable), the re-run succeeds and the event
moves to `processed`. If the cause is systemic, `rake billing:reconcile_all` will fix every affected
customer in one pass rather than replaying events one at a time.

## 8. Known limits

These are accepted trade-offs, not oversights — still true as of this writing, carried forward from
the spec:

- ~~`origin_domain` is never written by the reconciler.~~ **Resolved**, by the membership-emails
  increment. `upsert` now assigns `origin_domain: subscription.metadata&.[]("origin_domain")`
  unconditionally on every reconcile, not just at checkout: `CreateCheckoutSession` stamps
  `origin_domain` into the subscription's Stripe metadata once, at creation, and every later
  reconcile — webhook-triggered or the nightly sweep — reads it back from Stripe rather than from
  whatever this app wrote last time. Unconditional cuts both ways on purpose: if the metadata key
  ever disappears upstream, the local column clears too, rather than sticking at a stale value (a
  `subscription.metadata&.[]("origin_domain") || membership.origin_domain` "keep whatever we already
  had" form was considered and rejected — it would silently keep emailing about a membership whose
  ownership signal Stripe no longer reports; see the "clears origin_domain when it disappears…"
  test in `reconcile_customer_test.rb`). Every row that predates checkout entirely — including
  everything built by the original `billing:reconcile_all`/the legacy-history import, before this
  metadata tag existed — still has `origin_domain: nil` and always will, since there is no Stripe
  metadata to backfill it from. The admin detail page shows "Unknown" for these rather than
  guessing, and `Membership#sold_by_this_app?`/`MailBranding.for(nil)`'s books fallback both treat
  that `nil` as the expected, permanent case it is — see §13 below.
- **`ReconcileAllCustomers` reports `success?: true` even when every individual customer failed to
  reconcile**, as long as at least one customer succeeded. The service only reports failure when
  *zero* customers reconciled out of a non-empty set (the "Stripe is down / credentials are wrong"
  signature that's worth retrying the whole sweep for). A run where 40 of 41 customers failed for
  40 unrelated reasons still reports `success?: true`; the only place that shows up is the
  per-customer `Rails.logger.error("[billing] sweep could not reconcile ...")` line for each one.
  If you run `rake billing:reconcile_all` by hand, read the printed `Failed:` count and the listed
  ids — do not assume a clean exit code means a clean sweep.
- **Both Stripe API calls happen inside the transaction holding the advisory lock.**
  `ReconcileCustomer#call` opens a Postgres transaction, takes `pg_advisory_xact_lock`, and only
  then calls `Stripe::Customer.retrieve` and `Stripe::Subscription.list` — both of which are
  network calls to Stripe's API. A slow or hanging Stripe response pins an open database connection
  and the advisory lock for that entire time. Under normal conditions this is milliseconds; under a
  Stripe-side slowdown, it can exhaust the Postgres connection pool.
- **The `stripe_subscription_id` absence rule is a model validation, not a database constraint.**
  `validates :stripe_subscription_id, absence: true, unless: :source_stripe?` in `app/models/membership.rb`
  runs on every ordinary `app/` write path, but it does not apply to `update_column`, `insert_all`,
  or `save(validate: false)`, and it does not retroactively clean up rows written before the
  validation shipped (127 of them in production, predating this branch). `ReconcileCustomer#upsert`'s
  defensive `return unless membership.stripe?` guard — see the comment on
  `test/lib/services/billing/reconcile_customer_test.rb`'s "does not modify a persisted non-stripe
  row whose id collides with an incoming subscription" test — is what actually stops a webhook from
  touching one of those legacy-shaped rows; the validation alone does not.
- **`users.stripe_customer_id` has a non-unique index, not a unique constraint.** If two user rows
  were ever given the same `stripe_customer_id` (by a bug, a bad manual edit, or a race), then
  `ReconcileCustomer#resolve_user`'s `User.find_by(stripe_customer_id:)` becomes nondeterministic —
  which of the two rows it returns is whatever Postgres happens to return first, and that could
  flip between reconciles. Nothing in the current code enforces or checks the uniqueness this
  implicitly relies on.
- ~~`Membership.granting_access` is referenced by comments but does not exist yet.~~ **Resolved.**
  It shipped with the entitlements increment — see §9. `Admin::MembershipsController#revoke`'s
  claim that it "ends access immediately" is now accurate: `User#member?` and every paywall check
  read `Membership.granting_access` live, so revoking a row (or letting a comp's
  `current_period_end` pass) changes what the very next request sees.

## 9. Entitlements: who counts as a member

`User#member? = memberships.granting_access.exists?` (`app/models/user.rb`) is the one method
every paywall check ultimately calls. It is a single `exists?` query against one scope,
`Membership.granting_access` (`app/models/membership.rb`), which encodes three rules that look
similar but exist for different reasons — see the spec's "Entitlement" section before changing any
of them:

1. **`source: :stripe`, status `active` or `trialing`** — grants **without checking the date**.
   Stripe's status is authoritative and this app's copy of `current_period_end` can be stale, so
   checking it here could only ever produce a false denial for someone who is actually paying.
2. **`source: :stripe`, status `canceled`, `current_period_end` in the future** — the paid-through
   grace period. A cancelled subscription still grants access until the period it was already paid
   for runs out.
3. **`source: :comped`/`:legacy`, status `active`, `current_period_end` null or in the future** — a
   comp or legacy grant has no Stripe status to trust, so it must be both `active` *and* unexpired.
   `nil` means "never expires" (every `:legacy` row, and a comp with no expiry set); a comp with a
   past `current_period_end` does **not** grant access, even though its `status` column still reads
   `active` — nothing flips that column when a comp lapses, `granting_access`'s date filter is what
   actually denies it.

`User#granting_membership` (`app/models/user.rb`) returns the actual row —
`memberships.granting_access.order(:source, current_period_end: :desc).first` — for anywhere the
UI needs to *show* the membership (plan, renewal date), not just gate on its existence. Both
`/membership` and `/members` call it; `GET /membership_state` (§12) returns its `interval` and
`current_period_end` as JSON for edge-cached pages.

**A user can hold more than one granting row** (§3's Stripe+legacy overlap is the production
example) — `member?` only cares whether *any* row grants, and `granting_membership` picks the most
relevant one to display, not "the" membership, because there can legitimately be more than one.

## 10. `MembershipGate`: putting a feature behind the paywall

`MembershipGate` (`app/lib/membership_gate.rb`) is a plain module holding one frozen hash,
`FEATURES`, mapping a feature key to a human-readable description:

```ruby
FEATURES = {
  members_area: "The members' area at /members"
}.freeze
```

It is deliberately a registry, not an abstraction layer — its entire value is that a reviewer can
read one small file and know the complete answer to "what is behind the paywall?" Two entry
points:

- `MembershipGate.members_only?(:some_feature)` — a boolean, for view-level checks (e.g. showing or
  hiding a nav link).
- The `MembershipGated` concern (`app/controllers/concerns/membership_gated.rb`) — include it in a
  controller and add `before_action -> { require_membership!(:some_feature) }`. A non-member gets
  redirected to `/membership` (never a bare 403) with a message tailored to whether they're signed
  in at all; a member falls through untouched.

**To put a new page or action behind the paywall:**

1. Add its key to `MembershipGate::FEATURES` with a short description.
2. `include MembershipGated` in the controller, and add the `before_action` calling
   `require_membership!(:your_key)`.

`require_membership!` calls `MembershipGate.validate!` first, which **raises `UnknownFeature`** for
any key not in the hash. That's deliberate: a typo'd feature key becomes a loud exception in
development and in test, never a page that silently gates nothing (a typo resolving to a falsy
`members_only?` check) or silently gates everything (a stray `before_action` with no matching
entry). `MembersController` (`app/controllers/members_controller.rb`) is the reference
implementation — the first and, as of this writing, only gated surface.

Both nested under `Membership`/`MembershipGate` at the top level rather than
`Membership::Gate` on purpose: inside a `Membership` namespace a bare `Membership` constant
resolves to the *module*, not the model — the same constant-shadowing trap that has bitten
`Search::`, `Services::BooksMigration`, and `ItemRankings::` in this codebase before.

## 11. Checkout and donations: the write path to Stripe

**Nothing here accepts a price, an amount, or a user id from the client — only a plan `key`.**
`MembershipController#checkout` (`app/controllers/membership_controller.rb`) looks the key up
against `BillingPlan.membership.active`; a request that also supplies `stripe_price_id`,
`customer_id`, `user_id`, `success_url` or `cancel_url` has every one of those ignored — see the
controller test `"checkout ignores a price id, customer id, user id, success url and cancel url
supplied by the client"`. A client that could name a price could name a one-cent one.

The flow, `POST /membership/checkout` for a signed-in visitor:

1. **Already a member?** Redirected — to the portal (below) if they have a `stripe_customer_id`
   (an existing Stripe subscriber trying to buy a second one), or back to `/membership` with a
   thank-you notice if they don't (a comped/legacy member, who has no billing account to manage
   here and shouldn't see "there is no billing account attached" as if it were an error).
2. **`Services::Billing::EnsureCustomer.call(user:)`** (`app/lib/services/billing/ensure_customer.rb`)
   — finds the user's existing `stripe_customer_id`, or creates a Stripe Customer and **writes the
   id back to the user in this same request**. That write is the point of the service: it makes the
   user↔customer link exist *before* any webhook for the coming subscription can possibly arrive,
   which is why `ReconcileCustomer` needs no "recover the user from the checkout session" fallback
   the way legacy's handler does.
3. **`Services::Billing::CreateCheckoutSession.call(plan:, user:, customer_id:, domain:, ...)`**
   (`app/lib/services/billing/create_checkout_session.rb`) — the **only** call site in the app
   allowed to call `Stripe::Checkout::Session.create`. `test/lint/stripe_checkout_session_call_sites_test.rb`
   scans every `.rb` and `.rake` file under `app/` and `lib/` (so `lib/tasks/*.rake` is covered, not
   just app code) and fails the build on a second
   `Stripe::Checkout::Session.create` call site anywhere, *and* on any reference at all to
   `Stripe::PaymentLink` — this app must never create one, because legacy's coexistence guard
   structurally assumes it never does (see the spec's "Legacy coexistence"). It stamps
   `metadata[origin_app] = "the-greatest"` on **every** session it creates, both membership and
   donation, plus `subscription_data[metadata][origin_app]` on membership sessions specifically —
   both are load-bearing for legacy's webhook guard, not just informational.
4. The controller redirects (`303 see_other`, `allow_other_host: true`) straight to the returned
   `checkout.stripe.com` URL.

**`success_url`/`cancel_url` are never built from `request.host`.** `canonical_host` in
`MembershipController` reads `Rails.application.config.domains[Current.domain]` instead, because
nginx forwards the client's raw `Host` header verbatim and `config.hosts` is unset in production —
see `docs/guides/stripe-account-setup.md`'s "Ops follow-ups" for why that's still worth fixing
separately. A forged `Host` header cannot make this app mint a real Stripe-branded checkout link
pointing anywhere but a real site.

**Donations** (`POST /membership/donate`) reuse the same `CreateCheckoutSession` service in
`mode: "payment"` with `submit_type: "donate"`, against the single `kind: :donation` plan (a
`custom_unit_amount` price: $1 minimum, $25 preset — see `Services::Billing::CreateDonationPrice`).
Donations are open to signed-out visitors; Stripe collects the email at checkout, and no Stripe
Customer is created for an anonymous one-off donor (creating one would just be a row the nightly
reconcile sweep pages through forever for someone who's never coming back).

**The Billing Portal** (`POST /membership/portal`, `Services::Billing::CreatePortalSession`)
requires a **portal configuration activated on the Stripe account** — this is dashboard setup, not
code, and it's step 6 of `docs/guides/stripe-account-setup.md`. Without it, `Stripe::BillingPortal::
Session.create` raises and "Manage billing" fails for every member with the same generic error
message checkout failures show.

**`GET /membership/thanks`** — where Stripe redirects a successful payer — **grants nothing.** It
calls `Services::Billing::ReconcileCustomer` synchronously on the signed-in visitor's own customer
id (so the page is truthful before the async webhook lands), then re-reads
`current_user.granting_membership`. Hitting the URL directly, with no real purchase behind it,
shows no membership — `MembershipControllerTest#"thanks grants nothing when hit directly by a
non-member"` pins this. `/membership` itself makes **zero Stripe API calls** to render — it only
reads `BillingPlan` rows — so it degrades gracefully (empty plan list, no crash) in the window
between a fresh deploy and running `stripe:sync_plans`.

**Why the new app sells through legacy's existing prices, never products of its own:** one
membership covers every site, and a subscription bought on music has to be the identical Stripe
object as one bought through legacy books — see the spec's "Legacy coexistence". This is also
exactly why `stripe:bootstrap` (§4) refuses outright when `STRIPE_LIVEMODE=true`: running it live
would create a *second* membership product, silently splitting subscribers across two products
with no way to tell them apart afterward.

## 12. Webhooks: two endpoints, one signing-secret list, and where donations get recorded

**Two endpoints are registered in the live Stripe account, one per production host currently
selling membership** — `https://thegreatestmusic.org/webhooks/stripe` and
`https://thegreatest.games/webhooks/stripe` (books hasn't cut over from legacy yet). **Stripe
issues a separate signing secret per endpoint**, and a delivery is only ever signed with the secret
of the endpoint it was sent to. `Services::Billing::StripeClient.webhook_secrets`
(`app/lib/services/billing/stripe_client.rb`) reads `STRIPE_WEBHOOK_SECRET` as a **comma-separated
list**, and `Webhooks::StripeController#verified_event` tries each configured secret in turn until
one verifies. Configuring only one secret means every delivery to the *other* endpoint fails
verification, returns 400, and Stripe eventually disables that endpoint after enough consecutive
failures — a slow, silent loss of every event from one production host. See
`deployment/ENV.md`'s `STRIPE_WEBHOOK_SECRET` entry and `docs/guides/stripe-account-setup.md` §§1–2
for the full registration walkthrough, including the Cloudflare WAF exclusion both endpoints need
first.

**Both endpoints receive every event on the shared account — legacy's traffic included.** That is
Stripe's delivery model, not a targeting choice: there's no way to scope a delivery to "only events
this app created." Concretely, one subscription change delivers to *both* production endpoints,
and both deliveries land within moments of each other. The unique index on
`stripe_events.stripe_event_id` makes the second delivery reuse the same row rather than inserting
a duplicate — see §2's core design — but `Webhooks::StripeController#create` re-enqueues
`Billing::ProcessStripeEventJob` whenever that row is still `received` or `failed`, deliberately: a
duplicate row is not proof the first delivery was ever processed, and one stranded at `received`
because `perform_async` failed must not be reported to Stripe as delivered. Since the two endpoints
fire together, the second delivery normally finds the row still `received` — **two concurrent jobs
processing the same event is the norm, not an edge case**, and every service the job calls has to
converge under that, not merely tolerate an occasional race. `ReconcileCustomer` does it with a
per-customer Postgres advisory lock (§2); `RecordDonation` does it below. Legacy's own coexistence
guard is the mirror image: it receives this app's events too, on its own endpoint, and skips them by
`metadata[origin_app]`/`payment_link` checks documented in the spec's "Legacy coexistence" and in
legacy's own `docs/features/stripe_coexistence_guard.md`.

**Donations are recorded from the same event stream, not a separate path.**
`Billing::ProcessStripeEventJob#record_donation` (`app/sidekiq/billing/process_stripe_event_job.rb`)
runs on every event in `DONATION_COMPLETION_EVENT_TYPES` — `checkout.session.completed` and
`checkout.session.async_payment_succeeded` — *before* the customer-id check that drives
subscription reconciliation — a donation, especially an anonymous one, may carry no customer at
all, so it has to be handled first or every anonymous donation would be marked `ignored` and never
recorded. The second event type exists because `CreateCheckoutSession` places no restriction on
`payment_method_types`, so Stripe's automatic payment methods can offer a delayed-notification one
(ACH Direct Debit, SEPA Direct Debit, Bacs, Boleto, OXXO, Konbini, ...): for those,
`checkout.session.completed` fires immediately with `payment_status` still `unpaid` — the
`payment_status == "paid"` check in `RecordDonation` below correctly no-ops on that delivery — and
the eventual settlement, sometimes days later, arrives as `checkout.session.async_payment_succeeded`
instead. Both event types deliver a Checkout Session as `data.object`, so `record_donation` needs
no per-type branching: it hands the session id (an identifier, never state) to
`Services::Billing::RecordDonation` (`app/lib/services/billing/record_donation.rb`), which re-reads
the full session from the Stripe API — mirroring `ReconcileCustomer`'s "re-read, don't trust the
payload" design — and `find_or_initialize_by(stripe_payment_intent_id:)`s a `Donation` row. That
same unique index is what makes a webhook-recorded donation and a legacy-history-imported one
converge instead of duplicating if the same payment ever shows up both ways.

Unlike `ReconcileCustomer`, `RecordDonation` takes no lock: a donation session may carry no
customer at all (an anonymous donor), so there is nothing to lock on. Instead it rescues the two
shapes a genuine two-jobs-same-payment-intent race can surface as —
`ActiveRecord::RecordNotUnique` when both INSERTs reach the partial unique index before either
commits, `ActiveRecord::RecordInvalid` when the loser's own uniqueness validation SELECT runs after
the winner has already committed — and re-reads the winner's row instead of raising. The
`RecordInvalid` rescue is scoped to `errors.of_kind?(:stripe_payment_intent_id, :taken)` on purpose:
a donation invalid for any other reason still raises, the same `stripe_events` row still flips to
`failed`, and Sidekiq still retries — silently swallowing a genuinely broken donation is the failure
mode `Webhooks::StripeController#record_event`'s identical guard exists to avoid, and this mirrors
it. Without this, the loser's exception was not rescued by `RecordDonation`'s
`rescue ::Stripe::StripeError`, so it propagated, flipped the row to `failed`, and Sidekiq retried —
the retry self-heals in ~30s since the row already exists by then, so this was noise rather than
data loss, but an operator following the verification table below would see `failed` rows on real,
successful donations and reasonably suspect something was broken. Subscription events never hit
this: `ReconcileCustomer`'s advisory lock serialises them before either job reaches a write.

This is also how **legacy's own donations get written here**, since both endpoints see every
event: `RecordDonation#resolve_user` tries `metadata[app_user_id]` first (this app's own tag),
falls back to `client_reference_id` **only when `metadata[origin_app]` matches this app** (legacy
sets `client_reference_id` too, but on a legacy-originated session it points at a legacy user id
that may coincidentally collide with an unrelated new-app user, since both apps allocate ids
independently now), and finally `stripe_customer_id` (safe unconditionally — a Stripe customer id
genuinely identifies one person regardless of which app created the session). A donation
attributable to neither path is recorded with `user_id: nil` and whatever `email` Stripe collected
— an anonymous donation, same as one made by a signed-out visitor on this app.

## 13. Email coexistence: this app emails only what it sold

§12 established that both webhook endpoints receive every event on the shared account — legacy's
subscriptions and donations included, not just this app's own. The membership-emails increment
(spec increment 8; see `docs/features/email.md` for the mailer-side detail) has to answer the
question that raises: when this app reconciles a **legacy-sold** subscription or records a
**legacy-taken** donation — which it does, routinely, because it cannot tell them apart from an
event alone — does it also email that person? It must not. Legacy is still live and still emails
its own subscribers and donors through its own, unmodified pipeline; if this app emailed them too,
every legacy member would get two welcome emails, two cancellation notices, two receipts, one from
each app, for as long as both run.

**`origin_domain` (memberships) / `domain` (donations) is the one signal both branding and
ownership are read from — the same column answers two different questions.** `CreateCheckoutSession`
stamps `origin_domain`/`domain` into Stripe metadata only on a session **this app** creates; legacy
creates its sessions through Payment Links and stamps nothing. §2 above covers how that value gets
onto the `Membership` row (`upsert` reads it back from the subscription's metadata, unconditionally,
on every reconcile); `RecordDonation` writes `donation.domain` from the same
`session.metadata["origin_domain"]` key at record time. Two independent readers then use that one
column for two different purposes:

- **Branding** — `MembershipMailer`/`AdminMailer` pass `membership.origin_domain`/`donation.domain`
  straight to `MailBranding.for(...)`, which resolves it to a site name, brand colour and host.
  `MailBranding.for(nil)` — every row this app didn't sell, plus every membership from before
  checkout existed — falls back to books' branding rather than raising, because a mailer running in
  Sidekiq has no `Current.domain` to fall back to instead (see `docs/features/email.md`'s "The one
  rule"). This fallback fires whether or not the email is actually sent — it only decides what a
  sent email would look like.
- **Ownership** — `Membership#sold_by_this_app?`/`Donation#sold_by_this_app?` are just
  `origin_domain.present?`/`domain.present?`, and `MembershipEmailScope.may_email?` gates every
  send on that predicate (unless `MEMBERSHIP_EMAIL_SCOPE=all` — see below). This is the check that
  actually decides *whether* to send, upstream of branding ever mattering.

The consequence of using one column for both: a legacy-sold membership reconciled by this app gets
branded mail templates *rendered* correctly (as books, since `origin_domain` is `nil`) if anyone
ever previews or force-sends one, but `MembershipEmailScope` stops it from ever actually being
*sent* in the normal flow — the blank `origin_domain` that makes `MailBranding` fall back to books
is the exact same blank value that makes `sold_by_this_app?` false and the send never happen.
Nothing about this needed a second column or a separate "who sold this" flag; the metadata tag
`CreateCheckoutSession` already had to stamp for legacy's own coexistence guard (see "Legacy
coexistence" in `docs/specs/membership-and-stripe-billing.md`) turned out to be sufficient signal
for the email side too.

**Legacy's own guard is the mirror image, not a coincidence.** Legacy's coexistence patch (§10 of
the spec's Increments table; `docs/features/stripe_coexistence_guard.md` in the legacy repo) skips
any event tagged `metadata[origin_app] == "the-greatest"` before writing or emailing anything.
Put the two guards side by side: legacy stays quiet about events *this* app created; this app stays
quiet (`MembershipEmailScope`, `own_only`) about events *legacy* created. Neither app can read the
other's source, so each one only trusts its own tag on its own outbound sessions — there is no
shared "who owns this" service, by design, because there will not always be two apps to ask.

**The switch, and why it lives in ENV rather than code.** `MEMBERSHIP_EMAIL_SCOPE` (see
`deployment/ENV.md`) is what turns this app from "quiet about legacy's traffic" into "the only
mailer left" without a deploy carrying application logic — set it to `all` in the same
infrastructure change that retires legacy's webhook endpoint at cutover, and every subsequent
reconcile or donation record starts emailing regardless of `origin_domain`/`domain`. Missing that
step at cutover has a specific, silent failure: legacy stops running (so it obviously stops
emailing), this app is still defaulting to `own_only` (so it *also* stays quiet about every
legacy-era row, forever, since no code path will ever flip that column from `nil` to something
truthy after the fact), and no membership or donation predating the cutover ever gets another email
from anyone again — not a crash, not a log line, just silence. See `docs/features/email.md`'s "The
eight membership emails" for the mailer/notifier side of this same gate.

**Flipping the switch without preparing for it fails the opposite way, and is the more damaging
mistake of the two.** `MembershipNotifier` derives *eligibility*, not just the once-only guard, from
`welcome_email_sent_at` (§2 above and `docs/features/email.md`'s "Durable eligibility, not
transition-driven") — so the moment `MEMBERSHIP_EMAIL_SCOPE=all` opens the gate, every legacy
membership that grants access and has a nil `welcome_email_sent_at` (which is all of them; this app
never welcomed any of them) is owed a welcome at the very next nightly sweep. **Run
`bin/rails billing:backfill_email_stamps` first, every time, with no exceptions** — it stamps
`welcome_email_sent_at`/`ended_email_sent_at` for every row the scope currently blocks, so there is
nothing left owed once it opens. See `deployment/ENV.md`'s `MEMBERSHIP_EMAIL_SCOPE` entry and
`docs/specs/membership-and-stripe-billing.md`'s "Cutover" section for the two-step order.
