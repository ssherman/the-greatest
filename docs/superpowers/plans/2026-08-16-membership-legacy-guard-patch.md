# Legacy Guard Patch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the legacy books app from choking on, or silently absorbing, the Stripe events that the new app's checkout will start producing in the shared Stripe account — and stop its webhook cleanup task from deleting the new app's endpoint.

**Architecture:** Three changes to `WebhooksController` and one to `StripeService`, all in the **separate legacy repository**. A `before_action` skips any event tagged as belonging to the other app, before a single row is written. A second discriminator skips Checkout Sessions that did not originate from one of legacy's own Stripe payment links — legacy sells exclusively through payment links, so "no payment link" is a structural, metadata-independent proof of "not mine". A backstop turns "no user could be resolved" from a raise into a logged skip. Separately, `stripe:delete_webhooks` is scoped to legacy's own endpoint URL instead of every endpoint in the account.

**Tech Stack:** Rails 8.1.1 on Ruby 3.4.7, stripe-ruby 17.2.0, Minitest + Mocha, PostgreSQL. Legacy repo only — the new app's Rails 8 / standardrb / daisyUI conventions do **not** apply there.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — this plan is **plan 3 of 6**, covering spec increment **10** ("Legacy guard patch"). Read the spec's "Legacy coexistence" section alongside this plan.

## Plan decomposition

| Plan | Spec increments | Status |
|---|---|---|
| Billing core | 1, 2, 3 | **MERGED + deployed** (PRs #228, #229, #231) |
| Data migration & admin | 4, 9 | **MERGED** (PR #233) |
| **Legacy guard patch** (this plan) | **10** | this one — separate repository |
| Mail foundation | 5 | not started |
| Selling: checkout, join page, entitlements, E2E | 6, 7, 11 | not started |
| Membership emails | 8 | not started |

**This must be deployed before increment 6 (Checkout) reaches production.** Increment 6 is the moment the new app first creates a subscription in the shared Stripe account.

---

## Where the work happens

Almost all of this plan runs in a **different repository from the one this plan file lives in**.

| | Path | Repo | Visibility |
|---|---|---|---|
| Tasks 1–6 | `/home/shane/dev/the-greatest-books/admin` | `ssherman/the-greatest-books` | **private** |
| Task 7 | this worktree (`web-app/..`, `docs/`) | `ssherman/the-greatest` | **public** |

Consequences that bind every task:

- **Do not `cd` between them inside one command.** Legacy work happens entirely under `/home/shane/dev/the-greatest-books/admin`; Task 7 happens entirely in this worktree.
- **Branch, commit, do not push.** Create `stripe-coexistence-guard` off `main` in the legacy repo and commit each task. Pushing legacy `main` **deploys to production immediately** (see the deploy pipeline section). Do not push and do not open a PR without asking the owner.
- **This plan file is committed to a public repository.** Do not paste real secrets into it or into any commit message: no `whsec_`, no `sk_live_`, no master key. Stripe **price and product ids are already public** in the spec and in legacy's `config/stripe_products.yml` — those are fine.

### Running commands in the legacy repo from this session

This session is worktree-isolated and refuses shell commands it cannot statically prove stay inside the worktree — which includes `export VAR=... ; cd elsewhere && …` chains. **Write a shell script into the scratchpad directory and run `bash <script>` instead.** Every command in this plan is given in that form.

The legacy app needs Ruby 3.4.7 from mise, which is installed but whose config file is untrusted, so use the interpreter path directly rather than `mise exec`:

```bash
# scratchpad/legacy.sh — the preamble every legacy command needs
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
```

---

## Verified facts about the legacy app

Measured on **2026-08-16** against the legacy repo at `f1c12cbb` and a freshly built local `tgb_test` database. Everything in this section was run, not inferred.

### The bug this patch fixes, reproduced

A realistic `customer.subscription.created` for a subscription the new app would create — customer unknown to legacy, `client_reference_id` a new-app user id above 150,000 — produces:

```
NEWAPP_STATUS      => 422
NEWAPP_EVENT_ROWS  => ["failed"]
NEWAPP_SUB_ROWS    => 0
```

422 is `ActiveRecord::RecordInvalid` from `subscription.update!(user: nil, …)`: `Subscription` declares a bare `belongs_to :user` and legacy runs `load_defaults 7.0`, so the association is required. Stripe retries a 422 for 72 hours and can disable the endpoint. (With a *truncated* payload the same path 500s earlier, at `Time.at(nil)`. Both outcomes trigger the same retry loop.)

### The second defect, which the spec does not mention

Legacy also receives `checkout.session.completed` for the new app's **donations**, and `Donation` declares `belongs_to :user, optional: true`. A payment-mode session with no resolvable user does not raise — it succeeds:

```
SESSION_STATUS    => 200
SESSION_DONATIONS => 1
```

So a donation taken on music or games would write a row into the books database and send the donor a books-branded thank-you from `contact@thegreatestbooks.org`, plus an admin notification. No error anywhere. The owner approved covering this.

### What makes "not mine" decidable

- **Legacy never creates a Checkout Session.** `Stripe::Checkout::Session.create` appears nowhere in the legacy codebase; the only call is `.list`, used to recover a `client_reference_id`. Every checkout session legacy is responsible for was created by a Stripe **Payment Link** (`SupportController#index` renders `StripeService.payment_links`), and Stripe sets `payment_link` on those sessions. `payment_link` being blank therefore means the session is not legacy's.
- **Legacy sets no subscription metadata at all.** Payment Link `metadata` (`price_id`, `created_by`) is copied to the *session*, never to the subscription. So a legacy subscription's `metadata[origin_app]` is always nil, and the new app's tag can never collide with it.
- **Price ids cannot be used as the discriminator.** By design the new app sells through legacy's own production prices (`price_1QvpHq…`, `price_1QvpHt…`), so both apps' subscriptions carry identical price ids.

### stripe-ruby 17.2.0 accessor behaviour (probed directly)

| Expression | Result |
|---|---|
| `object[:payment_link]` when the field is absent | `nil` |
| `object[:metadata]` when absent | `nil` |
| `invoice[:subscription_details]&.[](:metadata)&.[](:origin_app)` | `"the-greatest"` |
| `metadata["origin_app"]` and `metadata[:origin_app]` | both work — `[]` calls `to_sym` |
| `Stripe::ListObject.construct_from(has_more: false, data: […]).auto_paging_each` | yields typed objects, no network |

**Rule for the guard code: always use `object[:key]`, never `object.key`.** `[]` returns nil for a missing field; method access on an untyped nested Stripe object raises `NoMethodError`, which would 500 and start exactly the retry loop this patch exists to prevent.

### Test harness state — three landmines

The owner's words: *"the legacy app is hard to get up and running locally and the tests are broken."* Confirmed, and all three are worked around below. **These workarounds are why the plan is runnable at all — do not skip them.**

1. **Any failing test crashes the whole run.** `shoulda-context` 2.0.0 patches `Rails::TestUnitReporter#format_rerun_snippet` to call `executable`, which Rails 8 removed. The first failure raises `NameError` mid-report and no further tests run — so a TDD "watch it fail" step produces a stack trace instead of a failure message. Task 1 adds a four-line shim to `test_helper.rb`. Verified: with the shim, a deliberate failure reports cleanly and later tests still run.
2. **`create(:user)` fails on a fresh database.** `db/seeds.rb` inserts `User.create(id: 1)` without advancing the sequence, and `test_helper.rb` runs `Rails.application.load_seed` in *every* `setup`. The next factory-built user asks for id 1 and hits `PG::UniqueViolation`. **Build users with explicit ids** (`User.create!(id: 90_002, …)`) — which suits this patch, since the whole bug is about which id range a user came from.
3. **The webhook tests will really call SendGrid unless stubbed.** `Email#send` posts to the SendGrid API directly with no test adapter. Locally it fails on a nil key, but on a machine holding the master key it would send. **Every webhook test must stub `Email.any_instance.stubs(:send)`.**

Beyond those, the environment works: the suite boots, connects, seeds, and runs a targeted file in about a second.

### Environment prep already done for you

Do not redo these; they are complete as of 2026-08-16:

- `bundle install` under Ruby 3.4.7 — 225 gems, exit 0.
- `tgb_test` created in the `the-greatest-db-1` Postgres container on `localhost:6543` (a *different* database from `the_greatest_development` — the books dev data is untouched).
- The one pending legacy migration, `20260409160000_add_unique_index_to_subscriptions_stripe_subscription_id`, applied to `tgb_test`.
- That migration's `db/schema.rb` regeneration is **already sitting uncommitted in the legacy working tree**. The diff is exactly two lines (the version stamp and one index line) and Task 1 commits it. It had never been dumped locally, which is why a fresh test database reports "Migrations are pending" and refuses to run.

### The legacy deploy pipeline (why "just push it" is dangerous)

`.github/workflows/deploy-image.yaml` fires on **push to `main`**: it builds `admin/Dockerfile.web.prod`, pushes `ghcr.io/ssherman/the-greatest-books:main`, and on success dispatches `deploy.yaml`, which SSHes into the DB and web servers and runs `docker compose pull && up -d`.

- **There is no test gate and no lint gate. Nothing runs the suite before production.** Merging to `main` *is* deploying.
- The container's `bin/docker-entrypoint` is `#!/bin/bash -e` and runs `./bin/rails db:prepare` before `exec`ing the server, with `restart: unless-stopped` on the service. **A boot failure crash-loops the web container and 502s thegreatestbooks.org.** This patch adds no migration, so `db:prepare` is a no-op — but production **eager-loads**, so a constant or syntax error in `WebhooksController` or `StripeService` would take the site down. Task 6's `zeitwerk:check` exists for exactly this.
- The image build itself is a partial safety net: if the Docker build fails, the deploy step is skipped and the running container is untouched.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Tasks 1–6 are in the legacy repo**, `/home/shane/dev/the-greatest-books/admin`, on a branch `stripe-coexistence-guard` cut from `main`. **Never push. Never open a PR.** Ask the owner first.
- **Legacy conventions, not the new app's.** Two-space indent, `# frozen_string_literal: true` at the top of every Ruby file, `private` indented one level inside the class body with its methods indented under it (match the surrounding file exactly). Linter is `bin/rubocop` (rubocop-rails_config) — **not** standardrb.
- **The event tag is the exact string `"the-greatest"`**, matched against `metadata[origin_app]`. Define it once as `WebhooksController::FOREIGN_ORIGIN_APP`.
- **Never log a webhook payload.** Log the event id, the event type, and the reason. Payloads carry another site's customer email and postal address.
- **Never use method access on Stripe payload objects** — `object[:key]` only. See the accessor table above.
- **Add no gems, no migrations, no schema changes** beyond the already-generated `db/schema.rb` dump committed in Task 1.
- **Run the legacy suite with `bundle exec ruby -Itest <file>`** (plain Minitest), not `bin/rails test`. Both work now that the reporter shim is in, but `-Itest` on a single file is the fast loop.
- **Do not touch** `handle_invoice_paid`, `handle_invoice_payment_failed`, `handle_subscription_deletion`, the eight email bodies, `Email`, or `config/stripe_products.yml`. They are correct for legacy's own traffic and legacy retires in about two months.
- **Do not "fix" the four legacy ordering guards** (the created-event downgrade check, the checkout-session user recovery, the `RecordNotUnique` retry, the `email_sent` flag). The new app deletes that bug class structurally; legacy keeps living with it.
- **Do not scope `deactivate_all_payment_links`.** The owner chose not to: the new app creates no payment links, so it is harmless, and changing it risks a legacy path that still runs.

---

## Task 1: Make the legacy test suite usable, and pin current behaviour

The regression net. Written and committed **before any behaviour changes**, so every later task can prove it did not break legacy's own subscribers.

**Files:**
- Modify: `test/test_helper.rb` (add the reporter shim, after the `Shoulda::Matchers.configure` block at the end)
- Modify: `test/controllers/webhooks_controller_test.rb` (currently an empty two-line class)
- Commit: `db/schema.rb` (already modified in the working tree — do not regenerate it)

**Interfaces:**
- Consumes: nothing.
- Produces: the private test helpers `post_stripe_event(payload_hash)`, `subscription_event(...)` and `checkout_session_event(...)`, plus the `WEBHOOK_SECRET` constant and the `setup` credential stub. Tasks 2–4 add tests to this same file and reuse them verbatim.

- [ ] **Step 1: Cut the branch and confirm the starting state**

```bash
# scratchpad/t1-branch.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git checkout -b stripe-coexistence-guard
git status --short
```

Expected: the branch is created and `git status --short` shows exactly ` M db/schema.rb` and nothing else.

- [ ] **Step 2: Add the reporter shim to `test/test_helper.rb`**

Append at the very end of the file, after the `Shoulda::Matchers.configure` block:

```ruby
# shoulda-context 2.0.0 patches Rails::TestUnitReporter#format_rerun_snippet to
# call `executable`, which Rails 8 removed. Without this shim the FIRST failing
# test raises NameError while reporting itself, aborting the run before any
# later test executes — so a failure looks like a crash and hides everything
# after it.
Rails::TestUnitReporter.class_eval do
  def executable
    "bin/rails test"
  end
end
```

- [ ] **Step 3: Write the characterization tests**

Replace the whole of `test/controllers/webhooks_controller_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  WEBHOOK_SECRET = "whsec_test_dummy_secret"

  def setup
    super
    # The local checkout has no config/master.key, so Rails.application.credentials
    # returns nil for everything. Stub the lookup the controller performs; the
    # signature below is then generated and verified for real.
    Rails.application.credentials.stubs(:stripe).returns({test: {webhook_secret: WEBHOOK_SECRET}})
    # Email#send posts straight to the SendGrid API with no test adapter.
    Email.any_instance.stubs(:send).returns(true)
  end

  # Signs "#{timestamp}.#{payload}" with HMAC-SHA256 exactly as Stripe does, so
  # real signature verification runs and no captured secret lives in the repo.
  def post_stripe_event(payload_hash)
    payload = payload_hash.to_json
    timestamp = Time.now.to_i
    digest = OpenSSL::HMAC.hexdigest("SHA256", WEBHOOK_SECRET, "#{timestamp}.#{payload}")

    post "/webhooks/stripe",
      params: payload,
      headers: {
        "HTTP_STRIPE_SIGNATURE" => "t=#{timestamp},v1=#{digest}",
        "CONTENT_TYPE" => "application/json"
      }
  end

  def subscription_event(id:, customer:, metadata: {}, type: "customer.subscription.created")
    {
      id: "evt_#{id}",
      object: "event",
      type: type,
      data: {object: {
        id: id,
        object: "subscription",
        customer: customer,
        status: "active",
        metadata: metadata,
        current_period_end: 30.days.from_now.to_i,
        items: {object: "list", data: [{
          id: "si_#{id}",
          object: "subscription_item",
          price: {id: "price_1QvpHqEAWBHYHNGXLPrsxZ0v", recurring: {interval: "month"}}
        }]}
      }}
    }
  end

  def checkout_session_event(id:, mode:, payment_link: nil, metadata: {}, client_reference_id: nil,
    customer: "cus_test", payment_intent: nil, amount_total: 2500)
    {
      id: "evt_#{id}",
      object: "event",
      type: "checkout.session.completed",
      data: {object: {
        id: id,
        object: "checkout.session",
        mode: mode,
        customer: customer,
        client_reference_id: client_reference_id,
        payment_link: payment_link,
        payment_intent: payment_intent,
        amount_total: amount_total,
        metadata: metadata,
        customer_details: {email: "donor@example.com"}
      }}
    }
  end

  test "a wrongly signed request is rejected and writes nothing" do
    post "/webhooks/stripe",
      params: {id: "evt_bogus"}.to_json,
      headers: {"HTTP_STRIPE_SIGNATURE" => "t=1,v1=deadbeef", "CONTENT_TYPE" => "application/json"}

    assert_response :bad_request
    assert_equal 0, WebhookEvent.where(provider_event_id: "evt_bogus").count
  end

  test "a legacy subscription with a resolvable user is still recorded" do
    user = User.create!(id: 90_002, email: "legacy-member@example.com", stripe_customer_id: "cus_legacy")
    StripeService.stubs(:get_customer)
      .returns(Stripe::Customer.construct_from(id: "cus_legacy", email: user.email))

    post_stripe_event(subscription_event(id: "sub_legacy", customer: "cus_legacy"))

    assert_response :ok
    subscription = Subscription.find_by(stripe_subscription_id: "sub_legacy")
    assert_not_nil subscription
    assert_equal user.id, subscription.user_id
    assert_equal "active", subscription.status
    assert_equal "monthly", subscription.subscription_type
    assert_equal ["processed"], WebhookEvent.where(provider_event_id: "evt_sub_legacy").pluck(:status)
  end

  test "a legacy payment-link donation is still recorded" do
    post_stripe_event(checkout_session_event(
      id: "cs_legacy_donation",
      mode: "payment",
      payment_link: "plink_legacy",
      payment_intent: "pi_legacy_donation"
    ))

    assert_response :ok
    donation = Donation.find_by(stripe_payment_id: "pi_legacy_donation")
    assert_not_nil donation
    assert_equal 2500, donation.amount
    assert_equal "succeeded", donation.status
  end
end
```

- [ ] **Step 4: Run them against unmodified application code**

```bash
# scratchpad/t1-test.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
bundle exec ruby -Itest test/controllers/webhooks_controller_test.rb
```

Expected: **3 runs, 0 failures, 0 errors.** All three describe behaviour that already exists — this step proves the harness works and pins the "before" picture, so a later task cannot quietly break legacy's own subscribers.

If a test fails here, the harness is wrong, not the app. Do not change `WebhooksController` to make it pass.

- [ ] **Step 5: Commit**

```bash
# scratchpad/t1-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add test/test_helper.rb test/controllers/webhooks_controller_test.rb db/schema.rb
git commit -m "test(webhooks): pin current Stripe webhook behaviour before the coexistence guard

The webhooks controller had no test coverage at all. These three tests
describe what legacy does today — reject a bad signature, record a
subscription for a known user, record a payment-link donation — so the
guard that follows can be shown not to disturb it.

Also fixes two things that made the suite unusable: shoulda-context's
reporter patch calls a method Rails 8 removed, so the first failure
aborted the run, and db/schema.rb had never been dumped after the
subscriptions unique-index migration, so a fresh test database refused
to run at all."
```

---

## Task 2: Skip events tagged as belonging to the new app

**Files:**
- Modify: `app/controllers/webhooks_controller.rb` (constant + `before_action` at the top, two private methods)
- Test: `test/controllers/webhooks_controller_test.rb` (add to the file from Task 1)

**Interfaces:**
- Consumes: Task 1's `post_stripe_event`, `subscription_event`, `WEBHOOK_SECRET`, `setup`.
- Produces: `WebhooksController::FOREIGN_ORIGIN_APP` (`"the-greatest"`), and the private methods `skip_events_from_other_apps` (a `before_action`), `other_app_event_reason` → `String | nil`, and `origin_app(object)` → `String | nil`. Task 3 adds a second branch to `other_app_event_reason`.

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/webhooks_controller_test.rb`, after the existing tests:

```ruby
  test "a subscription tagged as the new app's is skipped entirely" do
    post_stripe_event(subscription_event(
      id: "sub_newapp",
      customer: "cus_newapp",
      metadata: {origin_app: "the-greatest", app_user_id: "150001"}
    ))

    assert_response :ok
    assert_equal 0, Subscription.where(stripe_subscription_id: "sub_newapp").count
    assert_equal 0, WebhookEvent.where(provider_event_id: "evt_sub_newapp").count
  end

  test "a subscription update tagged as the new app's is skipped too" do
    post_stripe_event(subscription_event(
      id: "sub_newapp_upd",
      customer: "cus_newapp",
      metadata: {origin_app: "the-greatest"},
      type: "customer.subscription.updated"
    ))

    assert_response :ok
    assert_equal 0, Subscription.where(stripe_subscription_id: "sub_newapp_upd").count
    assert_equal 0, WebhookEvent.where(provider_event_id: "evt_sub_newapp_upd").count
  end

  test "an invoice for a subscription tagged as the new app's is skipped" do
    post_stripe_event({
      id: "evt_in_newapp",
      object: "event",
      type: "invoice.paid",
      data: {object: {
        id: "in_newapp",
        object: "invoice",
        customer: "cus_newapp",
        subscription: "sub_newapp",
        subscription_details: {metadata: {origin_app: "the-greatest"}},
        lines: {object: "list", data: [{period: {end: 30.days.from_now.to_i}}]}
      }}
    })

    assert_response :ok
    assert_equal 0, WebhookEvent.where(provider_event_id: "evt_in_newapp").count
  end

  test "a legacy subscription carrying unrelated metadata is not skipped" do
    User.create!(id: 90_003, email: "other-member@example.com", stripe_customer_id: "cus_other")
    StripeService.stubs(:get_customer)
      .returns(Stripe::Customer.construct_from(id: "cus_other", email: "other-member@example.com"))

    post_stripe_event(subscription_event(
      id: "sub_other",
      customer: "cus_other",
      metadata: {campaign: "spring", origin_app: "some-other-thing"}
    ))

    assert_response :ok
    assert_not_nil Subscription.find_by(stripe_subscription_id: "sub_other")
  end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
# scratchpad/t2-test.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
bundle exec ruby -Itest test/controllers/webhooks_controller_test.rb
```

Expected: 7 runs, **3 failures**, and the fourth new test ("unrelated metadata is not skipped") already passing.

The three failures should read roughly:
- the subscription tests: `Expected: 0, Actual: 1` on the `WebhookEvent` count, having returned 422 rather than 200
- the invoice test: `Expected: 0, Actual: 1` on the `WebhookEvent` count (invoice handling returns 200 today but still writes the inbox row)

If the run aborts with a `NameError` in `format_rerun_snippet` instead of reporting failures, Task 1 Step 2's shim is missing.

- [ ] **Step 3: Add the constant and the filter**

In `app/controllers/webhooks_controller.rb`, replace the class opening:

```ruby
class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_stripe_webhook_signature
```

with:

```ruby
class WebhooksController < ApplicationController
  # Subscriptions and Checkout Sessions created by The Greatest — the new
  # multi-site app that shares this Stripe account — carry this in their
  # metadata. This app never sets origin_app on anything, so the check reads as
  # an explicit "not mine" rather than an inference from a missing user.
  FOREIGN_ORIGIN_APP = "the-greatest"

  skip_before_action :verify_authenticity_token
  before_action :verify_stripe_webhook_signature
  before_action :skip_events_from_other_apps
```

- [ ] **Step 4: Add the two private methods**

In the `private` section of `app/controllers/webhooks_controller.rb`, immediately after `verify_stripe_webhook_signature` and before `handle_subscription_update`:

```ruby
    # Both applications receive every event of the subscribed types on this
    # shared Stripe account, including events for subscriptions this app did
    # not create. Handling one of those raises — belongs_to :user is required
    # on Subscription — which returns 422, makes Stripe retry the same event
    # for 72 hours, and can get this endpoint disabled. Skip before anything is
    # written, so no row and no other site's customer data lands here.
    def skip_events_from_other_apps
      reason = other_app_event_reason
      return if reason.nil?

      # Identifiers only. The payload carries the other site's customer email
      # and address.
      Rails.logger.info "Skipping Stripe event #{@event.id} (#{@event.type}): #{reason}"
      head :ok
    end

    # Returns why this event belongs to another application, or nil when it is
    # ours to handle.
    def other_app_event_reason
      object = @event.data.object

      return "metadata origin_app=#{FOREIGN_ORIGIN_APP}" if origin_app(object) == FOREIGN_ORIGIN_APP

      nil
    end

    # Finds origin_app wherever the event type in question keeps it: directly on
    # subscriptions and checkout sessions, and under subscription_details on
    # invoices (moved beneath parent in Stripe's Basil release and later).
    #
    # Reads with [] rather than method access throughout. On a Stripe object []
    # returns nil for a field the payload does not contain, while method access
    # on an untyped nested object raises NoMethodError — a 500, and the same
    # 72-hour retry loop this guard exists to prevent.
    def origin_app(object)
      candidates = [
        object[:metadata],
        object[:subscription_details]&.[](:metadata),
        object[:parent]&.[](:subscription_details)&.[](:metadata)
      ]

      candidates.compact.each do |metadata|
        value = metadata[:origin_app]
        return value.to_s if value.present?
      end

      nil
    end
```

- [ ] **Step 5: Run the tests and watch them pass**

Run `scratchpad/t2-test.sh` again. Expected: **7 runs, 0 failures, 0 errors.** The three Task 1 tests must still pass — that is the point of having written them first.

- [ ] **Step 6: Commit**

```bash
# scratchpad/t2-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add app/controllers/webhooks_controller.rb test/controllers/webhooks_controller_test.rb
git commit -m "fix(webhooks): skip Stripe events belonging to the new app

The Greatest shares this Stripe account and is about to start selling
memberships through the same production prices. Its subscription events
arrive here for a customer this database has never seen, and the handler
calls update!(user: nil), which raises: 422, a 72-hour Stripe retry
loop, and eventually a disabled endpoint.

Subscriptions and checkout sessions it creates carry
metadata[origin_app] = the-greatest. Skip those before the inbox row is
written, logging the event id and type only."
```

---

## Task 3: Skip checkout sessions that did not come from a legacy payment link

The metadata tag is the primary guard. This is the structural one: it does not depend on the other app remembering to set anything, and it is what stops a music-site donation from writing a books donation row and emailing the donor a books-branded receipt.

**Files:**
- Modify: `app/controllers/webhooks_controller.rb` (one branch added to `other_app_event_reason`)
- Test: `test/controllers/webhooks_controller_test.rb`

**Interfaces:**
- Consumes: Task 2's `other_app_event_reason`; Task 1's `checkout_session_event`.
- Produces: no new names.

- [ ] **Step 1: Write the failing tests**

Add to `test/controllers/webhooks_controller_test.rb`:

```ruby
  test "a payment-mode checkout session with no payment link writes no donation" do
    post_stripe_event(checkout_session_event(
      id: "cs_newapp_donation",
      mode: "payment",
      payment_link: nil,
      payment_intent: "pi_newapp_donation",
      client_reference_id: "150001"
    ))

    assert_response :ok
    assert_equal 0, Donation.where(stripe_payment_id: "pi_newapp_donation").count
    assert_equal 0, WebhookEvent.where(provider_event_id: "evt_cs_newapp_donation").count
  end

  test "a subscription-mode checkout session with no payment link touches no user" do
    user = User.create!(id: 90_004, email: "collision@example.com", stripe_customer_id: "cus_legacy_owned")

    post_stripe_event(checkout_session_event(
      id: "cs_newapp_sub",
      mode: "subscription",
      payment_link: nil,
      customer: "cus_newapp",
      client_reference_id: user.id.to_s
    ))

    assert_response :ok
    assert_equal "cus_legacy_owned", user.reload.stripe_customer_id
  end
```

The second test is the id-collision guard the spec's Risks section worries about: legacy is still creating users, and if its ids ever reach the new app's range, a `client_reference_id` from the new app would match a real legacy user and `handle_checkout_session_completed` would overwrite that person's `stripe_customer_id`, silently detaching them from their own subscription.

- [ ] **Step 2: Run them and watch them fail**

Run `scratchpad/t2-test.sh`. Expected: 9 runs, **2 failures** — `Expected: 0, Actual: 1` on the donation count, and `Expected: "cus_legacy_owned", Actual: "cus_newapp"` on the reloaded user.

- [ ] **Step 3: Add the branch**

In `app/controllers/webhooks_controller.rb`, extend `other_app_event_reason`:

```ruby
    def other_app_event_reason
      object = @event.data.object

      return "metadata origin_app=#{FOREIGN_ORIGIN_APP}" if origin_app(object) == FOREIGN_ORIGIN_APP

      # This app has never created a Checkout Session — it sells entirely
      # through Stripe Payment Links, and Stripe stamps payment_link on every
      # session one of those produces. A session without it therefore came from
      # somewhere else, whether or not it carries the metadata tag above. This
      # is the backstop that keeps another site's donation from landing in this
      # database and mailing its donor a Greatest Books receipt.
      if @event.type == "checkout.session.completed" && object[:payment_link].blank?
        return "checkout session did not originate from one of this app's payment links"
      end

      nil
    end
```

- [ ] **Step 4: Run the tests and watch them pass**

Run `scratchpad/t2-test.sh`. Expected: **9 runs, 0 failures, 0 errors.** In particular Task 1's "a legacy payment-link donation is still recorded" must still pass — it is the proof this branch does not cost legacy its own donations.

- [ ] **Step 5: Commit**

```bash
# scratchpad/t3-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add app/controllers/webhooks_controller.rb test/controllers/webhooks_controller_test.rb
git commit -m "fix(webhooks): ignore checkout sessions from outside this app

Donation model allows a nil user, so a donation taken on music or games
did not raise here — it quietly wrote a donation row into this database
and emailed the donor a Greatest Books thank-you.

This app creates no Checkout Sessions; it sells through Payment Links,
and Stripe stamps payment_link on every session those produce. A session
without one is not ours, independently of whether the other app
remembered to tag it. That also stops a new-app client_reference_id from
ever overwriting a legacy user's stripe_customer_id."
```

---

## Task 4: Turn an unresolvable user into a logged skip

The last-resort backstop. If increment 6 ships without its metadata tag — the single most likely way this whole scheme fails — this is what stops legacy 422ing and losing its webhook endpoint.

**Files:**
- Modify: `app/models/webhook_event.rb` (add `mark_ignored!`)
- Modify: `app/controllers/webhooks_controller.rb` (`stripe` action, `handle_subscription_update`)
- Test: `test/controllers/webhooks_controller_test.rb`, `test/models/webhook_event_test.rb`

**Interfaces:**
- Consumes: Task 1's helpers.
- Produces: `WebhookEvent#mark_ignored!(reason = nil)`, which sets `status: :ignored`, `processed_at`, and `error`.

- [ ] **Step 1: Write the failing tests**

Add to `test/models/webhook_event_test.rb`, inside the existing empty class:

```ruby
  test "mark_ignored! records the status, the time and the reason" do
    event = WebhookEvent.create!(
      provider: :stripe,
      provider_event_id: "evt_ignored",
      event_type: "customer.subscription.created",
      payload: {id: "sub_x"},
      status: :pending
    )

    event.mark_ignored!("No user could be resolved")

    assert event.ignored?
    assert_not_nil event.processed_at
    assert_equal "No user could be resolved", event.error
  end
```

Add to `test/controllers/webhooks_controller_test.rb`:

```ruby
  test "an untagged subscription with no resolvable user is skipped, not failed" do
    StripeService.stubs(:find_checkout_session_for_subscription).returns(nil)

    post_stripe_event(subscription_event(id: "sub_orphan", customer: "cus_unknown"))

    assert_response :ok
    assert_equal 0, Subscription.where(stripe_subscription_id: "sub_orphan").count
    event = WebhookEvent.find_by(provider_event_id: "evt_sub_orphan")
    assert_not_nil event
    assert event.ignored?
  end
```

Note what this test asserts about today's behaviour: the event is **recorded** as ignored rather than dropped. That is deliberate — unlike a tagged event, an unresolvable one is a signal worth keeping, and it shows up in legacy's existing admin webhook-events list.

- [ ] **Step 2: Run them and watch them fail**

```bash
# scratchpad/t4-test.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
bundle exec ruby -Itest test/models/webhook_event_test.rb
bundle exec ruby -Itest test/controllers/webhooks_controller_test.rb
```

Expected: the model test fails with `NoMethodError: undefined method 'mark_ignored!'`; the controller test fails with `Expected response to be a <2XX>, but was <422>`.

- [ ] **Step 3: Add `mark_ignored!` to the model**

In `app/models/webhook_event.rb`, after `mark_processed!`:

```ruby
  def mark_ignored!(reason = nil)
    update!(
      status: :ignored,
      processed_at: Time.current,
      error: reason
    )
  end
```

- [ ] **Step 4: Add the backstop to the controller**

In `handle_subscription_update`, insert this immediately after the `if user.nil?` recovery block that calls `find_checkout_session_for_subscription`, and immediately **before** `subscription.update!`:

```ruby
      # Backstop. belongs_to :user is required on Subscription, so
      # update!(user: nil, …) raises RecordInvalid, returns 422, and Stripe
      # retries the same event for 72 hours before disabling the endpoint. A
      # subscription this app cannot attribute to anyone is not this app's to
      # record — skipping it is strictly better than the retry loop. Catches
      # whatever the origin_app guard misses: a subscription created straight
      # from the Stripe dashboard, or one from the other app that shipped
      # without its metadata tag.
      if user.nil?
        Rails.logger.warn "Skipping subscription #{stripe_subscription_id}: no user for Stripe customer #{subscription_data.customer}"
        webhook_event.mark_ignored!("No user could be resolved for Stripe customer #{subscription_data.customer}")
        return
      end
```

Then, in the `stripe` action, change:

```ruby
      webhook_event.mark_processed!
      head :ok
```

to:

```ruby
      # A handler that skipped its event has already marked it ignored; don't
      # overwrite that with "processed", which would claim work that never
      # happened.
      webhook_event.mark_processed! unless webhook_event.ignored?
      head :ok
```

- [ ] **Step 5: Run the tests and watch them pass**

Run `scratchpad/t4-test.sh`. Expected: the model file is 1 run / 0 failures, and the controller file is **10 runs, 0 failures, 0 errors**.

- [ ] **Step 6: Commit**

```bash
# scratchpad/t4-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add app/models/webhook_event.rb app/controllers/webhooks_controller.rb test/models/webhook_event_test.rb test/controllers/webhooks_controller_test.rb
git commit -m "fix(webhooks): skip subscriptions with no resolvable user

belongs_to :user is required on Subscription, so an unattributable
subscription raised RecordInvalid, returned 422, and put Stripe into a
72-hour retry loop that ends with the endpoint disabled. Record the
event as ignored with the reason and return 200 instead.

This is the backstop under the origin_app guard: it covers a
subscription created from the Stripe dashboard, and it covers the new
app shipping a checkout that forgets to tag its metadata."
```

---

## Task 5: Scope `stripe:delete_webhooks` to this app's own endpoint

`rake stripe:delete_webhooks` currently iterates `Stripe::WebhookEndpoint.list` and deletes **every endpoint in the account**. Once the new app registers its endpoint, running this task silently stops event delivery to the new app — no error in either application, and the only thing that notices is the new app's nightly reconcile.

**Files:**
- Modify: `app/services/stripe_service.rb` (three new class methods)
- Modify: `lib/tasks/stripe.rake` (`setup_webhook` and `delete_webhooks`)
- Test: `test/services/stripe_service_test.rb` (new file)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `StripeService.webhook_endpoint_url` → `String`; `StripeService.own_webhook_endpoint?(endpoint)` → `Boolean`; `StripeService.delete_own_webhook_endpoints` → `{deleted: Array<String>, kept: Array<String>}`.

- [ ] **Step 1: Write the failing tests**

Create `test/services/stripe_service_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class StripeServiceTest < ActiveSupport::TestCase
  OTHER_APP_URL = "https://thegreatest.games/webhooks/stripe"

  test "webhook_endpoint_url points at this app outside production" do
    assert_equal "https://dev.thegreatestbooks.org/webhooks/stripe", StripeService.webhook_endpoint_url
  end

  test "own_webhook_endpoint? matches only this app's url" do
    ours = Stripe::WebhookEndpoint.construct_from(id: "we_ours", url: StripeService.webhook_endpoint_url)
    theirs = Stripe::WebhookEndpoint.construct_from(id: "we_theirs", url: OTHER_APP_URL)

    assert StripeService.own_webhook_endpoint?(ours)
    assert_not StripeService.own_webhook_endpoint?(theirs)
  end

  test "delete_own_webhook_endpoints leaves the other application's endpoint alone" do
    StripeService.stubs(:configure_stripe_api).returns(true)
    Stripe::WebhookEndpoint.stubs(:list).returns(Stripe::ListObject.construct_from(
      object: "list",
      has_more: false,
      data: [
        {id: "we_ours", object: "webhook_endpoint", url: StripeService.webhook_endpoint_url},
        {id: "we_theirs", object: "webhook_endpoint", url: OTHER_APP_URL}
      ]
    ))
    Stripe::WebhookEndpoint.expects(:delete).with("we_ours").once

    result = StripeService.delete_own_webhook_endpoints

    assert_equal [StripeService.webhook_endpoint_url], result[:deleted]
    assert_equal [OTHER_APP_URL], result[:kept]
  end

  test "delete_own_webhook_endpoints deletes nothing when no endpoint matches" do
    StripeService.stubs(:configure_stripe_api).returns(true)
    Stripe::WebhookEndpoint.stubs(:list).returns(Stripe::ListObject.construct_from(
      object: "list",
      has_more: false,
      data: [{id: "we_theirs", object: "webhook_endpoint", url: OTHER_APP_URL}]
    ))
    Stripe::WebhookEndpoint.expects(:delete).never

    result = StripeService.delete_own_webhook_endpoints

    assert_empty result[:deleted]
    assert_equal [OTHER_APP_URL], result[:kept]
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
# scratchpad/t5-test.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
bundle exec ruby -Itest test/services/stripe_service_test.rb
```

Expected: 4 runs, 4 failures/errors — `NoMethodError: undefined method 'webhook_endpoint_url' for StripeService`.

- [ ] **Step 3: Add the three methods to `StripeService`**

In `app/services/stripe_service.rb`, inside `class << self`, immediately after `def payment_links … end` and before `deactivate_all_payment_links`:

```ruby
    # The single source of truth for this app's own webhook URL. setup_webhook
    # and delete_own_webhook_endpoints must agree on it: if the two ever
    # computed it separately and drifted, the delete task would stop matching
    # its own endpoint and start matching nothing — or the account-wide
    # behaviour would creep back in.
    def webhook_endpoint_url
      base_url = Rails.env.production? ? "https://thegreatestbooks.org" : "https://dev.thegreatestbooks.org"
      "#{base_url}/webhooks/stripe"
    end

    def own_webhook_endpoint?(endpoint)
      endpoint.url == webhook_endpoint_url
    end

    # Deletes only this application's endpoint. The Stripe account is shared
    # with The Greatest; deleting its endpoint stops event delivery there with
    # no error raised in either app and nothing in either log — the failure
    # would surface days later as missing memberships.
    def delete_own_webhook_endpoints
      configure_stripe_api
      deleted = []
      kept = []

      Stripe::WebhookEndpoint.list(limit: 100).auto_paging_each do |endpoint|
        if own_webhook_endpoint?(endpoint)
          Stripe::WebhookEndpoint.delete(endpoint.id)
          deleted << endpoint.url
        else
          kept << endpoint.url
        end
      end

      {deleted: deleted, kept: kept}
    end
```

- [ ] **Step 4: Run the tests and watch them pass**

Run `scratchpad/t5-test.sh`. Expected: **4 runs, 0 failures, 0 errors.**

- [ ] **Step 5: Rewire the rake tasks**

In `lib/tasks/stripe.rake`, in `setup_webhook`, replace:

```ruby
      # Determine the webhook URL based on environment
      base_url = if Rails.env.production?
        "https://thegreatestbooks.org"
      else
        "https://dev.thegreatestbooks.org"
      end

      webhook_url = "#{base_url}/webhooks/stripe"
```

with:

```ruby
      webhook_url = StripeService.webhook_endpoint_url
```

Then replace the whole `delete_webhooks` task:

```ruby
  desc "Delete all Stripe webhooks"
  task delete_webhooks: :environment do
    StripeService.configure_stripe_api

    begin
      webhooks = Stripe::WebhookEndpoint.list
      webhooks.data.each do |webhook|
        puts "Deleting webhook: #{webhook.id}"
        Stripe::WebhookEndpoint.delete(webhook.id)
      end
      puts "All webhooks deleted successfully!"
    rescue Stripe::StripeError => e
      puts "Error deleting webhooks: #{e.message}"
    end
  end
```

with:

```ruby
  desc "Delete this application's own Stripe webhook endpoint"
  task delete_webhooks: :environment do
    result = StripeService.delete_own_webhook_endpoints

    if result[:deleted].empty?
      puts "No endpoint matched #{StripeService.webhook_endpoint_url}. Nothing deleted."
    else
      result[:deleted].each { |url| puts "Deleted webhook endpoint: #{url}" }
    end

    result[:kept].each { |url| puts "Left alone, belongs to another application: #{url}" }
  rescue Stripe::StripeError => e
    puts "Error deleting webhooks: #{e.message}"
    exit 1
  end
```

- [ ] **Step 6: Confirm the task still loads**

```bash
# scratchpad/t5-tasks.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
cd /home/shane/dev/the-greatest-books/admin || exit 1
bundle exec rake -T stripe
```

Expected: three `stripe:` tasks listed, with `stripe:delete_webhooks` described as "Delete this application's own Stripe webhook endpoint". **Do not run the task itself** — it talks to the live Stripe account.

- [ ] **Step 7: Commit**

```bash
# scratchpad/t5-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add app/services/stripe_service.rb lib/tasks/stripe.rake test/services/stripe_service_test.rb
git commit -m "fix(stripe): delete only this app's own webhook endpoint

The task iterated every endpoint on the account and deleted all of them.
The Greatest is about to register its own endpoint on the same account,
and deleting it would stop event delivery there silently — no error in
either app, no log line anywhere, discovered days later as missing
memberships.

Scope the deletion to the endpoint whose URL this app registers, and
have setup_webhook read that URL from the same method so the two cannot
drift apart."
```

---

## Task 6: Document the guard, then verify the whole branch

**Files:**
- Create: `docs/features/stripe_coexistence_guard.md` (legacy repo)
- Verify: everything changed so far

- [ ] **Step 1: Write the document**

Create `docs/features/stripe_coexistence_guard.md`:

```markdown
# Stripe coexistence guard

## Why this exists

For roughly two months from August 2026, this app and The Greatest — the new
multi-site app at thegreatest.games / thegreatestbooks.org-to-be — both run
live against **one Stripe account**. Stripe delivers every event of a
subscribed type to every endpoint on the account, so this app receives events
for subscriptions and checkouts it did not create.

Without a guard, two things happen:

1. `customer.subscription.created` for a new-app subscription resolves no user
   here — its `client_reference_id` is a new-app user id above 150,000, which
   does not exist in this database — and `Subscription#belongs_to :user` is
   required, so `update!(user: nil, …)` raises. That returns 422, Stripe
   retries the same event for 72 hours, and the endpoint can be disabled.
2. `checkout.session.completed` for a new-app donation does *not* raise, because
   `Donation#belongs_to :user` is optional. It quietly writes a donation row
   here and emails the donor a Greatest Books thank-you — for a donation made
   on a different site.

## How events are classified

`WebhooksController#other_app_event_reason` runs as a `before_action`, after
signature verification and **before** any row is written.

| Signal | Applies to | Why it is reliable |
|---|---|---|
| `metadata[origin_app] == "the-greatest"` | subscriptions, checkout sessions, invoices (via `subscription_details`) | This app sets no subscription metadata at all, so the tag can never collide with our own |
| Checkout session with a blank `payment_link` | `checkout.session.completed` | This app has never called `Checkout::Session.create`; it sells only through Payment Links, and Stripe stamps `payment_link` on every session those produce |

A third guard sits deeper, in `handle_subscription_update`: if no user can be
resolved at all, the event is recorded as `ignored` with the reason and 200 is
returned. That covers a subscription created straight from the Stripe
dashboard, and it covers the new app shipping a checkout that forgets its tag.

**Price ids are not a usable signal.** The new app deliberately sells through
this app's own production prices, so both apps' subscriptions carry identical
price ids.

## Reading the payload

Always `object[:key]`, never `object.key`. On a Stripe object `[]` returns nil
for a field the payload does not carry, while method access on an untyped
nested object raises `NoMethodError` — a 500, and the same retry loop the
guard exists to prevent.

## What is deliberately not guarded

`StripeService.deactivate_all_payment_links` still operates account-wide. The
new app creates no payment links, so there is nothing there to damage.

## When this can be deleted

At cutover, when thegreatestbooks.org points at the new app and this app's
webhook endpoint is removed from the Stripe account. Deleting the guard before
then re-opens the 422 loop.
```

- [ ] **Step 2: Verify the app boots and eager-loads**

Production eager-loads. A constant or syntax error in a changed file means the web container never starts, `restart: unless-stopped` crash-loops it, and nginx 502s the whole site. This is the check that catches that before it is pushed:

```bash
# scratchpad/t6-verify.sh
#!/bin/bash
export PATH=/home/shane/.local/share/mise/installs/ruby/3.4.7/bin:$PATH
export RAILS_ENV=test
export PARALLEL_WORKERS=1
cd /home/shane/dev/the-greatest-books/admin || exit 1
echo "===== syntax ====="
for f in app/controllers/webhooks_controller.rb app/models/webhook_event.rb app/services/stripe_service.rb lib/tasks/stripe.rake; do
  ruby -c "$f" || exit 1
done
echo "===== zeitwerk ====="
bundle exec rails zeitwerk:check
echo "===== eager load ====="
bundle exec rails runner 'Rails.application.eager_load!; puts "eager load OK"'
echo "===== rubocop on changed files ====="
bundle exec rubocop app/controllers/webhooks_controller.rb app/models/webhook_event.rb app/services/stripe_service.rb lib/tasks/stripe.rake test/controllers/webhooks_controller_test.rb test/models/webhook_event_test.rb test/services/stripe_service_test.rb test/test_helper.rb
echo "===== tests ====="
bundle exec ruby -Itest test/controllers/webhooks_controller_test.rb
bundle exec ruby -Itest test/models/webhook_event_test.rb
bundle exec ruby -Itest test/services/stripe_service_test.rb
```

Expected: every file "Syntax OK"; `zeitwerk:check` reports "All is good!"; "eager load OK"; rubocop clean on the changed files (**fix offences in the changed files only** — do not reformat neighbouring code); 10 + 1 + 4 runs, 0 failures, 0 errors.

- [ ] **Step 3: Review the full branch diff**

```bash
# scratchpad/t6-diff.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git diff main...HEAD --stat
git diff main...HEAD
```

Read it against this checklist:
- No file outside `app/controllers/webhooks_controller.rb`, `app/models/webhook_event.rb`, `app/services/stripe_service.rb`, `lib/tasks/stripe.rake`, `db/schema.rb`, `docs/`, and `test/` is touched.
- `db/schema.rb` shows exactly two changed lines: the version stamp and one index line.
- No secret of any kind appears in the diff — no `whsec_`, no `sk_live_`, no key material.
- No migration was added.
- Nothing logs `@event.data.object` or any payload.

- [ ] **Step 4: Commit**

```bash
# scratchpad/t6-commit.sh
#!/bin/bash
cd /home/shane/dev/the-greatest-books/admin || exit 1
git add docs/features/stripe_coexistence_guard.md
git commit -m "docs(stripe): explain the coexistence guard and when to delete it

The guard looks arbitrary without the shared-Stripe-account context, and
it becomes wrong to keep after cutover. Write down both."
```

---

## Task 7: Record what shipped in the new app's spec

Back in **this** worktree (`/home/shane/dev/the-greatest/.claude/worktrees/membership-stripe`), on the current branch.

**Files:**
- Modify: `docs/specs/membership-and-stripe-billing.md`

- [ ] **Step 1: Update the increments table**

Change the increment 10 row's Done column to ✅, and update the Status section at the top of the spec to read:

```markdown
- **Status**: In Progress — increments 1–4, 9 and 10 shipped (Stripe foundation, webhook ingest,
  reconciliation engine, data migration, admin UI, legacy guard patch); increments 5–8 and 11 remain
```

- [ ] **Step 2: Replace the "Legacy guard patch" section body**

Replace the numbered list under `### Legacy guard patch (separate repo)` — keeping the paragraph above it that explains the 422 — with:

```markdown
**Shipped 2026-08-16** on the legacy repo branch `stripe-coexistence-guard`
(`/home/shane/dev/the-greatest-books/admin`), documented there in
`docs/features/stripe_coexistence_guard.md`. Four changes:

1. Events whose subscription, session or invoice carries
   `metadata[origin_app] == "the-greatest"` are skipped before any row is
   written, logging the event id and type only, and returning 200.
2. `checkout.session.completed` for a session with a blank `payment_link` is
   skipped for the same reason. Legacy has never called
   `Checkout::Session.create` — it sells only through Payment Links, and Stripe
   stamps `payment_link` on every session those produce — so this is a
   structural test that does not depend on the new app tagging anything. It
   exists because legacy's `Donation` allows a nil user: an untagged donation
   would not have 422'd, it would have written a books donation row and emailed
   the donor a books-branded receipt.
3. A subscription with no resolvable user is recorded as `ignored` with the
   reason and returns 200, rather than raising `RecordInvalid`. This is the
   backstop if increment 6 ships without the metadata tag.
4. `rake stripe:delete_webhooks` deletes only the endpoint whose URL legacy
   registers, and `setup_webhook` now reads that URL from the same method so
   the two cannot drift.

**`deactivate_all_payment_links` was deliberately left account-wide** — the new
app creates no payment links, so there is nothing there to damage, and changing
a legacy path that still runs is the larger risk.

**What increment 6 must do to hold up its end:**

- Set `subscription_data: {metadata: {app_user_id:, origin_app: "the-greatest"}}`
  on every subscription-mode Checkout Session, as the spec's checkout snippet
  already shows.
- **Also set top-level `metadata: {origin_app: "the-greatest"}` on every
  Checkout Session it creates, both modes.** A donation has no subscription to
  carry the tag, so without this the donation path relies on legacy's
  payment-link backstop alone. Guard 2 covers it either way; guard 1 makes the
  legacy log line say why, which is the difference between a five-minute and a
  two-hour diagnosis.
```

- [ ] **Step 3: Add the two new findings to "Carried forward"**

Append to the `## Carried forward from increments 1–3, 4 and 9` list:

```markdown
- **Legacy is deployed by pushing to `main`, with no test or lint gate anywhere.**
  `deploy-image.yaml` builds and pushes the image on push to `main` and dispatches an
  SSH deploy. Its `bin/docker-entrypoint` is `bash -e` and runs `db:prepare` before
  `exec`ing the server, with `restart: unless-stopped` — the same crash-loop shape as
  this app, and production eager-loads, so a constant error in a changed file takes
  thegreatestbooks.org down. The guard patch adds no migration, and Task 6 of its plan
  gates on `zeitwerk:check` plus an explicit `eager_load!`.
- **Legacy's `db/schema.rb` had never been dumped** after its 2026-04 subscriptions
  unique-index migration, so a fresh test database refused to run at all. Fixed in the
  guard-patch branch. Its test harness has two more traps worth knowing if anyone
  returns to it: `shoulda-context` crashes the runner on the first failure, and
  `db/seeds.rb` inserts `User.create(id: 1)` without advancing the sequence, so
  `create(:user)` raises `PG::UniqueViolation` on a clean database.
```

- [ ] **Step 4: Commit**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/membership-stripe
git add docs/specs/membership-and-stripe-billing.md
git commit -m "docs(billing): record the shipped legacy guard patch

Increment 10 is done in the legacy repo. Write down what actually
shipped — including the payment-link guard the spec had not anticipated
and the deliberate decision to leave deactivate_all_payment_links
account-wide — and the contract increment 6 has to honour: tag the
Checkout Session itself, not only subscription_data, so donations
identify themselves too."
```

---

## Review targets

When requesting code review (superpowers:requesting-code-review), point the reviewers at these three axes, not just the diff. The first two are what caught the real defects in the previous two plans.

**1. The deploy pipeline.** Legacy has no test gate; merging to `main` deploys. Production eager-loads and the entrypoint is `bash -e` with `restart: unless-stopped`, so a load-time error 502s all of thegreatestbooks.org. Ask: can anything in this diff fail at boot? Does it add a migration (it must not)? Would a rubocop or test failure be caught by anything other than a human running it?

**2. The threat model of a public, unauthenticated endpoint on a shared payment account.** `/webhooks/stripe` accepts anonymous POSTs from the internet; only the signature stands in front of it. Ask: can the new guard be reached before signature verification (it must not be)? Can an outside party set `metadata[origin_app]` on a subscription and thereby make legacy skip a real customer — and who actually can set it? Does any new log line or `error` column write leak a customer email, address, or payment identifier into a place it was not already? Note also that this plan file lives in a **public** repo while the patch lives in a **private** one, so nothing secret may travel from one to the other.

**3. Legacy's own traffic surviving.** The guard is a *skip*, so its failure mode is silence: a false positive means a genuine legacy subscriber is dropped with a 200 and nothing to alert on. Ask specifically whether a legacy payment-link subscription, a legacy payment-link donation, a legacy renewal invoice, and a legacy cancellation each still take exactly the path they take today — and whether Task 1's characterization tests would actually fail if they did not.

---

## Manual deploy and verification runbook

**For the owner. Not part of the implementation, and not something a subagent should do.**

Deploying = merging to `main`. Before that:

1. Re-run `scratchpad/t6-verify.sh` on the final branch. Everything green.
2. Confirm the diff touches no migration: `git diff main...HEAD --stat -- db/migrate` is empty.
3. Confirm the payment-link guard's premise against a real payload, because its failure is
   silent. Stripe Dashboard → Developers → Webhooks → legacy's endpoint → recent deliveries:
   open a `checkout.session.completed` produced by one of legacy's own payment links and
   confirm `payment_link` holds a non-null `plink_…` id. Do not try to answer this from the
   endpoint's API version — Stripe ships additive fields to all versions, so the version
   decides nothing here.

After the deploy lands:

4. Confirm the container came up rather than crash-looping:
   `docker compose -f docker-compose.prod.yml ps web` and
   `docker compose -f docker-compose.prod.yml logs --tail=200 web`.
5. Prove legacy's own path still works, without waiting for a real customer: in the
   Stripe Dashboard, find a recent `customer.subscription.updated` for an existing
   legacy subscriber and use **Resend**. Legacy's admin webhook-events list should show
   it `processed`, exactly as before.
6. Once increment 6 is live in the new app, buy a membership in a Stripe **sandbox**
   from the new app, then check legacy's logs for
   `Skipping Stripe event evt_… (customer.subscription.created): metadata origin_app=the-greatest`
   and confirm legacy's `subscriptions` table gained no row.
7. Keep an eye on the Stripe Dashboard's webhook endpoint page for legacy: the
   failure-rate graph going to zero for new-app events is the real signal.
8. Read legacy's Admin → Webhook Events for `ignored` rows, then again after a week. An
   `ignored` `customer.subscription.created` belonging to a Greatest Books customer means the
   no-user backstop dropped a real legacy purchase: it has no membership row and its welcome
   email will never send. Create the subscription manually. This is the one failure the patch
   introduces rather than removes, and nothing alerts on it.

**Rollback** is `git revert` on `main`, which re-triggers the same build-and-deploy. There is no state to unwind — the patch writes nothing new and adds no schema.
