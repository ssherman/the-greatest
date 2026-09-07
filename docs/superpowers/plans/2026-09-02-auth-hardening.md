# Auth Hardening Implementation Plan (PR 1 of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every account-takeover route in `/auth/sign_in` — dead audience check, client-supplied identity claims, unverified-email linking, and session fixation — with tests that forge real JWTs rather than stubbing the decoder.

**Architecture:** Identity becomes the Firebase `sub` claim from a signature-verified token. `JwtValidationService` gains a *required* `project_id` so the audience check cannot be skipped by omission, plus issuer verification and an in-process certificate cache. `AuthenticationService` stops reading `params[:user_data]` entirely and derives every claim — email, verification status, provider — from the verified payload. `UserAuthenticationService` is rewritten around uid-primary / verified-email-secondary lookup.

**Tech Stack:** Rails 8.1, ruby-jwt 3.2.0, Faraday, Minitest + Mocha + WebMock, Rails 8 native `rate_limit`.

**Spec:** `docs/superpowers/specs/2026-09-02-email-password-auth-design.md`

## Global Constraints

- Run all commands from `web-app/`. Docs live at the project root, not `web-app/docs/`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- Minitest 6: `assert_equal nil, x` is a hard failure — use `assert_nil`.
- Fixture names are semantic. The ones this plan uses: `regular_user` (user@example.com, email_verified false, no auth_uid), `password_user` (passworduser@example.com, external_provider 4, auth_uid `firebase-password-uid-123`), `google_user` (googleuser@example.com, external_provider 2, auth_uid `firebase-google-uid-456`).
- `User#external_provider` enum: facebook=0, twitter=1, google=2, apple=3, password=4.
- WebMock runs with `disable_net_connect!(allow_localhost: true)`. Every outbound HTTP call in a test must be stubbed.
- Tests run with `parallelize(workers: 10)`. Never memoise across tests in a way that leaks between them.
- A clean `bin/rails test` emits no new warnings. A new warning line is a regression.
- Never commit to `main`. This work is on `worktree-email-password-auth`.
- **Deviation from the spec, deliberate:** the spec assigned the `UserAuthenticationService` linking rule to PR 2. It is in this plan instead (Task 4), because sourcing email from the JWT does not by itself stop an attacker creating an unverified Firebase password account for a victim's address in our own project. Only the `email_verified` gate closes that route, and leaving it for PR 2 keeps a known takeover live throughout the migration.

---

### Task 1: Firebase project config and a shared JWT test helper

**Files:**
- Create: `config/initializers/firebase.rb`
- Create: `test/support/firebase_token_helper.rb`
- Modify: `test/test_helper.rb:7` (add one `require_relative`)
- Modify: `.env` (add `FIREBASE_PROJECT_ID`, untracked — see step 6)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Rails.application.config.x.firebase_project_id` → String
  - `Rails.application.config.x.firebase_issuer` → String
  - `FirebaseTokenHelper.key` → `OpenSSL::PKey::RSA` (memoised per process)
  - `FirebaseTokenHelper.certificate_pem` → String
  - `FirebaseTokenHelper.token(overrides = {}, kid:, alg:, signing_key:)` → String — **overrides must be brace-wrapped at every call site**: a bare `token("aud" => "x")` is parsed as keyword arguments on Ruby 4 and raises `ArgumentError: unknown keyword: "aud"`
  - `FirebaseTokenHelper.stub_certs(kid:, pem:, max_age:)` → WebMock stub

- [ ] **Step 1: Write the initializer**

The project id is not a secret — it is already in the committed JS at
`app/javascript/services/firebase_auth_service.js`. It gets a default so no
environment fails to boot, and stays ENV-overridable so a test can point at
another project.

```ruby
# config/initializers/firebase.rb
#
# The Firebase project every domain authenticates against. NOT a secret: this
# same value is compiled into the public JS bundle, and Firebase web API keys
# are public by design. It lives here rather than as a bare constant so a test
# can point at a different project, and so there is exactly one place that
# knows the issuer string is derived from it.
#
# Used to verify the `aud` and `iss` claims of every Firebase ID token. Before
# these were checked, a token minted by ANY Firebase project validated here.
Rails.application.config.x.firebase_project_id =
  ENV.fetch("FIREBASE_PROJECT_ID", "the-greatest-books")

Rails.application.config.x.firebase_issuer =
  "https://securetoken.google.com/#{Rails.application.config.x.firebase_project_id}"
```

- [ ] **Step 2: Write the test helper**

This is the core of the whole plan. The existing tests stub `JWT.decode`
wholesale, which is precisely why they never caught any of these defects — a
stubbed decoder validates nothing. Everything here builds a real token and
lets the real decoder run.

```ruby
# test/support/firebase_token_helper.rb
require "jwt"
require "openssl"

# Builds real, really-signed Firebase-shaped ID tokens so auth tests exercise
# the actual decoder instead of a stub.
#
# The RSA key and certificate are generated once per process and memoised:
# keygen is ~100ms and the suite runs 10 parallel workers, so per-test
# generation would be the slowest thing in the file. They are immutable after
# creation, so sharing them across tests in a worker is safe.
module FirebaseTokenHelper
  DEFAULT_KID = "test-kid".freeze

  class << self
    # A method, not a constant: this file is require_relative'd from
    # test_helper.rb, and eager_load is off in test, so resolving an autoloaded
    # app constant at module-body evaluation is a Zeitwerk sharp edge. Deferring
    # it to call time sidesteps that entirely.
    def certs_url
      Services::JwtValidationService::GOOGLE_CERTS_URL
    end

    def key
      @key ||= OpenSSL::PKey::RSA.new(2048)
    end

    def certificate
      @certificate ||= begin
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=firebase-test")
        cert.issuer = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now - 3600
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert
      end
    end

    def certificate_pem
      certificate.to_pem
    end

    def project_id
      Rails.application.config.x.firebase_project_id
    end

    def issuer
      Rails.application.config.x.firebase_issuer
    end

    # A well-formed Firebase ID token. Pass overrides to break exactly one
    # claim at a time; pass alg: "none" or a foreign key to forge.
    def token(overrides = {}, kid: DEFAULT_KID, alg: "RS256", signing_key: key)
      now = Time.now.to_i
      payload = {
        "iss" => issuer,
        "aud" => project_id,
        "sub" => "firebase-uid-abc",
        "email" => "someone@example.com",
        "email_verified" => true,
        "name" => "Some One",
        "picture" => "https://example.com/p.jpg",
        "auth_time" => now,
        "iat" => now,
        "exp" => now + 3600,
        "firebase" => {
          "sign_in_provider" => "password",
          "identities" => {"email" => ["someone@example.com"]}
        }
      }.merge(overrides)

      JWT.encode(payload, (alg == "none") ? nil : signing_key, alg, {"kid" => kid})
    end

    # Stubs Google's x509 endpoint. WebMock rather than Mocha on Faraday, so
    # the service's real HTTP + JSON + certificate parsing all run.
    def stub_certs(kid: DEFAULT_KID, pem: certificate_pem, max_age: 3600)
      WebMock.stub_request(:get, certs_url).to_return(
        status: 200,
        body: {kid => pem}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Cache-Control" => "public, max-age=#{max_age}, must-revalidate"
        }
      )
    end
  end
end
```

- [ ] **Step 3: Load the helper from test_helper**

In `test/test_helper.rb`, immediately after the existing
`require_relative "support/stripe_webhook_helper"` on line 7, add:

```ruby
require_relative "support/firebase_token_helper"
```

- [ ] **Step 4: Write a test proving the helper produces a token the real decoder accepts**

Create `test/support/firebase_token_helper_test.rb`:

```ruby
require "test_helper"

class FirebaseTokenHelperTest < ActiveSupport::TestCase
  test "produces a token the real JWT decoder verifies against the real certificate" do
    token = FirebaseTokenHelper.token
    cert = OpenSSL::X509::Certificate.new(FirebaseTokenHelper.certificate_pem)

    payload, header = JWT.decode(token, cert.public_key, true, {algorithm: "RS256"})

    assert_equal "RS256", header["alg"]
    assert_equal FirebaseTokenHelper::DEFAULT_KID, header["kid"]
    assert_equal FirebaseTokenHelper.project_id, payload["aud"]
    assert_equal FirebaseTokenHelper.issuer, payload["iss"]
    assert_equal "firebase-uid-abc", payload["sub"]
  end

  test "a token signed by a foreign key fails verification against our certificate" do
    foreign = OpenSSL::PKey::RSA.new(2048)
    token = FirebaseTokenHelper.token(signing_key: foreign)
    cert = OpenSSL::X509::Certificate.new(FirebaseTokenHelper.certificate_pem)

    assert_raises JWT::VerificationError do
      JWT.decode(token, cert.public_key, true, {algorithm: "RS256"})
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/support/firebase_token_helper_test.rb`
Expected: 2 runs, 0 failures. If keygen makes this slow (>5s), that is
expected once per process and does not recur.

- [ ] **Step 6: Add the env var to the local .env**

`.env` is gitignored. Append to `web-app/.env`:

```
FIREBASE_PROJECT_ID=the-greatest-books
```

The initializer defaults to the same value, so this is documentation rather
than a requirement. Production needs no SOPS entry for it — it is not a secret
and the default is correct.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix config/initializers/firebase.rb test/support/firebase_token_helper.rb test/support/firebase_token_helper_test.rb
git add config/initializers/firebase.rb test/support/firebase_token_helper.rb test/support/firebase_token_helper_test.rb test/test_helper.rb
git commit -m "test: add real-signature Firebase token helper and project config"
```

---

### Task 2: Make the audience check impossible to skip, and verify the issuer

**Files:**
- Modify: `app/lib/services/jwt_validation_service.rb:11-22`
- Modify: `test/lib/services/jwt_validation_service_test.rb` (full rewrite)

**Interfaces:**
- Consumes: `Rails.application.config.x.firebase_project_id`, `FirebaseTokenHelper` from Task 1.
- Produces: `Services::JwtValidationService.call(token, project_id:)` — `project_id` is now a **required** keyword. Returns the decoded payload Hash. Raises `JWT::DecodeError` and its subclasses (`JWT::InvalidAudError`, `JWT::InvalidIssuerError`, `JWT::ExpiredSignature`, `JWT::VerificationError`).

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `test/lib/services/jwt_validation_service_test.rb`.
Every existing test in that file stubs `JWT.decode` and must go — a stubbed
decoder cannot fail any of these.

```ruby
require "test_helper"
require "jwt"

class JwtValidationServiceTest < ActiveSupport::TestCase
  def setup
    @project_id = Rails.application.config.x.firebase_project_id
    FirebaseTokenHelper.stub_certs
  end

  def call(token)
    Services::JwtValidationService.call(token, project_id: @project_id)
  end

  test "accepts a well-formed token and returns its payload" do
    payload = call(FirebaseTokenHelper.token)

    assert_equal "firebase-uid-abc", payload["sub"]
    assert_equal "someone@example.com", payload["email"]
    assert_equal @project_id, payload["aud"]
  end

  test "project_id is required -- omitting it is an ArgumentError, not a skipped check" do
    assert_raises ArgumentError do
      Services::JwtValidationService.call(FirebaseTokenHelper.token)
    end
  end

  # F1. Before this, project_id defaulted to nil and AuthController never passed
  # one, so a token from any Firebase project on earth validated.
  test "rejects a token minted for a different Firebase project" do
    token = FirebaseTokenHelper.token({"aud" => "someone-elses-project"})

    assert_raises JWT::InvalidAudError do
      call(token)
    end
  end

  test "rejects a token whose issuer is not our project" do
    token = FirebaseTokenHelper.token({"iss" => "https://securetoken.google.com/someone-elses-project"})

    assert_raises JWT::InvalidIssuerError do
      call(token)
    end
  end

  # The legacy app is exploitable exactly here: it read alg from the header.
  test "rejects an unsigned alg=none token" do
    token = FirebaseTokenHelper.token({}, alg: "none")

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "rejects a token signed by a key that is not Google's" do
    foreign = OpenSSL::PKey::RSA.new(2048)
    token = FirebaseTokenHelper.token(signing_key: foreign)

    assert_raises JWT::VerificationError do
      call(token)
    end
  end

  test "rejects an expired token" do
    token = FirebaseTokenHelper.token({"exp" => Time.now.to_i - 60})

    assert_raises JWT::ExpiredSignature do
      call(token)
    end
  end

  test "rejects a token with a blank subject" do
    token = FirebaseTokenHelper.token({"sub" => ""})

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "rejects a token whose kid is not in Google's certificate set" do
    token = FirebaseTokenHelper.token(kid: "some-other-kid")

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "raises when Google's certificate endpoint fails" do
    WebMock.stub_request(:get, Services::JwtValidationService::GOOGLE_CERTS_URL)
      .to_return(status: 500, body: "")

    assert_raises JWT::DecodeError do
      call(FirebaseTokenHelper.token)
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/jwt_validation_service_test.rb`
Expected: FAIL. Notably "project_id is required" fails (no ArgumentError —
the default swallows it), the different-project test fails (no
`JWT::InvalidAudError` — `aud:` is passed but `verify_aud: true` never was, so
ruby-jwt never checked it), and the issuer test fails (nothing checks `iss`).

- [ ] **Step 3: Rewrite the service**

Replace lines 11-22 of `app/lib/services/jwt_validation_service.rb`:

```ruby
    # project_id is REQUIRED and deliberately has no default. Its `nil` default
    # was the vulnerability: AuthController never passed one, so the audience
    # check below was unreachable and a token from any Firebase project
    # validated here. A required argument makes that class of mistake a boot-time
    # ArgumentError instead of a silent hole.
    def self.call(token, project_id:)
      raise ArgumentError, "project_id is required" if project_id.blank?

      header = JWT.decode(token, nil, false).last
      cert = fetch_google_cert(header["kid"])

      # verify_aud/verify_iss are what actually enable the checks. Passing
      # `aud:` alone (as this did) configures a value ruby-jwt never compares.
      # ALGORITHM is a constant and is never read from the token header, which
      # is what makes an alg=none or algorithm-confusion forgery fail here.
      payload, _header = JWT.decode(token, cert.public_key, true, {
        algorithm: ALGORITHM,
        aud: project_id,
        verify_aud: true,
        iss: "https://securetoken.google.com/#{project_id}",
        verify_iss: true,
        verify_expiration: true,
        verify_iat: true
      })

      # Firebase guarantees a non-empty sub; a token without one identifies
      # nobody, and every lookup downstream keys on it.
      raise JWT::DecodeError, "Token has no subject" if payload["sub"].blank?

      payload
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/jwt_validation_service_test.rb`
Expected: 10 runs, 0 failures.

- [ ] **Step 5: Prove the tests are not vacuous (mutation evidence)**

Temporarily set `verify_aud: false` in the service and re-run. The
"rejects a token minted for a different Firebase project" test MUST fail.
Restore `verify_aud: true`. Repeat with `verify_iss: false` and confirm the
issuer test fails. Record both results in the commit message.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/jwt_validation_service.rb test/lib/services/jwt_validation_service_test.rb
git add app/lib/services/jwt_validation_service.rb test/lib/services/jwt_validation_service_test.rb
git commit -m "fix: verify Firebase token audience and issuer

project_id was optional and AuthController never passed one, so the audience
check never ran and any Firebase project's token validated. Making it required
plus verify_aud/verify_iss closes it. Mutation-checked: verify_aud:false and
verify_iss:false each turn the matching test red."
```

---

### Task 3: Cache Google's certificates instead of fetching per sign-in

**Files:**
- Modify: `app/lib/services/jwt_validation_service.rb:24-36` (the `fetch_google_cert` method)
- Modify: `test/lib/services/jwt_validation_service_test.rb` (append tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Services::JwtValidationService.reset_cert_cache!` — clears the in-process cache. Tests must call it in `setup` or caching leaks between them.

- [ ] **Step 1: Write the failing tests**

Append to `test/lib/services/jwt_validation_service_test.rb`, and add
`Services::JwtValidationService.reset_cert_cache!` as the FIRST line of the
existing `setup` method (before `FirebaseTokenHelper.stub_certs`).

```ruby
  test "fetches Google's certificates once across repeated validations" do
    3.times { call(FirebaseTokenHelper.token) }

    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 1
  end

  test "refetches once the Cache-Control max-age has passed" do
    FirebaseTokenHelper.stub_certs(max_age: 60)
    call(FirebaseTokenHelper.token)

    travel 61.seconds do
      call(FirebaseTokenHelper.token)
    end

    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 2
  end

  test "refetches when the kid is absent from the cached set" do
    call(FirebaseTokenHelper.token)

    # A rotated key: present in the fresh response, absent from what we cached.
    assert_raises JWT::DecodeError do
      call(FirebaseTokenHelper.token(kid: "rotated-kid"))
    end
    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 2
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/jwt_validation_service_test.rb`
Expected: FAIL — `reset_cert_cache!` is undefined (NoMethodError), and the
"once" test would otherwise report 3 requests.

- [ ] **Step 3: Implement the cache**

Replace `fetch_google_cert` in `app/lib/services/jwt_validation_service.rb`
with the following, and add the `require "monitor"` alongside the existing
requires at the top of the file:

```ruby
    # Google's signing certificates rotate roughly daily, and every sign-in used
    # to fetch them synchronously -- making Google an availability dependency of
    # every login and adding a round trip to each one.
    #
    # In-process rather than Rails.cache on purpose: production configures no
    # cache_store, so Rails.cache is a per-container file store anyway, and this
    # avoids coupling authentication to any external store. Each process holds
    # its own copy; a few extra fetches across processes is not worth a
    # dependency.
    #
    # An unknown kid forces a refetch before it is treated as an error, so a key
    # rotation mid-cache-window recovers on the next request rather than failing
    # every sign-in until the window expires.
    CERT_CACHE_LOCK = Monitor.new
    DEFAULT_CERT_TTL = 3600

    def self.reset_cert_cache!
      CERT_CACHE_LOCK.synchronize do
        @certs = nil
        @certs_expire_at = nil
      end
    end

    def self.fetch_google_cert(kid)
      CERT_CACHE_LOCK.synchronize do
        load_certs! if @certs.nil? || @certs_expire_at.nil? || Time.current >= @certs_expire_at
        load_certs! unless @certs.key?(kid)

        cert_pem = @certs[kid]
        raise JWT::DecodeError, "Unknown key ID" unless cert_pem

        OpenSSL::X509::Certificate.new(cert_pem)
      end
    end

    def self.load_certs!
      response = Faraday.get(GOOGLE_CERTS_URL)

      unless response.success?
        raise JWT::DecodeError, "Failed to fetch Google certificates: #{response.status}"
      end

      @certs = JSON.parse(response.body)
      @certs_expire_at = Time.current + cache_ttl_from(response)
    end

    def self.cache_ttl_from(response)
      max_age = response.headers["cache-control"].to_s[/max-age=(\d+)/, 1]
      max_age ? max_age.to_i : DEFAULT_CERT_TTL
    end

    private_class_method :load_certs!, :cache_ttl_from
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/jwt_validation_service_test.rb`
Expected: 13 runs, 0 failures.

- [ ] **Step 5: Run the full service test directory for cross-test leakage**

Run: `bin/rails test test/lib/services/`
Expected: 0 failures. A leak here shows up as another test seeing a cached
certificate it never stubbed.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/jwt_validation_service.rb test/lib/services/jwt_validation_service_test.rb
git add app/lib/services/jwt_validation_service.rb test/lib/services/jwt_validation_service_test.rb
git commit -m "perf: cache Google signing certificates per max-age

Every sign-in issued a synchronous Faraday GET to Google. An unknown kid
forces one refetch so key rotation recovers immediately."
```

---

### Task 4: Derive every identity claim from the verified token

**Files:**
- Modify: `app/lib/services/authentication_service.rb` (full rewrite)
- Modify: `test/lib/services/authentication_service_test.rb` (full rewrite)

**Interfaces:**
- Consumes: `Services::JwtValidationService.call(token, project_id:)` (Task 2), `Services::UserAuthenticationService.call(provider_data:, signup_domain:)` (Task 5 — write this task's code against that signature; Task 5 delivers it).
- Produces: `Services::AuthenticationService.call(auth_token:, project_id:, signup_domain: nil)`. Note `provider:` and `user_data:` are **removed** from the signature. Returns `{success: true, user:, provider_data:}` or `{success: false, error:, error_code:}` where `error_code` is one of `:invalid_token`, `:unsupported_provider`, `:email_verification_required`, `:user_creation_failed`, `:authentication_failed`.

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `test/lib/services/authentication_service_test.rb`:

```ruby
require "test_helper"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    Services::JwtValidationService.reset_cert_cache!
    FirebaseTokenHelper.stub_certs
    @project_id = Rails.application.config.x.firebase_project_id
  end

  def call(token, signup_domain: nil)
    Services::AuthenticationService.call(
      auth_token: token,
      project_id: @project_id,
      signup_domain: signup_domain
    )
  end

  test "authenticates a well-formed token and creates the user" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-new-1",
      "email" => "brand.new@example.com",
      "firebase" => {"sign_in_provider" => "google.com"}
    })

    result = call(token)

    assert result[:success]
    assert_equal "uid-new-1", result[:user].auth_uid
    assert_equal "brand.new@example.com", result[:user].email
    assert_equal "google", result[:user].external_provider
  end

  # F2. The whole class of bug: user_data was client-supplied params, and its
  # email won over the signed claim. This asserts the parameter is gone.
  test "call does not accept a user_data argument at all" do
    assert_raises ArgumentError do
      Services::AuthenticationService.call(
        auth_token: FirebaseTokenHelper.token,
        project_id: @project_id,
        user_data: {"providerData" => [{"providerId" => "password", "email" => "victim@example.com"}]}
      )
    end
  end

  test "provider comes from the token's sign_in_provider, not from a parameter" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-apple-1",
      "email" => "apple.person@example.com",
      "firebase" => {"sign_in_provider" => "apple.com"}
    })

    result = call(token)

    assert result[:success]
    assert_equal "apple", result[:user].external_provider
  end

  test "rejects a provider the app does not model" do
    token = FirebaseTokenHelper.token({"firebase" => {"sign_in_provider" => "anonymous"}})

    result = call(token)

    refute result[:success]
    assert_equal :unsupported_provider, result[:error_code]
  end

  test "rejects a token with no firebase claim" do
    token = FirebaseTokenHelper.token({"firebase" => nil})

    result = call(token)

    refute result[:success]
    assert_equal :unsupported_provider, result[:error_code]
  end

  test "maps an invalid token to invalid_token without raising" do
    result = call(FirebaseTokenHelper.token({"aud" => "another-project"}))

    refute result[:success]
    assert_equal :invalid_token, result[:error_code]
    assert_equal "Invalid authentication token", result[:error]
  end

  test "surfaces the unverified-email conflict as its own error code" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-attacker",
      "email" => users(:regular_user).email,
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    result = call(token)

    refute result[:success]
    assert_equal :email_verification_required, result[:error_code]
  end

  test "passes the signup domain through to user creation" do
    token = FirebaseTokenHelper.token({"sub" => "uid-dom-1", "email" => "domain.person@example.com"})

    result = call(token, signup_domain: "thegreatest.games")

    assert result[:success]
    assert_equal "thegreatest.games", result[:user].original_signup_domain
  end

  test "does not log the token payload" do
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    begin
      call(FirebaseTokenHelper.token({"sub" => "uid-log-1", "email" => "logged.person@example.com"}))
    ensure
      Rails.logger = original
    end

    refute_includes logged.string, "logged.person@example.com"
    refute_includes logged.string, "JWT Payload"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: FAIL. `project_id`/`signup_domain` are not yet accepted in this
shape, `user_data` is still a valid argument, provider still comes from a
parameter, and the payload is still logged.

- [ ] **Step 3: Rewrite the service**

Replace the entire contents of `app/lib/services/authentication_service.rb`:

```ruby
# Main authentication orchestrator.
#
# Everything this returns is derived from a signature-verified token. Nothing
# reaches it from request params. That is the entire security property: the
# previous version preferred params[:user_data]'s email over the signed `email`
# claim and took the provider from params[:provider], so a caller holding a
# valid token for their own account could name any victim and be handed that
# victim's row.
module Services
  class AuthenticationService
    # Firebase's sign_in_provider values, mapped to User#external_provider.
    # Firebase suffixes OAuth providers with ".com" but uses a bare "password"
    # for email/password. Anything absent here (anonymous, custom) is a provider
    # this app does not model and must not authenticate.
    PROVIDER_MAP = {
      "password" => "password",
      "google.com" => "google",
      "apple.com" => "apple",
      "facebook.com" => "facebook",
      "twitter.com" => "twitter"
    }.freeze

    def self.call(auth_token:, project_id:, signup_domain: nil)
      payload = JwtValidationService.call(auth_token, project_id: project_id)
      provider_data = extract_provider_data(payload)

      user = UserAuthenticationService.call(
        provider_data: provider_data,
        signup_domain: signup_domain
      )

      {success: true, user: user, provider_data: provider_data}
    rescue JWT::DecodeError => e
      Rails.logger.warn "JWT validation failed: #{e.class}"
      {success: false, error: "Invalid authentication token", error_code: :invalid_token}
    rescue UnsupportedProviderError => e
      Rails.logger.warn "Unsupported sign-in provider: #{e.message}"
      {success: false, error: "This sign-in method is not supported", error_code: :unsupported_provider}
    rescue UserAuthenticationService::UnverifiedEmailConflict
      {
        success: false,
        error: "Please verify your email address, then sign in again.",
        error_code: :email_verification_required
      }
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "User creation/update failed: #{e.message}"
      {success: false, error: "Failed to create user account", error_code: :user_creation_failed}
    rescue => e
      Rails.logger.error "Authentication failed: #{e.class}: #{e.message}"
      {success: false, error: "Authentication failed", error_code: :authentication_failed}
    end

    class UnsupportedProviderError < StandardError; end

    # No logging of the payload here. It used to write the full identity payload
    # -- email included -- to production logs at info level.
    def self.extract_provider_data(payload)
      sign_in_provider = payload.dig("firebase", "sign_in_provider")
      provider = PROVIDER_MAP[sign_in_provider]
      raise UnsupportedProviderError, sign_in_provider.inspect if provider.nil?

      {
        user_id: payload["sub"],
        email: payload["email"],
        name: payload["name"],
        picture: payload["picture"],
        # Strict true: Firebase sends a real boolean, and `|| false` on a
        # missing claim must not become "verified".
        email_verified: payload["email_verified"] == true,
        provider: provider,
        auth_time: payload["auth_time"],
        iat: payload["iat"],
        exp: payload["exp"]
      }
    end

    private_class_method :extract_provider_data
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: still some failures — the tests that depend on the new
`UserAuthenticationService` signature (`signup_domain`, `UnverifiedEmailConflict`)
cannot pass until Task 5. All others must pass. Do not proceed past Task 5
without returning to re-run this file.

- [ ] **Step 5: Commit**

```bash
bundle exec standardrb --fix app/lib/services/authentication_service.rb test/lib/services/authentication_service_test.rb
git add app/lib/services/authentication_service.rb test/lib/services/authentication_service_test.rb
git commit -m "fix: derive identity claims from the verified JWT only

Removes params[:user_data] and params[:provider] from the trust boundary.
Provider now comes from firebase.sign_in_provider. Drops the info-level
logging of full identity payloads."
```

---

### Task 5: Rewrite user lookup around uid-primary, verified-email-secondary

**Files:**
- Modify: `app/lib/services/user_authentication_service.rb` (full rewrite)
- Modify: `test/lib/services/user_authentication_service_test.rb` (full rewrite)

**Interfaces:**
- Consumes: `provider_data` Hash from `AuthenticationService.extract_provider_data` (Task 4) — keys `:user_id`, `:email`, `:name`, `:picture`, `:email_verified`, `:provider`, `:auth_time`, `:iat`, `:exp`.
- Produces: `Services::UserAuthenticationService.call(provider_data:, signup_domain: nil)` → `User`. Raises `Services::UserAuthenticationService::UnverifiedEmailConflict` and `ArgumentError`.

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `test/lib/services/user_authentication_service_test.rb`.
Three tests from the old file are deliberately dropped because the behaviour
they asserted is the vulnerability: unconditional email-first matching, and
treating a missing `email_verified` as acceptable for linking.

```ruby
require "test_helper"

class UserAuthenticationServiceTest < ActiveSupport::TestCase
  def provider_data(overrides = {})
    {
      user_id: "google_123",
      email: "test@example.com",
      name: "Test User",
      picture: "https://example.com/photo.jpg",
      email_verified: true,
      provider: "google",
      auth_time: Time.current.to_i,
      iat: Time.current.to_i,
      exp: (Time.current + 1.hour).to_i
    }.merge(overrides)
  end

  def call(overrides = {}, signup_domain: nil)
    Services::UserAuthenticationService.call(
      provider_data: provider_data(overrides),
      signup_domain: signup_domain
    )
  end

  # --- Step 1 of the rule: the uid is the identity ---

  test "matches an existing user by auth_uid regardless of the email claim" do
    existing = users(:password_user)

    user = call(
      user_id: existing.auth_uid,
      email: "totally.different@example.com",
      email_verified: true,
      provider: "password"
    )

    assert_equal existing.id, user.id
    assert_equal existing.email, user.email, "email must never be reassigned by a sign-in"
  end

  test "an auth_uid match wins over a competing email match" do
    uid_owner = users(:password_user)
    email_owner = users(:google_user)

    user = call(
      user_id: uid_owner.auth_uid,
      email: email_owner.email,
      email_verified: true,
      provider: "password"
    )

    assert_equal uid_owner.id, user.id
  end

  # --- Step 2: a verified email links ---

  test "links a new uid to an existing account when the email is verified" do
    existing = users(:regular_user)
    assert_nil existing.auth_uid

    user = call(user_id: "new-uid-9", email: existing.email, email_verified: true)

    assert_equal existing.id, user.id
    assert_equal "new-uid-9", user.reload.auth_uid
  end

  # The V1-user-chooses-Google case. Refusing here would lock a migrated user
  # out of their own account, so a verified email must relink.
  test "relinks an account that already holds a different uid when the email is verified" do
    existing = users(:password_user)
    original_uid = existing.auth_uid

    user = call(user_id: "google-uid-later", email: existing.email, email_verified: true, provider: "google")

    assert_equal existing.id, user.id
    assert_equal "google-uid-later", user.reload.auth_uid
    refute_equal original_uid, user.auth_uid
  end

  # --- Step 3: an unverified email may never link. This IS the original bug. ---

  test "refuses to link an existing account when the email is unverified" do
    victim = users(:google_user)

    assert_no_difference "User.count" do
      assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
        call(user_id: "attacker-uid", email: victim.email, email_verified: false, provider: "password")
      end
    end

    victim.reload
    assert_equal "firebase-google-uid-456", victim.auth_uid, "victim's uid must be untouched"
    assert_equal "google", victim.external_provider
  end

  test "refuses to link when email_verified is absent entirely" do
    victim = users(:google_user)

    assert_raises Services::UserAuthenticationService::UnverifiedEmailConflict do
      call(user_id: "attacker-uid", email: victim.email, email_verified: nil, provider: "password")
    end
  end

  # --- Step 4: create ---

  test "creates a user when neither the uid nor the email is known" do
    assert_difference "User.count", 1 do
      user = call(user_id: "fresh-uid", email: "fresh@example.com")

      assert_equal "fresh-uid", user.auth_uid
      assert_equal "fresh@example.com", user.email
      assert_equal "google", user.external_provider
      assert_equal "user", user.role
      assert_equal 1, user.sign_in_count
      assert_not_nil user.last_sign_in_at
    end
  end

  test "an unverified email that matches nothing still creates a user" do
    assert_difference "User.count", 1 do
      user = call(user_id: "fresh-unverified", email: "nobody.has.this@example.com", email_verified: false)

      assert_not user.email_verified
    end
  end

  test "records the signup domain on creation" do
    user = call({user_id: "dom-uid", email: "dom@example.com"}, signup_domain: "thegreatest.games")

    assert_equal "thegreatest.games", user.original_signup_domain
  end

  test "does not overwrite the signup domain of an existing account" do
    existing = users(:regular_user)
    original = existing.original_signup_domain

    call({user_id: "n-uid", email: existing.email, email_verified: true}, signup_domain: "thegreatest.games")

    assert_equal original, existing.reload.original_signup_domain
  end

  # --- Bookkeeping ---

  test "matches email case-insensitively" do
    existing = users(:regular_user)

    user = call(user_id: "case-uid", email: existing.email.upcase, email_verified: true)

    assert_equal existing.id, user.id
  end

  test "increments sign_in_count and stores provider data" do
    existing = users(:password_user)
    before = existing.sign_in_count || 0

    user = call(user_id: existing.auth_uid, email: existing.email, provider: "password")

    assert_equal before + 1, user.sign_in_count
    assert_equal "password", user.provider_data["password"]["provider"]
  end

  test "never downgrades an already-verified email" do
    existing = users(:google_user)
    assert existing.email_verified

    user = call(user_id: existing.auth_uid, email: existing.email, email_verified: false, provider: "google")

    assert user.reload.email_verified
  end

  test "requires a provider" do
    assert_raises ArgumentError do
      Services::UserAuthenticationService.call(provider_data: provider_data.except(:provider))
    end
  end

  test "requires a user_id" do
    assert_raises ArgumentError do
      Services::UserAuthenticationService.call(provider_data: provider_data(user_id: nil))
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: FAIL — `UnverifiedEmailConflict` is undefined, `signup_domain` is
not accepted, and the email-first lookup makes the uid-precedence tests fail.

- [ ] **Step 3: Rewrite the service**

Replace the entire contents of `app/lib/services/user_authentication_service.rb`:

```ruby
# Finds or creates the User a verified Firebase token belongs to.
#
# The lookup order is the security boundary:
#
#   1. auth_uid == the token's `sub`. Exact, and it came out of a signature.
#   2. a VERIFIED email. Control of an address proves ownership of the account
#      that uses it, so this relinks -- a V1 user imported under one uid who
#      later signs in with Google presents a different sub, and refusing would
#      lock them out of their own data.
#   3. an UNVERIFIED email that matches an existing account is refused outright.
#      This is the takeover route: anyone can create a Firebase password account
#      for someone else's address, and the previous version matched on email
#      unconditionally and then update!'d that row.
#   4. otherwise, create.
module Services
  class UserAuthenticationService
    # Raised at step 3. Callers turn this into "verify your email, then sign in
    # again" -- never into a new account, and never into a link.
    class UnverifiedEmailConflict < StandardError; end

    def self.call(provider_data:, signup_domain: nil)
      new(provider_data, signup_domain).call
    end

    def initialize(provider_data, signup_domain = nil)
      @provider_data = provider_data
      @signup_domain = signup_domain
    end

    def call
      raise ArgumentError, "provider is required in provider_data" if provider.blank?
      raise ArgumentError, "user_id is required in provider_data" if uid.blank?

      user = find_user
      user ? update_existing(user) : build_new
    end

    private

    attr_reader :provider_data, :signup_domain

    def uid = provider_data[:user_id]
    def provider = provider_data[:provider]
    def email = provider_data[:email].presence&.downcase
    def email_verified? = provider_data[:email_verified] == true

    def find_user
      by_uid = User.find_by(auth_uid: uid)
      return by_uid if by_uid
      return nil if email.nil?

      by_email = User.find_by("LOWER(email) = ?", email)
      return nil if by_email.nil?
      raise UnverifiedEmailConflict, "unverified email matches an existing account" unless email_verified?

      by_email
    end

    def update_existing(user)
      # email is deliberately absent: a sign-in must never rewrite the address
      # an account is known by.
      user.update!(
        auth_uid: uid,
        display_name: provider_data[:name].presence || user.display_name,
        photo_url: provider_data[:picture].presence || user.photo_url,
        external_provider: provider,
        email_verified: email_verified? || user.email_verified,
        last_sign_in_at: Time.current,
        sign_in_count: (user.sign_in_count || 0) + 1
      )
      persist_provider_data(user)
    end

    def build_new
      user = User.new(
        email: email,
        auth_uid: uid,
        display_name: provider_data[:name],
        photo_url: provider_data[:picture],
        external_provider: provider,
        email_verified: email_verified?,
        original_signup_domain: signup_domain,
        role: :user,
        last_sign_in_at: Time.current,
        sign_in_count: 1
      )
      persist_provider_data(user)
    end

    def persist_provider_data(user)
      user.provider_data ||= {}
      user.provider_data[provider.to_s] = provider_data
      user.save!
      user
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/user_authentication_service_test.rb`
Expected: 16 runs, 0 failures.

- [ ] **Step 5: Re-run Task 4's tests, now unblocked**

Run: `bin/rails test test/lib/services/authentication_service_test.rb`
Expected: 9 runs, 0 failures.

- [ ] **Step 6: Prove the takeover test is not vacuous (mutation evidence)**

In `find_user`, temporarily delete the line
`raise UnverifiedEmailConflict, ... unless email_verified?`. Re-run
`bin/rails test test/lib/services/user_authentication_service_test.rb`.
"refuses to link an existing account when the email is unverified" and
"refuses to link when email_verified is absent entirely" MUST both fail.
Restore the line. Record the result in the commit message.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb --fix app/lib/services/user_authentication_service.rb test/lib/services/user_authentication_service_test.rb
git add app/lib/services/user_authentication_service.rb test/lib/services/user_authentication_service_test.rb
git commit -m "fix: never link an account on an unverified email

Lookup is now uid-first, with email linking gated on the token's own
email_verified claim. An unverified email matching an existing account is
refused rather than silently claiming it. Mutation-checked: deleting the guard
turns both takeover tests red."
```

---

### Task 6: Reset the session, pass the project id, and stop accepting user_data

**Files:**
- Modify: `app/controllers/auth_controller.rb:14-67`
- Modify: `test/controllers/auth_controller_test.rb` (full rewrite)

**Interfaces:**
- Consumes: `Services::AuthenticationService.call(auth_token:, project_id:, signup_domain:)` (Task 4).
- Produces: `POST /auth/sign_in` accepting only `jwt`; `POST /auth/sign_out`. JSON error bodies gain `error_code` so the frontend can branch on `email_verification_required`.

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `test/controllers/auth_controller_test.rb`:

```ruby
require "test_helper"

class AuthControllerTest < ActionDispatch::IntegrationTest
  def setup
    Services::JwtValidationService.reset_cert_cache!
    FirebaseTokenHelper.stub_certs
  end

  test "signs in with a valid token and returns the user" do
    token = FirebaseTokenHelper.token({
      "sub" => "uid-ctrl-1",
      "email" => "ctrl.one@example.com",
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {jwt: token}, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "ctrl.one@example.com", body["user"]["email"]
    assert_equal "password", body["user"]["provider"]
  end

  test "rejects a missing jwt" do
    post auth_sign_in_path, params: {}, as: :json

    assert_response :unauthorized
    refute JSON.parse(response.body)["success"]
  end

  # F2 end to end: the payload that used to grant takeover must now be inert.
  test "a client-supplied user_data email cannot claim another user's account" do
    victim = users(:google_user)
    token = FirebaseTokenHelper.token({
      "sub" => "attacker-uid",
      "email" => "attacker@example.com",
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {
      jwt: token,
      provider: "password",
      user_data: {"providerData" => [{"providerId" => "password", "email" => victim.email}]}
    }, as: :json

    assert_response :success
    victim.reload
    assert_equal "firebase-google-uid-456", victim.auth_uid
    refute_equal victim.id, JSON.parse(response.body)["user"]["id"]
  end

  test "rejects a token minted for another Firebase project" do
    post auth_sign_in_path, params: {jwt: FirebaseTokenHelper.token({"aud" => "other-project"})}, as: :json

    assert_response :unauthorized
    assert_equal "Invalid authentication token", JSON.parse(response.body)["error"]
  end

  test "rejects an alg=none token" do
    post auth_sign_in_path, params: {jwt: FirebaseTokenHelper.token({}, alg: "none")}, as: :json

    assert_response :unauthorized
  end

  test "returns email_verification_required when an unverified email hits an existing account" do
    token = FirebaseTokenHelper.token({
      "sub" => "attacker-uid-2",
      "email" => users(:google_user).email,
      "email_verified" => false,
      "firebase" => {"sign_in_provider" => "password"}
    })

    post auth_sign_in_path, params: {jwt: token}, as: :json

    assert_response :unauthorized
    assert_equal "email_verification_required", JSON.parse(response.body)["error_code"]
  end

  # F3.
  test "rotates the session id on sign in" do
    get root_path
    before = session_id_cookie

    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-fix-1", "email" => "fix.one@example.com"})
    }, as: :json

    assert_response :success
    refute_equal before, session_id_cookie, "session id must rotate to prevent fixation"
  end

  test "rotates the session id on sign out" do
    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-fix-2", "email" => "fix.two@example.com"})
    }, as: :json
    before = session_id_cookie

    post auth_sign_out_path, as: :json

    assert_response :success
    refute_equal before, session_id_cookie
  end

  test "records the request host as the signup domain for a new user" do
    post auth_sign_in_path,
      params: {jwt: FirebaseTokenHelper.token({"sub" => "uid-host-1", "email" => "host.one@example.com"})},
      headers: {"HOST" => "dev.thegreatest.games"},
      as: :json

    assert_response :success
    assert_equal "dev.thegreatest.games", User.find_by(auth_uid: "uid-host-1").original_signup_domain
  end

  private

  def session_id_cookie
    cookies[Rails.application.config.session_options[:key]]
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/auth_controller_test.rb`
Expected: FAIL — the controller still passes `provider:`/`user_data:` to a
service that no longer accepts them (500s), and no session rotation happens.

- [ ] **Step 3: Rewrite the controller actions**

In `app/controllers/auth_controller.rb`, replace `sign_in` (lines 14-59) and
`sign_out` (lines 61-67):

```ruby
  def sign_in
    if params[:jwt].blank?
      render json: {success: false, error: "Missing jwt parameter"}, status: :unauthorized
      return
    end

    result = Services::AuthenticationService.call(
      auth_token: params[:jwt],
      project_id: Rails.application.config.x.firebase_project_id,
      signup_domain: request.host
    )

    unless result[:success]
      render json: {
        success: false,
        error: result[:error],
        error_code: result[:error_code]
      }, status: :unauthorized
      return
    end

    user = result[:user]

    # Session fixation: a pre-authentication session id must not survive into
    # the authenticated session. reset_session discards it, so the id an
    # attacker could have planted is worthless.
    reset_session
    session[:user_id] = user.id
    session[:provider] = user.external_provider
    cookies[TG_UID_COOKIE] = {
      value: user.id.to_s,
      secure: Rails.env.production?,
      same_site: :lax
    }

    render json: {
      success: true,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        provider: user.external_provider
      }
    }
  rescue => e
    Rails.logger.error "Authentication error: #{e.class}: #{e.message}"
    render json: {success: false, error: "Authentication failed"}, status: :internal_server_error
  end

  def sign_out
    cookies.delete(TG_UID_COOKIE)
    # Same reasoning as sign_in: leaving the id intact lets a captured
    # pre-logout session id be reused against the next sign-in on this browser.
    reset_session

    render json: {success: true}
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/auth_controller_test.rb`
Expected: 9 runs, 0 failures.

- [ ] **Step 5: Prove the fixation tests are not vacuous (mutation evidence)**

Delete the `reset_session` call in `sign_in`, re-run, and confirm
"rotates the session id on sign in" fails. Restore it. Repeat for `sign_out`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git add app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git commit -m "fix: rotate the session on sign in and sign out

Also passes the Firebase project id so the audience check runs, records
request.host as original_signup_domain, and surfaces error_code so the
frontend can branch on email_verification_required. Mutation-checked."
```

---

### Task 7: Rate-limit the unauthenticated auth endpoints

**Files:**
- Modify: `app/controllers/auth_controller.rb` (add `include VisitorIp` and two `rate_limit` declarations)
- Modify: `test/controllers/auth_controller_test.rb` (append tests)

**Interfaces:**
- Consumes: `VisitorIp#visitor_ip`, `Rails.application.config.x.rate_limit_store`.
- Produces: `429` with `{success: false, error: ...}` when either bucket trips.

- [ ] **Step 1: Write the failing tests**

Append to `test/controllers/auth_controller_test.rb`, before the `private`
section. Add `Rails.application.config.x.rate_limit_store.clear` as the first
line of `setup` — the test store is a real MemoryStore shared across tests in
a worker, so counts leak without it.

```ruby
  test "throttles repeated sign-in attempts from one visitor" do
    bad = FirebaseTokenHelper.token({"aud" => "other-project"})

    (AuthController::SIGN_IN_RATE + 1).times do
      post auth_sign_in_path, params: {jwt: bad}, as: :json
    end

    assert_response :too_many_requests
    refute JSON.parse(response.body)["success"]
  end

  test "throttles repeated provider checks from one visitor" do
    (AuthController::CHECK_PROVIDER_RATE + 1).times do
      post auth_check_provider_path, params: {email: "someone@example.com"}, as: :json
    end

    assert_response :too_many_requests
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/auth_controller_test.rb`
Expected: FAIL with `NameError: uninitialized constant AuthController::SIGN_IN_RATE`.

- [ ] **Step 3: Add the rate limits**

In `app/controllers/auth_controller.rb`, after the `before_action :prevent_caching`
line (line 12), insert:

```ruby
  include VisitorIp

  # Both endpoints are unauthenticated, and the repository is public, so an
  # attacker knows exactly what to hit. sign_in is a credential-stuffing target;
  # check_provider confirms whether an address has an account and names its
  # provider, which is an enumeration oracle.
  #
  # by: goes through visitor_ip, never request.remote_ip -- in production
  # remote_ip is the Cloudflare edge IP, so keying on it would put every visitor
  # in one bucket and lock out the whole site.
  #
  # with: is not optional. Rails' default raises TooManyRequests, which renders
  # an HTML error body to a caller that asked for JSON.
  SIGN_IN_RATE = 30
  CHECK_PROVIDER_RATE = 20
  RATE_WINDOW = 1.minute

  rate_limit to: SIGN_IN_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "auth-sign-in",
    only: [:sign_in]

  rate_limit to: CHECK_PROVIDER_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "auth-check-provider",
    only: [:check_provider]
```

And add this private method at the end of the class, before the final `end`:

```ruby
  private

  def render_rate_limited
    render json: {
      success: false,
      error: "Too many attempts. Please wait a moment and try again."
    }, status: :too_many_requests
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/auth_controller_test.rb`
Expected: 11 runs, 0 failures.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb --fix app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git add app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git commit -m "feat: rate-limit sign_in and check_provider by visitor IP"
```

---

### Task 8: Stop the frontend sending user_data, and surface the verification error

**Files:**
- Modify: `app/javascript/services/firebase_auth_service.js` (the `sendToBackend` method)
- Modify: `app/javascript/controllers/authentication_controller.js` (the `handleAuthError` handler)

**Interfaces:**
- Consumes: the `error_code` field added to the JSON error body in Task 6.
- Produces: `POST /auth/sign_in` bodies containing only `{jwt}`.

- [ ] **Step 1: Trim the request body**

In `app/javascript/services/firebase_auth_service.js`, replace the whole
`userData` object construction and the `fetch` body inside `sendToBackend`
with:

```javascript
      // Only the token. Everything the server needs is inside it, signed.
      // This used to also send uid, email, emailVerified, displayName and the
      // full providerData array -- and the server preferred that unsigned email
      // over the token's own claim, which made any account claimable by anyone
      // holding a valid token. Do not reintroduce a body field here.
      const response = await fetch('/auth/sign_in', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        body: JSON.stringify({ jwt: idToken })
      })
```

Delete the now-unused `provider` and `user` parameters' bodies where they were
only feeding `userData` — keep the parameters themselves, since
`handleAuthSuccess` and `handleEmailAuthResult` both still pass them and
`getProviderFromUser` is still used for logging.

- [ ] **Step 2: Branch on the verification error**

In `app/javascript/controllers/authentication_controller.js`, replace
`handleAuthError`:

```javascript
  // Handle authentication error
  handleAuthError(event) {
    this.showError(event.detail.error)
    this.showLoading(false)
  }
```

with:

```javascript
  // Handle authentication error. email_verification_required is not a failure
  // the reader can fix by retrying -- it means the address already belongs to
  // an account and Firebase has not confirmed they control it, so it gets the
  // resend-verification affordance rather than a red error box.
  handleAuthError(event) {
    this.showLoading(false)

    if (event.detail.code === 'email_verification_required') {
      this.showInfo(event.detail.error)
      if (this.hasVerificationMessageTarget) {
        this.verificationMessageTarget.style.display = 'block'
      }
      return
    }

    this.showError(event.detail.error)
  }
```

And in `firebase_auth_service.js`'s `sendToBackend`, propagate the code by
replacing `throw new Error(data.error || 'Authentication failed')` with:

```javascript
      if (!data.success) {
        const error = new Error(data.error || 'Authentication failed')
        error.code = data.error_code
        throw error
      }
```

and the `auth:error` dispatch in its `catch` with:

```javascript
      window.dispatchEvent(new CustomEvent('auth:error', {
        detail: { error: error.message, code: error.code }
      }))
```

- [ ] **Step 3: Rebuild the bundles and verify no JS errors**

```bash
yarn build:all
```

Expected: builds clean. Then start the server and sign in manually once on
`dev-new.thegreatestbooks.org` to confirm the flow still completes.

```bash
bin/rails server
```

Before running anything against port 3000, confirm the port is yours:

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If it prints another checkout, stop and report it — do not kill that server.

- [ ] **Step 4: Run the full suite**

Run: `bin/rails db:test:prepare test`
Expected: 0 failures, 0 errors, and no new warning lines.

- [ ] **Step 5: Lint everything and commit**

```bash
bundle exec standardrb
git add app/javascript/services/firebase_auth_service.js app/javascript/controllers/authentication_controller.js
git commit -m "fix: send only the JWT to /auth/sign_in

The unsigned identity fields the server used to prefer are gone from the
request body. Adds an email_verification_required branch in the error handler."
```

---

### Task 9: Update the authentication feature doc

**Files:**
- Modify: `docs/features/authentication.md` (project root, NOT `web-app/docs/`)

- [ ] **Step 1: Update the sign-in sequence diagram**

In the `Sign-In Flow` mermaid block, replace the two lines

```
    FAS->>RC: POST /auth/sign_in {jwt, provider, user_data}
    RC->>AS: AuthenticationService.call(auth_token:, provider:, user_data:)
```

with

```
    FAS->>RC: POST /auth/sign_in {jwt}
    RC->>AS: AuthenticationService.call(auth_token:, project_id:, signup_domain:)
```

and replace

```
    JWT->>JWT: Fetch Google public certs, validate RS256 signature
```

with

```
    JWT->>JWT: Cached Google certs; verify RS256 signature, aud, iss, sub
```

and replace

```
    UAS->>DB: Find by email or auth_uid, create/update user
```

with

```
    UAS->>DB: Find by auth_uid, else by VERIFIED email, else create
```

and after `RC->>RC: session[:user_id] = user.id` insert a preceding line:

```
    RC->>RC: reset_session (fixation)
```

- [ ] **Step 2: Add a security-model section**

Insert this immediately after the `## Supported Providers` table:

```markdown
## Security model

Everything the server trusts comes out of a signature-verified token. The
request body carries the JWT and nothing else.

| Property | Enforced by |
|---|---|
| Token really is Firebase's | RS256 verified against Google's certs; `ALGORITHM` is a constant, never read from the token header |
| Token is for **our** project | `aud` + `iss` checked with `verify_aud`/`verify_iss`; `project_id` is a required argument so no caller can skip it |
| Identity | `sub` claim → `users.auth_uid`. Never an email from the request |
| Provider | `firebase.sign_in_provider` claim, mapped through `PROVIDER_MAP`. Anything unmapped is refused |
| Cross-identity linking | Only on a token asserting `email_verified: true`. An unverified email matching an existing account raises `UnverifiedEmailConflict` — it never links and never creates a duplicate |
| Session fixation | `reset_session` on both sign-in and sign-out |
| Brute force / enumeration | `rate_limit` on `sign_in` and `check_provider`, keyed by `visitor_ip` |

**Do not reintroduce a request-body field carrying identity.** The parameter
`user_data` previously supplied the email, and the service preferred it over
the signed claim — which made any account claimable by anyone holding a valid
token for any account.
```

- [ ] **Step 3: Commit**

```bash
git add ../docs/features/authentication.md
git commit -m "docs: record the auth security model and the JWT-only request body"
```

---

## Self-Review

**Spec coverage.** F1 → Task 2. F2 → Tasks 4, 5, 6, 8. F3 → Task 6. F4 → Task 3.
F5 → Task 4. F6 (`original_signup_domain`) → Tasks 5, 6. Rate limits → Task 7.
The "real signed JWT" test requirement → Task 1, used by Tasks 2, 4, 6, 7.
F7 (cross-domain `actionCodeSettings`) and the failed-sign-in copy change are
**not** here — they are in the PR 2 plan, with the migration's cross-domain work.
F8 is out of scope by decision D5.

**Placeholder scan.** No TBD/TODO. Every code step carries the literal code.
Task 4's Step 4 deliberately expects partial failure and names Task 5 as the
unblocker rather than deferring work.

**Type consistency.** `Services::UserAuthenticationService.call(provider_data:, signup_domain:)`
is used identically in Task 4's service body, Task 5's definition and tests.
`UnverifiedEmailConflict` is namespaced `Services::UserAuthenticationService::UnverifiedEmailConflict`
in Task 4's rescue, Task 5's definition and the tests in both.
`Services::JwtValidationService.call(token, project_id:)` matches across Tasks 2, 3, 4.
`reset_cert_cache!` is defined in Task 3 and called in the setup blocks of
Tasks 3, 4 and 6. `error_code` values match between Task 4 (service), Task 6
(controller JSON) and Task 8 (JS branch).

**Known breakage this plan repairs.** Three existing tests assert the old
behaviour and are replaced wholesale rather than patched:
`authentication_service_test.rb` "validates project_id when provided" and
"extracts provider data from password provider user_data";
`user_authentication_service_test.rb` "preserves existing email_verified status
if not provided" (its `minimal_data` has no `email_verified`, which the new rule
correctly refuses to link on). All of `jwt_validation_service_test.rb` is
replaced because every test in it stubs `JWT.decode`.
