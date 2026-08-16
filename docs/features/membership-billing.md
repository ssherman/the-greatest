# Membership & Stripe Billing

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
| `donations` | One-time payments, recorded from `checkout.session.completed` in payment mode or imported from the legacy database. |

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
```

Because no event payload is ever written as membership state, **delivery order cannot matter.** A
`customer.subscription.created` that arrives after the `invoice.paid` that superseded it just
triggers a redundant reconcile that converges on the same rows Stripe currently reports. There is
no "last write wins" bug to have, because nothing is written from an event body in the first
place.

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
  is a database-enforced guarantee, not just a code convention — see the comment above the
  `absence` validation in `app/models/membership.rb`.
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
| `billing:verify_migration` | Runs `Services::Billing::VerifyMigration` — checks four invariants between the legacy books database and the new one: every legacy `stripe_subscription_id` has a matching `Membership`, every legacy `paid: true` user has a `source: :legacy` grant, every legacy donation was imported, and reports (never fails on) unattached memberships and stripe+legacy overlap users. **Exits non-zero if any of the first three invariants has a gap.** | After running the two `data_migration:` tasks below, and any time you want to sanity-check that the legacy and new data agree. Read below for what a non-zero exit means. |
| `data_migration:memberships` | Runs `Services::BooksMigration::MembershipMigrator` — imports every legacy `users.paid: true` row as a `source: :legacy` Membership. Idempotent (`find_or_initialize_by`-based), safe to re-run. | Once, as part of the legacy-history import (§5). |
| `data_migration:donations` | Runs `Services::BooksMigration::DonationMigrator` — imports the legacy `donations`-equivalent table into `donations`. Idempotent, safe to re-run. | Once, as part of the legacy-history import (§5), immediately after `data_migration:memberships`. |

**`rake stripe:sync_plans` and `stripe:bootstrap` are not implemented yet.** The billing plans
admin screen (`/admin/billing_plans` and its edit form) already tells the operator to run `rake
stripe:sync_plans` to refresh price ids and amounts, and the project spec names both tasks as the
eventual owners of those fields — but neither task exists in this codebase today. They arrive with
the checkout increment. Until then, `billing_plans` rows hold whatever seeded them, and running
either command gets `Don't know how to build task`.

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

On a first, clean run, expect roughly 28 legacy memberships imported and 21 donations, with
`unaccounted_for: 0` printed by `data_migration:memberships`.

**`billing:verify_migration` exits non-zero if any legacy record has no counterpart.** Do not treat
a non-zero exit as "run it again and hope." The task prints the actual list of offending ids under
each failing category (`missing_subscriptions`, `missing_grants`, `missing_donations`) — the
signal is to **read those ids** and find out why each one didn't migrate (a user that doesn't
exist in the new `users` table yet is the most likely cause), not to re-run the importer blindly.
Re-running is safe (both importers are idempotent) but will reproduce the exact same gap if the
underlying cause hasn't changed.

Unattached memberships and the legacy/Stripe overlap are reported by the same task but never cause
the non-zero exit — they're expected outcomes, not errors. Work through unattached ones with the
runbook in §6; the overlap list is informational only (§3).

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

- **`origin_domain` is never written by the reconciler.** `Membership#origin_domain` only gets set
  at checkout time (which domain — books, music, or games — the user was on when they subscribed).
  Any row that predates that write path, including everything built by
  `billing:reconcile_all`/the legacy-history import, has `origin_domain: nil`. The admin detail page
  shows "Unknown" for these rather than guessing.
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
- **`users.stripe_customer_id` has a non-unique index, not a unique constraint.** If two user rows
  were ever given the same `stripe_customer_id` (by a bug, a bad manual edit, or a race), then
  `ReconcileCustomer#resolve_user`'s `User.find_by(stripe_customer_id:)` becomes nondeterministic —
  which of the two rows it returns is whatever Postgres happens to return first, and that could
  flip between reconciles. Nothing in the current code enforces or checks the uniqueness this
  implicitly relies on.
