# Security Audit PR 1 — Auth Hotfix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the live account-takeover route (H1), stop Firebase ID tokens reaching production logs (M3), make Sidekiq Web fail closed (M2), and stop the admin `viewer` role from changing or deleting wizard data (M4).

**Architecture:** Four independent, small changes to existing code. H1 is a one-line gate where `AuthenticationService` builds its `ProviderEmailResolver`; M3 is one entry in `filter_parameters`; M2 extracts the Sidekiq Basic-auth check into a tiny `SidekiqWebAuth` module that refuses blank credentials; M4 adds two `before_action`s to each of the two shared admin concerns, using the existing `Admin::DomainScopedAuth` helpers.

**Tech Stack:** Rails 8.1, Minitest 6 + fixtures + Mocha, WebMock, Sidekiq 8 Web.

**Spec:** `docs/superpowers/specs/2026-10-01-security-audit-fixes-design.md` (sections "Corrections to the audit" and "PR 1 — auth hotfix"). This plan covers PR 1 only. PRs 2, 3, 4a and 4b get their own plans.

## Global Constraints

- Run every Rails/yarn command from `web-app/` inside the worktree `/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes`. Docs live at the project root `docs/`.
- Linter is `bundle exec standardrb` (never `bin/rubocop`). Do not run brakeman.
- Minitest 6: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Never test private methods; controller tests assert behaviour (status, redirect, data), never copy or CSS.
- Check fixture names before using them (they are semantic: `regular_user`, `google_user`, `contractor_user`, `games_editor_user`, `games_moderator_user`, `games_list`, `music_albums_list`).
- A clean `bin/rails test` emits no new warnings.
- Never commit to `main`; this branch is `worktree-security-audit-fixes`. Do not push or open a PR without asking Shane. Merging to `main` deploys to production.
- No Cloudflare changes of any kind.
- End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A returning Google user on a new device** (new Firebase uid, provider record carries their address, claim unverified or absent) must still link to their existing row — the fix must not break the main relink path. Test added in Task 1.
2. **A uid-matched row with a blank email** must not have an *unverified* claim filled onto it by `update_existing` — that fill is the other place the resolved email is written. Test added in Task 1.
3. **`email_verified` that is not exactly boolean `true`** (`false`, missing, the string `"true"`) must not pass the claim through. Test added in Task 1.
4. **Sidekiq credentials where only one variable is set** must refuse everything, not compare the other half. Test added in Task 3.
5. **The delete gate must not lock out moderators**, and viewers' GET reads (including the JSON `step_status`) must keep working. Tests added in Task 4.

---

### Task 0: Prepare the worktree

**Files:** none committed.

- [ ] **Step 1: Copy the gitignored files the app needs** (the worktree tool often copies none of them)

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes
MAIN=/home/shane/dev/the-greatest
for f in .env web-app/.env web-app/config/master.key web-app/e2e/.env; do
  [ -e "$f" ] || cp "$MAIN/$f" "$f"
done
[ -e web-app/node_modules ] || ln -s "$MAIN/web-app/node_modules" web-app/node_modules
ls .env web-app/.env web-app/config/master.key web-app/e2e/.env; ls -d web-app/node_modules
```

Expected: all five paths listed.

- [ ] **Step 2: Prepare the per-worktree test database and build assets**

```bash
cd web-app
bin/rails db:test:prepare
yarn build:all
```

Expected: both exit 0. (Admin controller tests render layouts, which need `app/assets/builds/`.)

- [ ] **Step 3: Baseline the files this plan touches**

```bash
bin/rails test test/lib/services/authentication_service_test.rb test/controllers/auth_controller_test.rb \
  test/lib/services/provider_email_resolver_test.rb test/lib/services/user_authentication_service_test.rb \
  test/controllers/admin/games/list_items_actions_controller_test.rb test/controllers/admin/games/list_wizard_controller_test.rb \
  test/controllers/admin/music/albums/list_items_actions_controller_test.rb test/controllers/admin/music/albums/list_wizard_controller_test.rb
```

Expected: 0 failures, 0 errors. If anything fails here, stop and report — it is pre-existing.

---

### Task 1: H1 — an unverified token email must not inherit provider trust

**Files:**
- Modify: `web-app/app/lib/services/authentication_service.rb` (the `ProviderEmailResolver.new` call in `.call`, and the `TRUSTED_EMAIL_PROVIDERS` comment)
- Modify: `web-app/app/lib/services/provider_email_resolver.rb` (header comment only)
- Modify: `web-app/test/lib/services/authentication_service_test.rb`
- Modify: `web-app/test/controllers/auth_controller_test.rb`
- Modify: `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md` (D8)
- Modify: `docs/features/oauth-providers.md` (the paragraph beginning "Linking *prefers* the address")

**Interfaces:**
- Consumes: `Services::ProviderEmailResolver.new(uid:, sign_in_provider:, project_id:, fallback_email:)` — unchanged signature.
- Produces: `fallback_email` is now `payload["email"]` only when `payload["email_verified"] == true`, otherwise `nil`. Nothing else changes shape.

**Background for the implementer:** the token's `email` claim is the Firebase *account record's* email, which its holder controls. This project allows multiple accounts per identity provider, so anyone can create a Firebase password account for a victim's address (no verification needed), link an email-less X or Facebook identity to it, and sign in with X. The token then says `sign_in_provider: twitter.com`, `email: victim`, `email_verified: false`. The X provider record has no email, so `ProviderEmailResolver` falls back to the claim; `email_trusted` is true because X is on `TRUSTED_EMAIL_PROVIDERS`; `UserAuthenticationService#find_user` returns the victim's row and `update_existing` rewrites its `auth_uid`. No legitimate sign-in needs the unverified claim: Google and password resolve from the provider record, and Facebook and Apple tokens carry no `email` claim at all.

- [ ] **Step 1: Write the failing regression tests**

Append to `web-app/test/lib/services/authentication_service_test.rb`, before the final `end`:

```ruby
  # --- H1 of the 2026-09-30 security audit ---
  #
  # The token's `email` is the Firebase ACCOUNT RECORD's email, which its holder
  # sets. A password account can be created for any address without proof, and
  # an email-less X or Facebook identity linked to it then signs in with a
  # trusted sign_in_provider and that address on the token. Only a verified
  # claim may stand in for the provider record.

  test "an unverified claim under a trusted provider cannot take over an existing account" do
    victim = users(:regular_user)
    original_uid = victim.auth_uid

    %w[twitter.com facebook.com].each_with_index do |sign_in_provider, i|
      Services::FirebaseAccountLookup.stubs(:call).returns([
        {"providerId" => sign_in_provider, "rawId" => "attacker-raw-#{i}"}
      ])
      token = FirebaseTokenHelper.token({
        "sub" => "uid-attacker-#{i}",
        "email" => victim.email,
        "email_verified" => false,
        "firebase" => {"sign_in_provider" => sign_in_provider, "identities" => {sign_in_provider => ["attacker-raw-#{i}"]}}
      })

      result = call(token)

      assert result[:success], "#{sign_in_provider}: #{result[:error]}"
      refute_equal victim.id, result[:user].id, "#{sign_in_provider}: signed in as the victim"
      assert_nil result[:user].email, "#{sign_in_provider}: the unverified claim reached the new row"
      # Tuple form: regular_user's auth_uid is nil, and Minitest 6 makes
      # assert_equal(nil, x) a hard failure.
      assert_equal [victim.id, original_uid], [victim.id, victim.reload.auth_uid],
        "#{sign_in_provider}: the victim's row was relinked"
    end
  end

  test "an unverified claim is never filled onto a uid-matched row with no email" do
    row = User.create!(
      auth_uid: "uid-x-blank",
      external_provider: :twitter,
      email: nil,
      email_verified: false,
      role: :user
    )
    Services::FirebaseAccountLookup.stubs(:call).returns([{"providerId" => "twitter.com"}])
    token = FirebaseTokenHelper.token({
      "sub" => "uid-x-blank",
      "email" => "unproven.address@example.com",
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "twitter.com"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert_equal row.id, result[:user].id
    assert_nil row.reload.email
  end

  test "a provider-record email still links an existing account when the claim is unverified" do
    existing = users(:google_user)
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "google.com", "email" => existing.email}
    ])
    token = FirebaseTokenHelper.token({
      "sub" => "uid-google-new-device",
      "email" => existing.email,
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "google.com"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert_equal existing.id, result[:user].id
    assert_equal "uid-google-new-device", existing.reload.auth_uid
  end

  test "only a claim whose email_verified is exactly true reaches the resolver" do
    [false, nil, "true"].each do |claim|
      payload = {
        "sub" => "uid_1",
        "firebase" => {"sign_in_provider" => "facebook.com"},
        "email" => "claim@example.com",
        "email_verified" => claim
      }
      Services::JwtValidationService.stubs(:call).returns(payload)

      Services::ProviderEmailResolver.expects(:new).with(
        uid: "uid_1",
        sign_in_provider: "facebook.com",
        project_id: "the-greatest-books",
        fallback_email: nil
      ).returns(stub(call: nil))

      Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd web-app
bin/rails test test/lib/services/authentication_service_test.rb -n "/takeover|never filled|exactly true|still links/"
```

Expected: "cannot take over" FAILS (signed in as the victim), "never filled" FAILS (email is filled), "exactly true" FAILS (unexpected invocation with `fallback_email: "claim@example.com"`). "still links" PASSES already — it pins behaviour the fix must keep.

- [ ] **Step 3: Implement the gate**

In `web-app/app/lib/services/authentication_service.rb`, replace the `email_resolver:` argument inside `self.call`:

```ruby
        email_resolver: ProviderEmailResolver.new(
          uid: payload["sub"],
          sign_in_provider: payload.dig("firebase", "sign_in_provider"),
          project_id: project_id,
          # Only a VERIFIED claim may stand in for the provider record. The
          # claim is the Firebase account record's email, which its holder
          # sets: a password account can be created for any address without
          # proof, and an email-less X or Facebook identity linked to it then
          # signs in with a trusted sign_in_provider and that address on the
          # token. Passing it through unverified let the provider's trust vouch
          # for an address the provider never asserted -- H1 of the 2026-09-30
          # security audit. No legitimate sign-in needs it: Google and password
          # resolve from the provider record, and Facebook and Apple tokens
          # carry no email claim at all. Strict `== true`, as for email_verified
          # below: a missing or non-boolean claim is not verification.
          fallback_email: (payload["email"] if payload["email_verified"] == true)
        )
```

In the same file, in the `TRUSTED_EMAIL_PROVIDERS` comment, replace the paragraph that ends "…not the provenance of whatever address happens to be on today's token." with:

```ruby
    # That is weaker than it sounds, though: the token's `email` claim is the
    # Firebase account RECORD's email, not necessarily the address the
    # provider asserted at signup, and its holder can set it. So this list is
    # only ever applied to an address that came from the provider record, or
    # from a claim Firebase marked verified -- `.call` refuses to hand an
    # unverified claim to ProviderEmailResolver at all. The list trusts the
    # provider's identity, never the provenance of an arbitrary address.
```

- [ ] **Step 4: Run the new tests to verify they pass**

```bash
bin/rails test test/lib/services/authentication_service_test.rb -n "/takeover|never filled|exactly true|still links/"
```

Expected: 4 runs, 0 failures.

- [ ] **Step 5: Run the whole file and the controller test to find the tests that relied on the fallback**

```bash
bin/rails test test/lib/services/authentication_service_test.rb test/controllers/auth_controller_test.rb
```

Expected: exactly these fail, because they reached an unverified password email only through the fallback (the default lookup stub returns no provider record):
- `authentication_service_test.rb` "surfaces the unverified-email conflict as its own error code"
- `authentication_service_test.rb` "password is never email-trusted on a false claim"
- `authentication_service_test.rb` "builds a resolver from the token's sub and sign_in_provider"
- `auth_controller_test.rb` "returns email_verification_required when an unverified email hits an existing account"

If any other test fails, stop and investigate before editing it.

- [ ] **Step 6: Give those tests a realistic provider record**

In production a password sign-in's address comes from the `password` provider record. Make the tests say so.

In `authentication_service_test.rb`, "surfaces the unverified-email conflict as its own error code" — add as the first line of the test body:

```ruby
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "password", "email" => users(:regular_user).email}
    ])
```

"password is never email-trusted on a false claim" — add as the first line:

```ruby
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "password", "email" => "pw.person@example.com"}
    ])
```

"builds a resolver from the token's sub and sign_in_provider" — add `"email_verified" => true,` to the `payload` hash (after `"email" => "claim@example.com"`). The expectation (`fallback_email: "claim@example.com"`) stays.

In `auth_controller_test.rb`, "returns email_verification_required when an unverified email hits an existing account" — add as the first line:

```ruby
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "password", "email" => users(:google_user).email}
    ])
```

Update the comment above `stub_account_lookup_empty` in **both** files. Replace its last sentence(s) about falling back to the token's own claim with:

```ruby
  # ...so the default here makes the provider-record lookup find nothing,
  # which makes the resolver fall back to the token's own `email` claim --
  # and AuthenticationService offers that claim only when email_verified is
  # exactly true, which FirebaseTokenHelper's default token is. A test of an
  # UNVERIFIED claim must stub the provider record it means
  # (FirebaseAccountLookup.stubs(:call)), as production would supply one.
```

(Keep the rest of each comment; in `authentication_service_test.rb` the part about WebMock and the token-minting test still holds.)

- [ ] **Step 7: Run the auth suites**

```bash
bin/rails test test/lib/services/authentication_service_test.rb test/controllers/auth_controller_test.rb \
  test/lib/services/provider_email_resolver_test.rb test/lib/services/user_authentication_service_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 8: Correct the resolver's header comment**

In `web-app/app/lib/services/provider_email_resolver.rb`, add this paragraph to the class comment, directly after the paragraph that ends "…is not writable by the account holder.":

```ruby
  #
  # fallback_email is that same mutable claim, so the caller must pass it only
  # when Firebase marked it verified. AuthenticationService does; an
  # unverified claim reaching here would let a trusted provider vouch for an
  # address it never asserted (H1, 2026-09-30 security audit).
```

- [ ] **Step 9: Correct the docs that said enumeration protection closes this route**

In `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`, append directly after D8's last sentence ("Keep the setting enabled — it remains load-bearing."):

```markdown

**Correction 2026-10-01 (security audit H1).** D8's trade-off was decided on a false
premise. Email enumeration protection blocks `accounts:update`, but not the route that
matters: create a Firebase password account for the victim's address (allowed under
"multiple accounts per identity provider", no verification), link an email-less X or
Facebook identity, sign in with it. The fallback then read the unverified claim and
`TRUSTED_EMAIL_PROVIDERS` trusted it. And the cost D8 feared does not arise: Facebook and
Apple tokens carry no `email` claim, so the fallback was already nil for them. The fallback
now receives the claim only when `email_verified == true`
(`authentication_service.rb`). Keep enumeration protection on regardless.
```

In `docs/features/oauth-providers.md`, replace the paragraph that begins "Linking *prefers* the address on the account's **provider record**" (through "…exactly as D10 of the provider registry design requires.") with:

```markdown
Linking reads the address from the account's **provider record**, never from an
unverified token claim. `Services::ProviderEmailResolver` falls back to the token's
`email` only when the provider record has none, and `Services::AuthenticationService`
supplies that fallback **only when `email_verified` is true**. The claim is the
account-record email its holder controls: a password account can be created for any
address and an email-less X or Facebook identity linked to it, so an unverified claim
under a trusted `sign_in_provider` is exactly the takeover `TRUSTED_EMAIL_PROVIDERS`
must never vouch for (H1 of the 2026-09-30 security audit). Email enumeration
protection stays enabled as well, as D10 of the provider registry design requires,
but it does not block that route on its own.
```

- [ ] **Step 10: Lint and commit**

```bash
bundle exec standardrb app/lib/services/authentication_service.rb app/lib/services/provider_email_resolver.rb \
  test/lib/services/authentication_service_test.rb test/controllers/auth_controller_test.rb
cd ..
git add web-app/app/lib/services/authentication_service.rb web-app/app/lib/services/provider_email_resolver.rb \
  web-app/test/lib/services/authentication_service_test.rb web-app/test/controllers/auth_controller_test.rb \
  docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md docs/features/oauth-providers.md
git commit -m "Auth: an unverified token email never inherits provider trust

The resolver's fallback took the token's email claim -- the Firebase
account record's email, which its holder sets -- whenever the provider
record had no address, and TRUSTED_EMAIL_PROVIDERS then trusted it from
the provider name alone. A password account for a victim's address plus a
linked email-less X or Facebook identity relinked the victim's row
(security audit H1). The claim now reaches the resolver only when
email_verified is exactly true.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: standardrb reports no offenses; commit succeeds.

---

### Task 2: M3 — filter the `jwt` parameter from logs

**Files:**
- Modify: `web-app/config/initializers/filter_parameter_logging.rb`
- Create: `web-app/test/config/filter_parameter_logging_test.rb`

**Interfaces:** none consumed or produced.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/config/filter_parameter_logging_test.rb`:

```ruby
require "test_helper"

# The Firebase ID token is posted to /auth/sign_in as {jwt: idToken}
# (firebase_auth_service.js). It is a bearer credential, replayable for up to
# an hour, and Rails logs request parameters at info in production. "jwt"
# matches none of the other partial patterns, so it needs its own entry.
class FilterParameterLoggingTest < ActiveSupport::TestCase
  def filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  test "the sign-in token is filtered at the top level" do
    assert_equal "[FILTERED]", filter.filter("jwt" => "eyJhbGciOi.secret.sig")["jwt"]
  end

  test "the sign-in token is filtered inside the wrapped JSON params" do
    filtered = filter.filter("auth" => {"jwt" => "eyJhbGciOi.secret.sig"})

    assert_equal "[FILTERED]", filtered.dig("auth", "jwt")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/config/filter_parameter_logging_test.rb
```

Expected: 2 failures — the token comes back unfiltered.

- [ ] **Step 3: Add the entry**

In `web-app/config/initializers/filter_parameter_logging.rb`, change the first line of the array from:

```ruby
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
```

to:

```ruby
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # The Firebase ID token posted to /auth/sign_in as {jwt: ...} -- a bearer
  # credential replayable for up to an hour. "jwt" matches none of the
  # patterns above (security audit M3).
  :jwt,
```

- [ ] **Step 4: Run it to verify it passes**

```bash
bin/rails test test/config/filter_parameter_logging_test.rb
```

Expected: 2 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb config/initializers/filter_parameter_logging.rb test/config/filter_parameter_logging_test.rb
cd ..
git add web-app/config/initializers/filter_parameter_logging.rb web-app/test/config/filter_parameter_logging_test.rb
git commit -m "Filter the jwt sign-in parameter from logs

The Firebase ID token was written to production logs on every sign-in,
because no filter pattern matched \"jwt\" (security audit M3).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: M2 — Sidekiq Web refuses everything when its credentials are blank

**Files:**
- Create: `web-app/app/lib/sidekiq_web_auth.rb`
- Modify: `web-app/config/routes.rb` (the `Sidekiq::Web.use(Rack::Auth::Basic)` block, ~line 335)
- Create: `web-app/test/lib/sidekiq_web_auth_test.rb`
- Create: `web-app/test/integration/sidekiq_admin_mount_test.rb`
- Modify: `deployment/ENV.md` (Sidekiq Configuration section), `.env.example`

**Interfaces:**
- Produces: `SidekiqWebAuth.authenticate(username, password, expected_username: ENV["SIDEKIQ_ADMIN_USERNAME"], expected_password: ENV["SIDEKIQ_ADMIN_PASSWORD"]) -> true | false`. `app/lib/` is an autoload root, so `app/lib/sidekiq_web_auth.rb` defines top-level `SidekiqWebAuth` (like `app/lib/domain_constraint.rb`).

**Background:** today the block compares against `ENV[...].to_s`, so with both variables unset an empty username and password (`Authorization: Basic Og==`) pass. Production does set them (Shane logs in), so this is latent — but a missing variable must fail closed. Fail at request time, never at boot: a boot-time raise would turn a missing variable into an outage on all four sites.

- [ ] **Step 1: Write the failing unit test**

Create `web-app/test/lib/sidekiq_web_auth_test.rb`:

```ruby
require "test_helper"

class SidekiqWebAuthTest < ActiveSupport::TestCase
  def auth(username, password, expected_username:, expected_password:)
    SidekiqWebAuth.authenticate(username, password,
      expected_username: expected_username, expected_password: expected_password)
  end

  test "accepts the configured credentials" do
    assert auth("admin", "s3cret", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects a wrong password" do
    refute auth("admin", "nope", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects a wrong username" do
    refute auth("root", "s3cret", expected_username: "admin", expected_password: "s3cret")
  end

  test "rejects empty credentials when nothing is configured" do
    refute auth("", "", expected_username: nil, expected_password: nil)
    refute auth("", "", expected_username: "", expected_password: "")
  end

  test "rejects everything when only one credential is configured" do
    refute auth("admin", "", expected_username: "admin", expected_password: nil)
    refute auth("", "s3cret", expected_username: nil, expected_password: "s3cret")
    refute auth("admin", "anything", expected_username: "admin", expected_password: "  ")
  end

  test "tolerates a nil submitted credential" do
    refute auth(nil, nil, expected_username: "admin", expected_password: "s3cret")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd web-app
bin/rails test test/lib/sidekiq_web_auth_test.rb
```

Expected: errors — `NameError: uninitialized constant SidekiqWebAuth`.

- [ ] **Step 3: Implement the module**

Create `web-app/app/lib/sidekiq_web_auth.rb`:

```ruby
# frozen_string_literal: true

# The Basic-auth check in front of Sidekiq::Web (config/routes.rb).
#
# Fails closed: if either expected credential is blank, nothing gets in. The
# previous inline check compared against ENV[...].to_s, so with the variables
# unset an empty username and password passed (security audit M2). It fails
# at request time, not at boot, so a missing variable locks the dashboard
# rather than taking the site down.
#
# Both sides are SHA-256'd before secure_compare so the comparison is
# constant-time regardless of input length.
module SidekiqWebAuth
  def self.authenticate(username, password,
    expected_username: ENV["SIDEKIQ_ADMIN_USERNAME"],
    expected_password: ENV["SIDEKIQ_ADMIN_PASSWORD"])
    return false if expected_username.blank? || expected_password.blank?

    matches?(username, expected_username) & matches?(password, expected_password)
  end

  def self.matches?(given, expected)
    ActiveSupport::SecurityUtils.secure_compare(
      ::Digest::SHA256.hexdigest(given.to_s),
      ::Digest::SHA256.hexdigest(expected)
    )
  end
  private_class_method :matches?
end
```

- [ ] **Step 4: Run the unit test to verify it passes**

```bash
bin/rails test test/lib/sidekiq_web_auth_test.rb
```

Expected: 6 runs, 0 failures.

- [ ] **Step 5: Write the failing integration test**

Create `web-app/test/integration/sidekiq_admin_mount_test.rb`:

```ruby
require "test_helper"

# Only the refusal paths are exercised here: Rack::Auth::Basic answers 401
# before Sidekiq::Web runs, so these need no Redis. The accept path is covered
# by SidekiqWebAuthTest.
class SidekiqAdminMountTest < ActionDispatch::IntegrationTest
  def with_env(vars)
    saved = vars.keys.index_with { |k| ENV[k] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def basic(username, password)
    {"HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password)}
  end

  test "empty credentials are refused when the variables are unset" do
    with_env("SIDEKIQ_ADMIN_USERNAME" => nil, "SIDEKIQ_ADMIN_PASSWORD" => nil) do
      get "/sidekiq-admin", headers: basic("", "")
    end

    assert_response :unauthorized
  end

  test "wrong credentials are refused when the variables are set" do
    with_env("SIDEKIQ_ADMIN_USERNAME" => "admin", "SIDEKIQ_ADMIN_PASSWORD" => "s3cret") do
      get "/sidekiq-admin", headers: basic("admin", "wrong")
    end

    assert_response :unauthorized
  end
end
```

- [ ] **Step 6: Run it to verify the unset case fails**

```bash
bin/rails test test/integration/sidekiq_admin_mount_test.rb
```

Expected: "empty credentials are refused…" FAILS (the old inline check lets `Basic Og==` through — the response is Sidekiq's, or an error if Redis is unreachable, not 401). "wrong credentials…" passes.

- [ ] **Step 7: Point the route at the module**

In `web-app/config/routes.rb`, replace:

```ruby
  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_USERNAME"].to_s)) &
      ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_ADMIN_PASSWORD"].to_s))
  end
```

with:

```ruby
  # Fails closed when either SIDEKIQ_ADMIN_* variable is blank; see SidekiqWebAuth.
  Sidekiq::Web.use(Rack::Auth::Basic) do |username, password|
    SidekiqWebAuth.authenticate(username, password)
  end
```

- [ ] **Step 8: Run both tests to verify they pass**

```bash
bin/rails test test/lib/sidekiq_web_auth_test.rb test/integration/sidekiq_admin_mount_test.rb
```

Expected: 8 runs, 0 failures.

- [ ] **Step 9: Document the variables**

In `deployment/ENV.md`, directly after the `#### SIDEKIQ_CONCURRENCY` block (after its `- **Recommended**:` line), add:

```markdown

#### SIDEKIQ_ADMIN_USERNAME / SIDEKIQ_ADMIN_PASSWORD
- **Description**: Basic-auth credentials for the Sidekiq dashboard at `/sidekiq-admin`
  (answers on every domain)
- **Required**: Yes in production, or the dashboard is unreachable
- **Default**: none. If either is blank, every login is refused (`SidekiqWebAuth`) — the
  dashboard fails closed, never open
```

In `.env.example`, directly after `SIDEKIQ_CONCURRENCY=5`, add:

```bash
# Sidekiq dashboard (/sidekiq-admin) Basic auth. Blank = dashboard locked.
SIDEKIQ_ADMIN_USERNAME=
SIDEKIQ_ADMIN_PASSWORD=
```

- [ ] **Step 10: Check autoloading, lint, commit**

```bash
CI=1 bin/rails zeitwerk:check
bundle exec standardrb app/lib/sidekiq_web_auth.rb config/routes.rb test/lib/sidekiq_web_auth_test.rb test/integration/sidekiq_admin_mount_test.rb
cd ..
git add web-app/app/lib/sidekiq_web_auth.rb web-app/config/routes.rb web-app/test/lib/sidekiq_web_auth_test.rb \
  web-app/test/integration/sidekiq_admin_mount_test.rb deployment/ENV.md .env.example
git commit -m "Sidekiq Web refuses every login when its credentials are blank

The inline Basic-auth check compared against ENV[...].to_s, so with the
variables unset an empty username and password got in (security audit M2).
Production sets them, so this was latent. Fails at request time, not boot.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: `zeitwerk:check` prints "All is good!"; no standardrb offenses.

---

### Task 4: M4 — the admin viewer role can read the import wizard but not change or delete

**Files:**
- Modify: `web-app/app/controllers/concerns/list_items_actions.rb` (the `included do` block)
- Modify: `web-app/app/controllers/concerns/base_list_wizard_controller.rb` (add an `included do` block)
- Create: `web-app/test/controllers/admin/games/list_import_permission_test.rb`
- Create: `web-app/test/controllers/admin/music/albums/list_import_permission_test.rb`

**Interfaces:**
- Consumes: `require_domain_write!` and `require_domain_delete!` from `Admin::DomainScopedAuth`, already included by `Admin::Music::BaseController` and `Admin::Games::BaseController`. Both redirect to the domain root when denied and return early for global admins/editors.
- Produces: nothing new.

**Background:** `DomainScopedAuth#authenticate_admin!` lets any domain role in, `viewer` included. These two concerns (used by the music albums, music songs and games list-items and wizard controllers) have no write or delete check, so a viewer can verify, re-link, delete and bulk-delete items, and drive the wizard (which enqueues paid OpenAI jobs). The routes table confirms every read is a GET and every change is POST/PATCH/DELETE, so the write gate keys on the verb; a future non-GET action is gated by default. `restart` and `reparse` delete rows, so they take the delete gate.

Fixture roles (verified): `contractor_user` is a music **editor** and a games **viewer**; `games_editor_user` is a games editor; `games_moderator_user` a games moderator; all three have global `role: 0` (`user`).

- [ ] **Step 1: Write the failing games test**

Create `web-app/test/controllers/admin/games/list_import_permission_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Security audit M4. ListItemsActions and BaseListWizardController had no
# write or delete check, so a domain viewer could change and delete import data.
class Admin::Games::ListImportPermissionTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:games]
    @list = lists(:games_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Games::Game",
      verified: false,
      position: 1,
      metadata: {"title" => "Pokémon Go", "rank" => 1}
    )
    @viewer = users(:contractor_user)     # games viewer
    @editor = users(:games_editor_user)
    @moderator = users(:games_moderator_user)
  end

  # --- viewer: reads work ---

  test "viewer can open a wizard step" do
    sign_in_as(@viewer, stub_auth: true)
    get step_admin_games_list_wizard_path(list_id: @list.id, step: "source")
    assert_response :success
  end

  test "viewer can poll step status" do
    sign_in_as(@viewer, stub_auth: true)
    get step_status_admin_games_list_wizard_path(list_id: @list.id, step: "parse", format: :json)
    assert_response :success
  end

  test "viewer can open an item modal" do
    sign_in_as(@viewer, stub_auth: true)
    get modal_admin_games_list_item_path(list_id: @list.id, id: @item.id, modal_type: "edit_metadata")
    assert_response :success
  end

  # --- viewer: writes and deletes are refused ---

  test "viewer cannot verify an item" do
    sign_in_as(@viewer, stub_auth: true)
    post verify_admin_games_list_item_path(list_id: @list.id, id: @item.id)

    assert_redirected_to games_root_path
    refute @item.reload.verified?
  end

  test "viewer cannot save wizard html" do
    sign_in_as(@viewer, stub_auth: true)
    post save_html_admin_games_list_wizard_path(list_id: @list.id), params: {raw_content: "<p>injected</p>"}

    assert_redirected_to games_root_path
    refute_equal "<p>injected</p>", @list.reload.raw_content
  end

  test "viewer cannot delete an item" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to games_root_path
  end

  test "viewer cannot bulk delete" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete bulk_delete_admin_games_list_items_path(list_id: @list.id), params: {item_ids: [@item.id]}
    end
    assert_redirected_to games_root_path
  end

  test "viewer cannot restart the wizard" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      post restart_admin_games_list_wizard_path(list_id: @list.id)
    end
    assert_redirected_to games_root_path
  end

  # --- editor: writes work, deletes are refused ---

  test "editor can verify an item" do
    sign_in_as(@editor, stub_auth: true)
    post verify_admin_games_list_item_path(list_id: @list.id, id: @item.id)

    assert @item.reload.verified?
  end

  test "editor cannot delete an item" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to games_root_path
  end

  test "editor cannot reparse (it deletes unverified items)" do
    sign_in_as(@editor, stub_auth: true)

    assert_no_difference "ListItem.count" do
      post reparse_admin_games_list_wizard_path(list_id: @list.id)
    end
    assert_redirected_to games_root_path
  end

  # --- moderator: deletes work ---

  test "moderator can delete an item" do
    sign_in_as(@moderator, stub_auth: true)

    assert_difference "ListItem.count", -1 do
      delete admin_games_list_item_path(list_id: @list.id, id: @item.id)
    end
  end
end
```

- [ ] **Step 2: Write the failing music test**

Create `web-app/test/controllers/admin/music/albums/list_import_permission_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Security audit M4, music side. See Admin::Games::ListImportPermissionTest.
class Admin::Music::Albums::ListImportPermissionTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:music]
    @list = lists(:music_albums_list)
    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Music::Album",
      verified: false,
      position: 1,
      metadata: {"title" => "The Dark Side of the Moon", "artists" => ["Pink Floyd"], "rank" => 1}
    )
    @editor = users(:contractor_user)     # music editor

    @viewer = User.create!(email: "music.viewer@example.com", role: :user, email_verified: true)
    @viewer.domain_roles.create!(domain: :music, permission_level: :viewer)

    @moderator = User.create!(email: "music.moderator@example.com", role: :user, email_verified: true)
    @moderator.domain_roles.create!(domain: :music, permission_level: :moderator)
  end

  test "viewer can open a wizard step" do
    sign_in_as(@viewer, stub_auth: true)
    get step_admin_albums_list_wizard_path(list_id: @list.id, step: "source")
    assert_response :success
  end

  test "viewer cannot change item metadata" do
    sign_in_as(@viewer, stub_auth: true)
    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate({"title" => "Hacked", "rank" => 1})}}

    assert_redirected_to music_root_path
    assert_equal "The Dark Side of the Moon", @item.reload.metadata["title"]
  end

  test "viewer cannot advance the wizard" do
    sign_in_as(@viewer, stub_auth: true)
    post advance_step_admin_albums_list_wizard_path(list_id: @list.id, step: "source")

    assert_redirected_to music_root_path
  end

  test "viewer cannot bulk delete" do
    sign_in_as(@viewer, stub_auth: true)

    assert_no_difference "ListItem.count" do
      delete bulk_delete_admin_albums_list_items_path(list_id: @list.id), params: {item_ids: [@item.id]}
    end
    assert_redirected_to music_root_path
  end

  test "editor can change item metadata but cannot delete" do
    sign_in_as(@editor, stub_auth: true)
    patch metadata_admin_albums_list_item_path(list_id: @list.id, id: @item.id),
      params: {list_item: {metadata_json: JSON.generate({"title" => "Fixed", "rank" => 1})}}
    assert_equal "Fixed", @item.reload.metadata["title"]

    assert_no_difference "ListItem.count" do
      delete admin_albums_list_item_path(list_id: @list.id, id: @item.id)
    end
    assert_redirected_to music_root_path
  end

  test "moderator can bulk delete" do
    sign_in_as(@moderator, stub_auth: true)

    assert_difference "ListItem.count", -1 do
      delete bulk_delete_admin_albums_list_items_path(list_id: @list.id), params: {item_ids: [@item.id]}
    end
  end
end
```

- [ ] **Step 3: Run both to verify they fail**

```bash
cd web-app
bin/rails test test/controllers/admin/games/list_import_permission_test.rb test/controllers/admin/music/albums/list_import_permission_test.rb
```

Expected: every "viewer cannot …", "editor cannot …" and the editor-delete half FAIL (the action ran). The "can" tests PASS — they pin what the fix must keep. If a "viewer can …" read test fails, stop: a read route is broken before any change.

- [ ] **Step 4: Gate the list-item concern**

In `web-app/app/controllers/concerns/list_items_actions.rb`, replace the `included do` block:

```ruby
  included do
    before_action :set_list
    before_action :set_item, if: :action_requires_item?
  end
```

with:

```ruby
  included do
    # Viewers may look; writers may change; only deleters may delete (security
    # audit M4). Gated on the verb rather than action names: every read here
    # is a GET (modal, the *_search lookups) and every change is POST, PATCH
    # or DELETE, so an action added later is write-gated by default.
    before_action :require_domain_write!, unless: -> { request.get? || request.head? }
    before_action :require_domain_delete!, only: [:destroy, :bulk_delete]
    before_action :set_list
    before_action :set_item, if: :action_requires_item?
  end
```

- [ ] **Step 5: Gate the wizard concern**

In `web-app/app/controllers/concerns/base_list_wizard_controller.rb`, directly after the line `WIZARD_STEPS = %w[source parse enrich validate review import complete].freeze`, add:

```ruby

  included do
    # Viewers may look; writers may drive the wizard (which enqueues paid AI
    # jobs); only deleters may restart or reparse, which destroy list items
    # (security audit M4). Every read (show, show_step, step_status) is a GET.
    before_action :require_domain_write!, unless: -> { request.get? || request.head? }
    before_action :require_domain_delete!, only: [:restart, :reparse]
  end
```

- [ ] **Step 6: Run the new tests to verify they pass**

```bash
bin/rails test test/controllers/admin/games/list_import_permission_test.rb test/controllers/admin/music/albums/list_import_permission_test.rb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 7: Run every existing test of the five controllers**

```bash
bin/rails test test/controllers/admin/games/list_items_actions_controller_test.rb test/controllers/admin/games/list_wizard_controller_test.rb \
  test/controllers/admin/music/albums/list_items_actions_controller_test.rb test/controllers/admin/music/albums/list_wizard_controller_test.rb \
  test/controllers/admin/music/songs/list_items_actions_controller_test.rb test/controllers/admin/music/songs/list_wizard_controller_test.rb
```

Expected: 0 failures (they sign in as `admin_user`, whom both gates pass).

- [ ] **Step 8: Lint and commit**

```bash
bundle exec standardrb app/controllers/concerns/list_items_actions.rb app/controllers/concerns/base_list_wizard_controller.rb \
  test/controllers/admin/games/list_import_permission_test.rb test/controllers/admin/music/albums/list_import_permission_test.rb
cd ..
git add web-app/app/controllers/concerns/list_items_actions.rb web-app/app/controllers/concerns/base_list_wizard_controller.rb \
  web-app/test/controllers/admin/games/list_import_permission_test.rb web-app/test/controllers/admin/music/albums/list_import_permission_test.rb
git commit -m "Admin import wizard: viewers read, writers write, deleters delete

ListItemsActions and BaseListWizardController had no write or delete
check, so a domain viewer could verify, re-link, delete and bulk-delete
items and drive the wizard's paid AI jobs (security audit M4). Writes are
gated on the HTTP verb so a future action is gated by default; destroy,
bulk_delete, restart and reparse need delete permission.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Verify the whole branch

**Files:** none.

- [ ] **Step 1: Full suite, lint, autoload check**

```bash
cd web-app
bin/rails test 2>&1 | tee /tmp/claude-1001/-home-shane-dev-the-greatest/1d060d07-cb75-4dbe-9710-bbd8540ba0d7/scratchpad/pr1-full-suite.log | tail -20
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
```

Expected: 0 failures, 0 errors; no standardrb offenses; "All is good!".

- [ ] **Step 2: Check for new warnings**

```bash
grep -n -i "warning" /tmp/claude-1001/-home-shane-dev-the-greatest/1d060d07-cb75-4dbe-9710-bbd8540ba0d7/scratchpad/pr1-full-suite.log | grep -v -i -E "weighted_list_rank|yarn|npm" | head
```

Expected: no lines (only the two known upstream sources are allowed).

- [ ] **Step 3: Confirm the auth flow end to end**

No new page or flow, so no new Playwright test is required. The existing auth E2E specs exercise sign-in on each domain; run them only if the dev server on port 3000 belongs to this worktree (see AGENTS.md "Port 3000 is shared"):

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If another checkout holds the port, skip and say so in the report — do not kill it.

- [ ] **Step 4: Report, do not push**

Report the commits on `worktree-security-audit-fixes` since `main` (`git log --oneline main..HEAD`), test counts, and that the branch is **unpushed**. Ask Shane before pushing or opening the PR. The PR description must say merging deploys to production and that H1 is live on music and games.
