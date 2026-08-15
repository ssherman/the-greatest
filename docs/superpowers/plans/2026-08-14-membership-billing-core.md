# Membership Billing Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the app a Stripe webhook endpoint that persists every event safely, and a reconciliation engine that makes local membership rows match Stripe's current state regardless of the order events arrive in.

**Architecture:** The webhook endpoint verifies the signature, checks `livemode`, inserts the raw event, and returns 200 — nothing else. A Sidekiq job then extracts only the customer id from the event and calls `Services::Billing::ReconcileCustomer`, which re-reads that customer's subscriptions from the Stripe API under a per-customer Postgres advisory lock and rewrites local rows to match. No event payload is ever treated as truth, which is what makes delivery order irrelevant.

**Tech Stack:** Rails 8.1, PostgreSQL, Sidekiq + sidekiq-cron, `stripe` gem ~> 19.5, Minitest + fixtures + Mocha, standardrb.

**Spec:** `docs/specs/membership-and-stripe-billing.md`

## Plan decomposition

The spec has 11 increments spanning independent subsystems. This plan covers **increments 1–3 only** — the billing core. It produces working, testable software on its own: the app correctly ingests and reconciles Stripe state, with no user-facing surface. The remaining plans, to be written separately:

| Plan | Spec increments | Depends on |
|---|---|---|
| **Billing core** (this plan) | 1, 2, 3 | — |
| Data migration & admin | 4, 9 | this plan |
| Mail foundation | 5 | — (fully independent) |
| Selling: checkout, join page, entitlements, E2E | 6, 7, 11 | this plan + legacy patch |
| Membership emails | 8 | mail foundation + selling |
| Legacy guard patch | 10 | — (separate repository) |

## Global Constraints

- **Working directory is `web-app/`** for every Rails and yarn command. Docs live at the project root in `docs/`, not `web-app/docs/`.
- **Worktree test-database hazard.** This worktree shares `the_greatest_test` with the main checkout. New tables created here **vanish between commands** if anything runs from the main checkout. If a test suddenly fails with `relation "memberships" does not exist`, re-run `bin/rails db:test:prepare` — the migration is fine.
- **Never run destructive DB commands against development.** No `db:drop`, `db:reset`, `db:schema:load`, or `create_fixtures`. The books data exists only in development and takes hours to rebuild. A `PreToolUse` hook blocks most of these.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. Run `--fix` before each commit.
- **Do not run brakeman.** The gate is `bin/rails test` + `standardrb`.
- **Rails 8 enum syntax:** `enum :status, {active: 0}` with the colon prefix. Never `enum status: {...}`.
- **Services** live in `app/lib/services/`, namespaced `module Services; module Billing`. **Never** `Services::Membership` — inside it, a bare `Membership` resolves to the module rather than the model. Jobs live in `app/sidekiq/`, generated with `bin/rails generate sidekiq:job billing/name` (not `generate job`).
- **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. The `keyword_init` is deliberate; a Standard cop is disabled for it.
- **Stripe API version is pinned to `2026-07-29.dahlia`.** Never read `subscription.current_period_end` — Stripe's Basil release moved it to `subscription.items.data[0].current_period_end`.
- **Tests never hit the network.** `WebMock.disable_net_connect!` is active and `Sidekiq::Testing.inline!` runs jobs synchronously. Stub Stripe with Mocha, not WebMock.
- **Fixture names are semantic** (`admin_user`, `regular_user`, `editor_user`, `password_user`, `google_user`, `contractor_user`), never `one`/`two`. Read the YAML to check a name; never call `create_fixtures`.
- **Secrets are ENV vars via SOPS**, never `Rails.application.credentials`, which is unused in this app.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `config/initializers/stripe.rb` | Boot-time configuration and the live-key guard |
| `app/lib/services/billing/stripe_client.rb` | Sole reader of Stripe ENV; api_key, api_version, livemode, webhook secret |
| `app/lib/services/billing/reconcile_customer.rb` | Make local membership rows match Stripe for one customer |
| `app/lib/services/billing/reconcile_all_customers.rb` | Page the whole account, reconcile each customer |
| `app/models/membership.rb` | Source of truth for "is this person a member?" |
| `app/models/stripe_event.rb` | Raw event inbox |
| `app/models/billing_plan.rb` | Price catalogue, replaces `stripe_products.yml` |
| `app/models/donation.rb` | One-time payment record |
| `app/controllers/webhooks/stripe_controller.rb` | Verify, guard, insert, enqueue, 200 |
| `app/sidekiq/billing/process_stripe_event_job.rb` | Extract customer id, dispatch to reconcile |
| `test/support/stripe_webhook_helper.rb` | Builds signed payloads at runtime from a dummy secret |
| `lib/tasks/billing.rake` | `billing:reconcile_all`, `billing:replay_failed` |

**Modified:** `Gemfile`, `config/routes.rb`, `config/schedule.yml`, `.env.example`, `deployment/ENV.md`, `db/schema.rb` (auto), plus four new fixture files.

---

### Task 1: Stripe gem and the StripeClient wrapper

Everything Stripe-configuration-shaped goes through one class, so there is exactly one place that reads ENV and exactly one place the live-key guard can live.

**Files:**
- Modify: `Gemfile`
- Create: `app/lib/services/billing/stripe_client.rb`
- Create: `config/initializers/stripe.rb`
- Modify: `.env.example`, `deployment/ENV.md`
- Test: `test/lib/services/billing/stripe_client_test.rb`

**Interfaces:**
- Produces: `Services::Billing::StripeClient.configure!`, `.livemode?` → boolean, `.webhook_secret` → String, `.api_version` → String, and `Services::Billing::StripeClient::ConfigurationError`.

- [ ] **Step 1: Add the gem**

In `Gemfile`, after the `gem "openai"` line:

```ruby
gem "stripe", "~> 19.5"
```

Run: `bundle install`

- [ ] **Step 2: Write the failing test**

Create `test/lib/services/billing/stripe_client_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class StripeClientTest < ActiveSupport::TestCase
      test "livemode? is true only for the exact string true" do
        with_env("STRIPE_LIVEMODE" => "true") { assert StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => "false") { refute StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => "TRUE") { refute StripeClient.livemode? }
        with_env("STRIPE_LIVEMODE" => nil) { refute StripeClient.livemode? }
      end

      test "configure! raises when a live key is used outside livemode" do
        with_env("STRIPE_SECRET_KEY" => "sk_live_abc123", "STRIPE_LIVEMODE" => "false") do
          error = assert_raises(StripeClient::ConfigurationError) { StripeClient.configure! }
          assert_match(/live key/i, error.message)
        end
      end

      test "configure! accepts a live key when livemode is on" do
        with_env("STRIPE_SECRET_KEY" => "sk_live_abc123", "STRIPE_LIVEMODE" => "true") do
          StripeClient.configure!
          assert_equal "sk_live_abc123", Stripe.api_key
        end
      end

      test "configure! pins the API version" do
        with_env("STRIPE_SECRET_KEY" => "sk_test_abc", "STRIPE_LIVEMODE" => "false") do
          StripeClient.configure!
          assert_equal "2026-07-29.dahlia", Stripe.api_version
        end
      end

      test "webhook_secret reads the environment variable" do
        with_env("STRIPE_WEBHOOK_SECRET" => "whsec_xyz") do
          assert_equal "whsec_xyz", StripeClient.webhook_secret
        end
      end

      private

      # Sets ENV keys for the block and restores prior values afterwards.
      def with_env(pairs)
        previous = pairs.keys.index_with { |key| ENV[key] }
        pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/billing/stripe_client_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Billing::StripeClient`

- [ ] **Step 4: Write the implementation**

Create `app/lib/services/billing/stripe_client.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # The only place in the app that reads Stripe configuration from ENV.
    #
    # The api_version pin is load-bearing: upgrading the gem would otherwise
    # silently change payload shapes underneath the reconciler. Stripe's Basil
    # release (2025-03-31) is the cautionary example — it moved
    # current_period_end off the Subscription object onto subscription items.
    class StripeClient
      class ConfigurationError < StandardError; end

      API_VERSION = "2026-07-29.dahlia"

      class << self
        def configure!
          key = secret_key

          if key.to_s.start_with?("sk_live_") && !livemode?
            raise ConfigurationError,
              "Refusing to boot: STRIPE_SECRET_KEY is a live key but STRIPE_LIVEMODE is not 'true'. " \
              "This guard exists so a misconfigured environment cannot touch real customers."
          end

          Stripe.api_key = key
          Stripe.api_version = API_VERSION
          true
        end

        def api_version = API_VERSION

        # Deliberately strict: only the exact string "true" enables livemode, so
        # a stray value can never accidentally point a test environment at
        # production data.
        def livemode? = ENV["STRIPE_LIVEMODE"] == "true"

        def webhook_secret = ENV.fetch("STRIPE_WEBHOOK_SECRET", "whsec_missing")

        def secret_key
          ENV.fetch("STRIPE_SECRET_KEY") do
            raise ConfigurationError, "STRIPE_SECRET_KEY is not set" unless Rails.env.local?
            "sk_test_missing"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 5: Add the boot initializer**

Create `config/initializers/stripe.rb`:

```ruby
# frozen_string_literal: true

# Configure Stripe at boot so the live-key guard fires before any request can.
# Tolerated in local environments so a developer without Stripe credentials can
# still boot the app; production has no such escape hatch.
Rails.application.config.to_prepare do
  Services::Billing::StripeClient.configure!
rescue Services::Billing::StripeClient::ConfigurationError => e
  raise unless Rails.env.local?
  Rails.logger.warn("[stripe] #{e.message}")
end

Rails.application.config.stripe_livemode = Services::Billing::StripeClient.livemode?
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/billing/stripe_client_test.rb`
Expected: PASS, 5 runs, 0 failures

- [ ] **Step 7: Document the environment variables**

Append to `.env.example`:

```
# Stripe billing. Use a Sandbox key in development; see docs/specs/membership-and-stripe-billing.md
STRIPE_SECRET_KEY=sk_test_replace_me
STRIPE_WEBHOOK_SECRET=whsec_replace_me
STRIPE_LIVEMODE=false
```

Add the same three names to `deployment/ENV.md` under a new "Stripe" heading, noting that `STRIPE_WEBHOOK_SECRET` differs between a dashboard endpoint and the `stripe listen` CLI, and that mixing them up is the most common signature-verification failure.

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix
bin/rails test test/lib/services/billing/stripe_client_test.rb
git add Gemfile Gemfile.lock app/lib/services/billing/stripe_client.rb \
        config/initializers/stripe.rb test/lib/services/billing/stripe_client_test.rb \
        ../.env.example ../deployment/ENV.md
git commit -m "feat(billing): add stripe gem and StripeClient configuration guard"
```

---

### Task 2: memberships table and Membership model

**Files:**
- Create: `db/migrate/<timestamp>_create_memberships.rb`
- Create: `app/models/membership.rb`
- Create: `test/fixtures/memberships.yml`
- Test: `test/models/membership_test.rb`

**Interfaces:**
- Produces: `Membership` with `source` (`stripe`/`comped`/`legacy`), `status` (Stripe's eight), `interval` (`monthly`/`yearly`), and `belongs_to :user, optional: true`. Later tasks rely on `Membership.find_or_initialize_by(stripe_subscription_id:)` and on the partial unique index.

- [ ] **Step 1: Generate the model**

Run:

```bash
bin/rails generate model Membership user:references source:integer status:integer \
  interval:integer stripe_subscription_id:string stripe_customer_id:string \
  current_period_end:datetime canceled_at:datetime cancel_at_period_end:boolean \
  origin_domain:string welcome_email_sent_at:datetime ended_email_sent_at:datetime \
  stripe_synced_at:datetime note:text granted_by:references
```

- [ ] **Step 2: Edit the migration**

Replace the generated `db/migrate/<timestamp>_create_memberships.rb` body with:

```ruby
class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships do |t|
      # Nullable on purpose: with one shared Stripe account and a live legacy
      # app, an unmappable customer will eventually appear. Storing it
      # unattached beats dropping it silently.
      t.references :user, null: true, foreign_key: true
      t.integer :source, null: false, default: 0
      t.integer :status, null: false
      t.integer :interval
      t.string :stripe_subscription_id
      t.string :stripe_customer_id
      # nil means "never expires" — used by comped memberships.
      t.datetime :current_period_end
      t.datetime :canceled_at
      t.boolean :cancel_at_period_end, null: false, default: false
      t.string :origin_domain
      t.datetime :welcome_email_sent_at
      t.datetime :ended_email_sent_at
      t.datetime :stripe_synced_at
      t.text :note
      t.references :granted_by, null: true, foreign_key: {to_table: :users}

      t.timestamps
    end

    # Partial: comped and legacy rows have no subscription id, and several NULLs
    # must be allowed to coexist.
    add_index :memberships, :stripe_subscription_id,
      unique: true, where: "stripe_subscription_id IS NOT NULL"
    add_index :memberships, [:user_id, :status]
    add_index :memberships, :stripe_customer_id
  end
end
```

- [ ] **Step 3: Write the failing test**

Replace `test/models/membership_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  test "a stripe membership is valid" do
    membership = Membership.new(
      user: users(:regular_user), source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: "sub_new", stripe_customer_id: "cus_new",
      current_period_end: 1.month.from_now
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "a comped membership needs no stripe ids and no end date" do
    membership = Membership.new(
      user: users(:regular_user), source: :comped, status: :active,
      note: "Contributor", granted_by: users(:admin_user)
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "a membership may have no user" do
    membership = Membership.new(
      source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: "sub_orphan", stripe_customer_id: "cus_orphan"
    )
    assert membership.valid?, membership.errors.full_messages.join(", ")
  end

  test "stripe_subscription_id is unique" do
    existing = memberships(:regular_user_monthly)
    duplicate = Membership.new(
      user: users(:editor_user), source: :stripe, status: :active, interval: :monthly,
      stripe_subscription_id: existing.stripe_subscription_id
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_subscription_id], "has already been taken"
  end

  test "many memberships may have a null stripe_subscription_id" do
    2.times do |i|
      Membership.create!(user: users(:regular_user), source: :comped, status: :active,
        note: "comp #{i}")
    end
    assert_operator Membership.where(stripe_subscription_id: nil).count, :>=, 2
  end

  test "a stripe membership requires a subscription id" do
    membership = Membership.new(user: users(:regular_user), source: :stripe, status: :active)
    refute membership.valid?
    assert_includes membership.errors[:stripe_subscription_id], "can't be blank"
  end

  test "stripe? distinguishes reconcilable rows from manual grants" do
    assert memberships(:regular_user_monthly).stripe?
    refute memberships(:editor_user_comped).stripe?
    refute memberships(:password_user_legacy).stripe?
  end
end
```

- [ ] **Step 4: Write the fixtures**

Create `test/fixtures/memberships.yml`:

```yaml
# Semantic names, matching the users.yml convention.
regular_user_monthly:
  user: regular_user
  source: 0          # stripe
  status: 1          # active
  interval: 0        # monthly
  stripe_subscription_id: sub_regular_monthly
  stripe_customer_id: cus_regular
  current_period_end: <%= 20.days.from_now.to_fs(:db) %>
  cancel_at_period_end: false
  origin_domain: books
  stripe_synced_at: <%= 1.hour.ago.to_fs(:db) %>

google_user_canceled_in_grace:
  user: google_user
  source: 0          # stripe
  status: 2          # canceled
  interval: 1        # yearly
  stripe_subscription_id: sub_google_yearly
  stripe_customer_id: cus_google
  current_period_end: <%= 10.days.from_now.to_fs(:db) %>
  canceled_at: <%= 2.days.ago.to_fs(:db) %>
  cancel_at_period_end: true
  origin_domain: music

editor_user_comped:
  user: editor_user
  source: 1          # comped
  status: 1          # active
  current_period_end:   # nil — never expires
  note: Contributor comp
  granted_by: admin_user

password_user_legacy:
  user: password_user
  source: 2          # legacy
  status: 1          # active
  current_period_end:   # nil — legacy early supporters never expire
  note: Legacy early supporter
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/membership_test.rb`
Expected: FAIL — the validations and enums are not defined yet

- [ ] **Step 6: Write the model**

Replace `app/models/membership.rb`:

```ruby
# frozen_string_literal: true

# The single source of truth for "is this person a member?".
#
# Replaces the legacy app's Subscription model *and* its users.paid boolean.
# A comped membership is a row with source: :comped and no Stripe ids, which is
# what makes it structurally unreachable from the reconciler — that only ever
# touches source: :stripe rows.
class Membership < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :granted_by, class_name: "User", optional: true

  enum :source, {stripe: 0, comped: 1, legacy: 2}, prefix: true
  enum :status, {
    trialing: 0, active: 1, canceled: 2, incomplete: 3,
    incomplete_expired: 4, past_due: 5, unpaid: 6, paused: 7
  }
  enum :interval, {monthly: 0, yearly: 1}, prefix: true

  validates :source, presence: true
  validates :status, presence: true
  validates :stripe_subscription_id, uniqueness: true, allow_nil: true
  validates :stripe_subscription_id, presence: true, if: :source_stripe?

  scope :stripe_sourced, -> { where(source: :stripe) }

  # True when the reconciler owns this row. Reads better at call sites than
  # source_stripe? and gives a single place to change the rule.
  def stripe? = source_stripe?
end
```

Note the `prefix: true` on `source` and `interval`: without it, `Membership.stripe` as an enum scope would collide with the `Stripe` constant at some call sites, and `monthly`/`yearly` would generate bare predicates that read ambiguously next to `status`.

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/membership_test.rb`
Expected: PASS, 7 runs, 0 failures

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix
git add db/migrate db/schema.rb app/models/membership.rb \
        test/models/membership_test.rb test/fixtures/memberships.yml
git commit -m "feat(billing): add Membership model replacing Subscription and users.paid"
```

---

### Task 3: stripe_events table and StripeEvent model

**Files:**
- Create: `db/migrate/<timestamp>_create_stripe_events.rb`
- Create: `app/models/stripe_event.rb`
- Create: `test/fixtures/stripe_events.yml`
- Test: `test/models/stripe_event_test.rb`

**Interfaces:**
- Produces: `StripeEvent` with `status` (`received`/`processed`/`failed`/`ignored`), `#mark_processed!`, `#mark_failed!(error)`, `#mark_ignored!(reason)`, and `#stripe_customer_id_from_payload`.

- [ ] **Step 1: Generate and edit the migration**

Run:

```bash
bin/rails generate model StripeEvent stripe_event_id:string event_type:string \
  payload:jsonb livemode:boolean api_version:string stripe_customer_id:string \
  status:integer stripe_created_at:datetime processed_at:datetime \
  attempts:integer error:text
```

Replace the migration body:

```ruby
class CreateStripeEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :stripe_events do |t|
      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      # The FULL event, not just data.object. Legacy stored only the object and
      # lost the event type context and livemode along with it.
      t.jsonb :payload, null: false
      t.boolean :livemode, null: false
      t.string :api_version
      t.string :stripe_customer_id
      t.integer :status, null: false, default: 0
      t.datetime :stripe_created_at, null: false
      t.datetime :processed_at
      t.integer :attempts, null: false, default: 0
      t.text :error

      t.timestamps
    end

    # Unique, unlike legacy's plain index. This index IS the idempotency check:
    # a redelivered event fails the insert instead of being processed twice.
    add_index :stripe_events, :stripe_event_id, unique: true
    add_index :stripe_events, [:status, :created_at]
    add_index :stripe_events, :stripe_customer_id
  end
end
```

- [ ] **Step 2: Write the failing test**

Replace `test/models/stripe_event_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class StripeEventTest < ActiveSupport::TestCase
  test "stripe_event_id is unique" do
    duplicate = StripeEvent.new(
      stripe_event_id: stripe_events(:subscription_created).stripe_event_id,
      event_type: "customer.subscription.created", payload: {}, livemode: false,
      stripe_created_at: Time.current
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_event_id], "has already been taken"
  end

  test "a duplicate insert raises RecordNotUnique at the database level" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      StripeEvent.insert!({
        stripe_event_id: stripe_events(:subscription_created).stripe_event_id,
        event_type: "customer.subscription.created", payload: {}, livemode: false,
        status: 0, stripe_created_at: Time.current, attempts: 0,
        created_at: Time.current, updated_at: Time.current
      })
    end
  end

  test "mark_processed! stamps the time and status" do
    event = stripe_events(:subscription_created)
    event.mark_processed!
    assert event.processed?
    assert_not_nil event.processed_at
  end

  test "mark_failed! records the class and message but never the payload" do
    event = stripe_events(:subscription_created)
    event.mark_failed!(ArgumentError.new("boom"))
    assert event.failed?
    assert_match "ArgumentError", event.error
    assert_match "boom", event.error
    refute_match "cus_", event.error
  end

  test "mark_ignored! records the reason" do
    event = stripe_events(:subscription_created)
    event.mark_ignored!("livemode mismatch")
    assert event.ignored?
    assert_equal "livemode mismatch", event.error
  end

  test "stripe_customer_id_from_payload reads data.object.customer" do
    assert_equal "cus_regular",
      stripe_events(:subscription_created).stripe_customer_id_from_payload
  end

  test "stripe_customer_id_from_payload reads data.object.id for customer events" do
    assert_equal "cus_regular",
      stripe_events(:customer_updated).stripe_customer_id_from_payload
  end

  test "stripe_customer_id_from_payload returns nil when there is no customer" do
    assert_nil stripe_events(:no_customer).stripe_customer_id_from_payload
  end

  test "unprocessed scope returns received and failed events" do
    assert_includes StripeEvent.unprocessed, stripe_events(:subscription_created)
  end
end
```

- [ ] **Step 3: Write the fixtures**

Create `test/fixtures/stripe_events.yml`:

```yaml
subscription_created:
  stripe_event_id: evt_subscription_created
  event_type: customer.subscription.created
  livemode: false
  status: 0
  stripe_created_at: <%= 1.hour.ago.to_fs(:db) %>
  attempts: 0
  payload: >
    {"id":"evt_subscription_created","type":"customer.subscription.created",
     "livemode":false,
     "data":{"object":{"id":"sub_regular_monthly","object":"subscription",
     "customer":"cus_regular","status":"active"}}}

customer_updated:
  stripe_event_id: evt_customer_updated
  event_type: customer.updated
  livemode: false
  status: 0
  stripe_created_at: <%= 30.minutes.ago.to_fs(:db) %>
  attempts: 0
  payload: >
    {"id":"evt_customer_updated","type":"customer.updated","livemode":false,
     "data":{"object":{"id":"cus_regular","object":"customer",
     "email":"regular@example.com"}}}

no_customer:
  stripe_event_id: evt_no_customer
  event_type: price.updated
  livemode: false
  status: 0
  stripe_created_at: <%= 10.minutes.ago.to_fs(:db) %>
  attempts: 0
  payload: >
    {"id":"evt_no_customer","type":"price.updated","livemode":false,
     "data":{"object":{"id":"price_abc","object":"price"}}}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/stripe_event_test.rb`
Expected: FAIL — `mark_processed!` is undefined

- [ ] **Step 5: Write the model**

Replace `app/models/stripe_event.rb`:

```ruby
# frozen_string_literal: true

# The raw inbox for Stripe webhooks.
#
# Rows here are forensic evidence, never a source of truth. Nothing in the app
# reads a payload to decide what a membership's state is — that comes from
# re-reading Stripe. See Services::Billing::ReconcileCustomer.
class StripeEvent < ApplicationRecord
  enum :status, {received: 0, processed: 1, failed: 2, ignored: 3}

  validates :stripe_event_id, presence: true, uniqueness: true
  validates :event_type, presence: true
  validates :payload, presence: true
  validates :livemode, inclusion: {in: [true, false]}
  validates :stripe_created_at, presence: true

  scope :unprocessed, -> { where(status: [:received, :failed]) }
  scope :recent, -> { order(created_at: :desc) }

  # Derive the customer column from the payload so there is exactly one
  # implementation of "where does Stripe put the customer id?". The webhook
  # controller does not extract it separately.
  before_validation :derive_stripe_customer_id

  def mark_processed!
    update!(status: :processed, processed_at: Time.current, error: nil)
  end

  # Records the class and message only. The payload is never written to the
  # error column or the log: it carries customer email, name, address and card
  # last-four, and this application is open source.
  def mark_failed!(error)
    message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    update!(status: :failed, processed_at: Time.current, error: message,
      attempts: attempts + 1)
  end

  def mark_ignored!(reason)
    update!(status: :ignored, processed_at: Time.current, error: reason)
  end

  # Stripe puts the customer in different places depending on the event family:
  # customer.* events carry it as the object's own id, everything else as a
  # `customer` attribute. Returns nil for events with no customer at all
  # (price.*, product.*), which the job treats as "ignore".
  def stripe_customer_id_from_payload
    object = payload.dig("data", "object") || {}
    return object["id"] if object["object"] == "customer"
    object["customer"].presence
  end

  private

  def derive_stripe_customer_id
    self.stripe_customer_id ||= stripe_customer_id_from_payload
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/models/stripe_event_test.rb`
Expected: PASS, 9 runs, 0 failures

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
git add db/migrate db/schema.rb app/models/stripe_event.rb \
        test/models/stripe_event_test.rb test/fixtures/stripe_events.yml
git commit -m "feat(billing): add StripeEvent inbox with unique event id"
```

---

### Task 4: billing_plans and donations tables

Both are simple records with no behaviour beyond scopes, so they share a task.

**Files:**
- Create: `db/migrate/<timestamp>_create_billing_plans.rb`, `db/migrate/<timestamp>_create_donations.rb`
- Create: `app/models/billing_plan.rb`, `app/models/donation.rb`
- Create: `test/fixtures/billing_plans.yml`, `test/fixtures/donations.yml`
- Test: `test/models/billing_plan_test.rb`, `test/models/donation_test.rb`

**Interfaces:**
- Produces: `BillingPlan.membership.active.find_by!(key:)` and `BillingPlan.donation_price`, used by the selling plan. `Donation` with `amount_cents` and a unique `stripe_payment_intent_id`.

- [ ] **Step 1: Generate both models**

```bash
bin/rails generate model BillingPlan kind:integer key:string name:string \
  interval:integer amount_cents:integer currency:string stripe_price_id:string \
  stripe_lookup_key:string active:boolean position:integer

bin/rails generate model Donation user:references amount_cents:integer \
  currency:string status:integer stripe_payment_intent_id:string \
  stripe_checkout_session_id:string email:string domain:string
```

- [ ] **Step 2: Edit both migrations**

`db/migrate/<timestamp>_create_billing_plans.rb`:

```ruby
class CreateBillingPlans < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_plans do |t|
      t.integer :kind, null: false
      t.string :key, null: false
      t.string :name, null: false
      t.integer :interval
      t.integer :amount_cents
      t.string :currency, null: false, default: "usd"
      t.string :stripe_price_id, null: false
      t.string :stripe_lookup_key
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :billing_plans, :key, unique: true
    add_index :billing_plans, :stripe_price_id, unique: true
  end
end
```

`db/migrate/<timestamp>_create_donations.rb`:

```ruby
class CreateDonations < ActiveRecord::Migration[8.1]
  def change
    create_table :donations do |t|
      # Nullable: donations may be made while signed out.
      t.references :user, null: true, foreign_key: true
      t.integer :amount_cents, null: false
      t.string :currency, null: false, default: "usd"
      t.integer :status, null: false, default: 0
      t.string :stripe_payment_intent_id
      t.string :stripe_checkout_session_id
      t.string :email
      t.string :domain

      t.timestamps
    end

    add_index :donations, :stripe_payment_intent_id,
      unique: true, where: "stripe_payment_intent_id IS NOT NULL"
  end
end
```

- [ ] **Step 3: Write the failing tests**

Replace `test/models/billing_plan_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class BillingPlanTest < ActiveSupport::TestCase
  test "key is unique" do
    duplicate = BillingPlan.new(kind: :membership, key: "monthly", name: "Dupe",
      stripe_price_id: "price_dupe")
    refute duplicate.valid?
    assert_includes duplicate.errors[:key], "has already been taken"
  end

  test "stripe_price_id is unique" do
    duplicate = BillingPlan.new(kind: :membership, key: "other", name: "Other",
      stripe_price_id: billing_plans(:monthly).stripe_price_id)
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_price_id], "has already been taken"
  end

  test "membership scope returns only membership plans in position order" do
    assert_equal %w[monthly yearly], BillingPlan.membership.active.pluck(:key)
  end

  test "donation_price returns the single donation plan" do
    assert_equal billing_plans(:donation), BillingPlan.donation_price
  end

  test "inactive plans are excluded from active" do
    refute_includes BillingPlan.active, billing_plans(:retired_monthly)
  end

  test "amount_in_dollars formats cents" do
    assert_equal 5.0, billing_plans(:monthly).amount_in_dollars
  end
end
```

Replace `test/models/donation_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class DonationTest < ActiveSupport::TestCase
  test "a donation is valid without a user" do
    donation = Donation.new(amount_cents: 2500, status: :succeeded,
      stripe_payment_intent_id: "pi_anon", email: "anon@example.com")
    assert donation.valid?, donation.errors.full_messages.join(", ")
  end

  test "amount_cents must be positive" do
    donation = Donation.new(amount_cents: 0, status: :succeeded,
      stripe_payment_intent_id: "pi_zero")
    refute donation.valid?
    assert_includes donation.errors[:amount_cents], "must be greater than 0"
  end

  test "stripe_payment_intent_id is unique" do
    duplicate = Donation.new(amount_cents: 500, status: :succeeded,
      stripe_payment_intent_id: donations(:regular_user_gift).stripe_payment_intent_id)
    refute duplicate.valid?
    assert_includes duplicate.errors[:stripe_payment_intent_id], "has already been taken"
  end

  test "amount_in_dollars converts cents" do
    assert_equal 25.0, donations(:regular_user_gift).amount_in_dollars
  end

  test "successful scope returns only succeeded donations" do
    assert_includes Donation.successful, donations(:regular_user_gift)
    refute_includes Donation.successful, donations(:failed_attempt)
  end
end
```

- [ ] **Step 4: Write the fixtures**

Create `test/fixtures/billing_plans.yml`:

```yaml
monthly:
  kind: 0            # membership
  key: monthly
  name: Monthly Membership
  interval: 0        # monthly
  amount_cents: 500
  currency: usd
  stripe_price_id: price_test_monthly
  stripe_lookup_key: membership_monthly
  active: true
  position: 0

yearly:
  kind: 0            # membership
  key: yearly
  name: Yearly Membership
  interval: 1        # yearly
  amount_cents: 5000
  currency: usd
  stripe_price_id: price_test_yearly
  stripe_lookup_key: membership_yearly
  active: true
  position: 1

donation:
  kind: 1            # donation
  key: donation
  name: One-time Donation
  currency: usd
  stripe_price_id: price_test_donation
  stripe_lookup_key: donation_custom
  active: true
  position: 2

retired_monthly:
  kind: 0            # membership
  key: monthly_2024
  name: Monthly Membership (retired)
  interval: 0
  amount_cents: 400
  currency: usd
  stripe_price_id: price_test_monthly_2024
  active: false
  position: 3
```

Create `test/fixtures/donations.yml`:

```yaml
regular_user_gift:
  user: regular_user
  amount_cents: 2500
  currency: usd
  status: 1          # succeeded
  stripe_payment_intent_id: pi_regular_gift
  domain: books

anonymous_gift:
  amount_cents: 500
  currency: usd
  status: 1          # succeeded
  stripe_payment_intent_id: pi_anonymous_gift
  email: anonymous@example.com
  domain: music

failed_attempt:
  user: editor_user
  amount_cents: 1000
  currency: usd
  status: 2          # failed
  stripe_payment_intent_id: pi_failed
  domain: games
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/billing_plan_test.rb test/models/donation_test.rb`
Expected: FAIL — enums and scopes are undefined

- [ ] **Step 6: Write both models**

Replace `app/models/billing_plan.rb`:

```ruby
# frozen_string_literal: true

# The price catalogue, replacing the legacy app's config/stripe_products.yml.
#
# Price ids differ between the Stripe sandbox and the production account, which
# is exactly why that YAML file needed a hand-edited per-environment block. As
# database rows, each environment simply holds its own ids, and
# `rake stripe:sync_plans` re-resolves them from stripe_lookup_key.
class BillingPlan < ApplicationRecord
  enum :kind, {membership: 0, donation: 1}, prefix: true
  enum :interval, {monthly: 0, yearly: 1}, prefix: true

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true
  validates :stripe_price_id, presence: true, uniqueness: true
  validates :kind, presence: true

  scope :active, -> { where(active: true).order(:position) }
  scope :membership, -> { where(kind: :membership).order(:position) }

  def self.donation_price = find_by(kind: :donation, active: true)

  def amount_in_dollars = amount_cents && amount_cents / 100.0
end
```

Replace `app/models/donation.rb`:

```ruby
# frozen_string_literal: true

# A one-time payment. Recorded from checkout.session.completed in payment mode,
# and imported from the legacy books database for history.
#
# amount_cents is named for its unit on purpose: the legacy column was `amount`,
# which needed an amount_in_dollars helper to disambiguate at every call site.
class Donation < ApplicationRecord
  belongs_to :user, optional: true

  enum :status, {pending: 0, succeeded: 1, failed: 2, refunded: 3}

  validates :amount_cents, presence: true, numericality: {greater_than: 0}
  validates :status, presence: true
  validates :stripe_payment_intent_id, uniqueness: true, allow_nil: true

  scope :successful, -> { where(status: :succeeded) }
  scope :recent, -> { order(created_at: :desc) }

  def amount_in_dollars = amount_cents / 100.0
end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/models/billing_plan_test.rb test/models/donation_test.rb`
Expected: PASS, 11 runs, 0 failures

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb --fix
git add db/migrate db/schema.rb app/models/billing_plan.rb app/models/donation.rb \
        test/models/billing_plan_test.rb test/models/donation_test.rb \
        test/fixtures/billing_plans.yml test/fixtures/donations.yml
git commit -m "feat(billing): add BillingPlan catalogue and Donation record"
```

---

### Task 5: The webhook test helper

Written before the controller because every remaining task needs it. It builds a **genuinely signed** payload at runtime from a dummy secret, so real signature verification is exercised without a real `whsec_` ever entering the repository.

**Files:**
- Create: `test/support/stripe_webhook_helper.rb`
- Modify: `test/test_helper.rb`

**Interfaces:**
- Produces: `StripeWebhookHelper#stripe_event_payload(type:, object:, id:, livemode:)` → JSON String, and `#stripe_signature_header(payload, secret:, timestamp:)` → String. `TEST_WEBHOOK_SECRET` is the dummy secret.

- [ ] **Step 1: Write the helper**

Create `test/support/stripe_webhook_helper.rb`:

```ruby
# frozen_string_literal: true

# Builds real Stripe webhook signatures for tests.
#
# Stripe signs the string "#{timestamp}.#{payload}" with HMAC-SHA256 and sends
# it as "t=<timestamp>,v1=<hex>". Generating that here rather than checking in a
# captured header means signature verification is genuinely exercised and no
# real signing secret ever lands in the repository.
module StripeWebhookHelper
  TEST_WEBHOOK_SECRET = "whsec_test_dummy_secret"

  def stripe_event_payload(type:, object:, id: "evt_test_#{SecureRandom.hex(6)}", livemode: false)
    {
      id: id,
      object: "event",
      type: type,
      livemode: livemode,
      api_version: Services::Billing::StripeClient::API_VERSION,
      created: Time.current.to_i,
      data: {object: object}
    }.to_json
  end

  def stripe_signature_header(payload, secret: TEST_WEBHOOK_SECRET, timestamp: Time.current.to_i)
    signed = "#{timestamp}.#{payload}"
    digest = OpenSSL::HMAC.hexdigest("SHA256", secret, signed)
    "t=#{timestamp},v1=#{digest}"
  end

  # Minimal subscription object, shaped like the API version we pin. Note
  # current_period_end lives on the ITEM, not the subscription — Basil moved it.
  def stripe_subscription_object(id:, customer:, status: "active", interval: "month",
    period_end: 30.days.from_now, cancel_at_period_end: false, canceled_at: nil)
    {
      id: id,
      object: "subscription",
      customer: customer,
      status: status,
      cancel_at_period_end: cancel_at_period_end,
      canceled_at: canceled_at&.to_i,
      items: {
        object: "list",
        data: [{
          id: "si_#{id}",
          object: "subscription_item",
          current_period_end: period_end.to_i,
          current_period_start: (period_end - 30.days).to_i,
          price: {id: "price_test_monthly", recurring: {interval: interval}}
        }]
      }
    }
  end

  # Posts a correctly signed webhook. Returns the raw payload so callers can
  # assert on the stored row.
  def post_stripe_webhook(payload, secret: TEST_WEBHOOK_SECRET)
    post "/webhooks/stripe",
      params: payload,
      headers: {
        "HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload, secret: secret),
        "CONTENT_TYPE" => "application/json"
      }
    payload
  end
end
```

- [ ] **Step 2: Register the helper**

In `test/test_helper.rb`, add alongside the existing `require_relative "support/turbo_frame_links"`:

```ruby
require_relative "support/stripe_webhook_helper"
```

and inside the `ActionDispatch::IntegrationTest` reopening, add:

```ruby
include StripeWebhookHelper
```

- [ ] **Step 3: Verify the helper loads**

Run: `bin/rails test test/models/stripe_event_test.rb`
Expected: PASS — no behaviour changed, this only confirms the require resolves

- [ ] **Step 4: Commit**

```bash
bundle exec standardrb --fix
git add test/support/stripe_webhook_helper.rb test/test_helper.rb
git commit -m "test(billing): add runtime Stripe webhook signing helper"
```

---

### Task 6: Webhook endpoint — signature verification

**Files:**
- Create: `app/controllers/webhooks/stripe_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/controllers/webhooks/stripe_controller_test.rb`

**Interfaces:**
- Produces: `POST /webhooks/stripe` → 400 on a bad signature, 200 on a good one. Later tasks add the livemode guard and the insert.

- [ ] **Step 1: Write the failing test**

Create `test/controllers/webhooks/stripe_controller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Webhooks
  class StripeControllerTest < ActionDispatch::IntegrationTest
    setup do
      Services::Billing::StripeClient.stubs(:webhook_secret)
        .returns(StripeWebhookHelper::TEST_WEBHOOK_SECRET)
    end

    test "rejects a request with no signature header and writes nothing" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})

      assert_no_difference "StripeEvent.count" do
        post "/webhooks/stripe", params: payload, headers: {"CONTENT_TYPE" => "application/json"}
      end

      assert_response :bad_request
    end

    test "rejects a signature made with the wrong secret and writes nothing" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})

      assert_no_difference "StripeEvent.count" do
        post_stripe_webhook(payload, secret: "whsec_the_wrong_secret")
      end

      assert_response :bad_request
    end

    test "rejects a signature whose timestamp is outside the tolerance window" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})
      stale = stripe_signature_header(payload, timestamp: 10.minutes.ago.to_i)

      assert_no_difference "StripeEvent.count" do
        post "/webhooks/stripe", params: payload,
          headers: {"HTTP_STRIPE_SIGNATURE" => stale, "CONTENT_TYPE" => "application/json"}
      end

      assert_response :bad_request
    end

    test "accepts a correctly signed request" do
      payload = stripe_event_payload(type: "customer.updated", object: {id: "cus_x", object: "customer"})
      post_stripe_webhook(payload)
      assert_response :ok
    end
  end
end
```

The tolerance test is worth having explicitly: Stripe's `DEFAULT_TOLERANCE` is 300 seconds, and a future change that passes a larger tolerance to get around a flaky clock would silently reopen a replay window.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/controllers/webhooks/stripe_controller_test.rb`
Expected: FAIL — `ActionController::RoutingError: No route matches [POST] "/webhooks/stripe"`

- [ ] **Step 3: Add the route**

In `config/routes.rb`, outside every `constraints DomainConstraint...` block — put it next to the `post "auth/sign_in"` group, which is the existing home for host-independent routes:

```ruby
# Stripe webhooks. Deliberately outside every domain constraint: Stripe posts to
# one URL and the host is whatever the endpoint was registered with.
post "webhooks/stripe", to: "webhooks/stripe#create"
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/webhooks/stripe_controller.rb`:

```ruby
# frozen_string_literal: true

module Webhooks
  # Inherits ActionController::Base rather than ApplicationController on
  # purpose: no Pundit, no set_current_domain, no allow_browser check standing
  # between Stripe and a 200.
  #
  # There is no verification bypass — not behind an ENV var, not behind
  # Rails.env.development?, not behind a param. This application is open source,
  # and a bypass someone can read about is a bypass someone will probe for.
  # Local development uses `stripe listen`, which signs with a real secret.
  class StripeController < ActionController::Base
    skip_forgery_protection

    def create
      event = verified_event
      return head :bad_request if event.nil?

      head :ok
    end

    private

    def verified_event
      Stripe::Webhook.construct_event(
        request.raw_post,
        request.env["HTTP_STRIPE_SIGNATURE"],
        Services::Billing::StripeClient.webhook_secret
      )
    rescue JSON::ParserError, Stripe::SignatureVerificationError => e
      # Never log the payload: it carries customer email, name, address and card
      # last-four. The error class and message are enough to diagnose.
      Rails.logger.warn("[stripe-webhook] rejected: #{e.class}")
      nil
    end
  end
end
```

`request.raw_post` rather than `request.body.read`: Rails' JSON parameter parsing consumes the body, and a re-read that returns an empty or re-encoded string fails verification for reasons that are very hard to see.

- [ ] **Step 5: Filter Stripe payload fields out of the parameter log**

We never log the payload ourselves, but Rails' own `ActionController::LogSubscriber` writes parsed params to the log for every request, and a Stripe webhook body carries customer PII.

In `config/initializers/filter_parameter_logging.rb`, extend the existing array:

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Stripe webhook payload fields. ParameterFilter matches at any depth, so
  # these cover the nested card and customer objects in an event body.
  :last4, :exp_month, :exp_year, :postal_code, :address, :customer_details, :billing_details
]
```

Deliberately **not** adding `:name`: it would be filtered app-wide, and list names and book titles appear in params all over this codebase, which would make unrelated debugging much harder. The customer name in a Stripe payload is the accepted residual.

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/controllers/webhooks/stripe_controller_test.rb`
Expected: PASS, 4 runs, 0 failures

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/controllers/webhooks/stripe_controller.rb config/routes.rb \
        config/initializers/filter_parameter_logging.rb \
        test/controllers/webhooks/stripe_controller_test.rb
git commit -m "feat(billing): add Stripe webhook endpoint with signature verification"
```

---

### Task 7: Livemode guard and idempotent insert

**Files:**
- Modify: `app/controllers/webhooks/stripe_controller.rb`
- Create: `app/sidekiq/billing/process_stripe_event_job.rb`
- Test: `test/controllers/webhooks/stripe_controller_test.rb`

**Interfaces:**
- Produces: a persisted `StripeEvent` per accepted event, and `Billing::ProcessStripeEventJob.perform_async(stripe_event_id)` enqueued exactly once per unique event.

- [ ] **Step 1: Generate the job**

Run: `bin/rails generate sidekiq:job billing/process_stripe_event`

- [ ] **Step 2: Write the failing tests**

Append to `test/controllers/webhooks/stripe_controller_test.rb`, inside the class:

```ruby
    test "records an accepted event and enqueues processing" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_brand_new", customer: "cus_brand_new"),
        id: "evt_brand_new"
      )

      Sidekiq::Testing.fake! do
        assert_difference "StripeEvent.count", 1 do
          post_stripe_webhook(payload)
        end
        assert_equal 1, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
      event = StripeEvent.find_by!(stripe_event_id: "evt_brand_new")
      assert_equal "customer.subscription.created", event.event_type
      assert event.received?
      assert_equal "cus_brand_new", event.stripe_customer_id
      # The FULL event is stored, not just data.object.
      assert_equal "evt_brand_new", event.payload["id"]
      assert_equal "customer.subscription.created", event.payload["type"]
    end

    test "a redelivered event returns 200, writes no second row and enqueues nothing" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_dup", customer: "cus_dup"),
        id: "evt_dup"
      )

      Sidekiq::Testing.fake! do
        post_stripe_webhook(payload)
        ::Billing::ProcessStripeEventJob.jobs.clear

        assert_no_difference "StripeEvent.count" do
          post_stripe_webhook(payload)
        end
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
    end

    test "ignores an event whose livemode does not match and writes nothing else" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_live", customer: "cus_live"),
        id: "evt_live", livemode: true
      )

      Sidekiq::Testing.fake! do
        assert_difference "StripeEvent.count", 1 do
          post_stripe_webhook(payload)
        end
        assert_equal 0, ::Billing::ProcessStripeEventJob.jobs.size
      end

      assert_response :ok
      assert StripeEvent.find_by!(stripe_event_id: "evt_live").ignored?
      assert_equal 0, Membership.where(stripe_customer_id: "cus_live").count
    end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/webhooks/stripe_controller_test.rb`
Expected: FAIL — `StripeEvent.count` does not change; the controller stores nothing yet

- [ ] **Step 4: Rewrite the controller action**

Replace the `create` method and add the private methods in `app/controllers/webhooks/stripe_controller.rb`:

```ruby
    def create
      event = verified_event
      return head :bad_request if event.nil?

      record = record_event(event)
      return head :ok if record.nil? # redelivery; already handled

      if event.livemode != Rails.configuration.stripe_livemode
        # The interlock. A sandbox endpoint misconfigured to point at production
        # (or the reverse) writes nothing beyond this audit row.
        record.mark_ignored!("livemode mismatch: event=#{event.livemode} app=#{Rails.configuration.stripe_livemode}")
        return head :ok
      end

      ::Billing::ProcessStripeEventJob.perform_async(record.id)
      head :ok
    end

    private

    # Returns nil when the event has already been recorded. The unique index on
    # stripe_event_id IS the idempotency check — there is no lookup-then-insert
    # race to lose.
    def record_event(event)
      # stripe_customer_id is derived by StripeEvent's before_validation hook,
      # so the extraction rule lives in exactly one place.
      StripeEvent.create!(
        stripe_event_id: event.id,
        event_type: event.type,
        payload: event.to_hash.deep_stringify_keys,
        livemode: event.livemode,
        api_version: event.api_version,
        status: :received,
        stripe_created_at: Time.at(event.created)
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    end
```

Keep the existing `verified_event` method below these.

- [ ] **Step 5: Write the job**

Replace `app/sidekiq/billing/process_stripe_event_job.rb`:

```ruby
# frozen_string_literal: true

module Billing
  # Turns a stored event into a reconcile. The event is only ever read for an
  # identifier — never for state — which is what makes delivery order irrelevant.
  class ProcessStripeEventJob
    include Sidekiq::Job

    def perform(stripe_event_id)
      event = StripeEvent.find(stripe_event_id)
      return unless event.received? || event.failed?

      customer_id = event.stripe_customer_id_from_payload
      if customer_id.blank?
        event.mark_ignored!("no customer on event type #{event.event_type}")
        return
      end

      event.mark_processed!
    rescue => e
      event&.mark_failed!(e)
      raise
    end
  end
end
```

The reconcile call is added in Task 9; this task only establishes the dispatch and the status transitions.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/webhooks/stripe_controller_test.rb`
Expected: PASS, 7 runs, 0 failures

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/controllers/webhooks/stripe_controller.rb \
        app/sidekiq/billing/process_stripe_event_job.rb \
        test/controllers/webhooks/stripe_controller_test.rb
git commit -m "feat(billing): add livemode guard and idempotent event insert"
```

---

### Task 8: ReconcileCustomer — make local match Stripe

The heart of the design. It never reads an event payload; it re-reads Stripe.

**Files:**
- Create: `app/lib/services/billing/reconcile_customer.rb`
- Test: `test/lib/services/billing/reconcile_customer_test.rb`

**Interfaces:**
- Produces: `Services::Billing::ReconcileCustomer.call(stripe_customer_id:)` → `Result` with `success?`, `data` (an Array of `Membership`), `errors`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/billing/reconcile_customer_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class ReconcileCustomerTest < ActiveSupport::TestCase
      include StripeWebhookHelper

      setup do
        @user = users(:contractor_user)
        @user.update!(stripe_customer_id: "cus_reconcile")
      end

      # Builds a Stripe::Subscription from the helper's hash so the service sees
      # the same object shape the real API returns.
      def stripe_subscription(**opts)
        Stripe::Subscription.construct_from(
          stripe_subscription_object(**opts).deep_symbolize_keys
        )
      end

      def stub_stripe_list(subscriptions)
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_reconcile", status: "all"))
          .returns(Stripe::ListObject.construct_from(
            {object: "list", data: subscriptions.map(&:to_hash), has_more: false}
          ))
      end

      test "creates a membership from a stripe subscription" do
        stub_stripe_list([stripe_subscription(id: "sub_r1", customer: "cus_reconcile")])

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert result.success?
        membership = Membership.find_by!(stripe_subscription_id: "sub_r1")
        assert_equal @user, membership.user
        assert membership.source_stripe?
        assert membership.active?
        assert membership.interval_monthly?
        assert_equal "cus_reconcile", membership.stripe_customer_id
        assert_not_nil membership.stripe_synced_at
      end

      test "reads current_period_end from the subscription item, not the subscription" do
        period_end = 45.days.from_now
        stub_stripe_list([stripe_subscription(id: "sub_r2", customer: "cus_reconcile",
          period_end: period_end)])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        membership = Membership.find_by!(stripe_subscription_id: "sub_r2")
        assert_in_delta period_end.to_i, membership.current_period_end.to_i, 1
      end

      test "maps a yearly interval" do
        stub_stripe_list([stripe_subscription(id: "sub_r3", customer: "cus_reconcile",
          interval: "year")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert Membership.find_by!(stripe_subscription_id: "sub_r3").interval_yearly?
      end

      test "updates an existing membership rather than duplicating it" do
        Membership.create!(user: @user, source: :stripe, status: :past_due,
          interval: :monthly, stripe_subscription_id: "sub_r4",
          stripe_customer_id: "cus_reconcile")
        stub_stripe_list([stripe_subscription(id: "sub_r4", customer: "cus_reconcile",
          status: "active")])

        assert_no_difference "Membership.count" do
          ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")
        end

        assert Membership.find_by!(stripe_subscription_id: "sub_r4").active?
      end

      test "never modifies a comped membership" do
        comped = memberships(:editor_user_comped)
        original = comped.attributes.slice("status", "current_period_end", "note")
        stub_stripe_list([])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert_equal original, comped.reload.attributes.slice("status", "current_period_end", "note")
      end

      test "stores an unattached membership when no user matches the customer" do
        # No user has stripe_customer_id "cus_unknown", and the Stripe customer
        # carries no app_user_id metadata, so both resolution paths miss.
        Stripe::Customer.stubs(:retrieve).returns(
          Stripe::Customer.construct_from({id: "cus_unknown", object: "customer", metadata: {}})
        )
        Stripe::Subscription.expects(:list)
          .with(has_entries(customer: "cus_unknown", status: "all"))
          .returns(Stripe::ListObject.construct_from({
            object: "list", has_more: false,
            data: [stripe_subscription(id: "sub_orphan", customer: "cus_unknown").to_hash]
          }))

        ReconcileCustomer.call(stripe_customer_id: "cus_unknown")

        membership = Membership.find_by!(stripe_subscription_id: "sub_orphan")
        assert_nil membership.user
        assert_equal "cus_unknown", membership.stripe_customer_id
      end

      test "recovers the user from customer metadata when the column is unset" do
        @user.update!(stripe_customer_id: nil)
        Stripe::Customer.stubs(:retrieve).returns(
          Stripe::Customer.construct_from({
            id: "cus_reconcile", object: "customer",
            metadata: {app_user_id: @user.id.to_s}
          })
        )
        stub_stripe_list([stripe_subscription(id: "sub_meta", customer: "cus_reconcile")])

        ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        assert_equal @user, Membership.find_by!(stripe_subscription_id: "sub_meta").user
      end

      test "returns a failure result when Stripe errors" do
        Stripe::Subscription.expects(:list).raises(Stripe::APIError.new("upstream down"))

        result = ReconcileCustomer.call(stripe_customer_id: "cus_reconcile")

        refute result.success?
        assert_match(/upstream down/, result.errors.join)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/billing/reconcile_customer_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Billing::ReconcileCustomer`

- [ ] **Step 3: Write the service**

Create `app/lib/services/billing/reconcile_customer.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Makes local Membership rows match what Stripe says about one customer,
    # right now.
    #
    # This is the whole design. Webhook events are never read for state — only
    # for a customer id — so delivery order cannot affect the outcome. A late
    # customer.subscription.created triggers a redundant reconcile that
    # converges on the same rows, and cannot downgrade an active subscription
    # because the event's own status is never written.
    #
    # The same call is also the data migration, the nightly drift check, and the
    # recovery path if the endpoint is ever down past Stripe's 72-hour retry
    # window.
    class ReconcileCustomer
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(stripe_customer_id:)
        new(stripe_customer_id: stripe_customer_id).call
      end

      def initialize(stripe_customer_id:)
        @stripe_customer_id = stripe_customer_id
      end

      def call
        return failure("stripe_customer_id is required") if @stripe_customer_id.blank?

        memberships = ActiveRecord::Base.transaction do
          acquire_lock
          user = resolve_user
          subscriptions.map { |subscription| upsert(subscription, user) }
        end

        Result.new(success?: true, data: memberships, errors: [])
      rescue Stripe::StripeError => e
        Rails.logger.error("[billing] reconcile failed for #{@stripe_customer_id}: #{e.class}")
        failure(e.message)
      end

      private

      # Serialises concurrent reconciles for one customer without adding a
      # dependency. Transaction-scoped, so it releases on commit or rollback and
      # cannot leak. This replaces the legacy handler's RecordNotUnique rescue
      # and retry: the race is removed rather than recovered from.
      def acquire_lock
        ActiveRecord::Base.connection.exec_query(
          "SELECT pg_advisory_xact_lock(hashtext($1)::bigint)",
          "billing-reconcile-lock",
          [@stripe_customer_id]
        )
      end

      def subscriptions
        list = Stripe::Subscription.list(
          customer: @stripe_customer_id, status: "all", limit: 100
        )
        list.respond_to?(:auto_paging_each) ? list.auto_paging_each.to_a : list.data
      end

      # Two independent paths, tried in order. The first should almost always
      # win, because checkout writes stripe_customer_id to the user before any
      # webhook can fire. The second covers subscriptions created outside our
      # checkout — by the legacy books app, or by hand in the Stripe dashboard.
      def resolve_user
        found = ::User.find_by(stripe_customer_id: @stripe_customer_id)
        return found if found

        metadata_user_id = customer&.metadata&.[]("app_user_id")
        return nil if metadata_user_id.blank?

        ::User.find_by(id: metadata_user_id)
      end

      def customer
        @customer ||= Stripe::Customer.retrieve(@stripe_customer_id)
      rescue Stripe::StripeError
        nil
      end

      def upsert(subscription, user)
        membership = ::Membership.find_or_initialize_by(
          stripe_subscription_id: subscription.id
        )

        # Belt and braces. A comped row has no stripe_subscription_id so it can
        # never be found here, but the design promise is that a webhook cannot
        # touch a manual grant, and that promise deserves an explicit guard.
        return membership if membership.persisted? && !membership.stripe?

        item = subscription.items.data.first

        membership.assign_attributes(
          user: user,
          source: :stripe,
          status: subscription.status,
          interval: (item&.price&.recurring&.interval == "year") ? :yearly : :monthly,
          stripe_customer_id: subscription.customer,
          # Basil (2025-03-31) moved this off the subscription onto the item.
          # Reading subscription.current_period_end works today via a deprecated
          # accessor and will stop working without warning.
          current_period_end: item && Time.at(item.current_period_end),
          cancel_at_period_end: !!subscription.cancel_at_period_end,
          canceled_at: subscription.canceled_at && Time.at(subscription.canceled_at),
          stripe_synced_at: Time.current
        )
        membership.save!
        membership
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/billing/reconcile_customer_test.rb`
Expected: PASS, 9 runs, 0 failures

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/lib/services/billing/reconcile_customer.rb \
        test/lib/services/billing/reconcile_customer_test.rb
git commit -m "feat(billing): add ReconcileCustomer as the source of truth for membership state"
```

---

### Task 9: Wire the job to reconcile, and prove order-independence

This task contains the test that *is* the design claim. If someone later reintroduces payload-as-truth, this is what should fail.

**Files:**
- Modify: `app/sidekiq/billing/process_stripe_event_job.rb`
- Test: `test/sidekiq/billing/process_stripe_event_job_test.rb`

**Interfaces:**
- Consumes: `Services::Billing::ReconcileCustomer.call(stripe_customer_id:)` from Task 8.
- Produces: a fully wired ingest-to-reconcile path.

- [ ] **Step 1: Write the failing test**

Create `test/sidekiq/billing/process_stripe_event_job_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Billing
  class ProcessStripeEventJobTest < ActiveSupport::TestCase
    include StripeWebhookHelper

    setup do
      @user = users(:contractor_user)
      @user.update!(stripe_customer_id: "cus_order")
    end

    def event_row(type:, object:, id: "evt_#{SecureRandom.hex(4)}")
      StripeEvent.create!(
        stripe_event_id: id, event_type: type,
        payload: JSON.parse(stripe_event_payload(type: type, object: object, id: id)),
        livemode: false, status: :received, stripe_created_at: Time.current
      )
    end

    def expect_reconcile(customer_id, times: 1)
      Services::Billing::ReconcileCustomer.expects(:call)
        .with(stripe_customer_id: customer_id).times(times)
        .returns(Services::Billing::ReconcileCustomer::Result.new(
          success?: true, data: [], errors: []
        ))
    end

    test "reconciles the customer named on a subscription event" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o1", customer: "cus_order"))
      expect_reconcile("cus_order")

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.processed?
    end

    test "ignores an event with no customer" do
      event = event_row(type: "price.updated", object: {id: "price_x", object: "price"})
      Services::Billing::ReconcileCustomer.expects(:call).never

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.ignored?
    end

    test "does not reprocess an already-processed event" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o2", customer: "cus_order"))
      event.mark_processed!
      Services::Billing::ReconcileCustomer.expects(:call).never

      ProcessStripeEventJob.new.perform(event.id)
    end

    test "marks the event failed and re-raises so Sidekiq retries" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o3", customer: "cus_order"))
      Services::Billing::ReconcileCustomer.expects(:call).raises(StandardError, "boom")

      assert_raises(StandardError) { ProcessStripeEventJob.new.perform(event.id) }

      assert event.reload.failed?
      assert_equal 1, event.attempts
    end

    test "a failed reconcile result marks the event failed without raising" do
      event = event_row(type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_o4", customer: "cus_order"))
      Services::Billing::ReconcileCustomer.expects(:call)
        .returns(Services::Billing::ReconcileCustomer::Result.new(
          success?: false, data: nil, errors: ["stripe unavailable"]
        ))

      ProcessStripeEventJob.new.perform(event.id)

      assert event.reload.failed?
      assert_match(/stripe unavailable/, event.error)
    end

    # ---- The design claim ----
    #
    # Every delivery order of the three events that arrive when someone
    # subscribes must produce identical final state. This passes only because
    # the job reads the event for a customer id and nothing else. If anyone
    # reintroduces payload-as-truth, this is the test that should fail.
    test "every permutation of subscribe-time events converges on the same state" do
      subscription = stripe_subscription_object(id: "sub_perm", customer: "cus_order")
      specs = [
        {type: "customer.subscription.created", object: subscription},
        {type: "checkout.session.completed",
         object: {id: "cs_perm", object: "checkout_session", customer: "cus_order",
                  mode: "subscription", subscription: "sub_perm"}},
        {type: "invoice.paid",
         object: {id: "in_perm", object: "invoice", customer: "cus_order",
                  subscription: "sub_perm"}}
      ]

      states = specs.permutation.map do |ordering|
        Membership.delete_all

        ordering.each_with_index do |spec, index|
          event = event_row(type: spec[:type], object: spec[:object],
            id: "evt_perm_#{SecureRandom.hex(6)}_#{index}")

          Stripe::Customer.stubs(:retrieve).returns(
            Stripe::Customer.construct_from({id: "cus_order", object: "customer", metadata: {}})
          )
          Stripe::Subscription.stubs(:list).returns(
            Stripe::ListObject.construct_from({
              object: "list", has_more: false,
              data: [subscription.deep_symbolize_keys]
            })
          )

          ProcessStripeEventJob.new.perform(event.id)
        end

        Membership.order(:stripe_subscription_id).map do |m|
          m.attributes.slice("user_id", "source", "status", "interval",
            "stripe_subscription_id", "stripe_customer_id", "cancel_at_period_end")
        end
      end

      assert_equal 6, states.size, "expected all six permutations"
      assert_equal 1, states.uniq.size,
        "delivery order changed the final state: #{states.uniq.inspect}"
      assert_equal 1, states.first.size
      assert_equal @user.id, states.first.first["user_id"]
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/sidekiq/billing/process_stripe_event_job_test.rb`
Expected: FAIL — `ReconcileCustomer.call` is never invoked; the job only marks events processed

- [ ] **Step 3: Wire the job**

Replace the `perform` method in `app/sidekiq/billing/process_stripe_event_job.rb`:

```ruby
    def perform(stripe_event_id)
      event = StripeEvent.find(stripe_event_id)
      return unless event.received? || event.failed?

      customer_id = event.stripe_customer_id_from_payload
      if customer_id.blank?
        event.mark_ignored!("no customer on event type #{event.event_type}")
        return
      end

      result = Services::Billing::ReconcileCustomer.call(stripe_customer_id: customer_id)

      if result.success?
        event.mark_processed!
      else
        # A soft failure — usually Stripe being unavailable. Recorded rather than
        # raised, because Sidekiq's retry and the nightly reconcile both cover it.
        event.mark_failed!(result.errors.join("; "))
      end
    rescue => e
      event&.mark_failed!(e)
      raise
    end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/sidekiq/billing/process_stripe_event_job_test.rb`
Expected: PASS, 6 runs, 0 failures

- [ ] **Step 5: Run the whole suite**

Run: `bin/rails test`
Expected: PASS, no new failures. If a test fails with `relation "memberships" does not exist`, run `bin/rails db:test:prepare` and re-run — see Global Constraints.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix
git add app/sidekiq/billing/process_stripe_event_job.rb \
        test/sidekiq/billing/process_stripe_event_job_test.rb
git commit -m "feat(billing): reconcile on every event and prove order-independence"
```

---

### Task 10: ReconcileAllCustomers, rake tasks and the nightly cron

The account-wide sweep. This is what makes Stripe's 72-hour retry limit a non-event, and it is reused as the data migration in the next plan.

**Files:**
- Create: `app/lib/services/billing/reconcile_all_customers.rb`
- Create: `lib/tasks/billing.rake`
- Modify: `config/schedule.yml`
- Create: `app/sidekiq/billing/reconcile_all_customers_job.rb`
- Test: `test/lib/services/billing/reconcile_all_customers_test.rb`

**Interfaces:**
- Consumes: `Services::Billing::ReconcileCustomer.call(stripe_customer_id:)`.
- Produces: `Services::Billing::ReconcileAllCustomers.call` → `Result` whose `data` is `{customers: Integer, reconciled: Integer, failed: Array<String>}`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/services/billing/reconcile_all_customers_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

module Services
  module Billing
    class ReconcileAllCustomersTest < ActiveSupport::TestCase
      def subscription_list(customer_ids)
        Stripe::ListObject.construct_from({
          object: "list", has_more: false,
          data: customer_ids.each_with_index.map do |customer, index|
            {id: "sub_all_#{index}", object: "subscription", customer: customer}
          end
        })
      end

      def ok_result
        ReconcileCustomer::Result.new(success?: true, data: [], errors: [])
      end

      test "reconciles each distinct customer exactly once" do
        Stripe::Subscription.expects(:list).returns(
          subscription_list(%w[cus_a cus_b cus_a])
        )
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a").once.returns(ok_result)
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b").once.returns(ok_result)

        result = ReconcileAllCustomers.call

        assert result.success?
        assert_equal 2, result.data[:customers]
        assert_equal 2, result.data[:reconciled]
        assert_empty result.data[:failed]
      end

      test "keeps going when one customer fails and reports it" do
        Stripe::Subscription.expects(:list).returns(subscription_list(%w[cus_a cus_b]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_a")
          .returns(ReconcileCustomer::Result.new(success?: false, data: nil, errors: ["nope"]))
        ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_b").returns(ok_result)

        result = ReconcileAllCustomers.call

        assert result.success?
        assert_equal 1, result.data[:reconciled]
        assert_equal ["cus_a"], result.data[:failed]
      end

      test "returns a failure result when the account listing itself fails" do
        Stripe::Subscription.expects(:list).raises(Stripe::APIError.new("account listing down"))

        result = ReconcileAllCustomers.call

        refute result.success?
        assert_match(/account listing down/, result.errors.join)
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/billing/reconcile_all_customers_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::Billing::ReconcileAllCustomers`

- [ ] **Step 3: Write the service**

Create `app/lib/services/billing/reconcile_all_customers.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Sweeps every subscription in the Stripe account and reconciles each
    # distinct customer.
    #
    # Three jobs, one implementation:
    #   1. the initial data migration from the legacy books app
    #   2. a nightly drift check
    #   3. recovery if the webhook endpoint is ever down past Stripe's 72-hour
    #      retry window, after which events are gone for good
    #
    # One customer failing never stops the sweep; failures are collected and
    # reported so a partial outage is visible rather than silent.
    class ReconcileAllCustomers
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        customer_ids = distinct_customer_ids
        failed = []
        reconciled = 0

        customer_ids.each do |customer_id|
          result = ReconcileCustomer.call(stripe_customer_id: customer_id)
          if result.success?
            reconciled += 1
          else
            failed << customer_id
            Rails.logger.error("[billing] sweep could not reconcile #{customer_id}")
          end
        end

        Result.new(
          success?: true,
          data: {customers: customer_ids.size, reconciled: reconciled, failed: failed},
          errors: []
        )
      rescue Stripe::StripeError => e
        Rails.logger.error("[billing] sweep aborted: #{e.class}")
        Result.new(success?: false, data: nil, errors: [e.message])
      end

      private

      def distinct_customer_ids
        list = Stripe::Subscription.list(status: "all", limit: 100)
        rows = list.respond_to?(:auto_paging_each) ? list.auto_paging_each.to_a : list.data
        rows.filter_map { |subscription| subscription.customer }.uniq
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/billing/reconcile_all_customers_test.rb`
Expected: PASS, 3 runs, 0 failures

- [ ] **Step 5: Add the cron job wrapper**

Run: `bin/rails generate sidekiq:job billing/reconcile_all_customers`

Replace `app/sidekiq/billing/reconcile_all_customers_job.rb`:

```ruby
# frozen_string_literal: true

module Billing
  # Nightly drift check. Logs a summary so a divergence between local rows and
  # Stripe shows up in the log rather than in a support email.
  class ReconcileAllCustomersJob
    include Sidekiq::Job

    def perform
      result = Services::Billing::ReconcileAllCustomers.call

      if result.success?
        Rails.logger.info(
          "[billing] nightly sweep: #{result.data[:reconciled]}/#{result.data[:customers]} " \
          "customers reconciled, failed=#{result.data[:failed].inspect}"
        )
      else
        Rails.logger.error("[billing] nightly sweep failed: #{result.errors.join('; ')}")
        raise result.errors.join("; ")
      end
    end
  end
end
```

- [ ] **Step 6: Schedule it**

Append to `config/schedule.yml`:

```yaml

billing_reconcile_all:
  class: Billing::ReconcileAllCustomersJob
  cron: "0 5 * * *"
  description: "Reconcile every Stripe customer against local membership rows"
```

- [ ] **Step 7: Add the rake tasks**

Create `lib/tasks/billing.rake`:

```ruby
# frozen_string_literal: true

namespace :billing do
  desc "Reconcile every Stripe customer against local membership rows"
  task reconcile_all: :environment do
    result = Services::Billing::ReconcileAllCustomers.call

    if result.success?
      puts "Customers seen:  #{result.data[:customers]}"
      puts "Reconciled:      #{result.data[:reconciled]}"
      puts "Failed:          #{result.data[:failed].size}"
      result.data[:failed].each { |id| puts "  #{id}" }
    else
      warn "Sweep failed: #{result.errors.join("; ")}"
      exit 1
    end
  end

  desc "Re-enqueue every stripe_event left in the failed state"
  task replay_failed: :environment do
    events = StripeEvent.failed.order(:stripe_created_at)
    puts "Re-enqueuing #{events.count} failed events"
    events.find_each { |event| Billing::ProcessStripeEventJob.perform_async(event.id) }
  end
end
```

- [ ] **Step 8: Run the whole suite**

Run: `bin/rails test && bundle exec standardrb`
Expected: PASS with no offences

- [ ] **Step 9: Commit**

```bash
git add app/lib/services/billing/reconcile_all_customers.rb \
        app/sidekiq/billing/reconcile_all_customers_job.rb \
        lib/tasks/billing.rake config/schedule.yml \
        test/lib/services/billing/reconcile_all_customers_test.rb
git commit -m "feat(billing): add account-wide reconcile sweep with nightly cron"
```

---

## Manual verification against a Stripe Sandbox

Not automatable, and worth doing once before the next plan builds on this.

- [ ] Create a Stripe Sandbox in the dashboard. Put its secret key in `web-app/.env` as `STRIPE_SECRET_KEY`, and set `STRIPE_LIVEMODE=false`.
- [ ] Run `stripe listen --forward-to localhost:3000/webhooks/stripe`. Copy the `whsec_` it prints into `web-app/.env` as `STRIPE_WEBHOOK_SECRET`. **This is not the same secret as a dashboard endpoint's** — mixing them up is the most common signature-verification failure.
- [ ] Start the app. Per the project's environment notes, `bin/dev` needs a TTY and self-terminates in a backgrounded agent shell; use `yarn build:all` then `bin/rails server`.
- [ ] Run `stripe trigger customer.subscription.created`. Confirm a `StripeEvent` row appears with `status: processed`, and a `Membership` row exists with the right status and period end.
- [ ] Run the same trigger again with the same event replayed from the Stripe dashboard. Confirm no second `StripeEvent` row and no change to the membership.
- [ ] Run `bin/rails billing:reconcile_all` and confirm the counts match what the sandbox dashboard shows.

---

## Definition of done

- [ ] `bin/rails test` passes with no new failures
- [ ] `bundle exec standardrb` reports no offences
- [ ] The permutation test in Task 9 passes, and fails if `ReconcileCustomer` is changed to write `event.data.object.status` instead of re-reading Stripe
- [ ] An unsigned request returns 400 and writes zero rows
- [ ] A redelivered event returns 200 and writes no second row
- [ ] A `livemode` mismatch is recorded as ignored and reconciles nothing
- [ ] A comped membership survives a reconcile untouched
- [ ] Manual sandbox verification above is complete
