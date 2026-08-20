# Email

The mail foundation that every future mailer in this app builds on: how ActionMailer is wired up,
how an email picks the right site's branding, and how to test one without waiting for a real send.
This is increment 5 of `docs/specs/membership-and-stripe-billing.md` — see that spec's "Increments"
section for how it fits alongside checkout (6), entitlements (7) and the eight membership emails
(8) that will be built on top of it.

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
| Test | (ActionMailer's test delivery method) | `ActionMailer::Base.deliveries`, the normal Rails/Minitest array |

That test row is Rails' own default, not something this branch's `config/environments/test.rb`
sets — grepping that file for `delivery_method` finds nothing. Mail lands in
`ActionMailer::Base.deliveries` only because every mailer test here subclasses
`ActionMailer::TestCase`, which forces the `:test` delivery method per test. An integration or
service test that triggers `deliver_now`/`deliver_later` from outside that base class would not
get this for free — worth remembering once increment 8's membership emails start being triggered
from controller or service code rather than from mailer tests directly.

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

## The queue trap — that didn't materialize

`deliver_later` doesn't send mail directly; it enqueues `ActionMailer::MailDeliveryJob` through
ActiveJob, and Sidekiq — this app's queue adapter in every environment, including development —
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
| `ADMIN_NOTIFICATION_EMAIL` | `mail:smoke` aborts immediately with "ADMIN_NOTIFICATION_EMAIL is not set" — nothing to send the smoke test to. Not read anywhere else yet; a future membership-email increment may add more operational recipients that reuse it. |

None of these three have a default anywhere in the codebase — not in a test helper, a fixture, or
an environment file. See `deployment/ENV.md`'s "Email Configuration" section for the full
production reference, and `docs/guides/stripe-account-setup.md` for how they get set in production.

## Previews

`http://localhost:3000/rails/mailers` lists every mailer preview — currently the four
`SystemMailer#smoke_test` previews in `test/mailers/previews/system_mailer_preview.rb`, one per
domain plus one for an unrecognized domain (which should render with books' branding, proving the
`MailBranding` fallback).

Previews render for real, through `MailBranding#from`, so **they raise
`MailBranding::MissingFromAddress` unless `MAIL_FROM_ADDRESS` is set** in the environment the server
is running in — the code has no preview-mode exception to the "no default address" rule. Start the
server with the variable set:

```bash
MAIL_FROM_ADDRESS=noreply@thegreatestbooks.org bin/rails server
```

then visit `/rails/mailers`. For everyday local work, add `MAIL_FROM_ADDRESS` (and
`ADMIN_NOTIFICATION_EMAIL`, needed by `mail:smoke`) to `web-app/.env` instead of prefixing every
command — see `deployment/ENV.md`'s example `.env` block for the format.

## See also

- `docs/specs/membership-and-stripe-billing.md` — the spec this is increment 5 of.
- `docs/guides/stripe-account-setup.md` — the production runbook, including the SendGrid setup step.
- `deployment/ENV.md` — the full environment-variable reference, including these three.
