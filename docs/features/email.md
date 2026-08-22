# Email

The mail foundation that every future mailer in this app builds on: how ActionMailer is wired up,
how an email picks the right site's branding, and how to test one without waiting for a real send.
This is increment 5 of `docs/specs/membership-and-stripe-billing.md` — see that spec's "Increments"
section for how it fits alongside checkout (6), entitlements (7) and the eight membership emails
(8, documented below in "The eight membership emails") that are built on top of it.

## What exists

- **`MailDeliverySettings`** (`web-app/app/lib/mail_delivery_settings.rb`) — builds the SMTP
  settings hash ActionMailer needs to talk to SendGrid, reading `SENDGRID_API_KEY` from `ENV`. It
  raises `MailDeliverySettings::MissingApiKey` rather than falling back to a placeholder key — a
  placeholder would let the app boot and then fail every send with an opaque SMTP error, or worse,
  if the placeholder ever happened to be a real key, send mail from the wrong account. It is not
  the only reader of `SENDGRID_API_KEY`, though: `config/environments/production.rb` checks the
  variable itself before deciding whether to call this class at all (see "Delivery per
  environment" below), and `lib/tasks/mail.rake` checks it separately to give `mail:smoke` its own
  clear abort message.
- **`MailBranding`** (`web-app/app/lib/mail_branding.rb`) — resolves a domain (`:books`, `:music`,
  `:games`, a string, or `nil`) into the identity an email should wear: which site it claims to be
  from (`site_name`, read from `Rails.application.config.domain_settings` — not duplicated here),
  what colour its header band uses (`brand_color`, hex only), which address it sends from (`from`,
  built from `ENV["MAIL_FROM_ADDRESS"]`), and which host its links point at (`url_options`,
  `root_url`). Deliberately a top-level class, not nested under another module — see the file's own
  header comment on why (the nested-namespace-constant-shadowing gotcha that has bitten this
  codebase more than once).
- **`ApplicationMailer#branded_mail`** (`web-app/app/mailers/application_mailer.rb`) — the private
  method every mailer action calls instead of ActionMailer's own `mail`. Takes `domain:` plus
  whatever `mail` normally takes, resolves `MailBranding.for(domain)`, and merges the resolved
  `from` address in before delegating to `mail`.
- **`SystemMailer#smoke_test`** (`web-app/app/mailers/system_mailer.rb`) — the first real mailer
  built on this foundation, and a delivery-pipeline diagnostic in its own right, not customer-facing
  mail. `smoke_test(domain:, to:)` takes an arbitrary recipient; it doesn't hardcode one. It's
  `mail:smoke` that supplies `ADMIN_NOTIFICATION_EMAIL` as `to:`, and the previews (below) send to
  a hardcoded `preview@example.org` instead.
- **`mail:smoke`** (`web-app/lib/tasks/mail.rake`) — `bin/rails mail:smoke[domain]` (domain defaults
  to `books`). Calls `SystemMailer.smoke_test(...).deliver_now`, not `deliver_later` — the point is
  to see a failure in the terminal that ran the task, not in a Sidekiq retry nobody is watching.
  Aborts up front with a clear message if `ADMIN_NOTIFICATION_EMAIL` or `MAIL_FROM_ADDRESS` is
  unset, or if `SENDGRID_API_KEY` is unset in production.

## The one rule

Every mailer takes a domain **explicitly**, as a keyword argument, and calls `branded_mail` —
never ActionMailer's bare `mail`.

The reason: mail is delivered from a Sidekiq worker process, and `Current.domain` — the
thread-local that request-handling code uses to know which of the four sites is being served — is
`nil` there. There is no request setting it. A mailer that read `Current.domain` instead of taking
an explicit argument would compile without error, pass a naive test, and then send books-branded
mail to a music subscriber in production, silently, because `Current.domain` would resolve to
`nil` (or whatever it happened to be on that worker thread) rather than "music." Nothing would
raise. `ApplicationMailer` and `SystemMailer` have no code that reads `Current` at all, by design —
grepping `Current\.` across `app/mailers/` and every mailer view should always come back empty.

`memberships.origin_domain` is the value to pass for anything membership-related. It is `nil` for
every membership row created before checkout existed — including the entire legacy-data-migration
cohort (see `docs/specs/membership-and-stripe-billing.md`'s "Data migration" section) — which is
exactly why `MailBranding.for(nil)` falling back to books is a supported case, not defensive
padding added just in case. Those members really do have no recorded origin, and books is this
app's original site, so it is the correct default rather than an arbitrary one.

`branded_mail` also sets `self.default_url_options = @branding.url_options` — deliberately on the
*instance* (`self.`), never on the *class* (`self.class.`). `default_url_options` is an
ActiveSupport `class_attribute`, so a class-level write mutates a slot shared by every instance of
that mailer subclass, across every thread, for the life of the process. This was not a hypothetical
concern: `self.class.default_url_options =` was this code's first shipped form, and review
reproduced it as a real cross-thread bug under this app's `concurrency: 5` Sidekiq config
(`config/sidekiq.yml`) — a books email rendering with the music host. Anyone "tidying" that line
back to `self.class.` reintroduces it silently, since it still passes a naive smoke test.
`test/mailers/application_mailer_test.rb`'s `"does not leave default_url_options mutated on the
mailer class after branded_mail runs"` is the regression guard for exactly this.

## Delivery per environment

| Environment | `delivery_method` | Where mail goes |
|---|---|---|
| Production | `:smtp`, configured from `MailDeliverySettings.sendgrid_smtp` | SendGrid, over SMTP on port 587, authenticating with the literal username `apikey` and `SENDGRID_API_KEY` as the password |
| Development | `:file` | `tmp/mails/<recipient>` — one file per recipient address, plain-text MIME source, both the text and HTML parts inline. Nothing leaves the machine. |
| Test | `:test`, set explicitly in `config/environments/test.rb` | `ActionMailer::Base.deliveries`, the normal Rails/Minitest array |

That test row is set explicitly, and deliberately so. `ActionMailer::TestCase` forces `:test`
delivery per test, so mailer tests would land in `ActionMailer::Base.deliveries` either way — but a
test that triggers a send from *outside* that base class gets no such help. Without the explicit
setting, ActionMailer falls through to the `mail` gem's own default of `localhost:25`: an
integration test for one of increment 8's membership emails would fail with a connection error on
CI, or, on any machine running a local MTA, genuinely relay mail to a fixture address. Two lines in
`test.rb` remove that whole class of surprise, so an increment 8 controller or service test can
trigger a real send and assert on `ActionMailer::Base.deliveries` without ceremony.

Production's SMTP settings are guarded, and the guard changes what actually goes wrong when the
key is missing — not just whether the app boots. `config/environments/production.rb` only calls
`MailDeliverySettings.sendgrid_smtp` when `SENDGRID_API_KEY` is present. **When the key is absent,
`sendgrid_smtp` is never called at all, so its `raise MissingApiKey` never runs either.**
`smtp_settings` becomes `{}`, and the `mail` gem quietly falls back to its own built-in default
(`localhost:25`). The app boots — which is the point: a raise here, while
`config/environments/production.rb` is still loading and before Rails has finished booting, would
crash-loop the web container under `bin/docker-entrypoint`'s `bash -e` and 502 all four sites, the
same failure mode described in this repo's "a failing migration is an outage" lesson, just
triggered by a config file instead of a migration. But the resulting *send-time* error is a bare
SMTP connection failure to `localhost:25` — it never mentions `SENDGRID_API_KEY` or `MissingApiKey`
anywhere, so grepping logs for either string finds nothing. A separate initializer
(`config/initializers/mail_delivery_check.rb`) logs
`Rails.logger.warn("SENDGRID_API_KEY is not set; outbound mail will fail at send time")` at boot
when the key is absent in production — it has to live in an initializer rather than in
`production.rb` itself, because `Rails.logger` isn't installed until after environment files
finish loading. That boot-time warning, not the eventual delivery error, is what an operator should
actually grep for.

Two other framework log paths matter here, independent of the above. `ActionMailer::LogSubscriber`
logs a delivery error message at INFO — a rejected-recipient SMTP 5xx can echo the recipient's
address back into the log — and at DEBUG it dumps the entire encoded message, including the body.
`config/environments/production.rb` makes the log level switchable via `RAILS_LOG_LEVEL`, so
flipping it to `debug` during an incident starts writing full email bodies to the container logs;
know that before reaching for it, not after.

## The queue trap — that didn't materialize

`deliver_later` doesn't send mail directly; it enqueues `ActionMailer::MailDeliveryJob` through
ActiveJob, and Sidekiq — this app's queue adapter in production and development —
only pulls jobs from the queues listed in `config/sidekiq.yml`
(`critical`, `default`). If `deliver_later` ever enqueued onto a queue absent from that list, mail
would be accepted, reported as sent, and never actually delivered, with nothing in the app raising
an error to say so.

This was flagged as a real risk going into the implementation, on the strength of a Rails default
predating 6.1 where mail jobs queued onto `:mailers` — a queue this app's `sidekiq.yml` does not
list. **It did not happen.** On this app's actual Rails version (8.1.3.1), `deliver_later_queue_name`
resolves to `nil`, and `ActionMailer::MailDeliveryJob` falls back to ActiveJob's own default queue
name — `"default"` — which *is* one of the two queues `config/sidekiq.yml` lists. No configuration
change was needed to make mail deliverable; nothing was added to `config/application.rb` or any
environment file to force the queue name.

The guard test still exists — `test/mailers/system_mailer_test.rb`, `"deliver_later enqueues onto
a queue Sidekiq actually processes"` — as a forward-looking regression guard, not a fix for
anything currently broken. It asserts the enqueued job's queue is one of the queues in
`config/sidekiq.yml`, by reading that file directly rather than hardcoding `"default"`, so it stays
meaningful if `sidekiq.yml`'s queue list ever changes. It was confirmed to actually fail when the
queue is wrong (setting `config.action_mailer.deliver_later_queue_name = "mailers"` turns it red),
so it is a real guard, just one that never had anything to catch on this Rails version.

## Email HTML is not web HTML

The shared layout (`app/views/layouts/mailer.html.erb`) and every mailer template that extends it
follow email-client rules, not this app's normal frontend rules:

- **Table-based layout**, not flexbox/grid. Many email clients (Outlook's desktop rendering engine
  especially) ignore or mis-render modern CSS layout.
- **Inline styles only**, no `<style>` block and no external stylesheet. Most webmail clients strip
  `<style>` tags or the classes that would reference them.
- **No Tailwind, no daisyUI classes, no CSS custom properties.** None of it survives being emailed —
  there is no build step compiling a stylesheet into the message, so a Tailwind utility class in an
  email template is just an inert `class` attribute, and a `var(--color-primary)` reference resolves
  to nothing.
- **Hex colours, not `oklch()`.** `MailBranding::BRAND_COLORS` stores each domain's brand colour as
  a hex string specifically because `oklch()` — the colour function this app's web CSS uses
  elsewhere — is not supported in mail clients' CSS parsers.
- **`overflow-wrap: anywhere`** on the body cell, carried over from the same user-text lesson that
  applies to web pages: a long unbroken token (a URL, an id) must not be allowed to force the whole
  message wider than the reader's screen.

## ENV vars

| Variable | What breaks if it's missing |
|---|---|
| `SENDGRID_API_KEY` | `MailDeliverySettings.sendgrid_smtp` raises `MailDeliverySettings::MissingApiKey` — but only when something actually calls it. In production, `production.rb`'s guard (see "Delivery per environment" above) skips that call entirely when the key is absent, so the app boots; `config/initializers/mail_delivery_check.rb` logs a `Rails.logger.warn` naming the variable instead, and every send then fails later with a bare `localhost:25` connection error that names neither the variable nor the exception. `mail:smoke` aborts up front with a clear message if it's missing in production, independent of the above. |
| `MAIL_FROM_ADDRESS` | `MailBranding#from` raises `MailBranding::MissingFromAddress` the moment any mailer tries to build a `from` address — which means every `branded_mail` call fails, in every environment, development and previews included. There is no fallback address; the code refuses rather than sending from something malformed. |
| `ADMIN_NOTIFICATION_EMAIL` | `mail:smoke` aborts immediately with "ADMIN_NOTIFICATION_EMAIL is not set" — nothing to send the smoke test to. Also read by `AdminMailer#admin_address` (see "The eight membership emails" below), which raises `AdminMailer::MissingAdminAddress` the moment its job performs if the variable is blank. Already set in production as of this writing, so that raise is a safety net for a future misconfiguration, not something covering for a variable nobody has set yet. |

None of these three have a default anywhere in the codebase — not in a test helper, a fixture, or
an environment file. (`MEMBERSHIP_EMAIL_SCOPE`, added alongside the eight membership emails below,
is the exception: it *does* default, to `own_only`, on purpose — see that section.) See
`deployment/ENV.md`'s "Email Configuration" section for the full
production reference, and `docs/guides/stripe-account-setup.md` for how they get set in production.

## Previews

`http://localhost:3000/rails/mailers` lists every mailer preview: the four `SystemMailer#smoke_test`
previews in `test/mailers/previews/system_mailer_preview.rb`; the nine
`MembershipMailer` previews in `test/mailers/previews/membership_mailer_preview.rb` (one per action
per interesting domain, plus a nil-domain variant for every one of the four actions — not
hypothetical, every membership predating checkout has `origin_domain: nil`); and the eight
`AdminMailer` previews in `test/mailers/previews/admin_mailer_preview.rb` (same shape: one per
action, plus a nil-domain variant for each). All the `Membership`/`Donation` records these build are
constructed **in memory only** (`Membership.new`/`Donation.new`, never `.create`/`.save`) — a preview
must not write to the database.

Previews render for real, through `MailBranding#from`, so **they raise
`MailBranding::MissingFromAddress` unless `MAIL_FROM_ADDRESS` is set** in the environment the server
is running in — the code has no preview-mode exception to the "no default address" rule. The
`AdminMailer` previews additionally need `ADMIN_NOTIFICATION_EMAIL` set, for the same reason
`AdminMailer#admin_address` needs it in production. Start the server with both set:

```bash
MAIL_FROM_ADDRESS=contact@thegreatestbooks.org ADMIN_NOTIFICATION_EMAIL=ops@example.org bin/rails server
```

then visit `/rails/mailers`. For everyday local work, add both variables to `web-app/.env` instead
of prefixing every command — see `deployment/ENV.md`'s example `.env` block for the format.

## The eight membership emails (increment 8)

Two mailers, both built on the foundation above and neither reading `Current`: `MembershipMailer`
(`web-app/app/mailers/membership_mailer.rb`, customer-facing) and `AdminMailer`
(`web-app/app/mailers/admin_mailer.rb`, operational, never customer-facing). Eight actions between
them, and all the decision logic for *whether* to send lives outside both mailers, in
`Services::Billing::MembershipNotifier` (`web-app/app/lib/services/billing/membership_notifier.rb`)
and in `RecordDonation#deliver_receipt` — a mailer here only ever renders and addresses a message
it has already been told to send.

| Mailer#action | Triggered by | What it says |
|---|---|---|
| `MembershipMailer#welcome` | A membership this app sold transitions into `trialing`/`active` for the first time | Welcome, renewal date |
| `MembershipMailer#canceled_with_other_active` | That membership cancels, but the user still holds another access-granting row | Cancelled, but access continues via the other membership |
| `MembershipMailer#canceled_last` | That membership cancels and it was the user's only access-granting row | Cancelled, access ends at `current_period_end` |
| `MembershipMailer#donation_receipt` | `RecordDonation` commits a donation this app took, with a collected email | Thank-you receipt for the amount given |
| `AdminMailer#new_subscription` | Same trigger as `#welcome` | New membership on `<site>`, interval, renewal date, membership id — no customer address |
| `AdminMailer#subscription_canceled` | Same trigger as `#canceled_with_other_active`/`#canceled_last` | Membership cancelled on `<site>`, access-until date, membership id — no customer address |
| `AdminMailer#new_donation` | `RecordDonation` commits a donation this app took, attributable to a signed-in user | New donation: `$amount`, donation id and user id — no customer address |
| `AdminMailer#anonymous_donation` | Same trigger, but `donation.user_id` is blank | New anonymous donation: `$amount`, donation id — no customer address, no user id |

The admin notice always fires for a donation this app took, even when there is no collected email
to send the donor a receipt — a donation with no address is still revenue the owner should hear
about, so `#new_donation`/`#anonymous_donation` do not depend on `#donation_receipt` having sent.

### Three independent guards, and why each exists

`MembershipNotifier#call` checks three things, in order, before it will enqueue anything, and each
guards against a different failure:

1. **`MembershipEmailScope.may_email?`** (`web-app/app/lib/membership_email_scope.rb`) — the
   ownership gate. The legacy books app is still live on the *same* Stripe account and still emails
   its own subscribers, and every webhook endpoint — this app's and legacy's — receives every event
   on that shared account. Without this gate, a legacy subscriber would get two welcome emails for
   one subscription, one from each app. `MembershipEmailScope.may_email?(record)` is `true` when
   `MEMBERSHIP_EMAIL_SCOPE=all`, or when the record's own `sold_by_this_app?` (`origin_domain`
   present for a `Membership`, `domain` present for a `Donation`) says this app is the one that sold
   it. Defaults to `own_only`; an unrecognised value also falls back to `own_only`, deliberately — a
   typo in production must never silently start double-emailing every legacy subscriber. **Set
   `MEMBERSHIP_EMAIL_SCOPE=all` at legacy cutover** — see `deployment/ENV.md`'s entry for what
   happens if that switch is missed (every legacy-era member, silently, forever, gets no
   cancellation email from anyone).
2. **The `welcome_email_sent_at`/`ended_email_sent_at` timestamps on `Membership`** — the once-only
   guard for memberships. The nightly sweep re-reconciles every subscription on the account, so
   "this membership is currently active" is true every single night; without a timestamp, every
   member would get a new welcome email every night. `MembershipNotifier#deliver_welcome` and
   `#deliver_cancellation` both stamp their timestamp column and enqueue the mailer inside one
   `@membership.with_lock do ... end` block, **stamp before enqueue**. That ordering is
   load-bearing, not incidental: two webhook endpoints deliver every event, so two jobs routinely
   race to process the same transition concurrently, and stamping first means the loser of that
   race finds the timestamp already set and sends nothing. `with_lock` wrapping both statements in
   one transaction means a *failed* enqueue (Redis down, say) rolls the stamp back too, so a
   transient failure can still be retried on the next reconcile — the stamp only survives a
   *successful* enqueue.

   **Donations have no equivalent column, and that asymmetry is deliberate,** not an oversight.
   `RecordDonation#call`'s guard is `deliver_receipt(donation) if donation.previously_new_record?` —
   only the call that actually performed the `INSERT` sends, so an ordinary retry of an
   already-committed donation (e.g. `ProcessStripeEventJob` re-enqueuing because a *later* step in
   the same job failed) does not re-receipt the donor. The accepted consequence: if the row commits
   but the `deliver_later` enqueue itself then fails (a Redis blip, the process dying in that exact
   window), that donation is never retried as new, so the receipt never goes out — and nothing
   records that one was owed, because there is no `*_email_sent_at`-shaped column to fail to stamp.
   This is a silent miss, on purpose: for a one-time receipt, a rare missed email is judged the
   better failure direction than double-mailing a donor, whereas a membership's welcome/cancellation
   pair gets the stronger, resendable guarantee because it is a first-class column on a row that
   already exists and already gets re-read every night.
3. **The transition itself** — `Services::Billing::MembershipTransition`
   (`web-app/app/lib/services/billing/membership_transition.rb`). "Currently active" is true every
   night; "just became active" is true once. `ReconcileCustomer#upsert` captures the membership's
   `status` immediately before `assign_attributes` overwrites it, and returns a
   `MembershipTransition` — on *every* path, including the comped-row collision guard's early
   return, which yields a no-op transition (`previous_status` equal to the row's own current
   status, so nothing downstream can mistake an admin's manually-comped row for a fresh Stripe
   activation). `#became_active?` treats `trialing` and `active` as the same access-granting state,
   so converting a trial to a paid subscription is not a second welcome email. `#became_canceled?`
   excludes a `nil` `previous_status` — a brand-new row that arrives already cancelled (the
   account-wide migration's bulk import, or a subscription cancelled before this app ever saw it)
   is not a fresh cancellation event and must not trigger a cancellation email for something the
   person cancelled long ago.

### `deliver_later` does not run the mailer body

Worth stating plainly, because an earlier draft of this subsystem's own code comments got it
backwards: **`deliver_later` does not execute anything in the mailer.** It only serialises
`(mailer_class, action, args)` into an `ActionMailer::MailDeliveryJob` and hands that to ActiveJob.
The mailer action's body — building `@membership`/`@donation`, rendering the templates, resolving
`MailBranding`, and the actual SMTP round-trip — all run later, when that job **performs**, which in
this app's Sidekiq-backed queues means on a worker process, not inside the request or the
transaction that called `deliver_later`.

This matters for where an exception surfaces. `AdminMailer#admin_address` raises
`AdminMailer::MissingAdminAddress` if `ADMIN_NOTIFICATION_EMAIL` is ever unset — but only when the
job performs, never when `AdminMailer.new_subscription(membership).deliver_later` is *called*.
Concretely, `MembershipNotifier#deliver_welcome`/`#deliver_cancellation` place the `AdminMailer`
send **outside** the `with_lock` block that stamps `welcome_email_sent_at`/`ended_email_sent_at`:
not because the admin mailer's action body could raise transactionally (it can't; `deliver_later`
never runs it there), but because the *enqueue itself* — the synchronous push onto Redis — can fail
independently, and if that failure shared the lock with the customer-facing send, a rolled-back
stamp would leave the customer's job already irrevocably queued, reopening the exact double-send
the stamp-before-enqueue ordering exists to prevent. See the comments on both methods in
`membership_notifier.rb` for the full trace, including how this was confirmed empirically (driving
`ActionMailer::MailDeliveryJob#perform_now` directly with `ADMIN_NOTIFICATION_EMAIL` unset, and
observing no raise at enqueue time).

### PII: admin mail carries ids, never addresses

`AdminMailer`'s four templates reference a membership or donation's **id**, plan interval, amount,
and which site the sale came from — never a customer's email address, name, or any other Stripe
customer field. This is deliberate, not an oversight: an admin notice is forwarded around and
archived like any other mail, this repository is public, and there is no operational reason the
owner needs a customer's address inline in a "you got a new subscriber" ping — the membership/
donation id is enough to look the record up in `/admin` if more detail is ever needed.

### The cutover switch

`MembershipEmailScope` (above) is the single point of control for when this app starts emailing
about *every* membership and donation on the shared Stripe account rather than only the ones it
sold. See `deployment/ENV.md`'s `MEMBERSHIP_EMAIL_SCOPE` entry for the full production
runbook note — in short: leave it unset (or `own_only`) while legacy is still live, and set it to
`all` at legacy cutover, in the same change that retires legacy's webhook endpoint.

## See also

- `docs/specs/membership-and-stripe-billing.md` — the spec this is increment 5 of, and whose
  increment 8 is "The eight membership emails" above.
- `docs/features/membership-billing.md` — the billing side of the coexistence rule the ownership
  gate implements: what `ReconcileCustomer`/`RecordDonation` write to `origin_domain`/`domain`, and
  why legacy's own guard is the mirror image of `MembershipEmailScope`.
- `docs/guides/stripe-account-setup.md` — the production runbook, including the SendGrid setup step.
- `deployment/ENV.md` — the full environment-variable reference, including `MEMBERSHIP_EMAIL_SCOPE`.
