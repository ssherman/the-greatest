# OAuth Provider Registry and Sign in with X — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the five-file-per-provider social login pattern with one declarative registry, and ship Sign in with X on it.

**Architecture:** A single `config/auth_providers.json` is read by Rails and handed to JavaScript through a Stimulus value, so there is one list rather than one per layer. A generic OAuth provider class replaces the per-provider singletons, and one Stimulus action replaces one method per provider. Separately, account linking stops keying off the token's `email_verified` claim and keys off an enumerated trusted-provider allowlist instead — without which X sign-in dead-ends at a verification wall.

**Tech Stack:** Rails 8, Minitest + Mocha + fixtures, Stimulus, ViewComponents, daisyUI 5 / Tailwind 4, Rollup, Firebase JS SDK 12, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-05-oauth-provider-registry-design.md`

## Global Constraints

- **Run everything from `web-app/`.** Docs live at the project root, not `web-app/docs/`.
- **Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/facebook-login`, branch `worktree-facebook-login`. Never `cd` to the main checkout.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. Do not run brakeman.
- **`bin/rails test` does NOT build JavaScript.** After touching anything under `app/javascript/`, run `yarn build` or a syntax error ships invisibly.
- **There is no JS test runner in this project.** JavaScript is covered by source-level guards in `test/lint/` and by Playwright. Do not add a JS test framework.
- **Minitest 6:** `assert_equal nil, x` is a hard failure. Use `assert_nil`.
- **Services use the Result pattern** where they return one: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. The services touched here return plain hashes already; do not change that.
- **daisyUI 5.** These classes are removed and fail silently: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any occurrence; the fix is removing the class, never allowlisting it.
- **`TRUSTED_EMAIL_PROVIDERS` must never contain `"password"`.** It is the account-takeover vector the guard exists to block.
- **Never run a destructive command against development.** No `create_fixtures`, no `db:drop`/`db:reset`/`db:schema:load`, no bulk `delete_all`/`update_all` in `rails runner`.
- **Do not enable Facebook.** It ships `"enabled": false`. The Meta app is disabled and a replacement is separate work.

---

### Task 1: Provider registry — config file and Ruby reader

**Files:**
- Create: `web-app/config/auth_providers.json`
- Create: `web-app/app/lib/services/auth_provider_registry.rb`
- Test: `web-app/test/lib/services/auth_provider_registry_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `Services::AuthProviderRegistry.all` → `Hash{String => Hash}` keyed by provider id; `.enabled` → same shape, filtered to `"enabled" => true`; `.provider_names` → `Array<String>` of all ids; `.enabled_for_view` → `Array<Hash>` with symbol keys `:id, :firebase_id, :label, :scopes`, ordered as the file is.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/auth_provider_registry_test.rb`:

```ruby
require "test_helper"

class Services::AuthProviderRegistryTest < ActiveSupport::TestCase
  test "all returns every known provider keyed by id" do
    assert_kind_of Hash, Services::AuthProviderRegistry.all
    assert_includes Services::AuthProviderRegistry.provider_names, "google"
    assert_includes Services::AuthProviderRegistry.provider_names, "twitter"
    assert_includes Services::AuthProviderRegistry.provider_names, "facebook"
    assert_includes Services::AuthProviderRegistry.provider_names, "apple"
  end

  test "every entry declares the keys the view and the client need" do
    Services::AuthProviderRegistry.all.each do |id, entry|
      assert_match(/\A[a-z]+\z/, id, "provider id #{id.inspect} must be lowercase letters")
      assert_kind_of String, entry["firebase_id"], "#{id} needs a firebase_id"
      assert_kind_of String, entry["label"], "#{id} needs a label"
      assert_kind_of Array, entry["scopes"], "#{id} needs a scopes array"
      assert_includes [true, false], entry["enabled"], "#{id} needs an explicit enabled boolean"
    end
  end

  test "enabled excludes providers that are turned off" do
    enabled = Services::AuthProviderRegistry.enabled

    assert_includes enabled.keys, "google"
    assert_includes enabled.keys, "twitter"
    refute_includes enabled.keys, "facebook",
      "Facebook must ship disabled: the Meta app is restricted to development mode."
    refute_includes enabled.keys, "apple",
      "Apple is not implemented in this pass."
  end

  test "enabled_for_view exposes symbol keys in file order" do
    entries = Services::AuthProviderRegistry.enabled_for_view

    assert_equal %w[google twitter], entries.map { |e| e[:id] }
    google = entries.first
    assert_equal "google.com", google[:firebase_id]
    assert_equal "Google", google[:label]
    assert_equal ["profile", "email"], google[:scopes]
  end

  test "the X entry is labelled X and requests no scopes" do
    x = Services::AuthProviderRegistry.all.fetch("twitter")

    assert_equal "twitter.com", x["firebase_id"]
    assert_equal "X", x["label"]
    assert_empty x["scopes"], "Firebase's Twitter provider takes no scopes"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lib/services/auth_provider_registry_test.rb`
Expected: FAIL with `NameError: uninitialized constant Services::AuthProviderRegistry`.

- [ ] **Step 3: Create the config file**

Create `web-app/config/auth_providers.json`:

```json
{
  "google": {
    "firebase_id": "google.com",
    "label": "Google",
    "scopes": ["profile", "email"],
    "enabled": true
  },
  "twitter": {
    "firebase_id": "twitter.com",
    "label": "X",
    "scopes": [],
    "enabled": true
  },
  "facebook": {
    "firebase_id": "facebook.com",
    "label": "Facebook",
    "scopes": ["public_profile", "email"],
    "enabled": false
  },
  "apple": {
    "firebase_id": "apple.com",
    "label": "Apple",
    "scopes": ["email", "name"],
    "enabled": false
  }
}
```

- [ ] **Step 4: Write the reader**

Create `web-app/app/lib/services/auth_provider_registry.rb`:

```ruby
# The single source of truth for which social providers this app knows about.
#
# Shared rather than duplicated for the same reason config/asset_bundles.json
# is (see test/lint/asset_bundle_coverage_test.rb): the widget, the client, and
# AuthController#check_provider each need this list, and three copies drift.
#
# "enabled" gates the BUTTON only. A disabled provider can still authenticate
# if a token arrives from elsewhere -- the legacy site shares this Firebase
# project, so its Apple and Facebook tokens validate against /auth/sign_in
# today. That is why PROVIDER_MAP in AuthenticationService stays broader than
# the enabled set, and why check_provider reads every entry rather than only
# the enabled ones.
#
# This is NOT the trust boundary. Which providers may link an account by email
# is AuthenticationService::TRUSTED_EMAIL_PROVIDERS, a hardcoded constant --
# deliberately not config, so turning a button on can never widen a security
# decision as a side effect.
module Services
  class AuthProviderRegistry
    CONFIG_PATH = "config/auth_providers.json"

    class << self
      def all
        @all ||= JSON.parse(File.read(Rails.root.join(CONFIG_PATH))).freeze
      end

      def provider_names
        all.keys
      end

      def enabled
        all.select { |_id, entry| entry["enabled"] }
      end

      # Symbol-keyed and ordered, for the widget and the Stimulus value. Kept
      # separate from #enabled so the view is not coupled to the file's string
      # keys.
      def enabled_for_view
        enabled.map do |id, entry|
          {
            id: id,
            firebase_id: entry["firebase_id"],
            label: entry["label"],
            scopes: entry["scopes"]
          }
        end
      end

      # Test seam: the file is memoised because it cannot change at runtime.
      def reset!
        @all = nil
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/lib/services/auth_provider_registry_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **Step 6: Verify Zeitwerk resolves the new constant**

`eager_load` is off in test, so a naming mistake here would not surface until production boot.

Run: `cd web-app && CI=1 bin/rails zeitwerk:check`
Expected: `All is good!`

- [ ] **Step 7: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/auth_provider_registry.rb test/lib/services/auth_provider_registry_test.rb
git add web-app/config/auth_providers.json web-app/app/lib/services/auth_provider_registry.rb web-app/test/lib/services/auth_provider_registry_test.rb
git commit -m "feat(auth): add a shared OAuth provider registry"
```

---

### Task 2: Allow a nil email on OAuth accounts

**Files:**
- Modify: `web-app/app/models/user.rb:79` (the `validates :email` line)
- Test: `web-app/test/models/user_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `User#external_oauth_account?` → `Boolean`. True when `external_provider` is present and is not `password`.

**Why this comes first:** later tasks create users from tokens that carry no email. Without this, those tests fail on a validation rather than on the behaviour under test.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/models/user_test.rb`, inside the existing `UserTest` class:

```ruby
  # 20,063 rows in production already have a nil email -- they migrated via
  # upsert_all, which bypasses validations, so the model and the table have
  # been disagreeing. X supplies no email for roughly 4% of sign-ins, and
  # refusing those outright is worse than an account that cannot be linked.
  test "an OAuth account may have no email" do
    user = User.new(
      auth_uid: "x-uid-no-email",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    assert user.valid?, user.errors.full_messages.join(", ")
  end

  test "two OAuth accounts may both have no email" do
    User.create!(
      auth_uid: "x-uid-no-email-1",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    second = User.new(
      auth_uid: "x-uid-no-email-2",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    # Rails' uniqueness validator compares `email IS NULL`, so without
    # allow_nil the second nil-email row collides with the first even though
    # Postgres permits any number of NULLs.
    assert second.valid?, second.errors.full_messages.join(", ")
  end

  test "a password account still requires an email" do
    user = User.new(
      auth_uid: "password-uid-no-email",
      external_provider: :password,
      email_verified: false,
      role: :user
    )

    refute user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "an account with no provider at all still requires an email" do
    user = User.new(auth_uid: "orphan-uid", email_verified: false, role: :user)

    refute user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test "email uniqueness is still enforced when an email is present" do
    duplicate = User.new(
      email: users(:google_user).email,
      auth_uid: "some-other-uid",
      external_provider: :google,
      email_verified: true,
      role: :user
    )

    refute duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/models/user_test.rb -n "/OAuth account/"`
Expected: FAIL — `an OAuth account may have no email` fails with `Email can't be blank, Email has already been taken`.

- [ ] **Step 3: Change the validation**

In `web-app/app/models/user.rb`, replace this line:

```ruby
  validates :email, presence: true, uniqueness: true
```

with:

```ruby
  # Presence is conditional on the provider, not on auth_uid: password users
  # hold an auth_uid too, so keying on it would exempt exactly the accounts
  # that must have an email. A nil external_provider also stays required --
  # nothing identifies such a row.
  #
  # allow_nil on uniqueness is not optional. Rails compares `email IS NULL`,
  # so a second nil-email row collides with the first even though Postgres
  # permits any number of NULLs. Verified on users#1 (a V1 twitter row), which
  # fails today with BOTH "can't be blank" and "has already been taken".
  validates :email, presence: true, unless: :external_oauth_account?
  validates :email, uniqueness: {allow_nil: true}
```

Then add this public method, immediately after the `granting_membership` method:

```ruby
  # Any provider other than password. Derived from the enum rather than a
  # second hardcoded list, so adding a provider cannot leave this behind.
  def external_oauth_account?
    external_provider.present? && !password?
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/models/user_test.rb`
Expected: all pass.

- [ ] **Step 5: Run the full model and service suites for regressions**

The validation change touches every user-creating test in the suite.

Run: `cd web-app && bin/rails test test/models test/lib/services`
Expected: 0 failures.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/models/user.rb test/models/user_test.rb
git add web-app/app/models/user.rb web-app/test/models/user_test.rb
git commit -m "feat(auth): allow OAuth accounts to have no email"
```

---

### Task 3: Trust the provider, not the `email_verified` claim

**Files:**
- Modify: `web-app/app/lib/services/authentication_service.rb`
- Modify: `web-app/app/lib/services/user_authentication_service.rb:45,58`
- Test: `web-app/test/lib/services/authentication_service_test.rb`
- Test: `web-app/test/lib/services/user_authentication_service_test.rb`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS` → frozen `Array<String>` of Firebase `sign_in_provider` values. `extract_provider_data` now also returns the key `:email_trusted` → `Boolean`. `Services::UserAuthenticationService` reads `provider_data[:email_trusted]` for the linking decision and continues to read `provider_data[:email_verified]` for the column.

**This is the change that makes X usable.** X verifies addresses by confirmation mail but exposes no flag, so Firebase sends `email_verified: false`. Without this, every returning X user with an existing account is told to go verify their email.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/services/authentication_service_test.rb`, inside the class:

```ruby
  # F1. The guard's real question is not "did the token say verified" but
  # "could someone have registered this address at this provider without
  # controlling it". For X the answer is no -- it verifies by confirmation
  # mail -- but Firebase sends no flag saying so.
  test "a trusted OAuth provider is email-trusted even when the claim is false" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-x-1",
      "email" => "x.person@example.com",
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "twitter.com"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert result[:provider_data][:email_trusted], "twitter.com must be email-trusted"
    refute result[:provider_data][:email_verified],
      "the raw claim must still be recorded as false"
  end

  test "every trusted provider is trusted with a false claim" do
    Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS.each_with_index do |sign_in_provider, i|
      token = FirebaseTokenHelper.token({
        "sub" => "uid-trusted-#{i}",
        "email" => "trusted#{i}@example.com",
        "email_verified" => false,
        "firebase" => {"sign_in_provider" => sign_in_provider}
      })

      result = call(token)

      assert result[:success], "#{sign_in_provider}: #{result[:error]}"
      assert result[:provider_data][:email_trusted], "#{sign_in_provider} must be email-trusted"
    end
  end

  test "password is never email-trusted on a false claim" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-pw-untrusted",
      "email" => "pw.person@example.com",
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    assert result[:success], result[:error]
    refute result[:provider_data][:email_trusted],
      "a Firebase password account can be created for any address without " \
      "proving control -- this is the takeover vector the guard blocks"
  end

  test "password IS email-trusted once the claim is genuinely true" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-pw-verified",
      "email" => "pw.verified@example.com",
      "email_verified" => true,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    assert result[:success], result[:error]
    assert result[:provider_data][:email_trusted]
  end

  test "the trusted list never contains password" do
    refute_includes Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS, "password"
  end
```

Append to `web-app/test/lib/services/user_authentication_service_test.rb`, inside the class:

```ruby
  test "a trusted provider links to an existing account despite an unverified claim" do
    existing = users(:google_user)

    user = call(
      user_id: "brand-new-x-uid",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_equal existing.id, user.id, "X sign-in must land on the existing account"
    assert_equal "brand-new-x-uid", user.reload.auth_uid
  end

  test "an untrusted provider still refuses to link on an unverified email" do
    existing = users(:google_user)

    assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
      call(
        user_id: "attacker-uid",
        email: existing.email,
        email_verified: false,
        email_trusted: false,
        provider: "password"
      )
    end
  end

  test "the linking decision reads email_trusted, not email_verified" do
    existing = users(:google_user)

    # Deliberately contradictory: verified false, trusted true. If the guard
    # still read email_verified this would raise.
    user = call(
      user_id: "contradiction-uid",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "facebook"
    )

    assert_equal existing.id, user.id
  end

  test "a trusted sign-in does not mark the column verified" do
    existing = users(:google_user)
    existing.update!(email_verified: false)

    call(
      user_id: "x-uid-column-check",
      email: existing.email,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    refute existing.reload.email_verified,
      "the column records the provider's actual claim, not our trust inference"
  end
```

- [ ] **Step 2: Update the test helper's default provider data**

`UserAuthenticationService` is called directly by these tests with a hand-built hash. Every existing test would start failing closed once the guard reads a key their hash does not have.

In `web-app/test/lib/services/user_authentication_service_test.rb`, change the `provider_data` helper's default hash to include the new key, immediately after `email_verified: true`:

```ruby
      email_verified: true,
      email_trusted: true,
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/authentication_service_test.rb test/lib/services/user_authentication_service_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS`, and the linking tests fail with `UnverifiedEmailConflict`.

- [ ] **Step 4: Add the trusted-provider constant and the derived claim**

In `web-app/app/lib/services/authentication_service.rb`, add this constant immediately after `PROVIDER_MAP`:

```ruby
    # Providers that require email ownership at signup, so their address
    # assertion is trusted for account linking even when Firebase passes no
    # email_verified flag. X in particular verifies by confirmation mail but
    # exposes no flag for it, and Firebase therefore sends false.
    #
    # The question this answers is NOT "did the token say verified" -- it is
    # "could someone have registered this address at this provider without
    # controlling it". You cannot create a Google account on someone else's
    # Gmail, and X will not activate an account until it confirms the address.
    #
    # "password" is deliberately absent and MUST stay absent: a Firebase
    # password account can be created for any address without proving control,
    # which is precisely the account-takeover route UnverifiedEmailConflict
    # exists to block.
    #
    # This list is enumerated, never derived. A future provider that does not
    # require email ownership must not become trusted merely by not being
    # "password". It is also deliberately NOT read from
    # config/auth_providers.json: enabling a button must never widen a security
    # decision as a side effect.
    TRUSTED_EMAIL_PROVIDERS = %w[google.com apple.com facebook.com twitter.com].freeze
```

Then in `extract_provider_data`, add the new key immediately after the existing `email_verified:` line:

```ruby
        email_verified: payload["email_verified"] == true,
        # What the linking decision actually uses. Kept separate from the raw
        # claim above so the users.email_verified column keeps recording what
        # the provider genuinely asserted.
        email_trusted: payload["email_verified"] == true ||
          TRUSTED_EMAIL_PROVIDERS.include?(sign_in_provider),
```

- [ ] **Step 5: Make the guard read the new key**

In `web-app/app/lib/services/user_authentication_service.rb`, add a reader next to the existing `email_verified?` (line 45):

```ruby
    def email_verified? = provider_data[:email_verified] == true
    def email_trusted? = provider_data[:email_trusted] == true
```

Then change the guard on line 58 from:

```ruby
      raise UnverifiedEmailConflict, "unverified email matches an existing account" unless email_verified?
```

to:

```ruby
      raise UnverifiedEmailConflict, "untrusted email matches an existing account" unless email_trusted?
```

Finally, update the class comment's step 3 so it describes what the code now does. Replace:

```
#   3. an UNVERIFIED email that matches an existing account is refused outright.
#      This is the takeover route: anyone can create a Firebase password account
#      for someone else's address, and the previous version matched on email
#      unconditionally and then update!'d that row.
```

with:

```
#   3. an UNTRUSTED email that matches an existing account is refused outright.
#      This is the takeover route: anyone can create a Firebase password account
#      for someone else's address, and the previous version matched on email
#      unconditionally and then update!'d that row.
#
#      "Trusted" is broader than "verified" on purpose. A real OAuth provider
#      already proved ownership at signup, and X does so without ever sending
#      an email_verified flag -- so gating on the flag alone would send every
#      returning X user to a verification wall. See
#      AuthenticationService::TRUSTED_EMAIL_PROVIDERS. password is not on that
#      list and never will be.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/authentication_service_test.rb test/lib/services/user_authentication_service_test.rb test/controllers/auth_controller_test.rb`
Expected: 0 failures.

- [ ] **Step 7: Mutation-check the guard**

A test that cannot fail is worth nothing. Temporarily revert the guard to `unless email_verified?` and confirm the suite catches it.

Run: `cd web-app && bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: FAIL on `a trusted provider links to an existing account despite an unverified claim`. Restore the guard and re-run to green before continuing.

- [ ] **Step 8: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services test/lib/services
git add web-app/app/lib/services/authentication_service.rb web-app/app/lib/services/user_authentication_service.rb web-app/test/lib/services/authentication_service_test.rb web-app/test/lib/services/user_authentication_service_test.rb
git commit -m "fix(auth): trust the provider rather than the email_verified claim"
```

---

### Task 4: Fill a blank email on sign-in, never overwrite one

**Files:**
- Modify: `web-app/app/lib/services/user_authentication_service.rb` (`update_existing`)
- Test: `web-app/test/lib/services/user_authentication_service_test.rb`

**Interfaces:**
- Consumes: `email_trusted?` from Task 3.
- Produces: no new public API. `update_existing` now writes `email` when, and only when, the existing row has none.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/lib/services/user_authentication_service_test.rb`:

```ruby
  test "a sign-in fills a blank email" do
    blank = User.create!(
      auth_uid: "x-uid-blank-email",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    call(
      user_id: blank.auth_uid,
      email: "now.has.one@example.com",
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_equal "now.has.one@example.com", blank.reload.email,
      "an email-less row must pick up an address so it becomes linkable"
  end

  test "a sign-in never overwrites an existing email" do
    existing = users(:google_user)
    original = existing.email

    call(
      user_id: existing.auth_uid,
      email: "attacker.controlled@example.com",
      email_verified: true,
      email_trusted: true,
      provider: "google"
    )

    assert_equal original, existing.reload.email,
      "a sign-in must never rewrite the address an account is known by"
  end

  test "a sign-in with no email leaves a blank email blank" do
    blank = User.create!(
      auth_uid: "x-uid-still-blank",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    call(
      user_id: blank.auth_uid,
      email: nil,
      email_verified: false,
      email_trusted: true,
      provider: "twitter"
    )

    assert_nil blank.reload.email
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/user_authentication_service_test.rb -n "/blank email/"`
Expected: FAIL — `a sign-in fills a blank email` gets `nil`.

- [ ] **Step 3: Write the implementation**

In `web-app/app/lib/services/user_authentication_service.rb`, in `update_existing`, replace the comment and add the key. The current code opens:

```ruby
    def update_existing(user)
      # email is deliberately absent: a sign-in must never rewrite the address
      # an account is known by.
      user.update!(
        auth_uid: uid,
```

Replace those lines with:

```ruby
    def update_existing(user)
      # Fill a blank, never overwrite. Rewriting the address an account is
      # known by would be an account-takeover primitive; filling a blank is
      # not, and it is the only way an email-less OAuth row (X supplies no
      # address for roughly 4% of sign-ins, and 20,063 legacy rows have none)
      # ever becomes linkable to the same human's other providers.
      user.update!(
        email: user.email.presence || email,
        auth_uid: uid,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: 0 failures.

- [ ] **Step 5: Mutation-check the guard**

Temporarily change the new line to `email: email,` and confirm a test fails.

Run: `cd web-app && bin/rails test test/lib/services/user_authentication_service_test.rb -n "/never overwrites/"`
Expected: FAIL. Restore `user.email.presence || email` and re-run to green.

- [ ] **Step 6: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/lib/services/user_authentication_service.rb test/lib/services/user_authentication_service_test.rb
git add web-app/app/lib/services/user_authentication_service.rb web-app/test/lib/services/user_authentication_service_test.rb
git commit -m "feat(auth): fill a blank email on sign-in without overwriting one"
```

---

### Task 5: `check_provider` reads the registry

**Files:**
- Modify: `web-app/app/controllers/auth_controller.rb` (`check_provider`)
- Test: `web-app/test/controllers/auth_controller_test.rb`

**Interfaces:**
- Consumes: `Services::AuthProviderRegistry.provider_names` from Task 1.
- Produces: no new API. `check_provider` keeps its existing JSON shape.

`provider_names`, not `enabled` — a disabled provider's users still exist and still need the "use Sign in with X instead" message. 1,521 Apple users are in that position today.

- [ ] **Step 1: Write the failing test**

Append to `web-app/test/controllers/auth_controller_test.rb`, inside the class:

```ruby
  test "check_provider names every registry provider, not only the enabled ones" do
    apple_user = User.create!(
      email: "apple.person@example.com",
      auth_uid: "apple-uid-check-provider",
      external_provider: :apple,
      email_verified: true,
      role: :user
    )

    post auth_check_provider_path, params: {email: apple_user.email}, as: :json

    body = JSON.parse(response.body)
    assert body["has_oauth_provider"],
      "Apple ships disabled but 1,521 Apple users exist and still need the hint"
    assert_equal "apple", body["provider"]
  end

  test "check_provider still refuses to advertise password accounts" do
    post auth_check_provider_path, params: {email: users(:password_user).email}, as: :json

    body = JSON.parse(response.body)
    refute body["has_oauth_provider"], "advertising password accounts is an enumeration oracle"
    assert_nil body["provider"]
  end

  test "check_provider advertises X by its registry label" do
    x_user = User.create!(
      email: "x.person@example.com",
      auth_uid: "x-uid-check-provider",
      external_provider: :twitter,
      email_verified: false,
      role: :user
    )

    post auth_check_provider_path, params: {email: x_user.email}, as: :json

    body = JSON.parse(response.body)
    assert body["has_oauth_provider"]
    assert_equal "twitter", body["provider"]
    assert_includes body["message"], "X",
      "the message must use the registry label, not a capitalised enum name"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/controllers/auth_controller_test.rb -n "/check_provider/"`
Expected: FAIL on the X label test — the current code renders "Twitter", not "X".

- [ ] **Step 3: Write the implementation**

In `web-app/app/controllers/auth_controller.rb`, replace this block in `check_provider`:

```ruby
    # Only reveal OAuth providers, not password accounts (to avoid email enumeration)
    oauth_providers = %w[google apple facebook twitter]

    if user && oauth_providers.include?(user.external_provider)
      provider_name = user.external_provider.capitalize
```

with:

```ruby
    # Only reveal OAuth providers, not password accounts (to avoid email
    # enumeration).
    #
    # provider_names, not enabled: a provider whose button is turned off still
    # has users who need this hint. 1,521 Apple accounts are in exactly that
    # position, and the legacy site can still mint their tokens.
    registry = Services::AuthProviderRegistry.all

    if user && registry.key?(user.external_provider)
      # The registry label, not the enum name capitalised -- otherwise X reads
      # as "Twitter" and names a button that does not exist.
      provider_name = registry.fetch(user.external_provider).fetch("label")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/controllers/auth_controller_test.rb`
Expected: 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
cd web-app && bundle exec standardrb app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git add web-app/app/controllers/auth_controller.rb web-app/test/controllers/auth_controller_test.rb
git commit -m "feat(auth): check_provider reads the shared provider registry"
```

---

### Task 6: Generic OAuth provider in JavaScript

**Files:**
- Create: `web-app/app/javascript/services/auth_providers/oauth_provider.js`
- Delete: `web-app/app/javascript/services/auth_providers/google_provider.js`
- Modify: `web-app/app/javascript/entrypoints/firebase_auth.js`
- Test: `web-app/test/lint/auth_provider_registry_test.rb`

**Interfaces:**
- Consumes: `firebaseAuthService` (existing singleton).
- Produces: `window.__tgFirebase.oauthProvider`, an object with `async signIn(providerConfig, event)` where `providerConfig` is `{id, firebase_id, label, scopes}`. Also `providerClassFor(firebaseId)` for the lint test to reason about. `window.__tgFirebase.googleProvider` is **removed**.

**Deliberate deviation from the spec.** The spec described a separate
`services/auth_providers/registry.js` that imports the JSON and holds the constructor map.
There is no `@rollup/plugin-json` in this project, so the JSON cannot be imported, and the
config travels through a Stimulus value instead (Task 7). That leaves `registry.js` holding
nothing but the constructor map, so it is merged into `oauth_provider.js` rather than
existing as a one-constant file. Adding a build plugin to relocate a list Rails already
reads would be the wrong trade.

- [ ] **Step 1: Write the failing lint test**

There is no JS test runner, so this is a source-level guard in the same spirit as `test/lint/firebase_action_code_settings_test.rb`.

Create `web-app/test/lint/auth_provider_registry_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# config/auth_providers.json is read by Ruby; the browser gets it through a
# Stimulus value on the widget. The one thing that cannot travel as data is
# which Firebase class constructs each provider, so that map lives in JS -- and
# a provider present in the config but missing from the map fails silently at
# the moment someone clicks the button.
#
# There is no JS test runner in this project, so this is a source-level guard,
# same as test/lint/firebase_action_code_settings_test.rb.
class AuthProviderRegistryLintTest < ActiveSupport::TestCase
  OAUTH_PROVIDER_JS = Rails.root.join("app/javascript/services/auth_providers/oauth_provider.js")
  ENTRYPOINT_JS = Rails.root.join("app/javascript/entrypoints/firebase_auth.js")

  test "every configured provider has a Firebase constructor in the JS map" do
    source = File.read(OAUTH_PROVIDER_JS)

    Services::AuthProviderRegistry.all.each do |id, entry|
      assert_includes source, "'#{entry["firebase_id"]}'",
        "#{id} is in config/auth_providers.json but #{entry["firebase_id"]} is " \
        "absent from the constructor map in #{OAUTH_PROVIDER_JS.basename}. " \
        "The button would render and then fail on click."
    end
  end

  test "the per-provider singletons are gone" do
    removed = Rails.root.join("app/javascript/services/auth_providers/google_provider.js")

    refute File.exist?(removed),
      "google_provider.js should have been replaced by the generic oauth_provider.js"
  end

  test "the entrypoint exposes the generic provider, not a named singleton" do
    source = File.read(ENTRYPOINT_JS)

    assert_includes source, "oauthProvider",
      "the firebase bundle must expose the generic OAuth provider"
    refute_includes source, "googleProvider",
      "a named per-provider singleton defeats the registry"
  end

  test "email_provider is still exposed separately" do
    source = File.read(ENTRYPOINT_JS)

    assert_includes source, "emailProvider",
      "email/password is a different shape and must not be folded into the " \
      "OAuth abstraction"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lint/auth_provider_registry_test.rb`
Expected: FAIL — `oauth_provider.js` does not exist, so `File.read` raises `Errno::ENOENT`.

- [ ] **Step 3: Write the generic provider**

Create `web-app/app/javascript/services/auth_providers/oauth_provider.js`:

```js
import {
  GoogleAuthProvider,
  TwitterAuthProvider,
  FacebookAuthProvider,
  OAuthProvider,
  signInWithRedirect
} from 'firebase/auth'
import firebaseAuthService from '../firebase_auth_service.js'

// The only irreducibly per-provider JavaScript in the app. Everything else
// about a provider -- its id, label, scopes and whether its button renders --
// travels from config/auth_providers.json as data.
//
// Firebase needs a dedicated class for the providers it special-cases;
// OAuthProvider is the generic, id-constructed fallback and is what Apple
// uses. Getting this wrong fails at click time, not at build time, which is
// why test/lint/auth_provider_registry_test.rb pins every configured provider
// to an entry here.
const PROVIDER_CLASSES = {
  'google.com': GoogleAuthProvider,
  'twitter.com': TwitterAuthProvider,
  'facebook.com': FacebookAuthProvider
}

export function providerClassFor(firebaseId) {
  return PROVIDER_CLASSES[firebaseId] || null
}

class OauthProvider {
  // config is one entry from the registry: {id, firebase_id, label, scopes}.
  build(config) {
    const ProviderClass = providerClassFor(config.firebase_id)
    const provider = ProviderClass
      ? new ProviderClass()
      : new OAuthProvider(config.firebase_id)

    for (const scope of config.scopes || []) {
      provider.addScope(scope)
    }

    return provider
  }

  async signIn(config, event = null) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }

    try {
      const auth = firebaseAuthService.getAuth()
      await signInWithRedirect(auth, this.build(config))
    } catch (error) {
      console.error(`${config.label} sign in error:`, error)

      window.dispatchEvent(new CustomEvent('auth:error', {
        detail: {
          error: error.message,
          provider: config.id
        }
      }))

      throw error
    }
  }
}

const oauthProvider = new OauthProvider()

export default oauthProvider
```

- [ ] **Step 4: Delete the Google singleton and update the entrypoint**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/facebook-login
git rm web-app/app/javascript/services/auth_providers/google_provider.js
```

Then in `web-app/app/javascript/entrypoints/firebase_auth.js`, replace the import block and the window assignment:

```js
import firebaseAuthService from "../services/firebase_auth_service"
import oauthProvider from "../services/auth_providers/oauth_provider"
import emailProvider from "../services/auth_providers/email_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"

// oauthProvider is generic: the Stimulus controller passes it one registry
// entry per click, so a new provider needs no change here. emailProvider stays
// separate on purpose -- no redirect, plus signup, reset and verification.
window.__tgFirebase = { firebaseAuthService, oauthProvider, emailProvider, redirectHandler }
```

- [ ] **Step 5: Run the lint test to verify it passes**

Run: `cd web-app && bin/rails test test/lint/auth_provider_registry_test.rb`
Expected: 4 runs, 0 failures.

- [ ] **Step 6: Build the bundle**

`bin/rails test` does not build JavaScript. A syntax error here would otherwise ship invisibly.

Run: `cd web-app && yarn build`
Expected: builds with no `UNRESOLVED_IMPORT` error. Confirm `app/assets/builds/firebase-auth.js` was rewritten.

- [ ] **Step 7: Commit**

```bash
git add web-app/app/javascript/services/auth_providers/oauth_provider.js web-app/app/javascript/entrypoints/firebase_auth.js web-app/test/lint/auth_provider_registry_test.rb
git commit -m "refactor(auth): replace the Google singleton with a generic OAuth provider"
```

---

### Task 7: One Stimulus action for every OAuth provider

**Files:**
- Modify: `web-app/app/javascript/controllers/authentication_controller.js` (`signInWithGoogle`, `static values`)
- Test: `web-app/test/lint/auth_provider_registry_test.rb`

**Interfaces:**
- Consumes: `window.__tgFirebase.oauthProvider` from Task 6.
- Produces: Stimulus action `signInWithOauth(event)`, reading `event.params.provider` (a provider id string). Stimulus value `providers: Array`, populated by the widget in Task 8 with `[{id, firebase_id, label, scopes}, …]`. `signInWithGoogle` is **removed**.

- [ ] **Step 1: Add the failing lint assertions**

Append to `web-app/test/lint/auth_provider_registry_test.rb`, inside the class:

```ruby
  CONTROLLER_JS = Rails.root.join("app/javascript/controllers/authentication_controller.js")

  test "the controller has one generic OAuth action, not one per provider" do
    source = File.read(CONTROLLER_JS)

    assert_includes source, "signInWithOauth",
      "the controller needs a single generic OAuth sign-in action"
    refute_match(/signInWith(Google|Twitter|Facebook|Apple)\b/, source,
      "a per-provider action defeats the registry: adding a provider must not " \
      "mean editing this 688-line controller")
  end

  test "the controller declares a providers value" do
    source = File.read(CONTROLLER_JS)

    assert_match(/providers:\s*Array/, source,
      "the registry reaches the browser as a Stimulus Array value -- there is " \
      "no @rollup/plugin-json in this project, so the config cannot be imported")
  end

  test "the generic action still marks the pending redirect" do
    source = File.read(CONTROLLER_JS)
    action = source[/async signInWithOauth\(event\)\s*\{.*?\n  \}/m]

    assert action, "could not find signInWithOauth in #{CONTROLLER_JS}"
    assert_includes action, "markPendingRedirect()",
      "without this, a reload mid-redirect loses the sign-in silently: tg_uid " \
      "is unset, markSignedIn has not run, and Firebase has consumed its own key"
    assert_includes action, "clearPendingRedirect()",
      "a failed redirect must clear the marker it set"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/lint/auth_provider_registry_test.rb`
Expected: FAIL — `signInWithOauth` is absent and `signInWithGoogle` is present.

- [ ] **Step 3: Add the providers value**

In `web-app/app/javascript/controllers/authentication_controller.js`, change the `static values` block from:

```js
  static values = {
    reloadAfterAuth: Boolean,
    currentUser: Object,
    firebaseSrc: String
  }
```

to:

```js
  static values = {
    reloadAfterAuth: Boolean,
    currentUser: Object,
    firebaseSrc: String,
    // The enabled entries from config/auth_providers.json, handed over by the
    // widget. A Stimulus value rather than a JS import because there is no
    // @rollup/plugin-json in this project, and adding one to move a list that
    // Rails already reads would be the wrong trade.
    providers: Array
  }
```

- [ ] **Step 4: Replace the Google action with the generic one**

Replace the whole `signInWithGoogle` method — from its `// Handle Google sign in` comment through its closing brace — with:

```js
  // Look up one registry entry by id. Returns null for an unknown id rather
  // than throwing, so a stale button in cached Turbo markup degrades to a
  // visible error instead of an unhandled rejection.
  providerConfig(id) {
    return this.providersValue.find((provider) => provider.id === id) || null
  }

  // Handles every OAuth provider. The button supplies its id through a
  // Stimulus action param, so adding a provider touches config and markup
  // only -- never this file.
  async signInWithOauth(event) {
    event.preventDefault()

    const id = event.params.provider
    const config = this.providerConfig(id)

    if (!config) {
      console.error(`Unknown auth provider: ${id}`)
      this.showError('Sign-in is temporarily unavailable. Please try again.')
      return
    }

    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    // Resolved in its own try, same shape as submitEmailForm: a bundle-load
    // failure (e.g. firebase-auth.js 404s) has an error.message like "failed
    // to load firebase bundle from /assets/firebase-auth-a1b2c3.js", which is
    // meaningless -- and alarming -- in the login modal. A genuine Firebase
    // auth error below (the reader cancelling the provider flow, a real
    // provider error) is still shown verbatim, since that message IS useful.
    let firebase
    try {
      firebase = await this.firebase()
    } catch (error) {
      console.error("Firebase load failed:", error)
      this.showError("Sign-in is temporarily unavailable. Please try again.")
      this.showLoading(false)
      return
    }

    try {
      // Set BEFORE the redirect leaves the page: on return, connect() sees this
      // and eager-loads Firebase so getRedirectResult can run.
      markPendingRedirect()
      await firebase.oauthProvider.signIn(config, event)
    } catch (error) {
      console.error(`${config.label} sign in error:`, error)
      clearPendingRedirect()
      this.showError(error.message)
      this.showLoading(false)
    }
  }
```

- [ ] **Step 5: Run the lint test to verify it passes**

Run: `cd web-app && bin/rails test test/lint/auth_provider_registry_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 6: Confirm the existing refused-identity guard still holds**

`test/lint/refused_identity_ui_state_test.rb` and `test/lint/stimulus_manifest_test.rb` both read this controller.

Run: `cd web-app && bin/rails test test/lint`
Expected: 0 failures.

- [ ] **Step 7: Build and commit**

```bash
cd web-app && yarn build
git add web-app/app/javascript/controllers/authentication_controller.js web-app/test/lint/auth_provider_registry_test.rb
git commit -m "refactor(auth): one Stimulus action for every OAuth provider"
```

---

### Task 8: Render the buttons from the registry

**Files:**
- Modify: `web-app/app/components/authentication/widget_component.rb`
- Modify: `web-app/app/components/authentication/widget_component/widget_component.html.erb`
- Create: `web-app/app/views/shared/auth_icons/_google.html.erb`
- Create: `web-app/app/views/shared/auth_icons/_twitter.html.erb`
- Create: `web-app/app/views/shared/auth_icons/_facebook.html.erb`
- Create: `web-app/app/views/shared/auth_icons/_apple.html.erb`
- Test: `web-app/test/components/authentication/widget_component_test.rb` (exists; **replace** its three tests)

**Interfaces:**
- Consumes: `Services::AuthProviderRegistry.enabled_for_view` from Task 1; the `providers` Stimulus value and `signInWithOauth` action from Task 7.
- Produces: `Authentication::WidgetComponent#oauth_providers` → the array from `enabled_for_view`. Rendered markup gains one `button[data-authentication-provider-param]` per enabled provider.

An icon partial exists for **every** registry provider, enabled or not, so turning one on is genuinely a one-word change.

- [ ] **Step 1: Write the failing test**

`web-app/test/components/authentication/widget_component_test.rb` already exists and holds
three tests that cannot fail:

```ruby
  assert_not_empty result.text.strip
  assert_includes result.to_html, "<"
  assert_includes result.to_html, ">"
```

Every one of those passes against a component that renders a single stray character.
**Replace the file's entire contents** — do not append, or the vacuous assertions stay and
keep reporting green while the widget is broken.

Replace `web-app/test/components/authentication/widget_component_test.rb` with:

```ruby
# frozen_string_literal: true

require "test_helper"

class Authentication::WidgetComponentTest < ViewComponent::TestCase
  test "renders without raising" do
    assert_nothing_raised { render_inline(Authentication::WidgetComponent.new) }
  end

  test "still renders the email form alongside the OAuth buttons" do
    render_inline(Authentication::WidgetComponent.new)

    # The OAuth loop replaced markup that sat directly above this. If the loop
    # ever swallowed the email step, every assertion below would still pass.
    assert_selector "[data-authentication-target='emailStep'] input[type='email']"
    assert_selector "[data-authentication-target='passwordStep']", visible: :all
  end

  test "renders a button for every enabled provider" do
    render_inline(Authentication::WidgetComponent.new)

    Services::AuthProviderRegistry.enabled_for_view.each do |provider|
      selector = "button[data-authentication-provider-param='#{provider[:id]}']"
      assert_selector selector, count: 1,
        "expected exactly one #{provider[:id]} button"
    end
  end

  test "does not render a button for a disabled provider" do
    render_inline(Authentication::WidgetComponent.new)

    assert_no_selector "button[data-authentication-provider-param='facebook']",
      "Facebook ships disabled -- the Meta app is restricted to development mode"
    assert_no_selector "button[data-authentication-provider-param='apple']"
  end

  test "each button carries the generic action and the registry label" do
    render_inline(Authentication::WidgetComponent.new)

    button = page.find("button[data-authentication-provider-param='twitter']")

    assert_includes button["data-action"], "authentication#signInWithOauth"
    # Substring matching is Capybara's default and would pass on "Sign in with
    # Xylophone", so anchor the whole string.
    assert_equal "Sign in with X", button.text.strip
  end

  test "the enabled registry reaches the client as a Stimulus value" do
    render_inline(Authentication::WidgetComponent.new)

    raw = page.find("[data-controller='authentication']")["data-authentication-providers-value"]
    parsed = JSON.parse(raw)

    assert_equal %w[google twitter], parsed.map { |p| p["id"] }
    assert_equal "twitter.com", parsed.last["firebase_id"]
    assert_equal [], parsed.last["scopes"], "the client needs the scope list to build the provider"
  end

  test "every registry provider has an icon partial, enabled or not" do
    Services::AuthProviderRegistry.provider_names.each do |id|
      path = Rails.root.join("app/views/shared/auth_icons/_#{id}.html.erb")
      assert File.exist?(path),
        "#{id} is in the registry but has no icon partial at #{path}. " \
        "Enabling it would then be more than a one-word change."
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd web-app && bin/rails test test/components/authentication/widget_component_test.rb`
Expected: FAIL — no button carries `data-authentication-provider-param`.

- [ ] **Step 3: Create the icon partials**

Create `web-app/app/views/shared/auth_icons/_google.html.erb`:

```erb
<svg class="w-5 h-5" viewBox="0 0 24 24" aria-hidden="true">
  <path fill="currentColor" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
  <path fill="currentColor" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
  <path fill="currentColor" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
  <path fill="currentColor" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
</svg>
```

Create `web-app/app/views/shared/auth_icons/_twitter.html.erb`:

```erb
<svg class="w-5 h-5" viewBox="0 0 24 24" aria-hidden="true">
  <path fill="currentColor" d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
</svg>
```

Create `web-app/app/views/shared/auth_icons/_facebook.html.erb`:

```erb
<svg class="w-5 h-5" viewBox="0 0 24 24" aria-hidden="true">
  <path fill="currentColor" d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z"/>
</svg>
```

Create `web-app/app/views/shared/auth_icons/_apple.html.erb`:

```erb
<svg class="w-5 h-5" viewBox="0 0 24 24" aria-hidden="true">
  <path fill="currentColor" d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z"/>
</svg>
```

- [ ] **Step 4: Expose the registry from the component**

In `web-app/app/components/authentication/widget_component.rb`, add these two private methods after `reload_after_auth_data`:

```ruby
  def oauth_providers
    @oauth_providers ||= Services::AuthProviderRegistry.enabled_for_view
  end

  # The client needs firebase_id and scopes to construct the provider; the id
  # is what the action param carries back. Serialised whole rather than
  # per-button so the controller can resolve an unknown id to a real error
  # instead of an unhandled rejection.
  def oauth_providers_json
    oauth_providers.to_json
  end
```

- [ ] **Step 5: Render the buttons from the registry**

In `web-app/app/components/authentication/widget_component/widget_component.html.erb`, add the providers value to the root element. Change:

```erb
     data-authentication-firebase-src-value="<%= asset_path("firebase-auth.js") %>"
```

to:

```erb
     data-authentication-firebase-src-value="<%= asset_path("firebase-auth.js") %>"
     data-authentication-providers-value="<%= oauth_providers_json %>"
```

Then replace the entire hardcoded Google block — from `<!-- Google Sign In -->` through the `</div>` that closes `<div class="mb-4">` — with:

```erb
      <!-- OAuth providers, from config/auth_providers.json -->
      <% oauth_providers.each do |provider| %>
        <div class="mb-3">
          <button data-action="click->authentication#signInWithOauth"
                  data-authentication-provider-param="<%= provider[:id] %>"
                  class="btn btn-outline btn-primary w-full flex items-center justify-center gap-2">
            <%= render "shared/auth_icons/#{provider[:id]}" %>
            Sign in with <%= provider[:label] %>
          </button>
        </div>
      <% end %>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd web-app && bin/rails test test/components/authentication/widget_component_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 7: Confirm the daisyUI guard still passes**

Run: `cd web-app && bin/rails test test/lint/daisyui_v4_classes_test.rb`
Expected: 0 failures. If it fails, remove the offending class — never add an allowlist entry.

- [ ] **Step 8: Run the whole suite**

Run: `cd web-app && bin/rails test`
Expected: 0 failures, and no new warning lines beyond the two known upstream sources (`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`).

- [ ] **Step 9: Lint, build and commit**

```bash
cd web-app && bundle exec standardrb app/components test/components && yarn build:all
git add web-app/app/components/authentication web-app/app/views/shared/auth_icons web-app/test/components/authentication
git commit -m "feat(auth): render OAuth buttons from the provider registry"
```

---

### Task 9: Playwright coverage for the OAuth buttons

**Files:**
- Create: `web-app/e2e/tests/books/oauth-providers.spec.ts`

**Interfaces:**
- Consumes: the rendered widget from Task 8.
- Produces: no code interface.

**Why this file lives under `tests/books/`:** the `books` Playwright project is the only one with no auth setup and no `storageState`, so it starts anonymous — which is what a login test needs. The other hostnames are exercised from the same file with a `test.use` override, the pattern `e2e/tests/books/email-auth.spec.ts` already uses.

**Why it stops at the redirect:** a full X round trip cannot be automated past bot detection and 2FA. But `signInWithRedirect` navigates to `<authDomain>/__/auth/handler?…providerId=twitter.com` *before* reaching X, so asserting that navigation proves the config reached the button, the registry built the right Firebase provider, and Firebase accepted it.

- [ ] **Step 1: Confirm port 3000 is yours**

Caddy proxies every dev hostname to `localhost:3000` regardless of which worktree is listening. If another worktree holds it, this run tests THAT code and reports the result as yours.

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

Expected: `port 3000 is free`, or this worktree's path. **If it prints another checkout, stop and tell Shane.** Do not kill their server and do not run on another port — routes are host-constrained, so `localhost:<port>` 404s everywhere.

- [ ] **Step 2: Write the spec**

Create `web-app/e2e/tests/books/oauth-providers.spec.ts`:

```ts
import { test, expect, Page } from '@playwright/test';

// The widget is shared by every domain layout, so each hostname gets the same
// checks. storageState is cleared explicitly: the books project starts
// anonymous already, but the override makes that a property of the test rather
// than of the project config.
const DOMAINS = [
  { name: 'books', baseURL: 'https://dev-new.thegreatestbooks.org' },
  { name: 'music', baseURL: 'https://dev.thegreatestmusic.org' },
  { name: 'games', baseURL: 'https://dev.thegreatest.games' },
];

// Mirrors the enabled entries in web-app/config/auth_providers.json.
// test/components/.../widget_component_test.rb pins the rendered markup to that
// file; this pins what a real browser gets.
const ENABLED = [
  { id: 'google', label: 'Google', firebaseId: 'google.com' },
  { id: 'twitter', label: 'X', firebaseId: 'twitter.com' },
];

const DISABLED = ['facebook', 'apple'];

async function openLoginModal(page: Page) {
  await page.goto('/');
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page.locator('#login_modal')).toBeVisible();
}

for (const domain of DOMAINS) {
  test.describe(`OAuth provider buttons on ${domain.name}`, () => {
    test.use({ baseURL: domain.baseURL, storageState: { cookies: [], origins: [] } });

    test('renders exactly the enabled providers', async ({ page }) => {
      await openLoginModal(page);
      const modal = page.locator('#login_modal');

      for (const provider of ENABLED) {
        const button = modal.locator(`button[data-authentication-provider-param="${provider.id}"]`);
        await expect(button).toBeVisible();
        // Exact, not substring: Capybara-style containment would pass on
        // "Sign in with Xylophone".
        await expect(button).toHaveText(`Sign in with ${provider.label}`);
      }

      for (const id of DISABLED) {
        await expect(
          modal.locator(`button[data-authentication-provider-param="${id}"]`)
        ).toHaveCount(0);
      }
    });

    test('clicking X starts the Firebase redirect with the right providerId', async ({ page }) => {
      await openLoginModal(page);

      await page
        .locator('#login_modal button[data-authentication-provider-param="twitter"]')
        .click();

      // signInWithRedirect goes to the Firebase auth handler on THIS host
      // (nginx and Caddy proxy /__/auth* to the-greatest-books.firebaseapp.com)
      // before it ever reaches X. Waiting on that URL keeps the test off X's
      // bot detection while still proving the whole client path.
      await page.waitForURL(/\/__\/auth\/handler\?.*providerId=twitter\.com/, {
        timeout: 20000,
      });

      expect(page.url()).toContain('providerId=twitter.com');
    });

    test('an unknown provider id does not silently do nothing', async ({ page }) => {
      await openLoginModal(page);

      const errors: string[] = [];
      page.on('console', (msg) => {
        if (msg.type() === 'error') errors.push(msg.text());
      });

      // Rewrite a real button's param to an id the registry does not carry,
      // which is what stale Turbo-cached markup would look like after a
      // provider is removed from the config.
      await page.locator('#login_modal button[data-authentication-provider-param="google"]')
        .evaluate((el) => el.setAttribute('data-authentication-provider-param', 'nope'));

      await page.locator('#login_modal button[data-authentication-provider-param="nope"]').click();

      await expect(
        page.locator('#login_modal [data-authentication-target="errorMessage"]')
      ).toBeVisible();
      expect(errors.some((e) => e.includes('Unknown auth provider'))).toBe(true);
    });
  });
}
```

- [ ] **Step 3: Build assets and boot the server**

`bin/dev` needs a TTY and starts Sidekiq and file watchers that are not wanted here.

```bash
cd web-app && yarn build:all && bin/rails server
```

Leave it running in a second shell.

- [ ] **Step 4: Run the spec to verify it passes**

Run: `cd web-app && npx playwright test e2e/tests/books/oauth-providers.spec.ts --config=e2e/playwright.config.ts`
Expected: 9 passed (3 tests × 3 domains).

If Playwright reports missing browsers, run `npx playwright install` first.

- [ ] **Step 5: Mutation-check the redirect assertion**

Temporarily change `providerId=twitter\.com` to `providerId=google\.com` in the spec and confirm the X test fails. Restore it and re-run to green. Without this the regex could be matching nothing and timing out into a pass on a lenient matcher.

- [ ] **Step 6: Commit**

```bash
git add web-app/e2e/tests/books/oauth-providers.spec.ts
git commit -m "test(e2e): cover the OAuth provider buttons on every domain"
```

---

### Task 10: Measure the real X `email_verified` claim, then document

**Files:**
- Modify: `docs/superpowers/specs/2026-09-05-oauth-provider-registry-design.md` (record the measurement)
- Create: `docs/features/oauth-providers.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code interface.

**This is the one thing the database cannot answer.** `users.email_verified` reads `false` for 14,081 of 14,096 Google users because pre-hardening code read `email_verified` from a blob the client sent as `emailVerified`. So it discriminates nothing, and the X claim has to be observed.

- [ ] **Step 1: Sign in with X on dev**

With the server from Task 9 still running, open `https://dev-new.thegreatestbooks.org`, click Login, and complete a real X sign-in.

- [ ] **Step 2: Read the claim that actually arrived**

```bash
cd web-app && bin/rails runner 'u = User.where(external_provider: :twitter).order(updated_at: :desc).first; pd = u.provider_data; puts({id: u.id, email: u.email, column_verified: u.email_verified, token_claim: pd.is_a?(Hash) ? pd.dig("twitter", "email_verified") : pd, trusted: pd.is_a?(Hash) ? pd.dig("twitter", "email_trusted") : nil}.inspect)'
```

Expected: a row whose `provider_data` is keyed by the string `"twitter"` (the hardened format — integer keys like `"1"` mean the row predates PR #288 and is not your sign-in).

- [ ] **Step 3: Record the result in the spec**

In `docs/superpowers/specs/2026-09-05-oauth-provider-registry-design.md`, under decision **D6**, append one of these two paragraphs verbatim — whichever matches what Step 2 printed — with today's date substituted.

If `token_claim` printed `false`:

```markdown
**Measured <today's date>:** a real X sign-in on `dev-new.thegreatestbooks.org` produced
`email_verified: false` in the token, for an address X had confirmed. F1 is confirmed
empirically: `TRUSTED_EMAIL_PROVIDERS` is **load-bearing** for X, and without it every
returning X user with an existing account would hit a verification wall.
```

If `token_claim` printed `true`:

```markdown
**Measured <today's date>:** a real X sign-in on `dev-new.thegreatestbooks.org` produced
`email_verified: true` in the token. `TRUSTED_EMAIL_PROVIDERS` is therefore
**belt-and-braces** for X rather than load-bearing. It stays: Firebase's flag for X is not
contractual, and F1's reasoning does not depend on any single observation.
```

Then delete D6's instruction to measure, since it is now done.

- [ ] **Step 4: Write the feature doc**

Create `docs/features/oauth-providers.md`:

```markdown
# OAuth providers

Social sign-in is driven by one file: `web-app/config/auth_providers.json`.

## Adding a provider

1. Add an entry: `id`, `firebase_id`, `label`, `scopes`, `enabled`.
2. Add `web-app/app/views/shared/auth_icons/_<id>.html.erb`.
3. If Firebase special-cases it, add it to `PROVIDER_CLASSES` in
   `app/javascript/services/auth_providers/oauth_provider.js`. Providers Firebase
   constructs by id (Apple) need no entry — `OAuthProvider` is the fallback.
4. If it requires email ownership at signup, add its `firebase_id` to
   `Services::AuthenticationService::TRUSTED_EMAIL_PROVIDERS`.

`test/lint/auth_provider_registry_test.rb` fails if 1 and 3 disagree;
`test/components/authentication/widget_component_test.rb` fails if 2 is missing.

## `enabled` gates the button, nothing else

A disabled provider can still authenticate. One Firebase project serves the legacy
site as well, so its tokens validate against `/auth/sign_in` regardless of what this
app renders. That is why `PROVIDER_MAP` and `check_provider` read every entry while
the widget reads only the enabled ones.

## Trust is not configuration

`TRUSTED_EMAIL_PROVIDERS` is a hardcoded constant, deliberately not read from the
JSON: turning a button on must never widen a security decision as a side effect.

It answers "could someone register this address at this provider without controlling
it?", not "did the token say verified". X verifies addresses by confirmation mail but
sends no flag, so gating on the flag would send every returning X user to a
verification wall. `password` is excluded permanently — a Firebase password account
can be created for any address without proof, which is the account-takeover route
`UnverifiedEmailConflict` exists to block.

## Facebook is off

The Meta app is disabled by Meta and runs in development mode only, so only accounts
holding a role on the app can sign in. A replacement app is separate work; note that
it will issue fresh app-scoped ids, so `users.external_provider_uid` will not match
for Facebook. X ids are global and unaffected.

## Email-less accounts

X supplies no email for a minority of sign-ins, and 20,063 legacy rows have none.
Those accounts are valid (`User#external_oauth_account?` relaxes the presence rule)
but cannot be linked across providers. A later sign-in that does supply an address
fills the blank — `UserAuthenticationService#update_existing` never overwrites one.
```

- [ ] **Step 5: Full verification**

```bash
cd web-app && bin/rails test && bundle exec standardrb && yarn build:all
```

Expected: 0 failures, no standardrb offenses, clean build.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-05-oauth-provider-registry-design.md docs/features/oauth-providers.md
git commit -m "docs: record the measured X email_verified claim and document the registry"
```

---

## Notes for the reviewer

**What would make this plan wrong.** Task 3 is the one with real blast radius: it changes the condition under which two identities are treated as the same person, on live music and games. The mutation check in Task 3 Step 7 is not optional — a guard whose test passes with the old condition restored is not testing anything.

**What is deliberately not here.** Legacy identity recovery: the `legacy_v1_data` email backfill (12,719 recoverable addresses), uid-based claiming, and the 404 rows whose recovered address already belongs to another account. It is a merge problem, it is independent of this work, and it gets its own spec.

**Do not enable Facebook** to "test the registry end to end". The Meta app is disabled; the only account that can sign in is Shane's, and turning the button on would show a broken control to every visitor on live music and games.
