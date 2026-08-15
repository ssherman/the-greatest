# Membership & Stripe Billing

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2026-08-14
- **Developer**: Shane Sherman

## Overview

Bring the membership feature from the legacy books app into The Greatest as a
cross-domain subsystem: one membership that covers books, music and games, sold
through Stripe, with an entitlement layer that makes it cheap to put a feature
behind the paywall later.

This is not a port. The legacy webhook handler treats each Stripe event as a
delta to apply, which is why it has accumulated four separate ordering guards
over the years. This design makes webhooks *signals* and Stripe the *source of
truth*, which removes that bug class structurally rather than guarding against
it case by case.

**Non-goals.** No ads are added and no existing free capability is moved behind
the paywall. Multiple pricing tiers, Stripe's Entitlements API, proration and
plan-switching flows, and coupons are all out of scope.

## Context & Links

**Legacy source** (`/home/shane/dev/the-greatest-books/admin`):
- `app/controllers/webhooks_controller.rb` — the 400-line synchronous handler
- `app/services/stripe_service.rb` — payment links, product config, caching
- `app/models/{subscription,donation,webhook_event}.rb`
- `app/controllers/support_controller.rb`, `app/views/support/index.html.erb`
- `config/stripe_products.yml`, `lib/tasks/stripe.rake`
- `app/lib/email.rb` — SendGrid wrapper

**External docs** (verified 2026-08-14):
- Stripe Ruby gem 19.5.0 (2026-08-10); legacy runs 17.2.0
- Current API version `2026-07-29.dahlia`
- [Signature verification](https://docs.stripe.com/webhooks/signature) —
  `Stripe::Webhook::DEFAULT_TOLERANCE = 300` seconds, HMAC-SHA256, payload
  parsed only after verification succeeds
- [Pay what you want](https://docs.stripe.com/payments/checkout/pay-what-you-want) —
  `custom_unit_amount`
- [Sandboxes](https://docs.stripe.com/sandboxes) — up to five per account, each
  with isolated keys, webhooks, data and configuration
- [Price update](https://docs.stripe.com/api/prices/update) — `lookup_key` is
  updatable on an existing price
- Basil (2025-03-31) moved `current_period_start`/`current_period_end` off the
  Subscription object onto subscription items

**Project conventions that constrain this work:** secrets are ENV vars managed
with SOPS + age (`deployment/SECRETS.md`), never Rails credentials — which are
unused in this app; services live in `app/lib/services/`; jobs in `app/sidekiq/`;
`bundle exec standardrb` and `bin/rails test` gate every PR; daisyUI 5, with ten
removed v4 classes guarded by `test/lint/daisyui_v4_classes_test.rb`.

## Decisions

| Decision | Choice | Consequence |
|---|---|---|
| Legacy coexistence | Both apps live on one Stripe account for ~2 months | New app must tolerate legacy-created subscriptions; legacy needs a guard patch |
| Legacy safety | Small patch to the legacy repo | Must deploy before the new app can sell |
| Membership scope | One membership covers all sites | No scope column; sells through legacy's existing prices |
| Emails | Full support, built generic | ActionMailer + SendGrid foundation reusable beyond membership |
| First gate | Members-only extras only | Nothing is taken away from existing free users |
| Comped members | Row in `memberships`, not a boolean | `member?` is one query against one table |
| Donations | Single custom-amount price | Eight prices and eight payment links collapse to one price, zero links |
| Processing model | Reconcile from Stripe | Order-independent; one function also does migration, drift check, recovery |
| Production price ids | Add `lookup_key` to the live prices | `stripe:sync_plans` resolves ids in every environment |

## Architecture

### The core idea

The webhook endpoint verifies the signature, inserts the raw event, and returns
200. Nothing else. A Sidekiq job then extracts **only the customer id** — an
identifier, never state — re-reads that customer's current subscriptions from
the Stripe API, and rewrites the local rows to match.

Because no event payload is ever written to the database, **delivery order stops
mattering**. A late `customer.subscription.created` triggers a redundant
reconcile that converges on the same state. It cannot downgrade an active
subscription, because the event's status was never what we wrote.

Mapped against the legacy guards this replaces:

| Legacy guard (`webhooks_controller.rb`) | Why it disappears |
|---|---|
| "Don't downgrade an active subscription due to late-arriving created event" | Event status is never written; Stripe's current status is |
| `find_checkout_session_for_subscription` user recovery | `stripe_customer_id` is written during checkout, before any webhook |
| `rescue ActiveRecord::RecordNotUnique` + retry | Per-customer advisory lock removes the race |
| `email_sent` flag | Replaced by a computed status transition plus a timestamp column |

### Services

All under `Services::Billing::` — **not** `Services::Membership::`, because
inside a `Services::Membership` module a bare `Membership` resolves to the
module rather than the model. That constant-shadowing bug has bitten this
codebase at least three times (`Search::`, `Services::BooksMigration`,
`ItemRankings::`) and presents as a confusing `NameError`. For the same reason
the gating module is top-level `MembershipGate`, not `Membership::Gate` nested
inside the model class.

- `Services::Billing::StripeClient` — ENV config, pinned API version, livemode guard
- `Services::Billing::ReconcileCustomer` — the core; makes local match remote
- `Services::Billing::ReconcileAllCustomers` — pages the whole account
- `Services::Billing::EnsureCustomer` — find-or-create a Stripe Customer for a user
- `Services::Billing::CreateCheckoutSession` / `CreatePortalSession`
- `Services::Billing::RecordDonation`
- `Services::Billing::ClaimUnattachedMemberships`

All return the project's `Result` struct.

## Interfaces & Contracts

### Domain Model

Four new tables, global namespace (like `User` and `List`).

**`memberships`** — the single source of truth for "is this person a member?"

| Column | Type | Notes |
|---|---|---|
| `user_id` | bigint FK | **nullable** — an unmappable Stripe customer is stored, not dropped |
| `source` | integer | `stripe: 0, comped: 1, legacy: 2` |
| `status` | integer | `trialing, active, canceled, incomplete, incomplete_expired, past_due, unpaid, paused` |
| `interval` | integer | `monthly, yearly`; nil for comped |
| `stripe_subscription_id` | string | nil for comped/legacy; unique where not null |
| `stripe_customer_id` | string | denormalised so reconcile can find rows with no user |
| `current_period_end` | datetime | access-through date; **nil means never expires** |
| `canceled_at` | datetime | |
| `cancel_at_period_end` | boolean | default false |
| `origin_domain` | string | which site the purchase came from; drives email branding |
| `welcome_email_sent_at` | datetime | exactly-once guard |
| `ended_email_sent_at` | datetime | exactly-once guard |
| `stripe_synced_at` | datetime | last successful reconcile |
| `note` | text | why it was comped |
| `granted_by_id` | bigint FK → users | admin who comped it |

Indexes: unique on `stripe_subscription_id WHERE NOT NULL`; `[user_id, status]`;
`stripe_customer_id`.

**`stripe_events`** — the raw inbox

| Column | Type | Notes |
|---|---|---|
| `stripe_event_id` | string | **unique** — this index *is* the idempotency check |
| `event_type` | string | |
| `payload` | jsonb | the **full** event, not just `data.object` |
| `livemode` | boolean | not null; the sandbox/production interlock |
| `api_version` | string | |
| `stripe_customer_id` | string | extracted for admin filtering |
| `status` | integer | `received, processed, failed, ignored` |
| `stripe_created_at` | datetime | |
| `processed_at` | datetime | |
| `attempts` | integer | default 0 |
| `error` | text | |

**`billing_plans`** — replaces `config/stripe_products.yml` entirely

| Column | Type | Notes |
|---|---|---|
| `kind` | integer | `membership, donation` |
| `key` | string | `monthly` / `yearly` / `donation`; unique |
| `name` | string | |
| `interval` | integer | nil for donation |
| `amount_cents` | integer | display only; nil for donation |
| `currency` | string | default `usd` |
| `stripe_price_id` | string | unique |
| `stripe_lookup_key` | string | how the id is re-resolved per environment |
| `active` | boolean | default true |
| `position` | integer | default 0 |

**`donations`**

| Column | Type | Notes |
|---|---|---|
| `user_id` | bigint FK | nullable — anonymous donations |
| `amount_cents` | integer | not null (legacy `amount` renamed for clarity) |
| `currency` | string | default `usd` |
| `status` | integer | `pending, succeeded, failed, refunded` |
| `stripe_payment_intent_id` | string | unique |
| `stripe_checkout_session_id` | string | |
| `email` | string | for anonymous donors |
| `domain` | string | which site it came from |

Legacy `webhook_events` is **deliberately not migrated**. It is a processing log
for a pipeline being deleted; importing it would imply it could be replayed.

### Endpoints

All declared outside every `DomainConstraint` block, following the existing
pattern for `/my/lists` and `/searches`.

| Verb | Path | Purpose | Auth |
|---|---|---|---|
| POST | `/webhooks/stripe` | Stripe event ingest | Signature only |
| GET | `/membership` | Join page | Public |
| POST | `/membership/checkout` | Create Checkout Session, redirect | Signed in |
| POST | `/membership/donate` | Create one-time Checkout Session | Public |
| POST | `/membership/portal` | Create Billing Portal session, redirect | Signed in |
| GET | `/membership/thanks` | Post-checkout return | Public |
| GET | `/membership_state` | Per-user state for edge-cached pages | Signed in |
| GET | `/support` | 301 → `/membership` (legacy books URL) | Public |

Source of truth is `config/routes.rb`.

### Behaviors

**Webhook ingest.** The controller inherits `ActionController::Base` directly,
not `ApplicationController` — no Pundit, no `set_current_domain`, no
`allow_browser` between Stripe and a 200.

1. `Stripe::Webhook.construct_event(request.raw_post, sig_header, secret)`.
   `raw_post`, not `body.read`.
2. If `event.livemode != Rails.configuration.stripe_livemode`, record as
   `ignored` and return 200. Nothing else is written.
3. Insert a `StripeEvent`. `ActiveRecord::RecordNotUnique` → return 200 without
   enqueueing; the redelivery is already handled.
4. Enqueue `Billing::ProcessStripeEventJob`, return 200.

Failure modes: invalid signature → 400, zero rows written. Unparseable body →
400 (verification fails first). Processing failure happens in Sidekiq and never
affects the HTTP response.

**Reconcile.** Inside a Postgres advisory transaction lock keyed on the customer
id:

- Resolve the user: `User.find_by(stripe_customer_id:)`, then the Customer's
  `metadata[app_user_id]`, then leave the row unattached.
- `Stripe::Subscription.list(customer:, status: "all")`, paging.
- Upsert one `Membership` per subscription. Rows with `source != :stripe` are
  never eligible, so a comped membership is structurally unreachable.
- `current_period_end` is read from `subscription.items.data[0].current_period_end`,
  not the deprecated subscription-level field.
- Diff each row's status before and after; a genuine transition enqueues a
  mailer guarded by its `*_email_sent_at` timestamp.

Preconditions: a customer id. Postconditions: local rows for that customer match
Stripe at the moment of the read. Idempotent — running twice changes nothing.

**Checkout.** Accepts a plan `key` only. Never a price id, an amount, or a user
id from the client.

```ruby
plan        = BillingPlan.membership.active.find_by!(key: params[:plan])
result      = Services::Billing::EnsureCustomer.call(user: current_user)
customer_id = result.data                       # Result struct, per project convention
Stripe::Checkout::Session.create(
  mode: "subscription", customer: customer_id,
  line_items: [{price: plan.stripe_price_id, quantity: 1}],
  client_reference_id: current_user.id,
  subscription_data: {metadata: {app_user_id: current_user.id, origin_app: "the-greatest"}},
  success_url: membership_thanks_url(host: request.host),
  cancel_url:  membership_url(host: request.host)
)
```

`EnsureCustomer` returns an existing `stripe_customer_id` or creates one with
`idempotency_key: "customer-#{user.id}"`, writing it to the user **in this
request**. That write is what makes the user↔customer link exist before any
webhook can fire. If the user already has an active membership, checkout
redirects to the portal instead.

**Thanks page.** Calls `ReconcileCustomer` synchronously on the signed-in user's
own customer id, so the page is truthful before the webhook lands. It grants
nothing — it only re-reads Stripe — and is rate-limited.

**Donations.** One `billing_plans` row of `kind: :donation` pointing at a price
with `custom_unit_amount: {enabled: true, minimum: 100, preset: 2500}`. Checkout
Session in `mode: "payment"` with `submit_type: "donate"`. Stripe's documented
limits (single line item, quantity 1, no promo codes, no recurring) are all
acceptable here. Signed-out donations are allowed; Stripe collects the email.

**Entitlement.** `User#member?` is one `exists?` against
`Membership.granting_access`, which encodes three distinct rules:

- `source: :stripe` with status `active`/`trialing` — trust Stripe's status, do
  not check the date. Checking it would only produce false denials from stale
  data.
- `source: :stripe` with status `canceled` and `current_period_end` in the
  future — the paid-through grace period, matching current behaviour.
- `source: :comped`/`:legacy` with status `active` and `current_period_end` null
  or in the future — so a comped membership with an end date actually ends, and
  null means never.

**Feature gating.** `MembershipGate` (`app/lib/membership_gate.rb`) holds one
list of member-only feature keys, with a `members_only?(:feature)` view helper
and a `require_membership!` controller filter. The value is auditability — one
place answers "what is behind the paywall?" — not abstraction.

**Edge-cached pages.** `GET /membership_state` follows the existing
`UserListStateController` / `ReviewStateController` pattern: `prevent_caching`,
`require_signed_in!`, returns `{member:, plan:, current_period_end:}`. The
`/membership` page itself is `no-store, private` rather than edge-cached, since
it renders differently for members and is low-traffic.

When ads eventually land, the mechanism is a cookie set at sign-in (as legacy's
`TgbHideAds`), because suppression must happen before paint. **The cookie is
presentation only** — it is user-controllable, so every server-side gate
re-checks `member?`.

### Email

ActionMailer over SendGrid SMTP, configured from ENV. No third-party gem.

`ApplicationMailer` takes a **domain argument explicitly** and resolves the
from-address, site name, layout and URL host from `config.domain_settings`.
This is load-bearing: mailers run inside Sidekiq where `Current.domain` is
unset, so anything reading `Current` in a mailer silently sends a books-branded
email to a music subscriber. Hence `memberships.origin_domain`.

Everything sends with `deliver_later`. Previews in `test/mailers/previews/`.

Eight emails port from legacy: welcome, cancelled-with-other-active,
cancelled-last, donation confirmation, and four admin notifications. The
hardcoded `billing.stripe.com/p/login/…` link is replaced by a link to
`/membership`, which creates a proper per-customer portal session.

The foundation is generic because a second consumer is already waiting:
`User#generate_confirmation_token!` and `confirm_email!` exist and nothing calls
them.

### Non-functionals

- **Security.** No verification bypass path exists — not behind an ENV var, not
  behind `Rails.env.development?`, not behind a param. Payloads are never
  logged (legacy logs full customer PII on failure); log event id and type only.
  Test fixtures carry payloads but signatures are generated at runtime from a
  dummy secret, so no real `whsec_` enters the repo. Rate limiting goes on
  checkout creation, not the webhook — throttling the webhook means dropping
  legitimate Stripe deliveries. Comping is an admin-only Pundit policy.
- **Boot guard.** `StripeClient` raises if `STRIPE_SECRET_KEY` begins `sk_live_`
  while `STRIPE_LIVEMODE` is not true.
- **Pinning.** `Stripe.api_version = "2026-07-29.dahlia"` set explicitly so a
  gem upgrade cannot silently change payload shapes.
- **Colour.** Membership status is conveyed in words, never colour alone, and
  never as green-versus-red. The books theme's `success` token is purple on
  purpose — do not "fix" it.
- **Performance.** One extra Stripe API call per event. At this volume
  (hundreds of subscriptions) that is irrelevant, and it is what buys
  order-independence. Tradeoff accepted: a Stripe outage delays processing
  rather than allowing a write-through from the payload.

### ENV variables

Added to `.env.example`, `deployment/ENV.md`, and `sops secrets/.env.production`:

```
STRIPE_SECRET_KEY          # sandbox key in dev, live key in production
STRIPE_WEBHOOK_SECRET      # differs between a dashboard endpoint and `stripe listen`
STRIPE_LIVEMODE            # explicit, so staging is unambiguous
SENDGRID_API_KEY
MAIL_FROM_ADDRESS
ADMIN_NOTIFICATION_EMAIL
```

`STRIPE_LIVEMODE` is read once in an initializer into
`Rails.configuration.stripe_livemode`, so the webhook interlock is a boolean
comparison rather than repeated string parsing.

### Rake tasks

| Task | Purpose |
|---|---|
| `stripe:bootstrap` | Create products and prices with fixed lookup keys in a fresh sandbox. **Refuses to run when `STRIPE_LIVEMODE=true`.** |
| `stripe:sync_plans` | Resolve each `billing_plans` row's price by `stripe_lookup_key` against the current environment's Stripe account and update `stripe_price_id`, `amount_cents`, `interval`. Fails loudly on an unresolvable key. |
| `billing:reconcile_all` | Run `ReconcileAllCustomers` across the whole account. Also the nightly `sidekiq-cron` entry in `config/schedule.yml`. |
| `billing:replay_failed` | Re-enqueue `stripe_events` left in `failed`. |
| `data_migration:memberships` | Import legacy `users.paid` early supporters as `source: :legacy` rows. |
| `data_migration:donations` | Import legacy donation history. |
| `billing:verify_migration` | Report the invariant below, plus unattached rows. |

Lookup keys: `membership_monthly`, `membership_yearly`, `donation_custom`.

## Legacy coexistence

Both apps run live against one Stripe account for roughly two months, until
books cuts over to the new app.

**The new app sells through the same production prices legacy already uses.** It
creates no membership products of its own:

```
membership monthly → price_1QvpHqEAWBHYHNGXLPrsxZ0v  (prod_RpUGlPnfnCbn4m)
membership yearly  → price_1QvpHtEAWBHYHNGXQfQpB9tL  (prod_RpUGy8T59mpSdR)
```

This follows from "one membership, all sites" — a subscription bought on music
and one bought on legacy books are the same product. Legacy's
`stripe_products.yml`, products, prices and payment links are untouched, and
existing subscribers keep billing identically.

Safeguards:

1. `stripe:bootstrap` refuses to run when `STRIPE_LIVEMODE=true`. It is a
   sandbox-only tool. Production plans are seeded pointing at the ids above,
   with `lookup_key` written onto the live prices — verified as a label-only
   change with no effect on amount, billing or existing subscribers.
2. The new app never calls the PaymentLink API. Legacy's link lifecycle stays
   legacy's business.
3. Every subscription the new app creates carries
   `metadata[origin_app] = "the-greatest"`, so legacy's guard reads as an
   explicit "not mine, skip" rather than inferring it from a nil user.
4. Donations diverge harmlessly: the custom-amount price is new, and legacy
   reads its own eight ids from YAML. The `stripe_payment_intent_id` unique
   index means webhook-recorded and migration-imported rows converge rather
   than duplicating.

### Legacy guard patch (separate repo)

Without this, legacy 422s on every new-app subscription. Its handler looks the
user up by `stripe_customer_id` (miss), falls back to the checkout session's
`client_reference_id` — a new-app user id ≥ 150,001, which does not exist in the
legacy database, since the migration reserved ids below 150,000 — gets nil, and
calls `subscription.update!(user: nil, …)`. Legacy runs `load_defaults 7.0`, so
`belongs_to :user` is required and this raises. Stripe then retries the same
event for 72 hours and can disable the endpoint.

The patch:

1. Skip events whose subscription carries `metadata[origin_app] == "the-greatest"`,
   logging and returning 200. Backstop: when no user can be resolved, log and
   return 200 rather than raising.
2. Scope `rake stripe:delete_webhooks` to legacy's own URL. It currently
   iterates `Stripe::WebhookEndpoint.list` and deletes **every endpoint in the
   account**, which after this ships includes the new app's — silently stopping
   event delivery with no error anywhere. Same account-wide shape in
   `deactivate_all_payment_links`, harmless to us but worth scoping too.

**This must be deployed before increment 6 reaches production.**

### Cutover

Because both apps reconcile from the same Stripe account throughout, the new app
already holds every subscription on cutover day. Cutover is: point
thegreatestbooks.org at the new app, delete legacy's webhook endpoint, retire
legacy's `/support`. **There is no data migration at the end** — it happens now,
and the nightly reconcile keeps it true.

## Data migration

Subscriptions are **rebuilt from Stripe**, not copied. The legacy
`subscriptions` table was written by the handler being replaced and is the least
trustworthy copy. `ReconcileAllCustomers` pages every subscription in the live
account; users attach via `users.stripe_customer_id` (already migrated), then
customer metadata, then customer email. Leftovers land in the admin
"needs attention" list.

Two things can only come from the legacy database:

- **`users.paid = true` early supporters** → `memberships` with
  `source: :legacy`, `status: :active`, `current_period_end: nil`, note
  "Legacy early supporter". These have no Stripe representation.
- **`donations`** → keyed `stripe_payment_id` → `stripe_payment_intent_id`,
  `amount` → `amount_cents`. Append-only and never affected by the ordering
  bugs. Rows whose user no longer exists import unattached rather than failing
  the run — the same books/users drift that makes `data_migration:reviews` fail
  standalone against the live legacy database.

**Verification invariant:** not a count match — a legacy-vs-new count always
drifts against a live database — but *every `stripe_subscription_id` present in
legacy exists in `memberships`*, and unattached rows equal the set deliberately
expected.

## Development & testing

1. **A Stripe Sandbox** for local dev — isolated keys, webhooks, data and
   configuration, with no path to a real customer.
2. **`stripe listen --forward-to localhost:3000/webhooks/stripe`** — no public
   dev hostname, no tunnel. `stripe trigger customer.subscription.created` fires
   synthetic events. Document that the CLI's `whsec_` differs from a dashboard
   endpoint's; mixing them is the most common verification failure.
3. **The `livemode` interlock plus the boot guard**, above.
4. **Automated tests never hit the network.** Stripe calls stubbed with Mocha.
   Webhook tests build a payload fixture and sign it at runtime with a dummy
   secret, so real signature verification is exercised. The reconcile tests
   deliberately deliver events **out of order** and assert identical final
   state — that test is the design claim and must fail loudly if anyone
   reintroduces payload-as-truth.

E2E covers `/membership` to the redirect boundary: page renders, plans come from
the database, signed-out gets the auth modal, signed-in redirects to a
`checkout.stripe.com` URL. Completing a real checkout is sandbox plus manual
verification.

## Increments

| # | Increment | Depends on |
|---|---|---|
| 1 | Stripe foundation — gem, `StripeClient`, four tables, models, fixtures | — |
| 2 | Webhook ingest — endpoint, signature verification, livemode guard, idempotent insert, job stub | 1 |
| 3 | Reconciliation engine — `ReconcileCustomer`, advisory lock, `ReconcileAllCustomers`, nightly cron | 2 |
| 4 | Data migration — legacy comps, legacy donations, Stripe rebuild, verification report | 3 |
| 5 | Mail foundation — ActionMailer + SendGrid, domain-aware `ApplicationMailer`, previews | — |
| 6 | Checkout — `billing_plans`, rake tasks, `EnsureCustomer`, checkout/portal/donate, `/membership`, thanks page | 3, 10 |
| 7 | Entitlements — `member?`, access scope, `MembershipGate`, `/membership_state`, members-only area | 3 |
| 8 | Membership emails — the eight | 5, 6 |
| 9 | Admin UI — memberships incl. comping, donations, stripe events, billing plans | 3 |
| 10 | **Legacy guard patch** (separate repo) | — |
| 11 | E2E tests | 6, 7 |

Increments 1–5 only read from Stripe and are safe to ship in any order relative
to legacy. Increment 6 is the moment the new app first creates subscriptions in
the shared account, so increment 10 must be live before it.

## Acceptance Criteria

- [ ] An unsigned or wrongly-signed webhook request returns 400 and writes zero rows
- [ ] A redelivered event returns 200 and does not reprocess
- [ ] An event whose `livemode` mismatches is recorded `ignored` and writes nothing else
- [ ] Delivering `customer.subscription.created`, `checkout.session.completed` and
      `invoice.paid` in every permutation produces identical final state
- [ ] A comped membership is unchanged by any webhook for the same user
- [ ] A comped membership with a passed `current_period_end` does not grant access
- [ ] A cancelled Stripe subscription grants access until `current_period_end`
- [ ] Checkout rejects a request carrying a `stripe_price_id` or `user_id` param
- [ ] `stripe_customer_id` is persisted before the checkout redirect is issued
- [ ] `/membership/thanks` grants nothing when hit directly
- [ ] `/membership` renders with zero Stripe API calls
- [ ] `stripe:bootstrap` refuses to run with `STRIPE_LIVEMODE=true`
- [ ] `StripeClient` raises at boot on an `sk_live_` key with `STRIPE_LIVEMODE` unset
- [ ] Every legacy `stripe_subscription_id` exists in `memberships` after migration
- [ ] Every legacy `paid: true` user has a `source: :legacy` membership
- [ ] The welcome email sends exactly once across repeated reconciles
- [ ] A membership email uses the branding of `origin_domain`, not a `Current` lookup
- [ ] `bin/rails test` and `bundle exec standardrb` pass; Playwright covers `/membership`

## Risks

- **A Stripe outage delays processing** rather than allowing a write-through.
  Accepted: events queue in Sidekiq and Stripe retries for 72 hours, and the
  nightly reconcile is the backstop.
- **Legacy patch not deployed before increment 6** → legacy 422s and Stripe may
  disable its endpoint. Mitigated by the explicit dependency above.
- **Someone runs `rake stripe:delete_webhooks` on legacy** → the new app stops
  receiving events silently. Mitigated by the scoping change in the patch, and
  detected by the nightly reconcile.
- **User id collision.** The migration reserved user ids below 150,000. Legacy
  is still creating users; if the live books database ever passes 150,000, a
  legacy id could collide with a new-app id. Pre-existing and out of scope here,
  but the coexistence guards should not be the only thing standing between that
  and a mis-attached subscription.

## Future Improvements

- Stripe's Entitlements API, if multiple tiers with genuinely different feature
  sets ever ship. Additive, not a rewrite.
- Plan switching and proration.
- Ad suppression once an ad network is chosen — the cookie mechanism is
  described above.
