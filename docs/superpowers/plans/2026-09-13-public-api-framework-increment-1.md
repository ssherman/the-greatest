# Public API Framework — Increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the public API framework — bearer tokens, scopes, account-keyed rate limits, RFC 9457 errors, Alba serialization, an OpenAPI 3.1 contract enforced by tests, service accounts — with `GET /api/v1/books` and `GET /api/v1/books/{slug}` as the first two endpoints.

**Architecture:** `Api::V1::BaseController < ActionController::API` runs four before-actions in order — set `Current.domain`, `Cache-Control: private, no-store`, authenticate (one seam: `Services::Api::Authenticator` → `Api::Principal`), rate-limit (`Services::Api::RateLimiter` on the existing Redis-backed `config.x.rate_limit_store`), then a per-domain scope check. Tokens are `ApiToken` rows storing only a SHA-256 digest; service accounts are `User` rows with `account_kind: :service`. Resources are Alba classes under `app/lib/api/v1/books/`; every integration test validates request and response against `config/api/v1/openapi.yaml` through `openapi_first`.

**Tech Stack:** Rails 8.1, Postgres, Minitest 6 + fixtures + Mocha, Alba 4, openapi_first 3.4 (test only), Redis via `ActiveSupport::Cache::RedisCacheStore`.

**Spec:** `docs/superpowers/specs/2026-09-12-public-api-framework-design.md` — the plan argues from it; read both.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **Use Rails generators** for models, migrations and controllers (`bin/rails generate …`); never hand-create them. Generators create the matching test file.
- **Root-anchor every model reference inside `Api::V1::Books` and `Services::Api`**: `::Books::Book`, `::Api::Principal`. A bare `Books::` inside `module Api::V1::Books` resolves to `Api::V1::Books::…` and raises `NameError`; a bare `Api::` inside `module Services::Api` resolves to `Services::Api::…`. This has bitten the repo three times.
- Rails 8 enum syntax: `enum :account_kind, {person: 0, service: 1}` — colon prefix.
- Result pattern in services: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). `--fix` autocorrects.
- Minitest 6: `assert_nil x`, never `assert_equal nil, x`.
- A clean `bin/rails test` adds **no warning lines**.
- Tests mirror `app/` and are namespaced to match (`module Api; module V1; module Books; class BooksControllerTest`).
- Controller tests assert behaviour (status, headers, JSON keys), never HTML or copy.
- The dev database is shared with other worktrees and not disposable: no `db:reset`, no `delete_all` outside `RAILS_ENV=test`.
- After the new `app/lib/api` directory exists: `CI=1 bin/rails zeitwerk:check` must pass.
- Commit after every task with the attribution trailer from the session reminder. Never commit to `main`; the branch is `worktree-public-api-framework`.
- Rate-limit numbers and the token cap live in `config/initializers/api.rb` — a code change, not a database row.

---

## File structure

| File | Responsibility |
|---|---|
| `Gemfile` | add `alba`; add `openapi_first` to `:test` |
| `config/initializers/api.rb` | rate-limit tiers, unauthenticated IP limit, token cap |
| `app/lib/api/scopes.rb` | scope registry: known/mintable/satisfies? (hierarchy-aware) |
| `app/lib/api/principal.rb` | `Api::Principal` struct: user, token, scopes, tier |
| `app/lib/api/host.rb` | `Api::Host.base_url` from `config.domains`, never `request.host` |
| `app/lib/api/problem.rb` | RFC 9457 problem bodies, one per error code |
| `app/lib/api/page.rb` | pagination params → offset/meta/links; raises `InvalidParameter` |
| `app/lib/api/openapi_document.rb` | loads `config/api/v1/openapi.yaml`, sets `servers` per host |
| `app/lib/api/v1/books/author_summary_resource.rb` | Alba: `{id, slug, name}` for embedding in books |
| `app/lib/api/v1/books/book_resource.rb` | Alba: compact book + `:full` trait |
| `app/lib/services/api/authenticator.rb` | bearer → `Api::Principal` or failure code |
| `app/lib/services/api/rate_limiter.rb` | fixed windows on `config.x.rate_limit_store`; verdicts with headers data |
| `app/lib/services/api/service_accounts.rb` | create / mint / revoke for service accounts (rake tasks delegate here) |
| `app/lib/services/user_authentication_service.rb` | **modify**: sign-in lookups scoped to `User.person` |
| `app/lib/membership_gate.rb` | **modify**: register `:api` |
| `app/models/api_token.rb` | digest-only token model |
| `app/models/user.rb` | **modify**: `account_kind`, `has_many :api_tokens`, skip default lists for service accounts |
| `app/controllers/concerns/current_domain.rb` | extracted from `ApplicationController`; shared with the API base |
| `app/controllers/application_controller.rb` | **modify**: include `CurrentDomain` |
| `app/controllers/concerns/api/authentication.rb` | `authenticate!`, 401/403 challenges, unauthenticated IP window |
| `app/controllers/concerns/api/rate_limited.rb` | `enforce_rate_limit!`, the six headers, 429 |
| `app/controllers/concerns/api/error_rendering.rb` | `render_problem`, `rescue_from` for expected exceptions |
| `app/controllers/api/v1/base_controller.rb` | `ActionController::API` base: ordering of before-actions, `require_scope`, `render_ranked_page` |
| `app/controllers/api/v1/openapi_controller.rb` | public, cacheable `GET /api/v1/openapi.json` |
| `app/controllers/api/v1/books/base_controller.rb` | `require_scope "books:read"` |
| `app/controllers/api/v1/books/books_controller.rb` | index (rank order) and show |
| `config/api/v1/openapi.yaml` | the contract |
| `config/routes.rb` | **modify**: books `namespace :api`; global `openapi.json` |
| `lib/tasks/api.rake` | `api:service_account:create`, `api:service_account:token`, `api:token:revoke` |
| `db/migrate/*_create_api_tokens.rb`, `db/migrate/*_add_account_kind_to_users.rb` | schema |
| `test/support/api_token_secrets.rb` | the plaintext secrets fixtures are digested from |
| `test/support/api_conformance.rb` | `bearer(secret)` and `assert_api_response_conform(status:)` helpers |
| `test/test_helper.rb` | **modify**: require supports; `OpenapiFirst::Test.setup` |
| `test/fixtures/api_tokens.yml`, `test/fixtures/users.yml` | token corpus with a negative class; a service account |
| `test/integration/api/v1/contract_coverage_test.rb` | every documented response is reachable and conforms |
| `docs/features/public-api.md` | feature doc |

---

### Task 1: Gems and configuration

**Files:**
- Modify: `web-app/Gemfile`
- Create: `web-app/config/initializers/api.rb`
- Test: `web-app/test/config/api_config_test.rb`

**Interfaces:**
- Produces: `Rails.application.config.x.api.rate_limits` → `{member: {per_minute:, per_day:}, system: {…}}`; `config.x.api.unauthenticated_per_minute` (Integer); `config.x.api.max_tokens_per_user` (Integer).

- [ ] **Step 1: Add the gems**

In `web-app/Gemfile`, after `gem "jbuilder"`:

```ruby
gem "jbuilder"
# Public API serialization (docs/superpowers/specs/2026-09-12-public-api-framework-design.md, D7).
gem "alba", "~> 4.0"
```

In the `group :test do` block, after `gem "ostruct"`:

```ruby
  # Validates every API integration test's request and response against
  # config/api/v1/openapi.yaml. Not committee: 5.6.3 pins minitest ~> 5.3.
  gem "openapi_first", "~> 3.4"
```

Run: `bundle install`
Expected: both gems resolve; `bundle exec ruby -e 'require "alba"; require "openapi_first"; puts Alba::VERSION, OpenapiFirst::VERSION'` prints `4.x` and `3.4.x`.

- [ ] **Step 2: Write the failing config test**

`web-app/test/config/api_config_test.rb`:

```ruby
require "test_helper"

class ApiConfigTest < ActiveSupport::TestCase
  test "both tiers declare a per-minute and a per-day limit" do
    limits = Rails.application.config.x.api.rate_limits

    assert_equal [:member, :system], limits.keys
    limits.each_value do |tier|
      assert_operator tier.fetch(:per_minute), :>, 0
      assert_operator tier.fetch(:per_day), :>, tier.fetch(:per_minute)
    end
  end

  test "the system tier is more generous than the member tier" do
    limits = Rails.application.config.x.api.rate_limits

    assert_operator limits[:system][:per_minute], :>, limits[:member][:per_minute]
    assert_operator limits[:system][:per_day], :>, limits[:member][:per_day]
  end

  test "the unauthenticated window and the token cap are positive integers" do
    api = Rails.application.config.x.api

    assert_kind_of Integer, api.unauthenticated_per_minute
    assert_operator api.unauthenticated_per_minute, :>, 0
    assert_kind_of Integer, api.max_tokens_per_user
    assert_operator api.max_tokens_per_user, :>, 0
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bin/rails test test/config/api_config_test.rb`
Expected: FAIL — `undefined method 'keys' for nil` (config not defined).

- [ ] **Step 4: Write the initializer**

`web-app/config/initializers/api.rb`:

```ruby
# frozen_string_literal: true

# Tunables for the public API. Rails config, not an admin UI: changing a limit
# is a reviewed deploy, and there is exactly one place to read to know the
# whole answer. Spec: docs/superpowers/specs/2026-09-12-public-api-framework-design.md §4.
#
# Limits are keyed on the ACCOUNT, never the token, so minting more tokens
# never multiplies quota. The system tier is finite on purpose: it protects
# Postgres from a runaway agent loop, not from us.
Rails.application.configure do
  config.x.api.rate_limits = {
    member: {per_minute: 60, per_day: 5_000},
    system: {per_minute: 600, per_day: 200_000}
  }

  # 401 responses per visitor IP per minute. Bounds database load from junk;
  # the defence against guessing is the token's 238 bits of entropy, not this.
  config.x.api.unauthenticated_per_minute = 60

  config.x.api.max_tokens_per_user = 10
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/config/api_config_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock config/initializers/api.rb test/config/api_config_test.rb
git commit -m "feat(api): add alba and openapi_first, and the API tunables initializer"
```

---

### Task 2: `Api::Scopes` registry

**Files:**
- Create: `web-app/app/lib/api/scopes.rb`
- Test: `web-app/test/lib/api/scopes_test.rb`

**Interfaces:**
- Produces: `Api::Scopes.all` → `["books:read", "music:read", "games:read"]`; `Api::Scopes.known?(scope)`; `Api::Scopes.description(scope)`; `Api::Scopes.mintable_by(user)` → Array of scope strings (needs `user.service?` from Task 4 — until then, any object answering `service?`); `Api::Scopes.satisfies?(granted_array, required_string)` → Boolean, hierarchy-aware; `Api::Scopes::UnknownScope`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/scopes_test.rb`:

```ruby
require "test_helper"

module Api
  class ScopesTest < ActiveSupport::TestCase
    Account = Struct.new(:service?)

    test "the three read scopes are registered" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.all
    end

    test "known? and description" do
      assert Scopes.known?("books:read")
      assert Scopes.known?(:books_read.to_s.tr("_", ":"))
      refute Scopes.known?("books:write")
      assert_match(/books/i, Scopes.description("books:read"))
    end

    test "description of an unknown scope raises" do
      assert_raises(Scopes::UnknownScope) { Scopes.description("nope:read") }
    end

    test "a person may mint only the member-mintable scopes" do
      assert_equal ["books:read", "music:read", "games:read"], Scopes.mintable_by(Account.new(false))
    end

    test "a service account may mint every registered scope" do
      assert_equal Scopes.all, Scopes.mintable_by(Account.new(true))
    end

    test "satisfies? is true when the exact scope is granted" do
      assert Scopes.satisfies?(["music:read", "books:read"], "books:read")
      refute Scopes.satisfies?(["music:read"], "books:read")
      refute Scopes.satisfies?([], "books:read")
    end

    test "satisfies? honours hierarchy: a scope covers what it implies" do
      write = Scopes::Scope.new(name: "books:write", description: "Write", member_mintable: false, implies: ["books:read"])
      Scopes.stubs(:registry).returns(Scopes::ALL.merge("books:write" => write))

      assert Scopes.satisfies?(["books:write"], "books:read")
      refute Scopes.satisfies?(["books:read"], "books:write")
    end

    test "satisfies? ignores unknown granted scopes rather than raising" do
      refute Scopes.satisfies?(["nope:read"], "books:read")
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/api/scopes_test.rb`
Expected: FAIL — `uninitialized constant Api::Scopes`.

- [ ] **Step 3: Write the registry**

`web-app/app/lib/api/scopes.rb`:

```ruby
# frozen_string_literal: true

# The one place that answers "what may a token do?". A registry, not an
# abstraction layer -- its value is that a reviewer reads one hash and knows
# the complete answer, the same reason MembershipGate is a hash.
#
# Scope strings are OAuth-style (`books:read`) on purpose: when Doorkeeper
# arrives for the MCP server, these exact strings become OAuth scopes.
#
# Write and admin scopes are not defined yet. When one is, it goes here with
# `implies:` naming the reads it covers, and `satisfies?` already honours that.
module Api
  module Scopes
    class UnknownScope < StandardError; end

    Scope = Struct.new(:name, :description, :member_mintable, :implies, keyword_init: true)

    ALL = {
      "books:read" => Scope.new(
        name: "books:read",
        description: "Read books and authors on The Greatest Books",
        member_mintable: true,
        implies: []
      ),
      "music:read" => Scope.new(
        name: "music:read",
        description: "Read albums, artists and songs on The Greatest Music",
        member_mintable: true,
        implies: []
      ),
      "games:read" => Scope.new(
        name: "games:read",
        description: "Read games on The Greatest Games",
        member_mintable: true,
        implies: []
      )
    }.freeze

    def self.all = registry.keys

    def self.known?(scope) = registry.key?(scope.to_s)

    def self.description(scope) = fetch(scope).description

    def self.fetch(scope)
      registry.fetch(scope.to_s) do
        raise UnknownScope, "#{scope.inspect} is not registered in Api::Scopes::ALL"
      end
    end

    # What an account may put on a personal token. A person gets the
    # member-mintable set; a service account gets whatever an admin assigns.
    def self.mintable_by(user)
      return all if user.service?

      registry.values.select(&:member_mintable).map(&:name)
    end

    # Does the granted set cover the required scope? A granted scope covers
    # itself and everything it implies, transitively. Unknown granted scopes
    # are ignored rather than raised on: a token minted before a scope was
    # retired must still work for the scopes it does have.
    def self.satisfies?(granted, required)
      required = required.to_s
      Array(granted).any? { |scope| scope == required || expand(scope).include?(required) }
    end

    def self.expand(scope)
      return [] unless known?(scope)

      fetch(scope).implies.flat_map { |implied| [implied, *expand(implied)] }
    end

    # Indirection so a test can register a hypothetical write scope without
    # mutating the frozen constant.
    def self.registry = ALL
    private_class_method :registry
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/scopes_test.rb`
Expected: 8 runs, 0 failures. Mocha can stub a private class method; if `stubs(:registry)` complains, drop `private_class_method :registry`.

- [ ] **Step 5: Zeitwerk check for the new directory**

Run: `CI=1 bin/rails zeitwerk:check`
Expected: `All is good!`

- [ ] **Step 6: Commit**

```bash
git add app/lib/api/scopes.rb test/lib/api/scopes_test.rb
git commit -m "feat(api): scope registry with hierarchy-aware satisfies?"
```

---

### Task 3: `ApiToken` model, migration, fixtures

**Files:**
- Create (generator): `web-app/app/models/api_token.rb`, `web-app/db/migrate/*_create_api_tokens.rb`, `web-app/test/models/api_token_test.rb`, `web-app/test/fixtures/api_tokens.yml`
- Create: `web-app/test/support/api_token_secrets.rb`
- Modify: `web-app/test/test_helper.rb` (one `require_relative`), `web-app/app/models/user.rb` (`has_many :api_tokens`)

**Interfaces:**
- Consumes: `Api::Scopes.known?`, `Api::Scopes.mintable_by(user)` (Task 2); `user.service?` (Task 4 — this task adds a temporary stand-in on `User` that Task 4 replaces with the enum).
- Produces: `ApiToken.generate(user:, name:, scopes:, expires_at: nil)` → `[record, secret]` (record may be unpersisted with `errors`); `ApiToken.authenticate(secret)` → record or nil; `ApiToken#expired?`; `ApiToken#touch_last_used!`; `ApiToken::PREFIX`, `SECRET_FORMAT`; fixtures `api_tokens(:regular_user_token | :regular_user_music_only_token | :regular_user_expired_token | :non_member_token | :service_account_token)`; constants `ApiTokenSecrets::MEMBER`, `MUSIC_ONLY`, `EXPIRED`, `NON_MEMBER`, `SERVICE`.

- [ ] **Step 1: Generate the model**

Run:
```bash
bin/rails generate model ApiToken user:references name:string token_digest:string token_prefix:string expires_at:datetime last_used_at:datetime
```
Expected: creates the migration, `app/models/api_token.rb`, `test/models/api_token_test.rb`, `test/fixtures/api_tokens.yml`.

- [ ] **Step 2: Edit the migration** to add the `scopes` array, NOT NULL constraints and the unique digest index. Replace the generated file's contents with:

```ruby
class CreateApiTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.string :scopes, array: true, null: false, default: []
      t.datetime :expires_at
      t.datetime :last_used_at

      t.timestamps
    end
    add_index :api_tokens, :token_digest, unique: true
  end
end
```

Run: `bin/rails db:migrate`
Expected: migrates; `db/schema.rb` gains `api_tokens`. The dev database is shared with sibling worktrees — if `schema.rb` also picks up a sibling's migration, that is the known worktree behaviour; commit only the `api_tokens` block if so.

- [ ] **Step 3: Temporary stand-in for `service?` on `User`** (Task 4 replaces it with the enum). In `web-app/app/models/user.rb`, directly under `after_create :create_default_user_lists`:

```ruby
  has_many :api_tokens, dependent: :destroy

  # Replaced by the account_kind enum in the next commit.
  def service? = false
```

Move `has_many :api_tokens, dependent: :destroy` up to sit with the other `has_many` lines (after `has_many :books_reading_goals …`) — every user FK needs its `has_many` or admin delete-user 500s.

- [ ] **Step 4: The secrets support file and fixtures**

`web-app/test/support/api_token_secrets.rb`:

```ruby
# Plaintext secrets whose digests the api_tokens fixtures store. One constant
# per fixture row, so a test authenticates with ApiTokenSecrets::MEMBER and the
# fixture file derives the digest from the same value.
module ApiTokenSecrets
  MEMBER = "tg_#{"m" * 40}".freeze
  MUSIC_ONLY = "tg_#{"u" * 40}".freeze
  EXPIRED = "tg_#{"e" * 40}".freeze
  NON_MEMBER = "tg_#{"n" * 40}".freeze
  SERVICE = "tg_#{"s" * 40}".freeze
end
```

In `web-app/test/test_helper.rb`, after `require_relative "support/firebase_token_helper"`:

```ruby
require_relative "support/api_token_secrets"
```

Replace `web-app/test/fixtures/api_tokens.yml` with:

```yaml
# The corpus has a negative class on purpose: an expired token, a token whose
# owner is not a member, and a token missing the books scope. Secrets live in
# test/support/api_token_secrets.rb; only their SHA-256 digests are stored here,
# exactly as in production.

regular_user_token:
  user: regular_user
  name: laptop
  token_digest: <%= Digest::SHA256.hexdigest(ApiTokenSecrets::MEMBER) %>
  token_prefix: <%= ApiTokenSecrets::MEMBER[0, 12] %>
  scopes: ["books:read", "music:read", "games:read"]

regular_user_music_only_token:
  user: regular_user
  name: music-only
  token_digest: <%= Digest::SHA256.hexdigest(ApiTokenSecrets::MUSIC_ONLY) %>
  token_prefix: <%= ApiTokenSecrets::MUSIC_ONLY[0, 12] %>
  scopes: ["music:read"]

regular_user_expired_token:
  user: regular_user
  name: expired
  token_digest: <%= Digest::SHA256.hexdigest(ApiTokenSecrets::EXPIRED) %>
  token_prefix: <%= ApiTokenSecrets::EXPIRED[0, 12] %>
  scopes: ["books:read"]
  expires_at: <%= 1.day.ago.iso8601 %>

non_member_token:
  user: books_viewer_user
  name: laptop
  token_digest: <%= Digest::SHA256.hexdigest(ApiTokenSecrets::NON_MEMBER) %>
  token_prefix: <%= ApiTokenSecrets::NON_MEMBER[0, 12] %>
  scopes: ["books:read"]

service_account_token:
  user: agent_runner_service_account
  name: default
  token_digest: <%= Digest::SHA256.hexdigest(ApiTokenSecrets::SERVICE) %>
  token_prefix: <%= ApiTokenSecrets::SERVICE[0, 12] %>
  scopes: ["books:read", "music:read", "games:read"]
```

The `agent_runner_service_account` user does not exist yet. Append it to `web-app/test/fixtures/users.yml` now, **without** `account_kind` (that column arrives in Task 4, which adds `account_kind: 1` to this row):

```yaml
# A service account: the internal Python agent framework authenticates as this.
# No auth_uid, no external_provider, no membership; an email on a TLD (.invalid)
# that can never resolve, so no identity provider can ever vouch for it.
agent_runner_service_account:
  email: agent-runner@service-accounts.thegreatest.invalid
  display_name: agent-runner
  name: agent-runner
  role: 0
  email_verified: false
  original_signup_domain: thegreatestbooks.org
```

- [ ] **Step 5: Write the failing model tests**

Replace `web-app/test/models/api_token_test.rb` with:

```ruby
require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup do
    @user = users(:regular_user)
  end

  test "generate returns the secret once and stores only its digest and prefix" do
    token, secret = ApiToken.generate(user: @user, name: "agent", scopes: ["books:read"])

    assert token.persisted?
    assert_match ApiToken::SECRET_FORMAT, secret
    assert_equal Digest::SHA256.hexdigest(secret), token.token_digest
    assert_equal secret[0, 12], token.token_prefix
    assert_nil token.expires_at
    refute ApiToken.column_names.include?("secret")
    refute token.attributes.values.include?(secret)
  end

  test "generate with an expiry" do
    freeze_time do
      token, _secret = ApiToken.generate(user: @user, name: "short", scopes: ["books:read"], expires_at: 30.days.from_now)

      assert_equal 30.days.from_now, token.expires_at
    end
  end

  test "authenticate finds a live token by its secret" do
    assert_equal api_tokens(:regular_user_token), ApiToken.authenticate(ApiTokenSecrets::MEMBER)
  end

  test "authenticate returns nil for an unknown secret" do
    assert_nil ApiToken.authenticate("tg_#{"z" * 40}")
  end

  test "authenticate returns nil for an expired token" do
    assert_nil ApiToken.authenticate(ApiTokenSecrets::EXPIRED)
  end

  test "authenticate rejects a malformed secret without querying" do
    assert_no_queries do
      assert_nil ApiToken.authenticate(nil)
      assert_nil ApiToken.authenticate("")
      assert_nil ApiToken.authenticate("not-a-token")
      assert_nil ApiToken.authenticate("tg_short")
      assert_nil ApiToken.authenticate("tg_#{"m" * 40}!")
    end
  end

  test "expired? is false with no expiry, false before it, true at and after it" do
    token = api_tokens(:regular_user_token)
    refute token.expired?

    token.expires_at = 1.minute.from_now
    refute token.expired?

    token.expires_at = Time.current
    assert token.expired?
  end

  test "touch_last_used! writes once, then not again within five minutes" do
    token = api_tokens(:regular_user_token)
    assert_nil token.last_used_at

    freeze_time do
      token.touch_last_used!
      assert_equal Time.current, token.reload.last_used_at

      travel 4.minutes
      token.touch_last_used!
      assert_equal 4.minutes.ago, token.reload.last_used_at

      travel 2.minutes
      token.touch_last_used!
      assert_equal Time.current, token.reload.last_used_at
    end
  end

  test "requires a name of at most 60 characters" do
    token, _secret = ApiToken.generate(user: @user, name: "", scopes: ["books:read"])
    refute token.persisted?
    assert_includes token.errors[:name], "can't be blank"

    token, _secret = ApiToken.generate(user: @user, name: "x" * 61, scopes: ["books:read"])
    refute token.persisted?
    assert token.errors[:name].any?
  end

  test "requires at least one scope" do
    token, _secret = ApiToken.generate(user: @user, name: "empty", scopes: [])

    refute token.persisted?
    assert token.errors[:scopes].any?
  end

  test "rejects an unknown scope" do
    token, _secret = ApiToken.generate(user: @user, name: "bad", scopes: ["books:read", "films:read"])

    refute token.persisted?
    assert_includes token.errors[:scopes].join, "films:read"
  end

  test "rejects a scope the owner may not mint" do
    Api::Scopes.stubs(:mintable_by).with(@user).returns(["books:read"])

    token, _secret = ApiToken.generate(user: @user, name: "greedy", scopes: ["books:read", "music:read"])

    refute token.persisted?
    assert_includes token.errors[:scopes].join, "music:read"
  end

  test "an account holds at most the configured number of tokens" do
    cap = Rails.application.config.x.api.max_tokens_per_user
    existing = @user.api_tokens.count
    (cap - existing).times do |n|
      token, _secret = ApiToken.generate(user: @user, name: "fill-#{n}", scopes: ["books:read"])
      assert token.persisted?, token.errors.full_messages.join(", ")
    end

    token, _secret = ApiToken.generate(user: @user, name: "one-too-many", scopes: ["books:read"])

    refute token.persisted?
    assert token.errors[:base].any?
  end

  test "destroying a user destroys their tokens" do
    user = User.create!(email: "temp-token-owner@example.com", role: :user, email_verified: false, display_name: "Temp")
    ApiToken.generate(user: user, name: "t", scopes: ["books:read"])

    assert_difference("ApiToken.count", -1) { user.destroy! }
  end
end
```

- [ ] **Step 6: Run to verify they fail**

Run: `bin/rails test test/models/api_token_test.rb`
Expected: FAIL — `undefined method 'generate'` etc.

- [ ] **Step 7: Write the model**

Replace `web-app/app/models/api_token.rb` (keep the annotate header the generator/annotaterb wrote at the top) with:

```ruby
# frozen_string_literal: true

# A personal access token for the public API.
#
# Only the SHA-256 digest of the secret is stored. The secret exists in exactly
# one place -- the second element of .generate's return value -- and is gone
# once the caller drops it. This is the scheme GitHub, GitLab and Discourse use,
# and it does not depend on the scheme being private: an attacker with the
# source and a copy of the table needs a SHA-256 preimage of a 238-bit random
# string. bcrypt is deliberately NOT used: it exists to slow brute force on
# low-entropy secrets and would add ~100 ms to every API request for nothing.
#
# Rate limits key on the owning USER, not the token (Services::Api::RateLimiter),
# so the per-account cap here is about hygiene, not quota.
class ApiToken < ApplicationRecord
  PREFIX = "tg_"
  SECRET_LENGTH = 40
  SECRET_FORMAT = /\A#{PREFIX}[A-Za-z0-9]{#{SECRET_LENGTH}}\z/
  PREFIX_DISPLAY_LENGTH = 12
  LAST_USED_WRITE_INTERVAL = 5.minutes

  belongs_to :user

  validates :name, presence: true, length: {maximum: 60}
  validates :token_digest, presence: true, uniqueness: true
  validates :token_prefix, presence: true
  validates :scopes, presence: true
  validate :scopes_are_known_and_mintable
  validate :owner_is_under_the_cap, on: :create

  # Returns [record, secret]. The record is unpersisted (with errors) when
  # validation fails; the secret is still returned so the caller's control flow
  # stays uniform, and it is worthless without the row.
  def self.generate(user:, name:, scopes:, expires_at: nil)
    secret = PREFIX + SecureRandom.alphanumeric(SECRET_LENGTH)
    record = new(
      user: user,
      name: name,
      scopes: scopes,
      expires_at: expires_at,
      token_digest: digest(secret),
      token_prefix: secret[0, PREFIX_DISPLAY_LENGTH]
    )
    record.save
    [record, secret]
  end

  # The live token for a secret, or nil. A malformed secret never reaches the
  # database. secure_compare on the found digest is belt-and-braces: an indexed
  # lookup on a 256-bit digest is not a practical timing oracle, but the compare
  # costs nothing.
  def self.authenticate(secret)
    return nil unless SECRET_FORMAT.match?(secret.to_s)

    candidate = digest(secret)
    token = find_by(token_digest: candidate)
    return nil unless token && ActiveSupport::SecurityUtils.secure_compare(token.token_digest, candidate)
    return nil if token.expired?

    token
  end

  def self.digest(secret) = Digest::SHA256.hexdigest(secret)

  def expired? = expires_at.present? && expires_at <= Time.current

  # At most one write per LAST_USED_WRITE_INTERVAL, so a busy agent does not
  # cost an UPDATE per request. update_column: no validations, no callbacks,
  # no updated_at churn.
  def touch_last_used!
    return if last_used_at.present? && last_used_at > LAST_USED_WRITE_INTERVAL.ago

    update_column(:last_used_at, Time.current)
  end

  private

  def scopes_are_known_and_mintable
    return if scopes.blank? || user.nil?

    unknown = scopes.reject { |scope| Api::Scopes.known?(scope) }
    errors.add(:scopes, "unknown: #{unknown.join(", ")}") if unknown.any?

    forbidden = (scopes - unknown) - Api::Scopes.mintable_by(user)
    errors.add(:scopes, "not available to this account: #{forbidden.join(", ")}") if forbidden.any?
  end

  def owner_is_under_the_cap
    return if user.nil?

    cap = Rails.application.config.x.api.max_tokens_per_user
    errors.add(:base, "You can have at most #{cap} tokens") if user.api_tokens.count >= cap
  end
end
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/models/api_token_test.rb`
Expected: 14 runs, 0 failures. If `assert_no_queries` is undefined in `ActiveSupport::TestCase`, replace that block with `assert_equal 0, capture_sql { … }.size`.

- [ ] **Step 9: Run the user model tests and lint**

Run: `bin/rails test test/models/user_test.rb && bundle exec standardrb app/models/api_token.rb app/models/user.rb test/models/api_token_test.rb test/support/api_token_secrets.rb`
Expected: green, no offences.

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models/api_token.rb app/models/user.rb test/models/api_token_test.rb test/fixtures/api_tokens.yml test/fixtures/users.yml test/support/api_token_secrets.rb test/test_helper.rb
git commit -m "feat(api): ApiToken model storing SHA-256 digests, shown-once secrets"
```

---

### Task 4: Service accounts on `User` and the sign-in guard

**Files:**
- Create (generator): `web-app/db/migrate/*_add_account_kind_to_users.rb`
- Modify: `web-app/app/models/user.rb`, `web-app/app/lib/services/user_authentication_service.rb`, `web-app/test/fixtures/users.yml`, `web-app/test/fixtures/api_tokens.yml` (restore `service_account_token`'s user)
- Test: `web-app/test/models/user_test.rb`, `web-app/test/lib/services/user_authentication_service_test.rb`

**Interfaces:**
- Produces: `User#account_kind` enum (`person`/`service`), `User.person`/`User.service` scopes, `User#person?`/`User#service?`; `User::SERVICE_ACCOUNT_EMAIL_DOMAIN`, `User::SERVICE_ACCOUNT_NAME_FORMAT`, `User.service_account_email(name)`; fixture `users(:agent_runner_service_account)`.

- [ ] **Step 1: Generate and run the migration**

Run:
```bash
bin/rails generate migration AddAccountKindToUsers account_kind:integer
```
Edit the generated migration so the column is NOT NULL with a default (a non-rewriting add on Postgres 11+):

```ruby
class AddAccountKindToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :account_kind, :integer, null: false, default: 0
  end
end
```

Run: `bin/rails db:migrate`
Expected: `users.account_kind` in `db/schema.rb`.

- [ ] **Step 2: Mark the fixture as a service account**

In `web-app/test/fixtures/users.yml`, add `account_kind: 1` to the `agent_runner_service_account` row Task 3 created (after `role: 0`).

- [ ] **Step 3: Write the failing model tests**

Append to `web-app/test/models/user_test.rb`, inside the test class:

```ruby
  # --- service accounts -------------------------------------------------------

  test "account_kind defaults to person" do
    assert users(:regular_user).person?
    refute users(:regular_user).service?
    assert users(:agent_runner_service_account).service?
  end

  test "person and service scopes partition users" do
    assert_includes User.person, users(:regular_user)
    refute_includes User.person, users(:agent_runner_service_account)
    assert_includes User.service, users(:agent_runner_service_account)
  end

  test "service_account_email builds an address on the .invalid domain" do
    assert_equal "agent-runner@service-accounts.thegreatest.invalid", User.service_account_email("agent-runner")
    assert_match User::SERVICE_ACCOUNT_NAME_FORMAT, "agent-runner"
    refute_match User::SERVICE_ACCOUNT_NAME_FORMAT, "Agent Runner"
    refute_match User::SERVICE_ACCOUNT_NAME_FORMAT, "agent_runner"
  end

  test "creating a person creates the default user lists" do
    user = User.create!(email: "person-lists@example.com", role: :user, email_verified: false, display_name: "P")

    assert_operator user.user_lists.count, :>, 0
  end

  test "creating a service account creates no user lists" do
    user = User.create!(
      email: User.service_account_email("lists-check"), role: :user, email_verified: false,
      display_name: "lists-check", account_kind: :service
    )

    assert_equal 0, user.user_lists.count
  end
```

- [ ] **Step 4: Write the failing sign-in guard tests**

Append to `web-app/test/lib/services/user_authentication_service_test.rb`, inside the test class (it already defines `provider_data(overrides)`; keep using it):

```ruby
  # --- service accounts are invisible to sign-in -----------------------------

  test "a service account is never found by auth_uid" do
    service = users(:agent_runner_service_account)
    service.update_column(:auth_uid, "svc_uid_123")

    result = Services::UserAuthenticationService.call(provider_data: provider_data(user_id: "svc_uid_123", email: "someone@example.com"))

    refute_equal service, result
    assert result.person?
  end

  test "a service account is never linked by a trusted email" do
    service = users(:agent_runner_service_account)

    assert_difference "User.count", 1 do
      result = Services::UserAuthenticationService.call(
        provider_data: provider_data(user_id: "new_uid_9", email: service.email, email_verified: true, email_trusted: true)
      )
      refute_equal service, result
      assert result.person?
    end
    assert_nil service.reload.auth_uid
  end

  test "a person with the same email shape is still found" do
    person = users(:regular_user)
    person.update_column(:auth_uid, "person_uid_1")

    result = Services::UserAuthenticationService.call(provider_data: provider_data(user_id: "person_uid_1", email: person.email))

    assert_equal person, result
  end
```

Check how the existing tests in that file call the service (`call(provider_data: …)` vs a local helper) and match it; the assertions above are what matter.

- [ ] **Step 5: Run to verify they fail**

Run: `bin/rails test test/models/user_test.rb test/lib/services/user_authentication_service_test.rb`
Expected: the new tests FAIL (`undefined method 'person?'`, service account found by uid/email).

- [ ] **Step 6: Implement on `User`**

In `web-app/app/models/user.rb`:

Remove the temporary `def service? = false` from Task 3. Directly under `enum :external_provider, [...]` add:

```ruby
  # person: a human who signs in through Firebase. service: an internal
  # principal (the Python agent framework) that holds API tokens and nothing
  # else -- it cannot sign in (UserAuthenticationService scopes every lookup to
  # .person), has no membership, and gets the system rate tier.
  enum :account_kind, {person: 0, service: 1}

  SERVICE_ACCOUNT_EMAIL_DOMAIN = "service-accounts.thegreatest.invalid"
  SERVICE_ACCOUNT_NAME_FORMAT = /\A[a-z0-9-]+\z/

  # RFC 2606 reserves .invalid: the address can never resolve, so no identity
  # provider can ever assert it and the email-linking path can never match it.
  def self.service_account_email(name) = "#{name}@#{SERVICE_ACCOUNT_EMAIL_DOMAIN}"
```

Change the callback line to:

```ruby
  after_create :create_default_user_lists, unless: :service?
```

- [ ] **Step 7: Implement the guard**

In `web-app/app/lib/services/user_authentication_service.rb`, `find_user`:

```ruby
    def find_user
      # .person on both lookups: a service account (account_kind: service) holds
      # API tokens and must never be reachable through sign-in. Scoping here makes
      # it invisible to the uid AND the email path, rather than merely unlikely
      # to match -- the email path is the documented takeover route.
      by_uid = User.person.find_by(auth_uid: uid)
      return by_uid if by_uid
      return nil if email.nil?

      # .order(:id).first, not find_by: the database currently holds
      # case-insensitively duplicate email rows, and this lookup sits on the
      # security boundary (see the class comment). Without an explicit order,
      # which row wins is Postgres's choice and can change between query plans.
      by_email = User.person.where("LOWER(email) = ?", email).order(:id).first
      return nil if by_email.nil?
      raise UnverifiedEmailConflict, "untrusted email matches an existing account" unless email_trusted?

      by_email
    end
```

Also add, in the class comment's numbered list, a line 0: `0. account_kind: service rows are excluded from every step below.`

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bin/rails test test/models/user_test.rb test/lib/services/user_authentication_service_test.rb test/models/api_token_test.rb test/lib/services/authentication_service_test.rb`
Expected: all green. If the second guard test fails because `build_new` copies the *service* row's email into a new row and hits the unique email index — that would mean the guard is wrong; the expected path is: uid lookup finds nothing, email lookup (scoped to person) finds nothing, so a new person is created with that email — which collides with the service account's email on the `lower(email)` unique index. **That collision is the correct outcome to assert instead**: change the test to `assert_raises(ActiveRecord::RecordNotUnique) { … }` if that is what happens, and note in the test why (a service email can never be asserted by a real provider, so the path is unreachable in production; the test documents that the guard never *links*).

- [ ] **Step 9: Lint and commit**

Run: `bundle exec standardrb app/models/user.rb app/lib/services/user_authentication_service.rb test/models/user_test.rb test/lib/services/user_authentication_service_test.rb`

```bash
git add db/migrate db/schema.rb app/models/user.rb app/lib/services/user_authentication_service.rb test/fixtures/users.yml test/fixtures/api_tokens.yml test/models/user_test.rb test/lib/services/user_authentication_service_test.rb
git commit -m "feat(api): service accounts as User rows that sign-in can never find"
```

---

### Task 5: `Api::Principal` and `Services::Api::Authenticator`

**Files:**
- Create: `web-app/app/lib/api/principal.rb`, `web-app/app/lib/services/api/authenticator.rb`
- Test: `web-app/test/lib/services/api/authenticator_test.rb`

**Interfaces:**
- Consumes: `ApiToken.authenticate(secret)`, `#touch_last_used!` (Task 3); `User#member?`, `#person?`, `#service?` (Task 4); `Api::Scopes.satisfies?` (Task 2).
- Produces: `Api::Principal.new(user:, token:, scopes:, tier:)` with `#scope?(required)`; `Services::Api::Authenticator.call(request)` → `Result(success?:, data: principal, errors: [code])` where code ∈ `:unauthenticated | :invalid_token | :membership_required`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/api/authenticator_test.rb`:

```ruby
require "test_helper"

module Services
  module Api
    class AuthenticatorTest < ActiveSupport::TestCase
      def request_with(authorization)
        env = authorization ? {"HTTP_AUTHORIZATION" => authorization} : {}
        ActionDispatch::Request.new(Rack::MockRequest.env_for("/api/v1/books", env))
      end

      test "a member's live token yields a member principal" do
        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}"))

        assert result.success?
        principal = result.data
        assert_kind_of ::Api::Principal, principal
        assert_equal users(:regular_user), principal.user
        assert_equal api_tokens(:regular_user_token), principal.token
        assert_equal ["books:read", "music:read", "games:read"], principal.scopes
        assert_equal :member, principal.tier
        assert principal.scope?("books:read")
        refute principal.scope?("books:write")
      end

      test "a service account's token yields a system principal without a membership" do
        refute users(:agent_runner_service_account).member?

        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::SERVICE}"))

        assert result.success?
        assert_equal :system, result.data.tier
      end

      test "the scheme is case-insensitive and surrounding whitespace is tolerated" do
        assert Authenticator.call(request_with("bearer  #{ApiTokenSecrets::MEMBER} ")).success?
      end

      test "no Authorization header is :unauthenticated" do
        result = Authenticator.call(request_with(nil))

        refute result.success?
        assert_equal [:unauthenticated], result.errors
      end

      test "a non-Bearer scheme is :invalid_token" do
        result = Authenticator.call(request_with("Basic dXNlcjpwYXNz"))

        assert_equal [:invalid_token], result.errors
      end

      test "an empty bearer value is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer ")).errors
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer")).errors
      end

      test "an unknown secret is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer tg_#{"z" * 40}")).errors
      end

      test "an expired token is :invalid_token" do
        assert_equal [:invalid_token], Authenticator.call(request_with("Bearer #{ApiTokenSecrets::EXPIRED}")).errors
      end

      test "a person without an active membership is :membership_required" do
        result = Authenticator.call(request_with("Bearer #{ApiTokenSecrets::NON_MEMBER}"))

        assert_equal [:membership_required], result.errors
        assert_nil result.data
      end

      test "a lapsed membership turns a working token into :membership_required" do
        users(:regular_user).memberships.update_all(status: :unpaid)

        assert_equal [:membership_required], Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}")).errors
      end

      test "a successful authentication records last use" do
        token = api_tokens(:regular_user_token)
        assert_nil token.last_used_at

        Authenticator.call(request_with("Bearer #{ApiTokenSecrets::MEMBER}"))

        assert_not_nil token.reload.last_used_at
      end

      test "a failed authentication records nothing" do
        Authenticator.call(request_with("Bearer #{ApiTokenSecrets::NON_MEMBER}"))

        assert_nil api_tokens(:non_member_token).reload.last_used_at
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/api/authenticator_test.rb`
Expected: FAIL — `uninitialized constant Services::Api::Authenticator`.

- [ ] **Step 3: Write the principal**

`web-app/app/lib/api/principal.rb`:

```ruby
# frozen_string_literal: true

# Who is calling the API and what they may do. Built only by
# Services::Api::Authenticator; controllers read it and never look at a token.
# When Doorkeeper access tokens arrive for the MCP server, the authenticator
# builds the same struct from them and nothing downstream changes.
module Api
  Principal = Struct.new(:user, :token, :scopes, :tier, keyword_init: true) do
    def scope?(required) = Api::Scopes.satisfies?(scopes, required)
  end
end
```

- [ ] **Step 4: Write the authenticator**

`web-app/app/lib/services/api/authenticator.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Api
    # Turns a request's Authorization header into an ::Api::Principal, or a
    # single failure code the controller maps to an RFC 6750 response:
    #
    #   :unauthenticated     no Authorization header at all       -> 401, `Bearer`
    #   :invalid_token       wrong scheme, malformed, unknown, expired -> 401, `Bearer error="invalid_token"`
    #   :membership_required a person whose membership is not active -> 403, no challenge
    #
    # The only place that knows what a token IS. A session cookie is never
    # consulted: the API is stateless by design.
    #
    # NOTE the root anchor on ::Api::Principal -- inside Services::Api a bare
    # `Api::Principal` resolves to Services::Api::Principal and raises.
    class Authenticator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(request) = new(request).call

      def initialize(request)
        @request = request
      end

      def call
        header = @request.authorization
        return failure(:unauthenticated) if header.blank?

        token = bearer_value(header).then { |secret| secret && ApiToken.authenticate(secret) }
        return failure(:invalid_token) if token.nil?

        user = token.user
        return failure(:membership_required) if user.person? && !user.member?

        token.touch_last_used!
        success(::Api::Principal.new(
          user: user,
          token: token,
          scopes: token.scopes,
          tier: user.service? ? :system : :member
        ))
      end

      private

      def bearer_value(header)
        scheme, value = header.strip.split(/\s+/, 2)
        return nil unless scheme&.casecmp?("Bearer")

        value&.strip.presence
      end

      def success(principal) = Result.new(success?: true, data: principal, errors: [])

      def failure(code) = Result.new(success?: false, data: nil, errors: [code])
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/api/authenticator_test.rb`
Expected: 12 runs, 0 failures.

- [ ] **Step 6: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/lib/api app/lib/services/api test/lib/services/api && CI=1 bin/rails zeitwerk:check`

```bash
git add app/lib/api/principal.rb app/lib/services/api/authenticator.rb test/lib/services/api/authenticator_test.rb
git commit -m "feat(api): bearer authenticator producing an Api::Principal"
```

---

### Task 6: `Services::Api::RateLimiter`

**Files:**
- Create: `web-app/app/lib/services/api/rate_limiter.rb`
- Test: `web-app/test/lib/services/api/rate_limiter_test.rb`

**Interfaces:**
- Consumes: `config.x.api.rate_limits`, `config.x.api.unauthenticated_per_minute` (Task 1); `config.x.rate_limit_store`; `Api::Principal#tier`, `#user` (Task 5).
- Produces: `Services::Api::RateLimiter.hit(principal, now: Time.current)` → `Verdict`; `.hit_unauthenticated(ip, now:)` → `Verdict` (day nil); `.peek_unauthenticated(ip, now:)` → `Verdict` without counting. `Verdict#minute`, `#day` (each a `Window(limit:, remaining:, reset_at:, exceeded:)` with `#exceeded?`), `Verdict#exceeded?`, `Verdict#retry_after(now)` → Integer seconds or nil.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/services/api/rate_limiter_test.rb`:

```ruby
require "test_helper"

module Services
  module Api
    class RateLimiterTest < ActiveSupport::TestCase
      NOW = Time.utc(2026, 9, 13, 10, 30, 15)

      setup do
        @store = ActiveSupport::Cache::MemoryStore.new
        @config = ActiveSupport::OrderedOptions.new
        @config.rate_limits = {member: {per_minute: 3, per_day: 5}, system: {per_minute: 10, per_day: 20}}
        @config.unauthenticated_per_minute = 2
        @member = ::Api::Principal.new(user: users(:regular_user), token: nil, scopes: [], tier: :member)
        @system = ::Api::Principal.new(user: users(:agent_runner_service_account), token: nil, scopes: [], tier: :system)
      end

      def limiter(now: NOW) = RateLimiter.new(now: now, store: @store, config: @config)

      test "the first hit reports the tier's limits with one consumed" do
        verdict = limiter.hit(@member)

        assert_equal 3, verdict.minute.limit
        assert_equal 2, verdict.minute.remaining
        assert_equal Time.utc(2026, 9, 13, 10, 31, 0), verdict.minute.reset_at
        assert_equal 5, verdict.day.limit
        assert_equal 4, verdict.day.remaining
        assert_equal Time.utc(2026, 9, 14, 0, 0, 0), verdict.day.reset_at
        refute verdict.exceeded?
        assert_nil verdict.retry_after(NOW)
      end

      test "the request that crosses the minute limit is exceeded and still counts" do
        3.times { limiter.hit(@member) }

        verdict = limiter.hit(@member)

        assert verdict.minute.exceeded?
        assert verdict.exceeded?
        assert_equal 0, verdict.minute.remaining
        assert_equal 45, verdict.retry_after(NOW)

        again = limiter.hit(@member)
        assert again.exceeded?
        assert_equal 0, again.minute.remaining
      end

      test "a new minute resets the minute window but not the day" do
        3.times { limiter.hit(@member) }
        assert limiter.hit(@member).exceeded?

        verdict = limiter(now: NOW + 60).hit(@member)

        refute verdict.minute.exceeded?
        assert_equal 2, verdict.minute.remaining
        assert_equal 0, verdict.day.remaining
        assert verdict.day.exceeded?
      end

      test "the day window resets at midnight UTC" do
        5.times { limiter.hit(@member) }

        verdict = limiter(now: Time.utc(2026, 9, 14, 0, 0, 1)).hit(@member)

        assert_equal 4, verdict.day.remaining
        assert_equal Time.utc(2026, 9, 15), verdict.day.reset_at
      end

      test "retry_after is the seconds until the earliest exceeded window resets" do
        5.times { limiter.hit(@member) }
        verdict = limiter(now: NOW + 120).hit(@member)

        assert verdict.day.exceeded?
        refute verdict.minute.exceeded?
        assert_equal (Time.utc(2026, 9, 14) - (NOW + 120)).to_i, verdict.retry_after(NOW + 120)
      end

      test "windows are keyed on the user, so two principals do not share a bucket" do
        3.times { limiter.hit(@member) }
        other = ::Api::Principal.new(user: users(:editor_user), token: nil, scopes: [], tier: :member)

        refute limiter.hit(other).exceeded?
      end

      test "the system tier reads its own limits" do
        verdict = limiter.hit(@system)

        assert_equal 10, verdict.minute.limit
        assert_equal 20, verdict.day.limit
      end

      test "unauthenticated hits use the IP window and have no day window" do
        verdict = limiter.hit_unauthenticated("203.0.113.9")

        assert_equal 2, verdict.minute.limit
        assert_equal 1, verdict.minute.remaining
        assert_nil verdict.day

        limiter.hit_unauthenticated("203.0.113.9")
        assert limiter.hit_unauthenticated("203.0.113.9").exceeded?
        refute limiter.hit_unauthenticated("203.0.113.10").exceeded?
      end

      test "peek_unauthenticated reports without counting" do
        assert_equal 2, limiter.peek_unauthenticated("203.0.113.9").minute.remaining
        assert_equal 2, limiter.peek_unauthenticated("203.0.113.9").minute.remaining

        2.times { limiter.hit_unauthenticated("203.0.113.9") }

        peek = limiter.peek_unauthenticated("203.0.113.9")
        assert peek.exceeded?
        assert_equal 0, peek.minute.remaining
      end

      test "the class methods use the app's store and config" do
        verdict = RateLimiter.hit(@member)

        assert_equal Rails.application.config.x.api.rate_limits[:member][:per_minute], verdict.minute.limit
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/services/api/rate_limiter_test.rb`
Expected: FAIL — `uninitialized constant Services::Api::RateLimiter`.

- [ ] **Step 3: Write the limiter**

`web-app/app/lib/services/api/rate_limiter.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Api
    # Fixed-window counters for the public API on the same store the site's
    # `rate_limit` macros use (config.x.rate_limit_store: Redis in production,
    # a real MemoryStore in test -- see config/initializers/rate_limit_store.rb
    # for why a null store would make every limit test pass vacuously).
    #
    # Keyed on the USER, never the token: minting more tokens must not multiply
    # quota. Two windows per tier -- a calendar minute and a UTC calendar day --
    # plus a per-IP minute window for unauthenticated failures.
    #
    # Not DistributedRateLimiter: that is a blocking sliding-window limiter for
    # OUTBOUND calls to third-party APIs. This one answers with the numbers the
    # X-RateLimit-* headers need.
    class RateLimiter
      Window = Struct.new(:limit, :remaining, :reset_at, :exceeded, keyword_init: true) do
        def exceeded? = exceeded
      end

      Verdict = Struct.new(:minute, :day, keyword_init: true) do
        def windows = [minute, day].compact

        def exceeded? = windows.any?(&:exceeded?)

        # Seconds until the earliest exceeded window resets -- what Retry-After
        # carries. nil when nothing is exceeded.
        def retry_after(now = Time.current)
          reset = windows.select(&:exceeded?).map(&:reset_at).min
          reset && [(reset - now).ceil, 1].max
        end
      end

      def self.hit(principal, now: Time.current) = new(now: now).hit(principal)

      def self.hit_unauthenticated(ip, now: Time.current) = new(now: now).hit_unauthenticated(ip)

      def self.peek_unauthenticated(ip, now: Time.current) = new(now: now).peek_unauthenticated(ip)

      def initialize(now: Time.current, store: Rails.application.config.x.rate_limit_store, config: Rails.application.config.x.api)
        @now = now
        @store = store
        @config = config
      end

      # Counts this request against both of the principal's windows. A request
      # that exceeds a window still counts: hammering a 429 does not help.
      def hit(principal)
        limits = config.rate_limits.fetch(principal.tier)
        subject = "u:#{principal.user.id}"

        Verdict.new(
          minute: increment(minute_key(subject), limits.fetch(:per_minute), minute_end),
          day: increment(day_key(subject), limits.fetch(:per_day), day_end)
        )
      end

      def hit_unauthenticated(ip)
        Verdict.new(minute: increment(minute_key("anon:#{ip}"), config.unauthenticated_per_minute, minute_end), day: nil)
      end

      # Reads the IP window without counting, so a request from an address that
      # is already over the limit can be refused before the database is consulted.
      def peek_unauthenticated(ip)
        limit = config.unauthenticated_per_minute
        count = store.read(minute_key("anon:#{ip}"), raw: true).to_i

        Verdict.new(
          minute: Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: minute_end, exceeded: count >= limit),
          day: nil
        )
      end

      private

      attr_reader :now, :store, :config

      def minute_start = Time.at(now.to_i - (now.to_i % 60)).utc

      def minute_end = minute_start + 60

      def day_end = now.utc.beginning_of_day + 1.day

      def minute_key(subject) = "api:rl:#{subject}:m:#{minute_start.to_i}"

      def day_key(subject) = "api:rl:#{subject}:d:#{now.utc.to_date.iso8601}"

      # increment creates the key with the expiry when it is new, and returns the
      # new count. One second of slack so a key never outlives its window by
      # less than the clock granularity.
      def increment(key, limit, reset_at)
        count = store.increment(key, 1, expires_in: (reset_at - now).ceil + 1)
        Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: reset_at, exceeded: count > limit)
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/api/rate_limiter_test.rb`
Expected: 10 runs, 0 failures. If `store.read(key, raw: true)` returns nil on MemoryStore after an `increment`, change `peek_unauthenticated` to `store.read(minute_key(…)).to_i` and add a comment that RedisCacheStore stores incremented values raw and `read` handles both.

- [ ] **Step 5: Lint and commit**

Run: `bundle exec standardrb app/lib/services/api/rate_limiter.rb test/lib/services/api/rate_limiter_test.rb`

```bash
git add app/lib/services/api/rate_limiter.rb test/lib/services/api/rate_limiter_test.rb
git commit -m "feat(api): account-keyed fixed-window rate limiter with header data"
```

---

### Task 7: `Api::Host`, `Api::Problem`, `Api::Page`

**Files:**
- Create: `web-app/app/lib/api/host.rb`, `web-app/app/lib/api/problem.rb`, `web-app/app/lib/api/page.rb`
- Test: `web-app/test/lib/api/host_test.rb`, `web-app/test/lib/api/problem_test.rb`, `web-app/test/lib/api/page_test.rb`

**Interfaces:**
- Produces: `Api::Host.base_url(domain = Current.domain)` → `"https://dev-new.thegreatestbooks.org"`; `Api::Problem.new(code, detail: nil)` with `#status`, `#title`, `#to_h`, `Api::Problem::CONTENT_TYPE`, `Api::Problem::CODES`; `Api::Page.from_params(params, total_count:)` with `#page`, `#per_page`, `#offset`, `#total_pages`, `#next_page`, `#prev_page`, `#meta`, `#links(base_url)`; `Api::Page::InvalidParameter`.

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/host_test.rb`:

```ruby
require "test_helper"

module Api
  class HostTest < ActiveSupport::TestCase
    test "base_url is https on the configured host for the current domain" do
      Current.domain = :books
      assert_equal "https://dev-new.thegreatestbooks.org", Host.base_url

      Current.domain = :music
      assert_equal "https://dev.thegreatestmusic.org", Host.base_url
    end

    test "an explicit domain wins over Current" do
      Current.domain = :books
      assert_equal "https://dev.thegreatest.games", Host.base_url(:games)
    end

    test "a comma-separated domain setting uses its first host" do
      Rails.application.config.stubs(:domains).returns(books: "a.example.org,b.example.org")

      assert_equal "https://a.example.org", Host.base_url(:books)
    end

    test "no current domain falls back to books, the same default the site uses" do
      Current.domain = nil
      assert_equal "https://dev-new.thegreatestbooks.org", Host.base_url
    end
  end
end
```

`web-app/test/lib/api/problem_test.rb`:

```ruby
require "test_helper"

module Api
  class ProblemTest < ActiveSupport::TestCase
    setup { Current.domain = :books }

    test "every code has a status and a title" do
      Problem::CODES.each do |code|
        problem = Problem.new(code)
        assert_kind_of Integer, problem.status
        assert problem.title.present?, "#{code} has no title"
      end
    end

    test "the statuses match RFC 6750 and the spec" do
      assert_equal 401, Problem.new(:unauthenticated).status
      assert_equal 401, Problem.new(:invalid_token).status
      assert_equal 403, Problem.new(:membership_required).status
      assert_equal 403, Problem.new(:insufficient_scope).status
      assert_equal 404, Problem.new(:not_found).status
      assert_equal 400, Problem.new(:invalid_parameter).status
      assert_equal 429, Problem.new(:rate_limited).status
    end

    test "to_h is an RFC 9457 body with a stable code and a type on this host's docs page" do
      body = Problem.new(:rate_limited, detail: "Slow down.").to_h

      assert_equal "https://dev-new.thegreatestbooks.org/developers#errors-rate_limited", body[:type]
      assert_equal "Rate limit exceeded", body[:title]
      assert_equal 429, body[:status]
      assert_equal "rate_limited", body[:code]
      assert_equal "Slow down.", body[:detail]
    end

    test "detail is omitted, not null, when absent" do
      refute Problem.new(:not_found).to_h.key?(:detail)
    end

    test "an unknown code raises at construction" do
      assert_raises(KeyError) { Problem.new(:teapot) }
    end
  end
end
```

`web-app/test/lib/api/page_test.rb`:

```ruby
require "test_helper"

module Api
  class PageTest < ActiveSupport::TestCase
    def params(hash = {}) = ActionController::Parameters.new(hash)

    test "defaults to page 1 of 50" do
      page = Page.from_params(params, total_count: 120)

      assert_equal 1, page.page
      assert_equal 50, page.per_page
      assert_equal 0, page.offset
      assert_equal 3, page.total_pages
      assert_equal 2, page.next_page
      assert_nil page.prev_page
    end

    test "reads page and per_page from strings" do
      page = Page.from_params(params(page: "3", per_page: "25"), total_count: 120)

      assert_equal 3, page.page
      assert_equal 25, page.per_page
      assert_equal 50, page.offset
      assert_equal 5, page.total_pages
      assert_equal 4, page.next_page
      assert_equal 2, page.prev_page
    end

    test "an empty collection is one page with no neighbours" do
      page = Page.from_params(params, total_count: 0)

      assert_equal 1, page.total_pages
      assert_nil page.next_page
      assert_nil page.prev_page
    end

    test "a page past the end is allowed and points back at the last page" do
      page = Page.from_params(params(page: "99"), total_count: 120)

      assert_equal 99, page.page
      assert_nil page.next_page
      assert_equal 3, page.prev_page
    end

    test "rejects non-integers and out-of-range values with a message naming the parameter" do
      error = assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "abc"), total_count: 1) }
      assert_match(/page must be an integer 1 or greater/, error.message)

      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "0"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "-1"), total_count: 1) }
      assert_raises(Page::InvalidParameter) { Page.from_params(params(page: "1.5"), total_count: 1) }

      error = assert_raises(Page::InvalidParameter) { Page.from_params(params(per_page: "101"), total_count: 1) }
      assert_match(/per_page must be an integer between 1 and 100/, error.message)
      assert_raises(Page::InvalidParameter) { Page.from_params(params(per_page: "0"), total_count: 1) }
    end

    test "meta and links" do
      page = Page.from_params(params(page: "2", per_page: "10"), total_count: 35)

      assert_equal({page: 2, per_page: 10, total_count: 35, total_pages: 4}, page.meta)
      assert_equal(
        {
          self: "https://x.test/api/v1/books?page=2&per_page=10",
          next: "https://x.test/api/v1/books?page=3&per_page=10",
          prev: "https://x.test/api/v1/books?page=1&per_page=10",
          first: "https://x.test/api/v1/books?page=1&per_page=10",
          last: "https://x.test/api/v1/books?page=4&per_page=10"
        },
        page.links("https://x.test/api/v1/books")
      )
    end

    test "links carry nulls, not missing keys, when there is no next or prev" do
      links = Page.from_params(params, total_count: 3).links("https://x.test/api/v1/books")

      assert links.key?(:next)
      assert_nil links[:next]
      assert_nil links[:prev]
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/api/host_test.rb test/lib/api/problem_test.rb test/lib/api/page_test.rb`
Expected: FAIL — uninitialized constants.

- [ ] **Step 3: Write `Api::Host`**

`web-app/app/lib/api/host.rb`:

```ruby
# frozen_string_literal: true

# The canonical absolute origin for the current site. Every URL the API emits
# is built from here, never from request.host: in production config.hosts is
# unset and nginx forwards the raw Host header, so request.host is whatever the
# client sent. config.domains is the same source config/routes.rb constrains on.
module Api
  module Host
    def self.base_url(domain = Current.domain)
      # :books is also ApplicationController#detect_current_domain's fallback.
      host = Rails.application.config.domains.fetch(domain || :books).split(",").first
      "https://#{host}"
    end
  end
end
```

- [ ] **Step 4: Write `Api::Problem`**

`web-app/app/lib/api/problem.rb`:

```ruby
# frozen_string_literal: true

# RFC 9457 Problem Details, one per error code the API can answer with. The
# `code` member is the stable machine-readable string clients switch on; `type`
# points at that code's section on this host's /developers page (which ships
# in increment 3 -- a type URI is an identifier first and a link second).
#
# 500s are deliberately not here: an unexpected exception is a bug, and the
# base controller lets it reach Rails' handler (a generic JSON 500) rather than
# dressing it up.
module Api
  class Problem
    CONTENT_TYPE = "application/problem+json"

    DEFINITIONS = {
      unauthenticated: [401, "Authentication required"],
      invalid_token: [401, "Invalid token"],
      membership_required: [403, "Membership required"],
      insufficient_scope: [403, "Insufficient scope"],
      not_found: [404, "Not found"],
      invalid_parameter: [400, "Invalid parameter"],
      rate_limited: [429, "Rate limit exceeded"]
    }.freeze

    CODES = DEFINITIONS.keys.freeze

    attr_reader :code, :status, :title, :detail

    def initialize(code, detail: nil)
      @code = code.to_sym
      @status, @title = DEFINITIONS.fetch(@code)
      @detail = detail
    end

    def to_h
      {
        type: "#{Host.base_url}/developers#errors-#{code}",
        title: title,
        status: status,
        code: code.to_s,
        detail: detail
      }.compact
    end
  end
end
```

- [ ] **Step 5: Write `Api::Page`**

`web-app/app/lib/api/page.rb`:

```ruby
# frozen_string_literal: true

# Offset pagination for API collections: parses and validates `page` and
# `per_page`, and produces the `meta` and `links` members of a collection
# envelope. A page past the end is legal and empty -- what an iterating client
# expects -- which matches the empty-page behaviour Pagy gives the site.
#
# Not Pagy itself: the site's helper reads the page from the request and 404s
# past the end; the API validates its own parameters and answers 400 with a
# problem body naming the offender.
module Api
  class Page
    class InvalidParameter < StandardError; end

    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 100

    attr_reader :page, :per_page, :total_count

    def self.from_params(params, total_count:)
      new(
        page: integer(params[:page], name: "page", default: 1, min: 1),
        per_page: integer(params[:per_page], name: "per_page", default: DEFAULT_PER_PAGE, min: 1, max: MAX_PER_PAGE),
        total_count: total_count
      )
    end

    def self.integer(raw, name:, default:, min:, max: nil)
      return default if raw.nil?

      value = Integer(raw.to_s, 10, exception: false)
      in_range = value && value >= min && (max.nil? || value <= max)
      return value if in_range

      range = max ? "between #{min} and #{max}" : "#{min} or greater"
      raise InvalidParameter, "#{name} must be an integer #{range}"
    end

    def initialize(page:, per_page:, total_count:)
      @page = page
      @per_page = per_page
      @total_count = total_count
    end

    def offset = (page - 1) * per_page

    def total_pages = [(total_count.to_f / per_page).ceil, 1].max

    def next_page = (page < total_pages) ? page + 1 : nil

    def prev_page = (page > 1) ? [page - 1, total_pages].min : nil

    def meta = {page: page, per_page: per_page, total_count: total_count, total_pages: total_pages}

    def links(base_url)
      {
        self: url(base_url, page),
        next: next_page && url(base_url, next_page),
        prev: prev_page && url(base_url, prev_page),
        first: url(base_url, 1),
        last: url(base_url, total_pages)
      }
    end

    private

    def url(base_url, number) = "#{base_url}?page=#{number}&per_page=#{per_page}"
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/host_test.rb test/lib/api/problem_test.rb test/lib/api/page_test.rb`
Expected: 16 runs, 0 failures.

- [ ] **Step 7: Lint and commit**

Run: `bundle exec standardrb app/lib/api test/lib/api`

```bash
git add app/lib/api/host.rb app/lib/api/problem.rb app/lib/api/page.rb test/lib/api/host_test.rb test/lib/api/problem_test.rb test/lib/api/page_test.rb
git commit -m "feat(api): Host, Problem (RFC 9457) and Page value objects"
```

---

### Task 8: Extract `CurrentDomain` from `ApplicationController`

**Files:**
- Create: `web-app/app/controllers/concerns/current_domain.rb`
- Modify: `web-app/app/controllers/application_controller.rb`
- Test: `web-app/test/controllers/current_domain_test.rb`

**Interfaces:**
- Produces: `CurrentDomain` concern — `before_action :set_current_domain`; private `current_domain`, `domain_settings`; sets `Current.domain`. Works in both `ActionController::Base` (with `helper_method`) and `ActionController::API` (without).

- [ ] **Step 1: Write the failing test**

`web-app/test/controllers/current_domain_test.rb`:

```ruby
require "test_helper"

class CurrentDomainTest < ActionDispatch::IntegrationTest
  test "a books host sets Current.domain to books" do
    host! "dev-new.thegreatestbooks.org"
    get "/privacy_policy"

    assert_response :success
    assert_equal :books, @controller.send(:current_domain)
    assert_equal "The Greatest Books", @controller.send(:domain_settings)[:name]
  end

  test "a music host sets Current.domain to music" do
    host! "dev.thegreatestmusic.org"
    get "/privacy_policy"

    assert_response :success
    assert_equal :music, @controller.send(:current_domain)
  end

  test "the concern is what ApplicationController uses" do
    assert_includes ApplicationController.ancestors, CurrentDomain
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/current_domain_test.rb`
Expected: the third test FAILS (`uninitialized constant CurrentDomain`).

- [ ] **Step 3: Write the concern**

`web-app/app/controllers/concerns/current_domain.rb`:

```ruby
# frozen_string_literal: true

# Resolves which site a request is for from its host and publishes it as
# Current.domain. Shared by ApplicationController (HTML) and Api::V1::BaseController
# (JSON), which is why it does not assume ActionController::Base: helper_method
# only exists on the HTML side.
#
# Unrecognised hosts fall back to :books. In production config.hosts is unset,
# so request.host is client-supplied -- nothing here should ever be used to
# build a URL (see Api::Host and the routes file for the canonical source).
module CurrentDomain
  extend ActiveSupport::Concern

  included do
    before_action :set_current_domain
    helper_method :current_domain, :domain_settings if respond_to?(:helper_method)
  end

  private

  attr_reader :current_domain, :domain_settings

  def set_current_domain
    @current_domain = detect_current_domain
    @domain_settings = Rails.application.config.domain_settings[@current_domain]
    Current.domain = @current_domain

    # Debug logging
    Rails.logger.info "Host: #{request.host}"
    Rails.logger.info "Detected domain: #{@current_domain}"
    Rails.logger.info "Domain settings: #{@domain_settings}"
  end

  def detect_current_domain
    host = request.host

    Rails.application.config.domains.each do |domain, configured|
      return domain if configured.split(",").include?(host)
    end

    :books # default for unrecognized hosts
  end
end
```

- [ ] **Step 4: Rewire `ApplicationController`**

In `web-app/app/controllers/application_controller.rb`:

1. Add `include CurrentDomain` immediately after `include RankingConfigurationGating`.
2. Delete `before_action :set_current_domain`.
3. Delete the private `set_current_domain` and `detect_current_domain` methods, the two `attr_reader` lines (`:current_domain`, `:domain_settings`) and the `helper_method :current_domain, :domain_settings` line.

Nothing else changes. `helper_method :current_user, :signed_in?` stays.

- [ ] **Step 5: Run the test plus the broad controller suite**

Run: `bin/rails test test/controllers/current_domain_test.rb && bin/rails test test/controllers test/components test/views`
Expected: all green — behaviour is unchanged, only its location.

- [ ] **Step 6: Lint and commit**

Run: `bundle exec standardrb app/controllers/concerns/current_domain.rb app/controllers/application_controller.rb test/controllers/current_domain_test.rb`

```bash
git add app/controllers/concerns/current_domain.rb app/controllers/application_controller.rb test/controllers/current_domain_test.rb
git commit -m "refactor: extract CurrentDomain concern so the API base can share it"
```

---

### Task 9: Alba resources for books

**Files:**
- Create: `web-app/app/lib/api/v1/books/author_summary_resource.rb`, `web-app/app/lib/api/v1/books/book_resource.rb`
- Test: `web-app/test/lib/api/v1/books/book_resource_test.rb`

**Interfaces:**
- Consumes: `Api::Host.base_url` (Task 7); `rails_public_blob_url` direct route; `::Books::Book` associations `book_authors`(ordered)→`author`, `primary_image`→`file`, `categories`, `countries`, `original_language`, `primary_description(kind: :summary)`, `primary_ranked_item`.
- Produces: `Api::V1::Books::AuthorSummaryResource.new(author).to_h` → `{id:, slug:, name:}`; `Api::V1::Books::BookResource.new(book, params: {rank: Integer|nil}).to_h` (compact) and `.new(book, with_traits: :full).to_h` (full). Key order and names are the contract in `openapi.yaml` (Task 11).

- [ ] **Step 1: Write the failing tests**

`web-app/test/lib/api/v1/books/book_resource_test.rb`:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class BookResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @book = books_books(:war_and_peace)
        end

        test "compact shape" do
          hash = BookResource.new(@book, params: {rank: 7}).to_h

          assert_equal(
            %i[id slug title subtitle first_published_year rank authors cover_url url api_url],
            hash.keys
          )
          assert_equal @book.id, hash[:id]
          assert_equal "war-and-peace", hash[:slug]
          assert_equal "War and Peace", hash[:title]
          assert_nil hash[:subtitle]
          assert_equal 1869, hash[:first_published_year]
          assert_equal 7, hash[:rank]
          assert_equal [{id: books_authors(:tolstoy).id, slug: "leo-tolstoy", name: "Leo Tolstoy"}], hash[:authors]
          assert_nil hash[:cover_url]
          assert_equal "https://dev-new.thegreatestbooks.org/book/war-and-peace", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books/war-and-peace", hash[:api_url]
        end

        test "rank falls back to the primary ranking when not supplied" do
          RankedItem.create!(item: @book, ranking_configuration: ranking_configurations(:books_global), rank: 3, score: 90)

          assert_equal 3, BookResource.new(@book).to_h[:rank]
        end

        test "rank is null for an unranked book" do
          assert_nil BookResource.new(@book).to_h[:rank]
        end

        test "a rank of nil passed explicitly stays nil" do
          assert_nil BookResource.new(@book, params: {rank: nil}).to_h[:rank]
        end

        test "authors are in position order" do
          second = books_authors(:garnett)
          ::Books::BookAuthor.create!(book: @book, author: second, position: 2, role: 0)

          assert_equal ["leo-tolstoy", second.slug], BookResource.new(@book.reload).to_h[:authors].map { |a| a[:slug] }
        end

        test "cover_url is the CDN URL of the primary image" do
          file = stub(attached?: true, key: "covers/abc123.jpg")
          @book.stubs(:primary_image).returns(stub(file: file))

          assert_equal "https://images-dev.thegreatestbooks.org/covers/abc123.jpg", BookResource.new(@book).to_h[:cover_url]
        end

        test "full trait adds the detail fields in order" do
          hash = BookResource.new(@book, with_traits: :full).to_h

          assert_equal(
            %i[id slug title subtitle first_published_year rank authors cover_url url api_url
              sort_title alternate_titles book_kind book_length page_range word_count description
              original_language categories countries],
            hash.keys
          )
          assert_equal ["Voyna i mir"], hash[:alternate_titles]
          assert_equal "standalone", hash[:book_kind]
          assert_nil hash[:book_length]
          assert_nil hash[:description]
          language = languages(:russian)
          assert_equal({id: language.id, slug: language.slug, name: language.name}, hash[:original_language])
          assert_equal [], hash[:categories]
          assert_equal [], hash[:countries]
        end

        test "full trait resolves the primary summary description" do
          @book.assign_description(source: :openai, content: "A long Russian novel.", kind: :summary)
          @book.save!

          assert_equal "A long Russian novel.", BookResource.new(@book.reload, with_traits: :full).to_h[:description]
        end

        test "full trait lists active categories and countries with slugs" do
          category = ::Books::Category.create!(name: "Novel", category_type: :genre)
          deleted = ::Books::Category.create!(name: "Gone", category_type: :genre, deleted: true)
          CategoryItem.create!(category: category, item: @book)
          CategoryItem.create!(category: deleted, item: @book)
          country = ::Books::Country.create!(name: "Russia", slug: "russia")
          ::Books::BookCountry.create!(book: @book, country: country)

          hash = BookResource.new(@book.reload, with_traits: :full).to_h

          assert_equal [{id: category.id, slug: category.slug, name: "Novel", category_type: "genre"}], hash[:categories]
          assert_equal [{id: country.id, slug: "russia", name: "Russia"}], hash[:countries]
        end
      end
    end
  end
end
```

Check the fixture names used here exist before running: `grep -n '^russian:' test/fixtures/languages.yml`, `grep -n '^garnett:' test/fixtures/books/authors.yml`. If `languages(:russian)` does not exist, find the language fixture `war_and_peace` references (`original_language: russian` in `test/fixtures/books/books.yml`) and use that name. If `Books::Category.create!`/`Books::Country.create!` need more attributes than shown, read the model validations and supply them — do not weaken the assertions.

- [ ] **Step 2: Run to verify they fail**

Run: `bin/rails test test/lib/api/v1/books/book_resource_test.rb`
Expected: FAIL — `uninitialized constant Api::V1::Books::BookResource`.

- [ ] **Step 3: Write the author summary resource**

`web-app/app/lib/api/v1/books/author_summary_resource.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # The author as embedded in a book: enough to display and to follow.
      # The author index/show (increment 2) gets its own AuthorResource.
      class AuthorSummaryResource
        include Alba::Resource

        attributes :id, :slug, :name
      end
    end
  end
end
```

- [ ] **Step 4: Write the book resource**

`web-app/app/lib/api/v1/books/book_resource.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # The book as the API presents it. Compact by default (the index), with a
      # :full trait for show. Key order here IS the order in config/api/v1/openapi.yaml.
      #
      # Every model reference is root-anchored: inside Api::V1::Books a bare
      # `Books::Book` resolves to Api::V1::Books::Book and raises NameError.
      #
      # `params[:rank]` lets the index pass the rank it already has from the
      # RankedItem row instead of triggering a query per book; show omits it and
      # the resource reads the primary ranking itself.
      class BookResource
        include Alba::Resource

        attributes :id, :slug, :title, :subtitle, :first_published_year

        attribute :rank do |book|
          params.key?(:rank) ? params[:rank] : book.primary_ranked_item&.rank
        end

        # book_authors, not authors: the through association would not use the
        # preloaded rows, and book_authors carries the position order.
        attribute :authors do |book|
          book.book_authors.map { |book_author| AuthorSummaryResource.new(book_author.author).to_h }
        end

        attribute :cover_url do |book|
          file = book.primary_image&.file
          file&.attached? ? Rails.application.routes.url_helpers.rails_public_blob_url(file) : nil
        end

        attribute :url do |book|
          "#{::Api::Host.base_url}/book/#{book.slug}"
        end

        attribute :api_url do |book|
          "#{::Api::Host.base_url}/api/v1/books/#{book.slug}"
        end

        trait :full do
          attributes :sort_title, :alternate_titles, :book_kind, :book_length, :page_range, :word_count

          attribute :description do |book|
            book.primary_description(kind: :summary)&.content
          end

          attribute :original_language do |book|
            language = book.original_language
            language && {id: language.id, slug: language.slug, name: language.name}
          end

          # reject(&:deleted?) on the preloaded rows rather than the .active scope,
          # which would issue a fresh query per book.
          attribute :categories do |book|
            book.categories.reject(&:deleted?).map do |category|
              {id: category.id, slug: category.slug, name: category.name, category_type: category.category_type}
            end
          end

          attribute :countries do |book|
            book.countries.map { |country| {id: country.id, slug: country.slug, name: country.name} }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/lib/api/v1/books/book_resource_test.rb`
Expected: 9 runs, 0 failures. Two things to check if not:
- Alba 4 may return string keys from `to_h`; if so, switch the resource to symbol keys per Alba's docs (`Alba.symbolize_keys!` in `config/initializers/alba.rb`, or the resource-level equivalent) and keep the tests as written — symbol keys are what `render json:` handles cleanly either way.
- If `trait` is unavailable, the installed Alba is below 3.5; `bundle update alba` and re-check `Alba::VERSION`.

- [ ] **Step 6: Lint, zeitwerk, commit**

Run: `bundle exec standardrb app/lib/api/v1 test/lib/api/v1 && CI=1 bin/rails zeitwerk:check`

```bash
git add app/lib/api/v1 test/lib/api/v1 config/initializers/alba.rb
git commit -m "feat(api): Alba resources for books with a :full trait"
```

(`git add config/initializers/alba.rb` only if that file was needed.)

---

### Task 10: Routes, base controller, concerns, `BooksController`

**Files:**
- Create: `web-app/app/controllers/concerns/api/authentication.rb`, `web-app/app/controllers/concerns/api/rate_limited.rb`, `web-app/app/controllers/concerns/api/error_rendering.rb`, `web-app/app/controllers/api/v1/base_controller.rb`, `web-app/app/controllers/api/v1/books/base_controller.rb`, `web-app/test/support/api_conformance.rb`
- Create (generator): `web-app/app/controllers/api/v1/books/books_controller.rb`, `web-app/test/controllers/api/v1/books/books_controller_test.rb`
- Modify: `web-app/config/routes.rb`, `web-app/test/test_helper.rb`

**Interfaces:**
- Consumes: everything from Tasks 5–9.
- Produces: `GET /api/v1/books`, `GET /api/v1/books/:slug` on the books host; `Api::V1::BaseController` with `self.require_scope(scope)`, `current_principal`, `render_problem(problem, www_authenticate: nil)`, `render_ranked_page(relation, path:) { |ranked_item| hash }`; test helper `bearer(secret)` → headers hash.

- [ ] **Step 1: Routes**

In `web-app/config/routes.rb`, inside `constraints DomainConstraint.new(Rails.application.config.domains[:books]) do` (line ~582), as the **first** thing in that block:

```ruby
    # Public API, books resources. JSON only: `defaults` means no extension is
    # needed, `constraints` means /api/v1/books.xml matches nothing (a routing
    # 404, not a 406). Domain comes from the host, like everything else.
    # Spec: docs/superpowers/specs/2026-09-12-public-api-framework-design.md
    namespace :api, defaults: {format: :json}, constraints: {format: :json} do
      namespace :v1 do
        scope module: :books do
          resources :books, only: [:index, :show], param: :slug
        end
      end
    end
```

Run: `bin/rails routes -g 'api/v1'`
Expected:
```
api_v1_books GET /api/v1/books(.:format)       api/v1/books/books#index {format: :json}
 api_v1_book GET /api/v1/books/:slug(.:format) api/v1/books/books#show {format: :json}
```

- [ ] **Step 2: Generate the controller**

Run:
```bash
bin/rails generate controller api/v1/books/books index show --skip-routes --no-helper -e none --parent=Api::V1::Books::BaseController
```
Expected: `app/controllers/api/v1/books/books_controller.rb` and `test/controllers/api/v1/books/books_controller_test.rb`. Delete any `app/views/api/` directory the generator created.

- [ ] **Step 3: The test support helpers**

`web-app/test/support/api_conformance.rb`:

```ruby
# Helpers for API integration tests.
module ApiConformance
  def bearer(secret) = {"Authorization" => "Bearer #{secret}"}

  # Validates only the RESPONSE against the OpenAPI document. For the tests
  # that deliberately send an invalid request (page=0) -- assert_api_conform
  # would fail on the request half, which is the point of the test.
  # Defined in Task 11 once openapi_first is wired up; until then this is a
  # status assertion only.
  def assert_api_response_conform(status:)
    assert_equal status, response.status
  end
end

module ActionDispatch
  class IntegrationTest
    include ApiConformance
  end
end
```

In `web-app/test/test_helper.rb`, after `require_relative "support/api_token_secrets"`:

```ruby
require_relative "support/api_conformance"
```

- [ ] **Step 4: Write the failing controller tests**

Replace `web-app/test/controllers/api/v1/books/books_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    module Books
      class BooksControllerTest < ActionDispatch::IntegrationTest
        RATE_HEADERS = %w[X-RateLimit-Limit X-RateLimit-Remaining X-RateLimit-Reset
          X-RateLimit-Daily-Limit X-RateLimit-Daily-Remaining X-RateLimit-Daily-Reset].freeze

        setup do
          host! "dev-new.thegreatestbooks.org"
          @rc = ranking_configurations(:books_global)
          @war_and_peace = books_books(:war_and_peace)
          @crime = books_books(:crime_and_punishment)
          @mice = books_books(:of_mice_and_men)
          RankedItem.create!(item: @war_and_peace, ranking_configuration: @rc, rank: 1, score: 100)
          RankedItem.create!(item: @crime, ranking_configuration: @rc, rank: 2, score: 90)
          RankedItem.create!(item: @mice, ranking_configuration: @rc, rank: 3, score: 80)
        end

        def json = response.parsed_body.deep_symbolize_keys

        # --- index ---------------------------------------------------------------

        test "index lists ranked books best first with meta and links" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_equal "application/json; charset=utf-8", response.content_type
          assert_equal %w[war-and-peace crime-and-punishment of-mice-and-men], json[:data].map { |b| b[:slug] }
          assert_equal [1, 2, 3], json[:data].map { |b| b[:rank] }
          assert_equal({page: 1, per_page: 50, total_count: 3, total_pages: 1}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books?page=1&per_page=50", json[:links][:self]
          assert_nil json[:links][:next]
        end

        test "index excludes unranked books" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          refute_includes json[:data].map { |b| b[:slug] }, books_books(:got).slug
        end

        test "index paginates" do
          get "/api/v1/books?page=2&per_page=2", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_equal ["of-mice-and-men"], json[:data].map { |b| b[:slug] }
          assert_equal({page: 2, per_page: 2, total_count: 3, total_pages: 2}, json[:meta])
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/books?page=1&per_page=2", json[:links][:prev]
          assert_nil json[:links][:next]
        end

        test "a page past the end is an empty 200" do
          get "/api/v1/books?page=9", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 3, json[:meta][:total_count]
        end

        test "invalid pagination parameters are a 400 problem" do
          {"page=0" => /page/, "page=abc" => /page/, "per_page=101" => /per_page/, "per_page=0" => /per_page/}.each do |query, detail|
            get "/api/v1/books?#{query}", headers: bearer(ApiTokenSecrets::MEMBER)

            assert_response :bad_request, query
            assert_equal "application/problem+json; charset=utf-8", response.content_type
            assert_equal "invalid_parameter", json[:code]
            assert_match detail, json[:detail]
          end
        end

        test "index with no primary ranking configuration is an empty 200" do
          ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)

          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_equal [], json[:data]
          assert_equal 0, json[:meta][:total_count]
        end

        test "index does not N+1 on authors or covers" do
          get "/api/v1/books?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) # warm-up: last_used_at write, schema
          one = capture_sql { get "/api/v1/books?per_page=1", headers: bearer(ApiTokenSecrets::MEMBER) }
          three = capture_sql { get "/api/v1/books?per_page=3", headers: bearer(ApiTokenSecrets::MEMBER) }

          assert_equal one.size, three.size, "query count grew with page size:\n#{three.join("\n")}"
        end

        # --- show ----------------------------------------------------------------

        test "show renders the full book" do
          get "/api/v1/books/#{@war_and_peace.slug}", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_equal "war-and-peace", json[:data][:slug]
          assert_equal 1, json[:data][:rank]
          assert json[:data].key?(:description)
          assert json[:data].key?(:categories)
          assert_equal "https://dev-new.thegreatestbooks.org/book/war-and-peace", json[:data][:url]
        end

        test "show of an unranked book has a null rank" do
          get "/api/v1/books/#{books_books(:got).slug}", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :success
          assert_nil json[:data][:rank]
        end

        test "show of an unknown slug is a 404 problem" do
          get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "not_found", json[:code]
        end

        test "show does not fall back to a primary-key lookup" do
          get "/api/v1/books/#{@war_and_peace.id}", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        test "a non-JSON format is a routing 404" do
          get "/api/v1/books.xml", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
        end

        # --- authentication ------------------------------------------------------

        test "no token is a 401 with a bare Bearer challenge" do
          get "/api/v1/books"

          assert_response :unauthorized
          assert_equal "Bearer", response.headers["WWW-Authenticate"]
          assert_equal "application/problem+json; charset=utf-8", response.content_type
          assert_equal "unauthenticated", json[:code]
          assert_equal 401, json[:status]
        end

        test "an unknown token is a 401 invalid_token" do
          get "/api/v1/books", headers: bearer("tg_#{"z" * 40}")

          assert_response :unauthorized
          assert_equal %(Bearer error="invalid_token"), response.headers["WWW-Authenticate"]
          assert_equal "invalid_token", json[:code]
        end

        test "an expired token is a 401 invalid_token" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::EXPIRED)

          assert_response :unauthorized
          assert_equal "invalid_token", json[:code]
        end

        test "a session cookie without a bearer token is still a 401" do
          sign_in_as(users(:regular_user), stub_auth: true)

          get "/api/v1/books"

          assert_response :unauthorized
        end

        test "a non-member's token is a 403 membership_required with no challenge" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::NON_MEMBER)

          assert_response :forbidden
          assert_nil response.headers["WWW-Authenticate"]
          assert_equal "membership_required", json[:code]
        end

        test "a service account needs no membership and gets the system limits" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::SERVICE)

          assert_response :success
          assert_equal Rails.application.config.x.api.rate_limits[:system][:per_minute].to_s, response.headers["X-RateLimit-Limit"]
        end

        # --- scopes --------------------------------------------------------------

        test "a token without books:read is a 403 insufficient_scope with a scope challenge" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY)

          assert_response :forbidden
          assert_equal %(Bearer error="insufficient_scope", scope="books:read"), response.headers["WWW-Authenticate"]
          assert_equal "insufficient_scope", json[:code]
        end

        # --- rate limiting -------------------------------------------------------

        test "every authenticated response carries the six rate-limit headers" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          RATE_HEADERS.each { |name| assert_match(/\A\d+\z/, response.headers[name].to_s, name) }
          limits = Rails.application.config.x.api.rate_limits[:member]
          assert_equal limits[:per_minute].to_s, response.headers["X-RateLimit-Limit"]
          assert_equal (limits[:per_minute] - 1).to_s, response.headers["X-RateLimit-Remaining"]
          assert_equal limits[:per_day].to_s, response.headers["X-RateLimit-Daily-Limit"]
        end

        test "error responses after authentication carry the headers too" do
          get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :not_found
          RATE_HEADERS.each { |name| assert response.headers[name].present?, name }
        end

        test "a 401 carries only the minute triple, describing the IP window" do
          get "/api/v1/books"

          assert_equal Rails.application.config.x.api.unauthenticated_per_minute.to_s, response.headers["X-RateLimit-Limit"]
          assert response.headers["X-RateLimit-Remaining"].present?
          assert response.headers["X-RateLimit-Reset"].present?
          assert_nil response.headers["X-RateLimit-Daily-Limit"]
        end

        test "exceeding a window is a 429 with Retry-After and the headers" do
          reset_at = 30.seconds.from_now
          minute = Services::Api::RateLimiter::Window.new(limit: 60, remaining: 0, reset_at: reset_at, exceeded: true)
          day = Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 100, reset_at: 1.day.from_now, exceeded: false)
          Services::Api::RateLimiter.stubs(:hit).returns(Services::Api::RateLimiter::Verdict.new(minute: minute, day: day))

          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)

          assert_response :too_many_requests
          assert_match(/\A\d+\z/, response.headers["Retry-After"])
          assert_equal "0", response.headers["X-RateLimit-Remaining"]
          assert_equal "rate_limited", json[:code]
          assert_match(/Per-minute limit of 60/, json[:detail])
        end

        test "too many unauthenticated requests from one address is a 429 before any lookup" do
          limit = Rails.application.config.x.api.unauthenticated_per_minute
          limit.times { get "/api/v1/books", headers: {"CF-Connecting-IP" => "203.0.113.7"} }

          assert_no_queries do
            get "/api/v1/books", headers: {"CF-Connecting-IP" => "203.0.113.7"}
          end

          assert_response :too_many_requests
          assert_equal "rate_limited", json[:code]
          assert response.headers["Retry-After"].present?

          get "/api/v1/books", headers: {"CF-Connecting-IP" => "203.0.113.8"}
          assert_response :unauthorized
        end

        # --- caching -------------------------------------------------------------

        test "responses are never cacheable by a shared cache" do
          get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER)
          assert_equal "private, no-store", response.headers["Cache-Control"]

          get "/api/v1/books"
          assert_equal "private, no-store", response.headers["Cache-Control"]
        end
      end
    end
  end
end
```

`assert_no_queries`: if it is not available in `ActionDispatch::IntegrationTest`, replace with `assert_equal 0, capture_sql { … }.size`.

- [ ] **Step 5: Run to verify they fail**

Run: `bin/rails test test/controllers/api/v1/books/books_controller_test.rb`
Expected: FAIL — `uninitialized constant Api::V1::Books::BaseController` (or similar).

- [ ] **Step 6: Write `Api::ErrorRendering`**

`web-app/app/controllers/concerns/api/error_rendering.rb`:

```ruby
# frozen_string_literal: true

module Api
  # Renders ::Api::Problem bodies and maps the exceptions the API expects onto
  # them. Anything not listed here is a bug and reaches Rails' own handler
  # (a generic JSON 500) -- deliberately not rescued, so tests fail loudly
  # instead of passing against a friendly body.
  module ErrorRendering
    extend ActiveSupport::Concern

    included do
      rescue_from ActiveRecord::RecordNotFound do
        render_problem(::Api::Problem.new(:not_found, detail: "No #{controller_name.singularize} with that slug"))
      end

      rescue_from ::Api::Page::InvalidParameter do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end

      rescue_from ActionController::ParameterMissing do |error|
        render_problem(::Api::Problem.new(:invalid_parameter, detail: error.message))
      end
    end

    private

    def render_problem(problem, www_authenticate: nil)
      response.headers["WWW-Authenticate"] = www_authenticate if www_authenticate
      render json: problem.to_h, status: problem.status, content_type: ::Api::Problem::CONTENT_TYPE
    end
  end
end
```

- [ ] **Step 7: Write `Api::RateLimited`**

`web-app/app/controllers/concerns/api/rate_limited.rb`:

```ruby
# frozen_string_literal: true

module Api
  # Counts the authenticated request against its account's windows and answers
  # 429 when one is exhausted. Headers are set here, in the before_action, so
  # every later render -- success, 404, 429 -- carries them without an
  # after_action. Requires current_principal (Api::Authentication) to have run.
  #
  # apply_rate_limit_headers is also used by Api::Authentication for the
  # unauthenticated IP window; that verdict has no day window and emits only
  # the minute triple.
  module RateLimited
    extend ActiveSupport::Concern

    included do
      before_action :enforce_rate_limit!
    end

    private

    def enforce_rate_limit!
      verdict = Services::Api::RateLimiter.hit(current_principal)
      apply_rate_limit_headers(verdict)
      return unless verdict.exceeded?

      render_rate_limited(verdict)
    end

    def render_rate_limited(verdict)
      retry_after = verdict.retry_after
      response.headers["Retry-After"] = retry_after.to_s
      window = if verdict.minute.exceeded?
        "Per-minute limit of #{verdict.minute.limit}"
      else
        "Daily limit of #{verdict.day.limit}"
      end
      render_problem(::Api::Problem.new(:rate_limited, detail: "#{window} requests reached. Retry after #{retry_after} seconds."))
    end

    def apply_rate_limit_headers(verdict)
      minute = verdict.minute
      response.headers["X-RateLimit-Limit"] = minute.limit.to_s
      response.headers["X-RateLimit-Remaining"] = minute.remaining.to_s
      response.headers["X-RateLimit-Reset"] = minute.reset_at.to_i.to_s

      day = verdict.day
      return if day.nil?

      response.headers["X-RateLimit-Daily-Limit"] = day.limit.to_s
      response.headers["X-RateLimit-Daily-Remaining"] = day.remaining.to_s
      response.headers["X-RateLimit-Daily-Reset"] = day.reset_at.to_i.to_s
    end
  end
end
```

- [ ] **Step 8: Write `Api::Authentication`**

`web-app/app/controllers/concerns/api/authentication.rb`:

```ruby
# frozen_string_literal: true

module Api
  # Resolves the bearer token into current_principal, or halts with an RFC 6750
  # response. Unauthenticated failures count against a per-IP window so junk
  # cannot turn into database load; an address already over that window is
  # refused before any lookup. Requires VisitorIp and Api::RateLimited's
  # apply_rate_limit_headers.
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :authenticate!
    end

    private

    attr_reader :current_principal

    def authenticate!
      peek = Services::Api::RateLimiter.peek_unauthenticated(visitor_ip)
      if peek.exceeded?
        apply_rate_limit_headers(peek)
        return render_rate_limited(peek)
      end

      result = Services::Api::Authenticator.call(request)
      if result.success?
        @current_principal = result.data
        return
      end

      case result.errors.first
      when :membership_required
        render_problem(::Api::Problem.new(
          :membership_required,
          detail: "API access is a membership benefit. Membership covers every site."
        ))
      when :unauthenticated
        apply_rate_limit_headers(Services::Api::RateLimiter.hit_unauthenticated(visitor_ip))
        render_problem(::Api::Problem.new(:unauthenticated, detail: "Send a personal access token as `Authorization: Bearer <token>`."),
          www_authenticate: "Bearer")
      else
        apply_rate_limit_headers(Services::Api::RateLimiter.hit_unauthenticated(visitor_ip))
        render_problem(::Api::Problem.new(:invalid_token, detail: "The token is malformed, unknown, revoked or expired."),
          www_authenticate: %(Bearer error="invalid_token"))
      end
    end
  end
end
```

- [ ] **Step 9: Write the base controllers**

`web-app/app/controllers/api/v1/base_controller.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    # Every authenticated API endpoint inherits from here. ActionController::API:
    # no session, no cookies, no CSRF, no allow_browser (which would 406 curl).
    #
    # before_action order is load-bearing and follows include order:
    #   1. set_current_domain   (CurrentDomain)      -- Current.domain from the host
    #   2. prevent_caching      (Cacheable)          -- private, no-store on EVERY response
    #   3. authenticate!        (Api::Authentication)
    #   4. enforce_rate_limit!  (Api::RateLimited)
    #   5. require_scope!
    class BaseController < ActionController::API
      include CurrentDomain
      include Cacheable
      include VisitorIp
      include ::Api::ErrorRendering

      before_action :prevent_caching

      include ::Api::Authentication
      include ::Api::RateLimited

      class_attribute :required_scope, instance_writer: false

      before_action :require_scope!

      def self.require_scope(scope) = self.required_scope = scope

      private

      def require_scope!
        scope = required_scope
        raise "#{self.class.name} declares no required_scope" if scope.nil?
        return if current_principal.scope?(scope)

        render_problem(
          ::Api::Problem.new(:insufficient_scope, detail: "This endpoint requires the #{scope} scope."),
          www_authenticate: %(Bearer error="insufficient_scope", scope="#{scope}")
        )
      end

      # Paginates a rank-ordered relation (or nil, when there is no ranking to
      # read from) and renders the collection envelope. The block turns one
      # RankedItem row into its hash. Page params are validated even when the
      # relation is nil so a bad page is always a 400.
      def render_ranked_page(relation, path:)
        page = ::Api::Page.from_params(params, total_count: relation&.count || 0)
        rows = relation ? relation.offset(page.offset).limit(page.per_page) : []

        render json: {
          data: rows.map { |row| yield(row) },
          meta: page.meta,
          links: page.links("#{::Api::Host.base_url}#{path}")
        }
      end
    end
  end
end
```

`web-app/app/controllers/api/v1/books/base_controller.rb`:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # Root-anchored superclass: inside Api::V1::Books a bare BaseController
      # is this class itself.
      class BaseController < ::Api::V1::BaseController
        require_scope "books:read"
      end
    end
  end
end
```

- [ ] **Step 10: Write the books controller**

Replace the generated `web-app/app/controllers/api/v1/books/books_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    module Books
      # GET /api/v1/books        -- the primary ranking, best first, paginated
      # GET /api/v1/books/:slug  -- one book, full shape
      #
      # Every model reference is root-anchored (::Books::…): inside this module
      # a bare Books:: resolves to Api::V1::Books:: and raises NameError.
      class BooksController < BaseController
        def index
          ranking_configuration = ::Books::RankingConfiguration.default_primary
          relation = ranking_configuration && ::Books::RankedBooksQuery.call(ranking_configuration: ranking_configuration)

          render_ranked_page(relation, path: "/api/v1/books") do |ranked_item|
            BookResource.new(ranked_item.item, params: {rank: ranked_item.rank}).to_h
          end
        end

        def show
          # find_by!(slug:), never friendly.find: 137 books have purely numeric
          # slugs and friendly_id resolves slugs before primary keys.
          book = ::Books::Book
            .includes(:categories, :countries, :original_language, :descriptions, {book_authors: :author},
              {primary_image: {file_attachment: :blob}})
            .find_by!(slug: params[:slug])

          render json: {data: BookResource.new(book, with_traits: :full).to_h}
        end
      end
    end
  end
end
```

- [ ] **Step 11: Run the tests**

Run: `bin/rails test test/controllers/api/v1/books/books_controller_test.rb`
Expected: 25 runs, 0 failures. Likely first-run issues and their fixes:
- `Cache-Control` reads `private, no-store` in a different order or with `Pragma` — `prevent_caching` also sets `Pragma: no-cache`; only assert `Cache-Control`. If Rails normalises the value to `no-store, private`, update the assertion to the value Rails emits (both are correct HTTP) and note it.
- `BookResource` unresolved inside the controller: it lives in `app/lib/api/v1/books/`; both `app/lib` and `app/controllers` are autoload roots, so `Api::V1::Books::BookResource` resolves from the lexical scope — if not, write `::Api::V1::Books::BookResource`.
- The N+1 test differing by one query: confirm the warm-up request ran (it writes `last_used_at`); if the difference is the `count` query vs `offset`/`limit`, both requests issue both, so look at the printed SQL for a per-book query and add it to `RankedBooksQuery`'s includes — no, that file is shared with the site; add the include in the controller via `.includes(item: …)` merged onto the relation instead.

- [ ] **Step 12: Lint, zeitwerk, site controller tests, commit**

Run: `bundle exec standardrb app/controllers test/controllers/api test/support && CI=1 bin/rails zeitwerk:check && bin/rails test test/controllers/books`
Expected: no offences; books site tests still green.

```bash
git add config/routes.rb app/controllers/api app/controllers/concerns/api test/controllers/api test/support/api_conformance.rb test/test_helper.rb
git commit -m "feat(api): base controller, auth/rate-limit/error concerns, GET /api/v1/books and /books/:slug"
```

---

### Task 11: The OpenAPI contract, `openapi.json`, and conformance in tests

**Files:**
- Create: `web-app/config/api/v1/openapi.yaml`, `web-app/app/lib/api/openapi_document.rb`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/test/controllers/api/v1/openapi_controller_test.rb`
- Create (generator): `web-app/app/controllers/api/v1/openapi_controller.rb`
- Modify: `web-app/config/routes.rb`, `web-app/test/test_helper.rb`, `web-app/test/support/api_conformance.rb`, `web-app/test/controllers/api/v1/books/books_controller_test.rb`

**Interfaces:**
- Produces: `GET /api/v1/openapi.json` on all three hosts (public, `Cache-Control: public, max-age=3600`); `Api::OpenapiDocument.for_host(base_url)` → Hash; `assert_api_conform(status:)` (from openapi_first) and `assert_api_response_conform(status:)` in every integration test.

- [ ] **Step 1: Write the document**

`web-app/config/api/v1/openapi.yaml`:

```yaml
openapi: 3.1.0
info:
  title: The Greatest API
  version: "1"
  description: |
    Read access to the ranked catalogues of The Greatest Books, The Greatest Music and
    The Greatest Games. Every endpoint except this document needs a bearer token; tokens
    are a membership benefit. Version 1 evolves additively: fields are added, never
    renamed, removed or retyped.
servers:
  - url: https://thegreatestbooks.org
security:
  - bearerAuth: []
paths:
  /api/v1/openapi.json:
    get:
      operationId: getOpenapi
      summary: This document
      security: []
      responses:
        "200":
          description: The OpenAPI 3.1 document as JSON, with `servers` set to the host it was fetched from.
          content:
            application/json:
              schema:
                type: object
  /api/v1/books:
    get:
      operationId: listBooks
      summary: Books in rank order
      description: The Greatest Books' primary ranking, best first. Only ranked books appear.
      parameters:
        - $ref: "#/components/parameters/page"
        - $ref: "#/components/parameters/per_page"
      responses:
        "200":
          description: A page of ranked books.
          headers:
            $ref: "#/components/x-rateLimitHeaders"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BookCollection"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/books/{slug}:
    get:
      operationId: getBook
      summary: One book
      parameters:
        - $ref: "#/components/parameters/slug"
      responses:
        "200":
          description: The book.
          headers:
            $ref: "#/components/x-rateLimitHeaders"
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BookItem"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "403":
          $ref: "#/components/responses/Forbidden"
        "404":
          $ref: "#/components/responses/NotFound"
        "429":
          $ref: "#/components/responses/TooManyRequests"
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      description: A personal access token (`tg_…`). Create one at /developers/tokens.
  parameters:
    page:
      name: page
      in: query
      description: 1-based page number. A page past the end returns an empty `data` array.
      schema:
        type: integer
        minimum: 1
        default: 1
    per_page:
      name: per_page
      in: query
      schema:
        type: integer
        minimum: 1
        maximum: 100
        default: 50
    slug:
      name: slug
      in: path
      required: true
      schema:
        type: string
  headers:
    X-RateLimit-Limit:
      description: Requests allowed per calendar minute.
      schema: {type: integer}
    X-RateLimit-Remaining:
      description: Requests left in the current minute.
      schema: {type: integer}
    X-RateLimit-Reset:
      description: Unix time at which the minute window resets.
      schema: {type: integer}
    X-RateLimit-Daily-Limit:
      description: Requests allowed per UTC day.
      schema: {type: integer}
    X-RateLimit-Daily-Remaining:
      description: Requests left today.
      schema: {type: integer}
    X-RateLimit-Daily-Reset:
      description: Unix time of the next 00:00 UTC.
      schema: {type: integer}
    Retry-After:
      description: Seconds until the exhausted window resets.
      schema: {type: integer}
    WWW-Authenticate:
      description: RFC 6750 challenge.
      schema: {type: string}
  # Not a standard components key; referenced by every 200 so the six headers
  # are written once. OpenAPI permits x- extensions here.
  x-rateLimitHeaders:
    X-RateLimit-Limit:
      $ref: "#/components/headers/X-RateLimit-Limit"
    X-RateLimit-Remaining:
      $ref: "#/components/headers/X-RateLimit-Remaining"
    X-RateLimit-Reset:
      $ref: "#/components/headers/X-RateLimit-Reset"
    X-RateLimit-Daily-Limit:
      $ref: "#/components/headers/X-RateLimit-Daily-Limit"
    X-RateLimit-Daily-Remaining:
      $ref: "#/components/headers/X-RateLimit-Daily-Remaining"
    X-RateLimit-Daily-Reset:
      $ref: "#/components/headers/X-RateLimit-Daily-Reset"
  responses:
    BadRequest:
      description: A query parameter is malformed or out of range.
      headers:
        $ref: "#/components/x-rateLimitHeaders"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Unauthorized:
      description: No token, or a token that is malformed, unknown, revoked or expired.
      headers:
        WWW-Authenticate:
          $ref: "#/components/headers/WWW-Authenticate"
          required: true
        X-RateLimit-Limit:
          $ref: "#/components/headers/X-RateLimit-Limit"
        X-RateLimit-Remaining:
          $ref: "#/components/headers/X-RateLimit-Remaining"
        X-RateLimit-Reset:
          $ref: "#/components/headers/X-RateLimit-Reset"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Forbidden:
      description: The token is valid but its account is not a member (`membership_required`) or lacks the scope this host needs (`insufficient_scope`).
      headers:
        WWW-Authenticate:
          $ref: "#/components/headers/WWW-Authenticate"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    NotFound:
      description: No record with that slug.
      headers:
        $ref: "#/components/x-rateLimitHeaders"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    TooManyRequests:
      description: A rate-limit window is exhausted. `Retry-After` says when it resets.
      headers:
        Retry-After:
          $ref: "#/components/headers/Retry-After"
          required: true
        X-RateLimit-Limit:
          $ref: "#/components/headers/X-RateLimit-Limit"
        X-RateLimit-Remaining:
          $ref: "#/components/headers/X-RateLimit-Remaining"
        X-RateLimit-Reset:
          $ref: "#/components/headers/X-RateLimit-Reset"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
  schemas:
    Problem:
      description: RFC 9457 Problem Details with a stable `code`.
      type: object
      required: [type, title, status, code]
      properties:
        type:
          type: string
          format: uri
        title:
          type: string
        status:
          type: integer
        code:
          type: string
          enum: [unauthenticated, invalid_token, membership_required, insufficient_scope, not_found, invalid_parameter, rate_limited]
        detail:
          type: string
    PaginationMeta:
      type: object
      required: [page, per_page, total_count, total_pages]
      properties:
        page: {type: integer, minimum: 1}
        per_page: {type: integer, minimum: 1, maximum: 100}
        total_count: {type: integer, minimum: 0}
        total_pages: {type: integer, minimum: 1}
    PaginationLinks:
      type: object
      required: [self, next, prev, first, last]
      properties:
        self: {type: string, format: uri}
        next: {type: [string, "null"], format: uri}
        prev: {type: [string, "null"], format: uri}
        first: {type: string, format: uri}
        last: {type: string, format: uri}
    AuthorSummary:
      type: object
      required: [id, slug, name]
      properties:
        id: {type: integer}
        slug: {type: string}
        name: {type: string}
    Book:
      type: object
      required: [id, slug, title, subtitle, first_published_year, rank, authors, cover_url, url, api_url]
      properties:
        id: {type: integer}
        slug: {type: string}
        title: {type: string}
        subtitle: {type: [string, "null"]}
        first_published_year: {type: [integer, "null"]}
        rank:
          type: [integer, "null"]
          description: Position in the site's primary ranking; null when unranked.
        authors:
          type: array
          items:
            $ref: "#/components/schemas/AuthorSummary"
        cover_url: {type: [string, "null"], format: uri}
        url: {type: string, format: uri, description: The book's page on the site.}
        api_url: {type: string, format: uri}
    BookFull:
      allOf:
        - $ref: "#/components/schemas/Book"
        - type: object
          required: [sort_title, alternate_titles, book_kind, book_length, page_range, word_count, description, original_language, categories, countries]
          properties:
            sort_title: {type: [string, "null"]}
            alternate_titles:
              type: array
              items: {type: string}
            book_kind:
              type: string
              enum: [standalone, collection]
            book_length:
              type: [string, "null"]
              enum: [very_short, short, medium, moderate, long, very_long, null]
            page_range: {type: [string, "null"]}
            word_count: {type: [integer, "null"]}
            description: {type: [string, "null"]}
            original_language:
              type: [object, "null"]
              required: [id, slug, name]
              properties:
                id: {type: integer}
                slug: {type: string}
                name: {type: string}
            categories:
              type: array
              items:
                type: object
                required: [id, slug, name, category_type]
                properties:
                  id: {type: integer}
                  slug: {type: [string, "null"]}
                  name: {type: string}
                  category_type: {type: string}
            countries:
              type: array
              items:
                type: object
                required: [id, slug, name]
                properties:
                  id: {type: integer}
                  slug: {type: string}
                  name: {type: string}
    BookCollection:
      type: object
      required: [data, meta, links]
      properties:
        data:
          type: array
          items:
            $ref: "#/components/schemas/Book"
        meta:
          $ref: "#/components/schemas/PaginationMeta"
        links:
          $ref: "#/components/schemas/PaginationLinks"
    BookItem:
      type: object
      required: [data]
      properties:
        data:
          $ref: "#/components/schemas/BookFull"
```

If openapi_first rejects the `$ref` to `#/components/x-rateLimitHeaders` in a `headers` map (a `headers` object's value must be a map of header objects, and some parsers do not resolve a `$ref` at that level), inline the six `$ref: "#/components/headers/…"` entries in each place and delete `x-rateLimitHeaders`. Correctness of the document beats brevity.

- [ ] **Step 2: Write the document loader**

`web-app/app/lib/api/openapi_document.rb`:

```ruby
# frozen_string_literal: true

# Loads the hand-written contract and stamps the host it is being served from
# into `servers`, so a client that fetches it from the music site gets music
# URLs. Memoised outside development: the file changes only with a deploy.
module Api
  module OpenapiDocument
    PATH = Rails.root.join("config/api/v1/openapi.yaml")

    def self.raw
      return load if Rails.env.development?

      @raw ||= load
    end

    def self.for_host(base_url)
      raw.merge("servers" => [{"url" => base_url}])
    end

    def self.load = YAML.safe_load(File.read(PATH), aliases: true)
  end
end
```

- [ ] **Step 3: Route and controller for `openapi.json`**

In `web-app/config/routes.rb`, directly after the privacy/deletion policy `constraints … do … end` block (the one for `pages#privacy`), add:

```ruby
  # The API contract, on every real host, unauthenticated and edge-cacheable:
  # the one /api/ path that SHOULD cache. Served outside Api::V1::BaseController
  # (which authenticates) -- see Api::V1::OpenapiController.
  constraints DomainConstraint.new(
    [:books, :music, :games].map { |domain| Rails.application.config.domains[domain] }.join(",")
  ) do
    get "api/v1/openapi", to: "api/v1/openapi#show", as: :api_v1_openapi,
      defaults: {format: :json}, constraints: {format: :json}
  end
```

Run:
```bash
bin/rails generate controller api/v1/openapi show --skip-routes --no-helper -e none --parent=ActionController::API
```
Replace `web-app/app/controllers/api/v1/openapi_controller.rb` with:

```ruby
# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/openapi.json -- public, no token, cacheable for an hour.
    # Not a BaseController subclass on purpose: that base authenticates.
    class OpenapiController < ActionController::API
      include CurrentDomain
      include Cacheable

      def show
        expires_in 1.hour, public: true
        render json: ::Api::OpenapiDocument.for_host(::Api::Host.base_url)
      end
    end
  end
end
```

- [ ] **Step 4: Wire openapi_first into the test helper**

In `web-app/test/test_helper.rb`, after `require "webmock/minitest"`:

```ruby
require "openapi_first"
```

After the `WebMock.disable_net_connect!` line:

```ruby
# Every API integration test validates its request and response against the
# contract with assert_api_conform (see test/support/api_conformance.rb).
# report_coverage is OFF: openapi_first's own gate runs at process exit and
# exits 2 whenever coverage is under 100% -- which is every scoped run
# (`bin/rails test test/models/...`). test/integration/api/v1/contract_coverage_test.rb
# is the gate instead: it exercises every documented response itself.
OpenapiFirst::Test.setup do |test|
  test.register(Rails.root.join("config/api/v1/openapi.yaml").to_s)
  test.report_coverage = false
end
```

Replace `web-app/test/support/api_conformance.rb` with:

```ruby
# Helpers for API integration tests.
module ApiConformance
  include OpenapiFirst::Test::Methods

  def bearer(secret) = {"Authorization" => "Bearer #{secret}"}

  # Validates only the RESPONSE against the OpenAPI document. For the tests
  # that deliberately send an invalid request (page=0): assert_api_conform
  # validates the request too and would fail on exactly the input under test.
  def assert_api_response_conform(status:)
    assert_equal status, response.status, "#{request.request_method} #{request.fullpath}"
    validated = OpenapiFirst::Test[:default].validate_response(request, response, raise_error: false)
    assert validated.valid?, validated.error&.exception_message
  end
end

module ActionDispatch
  class IntegrationTest
    include ApiConformance
  end
end
```

- [ ] **Step 5: Add conformance to every books controller test**

In `web-app/test/controllers/api/v1/books/books_controller_test.rb`, add one line to each test right after its request(s), matching the status it asserts:

- every test that asserts `:success` → `assert_api_conform(status: 200)`
- `"invalid pagination parameters are a 400 problem"` → inside the loop, `assert_api_response_conform(status: 400)`
- the two 404 slug tests → `assert_api_conform(status: 404)` (the routing 404 for `.xml` gets nothing — it matches no operation)
- the 401 tests → `assert_api_conform(status: 401)`
- the 403 tests → `assert_api_conform(status: 403)`
- the two 429 tests → `assert_api_conform(status: 429)` after the 429 request
- the N+1 test and the caching test → leave as they are

- [ ] **Step 6: Write the openapi controller test**

Replace `web-app/test/controllers/api/v1/openapi_controller_test.rb` with:

```ruby
require "test_helper"

module Api
  module V1
    class OpenapiControllerTest < ActionDispatch::IntegrationTest
      test "serves the document publicly with the current host as its server" do
        host! "dev-new.thegreatestbooks.org"

        get "/api/v1/openapi.json"

        assert_response :success
        assert_api_conform(status: 200)
        body = response.parsed_body
        assert_equal "3.1.0", body["openapi"]
        assert_equal [{"url" => "https://dev-new.thegreatestbooks.org"}], body["servers"]
        assert body["paths"].key?("/api/v1/books")
        assert_match(/public/, response.headers["Cache-Control"])
        assert_match(/max-age=3600/, response.headers["Cache-Control"])
      end

      test "stamps the music host when fetched there" do
        host! "dev.thegreatestmusic.org"

        get "/api/v1/openapi.json"

        assert_response :success
        assert_equal "https://dev.thegreatestmusic.org", response.parsed_body["servers"].first["url"]
      end

      test "the document itself is valid enough to load" do
        assert_kind_of Hash, ::Api::OpenapiDocument.raw
        assert_equal ["/api/v1/openapi.json", "/api/v1/books", "/api/v1/books/{slug}"], ::Api::OpenapiDocument.raw["paths"].keys
      end
    end
  end
end
```

- [ ] **Step 7: Write the contract coverage test**

`web-app/test/integration/api/v1/contract_coverage_test.rb`:

```ruby
require "test_helper"

module Api
  module V1
    # Every (method, path, status) the contract documents must be reachable
    # and must conform. EXERCISES is the map from documented response to the
    # request that produces it; the test fails if the document gains a response
    # this map does not exercise, or the map names one the document lacks. This
    # is the coverage gate -- openapi_first's built-in one is disabled because
    # it exits 2 on every scoped test run.
    class ContractCoverageTest < ActionDispatch::IntegrationTest
      EXERCISES = {
        ["GET", "/api/v1/openapi.json", "200"] => -> { get "/api/v1/openapi.json" },
        ["GET", "/api/v1/books", "200"] => -> { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books", "400"] => -> { get "/api/v1/books?page=0", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books", "401"] => -> { get "/api/v1/books" },
        ["GET", "/api/v1/books", "403"] => -> { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MUSIC_ONLY) },
        ["GET", "/api/v1/books", "429"] => -> { with_exhausted_limit { get "/api/v1/books", headers: bearer(ApiTokenSecrets::MEMBER) } },
        ["GET", "/api/v1/books/{slug}", "200"] => -> { get "/api/v1/books/#{books_books(:war_and_peace).slug}", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}", "401"] => -> { get "/api/v1/books/war-and-peace" },
        ["GET", "/api/v1/books/{slug}", "403"] => -> { get "/api/v1/books/war-and-peace", headers: bearer(ApiTokenSecrets::NON_MEMBER) },
        ["GET", "/api/v1/books/{slug}", "404"] => -> { get "/api/v1/books/no-such-book", headers: bearer(ApiTokenSecrets::MEMBER) },
        ["GET", "/api/v1/books/{slug}", "429"] => -> { with_exhausted_limit { get "/api/v1/books/war-and-peace", headers: bearer(ApiTokenSecrets::MEMBER) } }
      }.freeze

      setup do
        host! "dev-new.thegreatestbooks.org"
        RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: ranking_configurations(:books_global), rank: 1, score: 100)
      end

      test "the map and the document describe the same responses" do
        # .to_a on both: openapi_first exposes routes and responses as lazy
        # enumerators, and request_method is already upcased ("GET").
        documented = OpenapiFirst::Test[:default].routes.to_a.flat_map do |route|
          route.responses.to_a.map { |resp| [route.request_method, route.path, resp.status.to_s] }
        end.uniq

        assert_equal documented.sort, EXERCISES.keys.sort,
          "documented responses and EXERCISES disagree -- add the missing entry to whichever side lacks it"
      end

      test "every documented response is reachable and conforms" do
        EXERCISES.each do |(_method, _path, status), exercise|
          instance_exec(&exercise)
          # Request validation would reject the deliberately bad page=0 request.
          assert_api_response_conform(status: Integer(status))
        end
      end

      private

      def with_exhausted_limit
        minute = Services::Api::RateLimiter::Window.new(limit: 60, remaining: 0, reset_at: 30.seconds.from_now, exceeded: true)
        day = Services::Api::RateLimiter::Window.new(limit: 5000, remaining: 10, reset_at: 1.day.from_now, exceeded: false)
        Services::Api::RateLimiter.stubs(:hit).returns(Services::Api::RateLimiter::Verdict.new(minute: minute, day: day))
        yield
      ensure
        Services::Api::RateLimiter.unstub(:hit)
      end
    end
  end
end
```

- [ ] **Step 8: Run everything API-related**

Run: `bin/rails test test/controllers/api test/integration/api test/lib/api`
Expected: green. Things that typically need a first-pass fix, and the correct fix for each:
- A response body failing schema validation → the *document* or the *resource* is wrong; make them agree (the spec §6 field list is the tie-breaker).
- `format: uri` failing on `null` → the `type: [string, "null"]` form already permits null; if json_schemer still applies the format to null, remove `format` from nullable URL fields.
- Header validation failing because a header is missing on a 400 → `apply_rate_limit_headers` ran in `enforce_rate_limit!`, before the page params are parsed in the action, so they are present; if the failure is on the `Unauthorized` response, check the anon verdict path sets the minute triple.
- `route.responses` / `route.request_method` not being the API of the installed openapi_first → read `OpenapiFirst::Definition#routes` in the installed gem and adapt the two accessor names; the shape (method, path template, status) is what matters.

- [ ] **Step 9: Lint, zeitwerk, no new warnings, commit**

Run: `bundle exec standardrb app config/api test && CI=1 bin/rails zeitwerk:check && bin/rails test test/controllers/api test/integration/api 2>&1 | grep -ci warning`
Expected: no offences; `0` warnings.

```bash
git add config/api/v1/openapi.yaml app/lib/api/openapi_document.rb app/controllers/api/v1/openapi_controller.rb config/routes.rb test/test_helper.rb test/support/api_conformance.rb test/controllers/api test/integration/api
git commit -m "feat(api): OpenAPI 3.1 contract served at /api/v1/openapi.json and enforced by every API test"
```

---

### Task 12: Service-account service and rake tasks

**Files:**
- Create: `web-app/app/lib/services/api/service_accounts.rb`, `web-app/lib/tasks/api.rake`
- Test: `web-app/test/lib/services/api/service_accounts_test.rb`, `web-app/test/lib/tasks/api_rake_test.rb`

**Interfaces:**
- Consumes: `User.service_account_email`, `User::SERVICE_ACCOUNT_NAME_FORMAT` (Task 4); `ApiToken.generate` (Task 3).
- Produces: `Services::Api::ServiceAccounts.create(name:, scopes:, token_name: "default")`, `.mint(name:, token_name:, scopes:)`, `.revoke(id:)` → `Result`; `data` is `{user:, token:, secret:}` for create/mint and `{token:}` for revoke. Rake: `api:service_account:create NAME= SCOPES= [TOKEN_NAME=]`, `api:service_account:token NAME= TOKEN_NAME= [SCOPES=]`, `api:token:revoke ID=`.

- [ ] **Step 1: Write the failing service tests**

`web-app/test/lib/services/api/service_accounts_test.rb`:

```ruby
require "test_helper"

module Services
  module Api
    class ServiceAccountsTest < ActiveSupport::TestCase
      test "create makes a service account and mints one token" do
        result = nil
        assert_difference ["User.count", "ApiToken.count"], 1 do
          result = ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read", "music:read"])
        end

        assert result.success?, result.errors.join(", ")
        user = result.data[:user]
        assert user.service?
        assert_equal "nightly-sync@service-accounts.thegreatest.invalid", user.email
        assert_equal "nightly-sync", user.display_name
        assert_equal 0, user.user_lists.count
        token = result.data[:token]
        assert_equal "default", token.name
        assert_equal ["books:read", "music:read"], token.scopes
        assert_match ApiToken::SECRET_FORMAT, result.data[:secret]
        assert_equal token, ApiToken.authenticate(result.data[:secret])
      end

      test "create is find-or-create on the account and always mints a new token" do
        ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read"])

        assert_no_difference "User.count" do
          assert_difference "ApiToken.count", 1 do
            result = ServiceAccounts.create(name: "nightly-sync", scopes: ["books:read"], token_name: "second")
            assert result.success?
            assert_equal "second", result.data[:token].name
          end
        end
      end

      test "create rejects a name that is not lowercase-kebab" do
        result = ServiceAccounts.create(name: "Nightly Sync", scopes: ["books:read"])

        refute result.success?
        assert_match(/NAME/, result.errors.first)
      end

      test "create rejects an unknown scope without creating the account" do
        assert_no_difference "User.count" do
          result = ServiceAccounts.create(name: "bad-scope", scopes: ["films:read"])
          refute result.success?
          assert_match(/films:read/, result.errors.join)
        end
      end

      test "mint adds a token to an existing service account" do
        user = users(:agent_runner_service_account)

        result = ServiceAccounts.mint(name: "agent-runner", token_name: "prod-2", scopes: ["games:read"])

        assert result.success?
        assert_equal user, result.data[:token].user
        assert_equal ["games:read"], result.data[:token].scopes
      end

      test "mint fails for an unknown account" do
        result = ServiceAccounts.mint(name: "nobody", token_name: "x", scopes: ["books:read"])

        refute result.success?
        assert_match(/no service account/i, result.errors.first)
      end

      test "revoke destroys a token by id" do
        token = api_tokens(:service_account_token)

        assert_difference "ApiToken.count", -1 do
          assert ServiceAccounts.revoke(id: token.id).success?
        end
        assert_nil ApiToken.authenticate(ApiTokenSecrets::SERVICE)
      end

      test "revoke of an unknown id fails" do
        refute ServiceAccounts.revoke(id: 0).success?
      end
    end
  end
end
```

- [ ] **Step 2: Write the failing rake tests**

`web-app/test/lib/tasks/api_rake_test.rb`:

```ruby
require "test_helper"
require "rake"

class ApiRakeTest < ActiveSupport::TestCase
  setup do
    unless Rake::Task.task_defined?("api:service_account:create")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/api.rake").to_s }
    end
    %w[api:service_account:create api:service_account:token api:token:revoke].each { |name| Rake::Task[name].reenable }
  end

  test "service_account:create prints exactly the secret" do
    out, _err = with_env("NAME" => "rake-made", "SCOPES" => "books:read,games:read") do
      capture_io { Rake::Task["api:service_account:create"].invoke }
    end

    secret = out.strip
    assert_match ApiToken::SECRET_FORMAT, secret
    assert_equal 1, out.lines.size
    token = ApiToken.authenticate(secret)
    assert_equal ["books:read", "games:read"], token.scopes
    assert_equal "rake-made@service-accounts.thegreatest.invalid", token.user.email
  end

  test "service_account:create aborts with the validation message on bad input" do
    with_env("NAME" => "Bad Name", "SCOPES" => "books:read") do
      error = assert_raises(SystemExit) { capture_io { Rake::Task["api:service_account:create"].invoke } }
      assert_match(/NAME/, error.message)
    end
  end

  test "service_account:token mints another token for an existing account" do
    out, _err = with_env("NAME" => "agent-runner", "TOKEN_NAME" => "prod-2", "SCOPES" => "books:read") do
      capture_io { Rake::Task["api:service_account:token"].invoke }
    end

    token = ApiToken.authenticate(out.strip)
    assert_equal users(:agent_runner_service_account), token.user
    assert_equal "prod-2", token.name
  end

  test "token:revoke destroys the token" do
    id = api_tokens(:service_account_token).id

    assert_difference "ApiToken.count", -1 do
      with_env("ID" => id.to_s) { capture_io { Rake::Task["api:token:revoke"].invoke } }
    end
  end
end
```

- [ ] **Step 3: Run to verify they fail**

Run: `bin/rails test test/lib/services/api/service_accounts_test.rb test/lib/tasks/api_rake_test.rb`
Expected: FAIL — `uninitialized constant Services::Api::ServiceAccounts`; rake file missing.

- [ ] **Step 4: Write the service**

`web-app/app/lib/services/api/service_accounts.rb`:

```ruby
# frozen_string_literal: true

module Services
  module Api
    # Creates and provisions service accounts -- User rows with
    # account_kind: :service that the Python agent framework authenticates as.
    # The rake tasks in lib/tasks/api.rake are thin wrappers over these three
    # methods; the secret is returned exactly once, in `data[:secret]`.
    class ServiceAccounts
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # Find-or-create the account by name, then mint one token. Re-running with
      # the same NAME never makes a second account; it does mint another token,
      # which is the point (rotation).
      def self.create(name:, scopes:, token_name: "default")
        unless User::SERVICE_ACCOUNT_NAME_FORMAT.match?(name.to_s)
          return failure("NAME must be lowercase letters, digits and dashes (got #{name.inspect})")
        end

        unknown = scopes.reject { |scope| ::Api::Scopes.known?(scope) }
        return failure("unknown scope(s): #{unknown.join(", ")}") if unknown.any?

        user = User.transaction do
          User.service.find_or_create_by!(email: User.service_account_email(name)) do |account|
            account.display_name = name
            account.name = name
            account.role = :user
            account.account_kind = :service
            account.email_verified = false
          end
        end

        mint_for(user, token_name: token_name, scopes: scopes)
      end

      def self.mint(name:, token_name:, scopes:)
        user = User.service.find_by(email: User.service_account_email(name))
        return failure("no service account named #{name.inspect}") if user.nil?

        mint_for(user, token_name: token_name, scopes: scopes)
      end

      def self.revoke(id:)
        token = ApiToken.find_by(id: id)
        return failure("no token with id #{id.inspect}") if token.nil?

        token.destroy!
        success(token: token)
      end

      def self.mint_for(user, token_name:, scopes:)
        token, secret = ApiToken.generate(user: user, name: token_name, scopes: scopes)
        return failure(*token.errors.full_messages) unless token.persisted?

        success(user: user, token: token, secret: secret)
      end
      private_class_method :mint_for

      def self.success(data) = Result.new(success?: true, data: data, errors: [])

      def self.failure(*messages) = Result.new(success?: false, data: nil, errors: messages)
    end
  end
end
```

- [ ] **Step 5: Write the rake file**

`web-app/lib/tasks/api.rake`:

```ruby
# Service-account provisioning for the public API. Each task prints the new
# secret and NOTHING else to stdout, so `bin/rails api:service_account:create … | sops …`
# works; errors go to stderr via abort.
namespace :api do
  def api_env!(name)
    ENV[name].presence || abort("#{name} is required")
  end

  def api_scopes
    api_env!("SCOPES").split(",").map(&:strip).reject(&:blank?)
  end

  def api_print!(result)
    abort result.errors.join("; ") unless result.success?
    puts result.data[:secret]
  end

  namespace :service_account do
    desc "Create a service account (NAME=lowercase-kebab SCOPES=books:read,music:read [TOKEN_NAME=default]) and print its first token"
    task create: :environment do
      api_print! Services::Api::ServiceAccounts.create(
        name: api_env!("NAME"), scopes: api_scopes, token_name: ENV.fetch("TOKEN_NAME", "default")
      )
    end

    desc "Mint another token for an existing service account (NAME= TOKEN_NAME= SCOPES=) and print it"
    task token: :environment do
      api_print! Services::Api::ServiceAccounts.mint(
        name: api_env!("NAME"), token_name: api_env!("TOKEN_NAME"), scopes: api_scopes
      )
    end
  end

  namespace :token do
    desc "Revoke (destroy) an API token by id (ID=)"
    task revoke: :environment do
      result = Services::Api::ServiceAccounts.revoke(id: api_env!("ID"))
      abort result.errors.join("; ") unless result.success?
    end
  end
end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/lib/services/api/service_accounts_test.rb test/lib/tasks/api_rake_test.rb`
Expected: 12 runs, 0 failures. If the rake tests report "already initialized constant" warnings, the `silence_warnings { load … }` guard is in place — check the task names in `task_defined?` match exactly.

- [ ] **Step 7: Lint and commit**

Run: `bundle exec standardrb app/lib/services/api/service_accounts.rb lib/tasks/api.rake test/lib/services/api/service_accounts_test.rb test/lib/tasks/api_rake_test.rb`

```bash
git add app/lib/services/api/service_accounts.rb lib/tasks/api.rake test/lib/services/api/service_accounts_test.rb test/lib/tasks/api_rake_test.rb
git commit -m "feat(api): service-account provisioning service and rake tasks"
```

---

### Task 13: `MembershipGate[:api]`, feature doc, full verification

**Files:**
- Modify: `web-app/app/lib/membership_gate.rb`, `web-app/test/lib/membership_gate_test.rb`
- Create: `docs/features/public-api.md`

- [ ] **Step 1: Register the feature**

In `web-app/app/lib/membership_gate.rb`, `FEATURES`:

```ruby
  FEATURES = {
    members_area: "The members' area at /members",
    api: "The public API at /api/v1 (tokens managed at /developers/tokens)"
  }.freeze
```

Add to `web-app/test/lib/membership_gate_test.rb`:

```ruby
  test "the API is registered as a members-only feature" do
    assert MembershipGate.members_only?(:api)
  end
```

Run: `bin/rails test test/lib/membership_gate_test.rb`
Expected: green.

- [ ] **Step 2: Write the feature doc**

`docs/features/public-api.md`:

```markdown
# Public API

Spec: `docs/superpowers/specs/2026-09-12-public-api-framework-design.md`. Code is the source of truth; this page is the map.

## Shape

- Per-site path, JSON only: `https://thegreatestbooks.org/api/v1/books`, `/api/v1/books/{slug}`. The domain comes from the host. Music and games resources are later increments.
- Contract: `web-app/config/api/v1/openapi.yaml`, served at `GET /api/v1/openapi.json` (public, cached an hour). Every API integration test validates against it (`assert_api_conform`), and `test/integration/api/v1/contract_coverage_test.rb` fails if a documented response is not exercised.
- Envelope `{"data": …}`; collections add `meta` and `links`. Errors are RFC 9457 `application/problem+json` with a stable `code` (`Api::Problem`).

## Authentication

`Authorization: Bearer tg_…`. Tokens are `ApiToken` rows storing only a SHA-256 digest; the secret is shown once (`ApiToken.generate`). `Services::Api::Authenticator` is the only code that inspects a token; it yields an `Api::Principal` (user, token, scopes, tier). A person needs an active membership (`User#member?`); a service account (`User#account_kind == service`) does not and gets the `system` tier.

Failures follow RFC 6750: 401 `WWW-Authenticate: Bearer` / `Bearer error="invalid_token"`; 403 `membership_required` (no challenge); 403 `Bearer error="insufficient_scope", scope="…"`.

## Scopes

`Api::Scopes` — `books:read`, `music:read`, `games:read`. Members may mint the three reads; service accounts get whatever an admin assigns. `Api::V1::<Domain>::BaseController` declares `require_scope`. Hierarchy (`x:write` implies `x:read`) is already honoured for when write scopes exist.

## Rate limits

`config/initializers/api.rb`. Keyed on the account, two fixed windows (calendar minute, UTC day), counted by `Services::Api::RateLimiter` on `config.x.rate_limit_store`. Headers on every authenticated response: `X-RateLimit-Limit/Remaining/Reset` and `X-RateLimit-Daily-Limit/Remaining/Reset`; 429 adds `Retry-After`. Unauthenticated failures count per visitor IP (minute window only).

## Service accounts

```
bin/rails api:service_account:create NAME=agent-runner SCOPES=books:read,music:read,games:read
bin/rails api:service_account:token  NAME=agent-runner TOKEN_NAME=prod-2 SCOPES=books:read
bin/rails api:token:revoke ID=42
```

Each prints only the secret. `Services::UserAuthenticationService` scopes every lookup to `User.person`, so a service account can never sign in or be linked.

## Deploy prerequisites (edge)

Per zone: a Cloudflare custom rule `starts_with(http.request.uri.path, "/api/")` → Skip Super Bot Fight Mode, above the comma/`/rc/`/`.csv` challenge rules, created as Log first. Confirm no cache-everything rule covers `/api/`. Verify from outside with a non-browser user agent: `GET /api/v1/books` must be a 401 with `WWW-Authenticate`, not a challenge page.

## Not yet

`/developers` and `/developers/tokens` (increment 3), authors (increment 2), search, filters, music/games, OAuth/MCP.
```

- [ ] **Step 3: Full verification**

Run, in order, and read the output:

```bash
bundle exec standardrb
CI=1 bin/rails zeitwerk:check
bin/rails test 2>&1 | tee /tmp/claude-1001/-home-shane-dev-the-greatest/a5fffb2a-d816-45d1-9da3-b5b26e6b5001/scratchpad/full-suite.log | tail -5
grep -ci 'warning' /tmp/claude-1001/-home-shane-dev-the-greatest/a5fffb2a-d816-45d1-9da3-b5b26e6b5001/scratchpad/full-suite.log
```

Expected: no offences; `All is good!`; `0 failures, 0 errors`; the warning count equals what `main` produces (the two known upstream sources) — compare by running `git stash`-free: check out `main` in the main checkout is NOT allowed from a worktree; instead compare against the count recorded in AGENTS.md (two known sources). Any new `warning` line is a regression to fix at the cause.

- [ ] **Step 4: Smoke it against the dev server**

```bash
yarn build:all >/dev/null 2>&1
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```
If the port is free: start `bin/rails server` in the background, then

```bash
secret=$(bin/rails api:service_account:create NAME=smoke-test SCOPES=books:read)
curl -si https://dev-new.thegreatestbooks.org/api/v1/books?per_page=2 -H "Authorization: Bearer $secret" | head -20
curl -si https://dev-new.thegreatestbooks.org/api/v1/books | head -8
curl -s https://dev-new.thegreatestbooks.org/api/v1/openapi.json | head -c 200
```
Expected: a 200 with two ranked books and the six headers; a 401 with `WWW-Authenticate: Bearer`; the document. Then revoke: `bin/rails api:token:revoke ID=$(bin/rails runner 'puts ApiToken.joins(:user).where(users: {email: User.service_account_email("smoke-test")}).last.id')` and stop the server. If the port belongs to another checkout, skip this step and say so in the task report — do not kill their server.

- [ ] **Step 5: Commit**

```bash
git add app/lib/membership_gate.rb test/lib/membership_gate_test.rb ../docs/features/public-api.md
git commit -m "docs(api): register the API with MembershipGate and add the feature doc"
```

---

## Self-review against the spec

- §1 routing/controllers → Tasks 8, 10, 11 (routes, `ActionController::API` base, `CurrentDomain`, before-action order, `private, no-store`, JSON-only, root-anchoring).
- §2 tokens/authentication → Tasks 3, 5, 10 (digest storage, `SECRET_FORMAT`, `secure_compare`, `touch_last_used!` throttle, cap, RFC 6750 challenges, unauthenticated IP window with peek-before-lookup).
- §3 service accounts/scopes → Tasks 2, 4, 12 (enum, `.invalid` email, sign-in guard on both lookups, no default lists, `mintable_by`, hierarchy, rake tasks printing only the secret).
- §4 rate limiting → Tasks 1, 6, 10 (config tiers, two windows, keyed on user, rejected request still counts, six headers, `Retry-After`, minute-triple-only on 401).
- §5 response format → Tasks 7, 9, 10 (envelope, `Api::Page` 400s and empty overflow, RFC 9457 with `code` and `type` anchor, URLs from `config.domains`).
- §6 resources → Tasks 9, 10 (field lists, `rank` from primary configuration, `find_by!(slug:)`, includes, N+1 pin, nil-ranking empty index).
- §7 OpenAPI → Task 11 (3.1 doc, public cached endpoint, `assert_api_conform` everywhere, coverage gate).
- §8 pages → increment 3, not this plan. §9 threat model → Task 3's model comment and the doc. Testing section → each task; the sign-in guard, fixtures with a negative class, `.xml` 404, session-cookie 401, zeitwerk and warnings in Task 13. Rollout → documented in Task 13's feature doc; the Cloudflare steps are Shane's.
- One deviation from the spec, deliberate: the base controller does not include `ActionController::HttpAuthentication::Token::ControllerMethods` — `ActionDispatch::Request#authorization` already exposes the header and the authenticator parses it, so the include would be dead weight.
- Type consistency: `Verdict`/`Window` names and members (`limit`, `remaining`, `reset_at`, `exceeded`) match between Task 6, Task 10 and Task 11; `Result` structs all use `success?`/`data`/`errors`; `render_problem(problem, www_authenticate:)` has one signature; `assert_api_response_conform(status:)` is defined once (stub in Task 10, real in Task 11).
