# Firebase Account Lookup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve a trustworthy email from Firebase's provider record when an OAuth ID token carries no `email` claim, so Facebook (and email-less X/Apple) sign-ins link to the right account instead of creating a duplicate.

**Architecture:** Three new service objects — a cached service-account token minter, an Identity Toolkit `accounts:lookup` client, and a resolver implementing the provider-entry rule. The resolver is injected into `UserAuthenticationService` and invoked **lazily**, so the network call happens only when the `auth_uid` match misses and an email actually decides something.

**Tech Stack:** Ruby 4.0.6, Rails 8.1, Faraday, `jwt` 3.2.0 (already in the Gemfile), Minitest + Mocha.

**Spec:** `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`

## Global Constraints

- Run all commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Services live in `app/lib/services/`, **not** `app/services/`.
- Lint is `bundle exec standardrb`, never `bin/rubocop`. Do not run brakeman.
- Minitest is 6.x: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Stub all external APIs with Mocha. No test may make a real HTTP request.
- Secrets are ENV vars managed via SOPS, never `Rails.application.credentials`.
- `TRUSTED_EMAIL_PROVIDERS` is unchanged by this plan and `password` stays absent from it (spec D7).
- Faraday open and read timeouts are **3 seconds each**, set explicitly (spec D2).
- A failed lookup **refuses the sign-in**. It never falls back to client-supplied data and never proceeds on a guessed address (spec D2).
- `extract_provider_data` stays a pure function of the payload (spec D4).
- A clean `bin/rails test` emits no new warnings. A new warning line is a regression.

## A correction to the spec's test list, found while tracing call paths

The spec's test bullet says *"uid hit performs zero lookups."* That is true only for a uid-matched row that **already has an email**.

`update_existing` contains:

```ruby
email: user.email.presence || (email_trusted? ? fillable_email(user) : nil),
```

Ruby short-circuits `||`, so `fillable_email` — which reads `email` — is never reached when the row already has one. But a uid-matched row with a **blank** email does reach it, and that is the opportunistic email-fill path for email-less OAuth rows.

That is correct and desirable: the fill is exactly where a trustworthy address matters most, and it is how an email-less X or Facebook row ever becomes linkable. The plan therefore specifies two tests instead of one, and the precise property is:

> **A uid hit on a row that already has an email performs zero lookups. A uid hit on a blank-email row performs exactly one, and fills the blank.**

---

## File Structure

| File | Responsibility |
|---|---|
| `app/lib/services/google_service_account_token.rb` | Mint + cache the OAuth bearer token (new) |
| `app/lib/services/firebase_account_lookup.rb` | POST `accounts:lookup`, return `providerUserInfo` (new) |
| `app/lib/services/provider_email_resolver.rb` | Spec D3's resolution rule (new) |
| `app/lib/services/user_authentication_service.rb` | `email` becomes lazily resolved (modify) |
| `app/lib/services/authentication_service.rb` | Build the resolver, map the failure (modify) |
| `deployment/ENV.md` | Document `FIREBASE_SERVICE_ACCOUNT_KEY` (modify) |
| `docs/features/oauth-providers.md` | Record the new behaviour, retire the D10 pairing (modify) |

---

## Task 1: Service-account token minter

**Files:**
- Create: `web-app/app/lib/services/google_service_account_token.rb`
- Test: `web-app/test/lib/services/google_service_account_token_test.rb`
- Modify: `deployment/ENV.md` (project root, not `web-app/`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Services::GoogleServiceAccountToken.access_token` → `String`. Raises `Services::GoogleServiceAccountToken::Error` on any failure. `Services::GoogleServiceAccountToken.reset!` clears the cache (tests must call this in `setup`).

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/google_service_account_token_test.rb`:

```ruby
require "test_helper"

class GoogleServiceAccountTokenTest < ActiveSupport::TestCase
  # A throwaway RSA key. Generated per-run rather than checked in so this file
  # never looks like it contains a real credential.
  KEY = OpenSSL::PKey::RSA.generate(2048)

  def setup
    Services::GoogleServiceAccountToken.reset!
    ENV["FIREBASE_SERVICE_ACCOUNT_KEY"] = Base64.strict_encode64(
      JSON.generate(client_email: "svc@example.iam.gserviceaccount.com", private_key: KEY.to_pem)
    )
  end

  def teardown
    Services::GoogleServiceAccountToken.reset!
    ENV.delete("FIREBASE_SERVICE_ACCOUNT_KEY")
  end

  def stub_exchange(status: 200, body: {access_token: "ya29.token", expires_in: 3600})
    response = mock
    response.stubs(:status).returns(status)
    response.stubs(:body).returns(JSON.generate(body))
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)
    connection
  end

  test "returns the access token from the exchange" do
    stub_exchange

    assert_equal "ya29.token", Services::GoogleServiceAccountToken.access_token
  end

  test "a second call inside the lifetime issues no second exchange" do
    connection = stub_exchange
    connection.expects(:post).once.returns(
      stub(status: 200, body: JSON.generate(access_token: "ya29.token", expires_in: 3600))
    )

    2.times { Services::GoogleServiceAccountToken.access_token }
  end

  test "a token near expiry is refreshed" do
    stub_exchange(body: {access_token: "first", expires_in: 60})
    assert_equal "first", Services::GoogleServiceAccountToken.access_token

    stub_exchange(body: {access_token: "second", expires_in: 3600})
    assert_equal "second", Services::GoogleServiceAccountToken.access_token,
      "expires_in 60 is inside the 300s refresh buffer, so the next call must re-exchange"
  end

  test "a non-200 exchange raises rather than returning nil" do
    stub_exchange(status: 401, body: {error: "unauthorized_client"})

    error = assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
    assert_match(/401/, error.message)
  end

  test "an exchange with no access_token raises" do
    stub_exchange(body: {expires_in: 3600})

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end

  test "a missing credential raises a named error rather than a NoMethodError" do
    ENV.delete("FIREBASE_SERVICE_ACCOUNT_KEY")

    error = assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
    assert_match(/FIREBASE_SERVICE_ACCOUNT_KEY/, error.message)
  end

  test "a credential that is not base64 JSON raises a named error" do
    ENV["FIREBASE_SERVICE_ACCOUNT_KEY"] = Base64.strict_encode64("not json")

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end

  test "a timeout raises the service's own error, not Faraday's" do
    connection = mock
    connection.stubs(:post).raises(Faraday::TimeoutError)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/google_service_account_token_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::GoogleServiceAccountToken`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/google_service_account_token.rb`:

```ruby
# frozen_string_literal: true

require "base64"
require "faraday"
require "json"
require "jwt"
require "monitor"
require "openssl"

module Services
  # Mints and caches the OAuth bearer token used to call Identity Toolkit as
  # this project's service account.
  #
  # In-process rather than Rails.cache for the same reason
  # JwtValidationService caches certs in-process: production configures no
  # cache_store, so Rails.cache is a per-container file store anyway.
  class GoogleServiceAccountToken
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    SCOPE = "https://www.googleapis.com/auth/identitytoolkit"
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    ASSERTION_LIFETIME = 3600
    # Refresh this far before expiry so a token never expires mid-request.
    REFRESH_BUFFER = 300
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    class Error < StandardError; end

    LOCK = Monitor.new

    class << self
      def access_token
        LOCK.synchronize do
          refresh! if expired?
          @access_token
        end
      end

      def reset!
        LOCK.synchronize do
          @access_token = nil
          @expires_at = nil
        end
      end

      private

      def expired?
        @access_token.nil? || @expires_at.nil? ||
          Time.current >= (@expires_at - REFRESH_BUFFER)
      end

      def refresh!
        response = post_assertion(build_assertion)

        unless response.status == 200
          raise Error, "token exchange failed (#{response.status})"
        end

        data = JSON.parse(response.body)
        token = data["access_token"]
        raise Error, "token exchange returned no access_token" if token.blank?

        @access_token = token
        @expires_at = Time.current + data["expires_in"].to_i
      rescue JSON::ParserError => e
        raise Error, "token exchange returned an unparseable body: #{e.message}"
      rescue Faraday::Error => e
        raise Error, "token exchange request failed: #{e.class}"
      end

      def credentials
        raw = ENV["FIREBASE_SERVICE_ACCOUNT_KEY"]
        raise Error, "FIREBASE_SERVICE_ACCOUNT_KEY is not set" if raw.blank?

        JSON.parse(Base64.decode64(raw))
      rescue JSON::ParserError
        raise Error, "FIREBASE_SERVICE_ACCOUNT_KEY is not valid base64-encoded JSON"
      end

      def build_assertion
        creds = credentials
        now = Time.current.to_i

        JWT.encode(
          {
            iss: creds.fetch("client_email"),
            scope: SCOPE,
            aud: TOKEN_URL,
            iat: now,
            exp: now + ASSERTION_LIFETIME
          },
          OpenSSL::PKey::RSA.new(creds.fetch("private_key")),
          "RS256"
        )
      rescue KeyError => e
        raise Error, "service account key is missing #{e.key}"
      rescue OpenSSL::PKey::RSAError
        raise Error, "service account private_key is not a usable RSA key"
      end

      def post_assertion(assertion)
        connection = Faraday.new(url: TOKEN_URL) do |conn|
          conn.options.open_timeout = OPEN_TIMEOUT
          conn.options.timeout = READ_TIMEOUT
          conn.adapter Faraday.default_adapter
        end

        connection.post("") do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body = URI.encode_www_form(grant_type: GRANT_TYPE, assertion: assertion)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/google_service_account_token_test.rb`
Expected: PASS, 8 runs, 0 failures

- [ ] **Step 5: Document the ENV var**

In `deployment/ENV.md`, in the Firebase section (immediately after the `FIREBASE_API_KEY` entry), add:

```markdown
#### FIREBASE_SERVICE_ACCOUNT_KEY
- **Description**: Base64-encoded JSON key for a GCP service account with the
  `firebaseauth.users.get` permission on the `the-greatest-books` project.
  Used to call Identity Toolkit `accounts:lookup` and read the email Firebase
  keeps on an account's provider record but does not put in the ID token.
- **Required**: Yes. Without it, any sign-in whose `auth_uid` does not already
  match a user is refused — that is new sign-ups and anyone adding a provider.
- **Format**: `base64 -w0 service-account.json`
- **Used By**: web
- **Security**: A real credential, unlike `FIREBASE_API_KEY`. Never commit it;
  manage via SOPS — see `deployment/SECRETS.md`.
```

- [ ] **Step 6: Run lint and commit**

```bash
bundle exec standardrb
git add web-app/app/lib/services/google_service_account_token.rb \
        web-app/test/lib/services/google_service_account_token_test.rb \
        deployment/ENV.md
git commit -m "feat(auth): mint and cache a Google service-account token"
```

---

## Task 2: Identity Toolkit account lookup

**Files:**
- Create: `web-app/app/lib/services/firebase_account_lookup.rb`
- Test: `web-app/test/lib/services/firebase_account_lookup_test.rb`

**Interfaces:**
- Consumes: `Services::GoogleServiceAccountToken.access_token`.
- Produces: `Services::FirebaseAccountLookup.call(uid, project_id:)` → `Array<Hash>` of `providerUserInfo` entries (each with string keys `"providerId"`, `"rawId"`, `"email"`, …). Returns `[]` when the account has none. Raises `Services::FirebaseAccountLookup::Error` on any failure.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/firebase_account_lookup_test.rb`:

```ruby
require "test_helper"

class FirebaseAccountLookupTest < ActiveSupport::TestCase
  PROJECT = "the-greatest-books"

  def setup
    Services::GoogleServiceAccountToken.stubs(:access_token).returns("ya29.token")
  end

  def stub_lookup(status: 200, body: nil)
    body ||= {
      users: [{
        localId: "skDlsJ347BRgwmZNMfJ28465YU23",
        providerUserInfo: [
          {providerId: "facebook.com", rawId: "10166754100896840", email: "shane@example.com"}
        ]
      }]
    }
    response = mock
    response.stubs(:status).returns(status)
    response.stubs(:body).returns(JSON.generate(body))
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)
    connection
  end

  test "returns the provider entries for the account" do
    stub_lookup

    entries = Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)

    assert_equal 1, entries.size
    assert_equal "facebook.com", entries.first["providerId"]
    assert_equal "shane@example.com", entries.first["email"]
  end

  test "posts the uid as localId to the project's lookup endpoint with a bearer token" do
    response = stub(status: 200, body: JSON.generate(users: [{providerUserInfo: []}]))
    request = mock
    headers = {}
    request.stubs(:headers).returns(headers)
    request.expects(:body=).with(JSON.generate(localId: ["uid_1"]))
    connection = mock
    connection.expects(:post).with("/v1/projects/#{PROJECT}/accounts:lookup").yields(request).returns(response)
    Faraday.stubs(:new).returns(connection)

    Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)

    assert_equal "Bearer ya29.token", headers["Authorization"]
  end

  test "an account with no provider entries returns an empty array, not nil" do
    stub_lookup(body: {users: [{localId: "uid_1"}]})

    assert_equal [], Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
  end

  test "an unknown account returns an empty array" do
    stub_lookup(body: {})

    assert_equal [], Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
  end

  test "a non-200 raises" do
    stub_lookup(status: 403, body: {error: {message: "PERMISSION_DENIED"}})

    error = assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
    assert_match(/403/, error.message)
  end

  test "an unparseable body raises" do
    response = mock
    response.stubs(:status).returns(200)
    response.stubs(:body).returns("<html>gateway error</html>")
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
  end

  test "a timeout raises the service's own error, not Faraday's" do
    connection = mock
    connection.stubs(:post).raises(Faraday::TimeoutError)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
  end

  test "a blank uid raises without making a request" do
    Faraday.expects(:new).never

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("", project_id: PROJECT)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/firebase_account_lookup_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::FirebaseAccountLookup`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/firebase_account_lookup.rb`:

```ruby
# frozen_string_literal: true

require "faraday"
require "json"

module Services
  # Reads an account's provider records from Identity Toolkit.
  #
  # Firebase keeps a provider-supplied email on the PROVIDER record and, under
  # this project's "allow multiple accounts with the same email address"
  # setting, does not promote it to the ACCOUNT record -- which is what mints
  # ID tokens. So the address exists, and the token does not carry it. Google's
  # own guidance for that setting is to retrieve it from the identity provider
  # yourself; this is that.
  #
  # Unlike the copy the browser sends, what comes back here is server-to-server
  # from Google and is not attacker-controlled.
  class FirebaseAccountLookup
    BASE_URL = "https://identitytoolkit.googleapis.com"
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 3

    class Error < StandardError; end

    def self.call(uid, project_id:)
      new(uid, project_id).call
    end

    def initialize(uid, project_id)
      @uid = uid
      @project_id = project_id
    end

    def call
      raise Error, "uid is required" if @uid.blank?
      raise Error, "project_id is required" if @project_id.blank?

      response = post_lookup

      unless response.status == 200
        raise Error, "accounts:lookup failed (#{response.status})"
      end

      account = Array(JSON.parse(response.body)["users"]).first
      Array(account && account["providerUserInfo"])
    rescue JSON::ParserError => e
      raise Error, "accounts:lookup returned an unparseable body: #{e.message}"
    rescue Faraday::Error => e
      raise Error, "accounts:lookup request failed: #{e.class}"
    end

    private

    def post_lookup
      connection = Faraday.new(url: BASE_URL) do |conn|
        conn.options.open_timeout = OPEN_TIMEOUT
        conn.options.timeout = READ_TIMEOUT
        conn.adapter Faraday.default_adapter
      end

      connection.post("/v1/projects/#{@project_id}/accounts:lookup") do |req|
        req.headers["Authorization"] = "Bearer #{GoogleServiceAccountToken.access_token}"
        req.headers["Content-Type"] = "application/json"
        req.body = JSON.generate(localId: [@uid])
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/firebase_account_lookup_test.rb`
Expected: PASS, 8 runs, 0 failures

- [ ] **Step 5: Run lint and commit**

```bash
bundle exec standardrb
git add web-app/app/lib/services/firebase_account_lookup.rb \
        web-app/test/lib/services/firebase_account_lookup_test.rb
git commit -m "feat(auth): read an account's provider records from Identity Toolkit"
```

---

## Task 3: Provider email resolver

**Files:**
- Create: `web-app/app/lib/services/provider_email_resolver.rb`
- Test: `web-app/test/lib/services/provider_email_resolver_test.rb`

**Interfaces:**
- Consumes: `Services::FirebaseAccountLookup.call(uid, project_id:)`.
- Produces: `Services::ProviderEmailResolver.new(uid:, sign_in_provider:, project_id:, fallback_email: nil)` responding to `#call` → `String` or `nil`. Propagates `FirebaseAccountLookup::Error` and `GoogleServiceAccountToken::Error` — it must NOT swallow them, because spec D2 requires the sign-in to be refused.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lib/services/provider_email_resolver_test.rb`:

```ruby
require "test_helper"

class ProviderEmailResolverTest < ActiveSupport::TestCase
  PROJECT = "the-greatest-books"

  def resolver(sign_in_provider: "facebook.com", fallback_email: nil)
    Services::ProviderEmailResolver.new(
      uid: "uid_1",
      sign_in_provider: sign_in_provider,
      project_id: PROJECT,
      fallback_email: fallback_email
    )
  end

  test "returns the email from the entry matching the sign-in provider" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "google.com", "email" => "wrong@example.com"},
      {"providerId" => "facebook.com", "email" => "right@example.com"}
    ])

    assert_equal "right@example.com", resolver.call
  end

  test "falls back to the token claim when the provider entry has no email" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "facebook.com", "rawId" => "10166754100896840"}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "falls back to the token claim when no entry matches the provider" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "google.com", "email" => "other@example.com"}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "returns nil when neither the provider entry nor the token has an email" do
    Services::FirebaseAccountLookup.stubs(:call).returns([])

    assert_nil resolver.call
  end

  test "an entry with a blank email falls back rather than returning the blank" do
    Services::FirebaseAccountLookup.stubs(:call).returns([
      {"providerId" => "facebook.com", "email" => ""}
    ])

    assert_equal "claim@example.com", resolver(fallback_email: "claim@example.com").call
  end

  test "a lookup failure propagates rather than degrading to the token claim" do
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    # Spec D2: without the email we cannot tell a new user from an existing one
    # adding a provider, so the sign-in must be refused rather than guessing.
    # Silently returning fallback_email here would reintroduce exactly the
    # duplicate-account outcome this design exists to prevent.
    assert_raises(Services::FirebaseAccountLookup::Error) do
      resolver(fallback_email: "claim@example.com").call
    end
  end

  test "a token minting failure propagates too" do
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::GoogleServiceAccountToken::Error, "boom")

    assert_raises(Services::GoogleServiceAccountToken::Error) { resolver.call }
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/lib/services/provider_email_resolver_test.rb`
Expected: FAIL — `NameError: uninitialized constant Services::ProviderEmailResolver`

- [ ] **Step 3: Write the implementation**

Create `web-app/app/lib/services/provider_email_resolver.rb`:

```ruby
# frozen_string_literal: true

module Services
  # Resolves the address an account-linking decision should use.
  #
  # Prefers the identity provider's own assertion over the token's `email`
  # claim, and that ordering is the security property, not an optimisation.
  # The claim is the Firebase ACCOUNT RECORD's email, which its holder can
  # repoint via Identity Toolkit accounts:update while sign_in_provider stays
  # put -- the account-takeover route found in PR #300's final review. The
  # provider record holds what the provider vouched for and is not writable by
  # the account holder.
  #
  # Errors propagate on purpose. See the failure test in
  # test/lib/services/provider_email_resolver_test.rb.
  class ProviderEmailResolver
    def initialize(uid:, sign_in_provider:, project_id:, fallback_email: nil)
      @uid = uid
      @sign_in_provider = sign_in_provider
      @project_id = project_id
      @fallback_email = fallback_email
    end

    def call
      entry = provider_entry
      provider_email = entry && entry["email"].presence

      provider_email || @fallback_email.presence
    end

    private

    def provider_entry
      entries = FirebaseAccountLookup.call(@uid, project_id: @project_id)
      entries.find { |e| e["providerId"] == @sign_in_provider }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/lib/services/provider_email_resolver_test.rb`
Expected: PASS, 7 runs, 0 failures

- [ ] **Step 5: Mutation check on the propagation guard**

Temporarily change `provider_entry` to swallow the error:

```ruby
    def provider_entry
      entries = FirebaseAccountLookup.call(@uid, project_id: @project_id)
      entries.find { |e| e["providerId"] == @sign_in_provider }
    rescue FirebaseAccountLookup::Error
      nil
    end
```

Run: `bin/rails test test/lib/services/provider_email_resolver_test.rb`
Expected: FAIL on `a lookup failure propagates rather than degrading to the token claim`.
**Then revert the mutation.** Re-run and confirm PASS before continuing.

- [ ] **Step 6: Run lint and commit**

```bash
bundle exec standardrb
git add web-app/app/lib/services/provider_email_resolver.rb \
        web-app/test/lib/services/provider_email_resolver_test.rb
git commit -m "feat(auth): resolve the linking email from the provider record"
```

---

## Task 4: Lazy email resolution in UserAuthenticationService

**Files:**
- Modify: `web-app/app/lib/services/user_authentication_service.rb`
- Test: `web-app/test/lib/services/user_authentication_service_test.rb`

**Interfaces:**
- Consumes: any object responding to `#call` → `String` or `nil` (Task 3's resolver satisfies this).
- Produces: `Services::UserAuthenticationService.call(provider_data:, signup_domain: nil, email_resolver: nil)`. When `email_resolver` is nil the service reads `provider_data[:email]` exactly as before, so every existing call site and test is unaffected.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/services/user_authentication_service_test.rb`, inside the class:

```ruby
  # --- Lazy email resolution ---

  # The whole cost argument for resolving lazily: a returning user whose row
  # already has an address must not pay a network round trip.
  # password_user, not regular_user: these two need a row that already has an
  # auth_uid to match on, and regular_user's is nil -- passing that as user_id
  # raises ArgumentError before any of this is exercised.
  test "a uid match on a row that already has an email never calls the resolver" do
    existing = users(:password_user)
    assert existing.email.present?, "fixture precondition"
    resolver = mock
    resolver.expects(:call).never

    Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: existing.auth_uid, provider: "google"),
      email_resolver: resolver
    )
  end

  test "a uid match on a blank-email row resolves once and fills the blank" do
    existing = users(:password_user)
    # update_columns, not update!: :email's presence rule is only relaxed for
    # external_oauth_account?, and this row is a password account until the
    # same statement changes it.
    existing.update_columns(email: nil, external_provider: User.external_providers[:twitter])
    resolver = mock
    resolver.expects(:call).once.returns("filled@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(
        user_id: existing.auth_uid, provider: "twitter", email_trusted: true
      ),
      email_resolver: resolver
    )

    assert_equal "filled@example.com", user.reload.email
  end

  test "a uid miss resolves the email and links by it" do
    existing = users(:regular_user)
    existing.update!(email: "target@example.com")
    resolver = mock
    resolver.expects(:call).once.returns("TARGET@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(
        user_id: "brand_new_uid", email: nil, provider: "facebook", email_trusted: true
      ),
      email_resolver: resolver
    )

    assert_equal existing.id, user.id, "the resolved address must drive the link"
  end

  test "the resolver is consulted at most once per sign-in" do
    resolver = mock
    resolver.expects(:call).once.returns("new.person@example.com")

    Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: nil, provider: "facebook"),
      email_resolver: resolver
    )
  end

  test "a resolver returning nil creates a user with no email" do
    resolver = mock
    resolver.stubs(:call).returns(nil)

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: nil, provider: "facebook"),
      email_resolver: resolver
    )

    assert_nil user.email
    assert_predicate user, :persisted?
  end

  test "an untrusted provider still raises against an existing row even when resolved" do
    existing = users(:regular_user)
    existing.update!(email: "victim@example.com")
    resolver = mock
    resolver.stubs(:call).returns("victim@example.com")

    assert_raises(Services::UserAuthenticationService::UnverifiedEmailConflict) do
      Services::UserAuthenticationService.call(
        provider_data: provider_data(
          user_id: "attacker_uid", email: nil, provider: "password", email_trusted: false
        ),
        email_resolver: resolver
      )
    end
  end

  test "with no resolver the service reads provider_data[:email] as before" do
    existing = users(:regular_user)
    existing.update!(email: "legacy@example.com")

    user = Services::UserAuthenticationService.call(
      provider_data: provider_data(user_id: "brand_new_uid", email: "legacy@example.com")
    )

    assert_equal existing.id, user.id
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: FAIL — `ArgumentError: unknown keyword: :email_resolver`

- [ ] **Step 3: Write the implementation**

In `web-app/app/lib/services/user_authentication_service.rb`, replace the constructor trio:

```ruby
    def self.call(provider_data:, signup_domain: nil)
      new(provider_data, signup_domain).call
    end

    def initialize(provider_data, signup_domain = nil)
      @provider_data = provider_data
      @signup_domain = signup_domain
    end
```

with:

```ruby
    def self.call(provider_data:, signup_domain: nil, email_resolver: nil)
      new(provider_data, signup_domain, email_resolver).call
    end

    def initialize(provider_data, signup_domain = nil, email_resolver = nil)
      @provider_data = provider_data
      @signup_domain = signup_domain
      @email_resolver = email_resolver
    end
```

Add `email_resolver` to the `attr_reader` line:

```ruby
    attr_reader :provider_data, :signup_domain, :email_resolver
```

Replace the `email` definition:

```ruby
    def email = provider_data[:email].presence&.downcase
```

with:

```ruby
    # Lazily resolved, and memoised so one sign-in costs at most one lookup.
    #
    # find_user returns on the auth_uid match before reading this, so a
    # returning user whose row already has an address never triggers the
    # resolver at all -- update_existing's `user.email.presence ||` short-
    # circuits before fillable_email is reached. A uid-matched row with a
    # BLANK email does resolve, which is the point: that fill is the only way
    # an email-less OAuth row ever becomes linkable to the same human's other
    # providers.
    #
    # defined? rather than ||=, so a resolved nil is cached instead of
    # re-resolving on every call.
    def email
      return @email if defined?(@email)

      raw = email_resolver ? email_resolver.call : provider_data[:email]
      @email = raw.presence&.downcase
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: PASS, 0 failures. Existing tests must still pass unchanged — none of them pass `email_resolver`, so all take the `provider_data[:email]` path.

- [ ] **Step 5: Mutation check on the memoisation**

Temporarily change `email` to resolve every call:

```ruby
    def email
      raw = email_resolver ? email_resolver.call : provider_data[:email]
      raw.presence&.downcase
    end
```

Run: `bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: FAIL on `the resolver is consulted at most once per sign-in`.
**Then revert the mutation.** Re-run and confirm PASS.

- [ ] **Step 6: Run lint and commit**

```bash
bundle exec standardrb
git add web-app/app/lib/services/user_authentication_service.rb \
        web-app/test/lib/services/user_authentication_service_test.rb
git commit -m "feat(auth): resolve the linking email lazily, only when uid misses"
```

---

## Task 5: Wire it into AuthenticationService and refuse on failure

**Files:**
- Modify: `web-app/app/lib/services/authentication_service.rb`
- Test: `web-app/test/lib/services/authentication_service_test.rb`
- Modify: `docs/features/oauth-providers.md` (project root)

**Interfaces:**
- Consumes: `Services::ProviderEmailResolver.new(uid:, sign_in_provider:, project_id:, fallback_email:)`, `Services::FirebaseAccountLookup::Error`, `Services::GoogleServiceAccountToken::Error`.
- Produces: `AuthenticationService.call` returns `{success: false, error: "We couldn't complete sign-in. Please try again.", error_code: :account_lookup_failed}` when the lookup fails.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/lib/services/authentication_service_test.rb`, inside the class:

```ruby
  # --- Provider email resolution ---

  test "builds a resolver from the token's sub and sign_in_provider" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com", "identities" => {"facebook.com" => ["1016"]}},
      "email" => "claim@example.com"
    }
    Services::JwtValidationService.stubs(:call).returns(payload)

    Services::ProviderEmailResolver.expects(:new).with(
      uid: "uid_1",
      sign_in_provider: "facebook.com",
      project_id: "the-greatest-books",
      fallback_email: "claim@example.com"
    ).returns(stub(call: "resolved@example.com"))

    Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")
  end

  test "a lookup failure refuses the sign-in with a retriable code" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    result = Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")

    assert_equal false, result[:success]
    assert_equal :account_lookup_failed, result[:error_code],
      "must not be swallowed by the catch-all rescue into :authentication_failed"
  end

  test "a token minting failure refuses the sign-in with the same code" do
    payload = {
      "sub" => "uid_1",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::GoogleServiceAccountToken.stubs(:access_token)
      .raises(Services::GoogleServiceAccountToken::Error, "no credential")

    result = Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")

    assert_equal :account_lookup_failed, result[:error_code]
  end

  test "a refused sign-in creates no user row" do
    payload = {
      "sub" => "uid_never_seen",
      "firebase" => {"sign_in_provider" => "facebook.com"}
    }
    Services::JwtValidationService.stubs(:call).returns(payload)
    Services::FirebaseAccountLookup.stubs(:call).raises(Services::FirebaseAccountLookup::Error, "boom")

    assert_no_difference "User.count" do
      Services::AuthenticationService.call(auth_token: "t", project_id: "the-greatest-books")
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: FAIL — the resolver is never constructed, and the failure tests report `:authentication_failed` instead of `:account_lookup_failed`.

- [ ] **Step 3: Write the implementation**

In `web-app/app/lib/services/authentication_service.rb`, replace the `UserAuthenticationService.call` invocation inside `self.call`:

```ruby
      user = UserAuthenticationService.call(
        provider_data: provider_data,
        signup_domain: signup_domain
      )
```

with:

```ruby
      user = UserAuthenticationService.call(
        provider_data: provider_data,
        signup_domain: signup_domain,
        email_resolver: ProviderEmailResolver.new(
          uid: payload["sub"],
          sign_in_provider: payload.dig("firebase", "sign_in_provider"),
          project_id: project_id,
          fallback_email: payload["email"]
        )
      )
```

Then add this rescue **above** the existing `rescue ActiveRecord::RecordInvalid`, so it precedes the catch-all `rescue => e`:

```ruby
    rescue FirebaseAccountLookup::Error, GoogleServiceAccountToken::Error => e
      # Refuse rather than guess. Without the address we cannot tell a new user
      # from an existing one adding a provider, and proceeding would silently
      # create a duplicate of a real account -- permanent, and undoable only by
      # a merge. A refused sign-in is temporary and self-heals on retry.
      #
      # This clause MUST stay above the catch-all `rescue => e` below; Ruby
      # matches rescue clauses in order, and the catch-all would otherwise
      # flatten this into a generic :authentication_failed.
      Rails.logger.error "Firebase account lookup failed: #{e.class}: #{e.message}"
      {
        success: false,
        error: "We couldn't complete sign-in. Please try again.",
        error_code: :account_lookup_failed
      }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: PASS, 0 failures

- [ ] **Step 5: Mutation check on the rescue ordering**

Temporarily move the new `rescue FirebaseAccountLookup::Error, GoogleServiceAccountToken::Error` clause to **below** the catch-all `rescue => e`.

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: FAIL on both failure tests, reporting `:authentication_failed`.
**Then revert the mutation.** Re-run and confirm PASS.

- [ ] **Step 6: Update the feature doc**

In `docs/features/oauth-providers.md`, replace the third paragraph of the "Facebook runs on a replacement Meta app" section — the one beginning **"The token's `email` claim depends on the Meta app's mode."** — with:

```markdown
**Facebook tokens carry no `email` claim, and that is permanent.** It is not a Meta
setting: Firebase keeps a provider-supplied address on the provider record and, under
this project's "allow multiple accounts with the same email address" setting, does not
promote it to the account record that mints ID tokens. Measured four times on
2026-09-07, including against a published app with a revoked grant and a deleted
Firebase account. `Services::ProviderEmailResolver` fetches it server-to-server
instead; see `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`.
```

Then replace this exact paragraph (currently `docs/features/oauth-providers.md:56-60`):

```markdown
This trust model leans on one Firebase console setting: Email enumeration protection
must stay ON, because it is what stops an attacker from using `accounts:update` to
retarget their own account's email to a victim's address and get linked via this list.
See D10 in the OAuth provider registry design doc for the full attack and why the two
are a pair.
```

with:

```markdown
Linking reads the address from the account's **provider record**, not the token's
`email` claim, so an account holder cannot repoint it via `accounts:update`. That
closes the takeover in code. Email enumeration protection stays enabled as hygiene
but is no longer load-bearing — spec D8 retires the pairing that D10 of the provider
registry design required.
```

- [ ] **Step 7: Run the full gate and commit**

```bash
bin/rails test
bundle exec standardrb
yarn build:all
git add web-app/app/lib/services/authentication_service.rb \
        web-app/test/lib/services/authentication_service_test.rb \
        docs/features/oauth-providers.md
git commit -m "feat(auth): resolve Facebook's missing email from the provider record"
```

Expected: full suite green with no new warnings, standardrb clean, build clean.

---

## Task 6: Verify end to end against a real sign-in

**Files:** none — this is a manual verification gate, and its result decides whether the branch merges.

**Interfaces:**
- Consumes: everything above, plus a real `FIREBASE_SERVICE_ACCOUNT_KEY` in `web-app/.env`.

- [ ] **Step 1: Confirm the service account works before touching the app**

```bash
bin/rails runner 'puts Services::FirebaseAccountLookup.call("skDlsJ347BRgwmZNMfJ28465YU23", project_id: Rails.application.config.x.firebase_project_id).inspect'
```

Expected: an array containing a `facebook.com` entry whose `"email"` is populated. A `PERMISSION_DENIED` means the service account lacks `firebaseauth.users.get`; a missing-credential error means the ENV var is not loaded.

- [ ] **Step 2: Start the app**

Confirm port 3000 is free first — Caddy proxies every dev hostname to it regardless of which worktree is listening:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

Then `yarn build:all && bin/rails server` (not `bin/dev`, which needs a TTY).

- [ ] **Step 3: Sign in with Facebook on a dev host**

Visit `https://dev.thegreatest.games`, open the login modal, click **Sign in with Facebook**.

- [ ] **Step 4: Confirm the account linked rather than duplicating**

```bash
bin/rails runner 'u = User.where(external_provider: :facebook).order(updated_at: :desc).first; puts({id: u.id, email: u.email, uid: u.external_provider_uid, sign_ins: u.sign_in_count, created: u.created_at}.inspect)'
```

Expected: the **existing** user row for that address, with `sign_in_count` incremented — not a new row created moments ago. A brand-new row means the resolver returned nil and the linking did not happen; do not merge.

- [ ] **Step 5: Stop the server**

Kill the `bin/rails server` process and confirm port 3000 is free again, so other worktrees can run E2E.

---

## Notes for the executor

- **Do not run the Playwright suite for this work.** This path needs a real Facebook round trip, which E2E cannot reach. The existing `e2e/tests/books/oauth-providers.spec.ts` already covers the button and the redirect and needs no change.
- **Facebook is already enabled** on this branch (commit `a9fe38da`): `config/auth_providers.json`, three pinned test assertions, and the generalised Playwright redirect loop. Do not re-do that work.
- The legacy books app's `users_controller.rb` vulnerabilities are explicitly out of scope (spec, Out of scope).
- The 12,683-row `legacy_v1_data` backfill is explicitly out of scope. Until it runs, a returning legacy Facebook user still lands on a new row even with everything here working — their `users.email` is `NULL`, so there is nothing for a resolved address to match.
