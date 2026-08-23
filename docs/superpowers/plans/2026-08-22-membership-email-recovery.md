# Membership Email Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two defects found by live production testing of increment 8 — a Stripe API field that moved, and membership emails that are lost permanently when an enqueue fails — without introducing the mass mail-out that the second fix would otherwise cause at legacy cutover.

**Architecture:** Both fixes are corrections to increment 8's centre. The first is one line plus a
comment: Stripe no longer sets `cancel_at_period_end` for a period-end cancellation, expressing it
as a `cancel_at` timestamp instead, so `ReconcileCustomer#upsert` must read both. The second
replaces transition-derived email eligibility with durable-state eligibility: a status transition is
observable exactly once, so if the enqueue fails the email can never be recovered, whereas the
`*_email_sent_at` columns are a permanent record of what is owed. That change makes a third task
mandatory — with durable eligibility, flipping `MEMBERSHIP_EMAIL_SCOPE=all` at legacy cutover would
make every legacy membership eligible for a welcome it never received, so the cutover needs a
backfill first.

**Tech Stack:** Rails 8.1, Stripe Ruby gem 19.5.0, Sidekiq via ActiveJob, Minitest + Mocha, standardrb.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — increment 8, and the first two entries under
"Carried forward". Subsystem docs: `docs/features/email.md`, `docs/features/membership-billing.md`.

## Global Constraints

- **No migration.** Every column needed already exists. If you believe you need one, STOP and report
  — a raising migration crash-loops the web container and 502s all four sites.
- Do not run destructive database commands. The development database holds books data that exists
  nowhere else and takes hours to rebuild. Never `create_fixtures`, `db:reset`, `db:drop`, or bulk
  `delete_all`/`update_all` outside the explicitly-scoped backfill in Task 3.
- **Every mailer takes a domain explicitly and calls `branded_mail`, never `mail`.** Mailers run in
  Sidekiq where `Current.domain` is nil.
- Never log an email address, an email body, or a delivery exception message. This repo is public.
- Services live in `app/lib/services/<domain>/`; jobs in `app/sidekiq/`.
- **`Membership`'s `status` enum has no prefix** (`membership.active?`, `.canceled?`); `source` and
  `interval` do (`source_stripe?`).
- The linter is `bundle exec standardrb`, NOT rubocop. `bin/rails test` must be green.
- Real fixture names: `regular_user_monthly`, `regular_user_gift`, `editor_user_comped`.
- `assert_enqueued_emails(1) { ... }` needs the parentheses; the bare form is a syntax error.
  `assert_enqueued_emails` lives in `ActionMailer::TestHelper`, not `ActiveJob::TestHelper`.

---

## Task 1: Read Stripe's `cancel_at`, not just the boolean

**Verified live on 2026-08-22.** After cancelling a real subscription through the Billing Portal,
Stripe returned:

```
status=active
cancel_at_period_end=false
cancel_at=1790114054          # 2026-09-22 21:54:14 UTC -- exactly current_period_end
canceled_at=1787435948        # 2026-08-22 21:59:08 UTC -- when cancel was clicked
cancellation_details={"reason" => "cancellation_requested", "feedback" => "unused"}
```

`ReconcileCustomer#upsert` reads only `!!subscription.cancel_at_period_end`, so the column is
permanently false and every reader of it is wrong — most visibly `/membership`, which tells a member
who just cancelled that their membership **renews**.

**Files:**
- Modify: `web-app/app/lib/services/billing/reconcile_customer.rb` (the `cancel_at_period_end:` line in `upsert`)
- Modify: `web-app/test/lib/services/billing/reconcile_customer_test.rb`

**Interfaces:**
- Consumes: the stubbed Stripe subscription built by the existing `stripe_subscription(**opts)`
  helper in that test file. You will need to add a `cancel_at:` keyword to it (defaulting to `nil`),
  alongside the `cancel_at_period_end:` it presumably already supports. Report what you changed.
- Produces: `Membership#cancel_at_period_end` is true when Stripe reports **either** signal.

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/services/billing/reconcile_customer_test.rb`:

```ruby
  # Stripe stopped expressing a period-end cancellation as cancel_at_period_end
  # and now sets a cancel_at timestamp instead. Verified live 2026-08-22: a real
  # portal cancellation returned cancel_at_period_end=false with cancel_at set
  # to exactly current_period_end. Reading only the boolean left the column
  # permanently false, so /membership told a member who had just cancelled that
  # their membership renews.
  test "treats a cancel_at timestamp as a scheduled cancellation" do
    subscription = stripe_subscription(cancel_at_period_end: false, cancel_at: 30.days.from_now.to_i)

    membership = reconcile_and_fetch(subscription)

    assert membership.cancel_at_period_end
  end

  test "still honours the cancel_at_period_end boolean when Stripe sets it" do
    subscription = stripe_subscription(cancel_at_period_end: true, cancel_at: nil)

    membership = reconcile_and_fetch(subscription)

    assert membership.cancel_at_period_end
  end

  test "reports no scheduled cancellation when Stripe sets neither signal" do
    subscription = stripe_subscription(cancel_at_period_end: false, cancel_at: nil)

    membership = reconcile_and_fetch(subscription)

    assert_not membership.cancel_at_period_end
  end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

Expected: the first test fails (the column is false where true was expected). The other two should
already pass — say so in your report if they do; a test that passes before the fix is not evidence.

- [ ] **Step 3: Read both signals**

In `web-app/app/lib/services/billing/reconcile_customer.rb`, replace the `cancel_at_period_end:` line
inside `upsert`'s `assign_attributes` with:

```ruby
          # Stripe expresses a scheduled cancellation two different ways, and as
          # of 2026 the portal uses the second: cancel_at_period_end stays FALSE
          # and a cancel_at timestamp carries the date. Verified live on
          # 2026-08-22 -- a real portal cancellation returned
          # cancel_at_period_end=false, cancel_at=<exactly current_period_end>,
          # canceled_at=<when cancel was clicked>. Reading only the boolean left
          # this column permanently false, so /membership told a member who had
          # just cancelled that their membership renews.
          #
          # Read both. The boolean may still be set by the API or by older
          # flows, and this column means "is a cancellation scheduled", which
          # either signal establishes. No offline test can catch the next such
          # move -- the tests stub the shape we expect -- so the runbook's live
          # cancellation check is what guards this going forward.
          cancel_at_period_end: subscription.cancel_at_period_end.present? || subscription.cancel_at.present?,
```

Note `.present?` rather than truthiness: `false.present?` is `false`, which is what we want, and it
reads the same for both fields.

- [ ] **Step 4: Run them and watch them pass**

```bash
bin/rails test test/lib/services/billing/reconcile_customer_test.rb
```

- [ ] **Step 5: Prove the first test is falsifiable**

Revert the line to `!!subscription.cancel_at_period_end` and confirm "treats a cancel_at timestamp as
a scheduled cancellation" goes red while the other two stay green. Restore, and record the output.

- [ ] **Step 6: Check the three readers still read correctly**

`cancel_at_period_end` is read in three places — `app/helpers/membership_helper.rb`,
`app/views/admin/memberships/index.html.erb`, `app/views/admin/memberships/show.html.erb`. None
should need changing, but confirm the helper's first branch (`source_stripe? &&
cancel_at_period_end? && ends_on`) now produces "Your membership is cancelled and stays active
until…" for a membership in this state, and say so in your report.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `fix(billing): treat Stripe's cancel_at as a scheduled cancellation`.

---

## Task 2: Derive email eligibility from durable state

A status transition is observable exactly once. `upsert` commits the status *before* the notifier
runs, so if `deliver_later` raises — Redis unavailable is the realistic case — `with_lock` correctly
rolls the timestamp back, but every later retry and nightly sweep computes `previous_status ==
status` and `became_active?` is false forever. The membership is owed a welcome, the nil timestamp
records exactly that, and nothing reads it. Reproduced: timestamp nil, zero emails enqueued on retry.

The `*_email_sent_at` columns are the durable record. Read them.

**Files:**
- Modify: `web-app/app/lib/services/billing/membership_notifier.rb`
- Modify: `web-app/test/lib/services/billing/membership_notifier_test.rb`
- Possibly modify: `web-app/app/lib/services/billing/membership_transition.rb` and its tests — see Step 5

**Interfaces:**
- Consumes: `Membership#welcome_email_sent_at`, `#ended_email_sent_at`, `#status`,
  `#sold_by_this_app?`, `MembershipEmailScope.may_email?`.
- Produces: `MembershipNotifier.call(transition)` keeps its signature — the transition remains the
  carrier — but eligibility no longer consults `became_active?` / `became_canceled?`.

- [ ] **Step 1: Write the failing tests**

Add to `web-app/test/lib/services/billing/membership_notifier_test.rb`:

```ruby
      # THE RECOVERY CASE. A prior attempt committed the status and then failed
      # to enqueue, so the stamp rolled back to nil. Under transition-derived
      # eligibility this membership could never be welcomed again, because every
      # later reconcile sees previous_status == status.
      test "sends a welcome that an earlier failed enqueue left owed" do
        membership = sold_membership(status: :active)
        membership.update!(welcome_email_sent_at: nil)
        # previous_status equals the current status: no transition to observe.
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
        assert_not_nil membership.reload.welcome_email_sent_at
      end

      test "sends nothing once the welcome has been sent, however often it reconciles" do
        membership = sold_membership(status: :active)
        membership.update!(welcome_email_sent_at: Time.current)
        transition = MembershipTransition.new(membership: membership, previous_status: "active")

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      # A membership we never welcomed must never receive an ending notice. This
      # replaces the old "arrived already cancelled" guard and covers the same
      # bulk-migrated rows, durably rather than transitionally.
      test "sends no cancellation for a membership that was never welcomed" do
        membership = sold_membership(status: :canceled)
        membership.update!(welcome_email_sent_at: nil, ended_email_sent_at: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: "canceled")

        assert_no_enqueued_emails { MembershipNotifier.call(transition) }
      end

      test "sends a cancellation that an earlier failed enqueue left owed" do
        membership = sold_membership(status: :canceled)
        membership.update!(welcome_email_sent_at: 1.month.ago, ended_email_sent_at: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: "canceled")

        assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
        assert_not_nil membership.reload.ended_email_sent_at
      end

      # A past_due membership recovering to active is not a new member, but it
      # IS access-granting and unwelcomed -- so it correctly gets the welcome it
      # never received. Documented rather than special-cased.
      test "welcomes an access-granting membership regardless of what it was before" do
        membership = sold_membership(status: :active)
        membership.update!(welcome_email_sent_at: nil)
        transition = MembershipTransition.new(membership: membership, previous_status: "past_due")

        assert_enqueued_emails(2) { MembershipNotifier.call(transition) }
      end
```

Keep every existing test in that file. Several assert on transitions; they should still pass, because
the cases they describe (scope gate, comped, no user, already-stamped) are unchanged. Report any that
do not, rather than editing them to fit.

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

Expected: the two "owed" tests fail — no emails enqueued, because no transition occurred.

- [ ] **Step 3: Replace the eligibility derivation**

In `web-app/app/lib/services/billing/membership_notifier.rb`, replace the `if/elsif/else` in `call`
with:

```ruby
        if welcome_owed?
          deliver_welcome
        elsif cancellation_owed?
          deliver_cancellation
        else
          skipped("no email owed")
        end
```

and add:

```ruby
      # trialing and active both grant access.
      ACCESS_GRANTING = %w[trialing active].freeze

      # Eligibility is derived from DURABLE state, not from the status
      # transition, and that is the whole point of this service.
      #
      # A transition is observable exactly once. upsert commits the status
      # before this service runs, so a failed enqueue -- Redis unavailable, say
      # -- leaves the stamp rolled back and the status already committed, and
      # every later retry and nightly sweep then computes previous_status ==
      # status. The email would be owed forever and never sent. The
      # *_email_sent_at columns ARE the record of what is owed; reading them
      # makes the whole path self-healing, because the next sweep simply
      # notices and sends.
      def welcome_owed?
        @membership.welcome_email_sent_at.nil? &&
          ACCESS_GRANTING.include?(@membership.status.to_s)
      end

      # Requires that a welcome actually went out. A membership this app never
      # welcomed must never be sent an ending notice -- which covers the
      # bulk-migrated rows that arrived already cancelled, durably, and replaces
      # the transition-era guard that did the same job only at the moment the
      # row was first seen.
      def cancellation_owed?
        @membership.ended_email_sent_at.nil? &&
          @membership.welcome_email_sent_at.present? &&
          @membership.canceled?
      end
```

- [ ] **Step 4: Run them and watch them pass**

```bash
bin/rails test test/lib/services/billing/membership_notifier_test.rb
```

- [ ] **Step 5: Remove what this made dead**

`MembershipTransition#became_active?` and `#became_canceled?` may now have no callers. Check:

```bash
grep -rn "became_active?\|became_canceled?\|status_changed?" app/ test/
```

If a predicate is unused outside its own tests, **delete it and its tests** — dead code with tests is
worse than dead code, because it looks maintained. Keep `MembershipTransition` itself: it is still
the carrier `ReconcileCustomer#upsert` returns on every path, including the comped-row early return,
and that uniformity was a deliberate fix. Report exactly what you removed and what you kept.

- [ ] **Step 6: Prove the recovery is real**

Revert `welcome_owed?` to `@transition.became_active? && @membership.welcome_email_sent_at.nil?` and
confirm "sends a welcome that an earlier failed enqueue left owed" goes red. Restore, and record the
output. This is the defect the task exists to fix; if that test does not fail against the old logic,
it is not testing the fix.

- [ ] **Step 7: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `fix(billing): recover membership emails from durable state, not transitions`.

---

## Task 3: The cutover backfill that Task 2 makes mandatory

Task 2 introduces a hazard it must ship with. Under durable eligibility, a membership is owed a
welcome whenever it grants access and has no `welcome_email_sent_at`. Every legacy membership
satisfies that — none was ever welcomed by this app. They are held back **only** by
`MembershipEmailScope`, which is `own_only` today.

The moment `MEMBERSHIP_EMAIL_SCOPE=all` is set at legacy cutover, the next nightly sweep would send
a welcome email to **every legacy member on the account**. That is a worse outcome than the defect
Task 2 fixes.

**Files:**
- Create: `web-app/lib/tasks/billing_backfill.rake` (or add to the existing `lib/tasks/billing.rake` — check which exists and follow the file's own conventions)
- Create: `web-app/test/lib/services/billing/backfill_email_stamps_test.rb`
- Create: `web-app/app/lib/services/billing/backfill_email_stamps.rb`

**Interfaces:**
- Produces: `Services::Billing::BackfillEmailStamps.call` → `Result` with `data` = a count hash
  `{welcome: n, ended: n}`; and a `billing:backfill_email_stamps` rake task wrapping it.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/billing/backfill_email_stamps_test.rb`:

```ruby
require "test_helper"

module Services
  module Billing
    class BackfillEmailStampsTest < ActiveSupport::TestCase
      include ActionMailer::TestHelper

      test "stamps a membership that was never welcomed" do
        membership = memberships(:regular_user_monthly)
        membership.update!(welcome_email_sent_at: nil, status: :active)

        BackfillEmailStamps.call

        assert_not_nil membership.reload.welcome_email_sent_at
      end

      test "stamps the ending notice on a membership that is already cancelled" do
        membership = memberships(:regular_user_monthly)
        membership.update!(status: :canceled, welcome_email_sent_at: nil, ended_email_sent_at: nil)

        BackfillEmailStamps.call

        assert_not_nil membership.reload.ended_email_sent_at
      end

      # Idempotent: running it twice must not move a stamp that already exists,
      # or a genuine send date would be rewritten to the backfill date.
      test "leaves an existing stamp untouched" do
        original = 3.days.ago.change(usec: 0)
        membership = memberships(:regular_user_monthly)
        membership.update!(welcome_email_sent_at: original)

        BackfillEmailStamps.call

        assert_equal original.to_i, membership.reload.welcome_email_sent_at.to_i
      end

      # The whole point: it must not send anything.
      test "sends no email of any kind" do
        memberships(:regular_user_monthly).update!(welcome_email_sent_at: nil)

        assert_no_enqueued_emails { BackfillEmailStamps.call }
      end

      test "reports how many rows it stamped" do
        memberships(:regular_user_monthly).update!(welcome_email_sent_at: nil, status: :active)

        result = BackfillEmailStamps.call

        assert result.success?
        assert result.data[:welcome] >= 1
      end
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/lib/services/billing/backfill_email_stamps_test.rb
```

Expected: `NameError: uninitialized constant BackfillEmailStamps`.

- [ ] **Step 3: Implement the service**

Create `web-app/app/lib/services/billing/backfill_email_stamps.rb`:

```ruby
module Services
  module Billing
    # Marks every existing membership as "already emailed", so that opening
    # MEMBERSHIP_EMAIL_SCOPE to `all` does not mail the entire back catalogue.
    #
    # MembershipNotifier derives eligibility from durable state: a membership
    # that grants access and has no welcome_email_sent_at is owed a welcome.
    # That is what makes a failed enqueue recoverable. It also means every
    # legacy membership -- none of which this app ever welcomed -- is one
    # config flag away from being owed one. Run this immediately BEFORE
    # flipping the scope at legacy cutover.
    #
    # Idempotent and additive: it only ever fills a nil stamp, never moves an
    # existing one, and never sends anything.
    class BackfillEmailStamps
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        now = Time.current

        welcome = ::Membership.where(welcome_email_sent_at: nil).update_all(
          welcome_email_sent_at: now, updated_at: now
        )

        ended = ::Membership.where(ended_email_sent_at: nil, status: :canceled).update_all(
          ended_email_sent_at: now, updated_at: now
        )

        Rails.logger.info("[billing] backfilled email stamps: welcome=#{welcome} ended=#{ended}")

        Result.new(success?: true, data: {welcome: welcome, ended: ended}, errors: [])
      end
    end
  end
end
```

This is the one place in this plan permitted to use `update_all`, and only because it is the whole
purpose of the task. It is scoped to rows with a nil stamp, touches no other column, and sends
nothing.

- [ ] **Step 4: Run it and watch it pass**

```bash
bin/rails test test/lib/services/billing/backfill_email_stamps_test.rb
```

- [ ] **Step 5: Add the rake task**

Find the existing billing rake file (`grep -rn "namespace :billing" lib/tasks/`) and add:

```ruby
  desc "Mark every existing membership as already-emailed, before opening MEMBERSHIP_EMAIL_SCOPE"
  task backfill_email_stamps: :environment do
    result = Services::Billing::BackfillEmailStamps.call
    puts "welcome stamps filled: #{result.data[:welcome]}"
    puts "ended stamps filled:   #{result.data[:ended]}"
  end
```

- [ ] **Step 6: Full suite, lint, commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `feat(billing): add the pre-cutover email-stamp backfill`.

---

## Task 4: Documentation

**Files:**
- Modify: `docs/specs/membership-and-stripe-billing.md`
- Modify: `docs/features/email.md`
- Modify: `docs/features/membership-billing.md`
- Modify: `docs/guides/stripe-account-setup.md`
- Modify: `deployment/ENV.md`

- [ ] **Step 1: Close the two open items in the spec**

The first "Carried forward" entry describes the lost-notification defect as OPEN. Replace it, in the
file's existing strikethrough-plus-"Fixed by" convention, with what was actually done: eligibility is
now derived from the `*_email_sent_at` columns rather than the transition, which makes a failed
enqueue self-healing on the next sweep.

Also record the `cancel_at` finding as a resolved entry, including the live-verified values, since it
is the second instance of a Stripe field moving under this subsystem (the first being Basil relocating
`current_period_end` onto the subscription item). State plainly that no offline test can catch the
next one, because the tests stub the shape we expect.

Update the Status line: the code follow-up it names as required before the first sale is now done.

- [ ] **Step 2: Document the backfill as a hard prerequisite**

In `deployment/ENV.md` under `MEMBERSHIP_EMAIL_SCOPE`, and in the spec, state that
`bin/rails billing:backfill_email_stamps` **must** be run immediately before setting the value to
`all`, and why: durable eligibility means every legacy membership is owed a welcome the moment the
gate opens. Make this impossible to miss — it is the single most damaging mistake available in this
subsystem.

- [ ] **Step 3: Update the subsystem docs**

In `docs/features/email.md`, replace the description of transition-driven sending with durable
eligibility, keeping the three-guard framing but correcting what the third guard now is. In
`docs/features/membership-billing.md`, update the `upsert` section for the `cancel_at` read.

- [ ] **Step 4: Add a live cancellation check to the runbook**

`docs/guides/stripe-account-setup.md`'s post-deploy verification should include cancelling the test
subscription and confirming `/membership` reads "Your membership is cancelled and stays active
until…" rather than "renews on…". That is the check that would have caught the `cancel_at` change,
and no unit test can.

- [ ] **Step 5: Verify and commit**

```bash
bin/rails test
bundle exec standardrb
```

Commit with the message `docs(billing): record the cancel_at and durable-eligibility fixes`.

---

## Notes for the reviewer

1. **Can any email now send twice?** Durable eligibility is a real change in blast radius: anything
   that clears a stamp, or any membership that reaches access-granting state without one, now sends.
   Trace it.
2. **Does Task 3 actually prevent the cutover mail-out?** Set `MEMBERSHIP_EMAIL_SCOPE=all` in a test,
   run the backfill, then run a reconcile over a legacy-shaped membership and confirm nothing sends.
   Then do the same *without* the backfill and confirm something does — proving the task is
   load-bearing rather than decorative.
3. **Task 3 uses `update_all`**, which this project's conventions otherwise forbid. Confirm it is
   scoped to nil stamps only, touches no other column, cannot send, and is genuinely idempotent.
4. **Is `cancellation_owed?`'s dependence on `welcome_email_sent_at` correct?** It means a membership
   whose welcome failed and was later backfilled would still get a cancellation. Judge whether that
   is the right call.
5. **Deploy pipeline:** no migration, but production eager-loads and a constant error in any of these
   files crash-loops all four sites. Confirm `RAILS_ENV=production bin/rails zeitwerk:check` passes
   (you will need four `STORAGE_*` vars from `web-app/.env`; never echo their values).
