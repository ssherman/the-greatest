# Membership Entitlements & Checkout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the membership rows that already exist in production actually mean something (increment 7), then let the new app sell memberships and take donations through Stripe (increment 6), with Playwright covering both (increment 11).

**Architecture:** Entitlement is one `exists?` against a single scope on `memberships` — no new tables, no new columns. Checkout creates Stripe Checkout Sessions through the API (never Payment Links), tagged `metadata[origin_app] = "the-greatest"` at the top level *and* on the subscription, which is what lets the legacy books app recognise and skip our events. Nothing about the "webhooks are signals, never data" reconcile design changes: checkout writes `stripe_customer_id` to the user before redirecting, and every state read still comes from a fresh Stripe API call.

**Tech Stack:** Rails 8, Stripe Ruby gem (pinned API version `2026-07-29.dahlia`), Sidekiq, Minitest + Mocha + fixtures, Stimulus, ViewComponents, daisyUI 5 / Tailwind 4, Playwright.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — read it before starting. This plan implements increments 7, 6 and 11 from its increments table. Increments 1–4, 9 and 10 are already shipped and deployed.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Working directory is `web-app/`** for all Rails/yarn commands. `docs/` is at the **project root**, not `web-app/docs/`.
- **Linter is `bundle exec standardrb`** — never `bin/rubocop`. Run it before every commit.
- **Full suite is `bin/rails test`.** Baseline for this branch: **6768 runs, 159891 assertions, 0 failures, 0 errors, 0 skips.** Any new failure is yours.
- **Services live in `app/lib/services/<domain>/`**, not `app/services/`. Jobs live in `app/sidekiq/`, generated with `bin/rails generate sidekiq:job billing/foo`.
- **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` declared inside each service class. `keyword_init` is deliberate; a Standard cop is disabled for it.
- **Rake tasks stay thin.** The logic goes in a service with an ordinary test; the task is a wrapper that prints and sets an exit code. `lib/tasks/billing.rake`'s `verify_migration` → `Services::Billing::VerifyMigration` is the precedent, and there is **no test in this repo that invokes a Rake task**, so do not invent that pattern.
- **Integration tests set the host with `host!`**, e.g. `host! Rails.application.config.domains[:books]` — see `test/controllers/my_lists_controller_test.rb:14`. There is no `books_host` helper; do not add one. `sign_in_as(user, stub_auth: true)` is defined in `test/test_helper.rb:39`.
- **`rails-controller-testing` is NOT in the Gemfile**, so `assert_template` and `assigns` do not exist. Assert on `response.body` or on behaviour instead.
- **Webhook test helpers already exist** in `test/support/stripe_webhook_helper.rb`: `TEST_WEBHOOK_SECRET`, `stripe_event_payload(type:, object:, id:, livemode:)`, `stripe_signature_header(payload, secret:, timestamp:)`, `stripe_subscription_object(...)`. Reuse them; do not write new signing code.
- **`with_env` already exists** in `test/lib/services/billing/stripe_client_test.rb` and takes a **hash**: `with_env("STRIPE_WEBHOOK_SECRET" => "whsec_x") { ... }`. It also saves and restores the `Stripe` module globals.
- **Billing services are namespaced `Services::Billing::`**, never `Services::Membership::` — inside a `Services::Membership` module a bare `Membership` resolves to the module, not the model. Same reason the gate is top-level `MembershipGate`. Root-anchor `::Membership`, `::User`, `::Donation` inside `Services::Billing`.
- **Rails 8 enum syntax:** `enum :status, {active: 0}` — colon prefix, never `enum status: {...}`.
- **daisyUI 5, not 4.** These ten classes fail silently and are blocked by `test/lint/daisyui_v4_classes_test.rb` with an **empty allowlist**: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`select`. When the guard fails, remove the class — never add an allowlist entry.
- **Colour:** membership status is conveyed in words, never colour alone, and never green-versus-red. The books theme's `success` token is **purple on purpose** — do not "fix" it.
- **Never log a Stripe payload.** It carries customer email, name, address and card last-four, and this repository is public. Log event id, event type, and exception class only.
- **No webhook verification bypass** — not behind an ENV var, not behind `Rails.env.development?`, not behind a param.
- **Every new user-facing page needs a Playwright E2E test** (Task 15 covers all of them at once).
- **Turbo frames trap links.** Any `turbo_frame_tag` whose contents link off-page needs `target: "_top"`. Guarded by `assert_no_frame_trapped_links`.
- **Long user-supplied text needs `overflow-wrap: anywhere`** — `break-words` does not fix the whole-page sideways scroll.
- **Stripe metadata rules, load-bearing for legacy coexistence.** Both are already spec'd in `docs/specs/membership-and-stripe-billing.md` under "What increment 6 must do to hold up its end":
  1. Set top-level `metadata: {origin_app: "the-greatest"}` on **every** Checkout Session, both modes.
  2. Set `subscription_data: {metadata: {app_user_id:, origin_app: "the-greatest"}}` on every subscription-mode session.
  3. **Create sessions with the API, never with Payment Links.** Legacy's structural guard is "this session carries no `payment_link`, so it is not mine". A session created through a payment link carries one, the guard never fires, and the donation defect it closes silently re-opens.
- **Do not touch the permutation test's assertions.** `test/sidekiq/billing/process_stripe_event_job_test.rb` contains `"every permutation of subscribe-time events converges on the same state"`. Task 10 adds a *stub* to it; it must not weaken or delete an assertion. It is the one test that would catch a regression back to "write state from the payload".

---

## File Structure

**Phase A — increment 7 (entitlements).** Nothing here calls Stripe.

| File | Responsibility |
|---|---|
| `app/models/membership.rb` (modify) | Add the `granting_access` scope — the single definition of "grants access" |
| `app/models/user.rb` (modify) | `has_many :memberships`, `#member?`, `#granting_membership` |
| `app/lib/membership_gate.rb` (create) | The registry of member-only feature keys — one place answers "what is behind the paywall?" |
| `app/controllers/concerns/membership_gated.rb` (create) | `require_membership!(:feature)` controller filter |
| `app/helpers/membership_helper.rb` (create) | `members_only?(:feature)` view helper + status wording |
| `app/controllers/members_controller.rb` (create) | The `/members` page — the first gated surface |
| `app/views/members/show.html.erb` (create) | Members' area |
| `app/controllers/membership_state_controller.rb` (create) | `GET /membership_state` — per-user JSON for edge-cached pages |
| `app/javascript/controllers/membership_state_controller.js` (create) | Reveals the hidden `#navbar_members` link client-side |

**Phase B — increment 6 (checkout).**

| File | Responsibility |
|---|---|
| `app/lib/services/billing/stripe_client.rb` (modify) | Support **multiple** webhook signing secrets (two endpoints = two secrets) |
| `app/controllers/webhooks/stripe_controller.rb` (modify) | Verify against each configured secret |
| `app/lib/services/billing/ensure_customer.rb` (create) | Find-or-create the Stripe Customer, writing `users.stripe_customer_id` in-request |
| `app/lib/services/billing/create_checkout_session.rb` (create) | Both modes, both metadata tags, no price id from the client |
| `app/lib/services/billing/create_portal_session.rb` (create) | Billing Portal session |
| `app/lib/services/billing/record_donation.rb` (create) | Re-reads the session from Stripe and upserts a `Donation` |
| `app/sidekiq/billing/process_stripe_event_job.rb` (modify) | Route `checkout.session.completed` through `RecordDonation` as well as reconcile |
| `app/controllers/membership_controller.rb` (create) | `/membership`, checkout, donate, portal, thanks |
| `app/views/membership/show.html.erb` + `_story_*.html.erb` + `thanks.html.erb` (create) | The page, with per-site story copy |
| `app/views/{books,music,games}/shared/_nav_links.html.erb` etc. (modify) | Support + Members nav entries |
| `lib/tasks/stripe.rake` (create) | `bootstrap`, `sync_plans`, `label_price`, `create_donation_price` |
| `config/routes.rb` (modify) | The membership routes + `/support` 301 |
| `docs/guides/stripe-account-setup.md` (create) | The manual Stripe-side runbook (endpoints, lookup keys, portal, Cloudflare) |

**Phase C — increment 11 (E2E).**

| File | Responsibility |
|---|---|
| `e2e/tests/books/membership.spec.ts` | Signed-out books |
| `e2e/tests/books/account/membership.spec.ts` | Signed-in books |
| `e2e/tests/music/public/membership.spec.ts` | Music story + plans |
| `e2e/tests/games/public/membership.spec.ts` | Games story + plans |

---

## Phase A — Increment 7: Entitlements

### Task 1: The access scope and `User#member?`

**Files:**
- Modify: `web-app/app/models/membership.rb`
- Modify: `web-app/app/models/user.rb:42-51` (the `has_many` block)
- Modify: `web-app/test/fixtures/memberships.yml`
- Test: `web-app/test/models/membership_test.rb`, `web-app/test/models/user_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Membership.granting_access` (an `ActiveRecord::Relation`), `User#member?` → `Boolean`, `User#granting_membership` → `Membership | nil`, `User#memberships` association.

Three rules, straight from the spec's Entitlement section. They are not the same rule with different data — each exists for its own reason:

1. `source: :stripe` with status `active`/`trialing` grants, **and the date is not checked.** Stripe's status is authoritative; checking a possibly-stale `current_period_end` would only produce false denials.
2. `source: :stripe` with status `canceled` and `current_period_end` in the future grants — the paid-through grace period, matching legacy behaviour.
3. `source: :comped`/`:legacy` with status `active` grants when `current_period_end` is null **or** in the future — so a comped membership with an end date actually ends, and null means never.

- [ ] **Step 1: Add the fixtures the scope needs to be falsifiable**

The four existing fixtures all *grant*. Without non-granting rows a broken scope passes. Append to `web-app/test/fixtures/memberships.yml`:

```yaml
regular_user_past_due:
  user: admin_user
  source: 0          # stripe
  status: 5          # past_due
  interval: 0        # monthly
  stripe_subscription_id: sub_admin_past_due
  stripe_customer_id: cus_admin
  current_period_end: <%= 20.days.from_now.to_fs(:db) %>
  origin_domain: books

canceled_and_expired:
  user: user_with_expired_membership
  source: 0          # stripe
  status: 2          # canceled
  interval: 0        # monthly
  stripe_subscription_id: sub_expired_grace
  stripe_customer_id: cus_expired
  current_period_end: <%= 3.days.ago.to_fs(:db) %>
  canceled_at: <%= 35.days.ago.to_fs(:db) %>
  cancel_at_period_end: true
  origin_domain: books

comped_expired:
  user: user_with_expired_comp
  source: 1          # comped
  status: 1          # active
  current_period_end: <%= 1.day.ago.to_fs(:db) %>
  note: Expired conference comp
  granted_by: admin_user

unattached_active:
  user:              # nil — an unmappable Stripe customer, stored not dropped
  source: 0          # stripe
  status: 1          # active
  interval: 1        # yearly
  stripe_subscription_id: sub_unattached
  stripe_customer_id: cus_unattached
  current_period_end: <%= 200.days.from_now.to_fs(:db) %>
```

`user_with_expired_membership` and `user_with_expired_comp` do not exist yet. Add them to `web-app/test/fixtures/users.yml`, copying the shape of the existing `regular_user` entry exactly (read it first with `sed -n '/^regular_user:/,/^$/p' test/fixtures/users.yml`) and changing only `email`, `display_name` and `external_user_id` to unique values. Do **not** invent columns.

Note the `memberships` table carries `index_memberships_one_grant_per_user_per_source (user_id, source) UNIQUE WHERE source <> 0 AND user_id IS NOT NULL`, so `comped_expired` must belong to a user who has no other comped/legacy row. That is why it gets a new user rather than reusing `editor_user`.

- [ ] **Step 2: Write the failing tests**

Add to `web-app/test/models/membership_test.rb`:

```ruby
  test "granting_access includes an active stripe membership" do
    assert_includes Membership.granting_access, memberships(:regular_user_monthly)
  end

  test "granting_access includes a canceled stripe membership still inside its paid period" do
    assert_includes Membership.granting_access, memberships(:google_user_canceled_in_grace)
  end

  test "granting_access excludes a canceled stripe membership past its paid period" do
    refute_includes Membership.granting_access, memberships(:canceled_and_expired)
  end

  test "granting_access excludes a past_due stripe membership even with a future period end" do
    # The date is deliberately in the future: this asserts the STATUS is what
    # denies access, not the date. A scope that only checked the date would pass
    # every other test in this file and fail this one.
    refute_includes Membership.granting_access, memberships(:regular_user_past_due)
  end

  test "granting_access includes a comped membership with no end date" do
    assert_includes Membership.granting_access, memberships(:editor_user_comped)
  end

  test "granting_access includes a legacy early-supporter membership" do
    assert_includes Membership.granting_access, memberships(:password_user_legacy)
  end

  test "granting_access excludes a comped membership whose end date has passed" do
    refute_includes Membership.granting_access, memberships(:comped_expired)
  end

  test "granting_access ignores the date for an active stripe membership" do
    # Trust Stripe's status over our copy of the date: a stale current_period_end
    # must not deny a subscriber who is currently paying.
    membership = memberships(:regular_user_monthly)
    membership.update!(current_period_end: 5.days.ago)

    assert_includes Membership.granting_access, membership
  end
```

Add to `web-app/test/models/user_test.rb`:

```ruby
  test "member? is true for a user with an active stripe membership" do
    assert users(:regular_user).member?
  end

  test "member? is true for a comped user" do
    assert users(:editor_user).member?
  end

  test "member? is false for a user whose comp has expired" do
    refute users(:user_with_expired_comp).member?
  end

  test "member? is false for a user with no membership at all" do
    user = users(:admin_user)
    user.memberships.destroy_all

    refute user.member?
  end

  test "granting_membership returns the row that grants access, not merely the newest" do
    user = users(:regular_user)
    user.memberships.create!(
      source: :stripe, status: :incomplete_expired,
      stripe_subscription_id: "sub_abandoned_attempt", stripe_customer_id: "cus_regular"
    )

    assert_equal memberships(:regular_user_monthly), user.granting_membership
  end
```

- [ ] **Step 3: Run them and watch them fail**

```bash
bin/rails test test/models/membership_test.rb test/models/user_test.rb
```

Expected: `NoMethodError: undefined method 'granting_access'` and `undefined method 'member?'`.

- [ ] **Step 4: Implement**

In `app/models/membership.rb`, after the validations:

```ruby
  # The single definition of "this row grants access". Three rules that look
  # similar but exist for different reasons -- see the spec's Entitlement
  # section before changing any of them.
  #
  # A Stripe row that is active or trialing grants WITHOUT a date check: Stripe's
  # status is authoritative and our copy of current_period_end can be stale, so
  # checking it could only ever produce a false denial for someone who is paying.
  # A canceled Stripe row grants until its paid-through date -- the grace period.
  # A comped or legacy grant has no Stripe status to trust, so it must be active
  # AND unexpired, with a null end date meaning "never expires".
  scope :granting_access, -> {
    now = Time.current

    where(source: :stripe, status: [:active, :trialing])
      .or(where(source: :stripe, status: :canceled).where(current_period_end: now..))
      .or(where(source: [:comped, :legacy], status: :active).where(current_period_end: nil))
      .or(where(source: [:comped, :legacy], status: :active).where(current_period_end: now..))
  }
```

In `app/models/user.rb`, inside the `has_many` block (after `has_many :reviews`):

```ruby
  has_many :memberships, dependent: :nullify
```

`:nullify`, not `:destroy` — `memberships.user_id` is nullable precisely so a membership survives without a user, and destroying a paid Stripe subscription row because a user record went away would lose billing history the reconciler would then rebuild unattached anyway.

Then, in the public methods section of `app/models/user.rb`:

```ruby
  # One indexed exists? against one table. This is the whole entitlement check --
  # there is deliberately no caching layer, no cookie, and no denormalised
  # boolean on users, because every one of those is a second source of truth.
  def member? = memberships.granting_access.exists?

  # The row a member's status is displayed from. Ordered so a Stripe row wins
  # over a comp when someone has both -- the Stripe row is the one with a
  # renewal date and a portal to manage.
  def granting_membership
    memberships.granting_access.order(:source, current_period_end: :desc).first
  end
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/models/membership_test.rb test/models/user_test.rb
```

Expected: PASS.

- [ ] **Step 6: Prove the tests can fail**

Temporarily delete the `.or(where(source: [:comped, :legacy], status: :active).where(current_period_end: nil))` branch and re-run. Expected: the comped and legacy tests fail. Restore the line. This is not optional — `assert_includes` against a scope is exactly the shape that has passed against deleted code in this repo before.

- [ ] **Step 7: Full suite and lint**

```bash
bin/rails test
bundle exec standardrb
```

- [ ] **Step 8: Commit**

```bash
git add web-app/app/models/membership.rb web-app/app/models/user.rb web-app/test/fixtures/memberships.yml web-app/test/fixtures/users.yml web-app/test/models/membership_test.rb web-app/test/models/user_test.rb
git commit -m "feat(billing): define which memberships grant access"
```

---

### Task 2: `MembershipGate` and the controller filter

**Files:**
- Create: `web-app/app/lib/membership_gate.rb`
- Create: `web-app/app/controllers/concerns/membership_gated.rb`
- Create: `web-app/app/helpers/membership_helper.rb`
- Test: `web-app/test/lib/membership_gate_test.rb`

**Interfaces:**
- Consumes: `User#member?` (Task 1).
- Produces: `MembershipGate::FEATURES` (Hash), `MembershipGate.members_only?(key)` → `Boolean`, `MembershipGate.validate!(key)` (raises `MembershipGate::UnknownFeature`), `MembershipGated#require_membership!(feature)` controller filter, `MembershipHelper#members_only?(key)` view helper, `MembershipHelper#membership_status_sentence(membership)` → `String`.

The registry's value is auditability — one file answers "what is behind the paywall?" — and it has teeth because `require_membership!` refuses an unregistered key rather than silently gating something nobody wrote down.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/membership_gate_test.rb`:

```ruby
require "test_helper"

class MembershipGateTest < ActiveSupport::TestCase
  test "members_only? is true for a registered feature" do
    assert MembershipGate.members_only?(:members_area)
  end

  test "members_only? accepts a string as well as a symbol" do
    assert MembershipGate.members_only?("members_area")
  end

  test "members_only? is false for anything not registered" do
    refute MembershipGate.members_only?(:ranked_lists)
  end

  test "every registered feature carries a human description" do
    # The registry exists to be read by a person asking "what is behind the
    # paywall?". A bare key with no description does not answer that.
    MembershipGate::FEATURES.each do |key, description|
      assert description.present?, "#{key} has no description"
    end
  end

  test "validate! raises for an unregistered feature" do
    assert_raises(MembershipGate::UnknownFeature) { MembershipGate.validate!(:not_a_feature) }
  end

  test "validate! returns the symbol for a registered feature" do
    assert_equal :members_area, MembershipGate.validate!("members_area")
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/lib/membership_gate_test.rb
```

Expected: `NameError: uninitialized constant MembershipGate`.

- [ ] **Step 3: Implement the gate**

Create `web-app/app/lib/membership_gate.rb`:

```ruby
# frozen_string_literal: true

# The one place that answers "what is behind the paywall?".
#
# Top-level and not nested under Membership on purpose: inside a Membership
# namespace a bare `Membership` resolves to the module rather than the model,
# which has bitten this codebase at least three times and presents as a
# confusing NameError.
#
# This is a registry, not an abstraction layer. Its value is that a reviewer can
# read one hash and know the complete answer. require_membership! refuses an
# unregistered key, so a feature cannot be gated without being written down here.
module MembershipGate
  class UnknownFeature < StandardError; end

  # key => what a person would call it
  FEATURES = {
    members_area: "The members' area at /members"
  }.freeze

  def self.members_only?(feature) = FEATURES.key?(feature.to_sym)

  def self.features = FEATURES.keys

  # Returns the symbol, or raises. Called by require_membership! so a typo in a
  # controller is a loud failure in development and in test rather than a page
  # that silently gates nothing (or gates everything).
  def self.validate!(feature)
    key = feature.to_sym
    raise UnknownFeature, "#{feature.inspect} is not registered in MembershipGate::FEATURES" unless FEATURES.key?(key)
    key
  end
end
```

- [ ] **Step 4: Run the test**

```bash
bin/rails test test/lib/membership_gate_test.rb
```

Expected: PASS.

- [ ] **Step 5: Add the controller filter and the view helper**

Create `web-app/app/controllers/concerns/membership_gated.rb`:

```ruby
# frozen_string_literal: true

# Puts a controller action behind the paywall.
#
#   include MembershipGated
#   before_action -> { require_membership!(:members_area) }
#
# Redirects rather than 403s: a non-member landing on a members-only URL should
# be shown how to become a member, not told off. Both branches land on
# /membership because that is where both the sign-in modal and the plans live.
module MembershipGated
  extend ActiveSupport::Concern

  private

  def require_membership!(feature)
    MembershipGate.validate!(feature)
    return if current_user&.member?

    message = if current_user
      "That page is for members. Membership covers every site."
    else
      "Sign in to your membership to open that page."
    end

    redirect_to membership_path, alert: message
  end
end
```

Create `web-app/app/helpers/membership_helper.rb`:

```ruby
# frozen_string_literal: true

module MembershipHelper
  # "Is this feature behind the paywall?" -- for rendering a members-only marker
  # next to something. It answers a question about the FEATURE, not about the
  # viewer; pair it with current_user&.member? when deciding what to show.
  def members_only?(feature) = MembershipGate.members_only?(feature)

  # Membership status in words. Never colour alone, and never green-versus-red:
  # a red-green colour-blind reader must get the same information from the text.
  def membership_status_sentence(membership)
    return "You are not currently a member." if membership.nil?

    ends_on = membership.current_period_end

    if membership.source_stripe? && membership.cancel_at_period_end? && ends_on
      "Your membership is cancelled and stays active until #{ends_on.to_fs(:long)}."
    elsif membership.source_stripe? && membership.canceled? && ends_on
      "Your membership has ended and access runs until #{ends_on.to_fs(:long)}."
    elsif membership.source_stripe? && ends_on
      "Your #{membership.interval} membership renews on #{ends_on.to_fs(:long)}."
    elsif ends_on
      "Your membership runs until #{ends_on.to_fs(:long)}."
    else
      "Your membership does not expire."
    end
  end
end
```

The enum predicates above are verified against the model, and they are deliberately inconsistent because the model is: `source` and `interval` are declared `prefix: true` (so `source_stripe?`, `interval_monthly?`), but `status` is **not**, so it is `canceled?` and `active?` with no prefix. `app/views/admin/memberships/show.html.erb:69` already uses `@membership.canceled?`. Do not "tidy" this by adding a prefix — that is a model change with an admin view depending on it.

- [ ] **Step 6: Test the helper**

Create `web-app/test/helpers/membership_helper_test.rb`:

```ruby
require "test_helper"

class MembershipHelperTest < ActionView::TestCase
  include MembershipHelper

  test "a nil membership reads as not a member" do
    assert_equal "You are not currently a member.", membership_status_sentence(nil)
  end

  test "an active stripe membership names its renewal date" do
    membership = memberships(:regular_user_monthly)

    sentence = membership_status_sentence(membership)

    assert_match(/renews on/, sentence)
    assert_match(membership.current_period_end.to_fs(:long), sentence)
  end

  test "a cancelled membership says it stays active until the paid-through date" do
    membership = memberships(:google_user_canceled_in_grace)

    assert_match(/stays active until|access runs until/, membership_status_sentence(membership))
  end

  test "a comp with no end date says it does not expire" do
    assert_equal "Your membership does not expire.", membership_status_sentence(memberships(:editor_user_comped))
  end
end
```

```bash
bin/rails test test/helpers/membership_helper_test.rb
```

Expected: PASS (fix the enum predicate names if it does not).

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/lib/membership_gate.rb web-app/app/controllers/concerns/membership_gated.rb web-app/app/helpers/membership_helper.rb web-app/test/lib/membership_gate_test.rb web-app/test/helpers/membership_helper_test.rb
git commit -m "feat(billing): add the membership gate registry and controller filter"
```

---

### Task 3: The `/members` page

**Files:**
- Create: `web-app/app/controllers/members_controller.rb`
- Create: `web-app/app/views/members/show.html.erb`
- Modify: `web-app/config/routes.rb` (in the global, non-domain-constrained block near `get "my/reviews"`)
- Test: `web-app/test/controllers/members_controller_test.rb`

**Interfaces:**
- Consumes: `require_membership!(:members_area)` (Task 2), `User#granting_membership` (Task 1), `membership_path` (defined in Task 11 — declare the route in this task so the path helper exists).
- Produces: `members_path` → `/members`.

This is the first gated surface. It takes nothing away from free users; it is a new page that only members can open.

- [ ] **Step 1: Add the routes**

In `web-app/config/routes.rb`, immediately after the `get "my/reviews/page/:page"` line, add:

```ruby
  # Membership -- global (non-domain-constrained) like /my/lists and /searches:
  # one membership covers every site, so there is one set of URLs served on
  # every host, with the layout resolved from Current.domain in the controller.
  get "membership", to: "membership#show", as: :membership
  get "membership/thanks", to: "membership#thanks", as: :membership_thanks
  post "membership/checkout", to: "membership#checkout", as: :membership_checkout
  post "membership/donate", to: "membership#donate", as: :membership_donate
  post "membership/portal", to: "membership#portal", as: :membership_portal

  # Per-user membership state for edge-cached pages, following
  # UserListStateController: never cached, JSON only.
  get "membership_state", to: "membership_state#show", as: :membership_state

  # The members' area -- the first thing behind the paywall.
  get "members", to: "members#show", as: :members

  # Legacy books URL. ~15 years of inbound links point at /support.
  get "support", to: redirect("/membership", status: 301)
```

Only `members#show` and `membership_state#show` get controllers in Phase A. The `membership#*` routes are wired in Task 11 — but declaring them now is deliberate, because `require_membership!` redirects to `membership_path` and Task 2's filter would raise without it.

To keep the suite green between here and Task 11, this task also creates a minimal `MembershipController#show` that renders the page shell; Task 11 fills in the plans, the buttons and the other four actions.

- [ ] **Step 2: Write the failing controller test**

Create `web-app/test/controllers/members_controller_test.rb`:

```ruby
require "test_helper"

class MembersControllerTest < ActionDispatch::IntegrationTest
  test "a member sees the members area" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get members_url

    assert_response :success
  end

  test "a comped member sees the members area" do
    sign_in_as(users(:editor_user), stub_auth: true)

    get members_url

    assert_response :success
  end

  test "a signed-in non-member is redirected to the membership page" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    get members_url

    assert_redirected_to membership_path
    assert_equal "That page is for members. Membership covers every site.", flash[:alert]
  end

  test "a signed-out visitor is redirected to the membership page" do
    get members_url

    assert_redirected_to membership_path
    assert_equal "Sign in to your membership to open that page.", flash[:alert]
  end

  test "a member whose comp has expired is redirected" do
    sign_in_as(users(:user_with_expired_comp), stub_auth: true)

    get members_url

    assert_redirected_to membership_path
  end

  test "the page is never cached" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get members_url

    assert_includes response.headers["Cache-Control"], "no-store"
  end
end
```

Every integration test class in this task needs the host set, because these routes serve every host and the layout comes from `Current.domain`. Add to the top of the class:

```ruby
  setup { host! Rails.application.config.domains[:books] }
```

- [ ] **Step 3: Run and watch it fail**

```bash
bin/rails test test/controllers/members_controller_test.rb
```

Expected: routing error / uninitialized constant `MembersController`.

- [ ] **Step 4: Implement the controller**

Create `web-app/app/controllers/members_controller.rb`:

```ruby
# frozen_string_literal: true

# The members' area -- the first surface behind the paywall.
#
# Global route, no DomainConstraint: one membership covers every site, so this
# page is served on every host with the layout resolved from Current.domain.
# Never cached: it is per-user by definition.
class MembersController < ApplicationController
  include Cacheable
  include DomainLayout
  include MembershipGated

  layout :resolve_layout

  before_action :prevent_caching
  before_action -> { require_membership!(:members_area) }

  def show
    @membership = current_user.granting_membership
  end
end
```

- [ ] **Step 5: Write the view**

Create `web-app/app/views/members/show.html.erb`:

```erb
<% content_for :title, "Members" %>

<div class="container mx-auto max-w-3xl px-4 py-10">
  <h1 class="text-3xl font-bold mb-2">Members' area</h1>
  <p class="text-base-content/70 mb-8">
    Thank you for supporting <%= domain_settings[:name] %>. Your membership covers
    every site in The Greatest, not just this one.
  </p>

  <div class="card bg-base-200 mb-8">
    <div class="card-body">
      <h2 class="card-title text-xl">Your membership</h2>
      <p><%= membership_status_sentence(@membership) %></p>

      <% if @membership&.source_stripe? %>
        <div class="card-actions mt-4">
          <%= button_to "Manage billing", membership_portal_path, class: "btn btn-primary" %>
        </div>
      <% else %>
        <p class="text-sm text-base-content/70 mt-2">
          This membership was granted directly, so there is nothing to bill and
          nothing to manage.
        </p>
      <% end %>
    </div>
  </div>

  <h2 class="text-xl font-semibold mb-3">What's here</h2>
  <p class="text-base-content/80">
    This is where members' features land as they ship. Right now it is mostly a
    thank-you page — the site has no ads, sells no data, and has no investors,
    and members are the reason that can stay true.
  </p>
</div>
```

`domain_settings` is already a `helper_method` on `ApplicationController`.

- [ ] **Step 6: Add the minimal `/membership` page shell**

Create `web-app/app/controllers/membership_controller.rb`:

```ruby
# frozen_string_literal: true

# The join / support page. Global route, per-domain layout, never edge-cached:
# it renders differently for members and non-members.
#
# Task 11 adds checkout, donate, portal and thanks. This is the shell the
# members' area redirects to.
class MembershipController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :prevent_caching

  def show
    @membership = current_user&.granting_membership
  end
end
```

Create `web-app/app/views/membership/show.html.erb` as a placeholder that Task 12 replaces:

```erb
<% content_for :title, "Support #{domain_settings[:name]}" %>

<div class="container mx-auto max-w-4xl px-4 py-10">
  <h1 class="text-3xl font-bold mb-4">Support <%= domain_settings[:name] %></h1>
  <p><%= membership_status_sentence(@membership) %></p>
</div>
```

Add a matching test to a new `web-app/test/controllers/membership_controller_test.rb`:

```ruby
require "test_helper"

class MembershipControllerTest < ActionDispatch::IntegrationTest
  test "the page renders for a signed-out visitor" do
    get membership_url

    assert_response :success
  end

  test "the page renders for a member" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_url

    assert_response :success
  end

  test "the page is never cached" do
    get membership_url

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "the legacy /support url permanently redirects" do
    get "/support"

    assert_response :moved_permanently
    assert_redirected_to "/membership"
  end
end
```

- [ ] **Step 7: Run both controller tests**

```bash
bin/rails test test/controllers/members_controller_test.rb test/controllers/membership_controller_test.rb
```

Expected: PASS.

- [ ] **Step 8: Prove the gate test can fail**

Comment out the `before_action -> { require_membership!(:members_area) }` line and re-run. Expected: the three redirect tests fail. Restore it.

- [ ] **Step 9: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/controllers/members_controller.rb web-app/app/controllers/membership_controller.rb web-app/app/views/members web-app/app/views/membership web-app/config/routes.rb web-app/test/controllers/members_controller_test.rb web-app/test/controllers/membership_controller_test.rb
git commit -m "feat(billing): add the members area behind the membership gate"
```

---

### Task 4: `GET /membership_state`

**Files:**
- Create: `web-app/app/controllers/membership_state_controller.rb`
- Test: `web-app/test/controllers/membership_state_controller_test.rb`

**Interfaces:**
- Consumes: `User#member?`, `User#granting_membership` (Task 1); the route added in Task 3.
- Produces: `GET /membership_state` → `{member: Boolean, plan: String|null, source: String|null, current_period_end: String|null, csrf_token: String}`.

Follows `UserListStateController` / `ReviewStateController` exactly: `prevent_caching`, `require_signed_in!`, and a **fresh `csrf_token` in the body** — the cached HTML's `<meta name="csrf-token">` belongs to whoever populated the cache, so without this the first write from a cached page 422s.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/controllers/membership_state_controller_test.rb`:

```ruby
require "test_helper"

class MembershipStateControllerTest < ActionDispatch::IntegrationTest
  test "a member gets their plan and renewal date" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["member"]
    assert_equal "monthly", body["plan"]
    assert_equal "stripe", body["source"]
    assert_equal memberships(:regular_user_monthly).current_period_end.iso8601, body["current_period_end"]
  end

  test "a comped member reports no plan and no end date" do
    sign_in_as(users(:editor_user), stub_auth: true)

    get membership_state_url, as: :json

    body = JSON.parse(response.body)
    assert_equal true, body["member"]
    assert_nil body["plan"]
    assert_equal "comped", body["source"]
    assert_nil body["current_period_end"]
  end

  test "a signed-in non-member reports member false" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    get membership_state_url, as: :json

    assert_equal false, JSON.parse(response.body)["member"]
  end

  test "a signed-out request is unauthorized" do
    get membership_state_url, as: :json

    assert_response :unauthorized
  end

  test "the response carries a usable csrf token" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert JSON.parse(response.body)["csrf_token"].present?
  end

  test "the response is never cached" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_state_url, as: :json

    assert_includes response.headers["Cache-Control"], "no-store"
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/controllers/membership_state_controller_test.rb
```

Expected: uninitialized constant `MembershipStateController`.

- [ ] **Step 3: Implement**

Create `web-app/app/controllers/membership_state_controller.rb`:

```ruby
# frozen_string_literal: true

# Per-user membership state for pages that are cached at the edge and therefore
# render identical HTML for everyone. Same shape and same rules as
# UserListStateController and ReviewStateController.
class MembershipStateController < ApplicationController
  include Cacheable
  include JsonErrorResponses

  before_action :prevent_caching
  before_action :require_signed_in!

  # GET /membership_state
  def show
    membership = current_user.granting_membership

    render json: {
      member: membership.present?,
      # nil for a comp or a legacy grant: they have no billing interval.
      plan: membership&.interval,
      source: membership&.source,
      # nil means "never expires", not "expired" -- the client must not treat a
      # null date as a lapsed membership.
      current_period_end: membership&.current_period_end&.iso8601,
      # The cached HTML's <meta name="csrf-token"> belongs to whoever rendered
      # the cache (or no one). Issue a fresh per-session token here for
      # client-side mutations to send back via X-CSRF-Token.
      csrf_token: form_authenticity_token
    }
  end
end
```

- [ ] **Step 4: Run the test**

```bash
bin/rails test test/controllers/membership_state_controller_test.rb
```

Expected: PASS.

- [ ] **Step 5: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/controllers/membership_state_controller.rb web-app/test/controllers/membership_state_controller_test.rb
git commit -m "feat(billing): serve per-user membership state for cached pages"
```

---

### Task 5: Reveal the Members link in the nav

**Files:**
- Create: `web-app/app/javascript/controllers/membership_state_controller.js`
- Modify: `web-app/app/javascript/controllers/index.js`
- Modify: `web-app/app/views/books/shared/_nav_links.html.erb`
- Modify: `web-app/app/views/layouts/music/application.html.erb`, `web-app/app/views/layouts/games/application.html.erb`
- Test: `web-app/test/lint/daisyui_v4_classes_test.rb` must stay green; no new Ruby test (this is client-side reveal, covered by E2E in Task 15)

**Interfaces:**
- Consumes: `GET /membership_state` (Task 4), `members_path` and `membership_path` (Task 3).
- Produces: a hidden `<li id="navbar_members">` in each nav, revealed client-side.

The nav ships in **edge-cached HTML**, so a link that differs per user must ship hidden and be revealed client-side — the same approach as `#navbar_my_lists` and the Login/Logout toggle. The `Support` link is identical for everyone and is therefore plain server-rendered markup.

- [ ] **Step 1: Read the existing pattern**

```bash
sed -n '1,60p' web-app/app/javascript/controllers/user_list_state_controller.js
grep -n "navbar_my_lists" web-app/app/javascript/controllers/user_list_state_controller.js
```

Note `cookieUid()` — hydration is gated on the non-HttpOnly `tg_uid` cookie so a previous user's state cannot render on a shared browser. Copy that gate; do not fetch when the cookie is absent (the endpoint would 401).

- [ ] **Step 2: Add the nav markup**

In `web-app/app/views/books/shared/_nav_links.html.erb`, after the `navbar_my_reviews` line:

```erb
<%# Revealed client-side by membership_state_controller when the visitor is a member. %>
<li id="navbar_members" class="hidden"><a href="/members">Members</a></li>
<li><%= link_to "Support", membership_path %></li>
```

In the music and games layouts, add the same two `<li>` entries to the nav list — grep each layout for the existing nav `<ul>` and match its markup exactly. Both layouts render the menu twice (mobile and desktop); add to both copies, exactly as the books partial is used twice.

- [ ] **Step 3: Write the Stimulus controller**

Create `web-app/app/javascript/controllers/membership_state_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Reveals the members-only nav link on edge-cached pages.
//
// The navbar ships in CDN-cached HTML that is identical for every visitor, so
// the Members link is rendered hidden and revealed here once /membership_state
// confirms the signed-in user is a member. Same approach as the My Lists link
// and the Login/Logout toggle.
export default class extends Controller {
  static values = {
    url: { type: String, default: "/membership_state" }
  }

  connect() {
    // Gated on the tg_uid cookie set by AuthController at sign-in. Without a
    // signed-in marker the endpoint would just 401, so skip the request.
    if (!this.cookieUid()) {
      this.reveal(false)
      return
    }

    this.refresh()
  }

  async refresh() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
      if (!response.ok) {
        this.reveal(false)
        return
      }
      const state = await response.json()
      this.reveal(!!state.member)
    } catch (_e) {
      // A failed state fetch must never break the page. Staying hidden is the
      // safe default: the /members page re-checks membership server-side, so a
      // hidden link costs a member one click, while a wrongly-revealed one
      // would send a non-member to a redirect.
      this.reveal(false)
    }
  }

  // querySelectorAll covers both the mobile and desktop copies of the menu.
  reveal(visible) {
    document.querySelectorAll("#navbar_members").forEach((el) => {
      el.classList.toggle("hidden", !visible)
    })
  }

  cookieUid() {
    const m = document.cookie.match(/(?:^|;\s*)tg_uid=([^;]+)/)
    return m ? decodeURIComponent(m[1]) : null
  }
}
```

- [ ] **Step 4: Register the controller and mount it**

Add the registration to `web-app/app/javascript/controllers/index.js`, following the exact form of the neighbouring `user_list_state` registration (read the file — it may use an explicit `application.register` list).

Mount it on `<body>` in each of the three layouts, alongside the existing `data-controller` values — grep for `user-list-state` in the layouts and append `membership-state` to the same attribute rather than adding a second `data-controller`.

- [ ] **Step 5: Build and check**

```bash
yarn build:all
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails test
bundle exec standardrb
```

- [ ] **Step 6: Verify by hand in the browser**

```bash
bin/rails server
```

Do **not** use `bin/dev` — foreman self-terminates in a non-TTY agent shell. Check what is already serving port 3000 first (`ss -ltnp | grep 3000`); another worktree may own it, which would silently invalidate what you see.

Sign in as a member and confirm the Members link appears; sign out and confirm it does not.

- [ ] **Step 7: Commit**

```bash
git add web-app/app/javascript web-app/app/views
git commit -m "feat(billing): reveal the members nav link on cached pages"
```

---

### Phase A checkpoint

Stop here and hand back for review before starting Phase B. Phase A is a complete, shippable increment: it changes nothing for anyone who is not already a member, and it can merge to main (and therefore deploy) on its own.

Run before handing off:

```bash
bin/rails test
bundle exec standardrb
```

---

## Phase B — Increment 6: Checkout

### Task 6: Verify webhooks against multiple signing secrets

**Files:**
- Modify: `web-app/app/lib/services/billing/stripe_client.rb`
- Modify: `web-app/app/controllers/webhooks/stripe_controller.rb`
- Modify: `/home/shane/dev/the-greatest/deployment/ENV.md` (the `STRIPE_WEBHOOK_SECRET` section, ~line 167)
- Test: `web-app/test/lib/services/billing/stripe_client_test.rb`, `web-app/test/controllers/webhooks/stripe_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `StripeClient.webhook_secrets` → `Array<String>`. `StripeClient.webhook_secret` is kept, returning the first, so existing callers and tests keep working.

**Why this task exists.** The decision is to register the endpoint on **two** production hosts — `https://thegreatestmusic.org/webhooks/stripe` and `https://thegreatest.games/webhooks/stripe`. Stripe issues a **separate signing secret per endpoint**, and the app currently verifies against exactly one. Without this change one of the two endpoints would fail verification on every delivery, return 400, and Stripe would retry it for 72 hours and eventually disable it. Two endpoints also means every event arrives twice; that is already safe, because `stripe_events.stripe_event_id` is unique and the controller answers 200 to a redelivery without re-enqueueing.

The ENV var name does not change — the value becomes a comma-separated list — so no new secret has to be threaded through SOPS.

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/services/billing/stripe_client_test.rb`. That file already defines a private `with_env(pairs)` helper that takes a **hash** and also saves and restores the `Stripe` module globals — use it, do not write another:

```ruby
      test "webhook_secrets splits a comma-separated list" do
        with_env("STRIPE_WEBHOOK_SECRET" => "whsec_one,whsec_two") do
          assert_equal ["whsec_one", "whsec_two"], StripeClient.webhook_secrets
        end
      end

      test "webhook_secrets trims whitespace and drops empties" do
        with_env("STRIPE_WEBHOOK_SECRET" => " whsec_one , , whsec_two ") do
          assert_equal ["whsec_one", "whsec_two"], StripeClient.webhook_secrets
        end
      end

      test "webhook_secrets is empty when the variable is unset" do
        with_env("STRIPE_WEBHOOK_SECRET" => nil) do
          assert_empty StripeClient.webhook_secrets
          refute StripeClient.webhook_configured?
        end
      end

      test "a single secret still works unchanged" do
        with_env("STRIPE_WEBHOOK_SECRET" => "whsec_only") do
          assert_equal ["whsec_only"], StripeClient.webhook_secrets
          assert StripeClient.webhook_configured?
        end
      end
```

Match the existing file's nesting and constant style — it is inside `module Services / module Billing` and refers to `StripeClient` unqualified.

Add to `web-app/test/controllers/webhooks/stripe_controller_test.rb`. It includes `StripeWebhookHelper` (`test/support/stripe_webhook_helper.rb`), which provides `TEST_WEBHOOK_SECRET`, `stripe_event_payload(type:, object:, id:, livemode:)`, `stripe_signature_header(payload, secret:, timestamp:)` and `stripe_subscription_object(...)`. Reuse them; do not write new signing code. Note the existing file stubs `StripeClient.webhook_secret` rather than setting ENV — for these two tests set the ENV variable instead, since the behaviour under test *is* the parsing:

```ruby
    test "an event signed with the second configured secret is accepted" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_two_secret", customer: "cus_two_secret"),
        id: "evt_two_secret",
        livemode: Rails.configuration.stripe_livemode
      )

      with_stripe_webhook_secrets("whsec_other_endpoint,#{StripeWebhookHelper::TEST_WEBHOOK_SECRET}") do
        post webhooks_stripe_url, params: payload,
          headers: {"HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload),
                    "CONTENT_TYPE" => "application/json"}
      end

      assert_response :ok
      assert StripeEvent.exists?(stripe_event_id: "evt_two_secret")
    end

    test "an event signed with none of the configured secrets is rejected" do
      payload = stripe_event_payload(
        type: "customer.subscription.created",
        object: stripe_subscription_object(id: "sub_bad_sig", customer: "cus_bad_sig"),
        id: "evt_bad_sig",
        livemode: Rails.configuration.stripe_livemode
      )

      assert_no_difference "StripeEvent.count" do
        with_stripe_webhook_secrets("whsec_first,whsec_second") do
          post webhooks_stripe_url, params: payload,
            headers: {"HTTP_STRIPE_SIGNATURE" => stripe_signature_header(payload, secret: "whsec_not_configured"),
                      "CONTENT_TYPE" => "application/json"}
        end
      end

      assert_response :bad_request
    end
```

The existing file already has an ENV save/restore around `STRIPE_WEBHOOK_SECRET` (see its lines 17 and 37). Extract that into a private helper in the same file and use it for both tests rather than repeating the save/restore:

```ruby
    private

    def with_stripe_webhook_secrets(value)
      previous = ENV["STRIPE_WEBHOOK_SECRET"]
      ENV["STRIPE_WEBHOOK_SECRET"] = value
      yield
    ensure
      previous.nil? ? ENV.delete("STRIPE_WEBHOOK_SECRET") : (ENV["STRIPE_WEBHOOK_SECRET"] = previous)
    end
```

If the existing tests stub `StripeClient.webhook_secret` in a `setup` block, that stub will shadow the ENV variable for these two tests — unstub it inside them (`Services::Billing::StripeClient.unstub(:webhook_secret)`) or move the stub out of `setup`. Whichever you choose, confirm by making the "second configured secret" test fail on purpose first (Step 2).

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/lib/services/billing/stripe_client_test.rb test/controllers/webhooks/stripe_controller_test.rb
```

Expected: `undefined method 'webhook_secrets'`, and the second-secret controller test returning 400.

- [ ] **Step 3: Implement in `StripeClient`**

First add the shared origin tag, next to `API_VERSION`. It lives here because three later services stamp it onto Stripe objects and they must not each carry their own copy of the string — a typo in one of them is invisible until the legacy app starts writing rows it should have skipped:

```ruby
      # Stamped onto every Stripe object this application creates -- customers,
      # checkout sessions, subscriptions, payment intents. The legacy books app
      # shares this Stripe account and reads this tag to decide "not mine, skip".
      # See docs/specs/membership-and-stripe-billing.md, "Legacy coexistence".
      ORIGIN_APP = "the-greatest"
```

Then replace the `webhook_secret` / `webhook_configured?` methods with:

```ruby
        # Every signing secret this deployment will accept.
        #
        # Plural because the account registers one endpoint per production host
        # (music and games), and Stripe issues a SEPARATE signing secret per
        # endpoint. Verifying against only one would 400 every delivery to the
        # other, and Stripe disables an endpoint that keeps failing. Set
        # STRIPE_WEBHOOK_SECRET to a comma-separated list.
        #
        # There is deliberately NO placeholder fallback. This repository is
        # public, so any literal here is a published value, and verifying a
        # signature against a published value is not verification. An earlier
        # version returned "whsec_missing" and was exactly that bypass. Callers
        # must check webhook_configured? and refuse the request instead.
        def webhook_secrets
          ENV["STRIPE_WEBHOOK_SECRET"].to_s.split(",").map(&:strip).reject(&:empty?)
        end

        # Kept for callers that only need "a" secret (and for the local
        # `stripe listen` case, which only ever has one).
        def webhook_secret = webhook_secrets.first

        # Whether deliveries can be verified at all. The webhook endpoint
        # refuses before verification when this is false.
        def webhook_configured? = webhook_secrets.any?
      end
```

- [ ] **Step 4: Implement in the controller**

Replace `verified_event` in `app/controllers/webhooks/stripe_controller.rb`:

```ruby
    # Tries every configured signing secret and returns the first event that
    # verifies. Two endpoints (one per production host) means two secrets, and a
    # delivery is only ever signed with the secret of the endpoint it went to.
    #
    # Note this is also exactly the shape Stripe documents for rotating a
    # secret: run with old and new configured until the rotation completes.
    def verified_event
      last_error = nil

      Services::Billing::StripeClient.webhook_secrets.each do |secret|
        return Stripe::Webhook.construct_event(
          request.raw_post, request.env["HTTP_STRIPE_SIGNATURE"], secret
        )
      rescue JSON::ParserError, Stripe::SignatureVerificationError => e
        # A parse failure is not secret-specific -- the body is simply not JSON,
        # so no other secret will help. Stop rather than re-parsing it N times.
        last_error = e
        break if e.is_a?(JSON::ParserError)
      end

      # Never log the payload: it carries customer email, name, address and card
      # last-four. The error class alone is enough to diagnose.
      Rails.logger.warn("[stripe-webhook] rejected: #{last_error&.class}")
      nil
    end
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/lib/services/billing/stripe_client_test.rb test/controllers/webhooks/stripe_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Update the ENV documentation**

In `deployment/ENV.md`, under `#### STRIPE_WEBHOOK_SECRET`, add:

```markdown
Accepts a **comma-separated list** of signing secrets. Stripe issues one secret
per registered endpoint, and production registers two — one per host
(`thegreatestmusic.org` and `thegreatest.games`) — so both must be present or
every delivery to the second endpoint returns 400 and Stripe eventually disables
it. Local development uses a single secret, the one `stripe listen` prints.

Rotating a secret uses the same mechanism: run with old and new configured
together until the rotation completes, then drop the old one.
```

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/lib/services/billing/stripe_client.rb web-app/app/controllers/webhooks/stripe_controller.rb web-app/test deployment/ENV.md
git commit -m "feat(billing): accept a signing secret per registered webhook endpoint"
```

---

### Task 7: `EnsureCustomer`

**Files:**
- Create: `web-app/app/lib/services/billing/ensure_customer.rb`
- Test: `web-app/test/lib/services/billing/ensure_customer_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::Billing::EnsureCustomer.call(user:)` → `Result` whose `data` is the `String` Stripe customer id.

**Why it matters.** This service is what deletes a whole class of legacy bug. Writing `users.stripe_customer_id` **during the checkout request**, before any webhook can fire, is what makes the user↔customer link exist by the time the first event arrives — which is why `ReconcileCustomer` needs no `find_checkout_session_for_subscription` user-recovery path.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/billing/ensure_customer_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class EnsureCustomerTest < ActiveSupport::TestCase
      test "returns the existing customer id without calling Stripe" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: "cus_already_there")
        ::Stripe::Customer.expects(:create).never

        result = EnsureCustomer.call(user: user)

        assert result.success?
        assert_equal "cus_already_there", result.data
      end

      test "creates a customer and persists the id on the user" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).returns(stub(id: "cus_new"))

        result = EnsureCustomer.call(user: user)

        assert result.success?
        assert_equal "cus_new", result.data
        assert_equal "cus_new", user.reload.stripe_customer_id
      end

      test "tags the customer so the reconciler can attach it without our database" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).with(
          has_entry(metadata: has_entries(app_user_id: user.id, origin_app: "the-greatest")),
          has_entry(idempotency_key: "customer-#{user.id}")
        ).returns(stub(id: "cus_new"))

        assert EnsureCustomer.call(user: user).success?
      end

      test "a Stripe failure is a failed Result, not an exception" do
        user = users(:regular_user)
        user.update!(stripe_customer_id: nil)
        ::Stripe::Customer.expects(:create).raises(::Stripe::APIConnectionError.new("boom"))

        result = EnsureCustomer.call(user: user)

        refute result.success?
        assert_nil user.reload.stripe_customer_id
      end

      test "a nil user fails without touching Stripe" do
        ::Stripe::Customer.expects(:create).never

        refute EnsureCustomer.call(user: nil).success?
      end
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/lib/services/billing/ensure_customer_test.rb
```

Expected: uninitialized constant.

- [ ] **Step 3: Implement**

Create `web-app/app/lib/services/billing/ensure_customer.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Find-or-create the Stripe Customer for a user, and write the id back to
    # the user IN THIS REQUEST.
    #
    # That write is the point of the service. It means the user<->customer link
    # exists before any webhook for the subscription can arrive, which is why
    # ReconcileCustomer needs no checkout-session user-recovery path -- the
    # legacy handler's find_checkout_session_for_subscription exists precisely
    # because it did not have this.
    class EnsureCustomer
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(user:) = new(user: user).call

      def initialize(user:)
        @user = user
      end

      def call
        return failure("user is required") if @user.nil?
        return success(@user.stripe_customer_id) if @user.stripe_customer_id.present?

        customer = ::Stripe::Customer.create(
          {
            email: @user.email,
            name: @user.display_name.presence || @user.name,
            # app_user_id is the reconciler's second attachment path, used when a
            # subscription turns up whose customer we have no local row for.
            # origin_app matches the tag on sessions and subscriptions so every
            # object this app creates is identifiable in a shared account.
            metadata: {app_user_id: @user.id, origin_app: StripeClient::ORIGIN_APP}
          },
          # Protects against a double-submitted checkout form creating two
          # customers for one user. Stripe expires these keys after 24 hours,
          # so it is a duplicate-click guard, not a permanent uniqueness claim.
          {idempotency_key: "customer-#{@user.id}"}
        )

        @user.update!(stripe_customer_id: customer.id)
        success(customer.id)
      rescue ::Stripe::StripeError => e
        # Never log the exception message here: Stripe echoes request parameters
        # in some error messages, and those carry the customer's email.
        Rails.logger.error("[billing] EnsureCustomer failed for user #{@user&.id}: #{e.class}")
        failure(e.message)
      end

      private

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

`StripeClient::ORIGIN_APP` is added by Task 6, which comes before this one. If it is missing, go back and add it there rather than inlining the string — one copy of that tag is the whole point.

- [ ] **Step 4: Run the test, then the suite, lint, commit**

```bash
bin/rails test test/lib/services/billing/ensure_customer_test.rb
bin/rails test
bundle exec standardrb
git add web-app/app/lib/services/billing/ensure_customer.rb web-app/test/lib/services/billing/ensure_customer_test.rb
git commit -m "feat(billing): ensure a Stripe customer exists before checkout"
```

---

### Task 8: `CreateCheckoutSession`

**Files:**
- Create: `web-app/app/lib/services/billing/create_checkout_session.rb`
- Test: `web-app/test/lib/services/billing/create_checkout_session_test.rb`

**Interfaces:**
- Consumes: `BillingPlan` (existing model, `kind_membership?` / `kind_donation?` predicates), `EnsureCustomer` (Task 7 — called by the controller, not by this service).
- Produces: `Services::Billing::CreateCheckoutSession.call(plan:, success_url:, cancel_url:, user: nil, customer_id: nil, domain: nil)` → `Result` whose `data` is the session URL `String`. Constant `Services::Billing::StripeClient::ORIGIN_APP == "the-greatest"`.

**The three legacy-coexistence constraints are enforced here.** Read the Global Constraints section again before writing this file. The tests below are what stop them silently regressing.

The service takes fully-formed `success_url` / `cancel_url` strings so it stays free of routing and protocol concerns; the controller builds them from `request.host`.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/billing/create_checkout_session_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class CreateCheckoutSessionTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @monthly = billing_plans(:monthly)
        @donation = billing_plans(:donation)
        @urls = {success_url: "https://example.test/membership/thanks", cancel_url: "https://example.test/membership"}
      end

      test "returns the session url" do
        ::Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_test_123"))

        result = CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)

        assert result.success?
        assert_equal "https://checkout.stripe.com/c/pay/cs_test_123", result.data
      end

      test "every session carries top-level origin_app metadata" do
        # Load-bearing for legacy coexistence: the legacy books app reads this to
        # decide "not mine, skip". Without it a donation relies on legacy's
        # payment-link backstop alone, and the legacy log line stops saying why.
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_app: "the-greatest"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "a donation session also carries top-level origin_app metadata" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_app: "the-greatest"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :music, **@urls)
      end

      test "a subscription session tags the subscription itself" do
        # A subscription outlives its checkout session, and legacy's guard reads
        # the subscription's metadata on later customer.subscription.* events.
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entries(
            mode: "subscription",
            subscription_data: has_entry(metadata: has_entries(app_user_id: @user.id, origin_app: "the-greatest"))
          )
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "a donation session is payment mode with a donate button" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entries(mode: "payment", submit_type: "donate")
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls)
      end

      test "the price comes from the plan record, never from the caller" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(line_items: [{price: @monthly.stripe_price_id, quantity: 1}])
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls)
      end

      test "an anonymous donation creates no customer" do
        ::Stripe::Checkout::Session.expects(:create).with { |params| !params.key?(:customer) }
          .returns(stub(url: "https://checkout.stripe.com/x"))

        assert CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls).success?
      end

      test "the origin domain rides along so a receipt can be branded" do
        ::Stripe::Checkout::Session.expects(:create).with(
          has_entry(metadata: has_entry(origin_domain: "games"))
        ).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :games, **@urls)
      end

      test "a subscription plan without a signed-in user fails before calling Stripe" do
        ::Stripe::Checkout::Session.expects(:create).never

        refute CreateCheckoutSession.call(plan: @monthly, domain: :books, **@urls).success?
      end

      test "a Stripe failure is a failed Result, not an exception" do
        ::Stripe::Checkout::Session.expects(:create).raises(::Stripe::InvalidRequestError.new("no such price", "price"))

        refute CreateCheckoutSession.call(plan: @monthly, user: @user, customer_id: "cus_x", domain: :books, **@urls).success?
      end

      test "the service never calls the PaymentLink API" do
        # Legacy's structural guard is "this session carries no payment_link, so
        # it is not mine". A session created through a payment link would carry
        # one, the guard would never fire, and the donation defect it closes
        # would silently re-open.
        ::Stripe::PaymentLink.expects(:create).never
        ::Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/x"))

        CreateCheckoutSession.call(plan: @donation, domain: :books, **@urls)
      end
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/lib/services/billing/create_checkout_session_test.rb
```

- [ ] **Step 3: Implement**

Create `web-app/app/lib/services/billing/create_checkout_session.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Creates a Stripe Checkout Session for a membership plan or a donation.
    #
    # THREE THINGS IN HERE ARE LOAD-BEARING FOR LEGACY COEXISTENCE. The legacy
    # books app shares this Stripe account until books cuts over, and its webhook
    # handler decides whether an event is its own. Breaking any of these silently
    # re-opens a defect on the legacy side, with a 200 and no error anywhere:
    #
    #   1. Top-level metadata[origin_app] on EVERY session, both modes. A donation
    #      has no subscription to carry the tag.
    #   2. subscription_data[metadata][origin_app] on subscription-mode sessions,
    #      because the subscription outlives the session and later
    #      customer.subscription.* events carry only the subscription.
    #   3. Sessions are created through this API and NEVER through a Payment Link.
    #      Legacy's structural guard is "this session has no payment_link, so it
    #      is not mine"; a session made via a payment link carries one.
    #
    # See docs/specs/membership-and-stripe-billing.md, "Legacy coexistence".
    #
    # The caller passes a BillingPlan record, never a price id, an amount or a
    # user id from the request. A client that could name a price could name a
    # $0.01 one.
    class CreateCheckoutSession
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # One definition, on StripeClient (Task 6). Do not re-declare it here.
      ORIGIN_APP = StripeClient::ORIGIN_APP

      def self.call(plan:, success_url:, cancel_url:, user: nil, customer_id: nil, domain: nil)
        new(plan: plan, success_url: success_url, cancel_url: cancel_url,
          user: user, customer_id: customer_id, domain: domain).call
      end

      def initialize(plan:, success_url:, cancel_url:, user:, customer_id:, domain:)
        @plan = plan
        @success_url = success_url
        @cancel_url = cancel_url
        @user = user
        @customer_id = customer_id
        @domain = domain
      end

      def call
        return failure("plan is required") if @plan.nil?
        return failure("a membership requires a signed-in user") if @plan.kind_membership? && @user.nil?

        session = ::Stripe::Checkout::Session.create(session_params)
        success(session.url)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] checkout session failed for plan #{@plan&.key}: #{e.class}")
        failure(e.message)
      end

      private

      def session_params
        base = {
          line_items: [{price: @plan.stripe_price_id, quantity: 1}],
          success_url: @success_url,
          cancel_url: @cancel_url,
          metadata: {
            origin_app: ORIGIN_APP,
            origin_domain: @domain.to_s.presence,
            app_user_id: @user&.id
          }.compact
        }

        @plan.kind_membership? ? base.merge(subscription_params) : base.merge(donation_params)
      end

      def subscription_params
        {
          mode: "subscription",
          customer: @customer_id,
          client_reference_id: @user.id.to_s,
          subscription_data: {
            metadata: {app_user_id: @user.id, origin_app: ORIGIN_APP, origin_domain: @domain.to_s.presence}.compact
          }
        }
      end

      def donation_params
        params = {mode: "payment", submit_type: "donate"}
        # Anonymous donations are allowed and deliberately create no Customer --
        # Stripe collects the email at checkout. Attaching a customer we invented
        # for a one-off donor would pollute the account with rows the reconciler
        # then pages through every night.
        params[:customer] = @customer_id if @customer_id.present?
        params[:payment_intent_data] = {
          metadata: {origin_app: ORIGIN_APP, origin_domain: @domain.to_s.presence, app_user_id: @user&.id}.compact
        }
        params
      end

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/lib/services/billing/create_checkout_session_test.rb
```

Expected: PASS.

- [ ] **Step 5: Prove the metadata tests can fail**

Delete `origin_app: ORIGIN_APP` from the `metadata:` hash and re-run. Expected: two tests fail. Restore. Then delete `subscription_data:` and re-run. Expected: one test fails. Restore. These two assertions are the entire contract with the legacy app; a vacuous version of them is worse than none.

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/lib/services/billing/create_checkout_session.rb web-app/test/lib/services/billing/create_checkout_session_test.rb
git commit -m "feat(billing): create tagged checkout sessions through the API"
```

---

### Task 9: `CreatePortalSession`

**Files:**
- Create: `web-app/app/lib/services/billing/create_portal_session.rb`
- Test: `web-app/test/lib/services/billing/create_portal_session_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::Billing::CreatePortalSession.call(customer_id:, return_url:)` → `Result` whose `data` is the portal URL `String`.

This replaces legacy's hardcoded `billing.stripe.com/p/login/…` link, which is a shared login page rather than a per-customer session.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/billing/create_portal_session_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class CreatePortalSessionTest < ActiveSupport::TestCase
      test "returns the portal url" do
        ::Stripe::BillingPortal::Session.expects(:create).with(
          has_entries(customer: "cus_x", return_url: "https://example.test/members")
        ).returns(stub(url: "https://billing.stripe.com/p/session/live_abc"))

        result = CreatePortalSession.call(customer_id: "cus_x", return_url: "https://example.test/members")

        assert result.success?
        assert_equal "https://billing.stripe.com/p/session/live_abc", result.data
      end

      test "a blank customer id fails without calling Stripe" do
        ::Stripe::BillingPortal::Session.expects(:create).never

        refute CreatePortalSession.call(customer_id: "", return_url: "https://example.test/members").success?
      end

      test "a Stripe failure is a failed Result" do
        # The most likely one in practice: no portal configuration has been
        # activated for this account in this livemode yet.
        ::Stripe::BillingPortal::Session.expects(:create)
          .raises(::Stripe::InvalidRequestError.new("No configuration provided", "configuration"))

        refute CreatePortalSession.call(customer_id: "cus_x", return_url: "https://example.test/members").success?
      end
    end
  end
end
```

- [ ] **Step 2: Run, fail, implement**

Create `web-app/app/lib/services/billing/create_portal_session.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # A per-customer Billing Portal session -- cancel, update card, see invoices.
    #
    # Replaces the legacy app's hardcoded billing.stripe.com/p/login/... link,
    # which is a shared login page that asks the customer to type their email and
    # wait for a code. A session URL drops them straight into their own portal.
    #
    # Requires a portal CONFIGURATION activated on the Stripe account for the
    # current livemode. That is dashboard setup, not code -- see
    # docs/guides/stripe-account-setup.md. Without it Stripe raises
    # InvalidRequestError and this returns a failed Result.
    class CreatePortalSession
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(customer_id:, return_url:) = new(customer_id: customer_id, return_url: return_url).call

      def initialize(customer_id:, return_url:)
        @customer_id = customer_id
        @return_url = return_url
      end

      def call
        return failure("customer_id is required") if @customer_id.blank?

        session = ::Stripe::BillingPortal::Session.create(
          customer: @customer_id, return_url: @return_url
        )
        success(session.url)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] portal session failed: #{e.class}")
        failure(e.message)
      end

      private

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

- [ ] **Step 3: Test, suite, lint, commit**

```bash
bin/rails test test/lib/services/billing/create_portal_session_test.rb
bin/rails test
bundle exec standardrb
git add web-app/app/lib/services/billing/create_portal_session.rb web-app/test/lib/services/billing/create_portal_session_test.rb
git commit -m "feat(billing): open a per-customer Stripe billing portal session"
```

---

### Task 10: `RecordDonation` and the job that calls it

**Files:**
- Create: `web-app/app/lib/services/billing/record_donation.rb`
- Modify: `web-app/app/sidekiq/billing/process_stripe_event_job.rb`
- Test: `web-app/test/lib/services/billing/record_donation_test.rb`, `web-app/test/sidekiq/billing/process_stripe_event_job_test.rb`

**Interfaces:**
- Consumes: `Donation` (existing model), `StripeEvent#payload`.
- Produces: `Services::Billing::RecordDonation.call(checkout_session_id:)` → `Result` whose `data` is the `Donation` or `nil` when the session was not a completed one-off payment.

**Why the job has to change.** `ProcessStripeEventJob` today extracts a customer id and reconciles subscriptions. A donation is `mode: "payment"` and produces no subscription, and an **anonymous** donation has no customer at all — so today a donation event is marked `ignored` and no `Donation` row is ever written. Recording donations is part of increment 6, and this is the only place it can happen.

**Staying faithful to the design.** The event payload is still read for **identifiers only** — the checkout session id. The amount, the paid/unpaid status and the email are re-read from the Stripe API, exactly as `ReconcileCustomer` re-reads subscriptions. Deciding "is this a donation?" from the API response rather than from the stored payload costs one extra API call per `checkout.session.completed` and keeps the rule "no state is ever written from an event body" literally true.

Legacy's own donations are delivered to our endpoint too, and this will record them. That is intended: `stripe_payment_intent_id` is unique, so a webhook-recorded row and a migration-imported row converge instead of duplicating. Their `domain` is nil, which is correct — they did not come from one of our sites.

- [ ] **Step 1: Write the failing service test**

Create `web-app/test/lib/services/billing/record_donation_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class RecordDonationTest < ActiveSupport::TestCase
      def session_stub(overrides = {})
        stub({
          id: "cs_test_1",
          mode: "payment",
          payment_status: "paid",
          payment_intent: "pi_test_1",
          amount_total: 2500,
          currency: "usd",
          customer: nil,
          customer_details: stub(email: "donor@example.com"),
          client_reference_id: nil,
          metadata: {"origin_domain" => "books", "app_user_id" => nil}
        }.merge(overrides))
      end

      test "records a paid donation" do
        ::Stripe::Checkout::Session.expects(:retrieve).with("cs_test_1").returns(session_stub)

        result = RecordDonation.call(checkout_session_id: "cs_test_1")

        assert result.success?
        donation = result.data
        assert_equal 2500, donation.amount_cents
        assert_equal "succeeded", donation.status
        assert_equal "pi_test_1", donation.stripe_payment_intent_id
        assert_equal "donor@example.com", donation.email
        assert_equal "books", donation.domain
      end

      test "attaches the donation to a signed-in donor" do
        user = users(:regular_user)
        ::Stripe::Checkout::Session.expects(:retrieve)
          .returns(session_stub(metadata: {"origin_domain" => "books", "app_user_id" => user.id.to_s}))

        assert_equal user, RecordDonation.call(checkout_session_id: "cs_test_1").data.user
      end

      test "ignores a subscription-mode session" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(mode: "subscription"))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end
      end

      test "ignores a session that was not actually paid" do
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(payment_status: "unpaid"))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end
      end

      test "ignores a paid session with no payment intent rather than matching every nil row" do
        # find_or_initialize_by(stripe_payment_intent_id: nil) would match the
        # first legacy-imported row with a null intent and overwrite it.
        ::Stripe::Checkout::Session.expects(:retrieve).returns(session_stub(payment_intent: nil))

        assert_no_difference "Donation.count" do
          assert_nil RecordDonation.call(checkout_session_id: "cs_test_1").data
        end
      end

      test "recording the same session twice writes one row" do
        ::Stripe::Checkout::Session.expects(:retrieve).twice.returns(session_stub)

        RecordDonation.call(checkout_session_id: "cs_test_1")
        assert_no_difference "Donation.count" do
          RecordDonation.call(checkout_session_id: "cs_test_1")
        end
      end

      test "a Stripe failure is a failed Result" do
        ::Stripe::Checkout::Session.expects(:retrieve).raises(::Stripe::APIConnectionError.new("down"))

        refute RecordDonation.call(checkout_session_id: "cs_test_1").success?
      end
    end
  end
end
```

- [ ] **Step 2: Run, fail, implement the service**

Create `web-app/app/lib/services/billing/record_donation.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Writes a Donation row for a completed one-off payment.
    #
    # Takes only the checkout session ID from the event -- an identifier, never
    # state -- and re-reads the session from the Stripe API for the amount, the
    # paid status and the donor's email, exactly as ReconcileCustomer re-reads
    # subscriptions. That is why a replayed or out-of-order delivery converges
    # instead of double-counting.
    #
    # This also records donations the LEGACY books app takes, because both apps
    # share one Stripe account and both endpoints receive every event. That is
    # intended: stripe_payment_intent_id is unique, so a webhook-recorded row and
    # a migration-imported row converge rather than duplicating. Their domain is
    # nil, which is correct -- they did not come from one of our sites.
    class RecordDonation
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(checkout_session_id:) = new(checkout_session_id: checkout_session_id).call

      def initialize(checkout_session_id:)
        @checkout_session_id = checkout_session_id
      end

      def call
        return failure("checkout_session_id is required") if @checkout_session_id.blank?

        session = ::Stripe::Checkout::Session.retrieve(@checkout_session_id)

        return success(nil) unless session.mode == "payment"
        return success(nil) unless session.payment_status == "paid"

        payment_intent_id = session.payment_intent
        # Without an intent id there is no idempotency key, and
        # find_or_initialize_by(nil) would match the first row with a null intent
        # -- an imported legacy donation -- and overwrite it.
        return success(nil) if payment_intent_id.blank?

        donation = ::Donation.find_or_initialize_by(stripe_payment_intent_id: payment_intent_id)
        donation.assign_attributes(
          user: resolve_user(session),
          amount_cents: session.amount_total,
          currency: session.currency,
          status: :succeeded,
          stripe_checkout_session_id: session.id,
          email: session.customer_details&.email,
          domain: session.metadata&.[]("origin_domain")
        )
        donation.save!

        success(donation)
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] donation record failed for #{@checkout_session_id}: #{e.class}")
        failure(e.message)
      end

      private

      # Anonymous donations are allowed and stay unattached. Two paths, in the
      # same order the reconciler uses.
      def resolve_user(session)
        app_user_id = session.metadata&.[]("app_user_id").presence || session.client_reference_id.presence
        return ::User.find_by(id: app_user_id) if app_user_id

        ::User.find_by(stripe_customer_id: session.customer) if session.customer.present?
      end

      def success(data) = Result.new(success?: true, data: data, errors: [])

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

```bash
bin/rails test test/lib/services/billing/record_donation_test.rb
```

Expected: PASS.

- [ ] **Step 3: Write the failing job test**

Add to `web-app/test/sidekiq/billing/process_stripe_event_job_test.rb`:

```ruby
  test "a completed donation session is recorded even with no customer on the event" do
    event = stripe_events(:checkout_session_completed_donation)
    ::Stripe::Checkout::Session.expects(:retrieve).returns(
      stub(id: "cs_donation_1", mode: "payment", payment_status: "paid",
        payment_intent: "pi_donation_1", amount_total: 5000, currency: "usd",
        customer: nil, customer_details: stub(email: "anon@example.com"),
        client_reference_id: nil, metadata: {"origin_domain" => "books"})
    )

    Billing::ProcessStripeEventJob.new.perform(event.id)

    assert_equal "processed", event.reload.status
    assert Donation.exists?(stripe_payment_intent_id: "pi_donation_1")
  end

  test "an event with neither a donation nor a customer is still ignored" do
    event = stripe_events(:price_updated_no_customer)

    Billing::ProcessStripeEventJob.new.perform(event.id)

    assert_equal "ignored", event.reload.status
  end
```

Add the two fixtures to `web-app/test/fixtures/stripe_events.yml`, matching the shape of the existing entries (read the file first — `payload` is jsonb and must be a **native YAML mapping**, not a JSON string):

```yaml
checkout_session_completed_donation:
  stripe_event_id: evt_donation_1
  event_type: checkout.session.completed
  livemode: false
  api_version: "2026-07-29.dahlia"
  status: 0
  stripe_created_at: <%= 1.hour.ago.to_fs(:db) %>
  payload:
    id: evt_donation_1
    type: checkout.session.completed
    data:
      object:
        id: cs_donation_1
        object: checkout.session
        mode: payment

price_updated_no_customer:
  stripe_event_id: evt_price_1
  event_type: price.updated
  livemode: false
  api_version: "2026-07-29.dahlia"
  status: 0
  stripe_created_at: <%= 1.hour.ago.to_fs(:db) %>
  payload:
    id: evt_price_1
    type: price.updated
    data:
      object:
        id: price_abc
        object: price
```

`stripe_events` has `livemode` not-null and `Rails.configuration.stripe_livemode` must match for processing; the existing fixtures already pin `livemode: false` and the tests already pin the configuration — follow whatever the file does rather than introducing a second convention.

- [ ] **Step 4: Modify the job**

In `app/sidekiq/billing/process_stripe_event_job.rb`, replace `perform`:

```ruby
    def perform(stripe_event_id)
      event = StripeEvent.find(stripe_event_id)
      return unless event.received? || event.failed?

      # A donation has no subscription, and an anonymous one has no customer at
      # all, so it must be handled before the customer check below -- otherwise
      # every anonymous donation is marked "ignored" and never recorded.
      donation = record_donation(event)

      customer_id = event.stripe_customer_id_from_payload
      if customer_id.blank?
        if donation
          event.mark_processed!
        else
          event.mark_ignored!("no customer on event type #{event.event_type}")
        end
        return
      end

      result = Services::Billing::ReconcileCustomer.call(stripe_customer_id: customer_id)

      if result.success?
        event.mark_processed!
      else
        # Raise rather than returning: returning would tell Sidekiq the job
        # succeeded, leaving the membership stale until the nightly sweep -- up to
        # 24 hours for what is usually a seconds-long blip. The method's outer
        # rescue does the mark_failed! bookkeeping, so this branch must NOT call
        # it too, or attempts would increment twice for one execution.
        raise result.errors.join("; ")
      end
    rescue => e
      event&.mark_failed!(e)
      raise
    end

    private

    # Returns the Donation when one was written, nil otherwise. Reads only the
    # session id from the payload; everything else comes from a fresh API read.
    # A Stripe failure propagates so the outer rescue marks the event failed and
    # Sidekiq retries -- silently dropping a donation is not an option.
    def record_donation(event)
      return nil unless event.event_type == "checkout.session.completed"

      session_id = event.payload.dig("data", "object", "id")
      return nil if session_id.blank?

      result = Services::Billing::RecordDonation.call(checkout_session_id: session_id)
      raise result.errors.join("; ") unless result.success?

      result.data
    end
```

- [ ] **Step 5: Fix the permutation test's stubs — without weakening it**

The permutation test feeds `checkout.session.completed` through the real job, which now retrieves the session from Stripe. Add a stub in that test's setup so the call is satisfied, returning a **subscription-mode** session (which is what a membership checkout actually produces):

```ruby
    ::Stripe::Checkout::Session.stubs(:retrieve).returns(
      stub(id: "cs_membership_1", mode: "subscription", payment_status: "no_payment_required",
        payment_intent: nil, amount_total: 500, currency: "usd", customer: "cus_test",
        customer_details: stub(email: "member@example.com"), client_reference_id: nil, metadata: {})
    )
```

**Do not remove or relax a single assertion in that test.** It asserts that every ordering of the subscribe-time events converges on identical `Membership` state, and it is the one test that would catch a regression back to writing state from the payload. After the change, re-read it and confirm the final-state assertions are byte-for-byte what they were.

- [ ] **Step 6: Run the job tests, then the suite**

```bash
bin/rails test test/sidekiq/billing/process_stripe_event_job_test.rb
bin/rails test
bundle exec standardrb
```

- [ ] **Step 7: Prove the donation path can fail**

Comment out the `donation = record_donation(event)` line and re-run. Expected: the donation job test fails with the event `ignored` and no `Donation` row. Restore it.

- [ ] **Step 8: Commit**

```bash
git add web-app/app/lib/services/billing/record_donation.rb web-app/app/sidekiq/billing/process_stripe_event_job.rb web-app/test
git commit -m "feat(billing): record donations from completed checkout sessions"
```

---

### Task 11: The membership controller

**Files:**
- Modify: `web-app/app/controllers/membership_controller.rb` (created as a shell in Task 3)
- Create: `web-app/app/views/membership/thanks.html.erb`
- Test: `web-app/test/controllers/membership_controller_test.rb`

**Interfaces:**
- Consumes: `EnsureCustomer` (7), `CreateCheckoutSession` (8), `CreatePortalSession` (9), `ReconcileCustomer` (shipped), `User#member?` (1).
- Produces: the five actions behind the routes declared in Task 3.

**Rules this controller enforces**, each with a test below:

- Checkout accepts a plan **key** only. Never a price id, never an amount, never a user id from the client.
- `stripe_customer_id` is persisted **before** the redirect is issued.
- An existing member who hits checkout is sent to the portal instead of buying a second subscription.
- `/membership/thanks` grants nothing — it only re-reads Stripe — and is rate-limited.
- `/membership` renders with **zero** Stripe API calls.
- Every external redirect needs `allow_other_host: true`; Rails 8 blocks cross-host redirects by default and the failure is a 500, not a warning.

- [ ] **Step 1: Write the failing tests**

First, the setup block. The rate limit store in the test environment is a single
`ActiveSupport::Cache::MemoryStore` shared by the **whole test process** (see
`config/initializers/rate_limit_store.rb`), so counts accumulate across tests in
this file and a later test would start failing for a reason that has nothing to
do with what it asserts. `test/controllers/reviews_controller_test.rb` already
clears it in `setup`; do the same:

```ruby
  setup do
    host! Rails.application.config.domains[:books]
    Rails.application.config.x.rate_limit_store.clear
  end
```

Then add a test that the limit actually fires, since it is now a security control
rather than decoration:

```ruby
  test "checkout is rate limited" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.stubs(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    11.times { post membership_checkout_url, params: {plan: "monthly"} }

    assert_redirected_to membership_path
    assert_match(/Too many attempts/, flash[:alert])
  end
```

Replace `web-app/test/controllers/membership_controller_test.rb` with the Task 3 tests plus:

```ruby
  test "the page makes no Stripe api calls" do
    Stripe::Checkout::Session.expects(:create).never
    Stripe::Customer.expects(:create).never
    Stripe::Subscription.expects(:list).never

    get membership_url

    assert_response :success
  end

  test "checkout redirects a signed-in visitor to the stripe session" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Services::Billing::CreateCheckoutSession.expects(:call).returns(
      Services::Billing::CreateCheckoutSession::Result.new(
        success?: true, data: "https://checkout.stripe.com/c/pay/cs_1", errors: []
      )
    )

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_1"
  end

  test "checkout persists the stripe customer id before redirecting" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Stripe::Customer.expects(:create).returns(stub(id: "cus_brand_new"))
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_equal "cus_brand_new", user.reload.stripe_customer_id
  end

  test "checkout ignores a price id supplied by the client" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).with(
      has_entry(line_items: [{price: billing_plans(:monthly).stripe_price_id, quantity: 1}])
    ).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    post membership_checkout_url,
      params: {plan: "monthly", stripe_price_id: "price_one_cent", user_id: users(:regular_user).id}

    assert_response :redirect
  end

  test "checkout rejects an unknown plan key" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "free_forever"}

    assert_redirected_to membership_path
  end

  test "checkout rejects an inactive plan" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: billing_plans(:retired_monthly).key}

    assert_redirected_to membership_path
  end

  test "checkout rejects the donation plan key" do
    # The donation plan is kind: donation and must not be buyable as a membership.
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "donation"}

    assert_redirected_to membership_path
  end

  test "an existing member is sent to the portal instead of buying twice" do
    sign_in_as(users(:regular_user), stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never
    Stripe::BillingPortal::Session.expects(:create).returns(stub(url: "https://billing.stripe.com/p/session/x"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to "https://billing.stripe.com/p/session/x"
  end

  test "checkout requires sign in" do
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "monthly"}

    assert_response :redirect
    refute_match(/checkout\.stripe\.com/, response.location)
  end

  test "a donation does not require sign in" do
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    post membership_donate_url

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_donate"
  end

  test "a donation by a signed-out visitor creates no stripe customer" do
    Stripe::Customer.expects(:create).never
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    post membership_donate_url

    assert_response :redirect
  end

  test "the portal requires a stripe customer" do
    user = users(:editor_user) # comped: a member, but never billed
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Stripe::BillingPortal::Session.expects(:create).never

    post membership_portal_url

    assert_redirected_to membership_path
  end

  test "thanks reconciles the signed-in visitor's own customer" do
    user = users(:regular_user)
    user.update!(stripe_customer_id: "cus_regular")
    sign_in_as(user, stub_auth: true)
    Services::Billing::ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_regular").returns(
      Services::Billing::ReconcileCustomer::Result.new(success?: true, data: [], errors: [])
    )

    get membership_thanks_url

    assert_response :success
  end

  test "thanks grants nothing when hit directly by a non-member" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Services::Billing::ReconcileCustomer.expects(:call).never

    get membership_thanks_url

    assert_response :success
    refute user.reload.member?
  end

  test "thanks works for a signed-out visitor without reconciling anything" do
    Services::Billing::ReconcileCustomer.expects(:call).never

    get membership_thanks_url

    assert_response :success
  end

  test "a failed checkout session sends the visitor back with a message" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).raises(Stripe::APIConnectionError.new("down"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to membership_path
    assert flash[:alert].present?
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/controllers/membership_controller_test.rb
```

- [ ] **Step 3: Implement the controller**

Replace `web-app/app/controllers/membership_controller.rb`:

```ruby
# frozen_string_literal: true

# The join / support page and the three write actions behind it.
#
# Global route, per-domain layout, never edge-cached: the page renders
# differently for members and non-members, and it is low-traffic enough that
# no-store costs nothing.
#
# Nothing here accepts a price, an amount or a user id from the client. The only
# thing a request may name is a plan KEY, which is looked up against
# billing_plans; a client that could name a price could name a one-cent one.
class MembershipController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_signed_in!, only: [:checkout, :portal]

  # Declared AFTER require_signed_in! -- filters run in declaration order and
  # rate_limit installs its own before_action, so an anonymous request to
  # :checkout is already turned away before by: runs. Donations are deliberately
  # open to anonymous visitors, so they are bucketed by IP.
  #
  # The webhook endpoint is NOT rate limited anywhere: throttling it would mean
  # dropping legitimate Stripe deliveries.
  rate_limit to: 10, within: 1.minute,
    by: -> { current_user&.id || request.remote_ip },
    with: -> { redirect_to membership_path, alert: "Too many attempts just now. Please try again in a minute." },
    store: Rails.application.config.x.rate_limit_store,
    only: [:checkout, :donate, :portal, :thanks]

  # GET /membership
  def show
    @membership = current_user&.granting_membership
    @plans = BillingPlan.membership.active
    @donation_plan = BillingPlan.donation_price
  end

  # POST /membership/checkout
  def checkout
    # An existing member buying a second subscription would be billed twice and
    # would need both cancelling by hand. Send them where they can manage the
    # one they have.
    return portal if current_user.member?

    plan = BillingPlan.membership.active.find_by(key: params[:plan])
    return redirect_to(membership_path, alert: "That membership option is not available.") if plan.nil?

    customer = Services::Billing::EnsureCustomer.call(user: current_user)
    return redirect_to(membership_path, alert: checkout_error) unless customer.success?

    result = Services::Billing::CreateCheckoutSession.call(
      plan: plan,
      user: current_user,
      customer_id: customer.data,
      domain: Current.domain,
      success_url: membership_thanks_url(host: request.host),
      cancel_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    # allow_other_host is required: Rails blocks cross-host redirects by default
    # and raises rather than warning.
    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # POST /membership/donate -- deliberately open to anonymous visitors. Stripe
  # collects the email, and no Customer is created for a one-off donor.
  def donate
    plan = BillingPlan.donation_price
    return redirect_to(membership_path, alert: "Donations are unavailable right now.") if plan.nil?

    customer_id = if current_user
      result = Services::Billing::EnsureCustomer.call(user: current_user)
      result.success? ? result.data : nil
    end

    result = Services::Billing::CreateCheckoutSession.call(
      plan: plan,
      user: current_user,
      customer_id: customer_id,
      domain: Current.domain,
      success_url: membership_thanks_url(host: request.host),
      cancel_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # POST /membership/portal
  def portal
    customer_id = current_user.stripe_customer_id
    if customer_id.blank?
      return redirect_to membership_path,
        alert: "There is no billing account attached to your membership."
    end

    result = Services::Billing::CreatePortalSession.call(
      customer_id: customer_id, return_url: membership_url(host: request.host)
    )
    return redirect_to(membership_path, alert: checkout_error) unless result.success?

    redirect_to result.data, allow_other_host: true, status: :see_other
  end

  # GET /membership/thanks
  #
  # Grants NOTHING. It re-reads Stripe for the signed-in visitor's own customer
  # id so the page is truthful before the webhook lands -- a subscription that
  # does not exist in Stripe produces no membership here, and a visitor who
  # simply types this URL gets a thank-you page and no entitlement.
  def thanks
    @membership = current_user&.granting_membership
    return if current_user&.stripe_customer_id.blank?

    Services::Billing::ReconcileCustomer.call(stripe_customer_id: current_user.stripe_customer_id)
    @membership = current_user.granting_membership
  end

  private

  # One message for every failure mode. The specific Stripe error is logged by
  # the service; showing it to the visitor would leak request parameters that
  # Stripe echoes back in some error strings.
  def checkout_error
    "Something went wrong starting that payment. Please try again, and let us know if it keeps happening."
  end
end
```

- [ ] **Step 4: Write the thanks view**

Create `web-app/app/views/membership/thanks.html.erb`:

```erb
<% content_for :title, "Thank you" %>

<div class="container mx-auto max-w-2xl px-4 py-16 text-center">
  <h1 class="text-3xl font-bold mb-4">Thank you</h1>

  <% if @membership %>
    <p class="mb-6"><%= membership_status_sentence(@membership) %></p>
    <%= link_to "Go to the members' area", members_path, class: "btn btn-primary" %>
  <% else %>
    <p class="mb-6">
      Your payment is being confirmed. This can take a few seconds — reload this
      page, or check back shortly, and your membership will appear.
    </p>
    <%= link_to "Back to membership", membership_path, class: "btn btn-primary" %>
  <% end %>
</div>
```

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/controllers/membership_controller_test.rb
```

Expected: PASS.

- [ ] **Step 6: Prove the two security tests can fail**

Change `find_by(key: params[:plan])` to `find_by(stripe_price_id: params[:stripe_price_id])` and re-run: the "ignores a price id supplied by the client" test must fail. Restore. Then comment out `return portal if current_user.member?` and re-run: the double-purchase test must fail. Restore.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/controllers/membership_controller.rb web-app/app/views/membership web-app/test/controllers/membership_controller_test.rb
git commit -m "feat(billing): sell memberships and take donations through Checkout"
```

---

### Task 12: The membership page

**Files:**
- Modify: `web-app/app/views/membership/show.html.erb`
- Create: `web-app/app/views/membership/_story_books.html.erb`, `_story_music.html.erb`, `_story_games.html.erb`, `_story_default.html.erb`
- Modify: `web-app/app/helpers/membership_helper.rb`
- Test: `web-app/test/controllers/membership_controller_test.rb` (add render assertions), `web-app/test/helpers/membership_helper_test.rb`

**Interfaces:**
- Consumes: `@plans`, `@donation_plan`, `@membership` from Task 11.
- Produces: `MembershipHelper#membership_story_partial` → `String` partial path.

Per the product decision, **each site gets its own story.** Books keeps the 2009 text from the legacy `/support` page; music and games get their own. The drafts below are starting points — the copy is the owner's to edit, and editing it must not require touching Ruby.

Controller tests assert **behaviour**, not copy: assert that the right partial rendered and that plan amounts come from the database, never that a paragraph contains a particular sentence.

- [ ] **Step 1: Add the partial selector to the helper**

In `web-app/app/helpers/membership_helper.rb`:

```ruby
  # Each site tells its own story on the membership page. Falls back to a
  # site-neutral version rather than to any one site's story, so a new host
  # never renders someone else's history.
  STORY_DOMAINS = %w[books music games].freeze

  def membership_story_partial
    domain = Current.domain.to_s
    STORY_DOMAINS.include?(domain) ? "membership/story_#{domain}" : "membership/story_default"
  end
```

- [ ] **Step 2: Write the stories**

`web-app/app/views/membership/_story_books.html.erb` — the legacy text, unchanged:

```erb
<p>In 2009, I set out to find the best books ever written—only to discover that no single, definitive list existed. That realization led me to create The Greatest Books, a platform that aggregates and continuously updates the world's most acclaimed literature.</p>

<p>Over the years, I've refined the site through three major redesigns—driven by my passion for literature and the desire to build a reliable, ever-evolving resource. Currently, it's a one-person endeavor, but my dream is to work on The Greatest Books full time and eventually hire a dedicated team.</p>

<p>Your monetary support directly funds ongoing development, enhances the site's features, and keeps the list up-to-date. Thank you for being part of this literary journey!</p>
```

`web-app/app/views/membership/_story_music.html.erb`:

```erb
<p>Every "greatest albums" list disagrees with every other one, and almost none of them show their work. The Greatest Music started as an attempt to fix that: read hundreds of published lists—critics' polls, magazine rankings, readers' choices—and combine them into one ranking you can trace back to its sources.</p>

<p>It is built and run by one person, alongside sister sites for books and games. There are no ads, no investors, and nothing here is for sale except the membership on this page.</p>

<p>Your support pays for the servers, the data, and the time to keep the rankings growing. Thank you for listening along.</p>
```

`web-app/app/views/membership/_story_games.html.erb`:

```erb
<p>The Greatest Games began as a spreadsheet. I wanted to know which games are genuinely regarded as the best—not the best of one year, or the favourites of one magazine, but the ones that hold up across every list anyone has published.</p>

<p>That spreadsheet became this site: hundreds of ranked lists, aggregated and re-scored, with every source shown. It is built and run by one person, alongside sister sites for books and music.</p>

<p>Your support keeps it online and keeps the lists coming. Thank you for playing along.</p>
```

`web-app/app/views/membership/_story_default.html.erb`:

```erb
<p>The Greatest aggregates hundreds of published "best of" lists into rankings you can trace back to their sources, across books, music and games.</p>

<p>It is built and run by one person. There are no ads, no investors, and nothing here is for sale except the membership on this page.</p>

<p>Your support pays for the servers, the data, and the time to keep it growing.</p>
```

- [ ] **Step 3: Write the page**

Replace `web-app/app/views/membership/show.html.erb`:

```erb
<% content_for :title, "Support #{domain_settings[:name]}" %>

<div class="container mx-auto max-w-4xl px-4 py-10">
  <h1 class="text-3xl font-bold text-center mb-6">Support <%= domain_settings[:name] %></h1>

  <div class="prose max-w-none mb-12 [overflow-wrap:anywhere]">
    <%= render membership_story_partial %>
  </div>

  <h2 class="text-2xl font-semibold text-center mb-2">Membership</h2>

  <% if @membership %>
    <p class="text-center text-base-content/70 mb-8"><%= membership_status_sentence(@membership) %></p>

    <div class="flex flex-wrap justify-center gap-3 mb-16">
      <%= link_to "Members' area", members_path, class: "btn btn-primary" %>
      <% if @membership.source_stripe? %>
        <%= button_to "Manage billing", membership_portal_path, class: "btn btn-outline" %>
      <% end %>
    </div>
  <% else %>
    <p class="text-center text-base-content/70 mb-8">
      One membership covers The Greatest Books, Music and Games.
    </p>

    <div class="grid gap-6 md:grid-cols-2 mb-16">
      <% @plans.each do |plan| %>
        <div class="card bg-base-200 h-full">
          <div class="card-body">
            <h3 class="card-title justify-center"><%= plan.name %></h3>

            <p class="text-center my-4">
              <span class="text-4xl font-bold">$<%= number_with_precision(plan.amount_in_dollars, precision: plan.amount_cents.to_i % 100 == 0 ? 0 : 2) %></span>
              <span class="text-base-content/70">/<%= plan.interval %></span>
            </p>

            <ul class="space-y-2 mb-6">
              <li>Access to the members' area</li>
              <li>Every site — books, music and games</li>
              <li>You fund the site directly: no ads, no data selling, no investors</li>
              <li>More members' features as they ship</li>
            </ul>

            <div class="card-actions justify-center mt-auto">
              <% if signed_in? %>
                <%= button_to "Join #{plan.interval}", membership_checkout_path,
                      params: {plan: plan.key},
                      class: "btn btn-primary btn-lg",
                      data: {testid: "join-#{plan.key}"} %>
              <% else %>
                <button class="btn btn-primary btn-lg"
                        data-testid="join-<%= plan.key %>"
                        onclick="login_modal.showModal()">Join <%= plan.interval %></button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
  <% end %>

  <% if @donation_plan %>
    <div class="text-center">
      <h2 class="text-2xl font-semibold mb-3">Make a one-time donation</h2>
      <p class="mb-6 text-base-content/80">
        Prefer to give once rather than subscribe? Any amount helps, and you do
        not need an account.
      </p>
      <%= button_to "Donate", membership_donate_path,
            class: "btn btn-outline btn-lg",
            data: {testid: "donate"} %>
    </div>
  <% end %>
</div>
```

`login_modal.showModal()` is the existing sign-in modal used by every domain layout — confirm the id by grepping a layout for `login_modal` before relying on it.

Note the `<li>` items carry no icon: the legacy page used green check marks, and status/benefit meaning must not depend on colour.

- [ ] **Step 4: Add render assertions**

Add to `web-app/test/controllers/membership_controller_test.rb`:

`rails-controller-testing` is not in the Gemfile, so there is no `assert_template`. Assert through the rendered body instead, and keep each story assertion to **one short distinctive phrase** so an edit to the copy breaks at most one line:

```ruby
  # These three assert that the right STORY renders per host, not that the copy
  # says anything in particular. Each matches one short distinctive phrase; if
  # the copy is rewritten, update the phrase here and nothing else.
  test "the books host renders the books story" do
    host! Rails.application.config.domains[:books]

    get membership_url

    assert_match "In 2009", response.body
  end

  test "the music host renders the music story" do
    host! Rails.application.config.domains[:music]

    get membership_url

    assert_match "greatest albums", response.body
    assert_no_match(/In 2009/, response.body)
  end

  test "the games host renders the games story" do
    host! Rails.application.config.domains[:games]

    get membership_url

    assert_match "spreadsheet", response.body
    assert_no_match(/In 2009/, response.body)
  end

  test "an unrecognised host renders the site-neutral story, not another site's" do
    host! "unknown.example.com"

    get membership_url

    assert_response :success
    assert_no_match(/In 2009/, response.body)
  end

  test "plan prices come from the database" do
    billing_plans(:monthly).update!(amount_cents: 700)

    get membership_url

    assert_match "$7", response.body
  end

  test "an inactive plan is not offered" do
    get membership_url

    assert_no_match(/#{Regexp.escape(billing_plans(:retired_monthly).name)}/, response.body)
  end

  test "the page still renders when no plans are configured" do
    # Production reaches this state between the deploy and stripe:sync_plans, and
    # a 500 on /membership would be the first thing a visitor sees.
    BillingPlan.delete_all

    get membership_url

    assert_response :success
  end
```

The `assert_no_match(/In 2009/)` lines are what make the per-host assertions falsifiable: without them a partial selector that always returned the books story would pass every positive assertion.

- [ ] **Step 5: Run everything**

```bash
bin/rails test test/controllers/membership_controller_test.rb
bin/rails test test/lint/daisyui_v4_classes_test.rb
bin/rails test
bundle exec standardrb
```

- [ ] **Step 6: Look at the page in a browser on all three hosts**

```bash
yarn build:all
bin/rails server
```

Check the three hostnames from `config/initializers/domain_config.rb` (`dev-new.thegreatestbooks.org`, `dev.thegreatestmusic.org`, `dev.thegreatest.games`). Confirm the right story renders on each, the cards do not overflow on a narrow viewport, and the page reads correctly in both light and dark themes.

- [ ] **Step 7: Commit**

```bash
git add web-app/app/views/membership web-app/app/helpers/membership_helper.rb web-app/test
git commit -m "feat(billing): build the membership page with per-site stories"
```

---

### Task 13: Plan bootstrap, sync, and the two live-account writes

**Files:**
- Create: `web-app/app/lib/services/billing/sync_plans.rb`
- Create: `web-app/app/lib/services/billing/bootstrap_plans.rb`
- Create: `web-app/app/lib/services/billing/label_price.rb`
- Create: `web-app/lib/tasks/stripe.rake`
- Test: `web-app/test/lib/services/billing/sync_plans_test.rb`, `bootstrap_plans_test.rb`, `label_price_test.rb`

**Interfaces:**
- Consumes: `BillingPlan`, `Services::Billing::StripeClient`.
- Produces:
  - `Services::Billing::SyncPlans.call` → `Result`, `data` = `{resolved: Array<String>, failures: Array<String>}` (lookup keys).
  - `Services::Billing::BootstrapPlans.call` → `Result`, `data` = `Array<BillingPlan>`. Fails in livemode.
  - `Services::Billing::LabelPrice.call(price_id:, lookup_key:)` → `Result`, `data` = `{before: String|nil, after: String, unit_amount: Integer|nil, currency: String}`.
  - `Services::Billing::CreateDonationPrice.call(product_name:)` → `Result`, `data` = the Stripe price object.
  - Rake tasks `stripe:bootstrap`, `stripe:sync_plans`, `stripe:label_price[price_id,lookup_key]`, `stripe:create_donation_price`.

**The logic lives in services, not in the rake tasks.** There is no test anywhere in this repo that invokes a Rake task, and inventing that pattern for the four most dangerous operations in the subsystem is the wrong place to start. `lib/tasks/billing.rake`'s `verify_migration` → `Services::Billing::VerifyMigration` is the established shape: the service decides and returns a `Result`, the task prints it and sets the exit code.

Four operations with sharply different blast radii, so sharply different guards:

| Operation | Writes to Stripe | Allowed in livemode |
|---|---|---|
| `BootstrapPlans` | Creates products + prices | **No** — fails hard |
| `SyncPlans` | Nothing (reads) | Yes |
| `LabelPrice` | Adds a `lookup_key` to one named price | Yes, with typed confirmation at the task layer |
| `CreateDonationPrice` | Creates one new product + price | Yes, with typed confirmation at the task layer |

`BootstrapPlans` must refuse in livemode because it would create a **second** set of membership products in an account that already sells through legacy's. The whole "one membership, all sites" decision rests on the new app selling through those same prices, and after the fact there would be no way to tell which subscriber is on which product.

`LabelPrice` and `CreateDonationPrice` are additive and are the two live-account changes increment 6 genuinely needs. They are tasks rather than dashboard clicks so there is a record of exactly what changed.

- [ ] **Step 1: Write the failing service tests**

Create `web-app/test/lib/services/billing/sync_plans_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class SyncPlansTest < ActiveSupport::TestCase
      def price_stub(id:, unit_amount:, interval: nil)
        stub(id: id, unit_amount: unit_amount, currency: "usd",
          recurring: interval && stub(interval: interval))
      end

      test "resolves each plan's price id from its lookup key" do
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_monthly"]))
          .returns(stub(data: [price_stub(id: "price_resolved_monthly", unit_amount: 600, interval: "month")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_yearly"]))
          .returns(stub(data: [price_stub(id: "price_resolved_yearly", unit_amount: 5000, interval: "year")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["donation_custom"]))
          .returns(stub(data: [price_stub(id: "price_resolved_donation", unit_amount: nil)]))

        result = SyncPlans.call

        assert result.success?
        assert_equal "price_resolved_monthly", billing_plans(:monthly).reload.stripe_price_id
        assert_equal 600, billing_plans(:monthly).reload.amount_cents
        assert_equal "yearly", billing_plans(:yearly).reload.interval
      end

      test "a custom-amount donation price resolves with no amount and no interval" do
        # unit_amount is nil for a custom_unit_amount price, and that is correct:
        # the amount is whatever the donor types. Writing 0 here would render "$0"
        # on the membership page.
        ::Stripe::Price.stubs(:list).returns(stub(data: [price_stub(id: "price_x", unit_amount: nil)]))

        SyncPlans.call

        donation = billing_plans(:donation).reload
        assert_nil donation.amount_cents
        assert_nil donation.interval
      end

      test "an unresolvable lookup key fails the whole run and names it" do
        ::Stripe::Price.stubs(:list).returns(stub(data: []))

        result = SyncPlans.call

        refute result.success?
        assert_includes result.data[:failures], "membership_monthly"
      end

      test "an unresolvable key leaves the existing price id alone" do
        # Better a stale id than a nil one: a nil stripe_price_id violates the
        # model's presence validation and would raise on the next save.
        ::Stripe::Price.stubs(:list).returns(stub(data: []))
        before = billing_plans(:monthly).stripe_price_id

        SyncPlans.call

        assert_equal before, billing_plans(:monthly).reload.stripe_price_id
      end

      test "plans with no lookup key are skipped rather than failing the run" do
        billing_plans(:monthly).update!(stripe_lookup_key: nil)
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["membership_yearly"]))
          .returns(stub(data: [price_stub(id: "price_y", unit_amount: 5000, interval: "year")]))
        ::Stripe::Price.stubs(:list).with(has_entry(lookup_keys: ["donation_custom"]))
          .returns(stub(data: [price_stub(id: "price_d", unit_amount: nil)]))

        result = SyncPlans.call

        assert result.success?
        refute_includes result.data[:resolved], "membership_monthly"
      end

      test "a Stripe failure is a failed Result, not an exception" do
        ::Stripe::Price.stubs(:list).raises(::Stripe::APIConnectionError.new("down"))

        refute SyncPlans.call.success?
      end
    end
  end
end
```

Create `web-app/test/lib/services/billing/bootstrap_plans_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class BootstrapPlansTest < ActiveSupport::TestCase
      test "refuses to run in livemode and touches nothing" do
        # The production account already sells membership through the legacy books
        # app's products. A second set here would split subscribers across two
        # products with no way to tell afterwards which is which.
        Rails.application.config.stubs(:stripe_livemode).returns(true)
        ::Stripe::Product.expects(:create).never
        ::Stripe::Price.expects(:create).never

        result = BootstrapPlans.call

        refute result.success?
        assert_match(/livemode/i, result.errors.join)
      end

      test "creates products and prices and upserts the three plans in a sandbox" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_m", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_yearly"))
          .returns(stub(id: "price_y", unit_amount: 5000, currency: "usd", lookup_key: "membership_yearly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "donation_custom"))
          .returns(stub(id: "price_d", unit_amount: nil, currency: "usd", lookup_key: "donation_custom"))

        result = BootstrapPlans.call

        assert result.success?
        assert_equal "price_m", ::BillingPlan.find_by(key: "monthly").stripe_price_id
        assert_equal "price_d", ::BillingPlan.find_by(key: "donation").stripe_price_id
      end

      test "the donation price is a custom-amount price with a floor and a preset" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_m", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))
        ::Stripe::Price.stubs(:create).with(has_entry(lookup_key: "membership_yearly"))
          .returns(stub(id: "price_y", unit_amount: 5000, currency: "usd", lookup_key: "membership_yearly"))
        ::Stripe::Price.expects(:create).with(
          has_entry(custom_unit_amount: {enabled: true, minimum: 100, preset: 2500})
        ).returns(stub(id: "price_d", unit_amount: nil, currency: "usd", lookup_key: "donation_custom"))

        assert BootstrapPlans.call.success?
      end

      test "running twice does not duplicate plan rows" do
        Rails.application.config.stubs(:stripe_livemode).returns(false)
        ::Stripe::Product.stubs(:create).returns(stub(id: "prod_test"))
        ::Stripe::Price.stubs(:create).returns(stub(id: "price_any", unit_amount: 500, currency: "usd", lookup_key: "membership_monthly"))

        assert_no_difference "BillingPlan.where(key: %w[monthly yearly donation]).count" do
          BootstrapPlans.call
          BootstrapPlans.call
        end
      end
    end
  end
end
```

`Rails.configuration` and `Rails.application.config` are the same object, so stubbing either one works for code that reads the other. Note that the existing webhook tests deliberately never stub this — they read `Rails.configuration.stripe_livemode` and build the payload to match or mismatch it, so the test cannot silently pass because `.env` happened to set a particular value. Follow that pattern anywhere you can; stub it here only because this test needs to force the refusal branch, which no environment should ever be in.

Create `web-app/test/lib/services/billing/label_price_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class LabelPriceTest < ActiveSupport::TestCase
      test "writes the lookup key and reports the amount either side of the change" do
        # The amount is reported so "this is a label-only change" is something the
        # operator can SEE, not something the plan asserts.
        ::Stripe::Price.expects(:retrieve).with("price_live_x")
          .returns(stub(id: "price_live_x", lookup_key: nil, unit_amount: 500, currency: "usd", active: true))
        ::Stripe::Price.expects(:update).with("price_live_x", has_entry(lookup_key: "membership_monthly"))
          .returns(stub(id: "price_live_x", lookup_key: "membership_monthly", unit_amount: 500, currency: "usd", active: true))

        result = LabelPrice.call(price_id: "price_live_x", lookup_key: "membership_monthly")

        assert result.success?
        assert_nil result.data[:before]
        assert_equal "membership_monthly", result.data[:after]
        assert_equal 500, result.data[:unit_amount]
      end

      test "a blank price id fails without calling Stripe" do
        ::Stripe::Price.expects(:retrieve).never

        refute LabelPrice.call(price_id: "", lookup_key: "membership_monthly").success?
      end

      test "a blank lookup key fails without calling Stripe" do
        ::Stripe::Price.expects(:retrieve).never

        refute LabelPrice.call(price_id: "price_live_x", lookup_key: "").success?
      end

      test "refuses when the key is already on a different price" do
        # transfer_lookup_key is deliberately NOT passed, so Stripe rejects this.
        # Silently moving a lookup key off another price is how a production
        # checkout starts pointing at the wrong amount.
        ::Stripe::Price.stubs(:retrieve).returns(stub(id: "price_live_x", lookup_key: nil, unit_amount: 500, currency: "usd", active: true))
        ::Stripe::Price.stubs(:update).raises(::Stripe::InvalidRequestError.new("lookup_key already in use", "lookup_key"))

        refute LabelPrice.call(price_id: "price_live_x", lookup_key: "membership_monthly").success?
      end
    end
  end
end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/lib/services/billing/sync_plans_test.rb test/lib/services/billing/bootstrap_plans_test.rb test/lib/services/billing/label_price_test.rb
```

Expected: uninitialized constants.

- [ ] **Step 3: Implement the four services**

Create `web-app/app/lib/services/billing/sync_plans.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Re-resolves every billing_plan's Stripe price id from its lookup key,
    # against whichever Stripe account this environment is pointed at.
    #
    # This is what replaces the legacy app's hand-edited per-environment block in
    # config/stripe_products.yml. A lookup key is stable across accounts; a price
    # id is not.
    class SyncPlans
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        resolved = []
        failures = []

        ::BillingPlan.where.not(stripe_lookup_key: [nil, ""]).find_each do |plan|
          price = ::Stripe::Price.list(lookup_keys: [plan.stripe_lookup_key], active: true).data.first

          if price.nil?
            # Leave the existing id alone. Better a stale id than a nil one:
            # stripe_price_id has a presence validation, so nilling it would raise
            # on save and leave the plan half-updated.
            failures << plan.stripe_lookup_key
            next
          end

          plan.update!(
            stripe_price_id: price.id,
            # nil for a custom-amount donation price, which is correct -- the
            # amount is whatever the donor types. Writing 0 would render "$0".
            amount_cents: price.unit_amount,
            currency: price.currency,
            interval: price.recurring && ((price.recurring.interval == "year") ? :yearly : :monthly)
          )
          resolved << plan.stripe_lookup_key
        end

        data = {resolved: resolved, failures: failures}
        return Result.new(success?: true, data: data, errors: []) if failures.empty?

        # Loud, never silent: a plan pointing at a price that does not exist in
        # this account produces "No such price" at the checkout redirect, which
        # the visitor sees and nobody else does.
        Result.new(success?: false, data: data,
          errors: ["could not resolve: #{failures.join(", ")}"])
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] plan sync failed: #{e.class}")
        Result.new(success?: false, data: {resolved: [], failures: []}, errors: [e.message])
      end
    end
  end
end
```

Create `web-app/app/lib/services/billing/create_donation_price.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # One custom-amount price, replacing the legacy app's eight fixed donation
    # prices and eight payment links.
    #
    # Stripe's documented limits on a custom_unit_amount price -- one line item,
    # quantity 1, no promotion codes, not recurring -- are all fine for a
    # donation. Safe to run against the live account: it creates a new product
    # and price and touches nothing existing.
    class CreateDonationPrice
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      LOOKUP_KEY = "donation_custom"
      MINIMUM_CENTS = 100
      PRESET_CENTS = 2500

      def self.call(product_name: "Donation to The Greatest") = new(product_name: product_name).call

      def initialize(product_name:)
        @product_name = product_name
      end

      def call
        product = ::Stripe::Product.create(name: @product_name)
        price = ::Stripe::Price.create(
          product: product.id,
          currency: "usd",
          custom_unit_amount: {enabled: true, minimum: MINIMUM_CENTS, preset: PRESET_CENTS},
          lookup_key: LOOKUP_KEY,
          nickname: "Custom donation"
        )

        Result.new(success?: true, data: price, errors: [])
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] donation price creation failed: #{e.class}")
        Result.new(success?: false, data: nil, errors: [e.message])
      end
    end
  end
end
```

Create `web-app/app/lib/services/billing/bootstrap_plans.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Creates membership and donation products/prices in a SANDBOX and seeds
    # billing_plans to match. A local-development and disaster-recovery tool.
    class BootstrapPlans
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      LOOKUP_KEYS = {
        "monthly" => "membership_monthly",
        "yearly" => "membership_yearly",
        "donation" => CreateDonationPrice::LOOKUP_KEY
      }.freeze

      def self.call = new.call

      def call
        # Refuses in livemode, hard. The production account already sells
        # membership through the legacy books app's products, and the whole "one
        # membership, all sites" decision rests on the new app selling through
        # those SAME prices. Creating a second set here would split subscribers
        # across two products with no way to tell them apart afterwards.
        if Rails.configuration.stripe_livemode
          return failure(
            "refusing to bootstrap: STRIPE_LIVEMODE is true and this is a sandbox-only tool. " \
            "Production plans point at the legacy account's existing prices -- see " \
            "docs/guides/stripe-account-setup.md."
          )
        end

        membership = ::Stripe::Product.create(
          name: "The Greatest Membership",
          description: "Membership across The Greatest Books, Music and Games"
        )

        monthly = ::Stripe::Price.create(
          product: membership.id, currency: "usd", unit_amount: 500,
          recurring: {interval: "month"}, lookup_key: LOOKUP_KEYS["monthly"],
          nickname: "Monthly membership"
        )

        yearly = ::Stripe::Price.create(
          product: membership.id, currency: "usd", unit_amount: 5000,
          recurring: {interval: "year"}, lookup_key: LOOKUP_KEYS["yearly"],
          nickname: "Yearly membership"
        )

        donation = CreateDonationPrice.call
        return failure(donation.errors.join("; ")) unless donation.success?

        plans = [
          upsert(key: "monthly", name: "Monthly Membership", kind: :membership, interval: :monthly, price: monthly, position: 0),
          upsert(key: "yearly", name: "Yearly Membership", kind: :membership, interval: :yearly, price: yearly, position: 1),
          upsert(key: "donation", name: "One-time Donation", kind: :donation, interval: nil, price: donation.data, position: 2)
        ]

        Result.new(success?: true, data: plans, errors: [])
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] bootstrap failed: #{e.class}")
        failure(e.message)
      end

      private

      # find_or_initialize_by on the natural key, so re-running is a no-op rather
      # than a duplicate -- the same rule the DataImporters follow.
      def upsert(key:, name:, kind:, interval:, price:, position:)
        plan = ::BillingPlan.find_or_initialize_by(key: key)
        plan.update!(
          name: name, kind: kind, interval: interval, position: position,
          stripe_price_id: price.id, stripe_lookup_key: price.lookup_key,
          amount_cents: price.unit_amount, currency: price.currency, active: true
        )
        plan
      end

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

Create `web-app/app/lib/services/billing/label_price.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Billing
    # Writes a lookup_key onto an existing Stripe price.
    #
    # This is how the two LIVE membership prices -- the ones the legacy books app
    # already sells through -- become resolvable by SyncPlans. A lookup key is a
    # label: it does not change the amount, the billing interval, or anything
    # about an existing subscriber. The Result reports the amount either side of
    # the change so that is verifiable rather than merely asserted.
    #
    # transfer_lookup_key is deliberately NOT passed. Without it, Stripe refuses
    # when the key is already on another price; with it, Stripe would silently
    # move the key, and a production checkout would start pointing at whatever
    # price inherited it.
    class LabelPrice
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(price_id:, lookup_key:) = new(price_id: price_id, lookup_key: lookup_key).call

      def initialize(price_id:, lookup_key:)
        @price_id = price_id
        @lookup_key = lookup_key
      end

      def call
        return failure("price_id is required") if @price_id.blank?
        return failure("lookup_key is required") if @lookup_key.blank?

        before = ::Stripe::Price.retrieve(@price_id)
        after = ::Stripe::Price.update(@price_id, lookup_key: @lookup_key)

        Result.new(
          success?: true,
          data: {
            price_id: after.id,
            before: before.lookup_key,
            after: after.lookup_key,
            unit_amount: after.unit_amount,
            currency: after.currency,
            active: after.active
          },
          errors: []
        )
      rescue ::Stripe::StripeError => e
        Rails.logger.error("[billing] labelling #{@price_id} failed: #{e.class}")
        failure(e.message)
      end

      private

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])
    end
  end
end
```

- [ ] **Step 4: Run the service tests**

```bash
bin/rails test test/lib/services/billing/sync_plans_test.rb test/lib/services/billing/bootstrap_plans_test.rb test/lib/services/billing/label_price_test.rb
```

Expected: PASS.

- [ ] **Step 5: Prove the livemode refusal can fail**

Comment out the `if Rails.configuration.stripe_livemode` guard in `BootstrapPlans` and re-run. Expected: the refusal test fails. Restore it. This guard is the one standing between a mistyped command and a duplicate set of membership products in the live account.

- [ ] **Step 6: Write the thin rake wrappers**

Create `web-app/lib/tasks/stripe.rake`, following the shape of `lib/tasks/billing.rake` exactly — print the `Result`, `exit 1` on failure, no logic:

```ruby
# frozen_string_literal: true

namespace :stripe do
  desc "Create membership and donation products/prices in a SANDBOX and seed billing_plans"
  task bootstrap: :environment do
    result = Services::Billing::BootstrapPlans.call

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "Sandbox bootstrapped:"
    result.data.each { |plan| puts "  #{plan.key.ljust(10)} #{plan.stripe_price_id}  (#{plan.stripe_lookup_key})" }
  end

  desc "Re-resolve every billing_plan's Stripe price from its lookup key"
  task sync_plans: :environment do
    result = Services::Billing::SyncPlans.call

    result.data[:resolved].each { |key| puts "resolved #{key}" }

    unless result.success?
      warn "FAILED to resolve: #{result.data[:failures].join(", ")}"
      warn "Each membership plan needs its lookup_key written onto the live price first:"
      warn "  CONFIRM=label-price bin/rails 'stripe:label_price[price_xxx,membership_monthly]'"
      exit 1
    end

    puts "All plans resolved."
  end

  desc "Write a lookup_key onto an existing Stripe price: stripe:label_price[price_id,lookup_key]"
  task :label_price, [:price_id, :lookup_key] => :environment do |_t, args|
    unless ENV["CONFIRM"] == "label-price"
      warn "REFUSING: re-run with CONFIRM=label-price to write a lookup key onto a live price."
      warn "This is a label-only change -- it does not affect the amount, the billing"
      warn "interval, or any existing subscriber -- but it does write to the live account."
      exit 1
    end

    result = Services::Billing::LabelPrice.call(price_id: args[:price_id], lookup_key: args[:lookup_key])

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "price:      #{result.data[:price_id]}"
    puts "lookup_key: #{result.data[:before].inspect} -> #{result.data[:after].inspect}"
    puts "amount:     #{result.data[:unit_amount]} #{result.data[:currency]} (unchanged), active=#{result.data[:active]}"
  end

  desc "Create the custom-amount donation price (safe in livemode: purely additive)"
  task create_donation_price: :environment do
    unless ENV["CONFIRM"] == "create-donation-price"
      warn "REFUSING: re-run with CONFIRM=create-donation-price."
      exit 1
    end

    result = Services::Billing::CreateDonationPrice.call

    unless result.success?
      warn "FAILED: #{result.errors.join("; ")}"
      exit 1
    end

    puts "price: #{result.data.id}  (lookup_key #{result.data.lookup_key})"
    puts "Now run: bin/rails stripe:sync_plans"
  end
end
```

- [ ] **Step 7: Run bootstrap against the real sandbox**

Local dev is already on a sandbox with `STRIPE_LIVEMODE=false`.

```bash
bin/rails stripe:bootstrap
bin/rails stripe:sync_plans
```

Confirm three `billing_plans` rows exist with real sandbox price ids. This is what makes the Playwright tests in Task 15 able to reach `checkout.stripe.com`. Then confirm the guard works for real:

```bash
STRIPE_LIVEMODE=true bin/rails stripe:bootstrap   # must refuse and exit 1
```

That command is safe to run: the guard is checked before the first Stripe call, and the sandbox key would be rejected by the boot guard in any case.

- [ ] **Step 8: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
git add web-app/app/lib/services/billing web-app/lib/tasks/stripe.rake web-app/test/lib/services/billing
git commit -m "feat(billing): bootstrap, sync and label Stripe prices"
```
### Task 14: Documentation and the Stripe-side runbook

**Files:**
- Create: `docs/guides/stripe-account-setup.md` (project root)
- Modify: `docs/features/membership-billing.md`
- Modify: `docs/specs/membership-and-stripe-billing.md` (increments table, acceptance criteria)
- Modify: `deployment/ENV.md`

**Interfaces:** none — documentation.

None of this is code, and all of it is on the critical path: increment 6 cannot reach production until the Stripe account has been set up by hand, and nothing in the codebase can do that.

- [ ] **Step 1: Write the runbook**

Create `docs/guides/stripe-account-setup.md` covering, in order:

1. **Prerequisite — the legacy guard must already be live.** It shipped 2026-08-16 (`the-greatest-books#7`). Confirm before the first live sale: `thegreatestbooks.org` renders, a resent `customer.subscription.updated` shows `processed` in legacy's admin webhook-events, and the `ignored` rows there read as expected.
2. **Register two webhook endpoints** in the live account:
   - `https://thegreatestmusic.org/webhooks/stripe`
   - `https://thegreatest.games/webhooks/stripe`
   Events: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.paused`, `customer.subscription.resumed`, `invoice.paid`, `invoice.payment_failed`.
   Note that both endpoints receive **every** event, so each one is delivered twice; the unique index on `stripe_events.stripe_event_id` makes the second a 200 with no reprocessing.
   Copy **both** signing secrets into `STRIPE_WEBHOOK_SECRET` as a comma-separated list.
3. **Cloudflare.** Both hosts sit behind Cloudflare, and a managed challenge answers a POST with a bare 403 that Stripe records as a failed delivery. Add a WAF skip rule for `/webhooks/stripe` on both hostnames before registering the endpoints. Verify with the Stripe Dashboard's "Send test webhook" and confirm a 200, not a 403.
4. **Write the lookup keys onto the two live membership prices** — the ones legacy already sells through:
   ```
   membership monthly -> price_1QvpHqEAWBHYHNGXLPrsxZ0v  (prod_RpUGlPnfnCbn4m)
   membership yearly  -> price_1QvpHtEAWBHYHNGXQfQpB9tL  (prod_RpUGy8T59mpSdR)
   ```
   ```bash
   CONFIRM=label-price bin/rails 'stripe:label_price[price_1QvpHqEAWBHYHNGXLPrsxZ0v,membership_monthly]'
   CONFIRM=label-price bin/rails 'stripe:label_price[price_1QvpHtEAWBHYHNGXQfQpB9tL,membership_yearly]'
   ```
   A `lookup_key` is a label. It does not change the amount, the interval, or anything about an existing subscriber. The task prints the amount before and after so that is verifiable rather than asserted.
5. **Create the live donation price:**
   ```bash
   CONFIRM=create-donation-price bin/rails stripe:create_donation_price
   ```
   This creates a **new** product and price. Legacy reads its own eight donation price ids from `config/stripe_products.yml` and is unaffected.
6. **Seed and resolve the production plans:** create the three `billing_plans` rows, then `bin/rails stripe:sync_plans` and confirm all three resolve.
7. **Activate a Billing Portal configuration** in the live account (Settings → Billing → Customer portal). Without one, `Stripe::BillingPortal::Session.create` raises and "Manage billing" fails for every member. Do the same in the sandbox.
8. **Post-deploy verification**, each with what "good" looks like:
   - `/membership` renders on all three hosts and shows $5 and $50 from the database.
   - A real sandbox purchase end to end, then `/members` opens.
   - The `stripe_events` admin screen shows the events as `processed`, twice-delivered ones as one row.
   - Legacy's admin webhook-events shows our events as `ignored` with the origin_app reason.
   - `bin/rails billing:verify_migration` still reports all invariants holding.
9. **Rollback.** What to do if it goes wrong: disable both endpoints in the Stripe Dashboard (events queue for 72 hours and the nightly `billing:reconcile_all` is the backstop), and revert the deploy. **Do not run `rake stripe:delete_webhooks` on legacy** — it was scoped in the guard patch, but on any un-patched checkout it deletes every endpoint in the account, including ours.

- [ ] **Step 2: Update the subsystem doc**

In `docs/features/membership-billing.md`, add sections for: the entitlement rules and where they live (`Membership.granting_access`, `User#member?`), `MembershipGate` and how to put something behind the paywall, the checkout flow end to end, the two-endpoint webhook setup and why `STRIPE_WEBHOOK_SECRET` is a list, and the donation recording path through `ProcessStripeEventJob`. Cross-link the runbook.

- [ ] **Step 3: Update the spec**

In `docs/specs/membership-and-stripe-billing.md`: mark increments 6, 7 and 11 done in the table; tick the acceptance criteria this branch satisfies; add anything found during implementation to "Carried forward". Do not tick a criterion the tests do not actually cover — the two already marked `[x]` carry an explicit note about being verified against live data instead, and that honesty is the point.

- [ ] **Step 4: Commit**

```bash
git add docs deployment/ENV.md
git commit -m "docs(billing): document checkout, entitlements and the Stripe account setup"
```

---

## Phase C — Increment 11: E2E

### Task 15: Playwright coverage

**Files:**
- Create: `web-app/e2e/tests/books/membership.spec.ts`
- Create: `web-app/e2e/tests/books/account/membership.spec.ts`
- Create: `web-app/e2e/tests/music/public/membership.spec.ts`
- Create: `web-app/e2e/tests/games/public/membership.spec.ts`

**Interfaces:** consumes everything above.

The project layout in `e2e/playwright.config.ts` decides which spec is signed in:

| Project | Host | Signed in? | testMatch |
|---|---|---|---|
| `books` | `dev-new.thegreatestbooks.org` | no | `books/` excluding `admin/` and `account/` |
| `books-account` | same | yes | `books/account/` |
| `chromium` | `dev.thegreatestmusic.org` | yes | `music/` |
| `games` | `dev.thegreatest.games` | yes | `games/` |

So signed-out coverage goes in `books/`, and signed-in coverage in `books/account/`.

**Scope boundary:** these tests stop at the redirect to `checkout.stripe.com`. Completing a purchase is manual sandbox verification (runbook step 8) — driving Stripe's hosted checkout from Playwright tests Stripe's UI, not ours.

**Not covered here, on purpose:** the members'-area view for an actual member. The E2E user is not a member, and comping them from a spec would leave shared dev state behind that later runs depend on. That case is covered by `MembersControllerTest`, where a fixture makes it exact.

- [ ] **Step 1: Make sure the plans resolve locally**

```bash
bin/rails stripe:sync_plans
```

Without this the page renders no plan cards and every test below fails for the wrong reason.

- [ ] **Step 2: Write the signed-out books spec**

Create `web-app/e2e/tests/books/membership.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books membership page', () => {
  test('the page renders with both plans', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByRole('heading', { level: 1, name: /Support The Greatest Books/i })).toBeVisible();
    await expect(page.getByTestId('join-monthly')).toBeVisible();
    await expect(page.getByTestId('join-yearly')).toBeVisible();
  });

  test('the books story is the one that renders', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByText(/In 2009/)).toBeVisible();
  });

  test('a signed-out visitor gets the sign-in modal instead of checkout', async ({ page }) => {
    await page.goto('/membership');
    await page.getByTestId('join-monthly').click();

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.locator('#login_modal')).toBeVisible();
  });

  test('the members area redirects a signed-out visitor to the membership page', async ({ page }) => {
    await page.goto('/members');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/Sign in to your membership/i)).toBeVisible();
  });

  test('the legacy support url lands on the membership page', async ({ page }) => {
    await page.goto('/support');

    await expect(page).toHaveURL(/\/membership$/);
  });

  test('a donation can be started without an account', async ({ page }) => {
    await page.goto('/membership');
    await page.getByTestId('donate').click();

    await expect(page).toHaveURL(/checkout\.stripe\.com/, { timeout: 20_000 });
  });
});
```

Confirm the sign-in modal's selector against a layout (`grep -n "login_modal" app/views/layouts/books/application.html.erb`) and the alert's rendered location (it may be a toast component rather than inline text) before relying on either.

- [ ] **Step 3: Write the signed-in books spec**

Create `web-app/e2e/tests/books/account/membership.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books membership, signed in', () => {
  test('a signed-in non-member is redirected away from the members area', async ({ page }) => {
    await page.goto('/members');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/That page is for members/i)).toBeVisible();
  });

  test('joining redirects to Stripe checkout', async ({ page }) => {
    await page.goto('/membership');
    await page.getByTestId('join-monthly').click();

    await expect(page).toHaveURL(/checkout\.stripe\.com/, { timeout: 20_000 });
  });

  test('the thanks page renders without granting anything', async ({ page }) => {
    await page.goto('/membership/thanks');

    await expect(page.getByRole('heading', { level: 1, name: /Thank you/i })).toBeVisible();

    await page.goto('/members');
    await expect(page).toHaveURL(/\/membership$/);
  });
});
```

That last test is the E2E form of the "thanks grants nothing when hit directly" acceptance criterion, and it is worth having in both layers: the integration test proves the code path, this proves it through a real browser session.

- [ ] **Step 4: Write the music and games specs**

Create `web-app/e2e/tests/music/public/membership.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Music membership page', () => {
  test('the page renders with the music story and both plans', async ({ page }) => {
    await page.goto('/membership');

    await expect(page.getByRole('heading', { level: 1, name: /Support The Greatest Music/i })).toBeVisible();
    await expect(page.getByText(/greatest albums/i)).toBeVisible();
    await expect(page.getByTestId('join-monthly')).toBeVisible();
    await expect(page.getByTestId('join-yearly')).toBeVisible();
  });

  test('the members link is not shown to a non-member', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_members')).toHaveClass(/hidden/);
  });
});
```

Create `web-app/e2e/tests/games/public/membership.spec.ts` with the same two tests, changing the heading to `/Support The Greatest Games/i` and the story text to `/spreadsheet/i`.

- [ ] **Step 5: Run the suite**

```bash
yarn build:all
bin/rails server
```

In a second shell:

```bash
yarn test:e2e
```

If the admin/account specs time out on the public homepage, the E2E user has lost its role from a reseed — `bin/rails e2e:admin` fixes it. Check what is actually serving port 3000 first; another worktree may own it, which would silently invalidate the whole run.

- [ ] **Step 6: Commit**

```bash
git add web-app/e2e
git commit -m "test(billing): cover membership and the members area with Playwright"
```

---

## Final verification

- [ ] `bin/rails test` — expect **at least** 6768 runs, 0 failures, 0 errors (the count rises with the new tests)
- [ ] `bundle exec standardrb`
- [ ] `bin/rails test test/lint/daisyui_v4_classes_test.rb` green with an empty allowlist
- [ ] `yarn test:e2e`
- [ ] `git diff main --stat` reviewed — no `schema.rb` changes from another worktree's migrations sneaking in (a worktree isolates files, not the database; always diff `schema.rb` before pushing)
- [ ] `docs/specs/membership-and-stripe-billing.md` increments table updated
- [ ] `docs/guides/stripe-account-setup.md` complete, and the Stripe-side steps in it actually run against the sandbox

## Review focus

Aim the reviews at these, not only at the code:

**Threat model.** Can a request name a price, an amount, or another user's id and have it honoured? Can `/membership/thanks` grant anything? Is there any path that verifies a webhook signature against a value present in this public repository? Is a Stripe payload ever written to a log or to `stripe_events.error`? Is the webhook endpoint rate-limited (it must not be)? Does an error message shown to a visitor echo anything Stripe sent back?

**Deploy pipeline.** This branch adds no migration, which removes the crash-loop hazard — confirm that is still true at review time. `bin/docker-entrypoint` is `bash -e` and runs `db:prepare` before `exec`ing the server, so a raising migration takes all four sites down; the worker container never migrates at all. Does anything in this branch require an ENV var that is not yet in SOPS (`STRIPE_WEBHOOK_SECRET` gains a second value)? Does the app still boot with Stripe entirely unconfigured — and is `StripeClient`'s comment claiming "nothing in this app serves a page from Stripe" now **false**, since `/membership` reads `billing_plans` and `/membership/checkout` calls the API? What does `/membership` render when `billing_plans` is empty?

**Legacy coexistence.** Every Checkout Session carries top-level `metadata[origin_app]`; every subscription-mode session also tags the subscription; nothing anywhere calls the PaymentLink API. Are those three facts asserted by tests that would actually fail if the code were deleted?
