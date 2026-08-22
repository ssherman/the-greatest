# Membership Emails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send the eight membership emails — four to customers, four to the site owner — on the Stripe events that already drive the reconciler, without ever double-emailing a member the legacy app is still emailing.

**Architecture:** The reconciler already rebuilds `memberships` from Stripe on every relevant event. This
increment captures the *status transition* that reconcile currently discards, hands it to a
`MembershipNotifier` service that decides which mail (if any) is owed, and sends it with
`deliver_later`. Two guards make it safe: per-membership timestamp columns
(`welcome_email_sent_at`, `ended_email_sent_at`) that already exist, and an **ownership gate** — this
app emails only about memberships and donations it sold, because the legacy books app is still live
on the same Stripe account and still emailing its own. A config switch flips that gate at legacy
cutover.

**Tech Stack:** Rails 8.1, ActionMailer over SendGrid SMTP (shipped in increment 5), Sidekiq via
ActiveJob, Minitest + Mocha, standardrb.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — increment 8 in the Increments table, and the
"Email" subsection of Architecture. The mail foundation it builds on is `docs/features/email.md`.

## Global Constraints

- **No migration.** Every column this needs already exists: `memberships.origin_domain`,
  `memberships.welcome_email_sent_at`, `memberships.ended_email_sent_at`, `donations.domain`,
  `donations.email`. Verified against `db/schema.rb`. If you believe you need a migration, stop and
  report — a raising migration crash-loops the web container and 502s all four sites.
- **Every mailer takes a domain explicitly and calls `branded_mail`, never `mail`.** Mailers run in
  Sidekiq where `Current.domain` is nil; reading `Current` sends books-branded mail to a music
  subscriber, silently. See `docs/features/email.md`.
- **Never pass a raw email address as a job argument.** ActiveJob logs arguments and
  `config.filter_parameters` does not reach them. Pass the `Membership` or `Donation` — ActiveJob
  serialises a GlobalID. (`MailDeliveryJob.log_arguments = false` is already set, but the rule holds:
  a GlobalID is also smaller and always current.)
- **Never log an email body, a recipient address, or a delivery exception message.** This repo is
  public.
- **Secrets are ENV vars** (SOPS-managed), never `Rails.application.credentials`.
- **Skinny models, fat services.** Business logic goes in `app/lib/services/billing/`; mailers hold
  only what a mailer holds. Jobs live in `app/sidekiq/`, never `app/jobs/`.
- **Rails 8 enum syntax**: `enum :status, {active: 1}` with a colon.
- **The linter is `bundle exec standardrb`**, not rubocop. `bin/rails test` must be green.
- **Run all commands from `web-app/`.** Docs live in `docs/` at the project root.
- **Do not run destructive database commands.** The development database holds books data that
  exists nowhere else and takes hours to rebuild.

## Decisions already made (do not relitigate)

Both were decided by the project owner on 2026-08-21:

1. **Customer email: only what this app sold**, with a switch to flip at legacy cutover. Legacy keeps
   emailing its own subscribers until it is retired.
2. **Admin notifications: only what this app sold**, for the same reason — otherwise every legacy sale
   produces two notices.

---

## Background: why the ownership gate is the crux

Both apps share one Stripe account, and **every webhook endpoint receives every event on the
account**. The new app therefore reconciles legacy's subscriptions into `memberships` — deliberately,
because that is how it knows about existing members.

Legacy's own guard (`stripe_coexistence_guard`) already stops legacy from emailing about *this app's*
sales: it skips any event whose `metadata[origin_app] == "the-greatest"`. That direction is solved.

The unsolved direction is this one: without a gate, this app would email legacy's subscribers about
events legacy is already emailing them about. Two welcome emails for one subscription.

**The signal is `origin_domain`** — `Services::Billing::CreateCheckoutSession` stamps it into Stripe
metadata on every session, subscription and payment intent this app creates. Legacy's have none.

**But nothing currently writes it to the `memberships` row.** The column exists, checkout puts it in
Stripe metadata, the admin view reads it, and `ReconcileCustomer#upsert` omits it entirely. So today
every membership has `origin_domain: nil`. Task 1 closes that gap, and it is a prerequisite for
everything else here — including correct branding, since `MailBranding.for(nil)` falls back to books
and would send books-branded mail to every music and games subscriber.

`donations.domain` is already written by `RecordDonation`, from the same metadata. Only memberships
were missed.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/services/billing/reconcile_customer.rb` | **Modify.** Write `origin_domain` from Stripe metadata; capture the pre-assignment status; hand both to the notifier. |
| `app/models/membership.rb` | **Modify.** `#sold_by_this_app?` — the ownership predicate. |
| `app/models/donation.rb` | **Modify.** `#sold_by_this_app?` — same rule, different column. |
| `app/lib/membership_email_scope.rb` | **New.** The cutover switch. One place that answers "may we email about this?" |
| `app/lib/services/billing/membership_notifier.rb` | **New.** Given a membership and its previous status, decide which mail is owed and enqueue it. All the transition logic lives here, not in the mailers. |
| `app/mailers/membership_mailer.rb` | **New.** Four customer-facing actions. |
| `app/mailers/admin_mailer.rb` | **New.** Four owner-facing actions. |
| `app/views/membership_mailer/*.{html,text}.erb` | **New.** Eight templates. |
| `app/views/admin_mailer/*.{html,text}.erb` | **New.** Eight templates. |
| `app/lib/services/billing/record_donation.rb` | **Modify.** Enqueue the donation emails after a successful write. |
| `test/mailers/previews/membership_mailer_preview.rb` | **New.** Browser previews, including the nil-domain case. |
| `test/mailers/previews/admin_mailer_preview.rb` | **New.** Same. |
| `docs/features/email.md`, `docs/features/membership-billing.md`, `docs/specs/membership-and-stripe-billing.md`, `deployment/ENV.md` | **Modify.** Document the gate, the switch, and mark increment 8 shipped. |

---

## Task 1: The ownership gate and the cutover switch

Nothing sends mail in this task. It establishes the single question every later task asks, and closes
the `origin_domain` gap that makes the question answerable.

**Files:**
- Modify: `web-app/app/lib/services/billing/reconcile_customer.rb` (the `upsert` method, ~line 97)
- Modify: `web-app/app/models/membership.rb`
- Modify: `web-app/app/models/donation.rb`
- Create: `web-app/app/lib/membership_email_scope.rb`
- Create: `web-app/test/lib/membership_email_scope_test.rb`
- Modify: `web-app/test/lib/services/billing/reconcile_customer_test.rb`
- Modify: `web-app/test/models/membership_test.rb`, `web-app/test/models/donation_test.rb`

**Interfaces:**
- Consumes: `Membership#origin_domain` (String, nullable), `Donation#domain` (String, nullable).
- Produces:
  - `MembershipEmailScope.may_email?(record)` → Boolean. `record` responds to `sold_by_this_app?`.
  - `MembershipEmailScope::ENV_VAR` = `"MEMBERSHIP_EMAIL_SCOPE"`, values `"own_only"` (default) and
    `"all"`.
  - `Membership#sold_by_this_app?` → Boolean (`origin_domain.present?`).
  - `Donation#sold_by_this_app?` → Boolean (`domain.present?`).
  - `ReconcileCustomer#upsert` now writes `origin_domain`.

- [ ] **Step 1: Write the failing test for the scope switch**

Create `web-app/test/lib/membership_email_scope_test.rb`:

```ruby
require "test_helper"

class MembershipEmailScopeTest < ActiveSupport::TestCase
  Record = Struct.new(:sold_by_this_app?)

  test "defaults to own_only, so a record this app did not sell is not emailed about" do
    with_env(MembershipEmailScope::ENV_VAR => nil) do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  test "own_only is explicit and behaves the same as the default" do
    with_env(MembershipEmailScope::ENV_VAR => "own_only") do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  # The cutover setting. Once legacy is retired it stops emailing its own
  # subscribers, and this app must start -- otherwise every legacy-era member
  # silently never hears about a cancellation again.
  test "all emails about every record, including ones this app did not sell" do
    with_env(MembershipEmailScope::ENV_VAR => "all") do
      assert MembershipEmailScope.may_email?(Record.new(true))
      assert MembershipEmailScope.may_email?(Record.new(false))
    end
  end

  # A typo in production must not silently start double-emailing every legacy
  # subscriber. Unknown values fall back to the safe setting.
  test "an unrecognised value falls back to own_only rather than all" do
    with_env(MembershipEmailScope::ENV_VAR => "evrything") do
      assert_not MembershipEmailScope.may_email?(Record.new(false))
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/lib/membership_email_scope_test.rb
```

Expected: FAIL — `NameError: uninitialized constant MembershipEmailScope`.

- [ ] **Step 3: Implement the scope switch**

Create `web-app/app/lib/membership_email_scope.rb`:

```ruby
# Answers one question: may this app email about this membership or donation?
#
# The legacy books app is still live on the same Stripe account and still
# emails its own subscribers. Every webhook endpoint receives every event on
# the account, so without this gate a legacy subscriber would get two welcome
# emails for one subscription -- one from each app.
#
# Deliberately top-level, not nested: a constant looked up from inside a nested
# module resolves against that module first, which has produced confusing
# NameErrors in this codebase more than once.
class MembershipEmailScope
  ENV_VAR = "MEMBERSHIP_EMAIL_SCOPE"

  OWN_ONLY = "own_only"
  ALL = "all"

  # @param record [#sold_by_this_app?] a Membership or Donation
  def self.may_email?(record)
    return true if scope == ALL

    record.sold_by_this_app?
  end

  # Anything unrecognised is treated as own_only. A typo in production must not
  # silently start double-emailing every legacy subscriber -- the failure
  # direction matters more than the convenience.
  def self.scope
    (ENV[ENV_VAR] == ALL) ? ALL : OWN_ONLY
  end
end
```

- [ ] **Step 4: Run it and watch it pass**

```bash
bin/rails test test/lib/membership_email_scope_test.rb
```

Expected: 4 runs, 0 failures.

- [ ] **Step 5: Write the failing tests for the two ownership predicates**

Add to `web-app/test/models/membership_test.rb`:

```ruby
  # origin_domain is set only by this app's own checkout, via Stripe metadata
  # that CreateCheckoutSession stamps and ReconcileCustomer reads back. A
  # membership legacy sold has none, and that absence is the ownership signal.
  test "sold_by_this_app? is true only when origin_domain is present" do
    membership = memberships(:active_stripe)

    membership.origin_domain = "music"
    assert membership.sold_by_this_app?

    membership.origin_domain = nil
    assert_not membership.sold_by_this_app?

    membership.origin_domain = ""
    assert_not membership.sold_by_this_app?
  end
```

Add to `web-app/test/models/donation_test.rb`:

```ruby
  test "sold_by_this_app? is true only when domain is present" do
    donation = donations(:one_time)

    donation.domain = "books"
    assert donation.sold_by_this_app?

    donation.domain = nil
    assert_not donation.sold_by_this_app?
  end
```

**Check the actual fixture names before running** — they are semantic in this codebase, not
`one`/`two`:

```bash
sed -n '/^[a-z_]*:/p' test/fixtures/memberships.yml
sed -n '/^[a-z_]*:/p' test/fixtures/donations.yml
```

Substitute the real names and say in your report which you used.

- [ ] **Step 6: Run them and watch them fail**

```bash
bin/rails test test/models/membership_test.rb test/models/donation_test.rb
```

Expected: FAIL — `NoMethodError: undefined method 'sold_by_this_app?'`.

- [ ] **Step 7: Add both predicates**

In `web-app/app/models/membership.rb`, near the other predicate methods (beside `def stripe? =
source_stripe?`):

```ruby
  # Did THIS app sell this membership, as opposed to the legacy books app?
  #
  # origin_domain is stamped into Stripe metadata by CreateCheckoutSession and
  # read back by ReconcileCustomer. Legacy creates its subscriptions through
  # Stripe Payment Links and sets no metadata, so a blank origin_domain means
  # "not ours" -- which is exactly when this app must stay quiet, because
  # legacy is still emailing that subscriber itself.
  def sold_by_this_app? = origin_domain.present?
```

In `web-app/app/models/donation.rb`:

```ruby
  # See Membership#sold_by_this_app?. RecordDonation already writes `domain`
  # from the same Stripe metadata, so donations needed no backfill.
  def sold_by_this_app? = domain.present?
```

- [ ] **Step 8: Run them and watch them pass**

```bash
bin/rails test test/models/membership_test.rb test/models/donation_test.rb
```

- [ ] **Step 9: Write the failing test for the `origin_domain` gap**

This is the substantive fix in this task.

**First, read `web-app/test/lib/services/billing/reconcile_customer_test.rb` and find how its existing
tests build a stubbed Stripe subscription and invoke the service.** The tests below call three
helpers that do not exist yet — you are writing them, in that file's own idiom, not inventing a new
mocking style:

- `stripe_subscription_double(status: "active", metadata: {})` — returns whatever shape the existing
  tests already use for a Stripe subscription (it must respond to `id`, `status`, `customer`,
  `items.data.first`, `cancel_at_period_end`, `canceled_at`, and `metadata`). Give it keyword
  arguments with sensible defaults so each test overrides only what it cares about. If the file
  already has an equivalent, **use that one and add the `metadata:` argument to it** rather than
  writing a second.
- `reconcile_and_fetch(subscription)` — runs the reconcile for that subscription and returns the
  resulting `Membership` row.
- `reconcile_and_transition(subscription)` — same, but returns the `MembershipTransition` (Task 2
  introduces it; in this task `reconcile_and_fetch` is enough).

Report the actual signatures you settled on, because Task 2's tests reuse them.

Then add:

```ruby
  # THE GAP. origin_domain is stamped into subscription metadata at checkout,
  # but upsert never read it back, so every membership row had origin_domain
  # nil. That breaks two things at once: MailBranding.for(nil) falls back to
  # books, so a music subscriber gets books-branded mail; and with no value
  # there is no way to tell this app's memberships from legacy's, which is the
  # ownership signal the email gate depends on.
  test "writes origin_domain from the subscription's Stripe metadata" do
    subscription = stripe_subscription_double(metadata: {"origin_domain" => "music"})

    membership = reconcile_and_fetch(subscription)

    assert_equal "music", membership.origin_domain
  end

  # Legacy sells through Stripe Payment Links and sets no metadata at all.
  test "leaves origin_domain nil for a subscription with no metadata" do
    subscription = stripe_subscription_double(metadata: {})

    membership = reconcile_and_fetch(subscription)

    assert_nil membership.origin_domain
  end

  # The nightly sweep re-reconciles every subscription on the account. Stripe is
  # the source of truth, so a value that disappeared upstream must disappear
  # here -- but a real value must never be clobbered by a later sync.
  test "keeps origin_domain across a second reconcile of the same subscription" do
    subscription = stripe_subscription_double(metadata: {"origin_domain" => "games"})

    reconcile_and_fetch(subscription)
    membership = reconcile_and_fetch(subscription)

    assert_equal "games", membership.origin_domain
  end
```

- [ ] **Step 10: Run them and watch them fail**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

Expected: FAIL — `origin_domain` is nil where "music" was expected.

- [ ] **Step 11: Write `origin_domain` in `upsert`**

In `web-app/app/lib/services/billing/reconcile_customer.rb`, inside the `membership.assign_attributes(
...)` call in `upsert`, add one line beside the others:

```ruby
          # Stripe is the source of truth for this like everything else here.
          # CreateCheckoutSession stamps origin_domain into subscription
          # metadata; legacy's subscriptions have none, and that absence is the
          # signal Membership#sold_by_this_app? reads. Assign unconditionally --
          # a value that vanished upstream must vanish here too.
          origin_domain: subscription.metadata&.[]("origin_domain"),
```

Use `&.[]` rather than method access: on a Stripe object `[]` returns nil for an absent field, while
method access on an untyped nested object raises `NoMethodError` — which in a webhook job means a
retry loop, not a clean failure. This is the same idiom `RecordDonation` already uses.

- [ ] **Step 12: Run them and watch them pass**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

- [ ] **Step 13: Prove all three new guards are falsifiable**

This codebase has a documented history of tests passing against deleted code. Break the
implementation and confirm each fires:

1. Delete the `origin_domain:` line from `assign_attributes` — the first and third reconcile tests
   must go red.
2. Change `sold_by_this_app?` to `origin_domain.nil?` — the membership predicate test must go red.
3. Change `MembershipEmailScope.scope` to always return `ALL` — the two `own_only` tests must go red.

Restore after each. Record all three results in your report. If any stays green, rewrite that test
before continuing.

- [ ] **Step 14: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): add the membership email ownership gate and fix origin_domain`.

---

## Task 2: Capture the status transition

`ReconcileCustomer#upsert` uses `assign_attributes` and then `save!`, which discards the previous
status — so there is currently nothing to answer "did this membership just *become* active?" Every
customer email in this increment depends on that answer.

**Files:**
- Modify: `web-app/app/lib/services/billing/reconcile_customer.rb`
- Modify: `web-app/test/lib/services/billing/reconcile_customer_test.rb`

**Interfaces:**
- Consumes: `Membership` statuses — `trialing`, `active`, `canceled`, `incomplete`,
  `incomplete_expired`, `past_due`, `unpaid`, `paused` (enum has **no** prefix, so the predicates are
  `membership.active?`, `membership.canceled?`).
- Produces: `ReconcileCustomer#upsert` returns the membership as before, and additionally exposes the
  transition through a new value object:
  `Services::Billing::MembershipTransition.new(membership:, previous_status:)` with
  `#became_active?`, `#became_canceled?`, and `#status_changed?`. `previous_status` is `nil` for a
  brand-new row.

- [ ] **Step 1: Write the failing test**

Add to `web-app/test/lib/services/billing/reconcile_customer_test.rb`:

```ruby
  test "reports a brand-new active membership as having become active" do
    subscription = stripe_subscription_double(status: "active")

    transition = reconcile_and_transition(subscription)

    assert_nil transition.previous_status
    assert transition.became_active?
    assert_not transition.became_canceled?
  end

  # The nightly sweep re-reconciles everything. An unchanged active membership
  # must NOT look like a new activation, or every member gets a welcome email
  # every night.
  test "an unchanged active membership has not become active" do
    subscription = stripe_subscription_double(status: "active")
    reconcile_and_transition(subscription)

    transition = reconcile_and_transition(subscription)

    assert_equal "active", transition.previous_status
    assert_not transition.became_active?
    assert_not transition.status_changed?
  end

  test "reports the move from active to canceled as having become canceled" do
    subscription = stripe_subscription_double(status: "active")
    reconcile_and_transition(subscription)

    transition = reconcile_and_transition(stripe_subscription_double(status: "canceled"))

    assert_equal "active", transition.previous_status
    assert transition.became_canceled?
    assert transition.status_changed?
  end

  # trialing -> active is a real transition but not a new membership. The
  # welcome email already went out when the trial started; sending a second on
  # conversion would be a duplicate.
  test "trialing counts as active, so converting a trial is not a new activation" do
    subscription = stripe_subscription_double(status: "trialing")
    reconcile_and_transition(subscription)

    transition = reconcile_and_transition(stripe_subscription_double(status: "active"))

    assert_not transition.became_active?
  end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

Expected: FAIL — `reconcile_and_transition` and `MembershipTransition` do not exist.

- [ ] **Step 3: Add the value object**

Create `web-app/app/lib/services/billing/membership_transition.rb`:

```ruby
module Services
  module Billing
    # What changed about a membership during one reconcile.
    #
    # Exists because ReconcileCustomer#upsert uses assign_attributes + save!,
    # which discards the prior status -- and every customer email in this
    # subsystem is driven by a genuine transition, not by a current state. The
    # nightly sweep re-reconciles every subscription on the account, so
    # "currently active" fires every night; "just became active" fires once.
    class MembershipTransition
      # trialing and active both grant access, so moving between them is not a
      # new activation -- the welcome email already went out at trial start.
      ACCESS_GRANTING = %w[trialing active].freeze

      attr_reader :membership, :previous_status

      def initialize(membership:, previous_status:)
        @membership = membership
        @previous_status = previous_status
      end

      def status_changed?
        previous_status.to_s != membership.status.to_s
      end

      def became_active?
        ACCESS_GRANTING.include?(membership.status.to_s) &&
          !ACCESS_GRANTING.include?(previous_status.to_s)
      end

      def became_canceled?
        membership.canceled? && !previous_status.nil? && previous_status.to_s != "canceled"
      end
    end
  end
end
```

Note `became_canceled?` excludes `previous_status.nil?`: a membership that arrives already canceled —
which the account-wide migration produced in bulk — is not a cancellation event anyone should be
emailed about.

- [ ] **Step 4: Capture the previous status in `upsert`**

In `web-app/app/lib/services/billing/reconcile_customer.rb`, in `upsert`, capture before assigning and
return the transition. Read the current method carefully and keep every existing behaviour — the
comped-row guard, the `user || membership.user` non-downgrade rule, and the Basil
`item.current_period_end` read all stay exactly as they are.

```ruby
        # Captured BEFORE assign_attributes, which overwrites it. nil for a new
        # row. This is the whole reason MembershipTransition exists.
        previous_status = membership.persisted? ? membership.status : nil
```

immediately before the `membership.assign_attributes(` call, and after `membership.save!` return:

```ruby
        MembershipTransition.new(membership: membership, previous_status: previous_status)
```

**`upsert`'s return value changes**, so every caller must be updated. Find them:

```bash
grep -rn "upsert" app/lib/services/billing/reconcile_customer.rb
```

Callers that need the membership itself now read `transition.membership`. Update them, and update any
test asserting on `upsert`'s return. Report every call site you changed.

- [ ] **Step 5: Run the tests and watch them pass**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

- [ ] **Step 6: Prove the transition logic is falsifiable**

1. Change `became_active?` to ignore `previous_status` entirely (return true whenever the status
   grants access) — "an unchanged active membership has not become active" must go red. This is the
   single most important guard in the increment: if it does not fire, every member receives a welcome
   email every night at 05:00 UTC.
2. Remove `trialing` from `ACCESS_GRANTING` — the trial-conversion test must go red.

Restore after each. Record both results.

- [ ] **Step 7: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): capture the membership status transition during reconcile`.

---

## Task 3: `MembershipMailer#welcome`

**Files:**
- Create (via generator): `web-app/app/mailers/membership_mailer.rb`,
  `web-app/app/views/membership_mailer/welcome.{html,text}.erb`,
  `web-app/test/mailers/membership_mailer_test.rb`
- Create: `web-app/app/lib/services/billing/membership_notifier.rb`
- Create: `web-app/test/lib/services/billing/membership_notifier_test.rb`
- Modify: `web-app/app/lib/services/billing/reconcile_customer.rb`

**Interfaces:**
- Consumes: `ApplicationMailer#branded_mail(domain:, **options, &block)`; `MailBranding.for(domain)`
  exposing `site_name`, `from`, `brand_color`, `url_options`, `root_url`;
  `MembershipEmailScope.may_email?(record)`; `MembershipTransition#became_active?`.
- Produces:
  - `MembershipMailer.welcome(membership)` → `Mail::Message`.
  - `Services::Billing::MembershipNotifier.call(transition)` → `Result` (the project's
    `Result = Struct.new(:success?, :data, :errors, keyword_init: true)` pattern), enqueuing whatever
    mail the transition owes.

- [ ] **Step 1: Generate the mailer**

```bash
bin/rails generate mailer Membership welcome
```

Delete any generated file this plan does not list.

- [ ] **Step 2: Write the failing mailer test**

Replace `web-app/test/mailers/membership_mailer_test.rb`:

```ruby
require "test_helper"

class MembershipMailerTest < ActionMailer::TestCase
  setup { ENV["MAIL_FROM_ADDRESS"] = "contact@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "addresses the welcome email to the member" do
    membership = memberships(:active_stripe)
    mail = MembershipMailer.welcome(membership)

    assert_equal [membership.user.email], mail.to
    assert_equal ["contact@example.org"], mail.from
  end

  # The whole reason branded_mail takes a domain explicitly: this runs in
  # Sidekiq, where Current.domain is nil.
  test "brands the welcome email for the membership's own origin_domain" do
    membership = memberships(:active_stripe)
    membership.update!(origin_domain: "music")

    mail = MembershipMailer.welcome(membership)

    assert_match "The Greatest Music", mail.body.encoded
    assert_no_match(/The Greatest Books/, mail.body.encoded)
  end

  test "links to the membership page on that same site, not to a hardcoded Stripe URL" do
    membership = memberships(:active_stripe)
    membership.update!(origin_domain: "games")
    games_host = Rails.application.config.domains[:games].to_s.split(",").first

    mail = MembershipMailer.welcome(membership)

    assert_match games_host, mail.body.encoded
    assert_match "/membership", mail.body.encoded
    assert_no_match(/billing\.stripe\.com/, mail.body.encoded)
  end

  test "renders both an HTML and a plain-text part" do
    mail = MembershipMailer.welcome(memberships(:active_stripe))

    assert_equal ["text/html", "text/plain"], mail.parts.map(&:mime_type).sort
  end
end
```

Check the real fixture names first (`sed -n '/^[a-z_]*:/p' test/fixtures/memberships.yml`) and use one
whose user has an email. Report which you used.

- [ ] **Step 3: Run it and watch it fail**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 4: Implement the mailer action**

Replace `web-app/app/mailers/membership_mailer.rb`:

```ruby
# Customer-facing membership mail.
#
# Every action takes the Membership and reads its origin_domain -- never
# Current.domain, which is nil in Sidekiq where these are delivered.
class MembershipMailer < ApplicationMailer
  def welcome(membership)
    @membership = membership
    @renews_on = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Welcome to #{MailBranding.for(membership.origin_domain).site_name}"
    )
  end
end
```

- [ ] **Step 5: Write the templates**

Adapted from the legacy copy, with the hardcoded `billing.stripe.com/p/login/...` link replaced by a
link to this app's own `/membership`, which creates a proper per-customer portal session.

`web-app/app/views/membership_mailer/welcome.html.erb`:

```erb
<p>Thank you for becoming a member of <strong><%= @branding.site_name %></strong>.</p>

<p>Your support keeps the site running and ad-free.</p>

<% if @renews_on %>
  <p>Your membership renews on <%= @renews_on.strftime("%B %-d, %Y") %>.</p>
<% end %>

<p>
  You can manage or cancel your membership at any time from
  <%= link_to "your membership page", membership_url(@branding.url_options) %>.
</p>

<p>
  If there is something you would like to see added to the site, just reply to this
  email — I read every one.
</p>
```

`web-app/app/views/membership_mailer/welcome.text.erb`:

```erb
Thank you for becoming a member of <%= @branding.site_name %>.

Your support keeps the site running and ad-free.
<% if @renews_on %>
Your membership renews on <%= @renews_on.strftime("%B %-d, %Y") %>.
<% end %>
You can manage or cancel your membership at any time:
<%= membership_url(@branding.url_options) %>

If there is something you would like to see added to the site, just reply to this
email -- I read every one.
```

**`membership_url` must be given `@branding.url_options` explicitly.** `branded_mail` sets
instance-level `default_url_options`, so a bare `membership_url` would also work — but being explicit
here documents the dependency and survives someone later refactoring the base class. Confirm the route
helper's real name first:

```bash
bin/rails routes | grep -i membership | head
```

If it is not `membership_url`, use the real one and say so in your report.

- [ ] **Step 6: Run the mailer tests and watch them pass**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 7: Write the failing notifier test**

Create `web-app/test/lib/services/billing/membership_notifier_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class MembershipNotifierTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup { ENV["MAIL_FROM_ADDRESS"] = "contact@example.org" }
      teardown { ENV.delete("MAIL_FROM_ADDRESS") }

      test "sends the welcome email when a membership this app sold becomes active" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_enqueued_emails 1 do
          MembershipNotifier.call(transition)
        end
      end

      test "stamps welcome_email_sent_at so a second reconcile cannot resend" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        MembershipNotifier.call(transition)
        membership.reload
        assert_not_nil membership.welcome_email_sent_at

        assert_no_enqueued_emails do
          MembershipNotifier.call(MembershipTransition.new(membership: membership, previous_status: nil))
        end
      end

      # THE COEXISTENCE GUARD. Legacy is still live and still emails its own
      # subscribers; without this, they would receive two welcome emails.
      test "sends nothing for a membership this app did not sell" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "emails a membership this app did not sell once the scope is opened at cutover" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        with_env(MembershipEmailScope::ENV_VAR => "all") do
          assert_enqueued_emails(1) { MembershipNotifier.call(transition) }
        end
      end

      # The nightly sweep re-reconciles every subscription on the account.
      test "sends nothing when the status did not change" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      # A comped membership never came from Stripe and has no origin_domain.
      test "sends nothing for a comped membership" do
        membership = memberships(:comped)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "sends nothing when the membership has no user to email" do
        membership = sold_membership(status: :active)
        membership.update!(user: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      private

      def sold_membership(status:)
        memberships(:active_stripe).tap { |m| m.update!(status: status, origin_domain: "books") }
      end
    end
  end
end
```

Fix the fixture names to the real ones. Note `assert_enqueued_emails(1) { ... }` needs the
parentheses — the bare `assert_enqueued_emails 1 { ... }` form is a Ruby syntax error, because the
brace block binds to the integer.

- [ ] **Step 8: Run it and watch it fail**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

- [ ] **Step 9: Implement the notifier**

Create `web-app/app/lib/services/billing/membership_notifier.rb`:

```ruby
module Services
  module Billing
    # Decides which membership email a reconcile owes, and enqueues it.
    #
    # All the "should we send this" logic lives here rather than in the mailers,
    # so a mailer stays a mailer and this stays testable without rendering
    # anything. Three independent guards, each of which exists for a reason:
    #
    #   1. MembershipEmailScope -- the legacy books app is still live on the
    #      same Stripe account and still emails its own subscribers. Without
    #      this, they get two of every email.
    #   2. The *_email_sent_at timestamps -- the nightly sweep re-reconciles
    #      every subscription on the account, and a transient Stripe blip can
    #      replay a transition. These make each email once-only per membership.
    #   3. The transition itself -- "currently active" is true every night;
    #      "just became active" is true once.
    class MembershipNotifier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(transition) = new(transition).call

      def initialize(transition)
        @transition = transition
        @membership = transition.membership
      end

      def call
        return skipped("not a stripe membership") unless @membership.stripe?
        return skipped("no user to email") if @membership.user&.email.blank?
        return skipped("outside the configured email scope") unless MembershipEmailScope.may_email?(@membership)

        if @transition.became_active? && @membership.welcome_email_sent_at.nil?
          deliver_welcome
        else
          skipped("no email owed for this transition")
        end
      end

      private

      def deliver_welcome
        # Stamp BEFORE enqueuing. Two webhook endpoints deliver every event, so
        # two jobs routinely process the same transition concurrently; stamping
        # first means the loser of that race finds the timestamp set and sends
        # nothing. Enqueuing first would send two emails and then stamp twice.
        @membership.update!(welcome_email_sent_at: Time.current)
        MembershipMailer.welcome(@membership).deliver_later

        Result.new(success?: true, data: :welcome, errors: [])
      end

      def skipped(reason)
        Result.new(success?: true, data: nil, errors: [])
      ensure
        Rails.logger.info("MembershipNotifier skipped membership #{@membership.id}: #{reason}")
      end
    end
  end
end
```

Note `skipped` logs the membership **id** and a fixed reason string — never the user's email address.

- [ ] **Step 10: Run it and watch it pass**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

- [ ] **Step 11: Call the notifier from the reconciler**

In `web-app/app/lib/services/billing/reconcile_customer.rb`, after `upsert` returns its transition,
call `MembershipNotifier.call(transition)`.

**Place the call outside the advisory-lock transaction** if `upsert` runs inside one. Enqueuing a job
inside a transaction that later rolls back leaves Sidekiq with a job referencing a row that does not
exist; and the notifier writes `welcome_email_sent_at`, which must commit for the once-only guard to
hold. Read the surrounding method and report where you placed it and why.

- [ ] **Step 12: Prove the guards are falsifiable**

1. Delete the `welcome_email_sent_at.nil?` check — "stamps welcome_email_sent_at so a second reconcile
   cannot resend" must go red.
2. Delete the `MembershipEmailScope.may_email?` check — "sends nothing for a membership this app did
   not sell" must go red.
3. Change `deliver_welcome` to enqueue before stamping — the second-reconcile test should still pass
   (it is sequential), so note in your report that this ordering is guarded only by reasoning about
   the concurrent case, not by a test. Do not fabricate a concurrency test that cannot fail.

Restore after each; record all three.

- [ ] **Step 13: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): send the membership welcome email on activation`.

---

## Task 4: The two cancellation emails

Legacy distinguishes "you cancelled, but you still have another active subscription" from "you
cancelled your last one, and your account reverts to free". This app has one membership covering all
sites, so the distinction is whether the user still holds **any** other access-granting membership
after this one ends.

**Files:**
- Modify: `web-app/app/mailers/membership_mailer.rb`
- Create: `web-app/app/views/membership_mailer/canceled_with_other_active.{html,text}.erb`
- Create: `web-app/app/views/membership_mailer/canceled_last.{html,text}.erb`
- Modify: `web-app/app/lib/services/billing/membership_notifier.rb`
- Modify: both test files from Task 3

**Interfaces:**
- Consumes: `User#memberships`, the `Membership.granting_access` scope,
  `MembershipTransition#became_canceled?`, `Membership#ended_email_sent_at`.
- Produces: `MembershipMailer.canceled_with_other_active(membership)` and
  `MembershipMailer.canceled_last(membership)`.

- [ ] **Step 1: Write the failing mailer tests**

Add to `web-app/test/mailers/membership_mailer_test.rb`:

```ruby
  test "the cancelled-last email says access ends and names the date" do
    membership = memberships(:active_stripe)
    membership.update!(status: :canceled, current_period_end: 30.days.from_now, origin_domain: "books")

    mail = MembershipMailer.canceled_last(membership)

    assert_equal [membership.user.email], mail.to
    assert_match membership.current_period_end.strftime("%B %-d, %Y"), mail.body.encoded
  end

  test "the cancelled-with-other-active email does not claim access is ending" do
    membership = memberships(:active_stripe)
    membership.update!(status: :canceled, current_period_end: 30.days.from_now, origin_domain: "books")

    mail = MembershipMailer.canceled_with_other_active(membership)

    assert_equal [membership.user.email], mail.to
    assert_no_match(/revert to a free account/, mail.body.encoded)
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 3: Add both actions**

In `web-app/app/mailers/membership_mailer.rb`:

```ruby
  # The member cancelled, but still holds another access-granting membership,
  # so nothing about their access changes.
  def canceled_with_other_active(membership)
    @membership = membership
    @access_until = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Your #{MailBranding.for(membership.origin_domain).site_name} membership was cancelled"
    )
  end

  # The member cancelled their last one. Access ends at the end of the period
  # they already paid for -- Membership.granting_access keeps a cancelled
  # Stripe membership granting access until current_period_end.
  def canceled_last(membership)
    @membership = membership
    @access_until = membership.current_period_end

    branded_mail(
      domain: membership.origin_domain,
      to: membership.user.email,
      subject: "Your #{MailBranding.for(membership.origin_domain).site_name} membership has ended"
    )
  end
```

- [ ] **Step 4: Write the four templates**

`canceled_with_other_active.html.erb`:

```erb
<p>Your <strong><%= @branding.site_name %></strong> membership has been cancelled.</p>

<% if @access_until %>
  <p>This membership stays active until <%= @access_until.strftime("%B %-d, %Y") %>.</p>
<% end %>

<p>You still have another active membership, so your access continues.</p>

<p>
  You can review everything from
  <%= link_to "your membership page", membership_url(@branding.url_options) %>.
</p>
```

`canceled_with_other_active.text.erb`:

```erb
Your <%= @branding.site_name %> membership has been cancelled.
<% if @access_until %>
This membership stays active until <%= @access_until.strftime("%B %-d, %Y") %>.
<% end %>
You still have another active membership, so your access continues.

You can review everything here:
<%= membership_url(@branding.url_options) %>
```

`canceled_last.html.erb`:

```erb
<p>Your <strong><%= @branding.site_name %></strong> membership has been cancelled.</p>

<% if @access_until %>
  <p>
    You keep member access until <%= @access_until.strftime("%B %-d, %Y") %> — the end of the
    period you have already paid for. After that your account will revert to a free account.
  </p>
<% end %>

<p>
  You can resubscribe at any time from
  <%= link_to "your membership page", membership_url(@branding.url_options) %>.
</p>

<p>
  If there was something specific that prompted you to cancel, I would genuinely like to hear
  it — just reply to this email.
</p>
```

`canceled_last.text.erb`:

```erb
Your <%= @branding.site_name %> membership has been cancelled.
<% if @access_until %>
You keep member access until <%= @access_until.strftime("%B %-d, %Y") %> -- the end of the
period you have already paid for. After that your account will revert to a free
account.
<% end %>
You can resubscribe at any time:
<%= membership_url(@branding.url_options) %>

If there was something specific that prompted you to cancel, I would genuinely
like to hear it -- just reply to this email.
```

- [ ] **Step 5: Run the mailer tests and watch them pass**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 6: Write the failing notifier tests**

Add to `web-app/test/lib/services/billing/membership_notifier_test.rb`:

```ruby
      test "sends the cancelled-last email when the user holds no other access" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_enqueued_email_with MembershipMailer, :canceled_last, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      test "sends the other-active variant when the user still holds another membership" do
        membership = sold_membership(status: :canceled)
        ::Membership.create!(
          user: membership.user, source: :comped, status: :active, current_period_end: nil
        )
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_enqueued_email_with MembershipMailer, :canceled_with_other_active, args: [membership] do
          MembershipNotifier.call(transition)
        end
      end

      test "stamps ended_email_sent_at so a second reconcile cannot resend" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        MembershipNotifier.call(transition)
        assert_not_nil membership.reload.ended_email_sent_at

        assert_no_enqueued_emails do
          MembershipNotifier.call(
            MembershipTransition.new(membership: membership, previous_status: "active")
          )
        end
      end

      # A membership that arrived already cancelled -- as the account-wide
      # migration produced in bulk -- is not a cancellation anyone should hear
      # about.
      test "sends nothing when a membership arrives already cancelled" do
        membership = sold_membership(status: :canceled)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end
```

- [ ] **Step 7: Run and watch them fail**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

- [ ] **Step 8: Extend the notifier**

In `web-app/app/lib/services/billing/membership_notifier.rb`, replace the single `if` in `call` with:

```ruby
        if @transition.became_active? && @membership.welcome_email_sent_at.nil?
          deliver_welcome
        elsif @transition.became_canceled? && @membership.ended_email_sent_at.nil?
          deliver_cancellation
        else
          skipped("no email owed for this transition")
        end
```

and add:

```ruby
      def deliver_cancellation
        # Stamp before enqueuing -- see deliver_welcome.
        @membership.update!(ended_email_sent_at: Time.current)

        if other_access?
          MembershipMailer.canceled_with_other_active(@membership).deliver_later
          Result.new(success?: true, data: :canceled_with_other_active, errors: [])
        else
          MembershipMailer.canceled_last(@membership).deliver_later
          Result.new(success?: true, data: :canceled_last, errors: [])
        end
      end

      # Does the user still hold access from some OTHER membership? Reuses the
      # same scope that answers User#member?, so the email can never contradict
      # what the site actually does.
      def other_access?
        @membership.user.memberships.granting_access.where.not(id: @membership.id).exists?
      end
```

- [ ] **Step 9: Run and watch them pass**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

- [ ] **Step 10: Prove the branch is falsifiable**

Invert `other_access?` (drop the `where.not`, so the membership counts itself). The
"cancelled-last" test must go red — without the exclusion, a cancelled-but-still-in-period membership
counts as its own "other access" and every member gets the wrong email. Restore and record.

- [ ] **Step 11: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): send both membership cancellation emails`.

---

## Task 5: The donation receipt

**Files:**
- Modify: `web-app/app/mailers/membership_mailer.rb`
- Create: `web-app/app/views/membership_mailer/donation_receipt.{html,text}.erb`
- Modify: `web-app/app/lib/services/billing/record_donation.rb`
- Modify: `web-app/test/mailers/membership_mailer_test.rb`
- Modify: `web-app/test/lib/services/billing/record_donation_test.rb`

**Interfaces:**
- Consumes: `Donation#amount_in_dollars` (Float), `#currency`, `#email` (String, the address Stripe
  collected — set even for anonymous donors), `#user` (nullable), `#domain`, `#sold_by_this_app?`.
- Produces: `MembershipMailer.donation_receipt(donation)`.

Donations differ from memberships in two ways that matter: **there may be no user** (anonymous
donations are supported and deliberately create no Stripe Customer), and the recipient therefore comes
from `donation.email`, not `donation.user.email`. There is also no `*_email_sent_at` column — the
once-only guard is `RecordDonation`'s own idempotency, which returns the existing row rather than
re-writing it.

- [ ] **Step 1: Write the failing mailer test**

Add to `web-app/test/mailers/membership_mailer_test.rb`:

```ruby
  test "the donation receipt goes to the address Stripe collected and names the amount" do
    donation = donations(:one_time)
    donation.update!(email: "donor@example.org", amount_cents: 2500, domain: "books", user: nil)

    mail = MembershipMailer.donation_receipt(donation)

    assert_equal ["donor@example.org"], mail.to
    assert_match "$25.00", mail.body.encoded
  end

  test "the donation receipt is branded for the site the donation came from" do
    donation = donations(:one_time)
    donation.update!(email: "donor@example.org", domain: "games")

    mail = MembershipMailer.donation_receipt(donation)

    assert_match "The Greatest Games", mail.body.encoded
  end
```

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 3: Add the action and templates**

In `web-app/app/mailers/membership_mailer.rb`:

```ruby
  # Anonymous donations are supported and create no Customer, so the recipient
  # is the address Stripe collected at checkout, not a user record.
  def donation_receipt(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: donation.email,
      subject: "Thank you for your donation to #{MailBranding.for(donation.domain).site_name}"
    )
  end
```

`web-app/app/views/membership_mailer/donation_receipt.html.erb`:

```erb
<p>Thank you for your donation of <strong><%= @amount %></strong> to <%= @branding.site_name %>.</p>

<p>
  It genuinely helps — the site has no ads and no investors, so donations and memberships
  are what keep it running.
</p>

<p>This email is your receipt. There is nothing else you need to do.</p>
```

`web-app/app/views/membership_mailer/donation_receipt.text.erb`:

```erb
Thank you for your donation of <%= @amount %> to <%= @branding.site_name %>.

It genuinely helps -- the site has no ads and no investors, so donations and
memberships are what keep it running.

This email is your receipt. There is nothing else you need to do.
```

- [ ] **Step 4: Run and watch it pass**

```bash
bin/rails test test/mailers/membership_mailer_test.rb
```

- [ ] **Step 5: Write the failing test for the trigger**

Add to `web-app/test/lib/services/billing/record_donation_test.rb`, following the file's existing
style for stubbing a Stripe session:

```ruby
  test "emails a receipt for a donation this app took" do
    assert_enqueued_emails 1 do
      RecordDonation.call(event_with_session(metadata: {"origin_domain" => "books"}))
    end
  end

  # Legacy is still live, still takes donations through its own payment links,
  # and still emails its own donors.
  test "emails nothing for a donation this app did not take" do
    assert_no_enqueued_emails do
      RecordDonation.call(event_with_session(metadata: {}))
    end
  end

  test "emails nothing when Stripe collected no address" do
    assert_no_enqueued_emails do
      RecordDonation.call(event_with_session(metadata: {"origin_domain" => "books"}, email: nil))
    end
  end
```

- [ ] **Step 6: Run and watch it fail**

```bash
bin/rails test test/lib/services/billing/record_donation_test.rb
```

- [ ] **Step 7: Trigger the receipt**

In `web-app/app/lib/services/billing/record_donation.rb`, immediately after `donation.save!` and
before `success(donation)`:

```ruby
        deliver_receipt(donation)
```

and add the private method:

```ruby
      # Legacy still takes donations through its own payment links and emails
      # those donors itself, so this app must stay quiet about anything it did
      # not take. MembershipEmailScope is the switch that opens up at cutover.
      def deliver_receipt(donation)
        return if donation.email.blank?
        return unless MembershipEmailScope.may_email?(donation)

        MembershipMailer.donation_receipt(donation).deliver_later
      end
```

Place it so the `RecordNotUnique` / `RecordInvalid` race-recovery path does **not** also send: the
loser of that race returns the winner's existing row, and the winner already sent. Read the rescue
blocks and report where you put the call relative to them.

- [ ] **Step 8: Run and watch it pass**

```bash
bin/rails test test/lib/services/billing/record_donation_test.rb
```

- [ ] **Step 9: Prove the race path does not double-send**

Write a test that runs `RecordDonation.call` twice for the same payment intent and asserts exactly one
email is enqueued across both calls. If that passes trivially because the second call short-circuits
before reaching your code, say so — do not claim it proves more than it does.

- [ ] **Step 10: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): send a receipt for donations this app takes`.

---

## Task 6: The four admin notifications

These go to `ADMIN_NOTIFICATION_EMAIL`, not to customers. Same ownership gate — the owner decided on
2026-08-21 that the new app should notify only about its own sales, so legacy keeps notifying about
legacy's and there is exactly one notice per sale.

**Files:**
- Create (via generator): `web-app/app/mailers/admin_mailer.rb`, its four view pairs, and
  `web-app/test/mailers/admin_mailer_test.rb`
- Modify: `web-app/app/lib/services/billing/membership_notifier.rb`
- Modify: `web-app/app/lib/services/billing/record_donation.rb`

**Interfaces:**
- Consumes: `ENV["ADMIN_NOTIFICATION_EMAIL"]`, `MailBranding`, `Membership`, `Donation`.
- Produces: `AdminMailer.new_subscription(membership)`, `AdminMailer.subscription_canceled(membership)`,
  `AdminMailer.new_donation(donation)`, `AdminMailer.anonymous_donation(donation)`.

- [ ] **Step 1: Generate the mailer**

```bash
bin/rails generate mailer Admin new_subscription subscription_canceled new_donation anonymous_donation
```

- [ ] **Step 2: Write the failing tests**

Replace `web-app/test/mailers/admin_mailer_test.rb`:

```ruby
require "test_helper"

class AdminMailerTest < ActionMailer::TestCase
  setup do
    ENV["MAIL_FROM_ADDRESS"] = "contact@example.org"
    ENV["ADMIN_NOTIFICATION_EMAIL"] = "owner@example.org"
  end

  teardown do
    ENV.delete("MAIL_FROM_ADDRESS")
    ENV.delete("ADMIN_NOTIFICATION_EMAIL")
  end

  test "new_subscription goes to the admin address, not to the member" do
    membership = memberships(:active_stripe)
    membership.update!(origin_domain: "music")

    mail = AdminMailer.new_subscription(membership)

    assert_equal ["owner@example.org"], mail.to
    assert_no_match(/#{Regexp.escape(membership.user.email)}/, mail.subject)
  end

  test "new_subscription names which site the sale came from" do
    membership = memberships(:active_stripe)
    membership.update!(origin_domain: "games")

    mail = AdminMailer.new_subscription(membership)

    assert_match "The Greatest Games", mail.body.encoded
  end

  test "new_donation names the amount" do
    donation = donations(:one_time)
    donation.update!(amount_cents: 5000, domain: "books")

    mail = AdminMailer.new_donation(donation)

    assert_equal ["owner@example.org"], mail.to
    assert_match "$50.00", mail.body.encoded
  end

  test "anonymous_donation does not assume a user" do
    donation = donations(:one_time)
    donation.update!(user: nil, email: nil, amount_cents: 1000, domain: "books")

    mail = AdminMailer.anonymous_donation(donation)

    assert_equal ["owner@example.org"], mail.to
    assert_match "$10.00", mail.body.encoded
  end

  test "raises nothing useful-looking when ADMIN_NOTIFICATION_EMAIL is unset" do
    ENV.delete("ADMIN_NOTIFICATION_EMAIL")

    assert_raises(AdminMailer::MissingAdminAddress) do
      AdminMailer.new_subscription(memberships(:active_stripe)).to
    end
  end
end
```

The last test encodes the same rule the rest of this subsystem follows: a missing configuration value
raises rather than silently defaulting. **Note the subject deliberately does not carry the member's
email address** — these emails are logged and forwarded like any other, and the repo's stance is to
keep addresses out of anything incidental.

- [ ] **Step 3: Run and watch them fail**

```bash
bin/rails test test/mailers/admin_mailer_test.rb
```

- [ ] **Step 4: Implement the mailer**

Replace `web-app/app/mailers/admin_mailer.rb`:

```ruby
# Operational notifications to the site owner. Never customer-facing.
#
# Branded for the site the sale came from, so the owner can tell at a glance
# which property produced it.
class AdminMailer < ApplicationMailer
  class MissingAdminAddress < StandardError; end

  def new_subscription(membership)
    @membership = membership
    @site_name = MailBranding.for(membership.origin_domain).site_name

    branded_mail(
      domain: membership.origin_domain,
      to: admin_address,
      subject: "New membership on #{@site_name}"
    )
  end

  def subscription_canceled(membership)
    @membership = membership
    @site_name = MailBranding.for(membership.origin_domain).site_name

    branded_mail(
      domain: membership.origin_domain,
      to: admin_address,
      subject: "Membership cancelled on #{@site_name}"
    )
  end

  def new_donation(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: admin_address,
      subject: "New donation: #{@amount}"
    )
  end

  def anonymous_donation(donation)
    @donation = donation
    @amount = ActiveSupport::NumberHelper.number_to_currency(donation.amount_in_dollars)

    branded_mail(
      domain: donation.domain,
      to: admin_address,
      subject: "New anonymous donation: #{@amount}"
    )
  end

  private

  def admin_address
    address = ENV["ADMIN_NOTIFICATION_EMAIL"]
    raise MissingAdminAddress, "ADMIN_NOTIFICATION_EMAIL is not set" if address.blank?

    address
  end
end
```

- [ ] **Step 5: Write the eight templates**

Each is short. `new_subscription.html.erb`:

```erb
<p>A new membership was purchased on <strong><%= @site_name %></strong>.</p>

<ul>
  <li>Interval: <%= @membership.interval || "unknown" %></li>
  <li>Renews: <%= @membership.current_period_end&.strftime("%B %-d, %Y") || "unknown" %></li>
  <li>Membership ID: <%= @membership.id %></li>
</ul>
```

`new_subscription.text.erb`:

```erb
A new membership was purchased on <%= @site_name %>.

Interval:      <%= @membership.interval || "unknown" %>
Renews:        <%= @membership.current_period_end&.strftime("%B %-d, %Y") || "unknown" %>
Membership ID: <%= @membership.id %>
```

`subscription_canceled.html.erb`:

```erb
<p>A membership was cancelled on <strong><%= @site_name %></strong>.</p>

<ul>
  <li>Access until: <%= @membership.current_period_end&.strftime("%B %-d, %Y") || "unknown" %></li>
  <li>Membership ID: <%= @membership.id %></li>
</ul>
```

`subscription_canceled.text.erb`:

```erb
A membership was cancelled on <%= @site_name %>.

Access until:  <%= @membership.current_period_end&.strftime("%B %-d, %Y") || "unknown" %>
Membership ID: <%= @membership.id %>
```

`new_donation.html.erb`:

```erb
<p>A donation of <strong><%= @amount %></strong> came in from <%= @branding.site_name %>.</p>

<ul>
  <li>Donation ID: <%= @donation.id %></li>
  <li>User ID: <%= @donation.user_id || "none" %></li>
</ul>
```

`new_donation.text.erb`:

```erb
A donation of <%= @amount %> came in from <%= @branding.site_name %>.

Donation ID: <%= @donation.id %>
User ID:     <%= @donation.user_id || "none" %>
```

`anonymous_donation.html.erb`:

```erb
<p>An anonymous donation of <strong><%= @amount %></strong> came in from <%= @branding.site_name %>.</p>

<p>Donation ID: <%= @donation.id %></p>
```

`anonymous_donation.text.erb`:

```erb
An anonymous donation of <%= @amount %> came in from <%= @branding.site_name %>.

Donation ID: <%= @donation.id %>
```

These deliberately carry **ids, not addresses** — the admin can look the record up in the admin UI,
and an id in an inbox is not PII.

- [ ] **Step 6: Run and watch them pass**

```bash
bin/rails test test/mailers/admin_mailer_test.rb
```

- [ ] **Step 7: Wire the two membership notifications**

In `web-app/app/lib/services/billing/membership_notifier.rb`, send the admin notice alongside each
customer email — inside `deliver_welcome` and `deliver_cancellation`, after the customer mail:

```ruby
        AdminMailer.new_subscription(@membership).deliver_later
```

```ruby
        AdminMailer.subscription_canceled(@membership).deliver_later
```

They share the customer email's guards, which is what the owner asked for: exactly one notice per
sale this app made, and none for legacy's.

- [ ] **Step 8: Wire the two donation notifications**

In `web-app/app/lib/services/billing/record_donation.rb`, extend `deliver_receipt`:

```ruby
      def deliver_receipt(donation)
        return unless MembershipEmailScope.may_email?(donation)

        MembershipMailer.donation_receipt(donation).deliver_later if donation.email.present?

        if donation.user_id.present?
          AdminMailer.new_donation(donation).deliver_later
        else
          AdminMailer.anonymous_donation(donation).deliver_later
        end
      end
```

Note the admin notice fires even when there is no address to send the donor a receipt — a donation
with no collected email is still revenue the owner should hear about.

- [ ] **Step 9: Add notifier and donation tests for the admin path**

Add to `web-app/test/lib/services/billing/membership_notifier_test.rb`:

```ruby
      test "an activation sends both the member's welcome and the owner's notice" do
        membership = sold_membership(status: :active)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
      end

      test "a membership this app did not sell notifies nobody, owner included" do
        membership = sold_membership(status: :active)
        membership.update!(origin_domain: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: nil)

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end
```

Set `ENV["ADMIN_NOTIFICATION_EMAIL"]` in that file's `setup`, since `AdminMailer` now raises without
it.

- [ ] **Step 10: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): notify the owner about memberships and donations`.

---

## Task 7: Delivery policy, previews, and documentation

**Files:**
- Modify: `web-app/app/mailers/application_mailer.rb`
- Create: `web-app/test/mailers/previews/membership_mailer_preview.rb`
- Create: `web-app/test/mailers/previews/admin_mailer_preview.rb`
- Modify: `deployment/ENV.md`, `docs/features/email.md`,
  `docs/features/membership-billing.md`, `docs/specs/membership-and-stripe-billing.md`

- [ ] **Step 1: Stop a hard bounce burning 25 retries**

`config.action_mailer.raise_delivery_errors = true` in production means a permanent SMTP failure — a
mailbox that no longer exists — raises inside the Sidekiq job, which then retries 25 times over
roughly 21 days. That is 25 attempts at an address that will never accept mail.

Add to `web-app/app/mailers/application_mailer.rb`:

```ruby
  # A permanent SMTP failure (550 mailbox unavailable, 553 bad address) will
  # never succeed on retry, and raise_delivery_errors is on in production -- so
  # without this, one dead mailbox burns 25 Sidekiq retries over ~21 days.
  # A transient failure raises a different class and still retries normally.
  #
  # Logs the mailer and action only. Never the recipient, never the exception
  # message: this repo is public and an SMTP error message quotes the address
  # it rejected.
  rescue_from Net::SMTPFatalError, Net::SMTPSyntaxError do |error|
    Rails.logger.warn(
      "Permanent delivery failure for #{mailer_name}##{action_name} (#{error.class}); not retrying"
    )
  end
```

Write a test in `web-app/test/mailers/application_mailer_test.rb` that a fatal SMTP error is swallowed
rather than raised, and that a transient one (`Net::SMTPServerBusy`) still propagates. If `rescue_from`
turns out not to cover the delivery path in this Rails version — verify, do not assume — report that
and use `discard_on` on `ActionMailer::MailDeliveryJob` instead.

- [ ] **Step 2: Write the previews**

Create `web-app/test/mailers/previews/membership_mailer_preview.rb` with one preview per action per
interesting domain, including **the nil-domain case for every action** — that is not hypothetical, it
is every membership predating checkout:

```ruby
# Preview all emails at http://localhost:3000/rails/mailers
class MembershipMailerPreview < ActionMailer::Preview
  def welcome_books = MembershipMailer.welcome(sample_membership("books"))

  def welcome_music = MembershipMailer.welcome(sample_membership("music"))

  def welcome_unknown_domain = MembershipMailer.welcome(sample_membership(nil))

  def canceled_last = MembershipMailer.canceled_last(sample_membership("books"))

  def canceled_with_other_active
    MembershipMailer.canceled_with_other_active(sample_membership("games"))
  end

  def donation_receipt = MembershipMailer.donation_receipt(sample_donation("books"))

  private

  # Built in memory, never saved -- a preview must not write to the database.
  def sample_membership(domain)
    Membership.new(
      id: 0,
      user: User.new(email: "member@example.org"),
      source: :stripe,
      status: :active,
      interval: :yearly,
      origin_domain: domain,
      current_period_end: 1.year.from_now
    )
  end

  def sample_donation(domain)
    Donation.new(id: 0, amount_cents: 2500, currency: "usd", email: "donor@example.org", domain: domain)
  end
end
```

Create `web-app/test/mailers/previews/admin_mailer_preview.rb`:

```ruby
# Preview all emails at http://localhost:3000/rails/mailers
class AdminMailerPreview < ActionMailer::Preview
  def new_subscription = AdminMailer.new_subscription(sample_membership("music"))

  def subscription_canceled = AdminMailer.subscription_canceled(sample_membership("books"))

  def new_donation = AdminMailer.new_donation(sample_donation("games", user: User.new(id: 0)))

  def anonymous_donation = AdminMailer.anonymous_donation(sample_donation("books", user: nil))

  private

  # Built in memory, never saved -- a preview must not write to the database.
  def sample_membership(domain)
    Membership.new(
      id: 0,
      user: User.new(email: "member@example.org"),
      source: :stripe,
      status: :active,
      interval: :monthly,
      origin_domain: domain,
      current_period_end: 1.month.from_now
    )
  end

  def sample_donation(domain, user:)
    Donation.new(id: 0, amount_cents: 5000, currency: "usd", email: "donor@example.org",
      domain: domain, user: user)
  end
end
```

Then verify they render. Previews need `MAIL_FROM_ADDRESS` and `ADMIN_NOTIFICATION_EMAIL`:

```bash
MAIL_FROM_ADDRESS=contact@thegreatestbooks.org ADMIN_NOTIFICATION_EMAIL=ops@example.org bin/rails server
```

`curl` each preview URL under `/rails/mailers/membership_mailer/` and `/rails/mailers/admin_mailer/`,
report the HTTP status for each, and confirm the branded ones show different header colours. Kill the
server afterwards. If port 3000 is taken, use another and say which — it may be serving a different
worktree.

- [ ] **Step 3: Document the switch in `deployment/ENV.md`**

Add `MEMBERSHIP_EMAIL_SCOPE` in the existing `#### VARIABLE` format, in the Email Configuration
section:

- Not required; defaults to `own_only`.
- `own_only` — email only about memberships and donations this app sold. Correct while the legacy
  books app is live, because legacy still emails its own subscribers and both apps receive every
  event on the shared Stripe account.
- `all` — email about everything on the account. **Set this at legacy cutover**, or legacy-era
  members will never receive a cancellation email from anyone again.
- Any unrecognised value is treated as `own_only`, deliberately: a typo must not start
  double-emailing paying customers.

- [ ] **Step 4: Document the subsystem**

Add a section to `docs/features/email.md` covering: the eight emails and what triggers each; the three
guards (scope, timestamps, transition) and why each exists; that admin notices carry ids, never
addresses; and the cutover switch with a pointer to `ENV.md`.

Add a section to `docs/features/membership-billing.md` covering the coexistence rule from the billing
side — that this app emails only what it sold, that legacy's guard handles the mirror case, and that
`origin_domain` is the signal for both branding and ownership.

- [ ] **Step 5: Mark the increment shipped**

In `docs/specs/membership-and-stripe-billing.md`: tick row 8 in the Increments table, update the
Status line (increment 8 was the last one — say so), and tick the two acceptance criteria about the
welcome email sending exactly once and mail using `origin_domain` branding rather than a `Current`
lookup.

Also revisit the "Carried forward" bullets about `origin_domain` never being written and the
welcome-mailer status diff having nothing to diff against — **both are fixed by this increment.**
Replace them with what was actually done rather than deleting them.

- [ ] **Step 6: Full suite, lint, and commit**

```bash
bin/rails test
bundle exec standardrb
bin/rails zeitwerk:check
```

Commit with the message `docs(billing): document the membership emails and mark increment 8 shipped`.

---

## Notes for the reviewer

Aim review at these, in order:

1. **Can any email send twice?** Trace every path: the nightly sweep re-reconciling an unchanged
   membership; two webhook endpoints delivering the same event concurrently; a Sidekiq retry after a
   partial failure; `RecordDonation`'s race-recovery rescue. The stamp-before-enqueue ordering in
   `MembershipNotifier` is load-bearing — check it was not "tidied" into enqueue-then-stamp.
2. **Can any email send to the wrong person, or about the wrong site?** `MailBranding.for(nil)` falls
   back to books; confirm every mailer passes the record's own domain and never `Current`.
   `grep -rn "Current\." app/mailers app/views/membership_mailer app/views/admin_mailer` must be empty.
3. **The coexistence gate.** With `MEMBERSHIP_EMAIL_SCOPE` unset, does anything at all send for a
   record with a blank `origin_domain`/`domain`? A single leak double-emails a paying customer of the
   legacy site.
4. **PII in logs and subjects.** No recipient address in a log line, a subject, or an exception
   message. Admin emails should carry ids.
5. **Test falsifiability.** The plan asks the implementer to prove specific mutations go red in Tasks
   1, 2, 3 and 4 — check the reports say so, and spot-check the most important one yourself: break
   `became_active?` so it ignores `previous_status` and confirm the nightly-resend test fails. If it
   does not, every member gets a welcome email every night.
6. **Deploy pipeline.** No migration is expected. Production eager-loads, and a constant error in any
   mailer takes all four sites down in a crash-loop under `bash -e` + `restart: unless-stopped`.
   Confirm `RAILS_ENV=production bin/rails zeitwerk:check` passes.
