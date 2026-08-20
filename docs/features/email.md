# Email

The mail foundation that every future mailer in this app builds on: how ActionMailer is wired up,
how an email picks the right site's branding, and how to test one without waiting for a real send.
This is increment 5 of `docs/specs/membership-and-stripe-billing.md` — see that spec's "Increments"
section for how it fits alongside checkout (6), entitlements (7) and the eight membership emails
(8) that will be built on top of it.

## What exists

- **`MailDeliverySettings`** (`web-app/app/lib/mail_delivery_settings.rb`) — builds the SMTP
  settings hash ActionMailer needs to talk to SendGrid, reading `SENDGRID_API_KEY` from `ENV`. It
  is the *only* place that reads that variable; everything else gets delivery settings through it.
  It raises `MailDeliverySettings::MissingApiKey` rather than falling back to a placeholder key —
  a placeholder would let the app boot and then fail every send with an opaque SMTP error, or worse,
  if the placeholder ever happened to be a real key, send mail from the wrong account.
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
  mail. Sends a short branded email to `ADMIN_NOTIFICATION_EMAIL`.
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

## Delivery per environment

| Environment | `delivery_method` | Where mail goes |
|---|---|---|
| Production | `:smtp`, configured from `MailDeliverySettings.sendgrid_smtp` | SendGrid, over SMTP on port 587, authenticating with the literal username `apikey` and `SENDGRID_API_KEY` as the password |
| Development | `:file` | `tmp/mails/<recipient>` — one file per recipient address, plain-text MIME source, both the text and HTML parts inline. Nothing leaves the machine. |
| Test | (ActionMailer's test delivery method) | `ActionMailer::Base.deliveries`, the normal Rails/Minitest array |

Production's SMTP settings are built lazily and guarded: `config/environments/production.rb` only
calls `MailDeliverySettings.sendgrid_smtp` when `SENDGRID_API_KEY` is present, and uses an empty
hash otherwise. Without that guard, a missing key would raise `MissingApiKey` while
`config/environments/production.rb` itself is loading — before Rails has finished booting — which
would crash-loop the web container under `bin/docker-entrypoint`'s `bash -e` and 502 all four
sites, the same failure mode described in this repo's "a failing migration is an outage" lesson,
just triggered by a config file instead of a migration. Deferring the raise to actual send time
(`raise_delivery_errors = true`) turns a missing key into a failed request instead of a down app.

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
| `SENDGRID_API_KEY` | `MailDeliverySettings.sendgrid_smtp` raises `MailDeliverySettings::MissingApiKey`. In production this is deferred to send time by the guard in `production.rb` (see "Delivery per environment" above), so the app still boots — but every send fails until it's set. `mail:smoke` also aborts up front if it's missing in production. |
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
