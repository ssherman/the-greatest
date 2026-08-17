# Membership Data Migration & Admin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the two pieces of legacy billing history that Stripe cannot supply — early-supporter comps and donation records — and give the app an admin surface for memberships, donations, Stripe events and billing plans.

**Architecture:** Two read-only legacy-database importers subclass the existing `Services::BooksMigration::Migrator`, driven by `data_migration:` rake tasks, and a `Services::Billing::VerifyMigration` service reports the cross-database invariants. Four flat `Admin::` controllers, routed in the existing global (domain-unconstrained) `namespace :admin` block and gated on the admin role, expose the billing tables. Two `Membership` hardening changes — a partial unique index and an absence validation — make the comp write path structurally safe rather than defensively guarded.

**Tech Stack:** Rails 8.1, PostgreSQL (two databases: `primary` and the read-only `legacy_books` replica), Sidekiq, Pagy, DaisyUI 5 on Tailwind 4, Minitest + fixtures + Mocha, Playwright, standardrb.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — this plan is **plan 2 of 6**, covering spec increments **4** and **9**.

## Plan decomposition

| Plan | Spec increments | Status |
|---|---|---|
| Billing core | 1, 2, 3 | **MERGED + deployed** (PRs #228, #229, #231) |
| **Data migration & admin** (this plan) | **4, 9** | this one |
| Mail foundation | 5 | not started |
| Selling: checkout, join page, entitlements, E2E | 6, 7, 11 | not started |
| Membership emails | 8 | not started |
| Legacy guard patch | 10 | separate repository |

## What increment 4 does NOT include

**The "rebuild subscriptions from Stripe" half of increment 4 is already done.** `billing:reconcile_all` ran in production and reconciled 127 of 127 customers, and the nightly `sidekiq-cron` sweep keeps it current. Do not write a subscription importer, do not re-run the sweep as part of this work, and do not "improve" `ReconcileAllCustomers`. What remains is the two things that can only come from the legacy database.

## One spec service is deliberately not built

The spec's service list names `Services::Billing::ClaimUnattachedMemberships`, without assigning it to an increment. **This plan replaces it with the manual attach action in Task 6, and that is a decision, not an omission.**

An automated claim has to guess which person a Stripe customer belongs to, and the only signal available is the email address on the Stripe customer record. Matching on that hands one person another person's paid membership whenever two accounts share an address, an address has been recycled, or a customer's Stripe email is stale — and it does so silently, at whatever hour the sweep runs. The volume does not justify the risk: the whole production account is 127 customers, and the ones that failed to resolve automatically are exactly the ones where the automatic answer was not good enough.

So an unattached membership surfaces as a banner and a filter, and a human confirms the identity and enters a user id. If a real claiming flow is ever wanted, the natural home is the user-facing side — a signed-in person proving they own the Stripe customer — not a background job.

## Verified facts about the data

Measured against the live legacy database on 2026-08-15. The production numbers will have drifted slightly by the time this runs — that is expected and is exactly why `billing:verify_migration` reports lists rather than asserting counts.

| Fact | Value |
|---|---|
| Legacy `users.paid = true` | 28 rows, all 28 ids present in the new `users` table |
| Of those, also carrying a legacy subscription | 6 |
| Legacy `donations` | 21 rows, **all** `status = 1` (succeeded) |
| Legacy donation `user_id` | never null; all 19 distinct ids present in the new `users` table |
| Legacy donation `stripe_payment_id` | never null, all `pi_` prefixed, no duplicates |
| Legacy donation `amount` | 500–5000, **already in cents** (legacy `amount_in_dollars` divides by 100) |
| Legacy `subscriptions` | 115 rows, all with a non-null distinct `stripe_subscription_id` |
| New-side `memberships` in **development** | 0 (production holds the 127-customer reconcile result) |

**Legacy `paid` is a permanent lifetime grant, not a denormalised subscription flag.** Verified in the legacy source: `User#member?` is `paid? || active_membership?`, and `webhooks_controller.rb` carries three `# No longer updating paid status here` comments. Nothing writes `paid` any more.

**Decision (approved by the owner): import all 28, including the 6 who also pay.** This reproduces live legacy behaviour exactly — those 6 have lifetime access today and keep it. It means 6 users will legitimately hold two membership rows, one `source: :stripe` and one `source: :legacy`. The admin UI must not treat that as an error, and `billing:verify_migration` reports the overlap count so it is visible rather than surprising.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Working directory is `web-app/`** for every Rails and yarn command. Docs live at the project root in `docs/`, **not** `web-app/docs/`. When in doubt, `pwd` first.
- **The development database is not disposable.** The books data exists ONLY in development and takes hours to rebuild. Never run `db:drop`, `db:reset`, `db:schema:load`, or `ActiveRecord::FixtureSet.create_fixtures` against development — `create_fixtures` TRUNCATES every table it names, it is not a read. To inspect a fixture, read the YAML. A `PreToolUse` hook blocks most of these.
- **Worktree test-database hazard.** This worktree shares `the_greatest_test` with the main checkout. A new index or table created here can **vanish between commands** if anything runs from the main checkout. If a test suddenly fails with a missing relation or index, re-run `bin/rails db:test:prepare` — the migration is fine.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop` (omakase, conflicting style). Run `bundle exec standardrb --fix` before each commit.
- **Do not run brakeman.** The gate is `bin/rails test` + `standardrb` + Playwright.
- **Use Rails generators** for migrations and any new model/controller — they create the matching test file.
- **Rails 8 enum syntax:** `enum :status, {active: 0}` with the colon prefix. Never `enum status: {...}`.
- **Root-anchor constants inside nested modules.** Inside `Services::BooksMigration`, write `::Membership`, `::Donation`, `::User`. Inside any `Admin::` controller, write `::Billing::ProcessStripeEventJob`. Bare references have produced confusing `NameError`s in this codebase at least three times.
- **`retry` is a Ruby keyword.** The Stripe-event re-run action is named **`reprocess`**, never `retry` — `def retry` is a syntax error.
- **Services** live in `app/lib/services/`, jobs in `app/sidekiq/`. **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` — the `keyword_init` is deliberate and a Standard cop is disabled for it.
- **Tests never hit the network.** `WebMock.disable_net_connect!` is active and `Sidekiq::Testing.inline!` runs jobs synchronously. Stub with Mocha.
- **No legacy test database exists or is required.** `LegacyBooks::Record` skips `connects_to` in the test environment. Every migrator test stubs `legacy_each`; every `VerifyMigration` test stubs the three legacy-read seams. **No test may query a `LegacyBooks::` model for real.**
- **Consequence of the above:** any filtering done in a legacy SQL scope is untestable. Where a rule matters, mirror it in Ruby inside the per-row method so a test can exercise it, and keep the scope for efficiency. This is the precedent `ReviewMigrator` sets and explains.
- **Fixture names are semantic** — `admin_user`, `regular_user`, `editor_user`, `password_user`, `google_user`, `contractor_user`. Never `one`/`two`. Read the YAML to check a name.
- **Existing membership fixtures** (`test/fixtures/memberships.yml`): `regular_user_monthly` (stripe/active), `google_user_canceled_in_grace` (stripe/canceled, future period end), `editor_user_comped` (comped/active, nil period end), `password_user_legacy` (legacy/active, nil period end). **`editor_user_comped` and `password_user_legacy` already occupy the one-comp-and-one-legacy-grant-per-user slots for those two users** — a test that comps `editor_user` again will hit the new unique index.
- **daisyUI is 5.7.x, Tailwind is v4.** These ten classes were removed in v5 and fail **silently**: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`. `test/lint/daisyui_v4_classes_test.rb` fails on any new occurrence and its allowlist must stay empty. Copying markup from a neighbouring admin view is safe — the branch-wide sweep is done.
- **Colour never carries meaning alone.** Membership and event status is conveyed **in words**. Never green-versus-red. The books theme's `success` token is purple on purpose — do not "fix" it.
- **Controller tests assert behaviour** — status codes, redirects, side effects on the database. Never HTML, CSS, or copy. If a designer could change it freely, do not test it.
- **`ActionController::Parameters.action_on_unpermitted_parameters` is `nil` in this app's test environment** (verified by running it, not assumed). An unpermitted param is silently dropped — it neither raises nor logs. Several tests below post `source`, `granted_by_id` and `stripe_price_id` deliberately to prove they are ignored; those tests only work because of this. If a future change sets it to `:raise`, they will need `assert_raises` instead.
- **`assert_queries_count` takes an exact integer in this codebase**, never a range (`assert_queries_count(7)`, `assert_queries_count(0)`). A range argument is not supported. Pin the real number by running the test — see Task 5 for the procedure.
- **This repository is public.** Never commit a real Stripe key, `whsec_`, price id from a live account, customer id, or captured webhook payload. Every fixture payload is synthetic.
- **Schema migrates itself on deploy.** `bin/docker-entrypoint` runs `./bin/rails db:prepare` when the command contains `rails server`, which is the `web` container's `CMD`. **The `worker` container runs `bundle exec sidekiq` and therefore skips it**, so during a deploy Sidekiq can briefly process jobs against an un-migrated database. Rake tasks are always run by hand.

---

## File Structure

**Created:**

| File | Responsibility |
|---|---|
| `db/migrate/<ts>_add_one_grant_per_user_index_to_memberships.rb` | Partial unique index: one legacy grant and one comp per user |
| `app/models/legacy_books/donation.rb` | Read-only view of legacy `donations` |
| `app/models/legacy_books/subscription.rb` | Read-only view of legacy `subscriptions`, for verification only |
| `app/lib/services/books_migration/membership_migrator.rb` | `users.paid = true` → `source: :legacy` memberships |
| `app/lib/services/books_migration/donation_migrator.rb` | Legacy `donations` → new `donations` |
| `app/lib/services/billing/verify_migration.rb` | Cross-database invariant report |
| `app/controllers/admin/memberships_controller.rb` | Membership list, detail, comp, edit, revoke, attach |
| `app/controllers/admin/donations_controller.rb` | Donation list (read-only) |
| `app/controllers/admin/stripe_events_controller.rb` | Event list, detail, re-run |
| `app/controllers/admin/billing_plans_controller.rb` | Plan list and display-field editing |
| `app/views/admin/memberships/{index,show,new,edit}.html.erb` | Membership screens |
| `app/views/admin/donations/index.html.erb` | Donation list |
| `app/views/admin/stripe_events/{index,show}.html.erb` | Event screens |
| `app/views/admin/billing_plans/{index,edit}.html.erb` | Plan screens |
| `test/lib/services/books_migration/membership_migrator_test.rb` | |
| `test/lib/services/books_migration/donation_migrator_test.rb` | |
| `test/lib/services/billing/verify_migration_test.rb` | |
| `test/controllers/admin/memberships_controller_test.rb` | |
| `test/controllers/admin/donations_controller_test.rb` | |
| `test/controllers/admin/stripe_events_controller_test.rb` | |
| `test/controllers/admin/billing_plans_controller_test.rb` | |
| `e2e/tests/books/admin/billing.spec.ts` | Playwright coverage of the four screens |
| `docs/features/membership-billing.md` | Subsystem documentation |

**Modified:** `app/models/membership.rb`, `config/routes.rb`, `lib/tasks/data_migration.rake`, `lib/tasks/billing.rake`, `app/views/admin/shared/_sidebar.html.erb`, `test/models/membership_test.rb`, `test/fixtures/memberships.yml`, `db/schema.rb` (auto).

---

### Task 1: Membership hardening — one grant per user, no subscription id on a manual grant

Closes two carried-forward items from the billing core, both of which the spec assigns here because this is where the comp write path first exists to test them against.

The first: the spec claims a comped membership is "structurally unreachable" from the reconciler, but today that rests only on a defensive `return` inside `ReconcileCustomer#upsert` — nothing stops a comped row from carrying a `stripe_subscription_id` in the first place. An absence validation makes the claim real.

The second: without a database constraint, the comp form and the legacy importer are both idempotent only by convention. A partial unique index on `(user_id, source)` restricted to non-Stripe sources gives each user at most one legacy grant and at most one comp, while leaving Stripe rows unconstrained — a user with two Stripe subscriptions is legitimate.

**Files:**
- Create: `db/migrate/<timestamp>_add_one_grant_per_user_index_to_memberships.rb`
- Modify: `app/models/membership.rb`
- Test: `test/models/membership_test.rb`

**Interfaces:**
- Produces: `Membership` rejects `stripe_subscription_id` on any row whose `source` is not `stripe`; the database rejects a second row with the same `(user_id, source)` when `source <> 0`. Later tasks rely on `Membership.source_legacy` / `.source_comped` / `.source_stripe` (the `source` enum carries `prefix: true`).

- [ ] **Step 1: Write the failing model tests**

Append to `test/models/membership_test.rb`:

```ruby
  test "a comped membership may not carry a stripe_subscription_id" do
    membership = Membership.new(
      user: users(:contractor_user), source: :comped, status: :active,
      stripe_subscription_id: "sub_should_not_be_here"
    )
    assert_not membership.valid?
    assert membership.errors.of_kind?(:stripe_subscription_id, :present)
  end

  test "a legacy membership may not carry a stripe_subscription_id" do
    membership = Membership.new(
      user: users(:contractor_user), source: :legacy, status: :active,
      stripe_subscription_id: "sub_should_not_be_here"
    )
    assert_not membership.valid?
  end

  test "a stripe membership still requires a stripe_subscription_id" do
    membership = Membership.new(user: users(:contractor_user), source: :stripe, status: :active)
    assert_not membership.valid?
    assert membership.errors.of_kind?(:stripe_subscription_id, :blank)
  end

  test "a second comped membership for the same user is rejected by the database" do
    # editor_user already holds editor_user_comped.
    assert_raises(ActiveRecord::RecordNotUnique) do
      Membership.new(user: users(:editor_user), source: :comped, status: :active).save(validate: false)
    end
  end

  test "a user may hold both a legacy grant and a comp" do
    Membership.create!(user: users(:contractor_user), source: :legacy, status: :active)
    membership = Membership.new(user: users(:contractor_user), source: :comped, status: :active)
    assert membership.save, membership.errors.full_messages.to_sentence
  end

  test "a user may hold two stripe memberships" do
    membership = Membership.new(
      user: users(:regular_user), source: :stripe, status: :active,
      stripe_subscription_id: "sub_regular_second", stripe_customer_id: "cus_regular"
    )
    assert membership.save, membership.errors.full_messages.to_sentence
  end

  test "two unattached comped rows are allowed" do
    Membership.create!(user: nil, source: :comped, status: :active)
    membership = Membership.new(user: nil, source: :comped, status: :active)
    assert membership.save, membership.errors.full_messages.to_sentence
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/models/membership_test.rb
```

Expected: the two absence tests FAIL (a comped row with a subscription id is currently valid), and the "second comped membership" test FAILS with no exception raised.

- [ ] **Step 3: Generate and write the migration**

```bash
bin/rails generate migration AddOneGrantPerUserIndexToMemberships
```

Replace the generated body:

```ruby
class AddOneGrantPerUserIndexToMemberships < ActiveRecord::Migration[8.1]
  def change
    # source <> 0 is "not :stripe". A user may hold any number of Stripe
    # subscriptions -- that is Stripe's business -- but at most one legacy
    # early-supporter grant and at most one comp. This is what makes both
    # MembershipMigrator and the admin comp form idempotent structurally
    # rather than by convention.
    #
    # user_id IS NOT NULL is required, not decorative: an unattached row is a
    # customer we could not map, and several of those must be able to coexist.
    add_index :memberships, [:user_id, :source],
      unique: true,
      where: "source <> 0 AND user_id IS NOT NULL",
      name: "index_memberships_one_grant_per_user_per_source"
  end
end
```

- [ ] **Step 4: Add the absence validation**

In `app/models/membership.rb`, directly below the existing `validates :stripe_subscription_id, presence: true, if: :source_stripe?`:

```ruby
  # The other direction, and the reason the spec's "a comped membership is
  # structurally unreachable from the reconciler" is a guarantee rather than an
  # aspiration. ReconcileCustomer finds rows by stripe_subscription_id, so a
  # manual grant that cannot hold one can never be found -- the defensive
  # `return unless membership.stripe?` guard in ReconcileCustomer#upsert is now
  # belt to this braces, not the only thing standing between a webhook and an
  # admin's decision.
  validates :stripe_subscription_id, absence: true, unless: :source_stripe?
```

Add this to the class-level comment, above `class Membership`:

```ruby
# CALLER WARNING -- the uniqueness/partial-index trap. `validates
# :stripe_subscription_id, uniqueness: true, allow_nil: true` runs a SELECT
# before the INSERT, so an ordinary duplicate raises RecordInvalid, NOT
# RecordNotUnique; the database constraint only fires when two writers race
# past the SELECT. A caller that needs to tell "already taken" from any other
# validation failure must rescue BOTH and narrow the RecordInvalid branch with
# `e.record.errors.of_kind?(:stripe_subscription_id, :taken)`, exactly as
# Webhooks::StripeController#record_event does for StripeEvent. Rescuing
# RecordInvalid broadly here would silently swallow an unrelated failure.
#
# The (user_id, source) index added alongside the absence validation below is
# NOT mirrored by a model validation, deliberately: it exists to make the comp
# and legacy-import write paths idempotent, and those paths use
# find_or_initialize_by, so they never generate a duplicate in normal
# operation. A caller that can race must rescue RecordNotUnique.
```

- [ ] **Step 5: Migrate and run the tests**

```bash
bin/rails db:migrate
bin/rails db:test:prepare
bin/rails test test/models/membership_test.rb
```

Expected: PASS. If a test fails with the index missing, re-run `bin/rails db:test:prepare` — see the worktree hazard in Global Constraints.

- [ ] **Step 6: Run the full model suite and the linter**

```bash
bin/rails test test/models/
bundle exec standardrb --fix
```

Expected: PASS. `annotaterb` rewrites the schema comment blocks in `app/models/membership.rb` and `test/fixtures/memberships.yml` — include those changes in the commit.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/membership.rb test/models/membership_test.rb test/fixtures/memberships.yml
git commit -m "feat(billing): one grant per user, and no subscription id on a manual grant"
```

---

### Task 2: Import legacy early supporters as source: :legacy memberships

28 legacy users carry `paid = true`, a permanent lifetime grant with no Stripe representation. They become `source: :legacy, status: :active, current_period_end: nil` membership rows.

`current_period_end: nil` is load-bearing — the spec's access rule for a non-Stripe row is "status `active` **and** `current_period_end` null or in the future", so nil is what makes the grant never expire.

Legacy `users.created_at` is the signup date, not the date the grant was given, so it is **not** copied onto the membership; these rows get today's timestamps.

**Files:**
- Create: `app/models/legacy_books/donation.rb` *(created here so Task 3 can use it; it is a two-line file and does not warrant its own task)*
- Create: `app/lib/services/books_migration/membership_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/membership_migrator_test.rb`

**Interfaces:**
- Consumes: `Membership` with the `(user_id, source)` unique index and the `absence` validation from Task 1.
- Produces: `Services::BooksMigration::MembershipMigrator.call` → `{success: true, data: {model: "Membership", count: Integer}}` or `{success: false, error: String, data: {...}}` (the shape `Services::BooksMigration::Migrator` returns). Rake task `data_migration:memberships`.

- [ ] **Step 1: Write the failing migrator test**

Create `test/lib/services/books_migration/membership_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::MembershipMigratorTest < ActiveSupport::TestCase
  # legacy_each is stubbed in every migrator test — no legacy test database
  # exists, and none is required. See the plan's Global Constraints.
  def run_migrator(rows)
    m = Services::BooksMigration::MembershipMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # A legacy users row as record.attributes yields it (String keys). Only the
  # three columns this migrator reads need to be realistic.
  def legacy_attrs(overrides = {})
    {"id" => users(:contractor_user).id, "paid" => true, "email" => "supporter@example.com"}.merge(overrides)
  end

  test "grants a never-expiring legacy membership to a paid user" do
    result = run_migrator([legacy_attrs])
    assert result[:success], result[:error]

    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    assert_not_nil membership
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
    assert_equal "Legacy early supporter", membership.note
    assert_nil membership.stripe_subscription_id
  end

  test "is idempotent across two runs" do
    run_migrator([legacy_attrs])
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs])
      assert result[:success], result[:error]
    end
  end

  test "does not overwrite a note an admin has edited" do
    run_migrator([legacy_attrs])
    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    membership.update!(note: "Verified by hand")

    run_migrator([legacy_attrs])
    assert_equal "Verified by hand", membership.reload.note
  end

  test "skips a legacy user that does not exist in the new users table" do
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs("id" => 999_999_999)])
      assert result[:success], result[:error]
    end
  end

  test "skips a row that is not flagged paid" do
    assert_no_difference -> { Membership.count } do
      result = run_migrator([legacy_attrs("paid" => false)])
      assert result[:success], result[:error]
    end
  end

  test "leaves an existing stripe membership for the same user untouched" do
    stripe_membership = memberships(:regular_user_monthly)
    run_migrator([legacy_attrs("id" => users(:regular_user).id)])

    assert_equal "active", stripe_membership.reload.status
    assert_equal "sub_regular_monthly", stripe_membership.stripe_subscription_id
    assert_equal "stripe", stripe_membership.source
    # Both rows coexist: this is the 6-overlap case, and it is intended.
    assert_equal 1, Membership.source_legacy.where(user_id: users(:regular_user).id).count
  end

  test "reactivates a legacy grant an admin previously revoked" do
    run_migrator([legacy_attrs])
    membership = Membership.source_legacy.find_by(user_id: users(:contractor_user).id)
    membership.update!(status: :canceled, current_period_end: 1.day.ago)

    run_migrator([legacy_attrs])
    membership.reload
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
  end
end
```

The last test pins a deliberate decision: the importer is a faithful mirror of legacy `paid`, so re-running it restores a grant. Anyone who wants a revoke to stick must clear `paid` in the legacy database — which is where the fact lives.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/membership_migrator_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::MembershipMigrator`.

- [ ] **Step 3: Create the legacy read models**

Create `app/models/legacy_books/donation.rb`:

```ruby
module LegacyBooks
  class Donation < Record
    self.table_name = "donations"
  end
end
```

- [ ] **Step 4: Write the migrator**

Create `app/lib/services/books_migration/membership_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `users.paid = true` -> a global Membership with source: :legacy.
    #
    # These 28 early supporters have no Stripe representation at all, which is
    # why the account-wide reconcile cannot produce them: they are the half of
    # the migration that can only come from the legacy database.
    #
    # Legacy `paid` is a PERMANENT grant, not a denormalised subscription flag.
    # Verified in the legacy source: User#member? is `paid? || active_membership?`
    # and webhooks_controller.rb stopped writing the column years ago. So a user
    # who is both an early supporter and a paying subscriber legitimately ends up
    # with two membership rows, and keeps access if the Stripe one lapses --
    # exactly what the live legacy site does today.
    #
    # current_period_end stays nil on purpose: Membership.granting_access reads a
    # non-Stripe row as "active AND (current_period_end IS NULL OR in the
    # future)", so nil is what encodes "never expires".
    #
    # Timestamps are NOT copied from the legacy user. users.created_at is the
    # signup date, not the date the grant was made; there is no column recording
    # the latter, so these rows get today's.
    class MembershipMigrator < Migrator
      NOTE = "Legacy early supporter"

      private

      # Scoped so the run streams 28 rows rather than every legacy user. The
      # `paid` check is repeated in upsert_row below because every migrator test
      # stubs legacy_each, which makes a scope-level filter untestable -- the
      # same tradeoff ReviewMigrator documents for its dedup.
      def legacy_model
        LegacyBooks::User.where(paid: true)
      end

      def model_key
        "Membership"
      end

      def upsert_row(attrs)
        return unless attrs["paid"]
        # A legacy user created after the user migration ran has no row here.
        # Skip rather than raise: the same books/users drift that makes
        # data_migration:reviews fail standalone against the live legacy
        # database. billing:verify_migration reports the shortfall by id.
        return unless ::User.exists?(id: attrs["id"])

        membership = ::Membership.find_or_initialize_by(user_id: attrs["id"], source: :legacy)
        membership.status = :active
        membership.current_period_end = nil
        # ||= so a note an admin has edited survives a re-run.
        membership.note ||= NOTE
        membership.save!
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/books_migration/membership_migrator_test.rb
```

Expected: PASS.

- [ ] **Step 6: Add the rake task**

In `lib/tasks/data_migration.rake`, insert before the `desc "Run all Phase-1 migrators in dependency order"` line:

```ruby
  desc "Import legacy users.paid early supporters as source: :legacy memberships"
  task memberships: :environment do
    # Print the arithmetic rather than trusting the count: upsert_row skips
    # silently for a user missing from the new users table, and a silent skip in
    # a billing migration is exactly the thing worth surfacing.
    legacy_paid = LegacyBooks::User.where(paid: true).count

    result = Services::BooksMigration::MembershipMigrator.call
    pp result
    abort "memberships migration failed: #{result[:error]}" unless result[:success]

    granted = Membership.source_legacy.count
    pp({
      legacy_paid_users: legacy_paid,
      legacy_memberships_now: granted,
      unaccounted_for: legacy_paid - granted
    })
  end
```

**Deliberately not added to `data_migration:all`.** That chain is the books content cold load and re-running it must not depend on the billing tables.

- [ ] **Step 7: Verify the task is wired and lint**

```bash
bin/rails -T data_migration:memberships
bundle exec standardrb --fix
bin/rails test test/lib/services/books_migration/
```

Expected: the task is listed with its description; tests PASS. **Do not run the task itself** — it writes to the development database against the live legacy database, which is a production-shaped operation and is not part of implementing this plan.

- [ ] **Step 8: Commit**

```bash
git add app/models/legacy_books/donation.rb app/lib/services/books_migration/membership_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/membership_migrator_test.rb
git commit -m "feat(billing): import legacy early supporters as legacy-source memberships"
```

---

### Task 3: Import legacy donation history

21 append-only donation records. Column renames: `stripe_payment_id` → `stripe_payment_intent_id`, `amount` → `amount_cents` (already cents — legacy's `amount_in_dollars` divides by 100).

The legacy `status` enum is `pending: 0, succeeded: 1, failed: 2, refunded: 3`, byte-identical to the new one, so the raw integer copies across. Legacy has no `currency` column; the new column's `usd` default applies.

Legacy timestamps **are** preserved here, unlike Task 2 — a donation's `created_at` is the date the money arrived, which is the fact being imported.

**Files:**
- Create: `app/lib/services/books_migration/donation_migrator.rb`
- Modify: `lib/tasks/data_migration.rake`
- Test: `test/lib/services/books_migration/donation_migrator_test.rb`

**Interfaces:**
- Consumes: `LegacyBooks::Donation` from Task 2.
- Produces: `Services::BooksMigration::DonationMigrator.call` → the same `{success:, data: {model: "Donation", count:}}` shape. Rake task `data_migration:donations`.

- [ ] **Step 1: Write the failing migrator test**

Create `test/lib/services/books_migration/donation_migrator_test.rb`:

```ruby
require "test_helper"

class Services::BooksMigration::DonationMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::DonationMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_attrs(overrides = {})
    {
      "id" => 4001,
      "user_id" => users(:contractor_user).id,
      "amount" => 2500,
      "status" => 1,
      "stripe_payment_id" => "pi_legacy_4001",
      "created_at" => Time.utc(2024, 3, 14, 9, 30),
      "updated_at" => Time.utc(2024, 3, 14, 9, 30)
    }.merge(overrides)
  end

  test "maps the legacy columns and preserves the donation date" do
    result = run_migrator([legacy_attrs])
    assert result[:success], result[:error]

    donation = Donation.find_by(stripe_payment_intent_id: "pi_legacy_4001")
    assert_not_nil donation
    assert_equal 2500, donation.amount_cents
    assert_equal "succeeded", donation.status
    assert_equal "usd", donation.currency
    assert_equal "books", donation.domain
    assert_equal users(:contractor_user).id, donation.user_id
    assert_equal Time.utc(2024, 3, 14, 9, 30), donation.created_at
  end

  test "copies each legacy status integer to the same symbol" do
    run_migrator([
      legacy_attrs("id" => 4002, "status" => 0, "stripe_payment_id" => "pi_pending"),
      legacy_attrs("id" => 4003, "status" => 2, "stripe_payment_id" => "pi_failed_import"),
      legacy_attrs("id" => 4004, "status" => 3, "stripe_payment_id" => "pi_refunded")
    ])

    assert_equal "pending", Donation.find_by(stripe_payment_intent_id: "pi_pending").status
    assert_equal "failed", Donation.find_by(stripe_payment_intent_id: "pi_failed_import").status
    assert_equal "refunded", Donation.find_by(stripe_payment_intent_id: "pi_refunded").status
  end

  test "is idempotent across two runs" do
    run_migrator([legacy_attrs])
    assert_no_difference -> { Donation.count } do
      result = run_migrator([legacy_attrs])
      assert result[:success], result[:error]
    end
  end

  test "never rewrites a donation that already exists" do
    existing = donations(:regular_user_gift)
    run_migrator([legacy_attrs("stripe_payment_id" => existing.stripe_payment_intent_id, "amount" => 99)])

    assert_equal 2500, existing.reload.amount_cents
  end

  test "imports unattached when the donor no longer exists" do
    result = run_migrator([legacy_attrs("user_id" => 999_999_999)])
    assert result[:success], result[:error]

    assert_nil Donation.find_by(stripe_payment_intent_id: "pi_legacy_4001").user_id
  end

  test "aborts the run naming the legacy id when a payment intent id is missing" do
    result = run_migrator([legacy_attrs("stripe_payment_id" => nil)])

    assert_not result[:success]
    assert_includes result[:error], "4001"
  end
end
```

The last test matters: the `stripe_payment_intent_id` unique index is **partial** (`WHERE ... IS NOT NULL`), so a nil id is unconstrained and `find_or_initialize_by(stripe_payment_intent_id: nil)` would match an unrelated existing row. Failing loudly is the only safe response.

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/books_migration/donation_migrator_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::BooksMigration::DonationMigrator`.

- [ ] **Step 3: Write the migrator**

Create `app/lib/services/books_migration/donation_migrator.rb`:

```ruby
module Services
  module BooksMigration
    # Legacy `donations` -> the global donations table.
    #
    # The other half of the migration that can only come from the legacy
    # database. Donation history is append-only and was never touched by the
    # ordering bugs in the legacy webhook handler, so it is the one legacy
    # billing table that is trustworthy as written.
    #
    # Column renames: stripe_payment_id -> stripe_payment_intent_id, amount ->
    # amount_cents. Legacy `amount` is ALREADY in cents (legacy's
    # amount_in_dollars divides by 100); the rename exists so no call site has
    # to remember that.
    #
    # The legacy status enum is pending: 0, succeeded: 1, failed: 2, refunded: 3
    # -- identical to the new one -- so the raw integer copies directly. Legacy
    # has no currency column; the new column's "usd" default applies.
    #
    # Legacy timestamps ARE preserved: a donation's created_at is the date the
    # money arrived, which is the fact being imported.
    class DonationMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Donation
      end

      def model_key
        "Donation"
      end

      def upsert_row(attrs)
        payment_intent_id = attrs["stripe_payment_id"].presence
        # The unique index on stripe_payment_intent_id is PARTIAL (WHERE NOT
        # NULL), so a nil is unconstrained and find_or_initialize_by(nil) would
        # match some unrelated nil-id row and silently overwrite it. Legacy
        # validates this column's presence and all 21 production rows carry a
        # pi_ id, so a blank here means the data is not what we believe. The
        # base class turns this into an aborted run naming the legacy id.
        raise "legacy donation has no stripe_payment_id" if payment_intent_id.nil?

        donation = ::Donation.find_or_initialize_by(stripe_payment_intent_id: payment_intent_id)
        # Append-only history: an existing row is either a previous import or a
        # webhook-recorded donation, and both are better than anything this
        # migrator would write over them.
        return if donation.persisted?

        donation.assign_attributes(
          # A donor whose account no longer exists imports unattached rather
          # than failing the run -- the same books/users drift MembershipMigrator
          # skips for.
          user_id: (attrs["user_id"] if ::User.exists?(id: attrs["user_id"])),
          amount_cents: attrs["amount"],
          status: attrs["status"],
          domain: "books",
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        )
        donation.save!
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/books_migration/donation_migrator_test.rb
```

Expected: PASS.

- [ ] **Step 5: Add the rake task**

In `lib/tasks/data_migration.rake`, directly below the `memberships` task:

```ruby
  desc "Import legacy donation history into donations"
  task donations: :environment do
    legacy_count = LegacyBooks::Donation.count

    result = Services::BooksMigration::DonationMigrator.call
    pp result
    abort "donations migration failed: #{result[:error]}" unless result[:success]

    pp({
      legacy_donations: legacy_count,
      donations_now: Donation.count,
      unattached: Donation.where(user_id: nil).count
    })
  end
```

- [ ] **Step 6: Lint and run the migrator suite**

```bash
bundle exec standardrb --fix
bin/rails test test/lib/services/books_migration/
```

Expected: PASS. Again, **do not run the rake task**.

- [ ] **Step 7: Commit**

```bash
git add app/lib/services/books_migration/donation_migrator.rb lib/tasks/data_migration.rake test/lib/services/books_migration/donation_migrator_test.rb
git commit -m "feat(billing): import legacy donation history"
```

---

### Task 4: billing:verify_migration — the cross-database invariant report

The spec is explicit that the check is **not** a count match: a legacy-versus-new count always drifts against a live database. The invariants are membership, stated as lists of what is missing.

The logic lives in a service, not the rake task, so it is testable — the task only prints. The three legacy reads are isolated in their own private methods so tests can stub them; no test may touch a `LegacyBooks::` model for real.

**Files:**
- Create: `app/models/legacy_books/subscription.rb`
- Create: `app/lib/services/billing/verify_migration.rb`
- Modify: `lib/tasks/billing.rake`
- Test: `test/lib/services/billing/verify_migration_test.rb`

**Interfaces:**
- Consumes: `Membership`, `Donation`, and the `source_legacy` / `source_stripe` enum scopes.
- Produces: `Services::Billing::VerifyMigration.call` → `Result` with `data` holding exactly these keys: `:missing_subscriptions` (Array<String>), `:missing_grants` (Array<Integer>), `:missing_donations` (Array<String>), `:unattached` (Array<Hash> with keys `:id`, `:stripe_customer_id`, `:stripe_subscription_id`, `:status`), `:overlap_user_ids` (Array<Integer>). `success?` is false when any of the three `missing_*` lists is non-empty.

- [ ] **Step 1: Write the failing service test**

Create `test/lib/services/billing/verify_migration_test.rb`:

```ruby
require "test_helper"

# Compact class definition on purpose, matching every other service test in
# this codebase. `module Services; module Billing; class ...` would put
# Services::Billing into the lexical scope, where a bare `Membership` searches
# Services::Billing::Membership first -- the constant-shadowing shape that has
# produced confusing NameErrors here three times.
class Services::Billing::VerifyMigrationTest < ActiveSupport::TestCase
  # The three legacy reads are the only seams that touch the replica; every
  # test stubs all three, because no legacy test database exists.
  def verify(subscription_ids: [], paid_user_ids: [], donation_intent_ids: [])
    service = Services::Billing::VerifyMigration.new
    service.stubs(:legacy_subscription_ids).returns(subscription_ids)
    service.stubs(:legacy_paid_user_ids).returns(paid_user_ids)
    service.stubs(:legacy_donation_intent_ids).returns(donation_intent_ids)
    service.call
  end

  test "succeeds when every legacy record has a counterpart" do
    result = verify(
      subscription_ids: ["sub_regular_monthly", "sub_google_yearly"],
      paid_user_ids: [users(:password_user).id],
      donation_intent_ids: ["pi_regular_gift"]
    )

    assert result.success?
    assert_empty result.data[:missing_subscriptions]
    assert_empty result.data[:missing_grants]
    assert_empty result.data[:missing_donations]
  end

  test "reports a legacy subscription with no membership" do
    result = verify(subscription_ids: ["sub_regular_monthly", "sub_vanished"])

    assert_not result.success?
    assert_equal ["sub_vanished"], result.data[:missing_subscriptions]
  end

  test "reports a paid user with no legacy grant" do
    result = verify(paid_user_ids: [users(:password_user).id, users(:contractor_user).id])

    assert_not result.success?
    assert_equal [users(:contractor_user).id], result.data[:missing_grants]
  end

  test "reports a legacy donation with no counterpart" do
    result = verify(donation_intent_ids: ["pi_regular_gift", "pi_never_imported"])

    assert_not result.success?
    assert_equal ["pi_never_imported"], result.data[:missing_donations]
  end

  test "lists unattached memberships" do
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan", stripe_customer_id: "cus_orphan"
    )

    result = verify
    row = result.data[:unattached].find { |r| r[:id] == orphan.id }

    assert_not_nil row
    assert_equal "cus_orphan", row[:stripe_customer_id]
    assert_equal "active", row[:status]
  end

  test "reports users holding both a legacy grant and a stripe membership" do
    Membership.create!(user: users(:regular_user), source: :legacy, status: :active)

    result = verify(paid_user_ids: [users(:regular_user).id, users(:password_user).id])

    # regular_user has regular_user_monthly (stripe) plus the new legacy row;
    # password_user has only password_user_legacy, so it is not an overlap.
    assert_equal [users(:regular_user).id], result.data[:overlap_user_ids]
  end

  test "an unattached membership alone does not fail the run" do
    Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_two", stripe_customer_id: "cus_orphan_two"
    )

    assert verify.success?
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/services/billing/verify_migration_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::Billing::VerifyMigration`.

- [ ] **Step 3: Create the legacy subscription read model**

Create `app/models/legacy_books/subscription.rb`:

```ruby
module LegacyBooks
  # Read for verification only. The legacy subscriptions table is deliberately
  # NOT migrated -- it was written by the handler this subsystem replaces and is
  # the least trustworthy copy of the data. Stripe is the source of truth, and
  # billing:reconcile_all already rebuilt every membership from it. This model
  # exists so verify_migration can ask "is every subscription legacy knew about
  # accounted for?" without importing any of it.
  class Subscription < Record
    self.table_name = "subscriptions"
  end
end
```

- [ ] **Step 4: Write the service**

Create `app/lib/services/billing/verify_migration.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Reports the legacy -> new billing migration invariants.
    #
    # Deliberately NOT a count match. A legacy-versus-new count always drifts,
    # because the legacy database is live and still creating rows while this
    # runs. The invariant is membership: every legacy subscription id must exist
    # in memberships, every paid: true user must have a legacy grant, and every
    # legacy donation must exist. Each is reported as the LIST of what is
    # missing, which is actionable; a count is not.
    #
    # Unattached memberships are reported but never fail the run -- an
    # unmappable Stripe customer is an expected outcome the spec designs for,
    # and whether the set is the one deliberately expected is a human judgement.
    class VerifyMigration
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        paid_user_ids = legacy_paid_user_ids

        subscription_ids = legacy_subscription_ids
        missing_subscriptions = subscription_ids -
          ::Membership.where(stripe_subscription_id: subscription_ids).pluck(:stripe_subscription_id)

        missing_grants = paid_user_ids -
          ::Membership.source_legacy.where(user_id: paid_user_ids).pluck(:user_id)

        donation_intent_ids = legacy_donation_intent_ids
        missing_donations = donation_intent_ids -
          ::Donation.where(stripe_payment_intent_id: donation_intent_ids).pluck(:stripe_payment_intent_id)

        # The 6 early supporters who also pay. Not a problem -- legacy
        # `paid? || active_membership?` gives them both today -- but two rows
        # for one person reads as a bug unless it is named up front.
        overlap_user_ids = ::Membership.source_stripe
          .where(user_id: ::Membership.source_legacy.where(user_id: paid_user_ids).select(:user_id))
          .distinct.pluck(:user_id).sort

        unattached = ::Membership.where(user_id: nil).order(:stripe_customer_id).map do |membership|
          {
            id: membership.id,
            stripe_customer_id: membership.stripe_customer_id,
            stripe_subscription_id: membership.stripe_subscription_id,
            status: membership.status
          }
        end

        errors = []
        errors << "#{missing_subscriptions.size} legacy subscriptions have no membership" if missing_subscriptions.any?
        errors << "#{missing_grants.size} paid users have no legacy grant" if missing_grants.any?
        errors << "#{missing_donations.size} legacy donations were not imported" if missing_donations.any?

        Result.new(
          success?: errors.empty?,
          data: {
            missing_subscriptions: missing_subscriptions,
            missing_grants: missing_grants,
            missing_donations: missing_donations,
            unattached: unattached,
            overlap_user_ids: overlap_user_ids
          },
          errors: errors
        )
      end

      private

      # The three seams that touch the legacy replica. Isolated as their own
      # methods so tests can stub them: no legacy test database exists, and no
      # test may query a LegacyBooks:: model for real.
      def legacy_subscription_ids
        LegacyBooks::Subscription.where.not(stripe_subscription_id: nil).distinct.pluck(:stripe_subscription_id)
      end

      def legacy_paid_user_ids
        LegacyBooks::User.where(paid: true).pluck(:id)
      end

      def legacy_donation_intent_ids
        LegacyBooks::Donation.where.not(stripe_payment_id: nil).distinct.pluck(:stripe_payment_id)
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/lib/services/billing/verify_migration_test.rb
```

Expected: PASS.

- [ ] **Step 6: Add the rake task**

Append inside the existing `namespace :billing do` block in `lib/tasks/billing.rake`:

```ruby
  desc "Report the legacy -> new billing migration invariants"
  task verify_migration: :environment do
    result = Services::Billing::VerifyMigration.call
    data = result.data

    puts "Legacy subscriptions with no membership: #{data[:missing_subscriptions].size}"
    data[:missing_subscriptions].each { |id| puts "  #{id}" }

    puts "Paid users with no legacy grant: #{data[:missing_grants].size}"
    data[:missing_grants].each { |id| puts "  user #{id}" }

    puts "Legacy donations not imported: #{data[:missing_donations].size}"
    data[:missing_donations].each { |id| puts "  #{id}" }

    puts "Early supporters who also pay through Stripe: #{data[:overlap_user_ids].size}"
    puts "  #{data[:overlap_user_ids].join(", ")}" if data[:overlap_user_ids].any?

    # Informational, never a failure: an unmappable customer is an outcome the
    # design expects. Attach these by hand at /admin/memberships?attached=false.
    puts "Unattached memberships: #{data[:unattached].size}"
    data[:unattached].each do |row|
      puts "  ##{row[:id]} #{row[:stripe_customer_id]} #{row[:stripe_subscription_id]} #{row[:status]}"
    end

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end
    puts "All invariants hold."
  end
```

- [ ] **Step 7: Verify wiring, lint, run the billing suite**

```bash
bin/rails -T billing:verify_migration
bundle exec standardrb --fix
bin/rails test test/lib/services/billing/
```

Expected: the task is listed; tests PASS.

- [ ] **Step 8: Commit**

```bash
git add app/models/legacy_books/subscription.rb app/lib/services/billing/verify_migration.rb lib/tasks/billing.rake test/lib/services/billing/verify_migration_test.rb
git commit -m "feat(billing): add billing:verify_migration invariant report"
```

---

### Task 5: Admin routes, sidebar, and the membership list

The first half of spec increment 9. Read-only screens plus the routing and navigation the remaining admin tasks build on.

**Naming decision — flat `Admin::` controllers, not `Admin::Billing::`.** A top-level `Billing` module already exists (`app/sidekiq/billing/`), so inside `Admin::Billing::StripeEventsController` a reference to `Billing::ProcessStripeEventJob` would resolve to `Admin::Billing::ProcessStripeEventJob` and raise. That is the constant-shadowing trap that has bitten this codebase three times. Flat also matches `Admin::UsersController` and `Admin::PenaltiesController`, the other cross-domain admin controllers.

**Authorization decision.** `Admin::BaseController#authenticate_admin!` admits admins **and editors**. Billing is money, so every controller in this increment adds `before_action :require_admin_role!`, matching `Admin::UsersController`. The spec calls this "an admin-only Pundit policy"; this codebase's admin layer does not use Pundit at all — `app/policies/` serves the public-facing models — so `require_admin_role!` is the faithful translation, not a downgrade.

**Files:**
- Modify: `config/routes.rb` (the global `namespace :admin do` block, around line 763)
- Create: `app/controllers/admin/memberships_controller.rb`
- Create: `app/views/admin/memberships/index.html.erb`
- Create: `app/views/admin/memberships/show.html.erb`
- Modify: `app/views/admin/shared/_sidebar.html.erb`
- Test: `test/controllers/admin/memberships_controller_test.rb`

**Interfaces:**
- Produces: route helpers `admin_memberships_path`, `admin_membership_path(membership)`, `new_admin_membership_path`, `edit_admin_membership_path(membership)`, `revoke_admin_membership_path(membership)`, `attach_admin_membership_path(membership)`, `admin_donations_path`, `admin_stripe_events_path`, `admin_stripe_event_path(event)`, `reprocess_admin_stripe_event_path(event)`, `admin_billing_plans_path`, `edit_admin_billing_plan_path(plan)`. Tasks 6–8 consume these.

- [ ] **Step 1: Write the failing controller test**

Create `test/controllers/admin/memberships_controller_test.rb`:

```ruby
require "test_helper"

class Admin::MembershipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @membership = memberships(:regular_user_monthly)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_memberships_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_memberships_url
    assert_response :redirect
  end

  test "filters by source" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "comped")
    assert_response :success
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(status: "canceled")
    assert_response :success
  end

  test "filters to unattached rows" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(attached: "false")
    assert_response :success
  end

  test "ignores a source that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "'; drop table memberships; --")
    assert_response :success
  end

  test "survives an array-valued search param" do
    # ?q[]=foo arrives as an Array; Reviews::MyReviewsQuery and
    # Admin::ReviewsBaseController both hit this exact shape.
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url("q" => ["cus_regular"])
    assert_response :success
  end

  test "searches by stripe customer id" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(q: "cus_regular")
    assert_response :success
  end

  test "searches by user email" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(q: users(:regular_user).email)
    assert_response :success
  end

  test "an admin sees the detail page" do
    sign_in_as(@admin, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :success
  end

  test "an editor is denied the detail page" do
    sign_in_as(@editor, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :redirect
  end

  test "the index does not N+1 over users" do
    sign_in_as(@admin, stub_auth: true)
    # includes(:user, :granted_by) is load-bearing: the table renders both in a
    # loop. Replace PIN_ME with the real number in Step 8 -- do not guess it.
    assert_queries_count(PIN_ME) { get admin_memberships_url }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/controllers/admin/memberships_controller_test.rb
```

Expected: FAIL — `NameError: undefined local variable or method 'admin_memberships_url'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside the global `namespace :admin do` block (the one at roughly line 730, **not** any of the three domain-scoped ones), directly after the `resources :users ... end` block:

```ruby
    # Billing. Global by design -- one membership covers books, music and games,
    # so these belong outside every DomainConstraint, exactly like users.
    resources :memberships, only: [:index, :show, :new, :create, :edit, :update] do
      member do
        post :revoke
        post :attach
      end
    end
    resources :donations, only: [:index]
    # `reprocess`, not `retry`: `retry` is a Ruby keyword and `def retry` is a
    # syntax error.
    resources :stripe_events, only: [:index, :show] do
      member do
        post :reprocess
      end
    end
    resources :billing_plans, only: [:index, :edit, :update]
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/admin/memberships_controller.rb`:

```ruby
# Admin surface for memberships, including comping.
#
# Admin-only, not admin-or-editor: Admin::BaseController#authenticate_admin!
# admits editors, and billing is money. Same rule and same mechanism as
# Admin::UsersController.
#
# Flat under Admin::, deliberately not nested in an Admin::Billing:: namespace.
# A top-level Billing module already exists (app/sidekiq/billing/), so inside
# Admin::Billing::X a reference to Billing::ProcessStripeEventJob would resolve
# to Admin::Billing::ProcessStripeEventJob and raise. That constant-shadowing
# trap has bitten this codebase three times.
class Admin::MembershipsController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_membership, only: [:show, :edit, :update, :revoke, :attach]

  # Sliced rather than excluding an unwanted set, so a visitor-invented query
  # param is never echoed back into every link on the page. Mirrors
  # Admin::ReviewsBaseController::FILTER_KEYS. "page" is absent on purpose:
  # changing a filter should land on page 1.
  FILTER_KEYS = %w[source status attached q].freeze

  helper_method :filter_params

  def index
    scope = ::Membership.includes(:user, :granted_by)

    # Guarded by the enum's own key set: params[:source] is attacker-controlled,
    # and .key? is false for an Array or an unknown string, so an invalid value
    # is ignored rather than reaching the query.
    scope = scope.where(source: params[:source]) if ::Membership.sources.key?(params[:source])
    scope = scope.where(status: params[:status]) if ::Membership.statuses.key?(params[:status])
    scope = scope.where(user_id: nil) if params[:attached] == "false"

    # to_s first: ?q[]=foo arrives as an Array, and sanitize_sql_like needs a
    # String. Two other controllers on this branch hit the same shape.
    @search_query = params[:q].to_s.presence
    scope = apply_search(scope, @search_query) if @search_query

    @unattached_count = ::Membership.where(user_id: nil).count
    @pagy, @memberships = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  def show
  end

  private

  def apply_search(scope, term)
    pattern = "%#{::User.sanitize_sql_like(term)}%"
    scope.where(
      "memberships.stripe_customer_id ILIKE :p " \
      "OR memberships.stripe_subscription_id ILIKE :p " \
      "OR memberships.user_id IN (SELECT id FROM users WHERE email ILIKE :p OR display_name ILIKE :p)",
      p: pattern
    )
  end

  def set_membership
    @membership = ::Membership.find(params[:id])
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
```

- [ ] **Step 5: Write the index view**

Create `app/views/admin/memberships/index.html.erb`:

```erb
<% content_for :title, "Memberships" %>

<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold">Memberships</h1>
  <%= link_to "Comp a membership", new_admin_membership_path, class: "btn btn-primary btn-sm" %>
</div>

<% if @unattached_count > 0 %>
  <div role="status" class="alert mb-4">
    <span>
      <%= pluralize(@unattached_count, "membership") %> could not be matched to a user.
      <%= link_to "Review them", admin_memberships_path(attached: "false"), class: "link" %>
    </span>
  </div>
<% end %>

<%= form_with url: admin_memberships_path, method: :get, class: "flex flex-wrap gap-2 mb-4" do |form| %>
  <%= form.search_field :q, value: @search_query,
        placeholder: "Email, customer id or subscription id",
        class: "input w-80", "aria-label": "Search memberships" %>
  <%= form.select :source, options_for_select(Membership.sources.keys.map { |s| [s.titleize, s] }, params[:source]),
        {include_blank: "Any source"}, class: "select" %>
  <%= form.select :status, options_for_select(Membership.statuses.keys.map { |s| [s.titleize, s] }, params[:status]),
        {include_blank: "Any status"}, class: "select" %>
  <%= form.submit "Filter", class: "btn" %>
  <%= link_to "Clear", admin_memberships_path, class: "btn btn-ghost" %>
<% end %>

<div class="overflow-x-auto">
  <table class="table">
    <thead>
      <tr>
        <th>User</th><th>Source</th><th>Status</th><th>Plan</th>
        <th>Access through</th><th>Started</th>
      </tr>
    </thead>
    <tbody>
      <% if @memberships.any? %>
        <% @memberships.each do |membership| %>
          <tr>
            <td class="[overflow-wrap:anywhere]">
              <%= link_to membership.user&.email || "Unattached — #{membership.stripe_customer_id}",
                    admin_membership_path(membership), class: "link" %>
            </td>
            <td><%= membership.source.titleize %></td>
            <td><%= membership.status.titleize %><%= " (ends at period end)" if membership.cancel_at_period_end %></td>
            <td><%= membership.interval&.titleize || "—" %></td>
            <td><%= membership.current_period_end&.to_date&.iso8601 || "Never expires" %></td>
            <td><%= membership.created_at.to_date.iso8601 %></td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="6" class="text-center text-base-content/70 py-8">No memberships match these filters.</td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<% if @pagy.pages > 1 %>
  <div class="mt-4 flex justify-center">
    <%== @pagy.series_nav %>
  </div>
<% end %>
```

Status is rendered **in words** — `.titleize` on the enum value — never as a colour-only badge. This is a hard requirement from the spec and from the project's accessibility rules.

- [ ] **Step 6: Write the show view**

Create `app/views/admin/memberships/show.html.erb`:

```erb
<% content_for :title, "Membership" %>

<%= link_to "← Memberships", admin_memberships_path, class: "link" %>

<h1 class="text-2xl font-bold mt-2 mb-6">
  <%= @membership.user&.email || "Unattached membership" %>
</h1>

<div class="card bg-base-100 mb-6">
  <div class="card-body">
    <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div><dt class="text-sm text-base-content/70">Source</dt><dd><%= @membership.source.titleize %></dd></div>
      <div><dt class="text-sm text-base-content/70">Status</dt><dd><%= @membership.status.titleize %></dd></div>
      <div><dt class="text-sm text-base-content/70">Plan</dt><dd><%= @membership.interval&.titleize || "—" %></dd></div>
      <div>
        <dt class="text-sm text-base-content/70">Access through</dt>
        <dd><%= @membership.current_period_end&.to_fs(:long) || "Never expires" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Cancels at period end</dt>
        <dd><%= @membership.cancel_at_period_end ? "Yes" : "No" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Canceled at</dt>
        <dd><%= @membership.canceled_at&.to_fs(:long) || "—" %></dd>
      </div>
      <div class="[overflow-wrap:anywhere]">
        <dt class="text-sm text-base-content/70">Stripe customer</dt>
        <dd><%= @membership.stripe_customer_id || "—" %></dd>
      </div>
      <div class="[overflow-wrap:anywhere]">
        <dt class="text-sm text-base-content/70">Stripe subscription</dt>
        <dd><%= @membership.stripe_subscription_id || "—" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Last synced from Stripe</dt>
        <dd><%= @membership.stripe_synced_at&.to_fs(:long) || "Never" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Origin</dt>
        <dd><%= @membership.origin_domain || "Unknown" %></dd>
      </div>
      <div class="sm:col-span-2">
        <dt class="text-sm text-base-content/70">Note</dt>
        <dd class="[overflow-wrap:anywhere]"><%= @membership.note.presence || "—" %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Granted by</dt>
        <dd><%= @membership.granted_by&.email || "—" %></dd>
      </div>
    </dl>
  </div>
</div>
```

The write controls are added in Task 6 — this view is read-only for now.

- [ ] **Step 7: Add the sidebar section**

In `app/views/admin/shared/_sidebar.html.erb`, insert a new `<li>` between the closing `</li>` of the "Global" `<details>` block and the closing `</ul>`:

```erb
      <!-- Billing Section (admin only — billing is money, and editors do not get it) -->
      <% if current_user&.admin? %>
        <li>
          <details open>
            <summary class="font-semibold">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h18M7 15h1m4 0h1m-7 4h12a3 3 0 003-3V8a3 3 0 00-3-3H6a3 3 0 00-3 3v8a3 3 0 003 3z" />
              </svg>
              Billing
            </summary>
            <ul>
              <li><%= link_to "Memberships", admin_memberships_path, class: "flex items-center gap-2" %></li>
              <li><%= link_to "Donations", admin_donations_path, class: "flex items-center gap-2" %></li>
              <li><%= link_to "Stripe Events", admin_stripe_events_path, class: "flex items-center gap-2" %></li>
              <li><%= link_to "Billing Plans", admin_billing_plans_path, class: "flex items-center gap-2" %></li>
            </ul>
          </details>
        </li>
      <% end %>
```

The three links other than Memberships point at controllers that do not exist yet. **Do not run the E2E suite or load an admin page in a browser until Task 8 is done** — routing resolves fine, but following one of those links 500s. The Minitest suite is unaffected because it never renders the sidebar without a controller behind the link it follows.

- [ ] **Step 8: Run the tests, then pin the real query count**

```bash
bin/rails test test/controllers/admin/memberships_controller_test.rb
```

Expected: every test PASSES except the N+1 one, which errors on the undefined `PIN_ME`. Now pin it honestly, in three moves — a query-count assertion that was never watched to fail is worth nothing, and this codebase has shipped two sort tests that passed against deleted code:

1. Replace `PIN_ME` with a deliberately wrong number such as `1`. Run the test and read the **actual** count from the failure message.
2. Put that number in, and confirm the test passes.
3. Now **break the code**: temporarily delete `.includes(:user, :granted_by)` from `index`. Re-run — the test **must** fail with a higher count. If it still passes, the assertion is vacuous and the fixture set is too small to expose an N+1; in that case add a second membership fixture attached to a different user, or delete the test rather than leave a decorative one. Restore the `includes` afterwards.

- [ ] **Step 9: Run the daisyUI guard, the full controller suite, and the linter**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails test test/controllers/
bundle exec standardrb --fix
```

Expected: PASS. If the daisyUI guard fails, **remove the offending class** — never add an allowlist entry.

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/admin/memberships_controller.rb app/views/admin/memberships app/views/admin/shared/_sidebar.html.erb test/controllers/admin/memberships_controller_test.rb
git commit -m "feat(admin): add the membership list and detail screens"
```

---

### Task 6: Comp, edit, revoke and attach

The write half of the membership admin. Four rules the tests pin, because each one is a way this could go wrong quietly:

1. `granted_by_id` comes from `current_user`, **never** from params — otherwise an admin could forge who authorised a comp.
2. `source` and `stripe_subscription_id` are never permitted params. `source` is hardcoded to `:comped`; the Task 1 absence validation rejects a subscription id on a comp regardless.
3. Editing or revoking a **Stripe** membership is refused. The next reconcile would silently overwrite the change, so a write that appears to work but does not is worse than a refusal.
4. Attaching an unattached membership takes an explicit **user id**. Never an email match — guessing identity from an email is how one person gets handed another person's paid membership.

**Files:**
- Modify: `app/controllers/admin/memberships_controller.rb`
- Create: `app/views/admin/memberships/new.html.erb`
- Create: `app/views/admin/memberships/edit.html.erb`
- Modify: `app/views/admin/memberships/show.html.erb`
- Test: `test/controllers/admin/memberships_controller_test.rb`

**Interfaces:**
- Consumes: the routes and `set_membership` from Task 5; `Membership`'s `(user_id, source)` unique index and absence validation from Task 1.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/admin/memberships_controller_test.rb`:

```ruby
  test "an admin comps a user" do
    sign_in_as(@admin, stub_auth: true)
    assert_difference -> { Membership.source_comped.count }, 1 do
      post admin_memberships_url, params: {
        membership: {user_id: users(:contractor_user).id, note: "Wrote the importer"}
      }
    end

    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
    assert_equal "Wrote the importer", membership.note
    assert_equal @admin.id, membership.granted_by_id
    assert_redirected_to admin_membership_url(membership)
  end

  test "an editor may not comp" do
    sign_in_as(@editor, stub_auth: true)
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:contractor_user).id}}
    end
    assert_response :redirect
  end

  test "a signed-out visitor may not comp" do
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:contractor_user).id}}
    end
    assert_response :redirect
  end

  test "granted_by cannot be forged through params" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, granted_by_id: users(:regular_user).id}
    }
    assert_equal @admin.id, Membership.source_comped.find_by(user_id: users(:contractor_user).id).granted_by_id
  end

  test "a comp cannot smuggle in a source or a subscription id" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {
        user_id: users(:contractor_user).id,
        source: "stripe",
        stripe_subscription_id: "sub_smuggled"
      }
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_not_nil membership
    assert_nil membership.stripe_subscription_id
  end

  test "comping accepts an end date" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, current_period_end: "2027-01-01"}
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_equal Date.new(2027, 1, 1), membership.current_period_end.to_date
  end

  test "comping a user who already has a comp updates it rather than adding a second" do
    sign_in_as(@admin, stub_auth: true)
    # editor_user already holds editor_user_comped. find_or_initialize_by means
    # this is an update, which is the intended behaviour: comping someone twice
    # revises their comp. The (user_id, source) index makes it impossible for
    # this to become a duplicate even under a race.
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:editor_user).id, note: "Revised comp"}}
    end
    assert_equal "Revised comp", memberships(:editor_user_comped).reload.note
    assert_equal 1, Membership.source_comped.where(user_id: users(:editor_user).id).count
  end

  test "comping an unknown user id re-renders the form" do
    sign_in_as(@admin, stub_auth: true)
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: 999_999_999}}
    end
    # A body, not `head :unprocessable_entity`: Turbo replaces the whole page
    # with a non-2xx response, so a bodiless one blanks it. Four routes in this
    # app have been bitten by that.
    assert_response :unprocessable_entity
  end

  test "an admin edits a comped membership's note and end date" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {
      membership: {note: "Renewed for another year", current_period_end: "2027-06-30"}
    }
    comped.reload
    assert_equal "Renewed for another year", comped.note
    assert_equal Date.new(2027, 6, 30), comped.current_period_end.to_date
  end

  test "editing a stripe membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_membership_url(@membership), params: {membership: {note: "Should not stick"}}
    assert_nil @membership.reload.note
    assert_response :redirect
  end

  test "an admin revokes a comp" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    comped.reload
    assert_equal "canceled", comped.status
    assert_not_nil comped.canceled_at
    assert comped.current_period_end <= Time.current
  end

  test "revoking a stripe membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    post revoke_admin_membership_url(@membership)
    assert_equal "active", @membership.reload.status
    assert_response :redirect
  end

  test "an editor may not revoke" do
    sign_in_as(@editor, stub_auth: true)
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    assert_equal "active", comped.reload.status
  end

  test "an admin attaches an unattached membership to a user" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_attach", stripe_customer_id: "cus_orphan_attach"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:contractor_user).id}
    assert_equal users(:contractor_user).id, orphan.reload.user_id
    # The durable half of the fix: the next reconcile resolves this customer by
    # the user record rather than needing the link again.
    assert_equal "cus_orphan_attach", users(:contractor_user).reload.stripe_customer_id
  end

  test "attaching does not overwrite a customer id the user already has" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_two", stripe_customer_id: "cus_orphan_two"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:regular_user).id}
    assert_equal users(:regular_user).id, orphan.reload.user_id
    assert_equal "cus_regular", users(:regular_user).reload.stripe_customer_id
  end

  test "attaching an already-attached membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    post attach_admin_membership_url(@membership), params: {user_id: users(:contractor_user).id}
    assert_equal users(:regular_user).id, @membership.reload.user_id
    assert_response :redirect
  end

  test "attaching to an unknown user id is refused" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_three", stripe_customer_id: "cus_orphan_three"
    )

    post attach_admin_membership_url(orphan), params: {user_id: 999_999_999}
    assert_nil orphan.reload.user_id
    assert_response :redirect
  end

  test "an editor may not attach" do
    sign_in_as(@editor, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_four", stripe_customer_id: "cus_orphan_four"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:contractor_user).id}
    assert_nil orphan.reload.user_id
  end

  test "an admin sees the comp form" do
    sign_in_as(@admin, stub_auth: true)
    get new_admin_membership_url
    assert_response :success
  end

  test "an editor is denied the comp form" do
    sign_in_as(@editor, stub_auth: true)
    get new_admin_membership_url
    assert_response :redirect
  end

  test "an admin sees the edit form for a comp" do
    sign_in_as(@admin, stub_auth: true)
    get edit_admin_membership_url(memberships(:editor_user_comped))
    assert_response :success
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bin/rails test test/controllers/admin/memberships_controller_test.rb
```

Expected: FAIL — the actions do not exist, so requests raise `AbstractController::ActionNotFound` or return the wrong status.

- [ ] **Step 3: Add the actions**

In `app/controllers/admin/memberships_controller.rb`, add these public actions after `show`:

```ruby
  def new
    @membership = ::Membership.new
  end

  def create
    user = ::User.find_by(id: comp_params[:user_id])
    if user.nil?
      @membership = ::Membership.new(comp_params)
      flash.now[:alert] = "No user with that id."
      render :new, status: :unprocessable_entity
      return
    end

    membership = ::Membership.find_or_initialize_by(user_id: user.id, source: :comped)
    membership.assign_attributes(
      status: :active,
      current_period_end: comp_params[:current_period_end].presence,
      note: comp_params[:note].presence,
      # From the session, never from params. An admin must not be able to
      # record someone else as the person who authorised a comp.
      granted_by_id: current_user.id
    )

    if membership.save
      redirect_to admin_membership_path(membership), notice: "Membership comped."
    else
      @membership = membership
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    # Only reachable if two admins comp the same user at the same moment --
    # find_or_initialize_by handles the ordinary repeat. The (user_id, source)
    # index is what turns the race into this instead of a duplicate row.
    redirect_to admin_memberships_path, alert: "That user already has a comped membership."
  end

  def edit
    return if editable?
    redirect_to admin_membership_path(@membership), alert: stripe_owned_message
  end

  def update
    unless editable?
      redirect_to admin_membership_path(@membership), alert: stripe_owned_message
      return
    end

    attributes = edit_params.to_h.symbolize_keys
    # An empty date field means "never expires", not "leave it alone".
    attributes[:current_period_end] = attributes[:current_period_end].presence if attributes.key?(:current_period_end)

    if @membership.update(attributes)
      redirect_to admin_membership_path(@membership), notice: "Membership updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def revoke
    unless editable?
      redirect_to admin_membership_path(@membership), alert: "Cancel a Stripe subscription in Stripe, not here."
      return
    end

    # Status and a passed end date, not destroy: the note and granted_by are the
    # audit trail for why access was given, and deleting the row throws that
    # away. Membership.granting_access denies a non-Stripe row whose
    # current_period_end has passed, so this ends access immediately.
    @membership.update!(status: :canceled, canceled_at: Time.current, current_period_end: Time.current)
    redirect_to admin_membership_path(@membership), notice: "Membership revoked."
  end

  def attach
    if @membership.user_id.present?
      redirect_to admin_membership_path(@membership), alert: "Already attached to a user."
      return
    end

    # An explicit user id, never an email match. Inferring identity from an
    # email address is how one person is handed another person's paid
    # membership; an admin looking at both records makes the call instead.
    user = ::User.find_by(id: params[:user_id])
    if user.nil?
      redirect_to admin_membership_path(@membership), alert: "No user with that id."
      return
    end

    ::Membership.transaction do
      @membership.update!(user: user)
      # Makes the link durable: ReconcileCustomer resolves a user by
      # users.stripe_customer_id first, so writing it means the next reconcile
      # finds this customer without help. Only when blank -- users
      # .stripe_customer_id has a non-unique index, and overwriting an existing
      # value would silently repoint whichever customer was there before.
      if user.stripe_customer_id.blank? && @membership.stripe_customer_id.present?
        user.update!(stripe_customer_id: @membership.stripe_customer_id)
      end
    end

    redirect_to admin_membership_path(@membership), notice: "Attached to #{user.email}."
  end
```

And these private methods:

```ruby
  # A Stripe membership is owned by the reconciler: the nightly sweep rewrites
  # status, interval, period end and cancellation from Stripe, so an edit here
  # would appear to work and then vanish. Refusing is the honest answer.
  def editable?
    !@membership.source_stripe?
  end

  def stripe_owned_message
    "This membership is owned by Stripe. Change it in the Stripe dashboard — the nightly reconcile will pick it up."
  end

  def comp_params
    # source and stripe_subscription_id are absent on purpose. source is
    # hardcoded to :comped in create; a subscription id on a non-Stripe row is
    # rejected by Membership's absence validation regardless.
    params.require(:membership).permit(:user_id, :note, :current_period_end)
  end

  # No user_id: which person a membership belongs to is changed through
  # `attach`, which has its own guards, never by editing a form field.
  def edit_params
    params.require(:membership).permit(:note, :current_period_end)
  end
```

- [ ] **Step 4: Write the comp form**

Create `app/views/admin/memberships/new.html.erb`:

```erb
<% content_for :title, "Comp a membership" %>

<%= link_to "← Memberships", admin_memberships_path, class: "link" %>
<h1 class="text-2xl font-bold mt-2 mb-6">Comp a membership</h1>

<%= form_with model: @membership, url: admin_memberships_path, method: :post, class: "max-w-lg" do |form| %>
  <% if @membership.errors.any? %>
    <div role="alert" class="alert mb-4">
      <span><%= @membership.errors.full_messages.to_sentence %></span>
    </div>
  <% end %>

  <fieldset class="fieldset">
    <legend class="fieldset-legend">Who</legend>
    <label class="label" for="membership_user_id">User id</label>
    <%= form.number_field :user_id, class: "input", required: true %>
    <p class="text-sm text-base-content/70">
      Find the id on the <%= link_to "users page", admin_users_path, class: "link" %>.
    </p>
  </fieldset>

  <fieldset class="fieldset">
    <legend class="fieldset-legend">Terms</legend>
    <label class="label" for="membership_current_period_end">Access through</label>
    <%= form.date_field :current_period_end, class: "input" %>
    <p class="text-sm text-base-content/70">Leave blank for a membership that never expires.</p>

    <label class="label" for="membership_note">Why</label>
    <%= form.text_area :note, class: "textarea w-full", rows: 3 %>
  </fieldset>

  <div class="mt-6 flex gap-2">
    <%= form.submit "Comp membership", class: "btn btn-primary" %>
    <%= link_to "Cancel", admin_memberships_path, class: "btn btn-ghost" %>
  </div>
<% end %>
```

No `form-control`, `label-text`, `input-bordered` or `textarea-bordered` — all four were removed in daisyUI 5 and fail silently.

- [ ] **Step 5: Write the edit form**

Create `app/views/admin/memberships/edit.html.erb`:

```erb
<% content_for :title, "Edit membership" %>

<%= link_to "← Membership", admin_membership_path(@membership), class: "link" %>
<h1 class="text-2xl font-bold mt-2 mb-6">
  Edit <%= @membership.source.titleize %> membership
</h1>

<%= form_with model: @membership, url: admin_membership_path(@membership), method: :patch, class: "max-w-lg" do |form| %>
  <% if @membership.errors.any? %>
    <div role="alert" class="alert mb-4">
      <span><%= @membership.errors.full_messages.to_sentence %></span>
    </div>
  <% end %>

  <fieldset class="fieldset">
    <legend class="fieldset-legend">Terms</legend>
    <label class="label" for="membership_current_period_end">Access through</label>
    <%= form.date_field :current_period_end, value: @membership.current_period_end&.to_date, class: "input" %>
    <p class="text-sm text-base-content/70">Leave blank for a membership that never expires.</p>

    <label class="label" for="membership_note">Why</label>
    <%= form.text_area :note, class: "textarea w-full", rows: 3 %>
  </fieldset>

  <div class="mt-6 flex gap-2">
    <%= form.submit "Save", class: "btn btn-primary" %>
    <%= link_to "Cancel", admin_membership_path(@membership), class: "btn btn-ghost" %>
  </div>
<% end %>
```

- [ ] **Step 6: Add the write controls to the show view**

Append to `app/views/admin/memberships/show.html.erb`:

```erb
<% unless @membership.source_stripe? %>
  <div class="flex gap-2 mb-6">
    <%= link_to "Edit", edit_admin_membership_path(@membership), class: "btn btn-sm" %>
    <% unless @membership.canceled? %>
      <%= button_to "Revoke", revoke_admin_membership_path(@membership), method: :post,
            class: "btn btn-sm btn-error",
            form: {data: {turbo_confirm: "Revoke this membership? Access ends immediately."}} %>
    <% end %>
  </div>
<% end %>

<% if @membership.user_id.nil? %>
  <div class="card bg-base-100">
    <div class="card-body">
      <h2 class="card-title text-lg">Attach to a user</h2>
      <p class="text-sm text-base-content/70">
        This Stripe customer could not be matched automatically. Confirm the person's
        identity yourself and enter their user id — this is never guessed from an
        email address.
      </p>
      <%= form_with url: attach_admin_membership_path(@membership), method: :post, class: "flex gap-2 items-end mt-2" do |form| %>
        <div>
          <label class="label" for="user_id">User id</label>
          <%= form.number_field :user_id, id: "user_id", class: "input", required: true %>
        </div>
        <%= form.submit "Attach", class: "btn btn-primary" %>
      <% end %>
    </div>
  </div>
<% end %>
```

- [ ] **Step 7: Run the tests**

```bash
bin/rails test test/controllers/admin/memberships_controller_test.rb
```

Expected: PASS.

- [ ] **Step 8: Run the guards and the linter**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails test test/models/ test/controllers/
bundle exec standardrb --fix
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/admin/memberships_controller.rb app/views/admin/memberships test/controllers/admin/memberships_controller_test.rb
git commit -m "feat(admin): comp, edit, revoke and attach memberships"
```

---

### Task 7: The Stripe event inbox

Read the raw event log and re-run a failed one. This is the operator's window into "did that webhook land, and what happened to it?"

**The payload is the sensitive part.** A Stripe event carries customer email, name, address and card last four. `StripeEvent#mark_failed!` already refuses to write it to the log for exactly this reason. Rendering it on an admin-only page is a different decision from logging it, and an acceptable one — but it is the reason this controller is admin-only, and the reason the fixtures in this public repository carry only synthetic payloads.

**Files:**
- Create: `app/controllers/admin/stripe_events_controller.rb`
- Create: `app/views/admin/stripe_events/index.html.erb`
- Create: `app/views/admin/stripe_events/show.html.erb`
- Test: `test/controllers/admin/stripe_events_controller_test.rb`

**Interfaces:**
- Consumes: the routes from Task 5; `StripeEvent`'s `status` enum (`received`, `processed`, `failed`, `ignored`) and `::Billing::ProcessStripeEventJob.perform_async(id)`.

- [ ] **Step 1: Write the failing controller test**

Create `test/controllers/admin/stripe_events_controller_test.rb`:

```ruby
require "test_helper"

class Admin::StripeEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    host! Rails.application.config.domains[:music]
  end

  def failed_event
    StripeEvent.create!(
      stripe_event_id: "evt_admin_failed", event_type: "customer.subscription.updated",
      payload: {"data" => {"object" => {"object" => "subscription", "customer" => "cus_admin"}}},
      livemode: false, status: :failed, stripe_created_at: Time.current, error: "Boom"
    )
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_stripe_events_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_stripe_events_url
    assert_response :redirect
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url(status: "failed")
    assert_response :success
  end

  test "ignores a status that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url(status: "nonsense")
    assert_response :success
  end

  test "survives an array-valued search param" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url("q" => ["cus_admin"])
    assert_response :success
  end

  test "an admin sees the detail page" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_event_url(failed_event)
    assert_response :success
  end

  test "an editor is denied the detail page" do
    sign_in_as(@editor, stub_auth: true)
    get admin_stripe_event_url(failed_event)
    assert_response :redirect
  end

  test "an admin re-enqueues a failed event" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    ::Billing::ProcessStripeEventJob.expects(:perform_async).with(event.id).once

    post reprocess_admin_stripe_event_url(event)
    assert_redirected_to admin_stripe_event_url(event)
  end

  test "an editor may not re-enqueue" do
    sign_in_as(@editor, stub_auth: true)
    event = failed_event
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "a processed event cannot be re-enqueued" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    event.mark_processed!
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "an ignored event cannot be re-enqueued" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    event.mark_ignored!("livemode mismatch")
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "re-enqueueing is not reachable by GET" do
    # Asked of the routing table directly, not through an integration request:
    # with show_exceptions set to :rescuable in test, a routing failure comes
    # back as a 404 rather than an exception, which would make an assert_raises
    # around `get` pass or fail for the wrong reason.
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/admin/stripe_events/1/reprocess", method: :get)
    end
    assert_equal(
      {controller: "admin/stripe_events", action: "reprocess", id: "1"},
      Rails.application.routes.recognize_path("/admin/stripe_events/1/reprocess", method: :post)
    )
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/controllers/admin/stripe_events_controller_test.rb
```

Expected: FAIL — `Admin::StripeEventsController` does not exist.

- [ ] **Step 3: Write the controller**

Create `app/controllers/admin/stripe_events_controller.rb`:

```ruby
# The operator's window into the raw webhook inbox.
#
# Admin-only, and not only because billing is money: a Stripe event payload
# carries customer email, name, address and card last four. StripeEvent
# deliberately refuses to write a payload to the log for that reason, and this
# controller is the one place it is rendered at all.
class Admin::StripeEventsController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_event, only: [:show, :reprocess]

  FILTER_KEYS = %w[status q].freeze

  helper_method :filter_params

  def index
    scope = StripeEvent.all
    scope = scope.where(status: params[:status]) if StripeEvent.statuses.key?(params[:status])

    @search_query = params[:q].to_s.presence
    if @search_query
      pattern = "%#{::User.sanitize_sql_like(@search_query)}%"
      scope = scope.where(
        "stripe_event_id ILIKE :p OR event_type ILIKE :p OR stripe_customer_id ILIKE :p",
        p: pattern
      )
    end

    @failed_count = StripeEvent.failed.count
    @pagy, @events = pagy(scope.order(stripe_created_at: :desc, id: :desc), limit: 50)
  end

  def show
  end

  # `reprocess`, not `retry`: `retry` is a Ruby keyword and `def retry` will not
  # parse. POST only -- re-running an event enqueues work and calls the Stripe
  # API, which must never happen because something prefetched a link.
  def reprocess
    unless @event.received? || @event.failed?
      redirect_to admin_stripe_event_path(@event),
        alert: "Only a received or failed event can be re-run. This one is #{@event.status}."
      return
    end

    ::Billing::ProcessStripeEventJob.perform_async(@event.id)
    redirect_to admin_stripe_event_path(@event), notice: "Re-enqueued for processing."
  end

  private

  def set_event
    @event = StripeEvent.find(params[:id])
  end

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
```

- [ ] **Step 4: Write the index view**

Create `app/views/admin/stripe_events/index.html.erb`:

```erb
<% content_for :title, "Stripe Events" %>

<h1 class="text-2xl font-bold mb-6">Stripe Events</h1>

<% if @failed_count > 0 %>
  <div role="status" class="alert mb-4">
    <span>
      <%= pluralize(@failed_count, "event") %> failed to process.
      <%= link_to "Review them", admin_stripe_events_path(status: "failed"), class: "link" %>
    </span>
  </div>
<% end %>

<%= form_with url: admin_stripe_events_path, method: :get, class: "flex flex-wrap gap-2 mb-4" do |form| %>
  <%= form.search_field :q, value: @search_query, placeholder: "Event id, type or customer id",
        class: "input w-80", "aria-label": "Search Stripe events" %>
  <%= form.select :status, options_for_select(StripeEvent.statuses.keys.map { |s| [s.titleize, s] }, params[:status]),
        {include_blank: "Any status"}, class: "select" %>
  <%= form.submit "Filter", class: "btn" %>
  <%= link_to "Clear", admin_stripe_events_path, class: "btn btn-ghost" %>
<% end %>

<div class="overflow-x-auto">
  <table class="table">
    <thead>
      <tr><th>Received</th><th>Type</th><th>Customer</th><th>Status</th><th>Attempts</th><th>Live</th></tr>
    </thead>
    <tbody>
      <% if @events.any? %>
        <% @events.each do |event| %>
          <tr>
            <td>
              <%= link_to event.stripe_created_at.to_fs(:short), admin_stripe_event_path(event), class: "link" %>
            </td>
            <td class="[overflow-wrap:anywhere]"><%= event.event_type %></td>
            <td class="[overflow-wrap:anywhere]"><%= event.stripe_customer_id || "—" %></td>
            <td><%= event.status.titleize %></td>
            <td class="tabular-nums"><%= event.attempts %></td>
            <td><%= event.livemode ? "Live" : "Test" %></td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="6" class="text-center text-base-content/70 py-8">No events match these filters.</td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<% if @pagy.pages > 1 %>
  <div class="mt-4 flex justify-center">
    <%== @pagy.series_nav %>
  </div>
<% end %>
```

- [ ] **Step 5: Write the show view**

Create `app/views/admin/stripe_events/show.html.erb`:

```erb
<% content_for :title, "Stripe Event" %>

<%= link_to "← Stripe Events", admin_stripe_events_path, class: "link" %>
<h1 class="text-2xl font-bold mt-2 mb-6 [overflow-wrap:anywhere]"><%= @event.event_type %></h1>

<div class="card bg-base-100 mb-6">
  <div class="card-body">
    <dl class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div class="[overflow-wrap:anywhere]">
        <dt class="text-sm text-base-content/70">Event id</dt><dd><%= @event.stripe_event_id %></dd>
      </div>
      <div><dt class="text-sm text-base-content/70">Status</dt><dd><%= @event.status.titleize %></dd></div>
      <div class="[overflow-wrap:anywhere]">
        <dt class="text-sm text-base-content/70">Customer</dt><dd><%= @event.stripe_customer_id || "—" %></dd>
      </div>
      <div><dt class="text-sm text-base-content/70">Mode</dt><dd><%= @event.livemode ? "Live" : "Test" %></dd></div>
      <div><dt class="text-sm text-base-content/70">API version</dt><dd><%= @event.api_version || "—" %></dd></div>
      <div><dt class="text-sm text-base-content/70">Attempts</dt><dd class="tabular-nums"><%= @event.attempts %></dd></div>
      <div>
        <dt class="text-sm text-base-content/70">Received from Stripe</dt>
        <dd><%= @event.stripe_created_at.to_fs(:long) %></dd>
      </div>
      <div>
        <dt class="text-sm text-base-content/70">Processed</dt>
        <dd><%= @event.processed_at&.to_fs(:long) || "—" %></dd>
      </div>
      <% if @event.error.present? %>
        <div class="sm:col-span-2">
          <dt class="text-sm text-base-content/70">Error</dt>
          <dd class="[overflow-wrap:anywhere]"><%= @event.error %></dd>
        </div>
      <% end %>
    </dl>

    <% if @event.received? || @event.failed? %>
      <div class="card-actions mt-4">
        <%= button_to "Re-run this event", reprocess_admin_stripe_event_path(@event), method: :post,
              class: "btn btn-sm btn-primary",
              form: {data: {turbo_confirm: "Re-read this customer from Stripe and rewrite their membership rows?"}} %>
      </div>
    <% end %>
  </div>
</div>

<h2 class="text-lg font-semibold mb-2">Payload</h2>
<p class="text-sm text-base-content/70 mb-2">
  Contains customer contact details. Do not paste it anywhere outside this admin.
</p>
<div class="overflow-x-auto">
  <pre class="text-xs bg-base-200 p-4 rounded"><%= JSON.pretty_generate(@event.payload) %></pre>
</div>
```

`<%= %>`, not `<%== %>` — the payload is remote data and must be HTML-escaped.

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/controllers/admin/stripe_events_controller_test.rb
```

Expected: PASS.

- [ ] **Step 7: Run the guards and the linter**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb
bundle exec standardrb --fix
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/admin/stripe_events_controller.rb app/views/admin/stripe_events test/controllers/admin/stripe_events_controller_test.rb
git commit -m "feat(admin): add the Stripe event inbox with a re-run action"
```

---

### Task 8: Donations and billing plans

The last two admin sections, and the one that makes the sidebar's four links all resolve.

Donations are read-only: they are payment history and nothing about them should be editable from a web form.

Billing plans permit **only** `name`, `position` and `active`. `stripe_price_id`, `stripe_lookup_key`, `amount_cents`, `key`, `kind` and `interval` are owned by `rake stripe:sync_plans`, which resolves them from Stripe per environment. A hand-edited price id is a silent way to charge the wrong amount.

**Files:**
- Create: `app/controllers/admin/donations_controller.rb`
- Create: `app/controllers/admin/billing_plans_controller.rb`
- Create: `app/views/admin/donations/index.html.erb`
- Create: `app/views/admin/billing_plans/index.html.erb`
- Create: `app/views/admin/billing_plans/edit.html.erb`
- Test: `test/controllers/admin/donations_controller_test.rb`
- Test: `test/controllers/admin/billing_plans_controller_test.rb`

**Interfaces:**
- Consumes: the routes from Task 5.

- [ ] **Step 1: Write the failing donations test**

Create `test/controllers/admin/donations_controller_test.rb`:

```ruby
require "test_helper"

class Admin::DonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_donations_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_donations_url
    assert_response :redirect
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(status: "succeeded")
    assert_response :success
  end

  test "ignores a status that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(status: "nonsense")
    assert_response :success
  end

  test "survives an array-valued search param" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url("q" => ["pi_regular_gift"])
    assert_response :success
  end

  test "searches by payment intent id" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(q: "pi_regular_gift")
    assert_response :success
  end

  test "the index does not N+1 over donors" do
    sign_in_as(@admin, stub_auth: true)
    # Pin PIN_ME the same way as the memberships index: wrong number, read the
    # real one from the failure, then delete `.includes(:user)` and confirm the
    # test fails. An unwatched query-count assertion is decoration.
    assert_queries_count(PIN_ME) { get admin_donations_url }
  end
end
```

- [ ] **Step 2: Write the failing billing plans test**

Create `test/controllers/admin/billing_plans_controller_test.rb`:

```ruby
require "test_helper"

class Admin::BillingPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @plan = billing_plans(:monthly)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_billing_plans_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_billing_plans_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_billing_plans_url
    assert_response :redirect
  end

  test "an admin edits the display fields" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {name: "Monthly Supporter", position: 5, active: false}
    }
    @plan.reload
    assert_equal "Monthly Supporter", @plan.name
    assert_equal 5, @plan.position
    assert_equal false, @plan.active
    assert_redirected_to admin_billing_plans_url
  end

  test "the stripe price id cannot be changed through the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {name: "Still fine", stripe_price_id: "price_attacker_owned"}
    }
    assert_equal "price_test_monthly", @plan.reload.stripe_price_id
  end

  test "the lookup key and amount cannot be changed through the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {
      billing_plan: {stripe_lookup_key: "attacker_key", amount_cents: 1, key: "hijacked"}
    }
    @plan.reload
    assert_equal "membership_monthly", @plan.stripe_lookup_key
    assert_equal 500, @plan.amount_cents
    assert_equal "monthly", @plan.key
  end

  test "an editor may not edit a plan" do
    sign_in_as(@editor, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {billing_plan: {name: "Nope"}}
    assert_equal "Monthly Membership", @plan.reload.name
  end

  test "an invalid name re-renders the form" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_billing_plan_url(@plan), params: {billing_plan: {name: ""}}
    assert_response :unprocessable_entity
    assert_equal "Monthly Membership", @plan.reload.name
  end
end
```

- [ ] **Step 3: Run both tests to verify they fail**

```bash
bin/rails test test/controllers/admin/donations_controller_test.rb test/controllers/admin/billing_plans_controller_test.rb
```

Expected: FAIL — neither controller exists.

- [ ] **Step 4: Write the donations controller**

Create `app/controllers/admin/donations_controller.rb`:

```ruby
# Read-only by design. Donations are payment history: a webhook records them,
# or the legacy import does. Nothing about a completed payment should be
# editable from a web form.
class Admin::DonationsController < Admin::BaseController
  before_action :require_admin_role!

  FILTER_KEYS = %w[status q].freeze

  helper_method :filter_params

  def index
    scope = Donation.includes(:user)
    scope = scope.where(status: params[:status]) if Donation.statuses.key?(params[:status])

    @search_query = params[:q].to_s.presence
    if @search_query
      pattern = "%#{::User.sanitize_sql_like(@search_query)}%"
      scope = scope.where(
        "donations.stripe_payment_intent_id ILIKE :p OR donations.email ILIKE :p " \
        "OR donations.user_id IN (SELECT id FROM users WHERE email ILIKE :p)",
        p: pattern
      )
    end

    # Over the whole table, not the filtered page: "how much has been given"
    # is the question this answers, and a per-page subtotal answers nothing.
    @succeeded_total_cents = Donation.successful.sum(:amount_cents)
    @pagy, @donations = pagy(scope.order(created_at: :desc, id: :desc), limit: 50)
  end

  private

  def filter_params(overrides = {})
    request.query_parameters.slice(*FILTER_KEYS).merge(overrides.stringify_keys).compact
  end
end
```

- [ ] **Step 5: Write the billing plans controller**

Create `app/controllers/admin/billing_plans_controller.rb`:

```ruby
# Display-field editing only.
#
# stripe_price_id, stripe_lookup_key, amount_cents, key, kind and interval are
# owned by `rake stripe:sync_plans`, which resolves them from the current
# environment's Stripe account. A hand-edited price id is a silent way to charge
# the wrong amount, or to charge through someone else's price -- so the form
# shows those fields and permits none of them.
class Admin::BillingPlansController < Admin::BaseController
  before_action :require_admin_role!
  before_action :set_plan, only: [:edit, :update]

  def index
    @plans = BillingPlan.order(:position, :id)
  end

  def edit
  end

  def update
    if @plan.update(plan_params)
      redirect_to admin_billing_plans_path, notice: "Plan updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_plan
    @plan = BillingPlan.find(params[:id])
  end

  def plan_params
    params.require(:billing_plan).permit(:name, :position, :active)
  end
end
```

- [ ] **Step 6: Write the donations index view**

Create `app/views/admin/donations/index.html.erb`:

```erb
<% content_for :title, "Donations" %>

<div class="flex items-center justify-between mb-6">
  <h1 class="text-2xl font-bold">Donations</h1>
  <p class="text-sm text-base-content/70">
    Total received: <span class="font-semibold tabular-nums"><%= number_to_currency(@succeeded_total_cents / 100.0) %></span>
  </p>
</div>

<%= form_with url: admin_donations_path, method: :get, class: "flex flex-wrap gap-2 mb-4" do |form| %>
  <%= form.search_field :q, value: @search_query, placeholder: "Email or payment intent id",
        class: "input w-80", "aria-label": "Search donations" %>
  <%= form.select :status, options_for_select(Donation.statuses.keys.map { |s| [s.titleize, s] }, params[:status]),
        {include_blank: "Any status"}, class: "select" %>
  <%= form.submit "Filter", class: "btn" %>
  <%= link_to "Clear", admin_donations_path, class: "btn btn-ghost" %>
<% end %>

<div class="overflow-x-auto">
  <table class="table">
    <thead>
      <tr><th>Date</th><th>Donor</th><th>Amount</th><th>Status</th><th>Site</th><th>Payment intent</th></tr>
    </thead>
    <tbody>
      <% if @donations.any? %>
        <% @donations.each do |donation| %>
          <tr>
            <td><%= donation.created_at.to_date.iso8601 %></td>
            <td class="[overflow-wrap:anywhere]">
              <%= donation.user&.email || donation.email.presence || "Anonymous" %>
            </td>
            <td class="tabular-nums"><%= number_to_currency(donation.amount_in_dollars) %></td>
            <td><%= donation.status.titleize %></td>
            <td><%= donation.domain || "—" %></td>
            <td class="[overflow-wrap:anywhere] text-xs"><%= donation.stripe_payment_intent_id || "—" %></td>
          </tr>
        <% end %>
      <% else %>
        <tr>
          <td colspan="6" class="text-center text-base-content/70 py-8">No donations match these filters.</td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

<% if @pagy.pages > 1 %>
  <div class="mt-4 flex justify-center">
    <%== @pagy.series_nav %>
  </div>
<% end %>
```

- [ ] **Step 7: Write the billing plans views**

Create `app/views/admin/billing_plans/index.html.erb`:

```erb
<% content_for :title, "Billing Plans" %>

<h1 class="text-2xl font-bold mb-2">Billing Plans</h1>
<p class="text-sm text-base-content/70 mb-6">
  Price ids and amounts come from Stripe. Run <code>rake stripe:sync_plans</code> to refresh them —
  they are not editable here.
</p>

<div class="overflow-x-auto">
  <table class="table">
    <thead>
      <tr><th>Name</th><th>Key</th><th>Kind</th><th>Interval</th><th>Amount</th><th>Stripe price</th><th>Lookup key</th><th>Active</th><th>Position</th><th></th></tr>
    </thead>
    <tbody>
      <% @plans.each do |plan| %>
        <tr>
          <td><%= plan.name %></td>
          <td><%= plan.key %></td>
          <td><%= plan.kind.titleize %></td>
          <td><%= plan.interval&.titleize || "—" %></td>
          <td class="tabular-nums"><%= plan.amount_in_dollars ? number_to_currency(plan.amount_in_dollars) : "Any amount" %></td>
          <td class="[overflow-wrap:anywhere] text-xs"><%= plan.stripe_price_id %></td>
          <td class="[overflow-wrap:anywhere] text-xs"><%= plan.stripe_lookup_key || "—" %></td>
          <td><%= plan.active? ? "Active" : "Retired" %></td>
          <td class="tabular-nums"><%= plan.position %></td>
          <td><%= link_to "Edit", edit_admin_billing_plan_path(plan), class: "btn btn-sm" %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>
```

Create `app/views/admin/billing_plans/edit.html.erb`:

```erb
<% content_for :title, "Edit plan" %>

<%= link_to "← Billing Plans", admin_billing_plans_path, class: "link" %>
<h1 class="text-2xl font-bold mt-2 mb-6">Edit <%= @plan.key %></h1>

<%= form_with model: @plan, url: admin_billing_plan_path(@plan), method: :patch, class: "max-w-lg" do |form| %>
  <% if @plan.errors.any? %>
    <div role="alert" class="alert mb-4">
      <span><%= @plan.errors.full_messages.to_sentence %></span>
    </div>
  <% end %>

  <fieldset class="fieldset">
    <legend class="fieldset-legend">Display</legend>
    <label class="label" for="billing_plan_name">Name shown to visitors</label>
    <%= form.text_field :name, class: "input w-full", required: true %>

    <label class="label" for="billing_plan_position">Sort position</label>
    <%= form.number_field :position, class: "input" %>

    <label class="label cursor-pointer justify-start gap-2">
      <%= form.check_box :active, class: "checkbox" %>
      <span>Offer this plan</span>
    </label>
  </fieldset>

  <div class="mt-6 flex gap-2">
    <%= form.submit "Save", class: "btn btn-primary" %>
    <%= link_to "Cancel", admin_billing_plans_path, class: "btn btn-ghost" %>
  </div>
<% end %>

<p class="text-sm text-base-content/70 mt-6">
  Stripe price <code class="[overflow-wrap:anywhere]"><%= @plan.stripe_price_id %></code>
  and the amount are set by <code>rake stripe:sync_plans</code>.
</p>
```

- [ ] **Step 8: Run the tests**

```bash
bin/rails test test/controllers/admin/donations_controller_test.rb test/controllers/admin/billing_plans_controller_test.rb
```

Expected: PASS.

- [ ] **Step 9: Run the whole suite and the linter**

```bash
bin/rails test
bundle exec standardrb --fix
```

Expected: PASS across the board. Every sidebar link now resolves.

- [ ] **Step 10: Commit**

```bash
git add app/controllers/admin/donations_controller.rb app/controllers/admin/billing_plans_controller.rb app/views/admin/donations app/views/admin/billing_plans test/controllers/admin/donations_controller_test.rb test/controllers/admin/billing_plans_controller_test.rb
git commit -m "feat(admin): add the donation ledger and billing plan screens"
```

---

### Task 9: End-to-end coverage and documentation

Every new user-facing page needs a Playwright spec. These are admin pages, and the books admin already carries specs of exactly this shape (`e2e/tests/books/admin/reviews.spec.ts`, `sidebar-nav.spec.ts`), so this follows that precedent rather than inventing a placement.

The spec covers the four screens plus the sidebar section. It deliberately does **not** comp a membership: the E2E database is the development database, a comp is a real grant against real user rows, and `editor_user`-style fixtures do not exist there. Write actions are covered by the controller tests.

**Files:**
- Create: `e2e/tests/books/admin/billing.spec.ts`
- Create: `docs/features/membership-billing.md` (project root `docs/`, **not** `web-app/docs/`)

**Interfaces:**
- Consumes: every route from Tasks 5–8.

- [ ] **Step 1: Write the E2E spec**

Create `web-app/e2e/tests/books/admin/billing.spec.ts`:

```typescript
import { test, expect } from "@playwright/test";

test.describe("Admin — billing", () => {
  const sidebar = (page: import("@playwright/test").Page) => page.getByTestId("admin-sidebar");

  test("the Billing section links to all four screens", async ({ page }) => {
    await page.goto("/admin/memberships");

    await sidebar(page).getByRole("link", { name: "Donations", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/donations/);
    await expect(page.getByRole("heading", { name: "Donations", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Stripe Events", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/stripe_events/);
    await expect(page.getByRole("heading", { name: "Stripe Events", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Billing Plans", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/billing_plans/);
    await expect(page.getByRole("heading", { name: "Billing Plans", level: 1 })).toBeVisible();

    await sidebar(page).getByRole("link", { name: "Memberships", exact: true }).click();
    await expect(page).toHaveURL(/\/admin\/memberships/);
    await expect(page.getByRole("heading", { name: "Memberships", level: 1 })).toBeVisible();
  });

  test("the membership filters round-trip through the URL", async ({ page }) => {
    await page.goto("/admin/memberships");

    await page.getByLabel("Search memberships").fill("cus_");
    await page.getByRole("button", { name: "Filter" }).click();

    await expect(page).toHaveURL(/q=cus_/);
    // The page must render whether or not the dev database has a match --
    // an empty result is a legitimate outcome, not a failure.
    await expect(page.getByRole("heading", { name: "Memberships", level: 1 })).toBeVisible();

    await page.getByRole("link", { name: "Clear" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships$/);
  });

  test("the comp form is reachable and cancels back to the list", async ({ page }) => {
    await page.goto("/admin/memberships");

    await page.getByRole("link", { name: "Comp a membership" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships\/new/);
    await expect(page.getByLabel("User id")).toBeVisible();

    await page.getByRole("link", { name: "Cancel" }).click();
    await expect(page).toHaveURL(/\/admin\/memberships$/);
  });

  test("the Stripe event status filter round-trips", async ({ page }) => {
    await page.goto("/admin/stripe_events");

    await page.getByRole("combobox").selectOption("failed");
    await page.getByRole("button", { name: "Filter" }).click();

    await expect(page).toHaveURL(/status=failed/);
    await expect(page.getByRole("heading", { name: "Stripe Events", level: 1 })).toBeVisible();
  });
});
```

- [ ] **Step 2: Run the E2E spec**

The dev server must be running. Per the project's environment notes, `bin/dev` self-terminates in a non-interactive shell — use `yarn build:all` plus `bin/rails server` instead, and check what is already on port 3000 before starting another.

```bash
yarn test:e2e e2e/tests/books/admin/billing.spec.ts
```

Expected: PASS. If every admin spec times out on the public homepage instead, the E2E admin user has lost its role — fix with `bin/rails e2e:admin`.

- [ ] **Step 3: Write the subsystem documentation**

Create `docs/features/membership-billing.md` at the **project root**. Cover, in this order:

1. **What it is** — one membership across books, music and games, sold through Stripe; the four tables (`memberships`, `stripe_events`, `billing_plans`, `donations`).
2. **The core idea** — webhooks are signals, never data. The endpoint verifies, inserts, returns 200; a job extracts only the customer id; `ReconcileCustomer` re-reads Stripe under a per-customer advisory lock. Delivery order cannot matter because no payload is ever written. **State plainly that the permutation test in `test/controllers/webhooks/stripe_controller_test.rb` guards this and must never be "optimised away".**
3. **The three membership sources** — `stripe` (owned by the reconciler; never edit one by hand), `comped` (an admin grant), `legacy` (imported early supporters, never expire). Note that a user may legitimately hold both a `stripe` and a `legacy` row.
4. **Rake tasks** — the table from the spec, with what each does and when to run it, marking `stripe:bootstrap` as sandbox-only.
5. **Runbook: importing legacy history** — the exact production sequence in Task 10, Step 2.
6. **Runbook: an unattached membership** — what it means, and the `/admin/memberships?attached=false` → confirm identity → attach-by-user-id flow, including why it is never matched by email.
7. **Runbook: a failed Stripe event** — `/admin/stripe_events?status=failed`, read the error, re-run; or `rake billing:replay_failed` in bulk.
8. **Known limits**, lifted from the spec's "Carried forward" section and still true: `origin_domain` is never written by reconcile; `ReconcileAllCustomers` reports `success?: true` even when every customer failed; both Stripe calls happen inside the advisory-lock transaction; `users.stripe_customer_id` has a non-unique index.

- [ ] **Step 4: Verify the docs link resolves and commit**

```bash
ls docs/features/membership-billing.md
```

```bash
git add web-app/e2e/tests/books/admin/billing.spec.ts docs/features/membership-billing.md
git commit -m "test(admin): add billing E2E coverage and subsystem docs"
```

---

### Task 10: Deploy-pipeline review

The billing core shipped four production-affecting defects that the code review chain missed — a build failure, an outage, an auth bypass, and log noise — because the reviews only ever examined code. This task and Task 11 are the correction. **Neither is optional and neither is a rubber stamp.**

Run this as a fresh review over the whole branch diff (`git diff main...HEAD`). Report findings; do not fix them in this task.

**Files:** none created. Findings are reported, then fixed in a follow-up commit if any are confirmed.

- [ ] **Step 1: Answer every question below against the branch diff**

**Boot and build.**
1. Does anything on this branch run at class-load or initializer time? `assets:precompile` runs in the Dockerfile build stage with `SECRET_KEY_BASE_DUMMY=1` and **no application ENV** — no `STRIPE_SECRET_KEY`, no `POSTGRES_PASSWORD`, no legacy database credentials. Anything eager-loaded that reads ENV or opens a connection breaks the image build, which is what happened in the billing core.
2. `LegacyBooks::Record` calls `connects_to` unless `Rails.env.test?`. The two new models under it — `LegacyBooks::Donation` and `LegacyBooks::Subscription` — are eager-loaded in production. Does merely *defining* them attempt a connection, or is the connection lazy until first query? If eager loading them could touch the replica at boot, a legacy-database outage becomes a web outage.
3. Is any new constant referenced from an initializer, a `config.to_prepare` block, or `config/schedule.yml`?

**Migration and deploy ordering.**
4. `bin/docker-entrypoint` runs `db:prepare` only when the command contains `rails server`. The `web` container matches; the **`worker` container runs `bundle exec sidekiq` and does not**. `docker compose up -d` starts both together. Is there any code on this branch that a Sidekiq job could execute against the un-migrated schema during that window? Specifically: does `Billing::ProcessStripeEventJob` → `ReconcileCustomer` → `Membership#save!` behave correctly when `index_memberships_one_grant_per_user_per_source` does not exist yet?
5. Conversely — once the index **does** exist, can any existing production data violate it? Production holds 127 reconciled memberships. All should be `source: :stripe` (unconstrained by this index), but confirm the reasoning: if any `source: :comped` or `:legacy` row already exists with a duplicate `(user_id, source)`, `db:prepare` fails and the **web container never starts**. That is a full outage. State what evidence supports the claim that no such row exists, and whether the migration should defend against it.
6. Does the new absence validation reject any row the reconciler currently writes? A `source: :stripe` row is exempt, but check `ReconcileCustomer#upsert`'s early-return path for a pre-existing non-Stripe row.

**Rake task safety.**
7. Both importers run by hand against production with a live legacy database on the other end. Is each safe to run twice? To interrupt halfway and resume? What is the blast radius if the legacy database returns unexpected data mid-run?
8. `Migrator#call` has no wrapping transaction — a mid-run failure leaves earlier rows committed. Is that the right behaviour here, and does the rake task's output make a partial run obvious?
9. Does `billing:verify_migration` exit non-zero on a genuine gap, and is anything it reports a *false* alarm that would train the operator to ignore it?

**Observability.**
10. Does anything new log a Stripe payload, a customer email, an address, or a card fragment? The billing core shipped a log-noise defect; the standard here is that a billing log must be readable.

- [ ] **Step 2: Report findings**

For each finding: the file and line, what breaks, the concrete sequence that triggers it, and severity. If nothing is found, say so explicitly and name which of the ten questions were checked against actual code rather than assumed.

- [ ] **Step 3: Fix confirmed findings and commit**

```bash
bin/rails test
bundle exec standardrb --fix
git add -A
git commit -m "fix(billing): close deploy-pipeline review findings"
```

If there are no findings, skip this step — do not create an empty commit.

---

### Task 11: Public-repo threat-model review

**This repository is public.** Everything on this branch — every route, every param filter, every auth check, every rake task — is readable by anyone deciding what to probe. The billing core shipped an auth bypass that was only a bypass *because* the repo is public: a fallback webhook secret would have been a literal an attacker could read and sign with.

This branch adds ten admin routes, four of which write, one of which grants free access to a paid product, and one of which renders customer PII. Review it as an attacker who has read every line.

**Files:** none created. Findings are reported, then fixed.

- [ ] **Step 1: Enumerate the new attack surface**

```bash
bin/rails routes | grep -E "memberships|donations|stripe_events|billing_plans"
```

For **each** route, write down: the HTTP verb, who may reach it, and the exact test that proves an editor and a signed-out visitor cannot. A route with no such test is a finding on its own.

- [ ] **Step 2: Answer every question below**

**Authorization.**
1. Every new controller must carry `before_action :require_admin_role!`. `Admin::BaseController#authenticate_admin!` admits **editors**, so a controller that inherits without adding the stricter filter is open to every editor. Confirm per controller, not per file-you-remember.
2. These routes live in the global `namespace :admin` block, outside every `DomainConstraint` — so they are reachable on **all four hostnames**. Is that intended, and does the auth check depend in any way on which domain the request arrived on?
3. Is any new action reachable by `GET` that mutates state or enqueues work? A `GET` is followed by prefetchers, crawlers and link previewers.

**Privilege and forgery.**
4. Comping grants a paid product for free. Trace `granted_by_id` from HTTP request to database column and prove it cannot come from params. Same for `source`.
5. Can any strong-params list be widened by a nested or array-shaped param? Try `membership[user_id][]`, `billing_plan[stripe_price_id]`, and a nested hash where a scalar is expected.
6. `attach` writes `users.stripe_customer_id`. Can an admin use it to point a user at a customer id that belongs to someone else, and what would the next reconcile then do? Is the "only when blank" guard sufficient, or does it just narrow the window?
7. Can the `attach` action be used to move a membership *between* users by attaching twice? Verify the `user_id.present?` guard actually closes that.

**Data exposure.**
8. `/admin/stripe_events/:id` renders a full event payload: customer email, name, address, card last four. Confirm it is HTML-escaped (`<%= %>`, never `<%== %>`), that the page is `no-store` (`Admin::BaseController` includes `prevent_caching` — verify it applies), and that no payload reaches a log, a flash message, or an error page.
9. Search across the branch for anything that must never be committed: a real `sk_`, `whsec_`, `price_` from the live account, `cus_`, `sub_`, `pi_`, a customer email, or a captured payload.

```bash
git diff main...HEAD | grep -nE "sk_live|sk_test|whsec_|price_1|cus_[A-Za-z0-9]{8,}|sub_1|pi_[A-Za-z0-9]{10,}"
```

Every hit must be an obviously synthetic test value. The **production** price ids named in the spec (`price_1Qvp…`) are already public in that document — do not treat their absence here as a finding, but do not add more.

**Injection and denial of service.**
10. Every search builds an `ILIKE` pattern. Confirm each passes the term through `sanitize_sql_like` **and** binds it as a parameter, and that `params[:q]` is `to_s`'d before use — `?q[]=x` arrives as an Array and has broken three controllers in this codebase already.
11. Enum filters use `Membership.sources.key?(params[:source])`. Confirm `.key?` is false for an Array, a Hash and an unknown String, so nothing attacker-shaped reaches the query.
12. The membership search uses a correlated `user_id IN (SELECT ...)` subquery against `users`. On a table with ~150,000 rows, what does a single-character search cost, and is the admin page a plausible accidental self-DoS?

**The reconciler's guarantees.**
13. The spec claims a webhook can never touch a comped membership. With the Task 1 absence validation in place, is that now structurally true, or does a path still exist — via `attach`, via `update`, via the importer — that could put a `stripe_subscription_id` on a non-Stripe row?

- [ ] **Step 3: Report findings**

For each: the file and line, the concrete request an attacker sends, what they gain, and severity. If nothing is found, say so explicitly and name which of the thirteen questions were checked against actual code rather than assumed.

- [ ] **Step 4: Fix confirmed findings and commit**

```bash
bin/rails test
bundle exec standardrb --fix
git add -A
git commit -m "fix(billing): close public-repo threat-model review findings"
```

If there are no findings, skip this step.

---

### Task 12: Final verification and spec update

- [ ] **Step 1: Run the full gate**

```bash
bin/rails db:test:prepare
bin/rails test
bundle exec standardrb
```

Expected: PASS, zero offenses. This is what CI runs and what blocks the merge.

- [ ] **Step 2: Run the E2E suite**

```bash
yarn test:e2e
```

Expected: PASS. CI does not run this — it is a local gate only.

- [ ] **Step 3: Update the spec's status and carried-forward section**

In `docs/specs/membership-and-stripe-billing.md`:

- Mark increments 4 and 9 as done in the Increments table, noting that increment 4's Stripe rebuild was completed separately by `billing:reconcile_all` in production.
- Tick the acceptance criteria this plan satisfies: "Every legacy `stripe_subscription_id` exists in `memberships` after migration" and "Every legacy `paid: true` user has a `source: :legacy` membership" — noting both are verified by `billing:verify_migration` rather than asserted in a test, because they are cross-database facts about live data.
- **Remove** the two carried-forward items this plan closed: the `Membership` validation-shape item and the "make structurally unreachable true rather than aspirational" item. Leave the other six — they belong to later increments.
- Add a new carried-forward entry for anything Tasks 10 and 11 surfaced that was deliberately not fixed here.
- Record the decision that all 28 early supporters are imported including the 6 who also pay, and that this is why some users hold two membership rows.

- [ ] **Step 4: Commit**

```bash
git add docs/specs/membership-and-stripe-billing.md
git commit -m "docs: mark increments 4 and 9 complete and close two carried-forward items"
```

- [ ] **Step 5: Report the production runbook to the owner**

Schema migrates itself: `bin/docker-entrypoint` runs `db:prepare` when the web container starts, so `index_memberships_one_grant_per_user_per_source` applies on deploy with no manual step.

The rake tasks are manual. After the deploy is live, in the web container:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails data_migration:memberships
docker compose -f docker-compose.prod.yml exec web bin/rails data_migration:donations
docker compose -f docker-compose.prod.yml exec web bin/rails billing:verify_migration
```

Expected on a first run: roughly 28 legacy memberships and 21 donations, `unaccounted_for: 0`, and `verify_migration` reporting zero missing in all three categories. **`verify_migration` exits non-zero if any legacy record has no counterpart** — that is the signal to read the listed ids, not to re-run blindly. Unattached memberships are reported but never fail the run; work through them at `/admin/memberships?attached=false`.

---

## Notes for the executor

- **Do not run either `data_migration:` task during implementation.** They write to the development database against the live legacy database. The development books data exists nowhere else and takes hours to rebuild.
- **`Membership.granting_access` does not exist yet.** The spec describes it and this plan's comments reference its semantics, but it ships in increment 7 (entitlements), a later plan. Do not add it here; do not write a test that calls it.
- **`User#member?` does not exist yet either.** Same increment, same rule.
- **`rake stripe:sync_plans` and `stripe:bootstrap` do not exist yet.** They ship in increment 6. The billing plans admin refers to `sync_plans` in copy and comments as the owner of the price fields, which is correct as a statement of design intent — do not implement them here, and do not link to them.
- If a test fails with a missing relation or index, re-run `bin/rails db:test:prepare` before debugging: this worktree shares `the_greatest_test` with the main checkout and its schema can be reverted by anything running there.
