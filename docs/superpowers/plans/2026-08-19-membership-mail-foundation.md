# Mail Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on ActionMailer over SendGrid SMTP and give the app a domain-aware mailer base class, so increment 8 can write the eight membership emails without inventing any infrastructure.

**Architecture:** ActionMailer is currently *disabled* — its railtie is commented out in
`config/application.rb` and there is no `app/mailers/` directory. This increment enables it, points
delivery at SendGrid's SMTP endpoint via ENV, and adds one small value object (`MailBranding`) that
turns a domain key into a from-address, site name, brand colour and URL host. `ApplicationMailer`
takes that domain as an **explicit argument** rather than reading `Current.domain`, because mailers
run inside Sidekiq where `Current` is unset. A single `SystemMailer#smoke_test` plus a rake task
proves the whole path end to end against the real SendGrid account before any customer-facing email
depends on it.

**Tech Stack:** Rails 8.1, ActionMailer (built in — no SendGrid gem), Sidekiq via ActiveJob, Minitest
+ Mocha, standardrb.

**Spec:** `docs/specs/membership-and-stripe-billing.md` — increment 5 in the Increments table, and the
"Email" subsection of Architecture.

## Global Constraints

Copied from the spec and from `CLAUDE.md`. Every task's requirements implicitly include these.

- **Secrets are ENV vars managed with SOPS + age** (`deployment/SECRETS.md`), never
  `Rails.application.credentials` — which is unused in this app.
- **No placeholder secret defaults, ever.** No `ENV.fetch("SENDGRID_API_KEY", "sk-test")`, no
  `|| "changeme"`. A missing secret must fail loudly, not send mail from a wrong identity.
- **Never log an email body, a recipient list, or an exception message from a delivery failure.**
  This repo is public. Log the mailer class and action only.
- **Plain library objects live in `app/lib/`**, services in `app/lib/services/<domain>/`, jobs in
  `app/sidekiq/` — never `app/services/` or `app/jobs/`.
- **Use Rails generators** — `bin/rails generate mailer`, never hand-created mailer files.
- **`bundle exec standardrb`** is the linter, not `bin/rubocop`.
- **`bin/rails test` must be green** before any task is reported complete.
- **Run all commands from `web-app/`.** Docs live in `docs/` at the project root.
- **Shared code stays top-level.** `MailBranding` and `MailDeliverySettings` must NOT be nested
  inside another module: a constant looked up from within a nested module resolves against that
  module first, which has produced confusing `NameError`s in this codebase more than once.
- **Scope cross-domain work to books, music and games.** The unknown-domain fallback in Task 2
  covers every other key without a special case; do not add one.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/application.rb` | Enable the ActionMailer railtie (one commented line). |
| `config/environments/production.rb` | SendGrid SMTP delivery; ActiveJob → Sidekiq. |
| `config/environments/development.rb` | File delivery to `tmp/mails`; ActiveJob → Sidekiq. |
| `app/lib/mail_delivery_settings.rb` | Builds the SMTP settings hash from ENV. One responsibility: no ENV reads scattered through environment files. |
| `app/lib/mail_branding.rb` | Domain key → site name, from-address, brand colour, URL host/port. The only place that knows a domain has an email identity. |
| `app/mailers/application_mailer.rb` | Base class. Takes a domain explicitly, sets from / layout / `default_url_options` from `MailBranding`. |
| `app/mailers/system_mailer.rb` | One operational mailer: `smoke_test`. Proves the plumbing. |
| `app/views/layouts/mailer.html.erb` / `.text.erb` | Shared email chrome, branded from `@branding`. |
| `app/views/system_mailer/smoke_test.html.erb` / `.text.erb` | Smoke email body. |
| `lib/tasks/mail.rake` | `mail:smoke` — send the smoke email; refuse when config is missing. |
| `test/lib/mail_delivery_settings_test.rb` | SMTP settings, including the no-placeholder rule. |
| `test/lib/mail_branding_test.rb` | Per-domain resolution, fallback, comma-separated host. |
| `test/mailers/application_mailer_test.rb` | Domain-awareness of the base class. |
| `test/mailers/system_mailer_test.rb` | The smoke mailer, and the queue-name regression test. |
| `test/mailers/previews/system_mailer_preview.rb` | Browser preview. |
| `deployment/ENV.md` | The three new ENV vars. |
| `docs/features/email.md` | Feature doc (project convention: every service gets one). |

---

## Task 1: Enable ActionMailer and configure delivery

Enabling a railtie changes application boot for every environment. This task's real test is the
**full existing suite**, not just the new file.

**Files:**
- Modify: `web-app/config/application.rb` (line 10, the commented `action_mailer/railtie`)
- Modify: `web-app/config/environments/production.rb`
- Modify: `web-app/config/environments/development.rb`
- Create: `web-app/app/lib/mail_delivery_settings.rb`
- Create: `web-app/test/lib/mail_delivery_settings_test.rb`
- Modify: `deployment/ENV.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `MailDeliverySettings.sendgrid_smtp` → `Hash` with keys `:address`, `:port`,
  `:domain`, `:user_name`, `:password`, `:authentication`, `:enable_starttls_auto`.
  `MailDeliverySettings::MissingApiKey` (a `StandardError` subclass).

- [ ] **Step 1: Confirm the `with_env` test helper exists and takes a hash**

```bash
grep -n "def with_env" -A 12 test/test_helper.rb
```

It should already be there and take a **hash**, not keyword arguments. If it is missing, add this
inside `ActiveSupport::TestCase` in `test/test_helper.rb`:

```ruby
def with_env(vars)
  original = vars.keys.index_with { |key| ENV[key] }
  vars.each { |key, value| ENV[key] = value }
  yield
ensure
  original.each { |key, value| ENV[key] = value }
end
```

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lib/mail_delivery_settings_test.rb`:

```ruby
require "test_helper"

class MailDeliverySettingsTest < ActiveSupport::TestCase
  test "builds SendGrid SMTP settings with the API key from ENV" do
    with_env("SENDGRID_API_KEY" => "SG.a-real-looking-key") do
      settings = MailDeliverySettings.sendgrid_smtp

      assert_equal "smtp.sendgrid.net", settings[:address]
      assert_equal 587, settings[:port]
      assert_equal "SG.a-real-looking-key", settings[:password]
      assert_equal :plain, settings[:authentication]
      assert settings[:enable_starttls_auto]
    end
  end

  # SendGrid's SMTP username is the literal string "apikey" for every account --
  # it is not the account name. Getting this wrong authenticates as nobody and
  # every send fails with a 535.
  test "the SMTP username is the literal string apikey, not the key itself" do
    with_env("SENDGRID_API_KEY" => "SG.some-key") do
      assert_equal "apikey", MailDeliverySettings.sendgrid_smtp[:user_name]
    end
  end

  test "raises rather than substituting a placeholder when the API key is missing" do
    with_env("SENDGRID_API_KEY" => nil) do
      error = assert_raises(MailDeliverySettings::MissingApiKey) do
        MailDeliverySettings.sendgrid_smtp
      end
      # The message must name the variable but must never echo a value.
      assert_match "SENDGRID_API_KEY", error.message
    end
  end

  test "raises when the API key is present but blank" do
    with_env("SENDGRID_API_KEY" => "   ") do
      assert_raises(MailDeliverySettings::MissingApiKey) { MailDeliverySettings.sendgrid_smtp }
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/lib/mail_delivery_settings_test.rb
```

Expected: FAIL with `NameError: uninitialized constant MailDeliverySettings`.

- [ ] **Step 4: Enable the ActionMailer railtie**

In `web-app/config/application.rb`, change line 10 from:

```ruby
# require "action_mailer/railtie"
```

to:

```ruby
require "action_mailer/railtie"
```

Leave `action_mailbox/engine` commented out — nothing receives mail.

- [ ] **Step 5: Create the settings object**

Create `web-app/app/lib/mail_delivery_settings.rb`:

```ruby
# Builds the SMTP settings ActionMailer needs to talk to SendGrid.
#
# This exists so that exactly one place reads SENDGRID_API_KEY. Environment
# files call it; nothing else should.
#
# It raises rather than falling back to a default. A placeholder key would let
# the app boot and then fail every send with an opaque 535 from SendGrid -- or,
# if the placeholder were ever a real key, send mail from the wrong account.
class MailDeliverySettings
  class MissingApiKey < StandardError; end

  # SendGrid authenticates SMTP with the literal username "apikey" and the API
  # key as the password. Same for every account -- it is not the account's
  # username.
  SMTP_USER_NAME = "apikey"
  SMTP_ADDRESS = "smtp.sendgrid.net"
  SMTP_PORT = 587

  def self.sendgrid_smtp
    api_key = ENV["SENDGRID_API_KEY"]

    if api_key.blank?
      raise MissingApiKey, "SENDGRID_API_KEY is not set; refusing to build SMTP settings"
    end

    {
      address: SMTP_ADDRESS,
      port: SMTP_PORT,
      domain: ENV.fetch("BOOKS_DOMAIN", "thegreatestbooks.org"),
      user_name: SMTP_USER_NAME,
      password: api_key,
      authentication: :plain,
      enable_starttls_auto: true
    }
  end
end
```

The `:domain` key is the HELO domain the SMTP client announces, not the from-address; any domain the
account controls is fine, which is why a plain default is acceptable there and nowhere else in this
file.

- [ ] **Step 6: Run the test to verify it passes**

```bash
bin/rails test test/lib/mail_delivery_settings_test.rb
```

Expected: 4 runs, 0 failures.

- [ ] **Step 7: Configure production delivery**

In `web-app/config/environments/production.rb`, replace the commented ActiveJob line (around line 53,
`# config.active_job.queue_adapter = :resque`) with:

```ruby
  # Sidekiq is already this app's job backend (app/sidekiq/), but ActiveJob was
  # never pointed at it because nothing used ActiveJob. deliver_later does, so
  # it must be -- otherwise mail queues into the in-process async adapter and is
  # lost on every deploy.
  config.active_job.queue_adapter = :sidekiq
```

Then add, near the other `config.action_*` settings:

```ruby
  # Mail
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = MailDeliverySettings.sendgrid_smtp
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_caching = false
  # Each mailer sets its own host from MailBranding, because the right host
  # depends on which site the mail is about. This default only backstops a
  # mailer that forgets.
  config.action_mailer.default_url_options = {host: ENV.fetch("BOOKS_DOMAIN", "thegreatestbooks.org"), protocol: "https"}
```

`MailDeliverySettings` is autoloaded from `app/lib`, and environment files run after autoloading is
configured, so referencing it here should work. If the app fails to boot with a `NameError`, that is
the signal this assumption is wrong — add
`require Rails.root.join("app/lib/mail_delivery_settings")` at the top of the environment file and
note it in your report.

**Careful:** `MailDeliverySettings.sendgrid_smtp` raises when the key is absent, and this line runs at
boot. In production the key will be present. But confirm this does not break
`RAILS_ENV=production bin/rails zeitwerk:check` when run locally without the key — if it does, wrap
the assignment so a missing key defers the failure to send time:

```ruby
  config.action_mailer.smtp_settings = ENV["SENDGRID_API_KEY"].present? ? MailDeliverySettings.sendgrid_smtp : {}
```

Report which form you shipped and why.

- [ ] **Step 8: Configure development delivery**

In `web-app/config/environments/development.rb`, add:

```ruby
  # Mail: write to tmp/mails instead of sending. No gem needed, and nothing can
  # accidentally email a real person from a developer's machine.
  config.action_mailer.delivery_method = :file
  config.action_mailer.file_settings = {location: Rails.root.join("tmp/mails")}
  config.action_mailer.perform_deliveries = true
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_caching = false
  config.active_job.queue_adapter = :sidekiq
```

Do **not** add anything to `config/environments/test.rb`. ActionMailer already defaults to
`delivery_method = :test` there, and leaving the ActiveJob adapter at its Rails default keeps this
change from touching ActiveStorage's jobs in the existing suite. Mailer tests get a test queue
adapter per-test by including `ActiveJob::TestHelper`, which is what it is for.

- [ ] **Step 9: Verify the app still boots and the whole suite is green**

```bash
bin/rails zeitwerk:check
bin/rails runner 'puts ActionMailer::Base.delivery_method'
bin/rails test
bundle exec standardrb
```

Expected: `zeitwerk:check` clean; the runner prints `file`; the **full** suite green with no new
failures; standardrb clean.

This full-suite run is the point of the task. Enabling a railtie applies
`config.load_defaults 8.0`'s ActionMailer defaults across the app for the first time. If something
distant breaks, it breaks here, where the cause is obvious — not three tasks later.

- [ ] **Step 10: Document the ENV variables**

In `deployment/ENV.md`, following the existing `#### VARIABLE_NAME` format used by the Stripe entries
around line 164, add an `### Email Configuration` section:

```markdown
### Email Configuration

#### SENDGRID_API_KEY
- **Description**: SendGrid API key, used as the SMTP password. The SMTP *username* is the literal
  string `apikey` and is not configurable.
- **Required**: Yes
- **Used By**: web, worker
- **Security**: Never commit this value. Managed via SOPS — see `deployment/SECRETS.md`.
- **Note**: The app raises `MailDeliverySettings::MissingApiKey` rather than falling back to a
  placeholder, so a missing key fails loudly instead of sending from the wrong identity.

#### MAIL_FROM_ADDRESS
- **Description**: The envelope from-address for all outbound mail, e.g. `noreply@thegreatestbooks.org`.
  Must be an address on a domain authenticated in SendGrid, or delivery fails SPF/DKIM and lands in
  spam.
- **Required**: Yes
- **Used By**: web, worker
- **Note**: One address serves every site. The *display name* varies per site ("The Greatest Books",
  "The Greatest Music", ...) — see `app/lib/mail_branding.rb`.

#### ADMIN_NOTIFICATION_EMAIL
- **Description**: Recipient for administrative notifications and the `mail:smoke` test email.
- **Required**: Yes
- **Used By**: web, worker
```

Also add them to the example block near line 231 alongside `STRIPE_SECRET_KEY`:

```
SENDGRID_API_KEY=SG.your_sendgrid_api_key_here
MAIL_FROM_ADDRESS=noreply@thegreatestbooks.org
ADMIN_NOTIFICATION_EMAIL=you@example.com
```

- [ ] **Step 11: Commit**

Stage `config/application.rb`, `config/environments/production.rb`,
`config/environments/development.rb`, `app/lib/mail_delivery_settings.rb`,
`test/lib/mail_delivery_settings_test.rb` and `deployment/ENV.md`, then commit with the message
`feat(mail): enable ActionMailer and configure SendGrid SMTP delivery`.

---

## Task 2: `MailBranding` — resolve a domain to its email identity

**Files:**
- Create: `web-app/app/lib/mail_branding.rb`
- Create: `web-app/test/lib/mail_branding_test.rb`

**Interfaces:**
- Consumes: `Rails.application.config.domains` (a `Hash` of symbol → host string, possibly
  comma-separated) and `Rails.application.config.domain_settings` (symbol → hash with a `:name`
  key). Both are defined in `config/initializers/domain_config.rb`.
- Produces: `MailBranding.for(domain)` → a `MailBranding` instance responding to `key` (Symbol),
  `site_name` (String), `from` (String, `"Name <address>"`), `brand_color` (String hex),
  `url_options` (Hash with `:host`, `:protocol`, and `:port` outside production).
  `MailBranding::MissingFromAddress` (a `StandardError` subclass).

**Why an explicit argument and not `Current.domain`:** mailers are delivered from Sidekiq, where
`Current` is unset. Anything reading `Current` inside a mailer silently sends a books-branded email
to a music subscriber. The spec calls this out, and `memberships.origin_domain` exists precisely so
the caller can pass the right value.

**Why one from-address with per-site display names:** SendGrid authenticates a *sending domain*.
Sending `from` three different domains needs three domain authentications and three sets of DNS
records; every one that is missing lands mail in spam. One authenticated address with a per-site
display name gets the branding at no deliverability cost.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/mail_branding_test.rb`:

```ruby
require "test_helper"

class MailBrandingTest < ActiveSupport::TestCase
  test "resolves the site name for each domain" do
    assert_equal "The Greatest Books", MailBranding.for(:books).site_name
    assert_equal "The Greatest Music", MailBranding.for(:music).site_name
    assert_equal "The Greatest Games", MailBranding.for(:games).site_name
  end

  test "accepts a string domain, as stored in memberships.origin_domain" do
    assert_equal :music, MailBranding.for("music").key
    assert_equal "The Greatest Music", MailBranding.for("music").site_name
  end

  # Every membership created before checkout existed -- including every row from
  # the account-wide migration -- has origin_domain: nil. The mailers must not
  # blow up on those, and must not send an unbranded email either.
  test "falls back to books for a nil domain" do
    assert_equal :books, MailBranding.for(nil).key
    assert_equal "The Greatest Books", MailBranding.for(nil).site_name
  end

  test "falls back to books for a domain with no mail identity" do
    assert_equal :books, MailBranding.for(:nonexistent).key
  end

  test "builds a from-address combining the site name and the ENV address" do
    with_env("MAIL_FROM_ADDRESS" => "noreply@example.org") do
      assert_equal "The Greatest Music <noreply@example.org>", MailBranding.for(:music).from
    end
  end

  test "raises rather than sending from a malformed address when MAIL_FROM_ADDRESS is unset" do
    with_env("MAIL_FROM_ADDRESS" => nil) do
      error = assert_raises(MailBranding::MissingFromAddress) { MailBranding.for(:books).from }
      assert_match "MAIL_FROM_ADDRESS", error.message
    end
  end

  # config.domains values come from ENV and may hold a comma-separated list --
  # the same reason MembershipController#canonical_host splits on ",". A URL
  # host of "a.example.org,b.example.org" produces links that 404.
  test "uses only the first host when the configured domain is a comma-separated list" do
    original = Rails.application.config.domains[:books]
    Rails.application.config.domains[:books] = "first.example.org,second.example.org"

    assert_equal "first.example.org", MailBranding.for(:books).url_options[:host]
  ensure
    Rails.application.config.domains[:books] = original
  end

  test "url_options carry a protocol" do
    assert_includes %w[http https], MailBranding.for(:books).url_options[:protocol]
  end

  # The site name has exactly one home: config.domain_settings. Duplicating it
  # into the mailer layer guarantees the two copies drift.
  test "reads the site name from domain_settings rather than a second copy" do
    original = Rails.application.config.domain_settings[:books]
    Rails.application.config.domain_settings[:books] = original.merge(name: "Renamed Site")

    assert_equal "Renamed Site", MailBranding.for(:books).site_name
  ensure
    Rails.application.config.domain_settings[:books] = original
  end

  test "each supported domain has a distinct brand colour in hex, not oklch" do
    colors = [:books, :music, :games].map { |domain| MailBranding.for(domain).brand_color }

    assert_equal colors.uniq.length, colors.length, "brand colours must be distinguishable"
    colors.each { |color| assert_match(/\A#[0-9A-F]{6}\z/, color, "email clients cannot parse oklch()") }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bin/rails test test/lib/mail_branding_test.rb
```

Expected: FAIL with `NameError: uninitialized constant MailBranding`.

- [ ] **Step 3: Implement `MailBranding`**

Create `web-app/app/lib/mail_branding.rb`:

```ruby
# Resolves a domain key into the identity an email should wear: which site it
# claims to be from, what it looks like, and which host its links point at.
#
# Deliberately top-level and not nested under another module. A constant looked
# up from inside a nested module resolves against that module first, which has
# produced confusing NameErrors in this codebase more than once.
#
# Callers pass the domain EXPLICITLY. Mailers run inside Sidekiq where
# Current.domain is nil, so a mailer that reads Current sends books-branded mail
# to music subscribers, silently. memberships.origin_domain exists to be passed
# here -- and is nil for every membership predating checkout, which is why the
# fallback below is a supported case rather than a defensive afterthought.
class MailBranding
  class MissingFromAddress < StandardError; end

  DEFAULT_DOMAIN = :books

  # Hex, because email clients cannot parse oklch(). books matches its theme's
  # --color-primary exactly; music uses daisyUI's stock light primary, which is
  # the theme it ships. Decorative only -- nothing in an email depends on a
  # reader telling two of these apart.
  #
  # This hash is also the allowlist: a domain absent from it has no email
  # identity and falls back to DEFAULT_DOMAIN. Site names deliberately are NOT
  # here -- they already live in config.domain_settings and must not be
  # duplicated, or the two copies will drift.
  BRAND_COLORS = {
    books: "#194F81",
    music: "#422AD5",
    games: "#006757"
  }.freeze

  attr_reader :key

  def self.for(domain)
    key = domain.presence&.to_sym
    new(BRAND_COLORS.key?(key) ? key : DEFAULT_DOMAIN)
  end

  def initialize(key)
    @key = key
  end

  def site_name
    Rails.application.config.domain_settings.fetch(key).fetch(:name)
  end

  def brand_color
    BRAND_COLORS.fetch(key)
  end

  def from
    address = ENV["MAIL_FROM_ADDRESS"]
    raise MissingFromAddress, "MAIL_FROM_ADDRESS is not set; refusing to send from a malformed address" if address.blank?

    "#{site_name} <#{address}>"
  end

  def url_options
    options = {host: host, protocol: Rails.env.production? ? "https" : "http"}
    options[:port] = 3000 unless Rails.env.production?
    options
  end

  private

  # config.domains values come from ENV and may hold a comma-separated list.
  # Same rule as MembershipController#canonical_host.
  def host
    Rails.application.config.domains[key].to_s.split(",").first
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bin/rails test test/lib/mail_branding_test.rb
```

Expected: 9 runs, 0 failures.

- [ ] **Step 5: Prove the tests are falsifiable**

This codebase has a documented history of tests that pass against deleted code. Before committing,
break the implementation three times and confirm each guard fires:

1. Change `DEFAULT_DOMAIN` to `:music` — both fallback tests must fail.
2. Delete `.split(",").first` — the comma-separated host test must fail.
3. Replace `raise MissingFromAddress` with `address = "x@example.org"` — the raise test must fail.
4. Hardcode `site_name` to return `"The Greatest Books"` — the domain_settings test must fail.

Restore the implementation after each. If any of the four stays green, that test is not testing what
it claims and must be rewritten before you continue. Record all four results in your report.

- [ ] **Step 6: Commit**

Stage `app/lib/mail_branding.rb` and `test/lib/mail_branding_test.rb`, then commit with the message
`feat(mail): add MailBranding to resolve a domain to its email identity`.

---

## Task 3: `ApplicationMailer` and the shared mail layout

**Files:**
- Create (via generator): `web-app/app/mailers/application_mailer.rb`,
  `web-app/app/views/layouts/mailer.html.erb`, `web-app/app/views/layouts/mailer.text.erb`
- Create: `web-app/test/mailers/application_mailer_test.rb`
- Modify: `web-app/app/lib/mail_branding.rb` (add `ROOT_HELPERS` and `#root_url`)
- Modify: `web-app/test/lib/mail_branding_test.rb` (two tests for `#root_url`)

**Interfaces:**
- Consumes: `MailBranding.for(domain)` → responds to `site_name`, `from`, `brand_color`,
  `url_options`. This task adds `#root_url` to it (Step 5).
- Produces: `ApplicationMailer#branded_mail(domain:, **mail_options, &block)` — sets `from`,
  `default_url_options` and the `@branding` instance variable the layout reads, then calls `mail`.
  Subclasses call `branded_mail`, never `mail`.

- [ ] **Step 1: Generate the mailer scaffolding**

```bash
bin/rails generate mailer Application
```

This creates `app/mailers/application_mailer.rb` and both `app/views/layouts/mailer.*` templates.
Delete any other file the generator produced that this plan does not list.

Record the preview path Rails expects — Task 4 needs it:

```bash
bin/rails runner 'puts Rails.application.config.action_mailer.preview_paths.inspect'
```

- [ ] **Step 2: Write the failing test**

`ApplicationMailer` is a base class with no actions, so the test drives it through a throwaway
subclass defined **in the test file**. The probe renders inline via the `mail` block form, so it
needs no template files of its own — that keeps a test-only mailer out of `app/`.

Create `web-app/test/mailers/application_mailer_test.rb`:

```ruby
require "test_helper"

class ApplicationMailerTest < ActionMailer::TestCase
  # Defined here rather than in app/ because it exists only to exercise the base
  # class. Renders inline, so it needs no view templates -- the shared layout
  # still wraps it, which is what the branding assertions below rely on.
  class ProbeMailer < ApplicationMailer
    def probe(domain:)
      branded_mail(domain: domain, to: "reader@example.org", subject: "Probe") do |format|
        format.text { render plain: "probe body" }
        format.html { render html: "<p>probe body</p>".html_safe }
      end
    end
  end

  setup { ENV["MAIL_FROM_ADDRESS"] = "noreply@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "sets the from-address from the domain it was given" do
    mail = ProbeMailer.probe(domain: :music)

    assert_equal ["noreply@example.org"], mail.from
    assert_equal "The Greatest Music <noreply@example.org>", mail[:from].value
  end

  test "brands the mail for the domain it was given, not for Current.domain" do
    Current.domain = :books
    mail = ProbeMailer.probe(domain: :games)

    assert_match "The Greatest Games", mail.body.encoded
    assert_no_match(/The Greatest Books/, mail.body.encoded)
  ensure
    Current.domain = nil
  end

  test "brands the mail even when Current.domain is unset, as it is inside Sidekiq" do
    Current.domain = nil
    mail = ProbeMailer.probe(domain: :music)

    assert_match "The Greatest Music", mail.body.encoded
  end

  test "renders both an HTML and a plain-text part" do
    mail = ProbeMailer.probe(domain: :books)

    assert_equal ["text/html", "text/plain"], mail.parts.map(&:mime_type).sort
  end

  test "points link URLs at the host for that domain" do
    mail = ProbeMailer.probe(domain: :games)
    expected_host = Rails.application.config.domains[:games].to_s.split(",").first

    assert_match expected_host, mail.body.encoded
  end
end
```

**If `render html:` / `render plain:` turns out to bypass the layout**, the two branding assertions
will fail on a probe that is otherwise correct. The fallback, in order of preference:

1. Add `layout: "mailer"` explicitly to each `render` call in the probe.
2. Failing that, replace the block body with `render(template: "system_mailer/smoke_test")` — but
   those templates do not exist until Task 4, so instead move the two branding assertions and the
   host assertion into Task 4's `SystemMailerTest`, where a real template pair exists, and leave the
   from-address and multipart assertions here.

Take the first option that works and record in your report which one you shipped.

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/mailers/application_mailer_test.rb
```

Expected: FAIL — `branded_mail` is undefined.

- [ ] **Step 4: Implement `ApplicationMailer`**

Replace `web-app/app/mailers/application_mailer.rb` with:

```ruby
# Base class for every mailer in the app.
#
# Subclasses call branded_mail, never mail, and always pass a domain. The domain
# is explicit because mailers are delivered from Sidekiq, where Current.domain
# is nil -- a mailer that reads Current sends books-branded mail to music
# subscribers, silently and unrecoverably.
class ApplicationMailer < ActionMailer::Base
  layout "mailer"

  private

  # @param domain [Symbol, String, nil] which site this mail is about. nil is
  #   valid and falls back to books -- see MailBranding.
  def branded_mail(domain:, **options, &block)
    @branding = MailBranding.for(domain)
    self.class.default_url_options = @branding.url_options

    mail(options.merge(from: @branding.from), &block)
  end
end
```

`default_url_options` is set per-send rather than once at boot because the correct host depends on
which site the mail concerns.

- [ ] **Step 5: Add `root_url` to `MailBranding`**

This app has **no** `root_url` helper — verified, it raises `NoMethodError`. Each domain has its own
named root route (`books_root`, `music_root`, `games_root`), because four sites share one route file.
Per-domain knowledge belongs in `MailBranding`, not scattered through email templates, so add it
there.

In `web-app/app/lib/mail_branding.rb`, add the constant beside `BRAND_COLORS`:

```ruby
  # There is no bare `root_url` in this app -- four sites share one route file,
  # so each domain's root is separately named. Verified: calling root_url
  # raises NoMethodError.
  ROOT_HELPERS = {
    books: :books_root_url,
    music: :music_root_url,
    games: :games_root_url
  }.freeze
```

and the public method beside `url_options`:

```ruby
  def root_url
    Rails.application.routes.url_helpers.public_send(ROOT_HELPERS.fetch(key), **url_options)
  end
```

Add this test to `web-app/test/lib/mail_branding_test.rb`:

```ruby
  # NOTE: which helper ROOT_HELPERS picks is deliberately NOT asserted. All three
  # root routes map to "/", and the host comes from url_options, so a wrong
  # mapping (books -> :music_root_url) produces a byte-identical URL and no
  # behavioural test can distinguish it. Asserting the constant's contents would
  # test the implementation, not the behaviour. This becomes testable the day any
  # domain's root moves off "/" -- add the assertion then.
  test "builds a root URL on the right host for each domain" do
    [:books, :music, :games].each do |domain|
      branding = MailBranding.for(domain)
      expected_host = Rails.application.config.domains[domain].to_s.split(",").first

      assert_includes branding.root_url, expected_host
    end
  end
```

Run it and confirm it passes:

```bash
bin/rails test test/lib/mail_branding_test.rb
```

Do NOT add a test asserting that two domains produce different root URLs. One was drafted and
deleted during execution: it cannot fail, for the reason the comment above states. A test that
cannot fail manufactures confidence, and this repo has three separate recorded incidents of exactly
that.

- [ ] **Step 6: Write the shared layout**

Email clients strip `<style>` blocks and support neither flexbox nor CSS custom properties, so this
cannot reuse the site's Tailwind. Table layout and inline styles only.

Replace `web-app/app/views/layouts/mailer.html.erb`:

```erb
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
  </head>
  <body style="margin: 0; padding: 0; background-color: #F4F4F5; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; color: #18181B;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #F4F4F5;">
      <tr>
        <td align="center" style="padding: 24px 12px;">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width: 560px; background-color: #FFFFFF; border-radius: 8px; overflow: hidden;">
            <tr>
              <td style="background-color: <%= @branding.brand_color %>; padding: 20px 28px;">
                <span style="color: #FFFFFF; font-size: 18px; font-weight: 600;"><%= @branding.site_name %></span>
              </td>
            </tr>
            <tr>
              <td style="padding: 28px; font-size: 16px; line-height: 1.6; word-break: break-word; overflow-wrap: anywhere;">
                <%= yield %>
              </td>
            </tr>
            <tr>
              <td style="padding: 0 28px 28px; font-size: 13px; line-height: 1.5; color: #71717A;">
                <%= link_to @branding.site_name, @branding.root_url, style: "color: #71717A;" %>
              </td>
            </tr>
          </table>
        </td>
      </tr>
    </table>
  </body>
</html>
```

`overflow-wrap: anywhere` is deliberate: a long unbroken token — a book title, a URL — otherwise
forces horizontal scrolling. This project has already been bitten by that on 1,272 pages, and
`break-words` does not fix it.

Replace `web-app/app/views/layouts/mailer.text.erb`:

```erb
<%= @branding.site_name %>
<%= "-" * @branding.site_name.length %>

<%= yield %>

--
<%= @branding.site_name %>
<%= @branding.root_url %>
```

- [ ] **Step 7: Run the test to verify it passes**

```bash
bin/rails test test/mailers/application_mailer_test.rb
```

Expected: 5 runs, 0 failures.

- [ ] **Step 8: Commit**

Stage `app/mailers/application_mailer.rb`, `app/lib/mail_branding.rb`, both
`app/views/layouts/mailer.*` templates, `test/lib/mail_branding_test.rb` and
`test/mailers/application_mailer_test.rb`, then commit with the message
`feat(mail): add domain-aware ApplicationMailer and shared email layout`.

---

## Task 4: `SystemMailer#smoke_test`, the queue-name guard, and the preview

The queue-name test in this task is the highest-value test in the plan. `deliver_later` enqueues an
ActiveJob, ActiveJob hands it to Sidekiq, and Sidekiq only processes the queues named in
`config/sidekiq.yml` (`critical` and `default`). If ActionMailer's `deliver_later_queue_name`
resolves to anything else — `mailers` was the Rails default before 6.1 — every email in this app
would enqueue successfully, report success, and never be delivered.

**Files:**
- Create (via generator): `web-app/app/mailers/system_mailer.rb`,
  `web-app/app/views/system_mailer/smoke_test.html.erb` / `.text.erb`,
  `web-app/test/mailers/system_mailer_test.rb`,
  `web-app/test/mailers/previews/system_mailer_preview.rb`
- Create: `web-app/lib/tasks/mail.rake`

**Interfaces:**
- Consumes: `ApplicationMailer#branded_mail(domain:, **options)`, `MailBranding.for`.
- Produces: `SystemMailer.smoke_test(domain:, to:)` → a `Mail::Message`.

- [ ] **Step 1: Generate the mailer**

```bash
bin/rails generate mailer System smoke_test
```

- [ ] **Step 2: Write the failing test**

Replace `web-app/test/mailers/system_mailer_test.rb`:

```ruby
require "test_helper"

class SystemMailerTest < ActionMailer::TestCase
  include ActiveJob::TestHelper

  setup { ENV["MAIL_FROM_ADDRESS"] = "noreply@example.org" }
  teardown { ENV.delete("MAIL_FROM_ADDRESS") }

  test "addresses the smoke email to the recipient it was given" do
    mail = SystemMailer.smoke_test(domain: :books, to: "ops@example.org")

    assert_equal ["ops@example.org"], mail.to
    assert_equal ["noreply@example.org"], mail.from
  end

  test "names the environment in the subject so a stray email is identifiable" do
    mail = SystemMailer.smoke_test(domain: :books, to: "ops@example.org")

    assert_match Rails.env, mail.subject
  end

  test "brands the smoke email for the domain it was given" do
    mail = SystemMailer.smoke_test(domain: :games, to: "ops@example.org")

    assert_match "The Greatest Games", mail.body.encoded
  end

  # THE IMPORTANT ONE. Sidekiq processes only the queues in config/sidekiq.yml.
  # If deliver_later enqueues onto any other queue, every email this app ever
  # sends is accepted, reported as sent, and silently never delivered.
  test "deliver_later enqueues onto a queue Sidekiq actually processes" do
    processed_queues = YAML.load_file(Rails.root.join("config/sidekiq.yml")).fetch(:queues)

    assert_enqueued_jobs 1 do
      SystemMailer.smoke_test(domain: :books, to: "ops@example.org").deliver_later
    end

    queue = enqueued_jobs.first[:queue]
    assert_includes processed_queues, queue,
      "deliver_later enqueued onto #{queue.inspect}, which is not in config/sidekiq.yml " \
      "(#{processed_queues.inspect}). Mail would be accepted and never delivered. " \
      "Set config.action_mailer.deliver_later_queue_name."
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
bin/rails test test/mailers/system_mailer_test.rb
```

Expected: FAIL — `smoke_test` does not accept those keyword arguments yet.

- [ ] **Step 4: Implement the mailer**

Replace `web-app/app/mailers/system_mailer.rb`:

```ruby
# Operational mail. Not customer-facing.
class SystemMailer < ApplicationMailer
  # Sent by `rake mail:smoke`. The only way to verify SendGrid credentials,
  # domain authentication and queue wiring in an environment without waiting for
  # a real customer email to fail.
  def smoke_test(domain:, to:)
    @sent_at = Time.current

    branded_mail(domain: domain, to: to, subject: "Mail smoke test — #{Rails.env}")
  end
end
```

Create `web-app/app/views/system_mailer/smoke_test.html.erb`:

```erb
<p>This is a test email from <strong><%= @branding.site_name %></strong>.</p>

<p>
  If you are reading this, SMTP delivery and domain authentication are working
  in <strong><%= Rails.env %></strong>.
</p>

<p>
  It does <strong>not</strong> prove the background queue works. <code>mail:smoke</code>
  calls <code>deliver_now</code>, so this message bypassed ActiveJob and Sidekiq
  entirely. Membership emails send with <code>deliver_later</code> and additionally
  need a Sidekiq worker consuming the <code>default</code> queue.
</p>

<p>Sent at <%= @sent_at.utc.iso8601 %>.</p>
```

Create `web-app/app/views/system_mailer/smoke_test.text.erb`:

```erb
This is a test email from <%= @branding.site_name %>.

If you are reading this, SMTP delivery and domain authentication are working
in <%= Rails.env %>.

It does NOT prove the background queue works. `mail:smoke` calls deliver_now,
so this message bypassed ActiveJob and Sidekiq entirely. Membership emails send
with deliver_later and additionally need a Sidekiq worker consuming the
"default" queue.

Sent at <%= @sent_at.utc.iso8601 %>.
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bin/rails test test/mailers/system_mailer_test.rb
```

Expected: 4 runs, 0 failures.

**If the queue-name test fails, that is a real finding, not a broken test.** Fix it by adding inside
the `Application` class in `config/application.rb`:

```ruby
    # Sidekiq processes only the queues in config/sidekiq.yml.
    config.action_mailer.deliver_later_queue_name = "default"
```

Then re-run. Record in your report which branch you took and what the queue name resolved to.

- [ ] **Step 6: Write the preview**

Replace `web-app/test/mailers/previews/system_mailer_preview.rb`:

```ruby
# Preview all emails at http://localhost:3000/rails/mailers
class SystemMailerPreview < ActionMailer::Preview
  def smoke_test_books
    SystemMailer.smoke_test(domain: :books, to: "preview@example.org")
  end

  def smoke_test_music
    SystemMailer.smoke_test(domain: :music, to: "preview@example.org")
  end

  def smoke_test_games
    SystemMailer.smoke_test(domain: :games, to: "preview@example.org")
  end

  # The nil case is not hypothetical: every membership created before checkout
  # existed has origin_domain: nil, and increment 8's mailers will pass it.
  def smoke_test_unknown_domain
    SystemMailer.smoke_test(domain: nil, to: "preview@example.org")
  end
end
```

Previews need `MAIL_FROM_ADDRESS` set in `web-app/.env`, since `MailBranding#from` raises without it.
Verify they render:

```bash
bin/rails server
# then open http://localhost:3000/rails/mailers/system_mailer
```

Confirm all four render and that the three branded ones show visibly different header colours.
Report what you saw. If the preview route 404s, set
`config.action_mailer.preview_paths = [Rails.root.join("test/mailers/previews").to_s]` in
`config/environments/development.rb`, using the value recorded in Task 3 Step 1 as the guide.

- [ ] **Step 7: Write the rake task**

Create `web-app/lib/tasks/mail.rake`:

```ruby
namespace :mail do
  desc "Send a smoke-test email to ADMIN_NOTIFICATION_EMAIL to verify delivery works"
  task :smoke, [:domain] => :environment do |_task, args|
    recipient = ENV["ADMIN_NOTIFICATION_EMAIL"]
    abort "ADMIN_NOTIFICATION_EMAIL is not set" if recipient.blank?
    abort "MAIL_FROM_ADDRESS is not set" if ENV["MAIL_FROM_ADDRESS"].blank?
    abort "SENDGRID_API_KEY is not set" if Rails.env.production? && ENV["SENDGRID_API_KEY"].blank?

    domain = args[:domain].presence || "books"

    # deliver_now, not deliver_later: the point is to see the failure here, in
    # this terminal, rather than in a Sidekiq retry nobody is watching.
    SystemMailer.smoke_test(domain: domain, to: recipient).deliver_now

    puts "Sent a #{domain} smoke test to #{recipient} via #{ActionMailer::Base.delivery_method}."
  end
end
```

The recipient printed here is an operator's own address from ENV, not user data — printing it is
intentional and is the only way the operator knows where to look.

- [ ] **Step 8: Verify the task end to end in development**

```bash
MAIL_FROM_ADDRESS=noreply@thegreatestbooks.org ADMIN_NOTIFICATION_EMAIL=ops@example.org \
  bin/rails mail:smoke
ls tmp/mails/
```

Expected: the task prints `via file`, and `tmp/mails/` holds a file containing both a plain-text and
an HTML part with "The Greatest Books" in each. Paste the first 20 lines of that file into your
report.

- [ ] **Step 9: Run the full suite and the linter**

```bash
bin/rails test
bundle exec standardrb
bin/rails zeitwerk:check
```

- [ ] **Step 10: Commit**

Stage `app/mailers/system_mailer.rb`, `app/views/system_mailer/`,
`test/mailers/system_mailer_test.rb`, `test/mailers/previews/system_mailer_preview.rb` and
`lib/tasks/mail.rake`, then commit with the message
`feat(mail): add SystemMailer smoke test, previews and mail:smoke task`.

---

## Task 5: Documentation

**Files:**
- Create: `docs/features/email.md`
- Modify: `docs/specs/membership-and-stripe-billing.md` (Status line, Increments table row 5)
- Modify: `docs/guides/stripe-account-setup.md` (a new step for SendGrid)

- [ ] **Step 1: Write the feature doc**

Create `docs/features/email.md` with real content under each of these headings — not headings alone:

- **What exists**: `MailDeliverySettings`, `MailBranding`, `ApplicationMailer#branded_mail`,
  `SystemMailer#smoke_test`, `mail:smoke`.
- **The one rule**: every mailer takes a domain explicitly and calls `branded_mail`, never `mail`.
  State the reason — `Current.domain` is nil inside Sidekiq, so reading it sends books-branded mail
  to music subscribers. Name `memberships.origin_domain` as the value to pass, and note that it is
  `nil` for every membership predating checkout, which `MailBranding` handles by falling back to
  books.
- **Delivery per environment**: production → SendGrid SMTP; development → files in `tmp/mails`;
  test → `ActionMailer::Base.deliveries`.
- **The queue trap**: `deliver_later` goes through ActiveJob to Sidekiq, and Sidekiq processes only
  the queues in `config/sidekiq.yml`. Name the guarding test
  (`test/mailers/system_mailer_test.rb`, "deliver_later enqueues onto a queue Sidekiq actually
  processes") and record the queue name the implementation resolved to.
- **Email HTML is not web HTML**: table layout, inline styles only, no Tailwind, no custom
  properties, hex colours because `oklch()` is unsupported.
- **ENV vars**: the three, and what breaks when each is missing.
- **Previews**: `http://localhost:3000/rails/mailers`, needs `MAIL_FROM_ADDRESS` in `.env`.

- [ ] **Step 2: Update the spec**

In `docs/specs/membership-and-stripe-billing.md`:

- Increments table: change row 5's `Done` cell from empty to `✅`.
- Status line: move increment 5 into the shipped list, leaving increment 8 as the only one remaining.
  Match the existing sentence structure exactly.

- [ ] **Step 3: Add the SendGrid step to the production runbook**

`docs/guides/stripe-account-setup.md` is the ordered list of by-hand production setup. Add a step
covering: create the SendGrid API key with Mail Send permission only; authenticate the sending domain
and add its DNS records; set `SENDGRID_API_KEY`, `MAIL_FROM_ADDRESS` and `ADMIN_NOTIFICATION_EMAIL`
in `sops secrets/.env.production`; then run `bin/rails mail:smoke` on the production host and confirm
arrival — **including checking the spam folder**, because an unauthenticated sending domain delivers
to spam rather than failing, which is indistinguishable from success on the app's side.

Place it before the Post-deploy verification step and renumber the following sections.

- [ ] **Step 4: Verify and commit**

```bash
bin/rails test
bundle exec standardrb
```

Stage `docs/features/email.md`, `docs/specs/membership-and-stripe-billing.md` and
`docs/guides/stripe-account-setup.md`, then commit with the message
`docs(mail): document the mail foundation and add SendGrid to the runbook`.

---

## Notes for the reviewer

Aim review at these, in order:

1. **Does anything read `Current.domain` inside a mailer or a mail view?** That is the single defect
   this design exists to prevent.
   `grep -rn "Current\." app/mailers app/views/layouts/mailer* app/views/system_mailer` must come
   back empty.
2. **Is `SENDGRID_API_KEY` or `MAIL_FROM_ADDRESS` given a default anywhere?** Including in a test
   helper, a fixture, or an environment file. A placeholder secret is a Global Constraint violation.
3. **Does the queue-name test actually fail when the queue is wrong?** Set
   `config.action_mailer.deliver_later_queue_name = "mailers"` and confirm it goes red. If it stays
   green the test is decorative and the production failure it exists to catch is unguarded.
4. **Do the `MailBranding` fallback tests fail when `DEFAULT_DOMAIN` changes?** Same reason. The
   implementer was asked to prove all four mutations in Task 2 Step 5 — check the report says so.
5. **Deploy pipeline:** this branch adds no migration, so `bin/docker-entrypoint`'s `db:prepare`
   cannot fail the boot. But it enables a railtie, and production eager-loads. A constant error in
   any mailer file takes all four sites down in a crash-loop under `restart: unless-stopped`.
   Confirm `RAILS_ENV=production bin/rails zeitwerk:check` passes and that `app/mailers/`
   eager-loads cleanly. Check specifically whether `config.action_mailer.smtp_settings =
   MailDeliverySettings.sendgrid_smtp` can raise at boot when `SENDGRID_API_KEY` is absent — that
   would be a crash-loop, not a failed send.
6. **Threat model:** the smoke rake task prints an ENV-supplied operator address — acceptable. Check
   that nothing else prints or logs a recipient, a body, or a rescued delivery error message.
