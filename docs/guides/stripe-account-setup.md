# Stripe account setup — production runbook

This is the by-hand, in-the-Stripe-Dashboard-and-Cloudflare part of shipping membership and
checkout (increment 6 of `docs/specs/membership-and-stripe-billing.md`). None of it is code, and
none of it can be automated from the app: it is the sequence a person follows once, in order, on
the shared live Stripe account. Read "Legacy coexistence" in that spec first — this runbook only
makes sense in that context.

**Every step here is a real, external action.** Nothing in this branch runs any of them
automatically, and this document does not run any of them either — it is instructions for a
human. Follow it in order; several steps depend on the ones before them.

## 0. Before you start: the legacy guard must already be live

**The legacy guard patch must already be live.** It shipped 2026-08-17 on the legacy repo
(`the-greatest-books#7`, branch `stripe-coexistence-guard`, documented in that repo's
`docs/features/stripe_coexistence_guard.md`). Without it, the moment this app creates its first
live subscription, legacy 422s on the matching webhook delivery and Stripe can disable legacy's
endpoint after enough retries. Confirm before doing anything below:

1. `https://thegreatestbooks.org` renders normally.
2. In the Stripe Dashboard, find a recent `customer.subscription.updated` delivery to legacy's
   endpoint and click "Resend". In legacy's `/admin/webhook_events`, the resent row should show
   `processed`.
3. Skim legacy's `ignored` rows in the same screen. Each one should carry a reason that makes
   sense (an `origin_app` tag, a blank `payment_link`, or "no resolvable user") — not a bare
   exception.
4. **Confirm legacy's own sessions actually carry a `payment_link` id.** One of legacy's guard
   checks is structural: it treats a `checkout.session.completed` with a *blank* `payment_link` as
   "not legacy's" — legacy has only ever sold through Payment Links, and Stripe stamps a
   `payment_link` id on every session those produce. That's only true if legacy's webhook endpoint
   is pinned to an API version new enough to include the field (Stripe added Payment Links in
   2021). Don't try to check this by reading the endpoint's configured API version number —
   Stripe ships additive response fields like this one to *every* API version, so the version
   number alone doesn't answer the question, and it's easy to end up comparing against a version
   string that was never real. Check a real payload instead: Stripe Dashboard → Developers →
   Webhooks → legacy's endpoint → Recent deliveries, open any `checkout.session.completed` that
   came from one of legacy's own Payment Links, and confirm `payment_link` holds a non-null
   `plink_...` id. If it's null on legacy's own traffic, the guard's structural check is silently
   inert and only the `origin_app` metadata tag is protecting legacy's donations — worth knowing
   before relying on it as a backstop.

If any of these fail, stop. Fix the legacy deploy before touching anything below — everything from
here on makes this app start selling on the shared account.

## 1. Cloudflare: check whether `/webhooks/stripe` is challenged (today: it is not)

**No action is needed on `thegreatestmusic.org` or `thegreatest.games` as things stand.** Verified
against production on 2026-08-19 — see the check below. Read this section anyway: it tells you the
one change that will silently break webhook delivery later.

A managed challenge answers a POST with a bare `403` — not JSON, not anything Stripe's client
retries past — and Stripe records it as a failed delivery indistinguishable from a real outage.
That is worth guarding against, but only where something is actually challenging.

**Why the three zones differ.** `thegreatestbooks.org` is on a **paid** Cloudflare plan, so the
full managed WAF is deployed to it (OWASP Core, Exposed Credentials Check, Cloudflare Managed
Ruleset). That is why it carries a skip rule — `(http.request.uri.path wildcard "/webhooks/*")`,
action `skip`, in its `http_request_firewall_managed` entrypoint ruleset — for legacy's webhook.

`thegreatestmusic.org` and `thegreatest.games` are on **free** plans. They have only the
Cloudflare Managed Free Ruleset available and **no `http_request_firewall_managed` entrypoint
ruleset at all** (the API returns `10003: could not find entrypoint ruleset in the
http_request_firewall_managed phase`). There is nothing there to skip, and a books-style rule
cannot even be created on those zones — the ruleset id in the books rule is zone-specific and does
not exist elsewhere.

**The check, which needs nothing but curl.** An unsigned POST should be rejected by *Rails*, not by
Cloudflare:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://thegreatestmusic.org/webhooks/stripe \
  -H "Content-Type: application/json" -H "Stripe-Signature: t=1,v1=probe" -d '{"probe":true}'
```

- **`400` with an empty body** — correct. That is `Webhooks::StripeController` returning
  `head :bad_request` after signature verification fails. The request reached the app; Cloudflare
  is not in the way. (A `503` means the app is up but `STRIPE_WEBHOOK_SECRET` is unset — also a
  Rails response, also fine for this check.)
- **`403` with an HTML body** — Cloudflare challenged it. Add a skip rule, then re-run this check.

Both hosts returned `400` on 2026-08-19.

### The thing that will change this: upgrading music or games to a paid plan

**A Pro upgrade deploys the managed WAF rulesets to that zone**, which is the same configuration
that made the skip rule necessary on books. Webhook deliveries can start returning `403` some time
after an upgrade, with nothing in the Stripe or app logs connecting the failure to a billing-plan
change made weeks earlier.

**If you upgrade either zone, re-run the check above before assuming anything still works.** If it
returns `403`:

- On a **paid** zone, mirror the books rule: a rule with action `skip` and
  `action_parameters: {"ruleset": "current"}` in that zone's `http_request_firewall_managed`
  entrypoint. Fetch the zone's own entrypoint id first
  (`GET /zones/{zone}/rulesets/phases/http_request_firewall_managed/entrypoint`) — **do not reuse
  the id from the books rule**, which is specific to that zone.
- Scope the expression to `(http.request.uri.path eq "/webhooks/stripe")` rather than books'
  `/webhooks/*`. This app has exactly one webhook route, and one guarded by signature verification
  at that; a narrower skip is less to reason about later.
- If the challenge turns out to come from Bot Fight Mode or Security Level rather than the managed
  WAF, the skip belongs in the `http_request_firewall_custom` phase instead, with the relevant
  products named in `action_parameters.products` — `skip` with `ruleset: current` only skips the
  managed ruleset.

Whatever you change, the verification is the same: the curl above, or step 2's "Send test webhook"
returning `200`.

## 2. Register the two webhook endpoints

Register two endpoints in the **live** Stripe account (Developers → Webhooks → Add endpoint):

- `https://thegreatestmusic.org/webhooks/stripe`
- `https://thegreatest.games/webhooks/stripe`

Books is not in this list — it has not cut over yet, and still runs on legacy's own endpoint.

Subscribe both endpoints to exactly these events:

```
checkout.session.completed
checkout.session.async_payment_succeeded
customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
customer.subscription.paused
customer.subscription.resumed
invoice.paid
invoice.payment_failed
```

**`checkout.session.async_payment_succeeded` matters for donations paid with a
delayed-notification method** (ACH Direct Debit, SEPA Direct Debit, Bacs, Boleto, OXXO, Konbini,
...), which this app's Checkout Sessions allow since `Services::Billing::CreateCheckoutSession`
sets no `payment_method_types` restriction. For one of those methods, Stripe fires
`checkout.session.completed` immediately with `payment_status` still `unpaid` — `RecordDonation`
correctly writes nothing on that delivery — and reports the eventual settlement, sometimes days
later, as this separate event instead. Without subscribing to it, a delayed-method donation
settles and is never recorded anywhere: no error, no failed row, just a `Donation` that should
exist and doesn't. `checkout.session.async_payment_failed` is deliberately not in this list —
there is nothing to record on a failed delayed payment.

**Both endpoints receive every one of these events, for every subscription on the account —
legacy's included.** That is by design, not a targeting mistake: Stripe delivers every subscribed
event type to every endpoint, with no way to scope a delivery to "only events this app created."
Concretely, a single subscription change delivers to both `thegreatestmusic.org` and
`thegreatest.games`, and both deliveries land within moments of each other. The unique index on
`stripe_events.stripe_event_id` (`app/models/stripe_event.rb`) makes the second delivery
`find_by`-and-reuse the same row rather than inserting a duplicate — see
`Webhooks::StripeController#record_event` — but it does **not** mean the second delivery is a
no-op. `#create` re-enqueues `Billing::ProcessStripeEventJob` whenever that row is still `received`
or `failed`, deliberately: a duplicate is not proof the first delivery was ever processed, and a row
stranded at `received` because `perform_async` failed must not be reported to Stripe as delivered.
Since the two endpoints fire together, the second delivery normally finds the row still `received`
— **two concurrent jobs processing the same event is the norm, not an edge case.** The job and the
services it calls (`ReconcileCustomer`'s advisory lock, `RecordDonation`'s race-recovery rescue) are
what make that converge quietly instead of double-processing; see `docs/features/membership-billing.md`
§12 for how each one does it.

**Copy both endpoints' signing secrets into `STRIPE_WEBHOOK_SECRET` as one comma-separated
value.** Each endpoint gets its own secret from Stripe, and a delivery is only ever signed with
the secret of the endpoint it was sent to
(`Services::Billing::StripeClient.webhook_secrets` / `#verified_event` in
`app/controllers/webhooks/stripe_controller.rb` try every configured secret in turn). Setting only
one secret means every delivery to the *other* endpoint fails signature verification, returns 400,
and Stripe eventually disables that endpoint after enough consecutive failures — a slow, silent
loss of every event from one of the two production hosts. See `deployment/ENV.md`'s
`STRIPE_WEBHOOK_SECRET` entry, which already documents the comma-separated format and shows it in
the example `.env` block.

**Verify:** from each endpoint's detail page in the Dashboard, use "Send test webhook" for
`checkout.session.completed`. Expect a `200` in the delivery log for both endpoints.

- A `403` with a Cloudflare-branded body means step 1's skip rule isn't matching that hostname —
  double check the path and hostname on the rule.
- A `400` almost always means the two secrets got swapped, or only one was deployed — re-check
  `STRIPE_WEBHOOK_SECRET`.

## 3. Write lookup keys onto the two live membership prices

The new app sells through the **same production prices legacy already uses** — see "Legacy
coexistence" in the spec for why. Those prices need a `stripe_lookup_key` so
`Services::Billing::SyncPlans` (`app/lib/services/billing/sync_plans.rb`) can resolve them by a
stable name instead of a hardcoded id:

```
membership monthly -> price_1QvpHqEAWBHYHNGXLPrsxZ0v  (prod_RpUGlPnfnCbn4m)
membership yearly  -> price_1QvpHtEAWBHYHNGXQfQpB9tL  (prod_RpUGy8T59mpSdR)
```

Run, against the live account (`STRIPE_LIVEMODE=true`, live `STRIPE_SECRET_KEY`):

```bash
CONFIRM=label-price bin/rails 'stripe:label_price[price_1QvpHqEAWBHYHNGXLPrsxZ0v,membership_monthly]'
CONFIRM=label-price bin/rails 'stripe:label_price[price_1QvpHtEAWBHYHNGXQfQpB9tL,membership_yearly]'
```

The `CONFIRM=label-price` env var is required — the task (`web-app/lib/tasks/stripe.rake`) refuses
without it, because this writes to the live account.

**A `lookup_key` is a label, nothing else.** `Services::Billing::LabelPrice`
(`app/lib/services/billing/label_price.rb`) calls `Stripe::Price.update(price_id, lookup_key:)`
with `transfer_lookup_key` deliberately **not** set — if the key were already on another price,
Stripe refuses rather than silently moving it. It does not touch the amount, the billing interval,
or anything about an existing subscriber. The task output proves this rather than asking you to
take it on faith: it prints the price's `unit_amount`/`currency`/`active` state, read *after* the
update, so the amount is visibly unchanged:

```
price:      price_1QvpHqEAWBHYHNGXLPrsxZ0v
lookup_key: nil -> "membership_monthly"
amount:     500 usd (unchanged), active=true
```

**Verify:** the `lookup_key: nil -> "membership_monthly"` line (or whatever the *before* value was,
if this is a re-run) confirms the write happened; the `amount: ... (unchanged)` line confirms
nothing else moved. 500/5000 cents ($5.00/mo, $50.00/yr) is what the amounts should read if these
are in fact the membership prices legacy already sells.

## 4. Create the live donation price

```bash
CONFIRM=create-donation-price bin/rails stripe:create_donation_price
```

This runs `Services::Billing::CreateDonationPrice`
(`app/lib/services/billing/create_donation_price.rb`), which creates a **new** Stripe product
("Donation to The Greatest") and a new custom-amount price (`custom_unit_amount`, minimum $1.00,
preset $25.00, `lookup_key: "donation_custom"`). It is additive — nothing existing is touched.
Legacy reads its own eight donation price ids from its own `config/stripe_products.yml` and is
completely unaffected by this new product existing.

The task prints the new price id:

```
price: price_1AbCdE...  (lookup_key donation_custom)
Now run: bin/rails stripe:sync_plans
```

**Write down that price id** — you'll want it in the next step if you seed the `billing_plans` row
by hand before running `sync_plans`, though `sync_plans` will fill it in either way since it
resolves by lookup key, not by id.

**Verify:** the printed `lookup_key` reads `donation_custom`. In the Dashboard, the new product
appears under Products with a single price whose "Customer chooses price" toggle is on.

## 5. Seed the three production `billing_plans` rows, then sync

`billing_plans` (`app/models/billing_plan.rb`) is empty in a fresh production database — there is
no seed task, because a production install only ever happens once and the ids differ per
environment (see `test/fixtures/billing_plans.yml` for the shape these rows take in test). Create
the three rows once, by hand, with `bin/rails runner`:

```bash
bin/rails runner '
BillingPlan.find_or_create_by!(key: "monthly") do |p|
  p.kind = :membership
  p.name = "Monthly Membership"
  p.interval = :monthly
  p.amount_cents = 500
  p.currency = "usd"
  p.stripe_price_id = "price_1QvpHqEAWBHYHNGXLPrsxZ0v"
  p.stripe_lookup_key = "membership_monthly"
  p.position = 0
end
BillingPlan.find_or_create_by!(key: "yearly") do |p|
  p.kind = :membership
  p.name = "Yearly Membership"
  p.interval = :yearly
  p.amount_cents = 5000
  p.currency = "usd"
  p.stripe_price_id = "price_1QvpHtEAWBHYHNGXQfQpB9tL"
  p.stripe_lookup_key = "membership_yearly"
  p.position = 1
end
BillingPlan.find_or_create_by!(key: "donation") do |p|
  p.kind = :donation
  p.name = "One-time Donation"
  p.currency = "usd"
  p.stripe_price_id = "price_from_step_4_output"
  p.stripe_lookup_key = "donation_custom"
  p.position = 2
end
'
```

The exact `amount_cents`/`stripe_price_id` values above don't need to be precise —
`stripe_price_id` only has to be non-blank and unique to satisfy `BillingPlan`'s validations at
insert time, because the very next command overwrites `stripe_price_id`, `amount_cents`,
`currency` and `interval` from the live Stripe account:

```bash
bin/rails stripe:sync_plans
```

`Services::Billing::SyncPlans` resolves each row's Stripe price by `stripe_lookup_key`
(`Stripe::Price.list(lookup_keys: [...], active: true)`) and rewrites those four columns to match
what it finds. It prints `resolved <lookup_key>` for each row that worked.

**Verify:** the command prints `resolved membership_monthly`, `resolved membership_yearly`,
`resolved donation_custom`, then `All plans resolved.`, and exits 0. If it instead prints `FAILED:
could not resolve: ...`, the named lookup key isn't on any active live price yet — go back to step
3 or step 4 for that plan. `/membership` is safe to load in the meantime: it queries
`BillingPlan.membership.active`/`BillingPlan.donation_price` and **renders with zero Stripe API
calls** even with an empty or partial table (`MembershipControllerTest#"the page still renders
when no plans are configured"` covers this) — that's the state production is in between deploy and
this sync, and it degrades to "no plans shown" rather than an error page.

## 6. Activate a Billing Portal configuration

`Services::Billing::CreatePortalSession` (`app/lib/services/billing/create_portal_session.rb`)
calls `Stripe::BillingPortal::Session.create`. Stripe requires a **portal configuration** to exist
for the account before that call succeeds; without one it raises `Stripe::InvalidRequestError` and
every member's "Manage billing" click (`POST /membership/portal`) fails with the app's generic
"Something went wrong" message.

In the Stripe Dashboard: **Settings → Billing → Customer portal**, and activate a configuration.
The specifics (which fields customers can edit, whether they can cancel immediately or at period
end) are a product decision, not something this runbook prescribes — pick something reasonable and
revisit later.

**Do this in both the live account and the sandbox.** The sandbox is a separate, isolated
configuration namespace (see the spec's "Sandboxes" reference); activating it in live does not
activate it in sandbox, and local/staging testing of the portal will fail the same way in sandbox
if it's skipped there.

**Verify:** as a member (comped is fine — comping doesn't need Stripe, see
`docs/features/membership-billing.md` §3), hit `POST /membership/portal` (the "Manage billing"
button on `/membership`, if you have a real `stripe_customer_id`) and confirm it redirects to a
`billing.stripe.com` URL rather than showing the "Something went wrong" alert. A comped member with
no `stripe_customer_id` will instead see "There is no billing account attached to your
membership" — that's the correct, different failure for that case, not this one.

## 7. Re-check the legacy guard, immediately pre-launch

Step 0's checks are worth re-running right before the first live sale, since time may have passed
since you first confirmed them:

- `thegreatestbooks.org` still renders.
- Resend a recent `customer.subscription.updated` from the Dashboard; legacy's
  `/admin/webhook_events` shows it `processed`.
- Legacy's `ignored` rows still read as expected (an `origin_app` tag, a blank `payment_link`, or
  "no resolvable user" — see legacy's `docs/features/stripe_coexistence_guard.md` for the full
  classification table).

## 8. Post-deploy verification

After the app is deployed with `STRIPE_LIVEMODE=true`, the live `STRIPE_SECRET_KEY`, and the
comma-separated `STRIPE_WEBHOOK_SECRET` from step 2:

| Check | What "good" looks like |
|---|---|
| `/membership` renders on all three hosts | Music, games, and books (the new app's own pre-cutover books host — not `thegreatestbooks.org`, which is still legacy) each show $5.00/mo and $50.00/yr, sourced from the `billing_plans` rows seeded in step 5. |
| A real sandbox purchase, end to end | Using **sandbox** keys, not live: sign in, `/membership` → checkout → complete a card on `checkout.stripe.com` → land on `/membership/thanks` → `/members` opens without a redirect. |
| `stripe_events` admin (`/admin/stripe_events`) | Events from the purchase above show `status: processed`. The same event delivered to both endpoints shows as **one row**, not two — the unique index from step 2 is what guarantees this. |
| Legacy's `/admin/webhook_events` | The same events show `status: ignored`, with the `origin_app` reason from legacy's guard classifier. If they show anything else (`processed`, or an error), the legacy guard isn't doing its job and this app's traffic is leaking into legacy's data. |
| `bin/rails billing:verify_migration` | Still reports `All invariants hold.` — a new live sale should never regress the legacy migration invariants; if it does, something is attaching new-app subscriptions to legacy-migrated rows incorrectly. |

## 9. Rollback

If something is wrong after the endpoints go live:

1. **Disable both webhook endpoints** in the Stripe Dashboard (not delete — disable). Events queue
   on Stripe's side for up to 72 hours, and `billing:reconcile_all` (also the nightly
   `sidekiq-cron` sweep at 05:00 UTC, `Billing::ReconcileAllCustomersJob`) is the backstop that
   catches up once the endpoints are re-enabled or once the sweep runs on its own.
2. **Revert the deploy.**

**Never run `rake stripe:delete_webhooks` on legacy as part of any rollback or cleanup here.** The
guard patch scoped it to delete only the endpoint whose URL legacy itself registers — but that
scoping only protects on a checkout of the patched branch. On any unpatched checkout of the legacy
repo, or if the patch is ever reverted, that task deletes **every** endpoint on the shared account,
including both of this app's. There is no legitimate reason to run it from this side of the
account at all.

**This danger does not end once the guard patch is deployed — it changes shape at books cutover.**
Legacy's own `docs/features/stripe_coexistence_guard.md` documents a second landmine in the same
task, for whoever eventually writes the books-cutover runbook: the scoped version resolves "my
endpoint" by URL, and legacy's URL is `https://thegreatestbooks.org/webhooks/stripe` — the exact
path this app also serves. Once `thegreatestbooks.org` is repointed at this app during cutover,
"delete only my own endpoint" resolves to **this app's** endpoint, not legacy's, at precisely the
moment someone on the legacy side is likely to run it to clean up. Legacy's doc's own remedy is to
never run `stripe:delete_webhooks` at or after cutover, and to remove legacy's endpoint from the
Stripe Dashboard by hand instead — the cutover runbook should carry that instruction forward.

## See also

- `docs/specs/membership-and-stripe-billing.md` — the design spec this runbook implements,
  especially "Legacy coexistence" and "Data migration".
- `docs/features/membership-billing.md` — the subsystem doc: entitlement rules, the paywall
  registry, the checkout flow, and the day-to-day admin runbooks (attaching an unattached
  membership, re-running a failed event, and so on).
- `deployment/ENV.md` — the full `STRIPE_*` environment variable reference.

## Ops follow-ups (not blocking, worth doing)

Two gaps surfaced during review of this branch that aren't part of the Stripe setup itself, but
are worth fixing in the deployment configuration:

- **Set `config.hosts` in `web-app/config/environments/production.rb`.** It's commented out today.
  This app's Stripe redirect URLs (`success_url`/`cancel_url`/the portal's `return_url`) are no
  longer built from `request.host` — `MembershipController#canonical_host` reads
  `Rails.application.config.domains[Current.domain]` instead, specifically because `request.host`
  is attacker-controlled here (nginx forwards the raw client `Host` header via
  `proxy_set_header Host $http_host;` in `deployment/nginx/snippets/proxy-params.conf`, and
  `config.hosts` isn't set to reject an unrecognised one). So this specific exploit path is closed
  for checkout. But `config.hosts` protects every *other* place in the app that might read
  `request.host` without knowing about this hazard, present or future, and Rails' own comment in
  that file calls it out as DNS-rebinding protection for exactly this reason. Setting it is small
  and has no known downside; there's just no code path in this branch that strictly requires it.
- **Configure nginx's `real_ip` module with Cloudflare's published IP ranges.** Today nginx has no
  `real_ip` configuration at all (`deployment/nginx/nginx.conf`), so `request.remote_ip` inside
  Rails resolves to the Cloudflare edge IP that proxied the request, not the visitor's own IP —
  every visitor behind the same Cloudflare PoP looks identical to Rails. `MembershipController`'s
  anonymous rate limits (on `:donate` and the `:thanks` return page) already prefer Cloudflare's
  `CF-Connecting-IP` header over `request.remote_ip` for exactly this reason (see the
  `#visitor_ip` comment there), which is correct **only** for traffic that actually passed through
  Cloudflare. A request sent straight to the origin's IP (bypassing Cloudflare entirely) can set
  `CF-Connecting-IP` to anything it likes, since nothing verifies the request came from
  Cloudflare's edge — that forges past the anonymous donation rate limit completely. The real fix
  is nginx's `real_ip` module (`set_real_ip_from` for each of Cloudflare's published ranges,
  `real_ip_header CF-Connecting-IP`), which makes Rails trust the header only when the *connecting*
  nginx peer is actually one of Cloudflare's own IPs — closing the forgery path structurally
  instead of by convention. This is a deployment/nginx change, not an application code change,
  which is why it's listed here rather than fixed in this branch.
