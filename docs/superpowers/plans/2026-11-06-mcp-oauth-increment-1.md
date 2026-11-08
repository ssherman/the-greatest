# MCP sign-in (OAuth) — increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member adds `https://<books host>/api/mcp` to Claude Code, Codex or claude.ai, clicks the sign-in link, signs in with the site's normal sign-in, approves, and is connected. No token is pasted.

**Architecture:**
- Doorkeeper 5.9 is the authorization server: authorization code + PKCE S256, public clients, hashed tokens, refresh with rotation.
- Hand-written: discovery documents (RFC 8414, RFC 9728), Dynamic Client Registration (RFC 7591) and `resource` handling (RFC 8707).
- An `OauthConnection` row (user, client, resource) is the long-lived grant. Every Doorkeeper grant and token carries a NOT NULL `connection_id`, which our code sets on the server.
- `Services::Api::Authenticator` turns an OAuth access token into the same `Api::Principal` a personal token gives. Nothing after it changes.

**Tech Stack:** Rails 8.1, Doorkeeper 5.9.9, the `mcp` gem 1.9, Minitest + fixtures + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md`, **increment 1 only** (`/api/mcp`). Increment 2 adds `/api/mcp/admin` and the 30-day admin clock. Increment 3 adds Connected apps, DCR pruning and the `/developers` instructions. Background: `docs/features/mcp-server.md`, `docs/features/public-api.md`, `docs/features/authentication.md`.

## Global Constraints

- Run Rails commands from `web-app/`. Lint with `bundle exec standardrb`. Never run rubocop or brakeman. Run one `bin/rails test` process at a time per worktree.
- **Use generators:**
  - `bin/rails generate doorkeeper:install`, `doorkeeper:migration`, `doorkeeper:pkce`;
  - `bin/rails generate model ...` for each model;
  - `bin/rails generate controller ... --no-helper --no-assets --skip-routes`.
  
  Delete the `use_doorkeeper` line the install generator adds to `config/routes.rb`: every OAuth route is hand-written (Task 4 onwards).
- **ALWAYS run annotaterb** (`bin/rails db:migrate` runs it). Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. The dev DB is shared between worktrees, so delete only the annotation lines for columns this branch's `schema.rb` lacks.
- **Never run a destructive command against the development database.**
- **Root-anchor constants.** Inside `module Services::Oauth`, a bare `Oauth::Resources` resolves to `Services::Oauth::Resources` and raises. Write `::Oauth::Resources`, `::Doorkeeper::...`, `::Api::Scopes`, `::OauthConnection`.
- **Domain-neutral.** Resource scopes are `"#{domain}:read"`, built from `Current.domain`, as `Api::McpController#required_scope` builds them. URLs come from `Api::Host.base_url`, never `request.host`. Routes sit inside the books `DomainConstraint` because only books has an MCP endpoint.
- **Increment 1 registers one resource, `mcp` → `/api/mcp`.** `/api/mcp/admin` behaves exactly as today. Its 401 gets no `resource_metadata`, and an OAuth token is a 401 there.
- **REST is untouched.** Every `/api/v1/*` response, header and 401 stays byte-for-byte as today. An OAuth token on `/api/v1/*` is a 401 `invalid_token`.
- **Every existing test passes untouched.** If one has to change, stop and report. Exception: the `token_kind=` audit lines (Task 2) may extend exact-match log assertions.
- Tests use Minitest 6 (`assert_nil`). Controller tests assert behaviour, never copy. Stub nothing in Doorkeeper: run its real code.
- **Never copy Cloudflare zone details** (rule names, expressions, limits, ranges) into this repo's code, docs, plan or commits. Never run `cfrules apply`.
- A clean `bin/rails test` prints no new warnings (Doorkeeper's included).

## Decisions this plan makes (spec leaves them to the builder)

- **P-a. Our own model classes.** `OauthApplication`, `OauthAccessGrant` and `OauthAccessToken` each include the Doorkeeper ActiveRecord mixin. They are configured with `application_class`, `access_grant_class` and `access_token_class`, so they can hold `belongs_to :connection` and be annotated. `OauthConnection` is the spec's connection (D5).
- **P-b. `connection_id` is NOT NULL** on `oauth_access_grants` and `oauth_access_tokens`. It is Doorkeeper's one `custom_access_token_attributes` entry, so Doorkeeper copies it grant → token → refreshed token. `Oauth::AuthorizationsController` drops any client-sent `connection_id` and merges the one it created (D5: server-stamped). A grant that somehow lacks it fails the insert loudly.
- **P-c. The resource lives on the connection** as a key (`"mcp"`, D17), not on tokens.
  - The authenticator maps the request path to a resource with `::Oauth::Resources.for_path`. A token whose connection's resource differs is refused. That is the audience binding (D3).
  - `/api/v1/*` maps to no resource, so OAuth tokens never work there.
- **P-d. The refresh refusal runs before Doorkeeper.** Spec D11 assumed a hook after the new token exists. `Oauth::TokensController#create` runs `Services::Oauth::TokenGate` first, which refuses with `invalid_grant` before any row is created. Same behaviour, no clean-up of a half-made token.
- **P-e. Reuse detection:**
  - Presenting a revoked refresh token revokes the connection, but **only when that token was created at or after the connection's `approved_at`**.
  - Tokens revoked by a re-approval are older than the new `approved_at`. Replaying one gets `invalid_grant` and leaves the new approval alone.
- **P-f. Eligibility.** The scopes an approval grants are `::Oauth::Resources.grantable_scopes(user, resource, domain, requested:)`, which is:
  - the requested scopes, or all of the resource's scopes when `scope` is absent,
  - ∩ `Api::Scopes.mintable_by(user)`,
  - ∩ the resource's scopes.
  
  `offline_access` is accepted (it is an optional Doorkeeper scope) and dropped from what is stored. Refresh tokens are always issued.
- **P-g. `resource` on authorize** is optional:
  - absent → `::Oauth::Resources.infer(scopes)`, which is always `mcp` in increment 1;
  - present → it must equal a registered resource's URL exactly, or the client gets `error=invalid_target` on its redirect URI.
  
  On the token endpoint a `resource` that differs from the connection's URL is a 400 `invalid_target`.
- **P-h. Rate-limit budgets** (D13, all per minute):

  | Window | Per IP | Per connector range |
  | --- | --- | --- |
  | pre-auth 401 (existing) | 60 (today's `unauthenticated_per_minute`) | 3,000 |
  | DCR | 10 | 600 |
  | token endpoint | 30 | 3,000 |

  - Ranges are **Anthropic's two published ranges only** (`160.79.104.0/21`, `153.61.208.0/20`). OpenAI's list is left out because ChatGPT is not an acceptance criterion (goal 6) and this plan will not guess its CIDRs. Adding it later is one config entry.
  - Each range is its own key, so Anthropic traffic shares one budget.
- **P-i. No RFC 9207 `iss`.** Metadata does not advertise `authorization_response_iss_parameter_supported` (D9). Codex then uses its per-server callback path, which DCR registers.
- **P-j. Metadata documents are hand-written hashes.** The `mcp` gem's `ProtectedResourceMetadata` belongs to its Rack middleware and adds nothing here. Responses send `Cache-Control: public, max-age=3600`.
- **P-k. DCR accepts** `redirect_uris` (required; 1–10 strings, each ≤ 2,000 characters), `client_name` (optional, ≤ 100 characters, defaulting to `"MCP client"`), `token_endpoint_auth_method` (absent or `"none"`), `grant_types` (absent or ⊆ `authorization_code`, `refresh_token`) and `response_types` (absent or `["code"]`). It ignores other fields.
  - Errors are `invalid_redirect_uri` for a bad URI and `invalid_client_metadata` for everything else.
  - A `redirect_uri` is valid when it is `https` with a host, or `http` with host exactly `localhost`, `127.0.0.1` or `[::1]` (D6). It must have no fragment and no userinfo.
- **P-l. The authorize page** is `Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController`. Doorkeeper's `base_controller` is `"ApplicationController"`, so the page gets the session sign-in, the books layout and CSRF. Its states, in order:
  1. invalid client or redirect URI: an error page, never a redirect;
  2. signed out: a sign-in prompt that opens `#login_modal`. The layout's widget reloads the page after sign-in, so the same URL comes back with its query intact;
  3. a request Doorkeeper refuses (bad scope, `plain` PKCE): an error redirect to the client (`handle_auth_errors :redirect`);
  4. no grantable scope: an explanation, a link to `/membership`, and a "Return to <client>" form. That form is the deny action, which sends `access_denied`;
  5. eligible: the approval screen.
  
  The Approve and Deny forms carry `data-turbo="false"`: Turbo Drive swallows the cross-origin redirect that ends the flow.

## Review Focus

1. **Approve submitted through Turbo Drive.** The 302 to `https://claude.ai/...` or `http://localhost:<port>/callback` must reach the browser as a full navigation. If it is fetched, the member sees nothing happen and the client never gets its code. The Task 6 E2E asserts that the browser lands on the callback URL with `code` and `state`.
2. **PKCE silently unenforced.** Doorkeeper skips the verifier check when the grants table has no `code_challenge` column (`pkce_supported?`). A wrong `code_verifier` must be `invalid_grant`, a missing one `invalid_request`, and `code_challenge_method=plain` refused at authorize. Owners: Task 1 (schema test), Task 7 (flow tests).
3. **A client-supplied `connection_id`, `resource` or timestamp** on the authorize GET or the Approve POST cannot bind the code to another connection or to another resource, or move `approved_at`. Owner: Task 6.
4. **A replayed refresh token from before a re-approval** gets `invalid_grant` and does not revoke the fresh connection (P-e). Owner: Task 7.
5. **The signed-out round trip.** After signing in from the authorize page, the member lands on the approval screen for the same request: same `state`, same `code_challenge`, same `redirect_uri`. The response is never cached (`prevent_caching`). Owner: Task 6 (integration + E2E).

---

### Task 1: Doorkeeper, the tables and the connection service

**Files:**
- Modify: `web-app/Gemfile` (`gem "doorkeeper", "~> 5.9"`), `Gemfile.lock`
- Create (generators): `config/initializers/doorkeeper.rb`, `config/locales/doorkeeper.en.yml`, migrations, `app/models/oauth_application.rb`, `oauth_access_grant.rb`, `oauth_access_token.rb`, `oauth_connection.rb`, their tests and fixtures
- Create: `app/lib/oauth/redirect_uris.rb`, `app/lib/services/oauth/connections.rb`, `test/support/oauth_test_helper.rb`
- Modify: `app/models/user.rb`, `test/controllers/admin/users_controller_test.rb`
- Test: `test/config/doorkeeper_config_test.rb`, `test/lib/oauth/redirect_uris_test.rb`, `test/lib/services/oauth/connections_test.rb`, the model tests

**Interfaces:**
- Produces:
  - Tables:
    - Doorkeeper's three tables. `oauth_applications.secret` is nullable. The grants table has the PKCE columns. Tokens have `previous_refresh_token`. `resource_owner_id` on grants and tokens has FKs to `users`.
    - `oauth_connections`: `user_id` (FK, not null), `oauth_application_id` (FK, not null), `resource` (string, not null), `scopes` (`string[]`, default `[]`, not null), `approved_at` (not null), `last_used_at`, `revoked_at`, timestamps, and a unique index on `[user_id, oauth_application_id, resource]`.
    - `connection_id` (bigint, not null, FK, indexed) on grants and tokens.
  - `OauthConnection`: `belongs_to :user`; `belongs_to :application, class_name: "OauthApplication", foreign_key: :oauth_application_id`; `has_many :access_tokens` / `:access_grants` (`foreign_key: :connection_id`, `dependent: :delete_all`); `scope :live` (`revoked_at: nil`); `#revoked?`; `resource` validated to be in `::Oauth::Resources` keys (Task 2 makes that registry; until then validate inclusion in `%w[mcp]`, and Task 2 swaps it to the registry).
  - `OauthAccessToken` and `OauthAccessGrant`: `belongs_to :connection, class_name: "OauthConnection"`.
  - `User has_many :oauth_connections, dependent: :destroy`.
  - `::Oauth::RedirectUris.loopback_host?(host) -> Boolean`: true only for `localhost` (any case), `127.0.0.1` and `[::1]`. `.loopback?(uri) -> Boolean`: http and a loopback host. `.valid_registration?(string) -> Boolean` (the P-k rule).
  - `Services::Oauth::Connections.approve(user:, application:, resource_key:, scopes:) -> Result(data: OauthConnection)`. In one transaction it finds or creates the (user, application, resource) row and, when the row existed, revokes all its unrevoked tokens and grants (`revoked_at = now`). It then sets `scopes`, `approved_at = now` and `revoked_at = nil`. It retries once on `ActiveRecord::RecordNotUnique` (a double-clicked Approve).
  - `Services::Oauth::Connections.revoke!(connection, at: Time.current)` sets `revoked_at` on the connection and on all its unrevoked tokens and grants.
  - `Services::Oauth::Connections.record_use(connection)` writes `last_used_at` at most once per 5 minutes with `update_column`, as `Tokens.record_use` does.
  - `OauthTestHelper#issue_oauth_token(connection, expires_in: 1.hour) -> [access_plaintext, refresh_plaintext]`. It creates an `OauthAccessToken` through Doorkeeper's `create_for`, so the stored values are hashed. Included in `ActionDispatch::IntegrationTest` and `ActiveSupport::TestCase`.
- Fixtures:
  - `oauth_applications`: `claude_code` (public, `redirect_uri: http://localhost/callback`) and `claude_ai` (public, `https://claude.ai/api/mcp/auth_callback`);
  - `oauth_connections`: `member_mcp` (user `regular_user`, who has an active membership; application `claude_code`; resource `mcp`; scopes `["books:read"]`);
  - grants and tokens: empty files. Their stored values are hashes; tests mint them.

- [ ] **Step 1: Write the failing tests**

`test/config/doorkeeper_config_test.rb`:
- `Doorkeeper::VERSION::STRING == "5.9.9"`, with the message "re-check URIChecker.matches?/loopback_uri? and AuthorizationsController#pre_auth_param_fields before bumping".
- `force_pkce?` is true and `pkce_code_challenge_methods == ["S256"]`.
- `grant_flows == ["authorization_code"]` and `refresh_token_enabled?`.
- `access_token_expires_in == 1.hour`.
- The token secret strategy is `Doorkeeper::SecretStoring::Sha256Hash`.
- `custom_access_token_attributes == [:connection_id]`.
- The scopes are `Api::Scopes.all + ["offline_access"]`, with `enforce_configured_scopes?`.
- `OauthAccessGrant.pkce_supported?` is true. This pins Review Focus 2.
- `OauthAccessToken.refresh_token_revoked_on_use?` is true.

`test/lib/oauth/redirect_uris_test.rb`:
- `URIChecker.matches?("http://localhost:53122/callback", "http://localhost/callback")` is true (the port is ignored for localhost).
- The same holds for `127.0.0.1` and `[::1]`.
- `"http://localhost:5/other"` against `/callback` is false.
- `"https://evil.example/api/mcp/auth_callback"` against the claude.ai URI is false.
- `"http://example.com/callback"` is `valid_registration?` false, and so is `"https://claude.ai/cb#frag"`.
- An `OauthApplication` with `redirect_uri: "http://localhost/callback"` is valid and one with `"http://example.com/cb"` is not. This proves the `force_ssl_in_redirect_uri` proc.

`test/lib/services/oauth/connections_test.rb`:
- Approving twice keeps one row.
- The second approval revokes the tokens issued under the first and resets `approved_at`.
- Approving a revoked connection clears `revoked_at`.
- `revoke!` revokes the connection's tokens and grants and leaves another connection's alone.

`users_controller_test.rb`: "should destroy user with an oauth connection". Give the user a connection and a token, destroy the user, and expect no `InvalidForeignKey`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/config/doorkeeper_config_test.rb test/lib/oauth/redirect_uris_test.rb test/lib/services/oauth/connections_test.rb`
Expected: FAIL (uninitialized constant Doorkeeper / OauthConnection).

- [ ] **Step 3: Install and configure**

- Add the gem and run the three Doorkeeper generators, then edit the migration as the Interfaces block says.
- Generate the four models (`--skip-migration` for the three Doorkeeper ones), then `db:migrate`.
- Configure the initializer:
  - `orm :active_record`;
  - the three model classes (P-a);
  - `base_controller "ApplicationController"`;
  - `resource_owner_authenticator { current_user }`. It returns nil when signed out; the controller handles that (Task 6), so it never redirects;
  - `access_token_expires_in 1.hour`, `authorization_code_expires_in 10.minutes`;
  - `use_refresh_token`, `hash_token_secrets`, `force_pkce`, `pkce_code_challenge_methods %w[S256]`;
  - `grant_flows %w[authorization_code]`;
  - `optional_scopes(*Api::Scopes.all, "offline_access")` and `enforce_configured_scopes`;
  - `custom_access_token_attributes [:connection_id]`;
  - `force_ssl_in_redirect_uri ->(uri) { !::Oauth::RedirectUris.loopback?(uri) }`;
  - `handle_auth_errors :redirect`.
- Prepend a module to `Doorkeeper::OAuth::Helpers::URIChecker.singleton_class` whose `loopback_uri?(uri)` returns `::Oauth::RedirectUris.loopback?(uri)`. Do it inside `Rails.application.config.to_prepare`. D7: Doorkeeper's own version uses `IPAddr`, so it never treats `localhost` as loopback.

- [ ] **Step 4: Run the tests and the full suite**

Run: `bin/rails test test/config/doorkeeper_config_test.rb test/lib/oauth test/lib/services/oauth test/models test/controllers/admin/users_controller_test.rb`, then `bin/rails test`
Expected: PASS, and no new warnings.

- [ ] **Step 5: Commit** `Doorkeeper, OAuth tables and connections (MCP OAuth inc 1)`

---

### Task 2: Resources registry, the authenticator and the 401 challenge

**Files:**
- Create: `app/lib/oauth/resources.rb`, `app/lib/services/oauth/access_tokens.rb`
- Modify:
  - `app/lib/services/api/authenticator.rb`, `app/lib/api/principal.rb`;
  - `app/controllers/concerns/api/authentication.rb`;
  - the three audit lines: `admin/books/categories_controller.rb:261`, `category_taggable.rb:75`, `mergeable.rb:57`;
  - `app/models/oauth_connection.rb` (validate against the registry).
- Test: `test/lib/oauth/resources_test.rb`, `test/lib/services/api/authenticator_test.rb`, `test/controllers/api/mcp_controller_test.rb`, `test/controllers/api/v1/books/books_controller_test.rb` (new cases only)

**Interfaces:**
- Consumes: Task 1's models, `Connections.record_use` and `OauthTestHelper`.
- Produces:
  - `::Oauth::Resources::Resource` (`key`, `path`, `admin`) with:
    - `#scopes(domain) -> ["#{domain}:read"]`;
    - `#url(base_url) -> base_url + path`;
    - `#metadata_path -> "/.well-known/oauth-protected-resource" + path`.
  - `::Oauth::Resources` (registry `ALL = {"mcp" => Resource(key: "mcp", path: "/api/mcp", admin: false)}`):
    - `.keys`, `.fetch(key)`;
    - `.for_path(path) -> Resource | nil`: an exact match on `request.path`;
    - `.for_url(url, base_url) -> Resource | nil`;
    - `.infer(scopes) -> Resource`: the registered admin resource if any scope is `Api::Scopes.admin?` and one exists, else `mcp`;
    - `.grantable_scopes(user, resource, domain, requested: nil) -> Array<String>` (P-f);
    - `.all_scopes(domain) -> Array<String>`.
  - `Services::Oauth::AccessTokens.find_live(secret, resource:) -> OauthAccessToken | nil`. It looks the token up with `OauthAccessToken.by_token`. It returns nil when there is no resource, or the token is revoked or expired, or its connection is revoked, or the connection's `resource != resource.key`.
  - `Services::Oauth::AccessTokens.record_use(token)`: `token.revoke_previous_refresh_token!` (D11: without it rotation never happens), then `Connections.record_use(token.connection)`.
  - `Api::Principal#token_kind -> "personal" | "oauth"`.
  - The authenticator resolves a personal token first, then `find_live` with `::Oauth::Resources.for_path(request.path)`.
    - For an OAuth token, scopes are `Api::Scopes.effective(connection.scopes, user)`. When they are empty the result is `failure(:invalid_token)`, never `:membership_required` (D12).
    - The principal's `token:` is the `OauthAccessToken`.
  - `Api::Authentication` builds every 401 `WWW-Authenticate` with `bearer_challenge(error = nil)`. When `::Oauth::Resources.for_path(request.path)` finds a resource, it appends `resource_metadata` and `scope`. Exact values for `/api/mcp`:
    - no token: `Bearer resource_metadata="https://<books host>/.well-known/oauth-protected-resource/api/mcp", scope="books:read"`
    - bad token: `Bearer error="invalid_token", resource_metadata="…same…", scope="books:read"`
    - every other path: today's `Bearer` / `Bearer error="invalid_token"`, unchanged.
  - Audit lines keep `token_id=` and gain `token_kind=<kind>` right after it.

- [ ] **Step 1: Write the failing tests**

`resources_test.rb`:
- `for_path("/api/mcp")` is `mcp`; `for_path("/api/mcp/admin")` and `for_path("/api/v1/books")` are nil.
- `grantable_scopes`:
  - a member with `requested: nil` gets `["books:read"]`;
  - a member with `requested: ["books:read", "offline_access"]` gets `["books:read"]`;
  - a non-member user gets `[]`;
  - a books admin who is not a member gets `["books:read"]` (via implies);
  - `requested: ["books:admin:merge"]` on `mcp` gets `[]`.

`authenticator_test.rb`:
- An OAuth token on a request to `/api/mcp` yields a principal with `scopes == ["books:read"]`, `tier == :member` and `token_kind == "oauth"`.
- The same token on `/api/v1/books` gives `:invalid_token`, and so does the same token on `/api/mcp/admin`.
- An expired token, a revoked token, and a token whose connection is revoked each give `:invalid_token`.
- When the member's membership lapses (`memberships(:regular_user_monthly)` set to expired), the token gives `:invalid_token`, not `:membership_required`.
- A personal token whose owner lapsed still gives `:membership_required`. This pins the existing behaviour.
- First use clears `previous_refresh_token` and revokes the old refresh token.
- An OAuth token authenticates after the member's `Session` rows are destroyed (anti-goal: signing out of the site does not disconnect).

`mcp_controller_test.rb`:
- POST `/api/mcp` with no token returns 401 with the exact no-token header above; a bad token returns the exact invalid-token header.
- A live OAuth token can `tools/list` (use `mcp_rpc_helpers.rb`).
- `/api/mcp/admin` with no token keeps the bare `Bearer`.

`books_controller_test.rb`: a no-token 401's `WWW-Authenticate` is still exactly `Bearer`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test test/lib/oauth/resources_test.rb test/lib/services/api/authenticator_test.rb test/controllers/api/mcp_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement the interfaces above.** Update the class comments on `Authenticator` and `Principal`: their "when Doorkeeper arrives" notes become what happens.

- [ ] **Step 4: Run** the files above, then `bin/rails test test/controllers/api test/lib/services/api test/integration/api`. Expected: PASS.

- [ ] **Step 5: Commit** `OAuth access tokens authenticate on /api/mcp; 401 names the resource metadata`

---

### Task 3: IP windows and connector-range budgets

**Files:**
- Modify: `app/lib/services/api/rate_limiter.rb`, `config/initializers/api.rb`
- Test: `test/lib/services/api/rate_limiter_test.rb`, `test/config/api_config_test.rb`

**Interfaces:**
- Produces:
  - Config (P-h):
    - `config.x.api.oauth_register_per_minute = 10` and `config.x.api.oauth_token_per_minute = 30`;
    - `config.x.api.connector_egress_ranges = {anthropic: %w[160.79.104.0/21 153.61.208.0/20]}`, with the two source URLs from the spec's Sources in a comment;
    - `config.x.api.connector_range_per_minute = {unauthenticated: 3_000, oauth_register: 600, oauth_token: 3_000}`.
  - `RateLimiter.hit_ip(window, ip)` and `.peek_ip(window, ip) -> Verdict`, where `window` is one of `:unauthenticated`, `:oauth_register`, `:oauth_token`.
    - An IP inside a range is keyed `api:rl:<window>:range:<name>:m:<minute>` and gets the range limit.
    - Otherwise it gets the window's per-IP limit. The `:unauthenticated` window keeps today's exact key `api:rl:anon:<ip>:m:<minute>`.
  - `hit_unauthenticated` and `peek_unauthenticated` become one-line wrappers, so `Api::Authentication` needs no edit.
  - The ranges are parsed into `IPAddr` once and memoized. A malformed IP string falls back to the per-IP key.

- [ ] **Step 1: Write the failing tests**
- `160.79.104.9` and `160.79.111.200` share one counter whose limit is 3,000.
- `153.61.208.1` uses the same `anthropic` key.
- `160.79.112.1` (just outside the /21) has its own per-IP window with limit 60.
- `hit_ip(:oauth_register, ip)` exceeds on the 11th hit.
- The `:unauthenticated` key for an outside IP is unchanged (`api:rl:anon:<ip>:m:...`).
- `api_config_test` asserts every configured CIDR parses.

- [ ] **Step 2: Verify they fail.** Run: `bin/rails test test/lib/services/api/rate_limiter_test.rb test/config/api_config_test.rb`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** those files plus `test/controllers/api`. Expected: PASS, with existing rate-limit tests untouched.
- [ ] **Step 5: Commit** `Connector egress ranges share their own rate-limit budget`

---

### Task 4: Discovery documents

**Files:**
- Create: `app/controllers/oauth/metadata_controller.rb` (`< ActionController::API`, include `CurrentDomain`)
- Modify: `config/routes.rb`, inside the books `DomainConstraint` block and outside `namespace :api`, with `format: false`
- Test: `test/controllers/oauth/metadata_controller_test.rb`

**Interfaces:**
- Consumes: `::Oauth::Resources` (Task 2).
- Produces:
  - Routes:
    - `GET /.well-known/oauth-authorization-server` → `#authorization_server`;
    - `GET /.well-known/oauth-protected-resource` and `GET /.well-known/oauth-protected-resource/api/mcp` → `#protected_resource` with `defaults: {resource_key: "mcp"}`.
  - The endpoint URLs later tasks route to: `/oauth/authorize`, `/api/oauth/token`, `/api/oauth/register`, `/api/oauth/revoke`.

- [ ] **Step 1: Write the failing tests.** Let `base = Api::Host.base_url`.
- The AS metadata's key set is **exactly** `issuer, authorization_endpoint, token_endpoint, registration_endpoint, revocation_endpoint, response_types_supported, grant_types_supported, code_challenge_methods_supported, token_endpoint_auth_methods_supported, scopes_supported`, with these values:
  - `issuer == base`;
  - `authorization_endpoint == base + "/oauth/authorize"`;
  - `token_endpoint == base + "/api/oauth/token"`;
  - `registration_endpoint == base + "/api/oauth/register"`;
  - `revocation_endpoint == base + "/api/oauth/revoke"`;
  - `response_types_supported == ["code"]`;
  - `grant_types_supported == ["authorization_code", "refresh_token"]`;
  - `code_challenge_methods_supported == ["S256"]`;
  - `token_endpoint_auth_methods_supported == ["none"]`;
  - `scopes_supported == ["books:read", "offline_access"]`.
  
  Asserting the exact key set guards the anti-goal: no `client_id_metadata_document_supported`, no `authorization_response_iss_parameter_supported`.
- The PRM at `/.well-known/oauth-protected-resource/api/mcp` is exactly `{resource: base + "/api/mcp", authorization_servers: [base], scopes_supported: ["books:read"], bearer_methods_supported: ["header"]}`.
- The root PRM is the same document.
- `/.well-known/oauth-protected-resource/api/mcp/admin` is a 404.
- Responses are `application/json` with `Cache-Control: public, max-age=3600`.
- The music host gets a 404.

- [ ] **Step 2: Verify they fail. Step 3: Implement. Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `OAuth discovery: authorization server and protected resource metadata`

---

### Task 5: Dynamic Client Registration

**Files:**
- Create: `app/controllers/oauth/registrations_controller.rb` (`< ActionController::API`, include `CurrentDomain`, `Cacheable`, `VisitorIp`, `::Api::ErrorRendering`)
- Modify: `config/routes.rb` (`post "api/oauth/register"`, books host, JSON)
- Test: `test/controllers/oauth/registrations_controller_test.rb`

**Interfaces:**
- Consumes: `::Oauth::RedirectUris.valid_registration?` (Task 1), `RateLimiter.hit_ip(:oauth_register, visitor_ip)` (Task 3).
- Produces: `POST /api/oauth/register` creates `OauthApplication(confidential: false, secret: nil, scopes: "")` and returns 201 with `client_id` (the `uid`), `client_id_issued_at`, `client_name`, `redirect_uris`, `grant_types: ["authorization_code", "refresh_token"]`, `response_types: ["code"]` and `token_endpoint_auth_method: "none"`. It sends no `client_secret`.

- [ ] **Step 1: Write the failing tests**
- A good body with `["http://localhost:33418/callback"]` returns 201. The application is public, and its `redirect_uri` is the URIs joined by newlines.
- The claude.ai https URI gets a 201.
- `http://example.com/cb` gets 400 `invalid_redirect_uri`, and so do `cursor://x`, `https://claude.ai/cb#f`, an empty array and 11 URIs.
- 400 `invalid_client_metadata` for:
  - `token_endpoint_auth_method: "client_secret_basic"`;
  - `grant_types: ["client_credentials"]`;
  - a 101-character `client_name`;
  - a body that is not a JSON object, such as `[]`, `"x"` or malformed JSON.
- No `client_name` gives `"MCP client"`.
- The 11th request in a minute from one IP gets 429 with `Retry-After`. From `160.79.104.9` the 11th succeeds.
- Every response has `Cache-Control: no-store`.

- [ ] **Step 2: Verify they fail. Step 3: Implement.** Parse the raw body with `JSON.parse`; never use `params`, so a malformed body is ours to answer. Count every request with `hit_ip` before any work.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `Dynamic Client Registration for public MCP clients`

---

### Task 6: The authorize page

**Files:**
- Create:
  - `app/controllers/oauth/authorizations_controller.rb` (`< Doorkeeper::AuthorizationsController`; include `DomainLayout`; `before_action :prevent_caching`; `layout :resolve_layout`);
  - `app/views/oauth/authorizations/new.html.erb` (approval), `signed_out.html.erb`, `ineligible.html.erb`, `error.html.erb`;
  - `e2e/tests/books/oauth-authorize.spec.ts`, `e2e/tests/books/member/oauth-authorize.spec.ts`, `e2e/tests/books/account/oauth-authorize.spec.ts`.
- Modify: `config/routes.rb` (`get`/`post`/`delete "oauth/authorize"`, books host, HTML)
- Test: `test/controllers/oauth/authorizations_controller_test.rb`

**Interfaces:**
- Consumes:
  - `::Oauth::Resources.grantable_scopes`, `.infer`, `.for_url` (Task 2);
  - `Services::Oauth::Connections.approve` (Task 1);
  - `OauthApplication`.
- Produces: the flow in P-l.
  - `#new` validates the client with `pre_auth.client_valid?`. If it is not valid, it renders `error` with the error's status.
  - Then the controller checks `current_user`. Nil renders `signed_out` with status 200.
  - Then `pre_auth.authorizable?`. If false, Doorkeeper's error redirect runs.
  - Then `resource`: a present `resource` that `for_url` does not know redirects with `error=invalid_target`.
  - Then `grantable_scopes`. Empty renders `ineligible`; otherwise it renders `new`.
  - `#create` re-runs every check on the POST (it never trusts the hidden fields' scope). Then:
    1. calls `Connections.approve(... scopes: grantable)`;
    2. builds `pre_auth` from params with `connection_id: connection.id` and `scope: grantable.join(" ")` merged in by the server;
    3. calls Doorkeeper's `authorize_response`.
    
    `pre_auth_params` drops any client-sent `connection_id`.
  - `#destroy` is Doorkeeper's deny: it redirects with `error=access_denied`.
  - Hidden fields carry `client_id`, `redirect_uri`, `state`, `response_type`, `code_challenge`, `code_challenge_method`, `scope` and `resource`.
  - The approval screen shows:
    - the client name (escaped);
    - the redirect host, from `URI(redirect_uri).host` plus the port when it is loopback;
    - the site name;
    - each scope's `Api::Scopes.description`;
    - Approve and Deny buttons, both forms with `data: {turbo: false}`.
  - The signed-out page has a "Sign in" button that runs `document.getElementById('login_modal').showModal()`, as `members/show.html.erb` does.

- [ ] **Step 1: Write the failing integration tests.** Use a DCR'd or fixture public client and a valid PKCE pair.
- A signed-out GET with a valid client returns 200 with the sign-in prompt and `Cache-Control` containing `no-store`.
- A bad `client_id` or an unregistered `redirect_uri` returns 4xx and no redirect, whether signed in or not.
- A signed-in member gets 200 (the approval screen).
- A signed-in non-member (a user with no membership fixture) gets 200 (ineligible). Its deny redirects with `error=access_denied&state=<state>`.
- `code_challenge_method=plain` redirects with an `error`, and so does no `code_challenge`.
- `resource=https://other.example/api/mcp` redirects with `error=invalid_target`.
- Approve (POST) 302s to `redirect_uri` with `code` and the same `state`. It creates one `OauthConnection` (resource `mcp`, scopes `["books:read"]`), and the grant's `connection_id` is that row.
- **Server-set attributes (Review Focus 3).** Send `connection_id=<another user's connection id>` on both the GET and the POST, plus `approved_at=2000-01-01`, `resource_key=mcp_admin` and `scope=books:admin:merge` on the POST. The grant still belongs to the member's own new connection, `approved_at` is now, and its scopes are `books:read`. A POST from a non-member with forged fields gets no code.
- A localhost redirect on a different port from the registered one (`http://localhost:61000/callback` against `http://localhost/callback`) is accepted.
- **CSP (D16).** The Approve response either has no `Content-Security-Policy` header, or its `form-action` allows the redirect's origin. A test helper parses the header and asserts it either way, so turning CSP on later fails here.

- [ ] **Step 2: Verify they fail. Step 3: Implement.**

daisyUI 5 classes only (see `AGENTS.md`). The page is a `card` in the books layout, and it fits 375 px with no horizontal scroll. Give `data-testid` only to elements role/text cannot target: `oauth-redirect-host`, `oauth-approve`, `oauth-deny`.

- [ ] **Step 4: Write the E2E specs.** Follow `developers.spec.ts` for project placement and `email-auth.spec.ts` for signing in through the modal. Each spec registers its own client in `beforeAll` with `request.post('/api/oauth/register')` and a `http://127.0.0.1:<port>/callback` URI. It intercepts that URI with `page.route` and records the URL the browser lands on.
  - signed out: the authorize URL shows the sign-in prompt. Sign in with the member account in the modal. After the reload the approval screen shows, for the same `state`. Approve lands on the callback with `code` and the same `state` (Review Focus 1 and 5).
  - member: Deny lands on the callback with `error=access_denied`. The page fits a 375 px viewport.
  - account (non-member): the page explains membership and links to `/membership`. "Return" lands on the callback with `error=access_denied`.

- [ ] **Step 5: Run.** `bin/rails test test/controllers/oauth`. Then check port 3000 is this worktree's with the `ss`/`readlink` check in `AGENTS.md`. Then run `yarn build:all`, `bin/rails server`, and `yarn test:e2e e2e/tests/books/oauth-authorize.spec.ts e2e/tests/books/member/oauth-authorize.spec.ts e2e/tests/books/account/oauth-authorize.spec.ts`. If another checkout holds the port, stop and report: never kill it and never use another port.
- [ ] **Step 6: Commit** `OAuth authorize page: sign in, approve, deny, ineligible`

---

### Task 7: The token endpoint: exchange, refresh, rotation, revoke

**Files:**
- Create: `app/controllers/oauth/tokens_controller.rb` (`< Doorkeeper::TokensController`; include `CurrentDomain`, `VisitorIp`, `::Api::ErrorRendering`), `app/lib/services/oauth/token_gate.rb`
- Modify: `config/routes.rb` (`post "api/oauth/token"` → `#create`, `post "api/oauth/revoke"` → `#revoke`, books host)
- Test: `test/lib/services/oauth/token_gate_test.rb`, `test/integration/oauth/flow_test.rb`

**Interfaces:**
- Consumes: Tasks 1–3 and 6 (the flow test drives the real authorize POST).
- Produces:
  - `Services::Oauth::TokenGate.call(params:, domain:) -> Result`. `errors` holds `:invalid_grant` or `:invalid_target`.
    - For `grant_type=refresh_token`, it finds the token with `OauthAccessToken.by_refresh_token`. A token it cannot find passes through, and Doorkeeper answers it. For a token it finds:
      - revoked, with `created_at >= connection.approved_at` (P-e): `Connections.revoke!` the connection, then `:invalid_grant`;
      - revoked otherwise: `:invalid_grant`;
      - the connection is revoked: `:invalid_grant`;
      - `Api::Scopes.effective(connection.scopes, user)` is empty: `Connections.revoke!`, then `:invalid_grant`. Renewing the membership later does not revive the connection;
      - a `resource` param whose `::Oauth::Resources.for_url` is not the connection's resource: `:invalid_target`.
    - For `grant_type=authorization_code`, it checks only the `resource` param against the grant's connection (`OauthAccessGrant.by_token(params[:code])`).
  - `#create` first runs `RateLimiter.hit_ip(:oauth_token, visitor_ip)`, which gives a 429 with `Retry-After` when exceeded. Then it runs the gate.
    - A refusal renders `{"error": "<code>", "error_description": "..."}` with status 400 and `Cache-Control: no-store`.
    - Otherwise it calls `super`.
  - `#revoke` is Doorkeeper's, behind the same rate limit.

- [ ] **Step 1: Write the failing tests.** In `flow_test.rb`, each test runs DCR → sign in → authorize GET → Approve → token, as integration requests:
- **Exchange.** The code plus the right verifier gives 200 with `access_token`, `refresh_token`, `token_type "Bearer"`, `expires_in 3600` and `scope "books:read"`. That access token can `tools/list` on `/api/mcp`.
- **PKCE (Review Focus 2).** A wrong verifier is `invalid_grant`. A missing verifier is `invalid_request`.
- **Single use.** A reused code is `invalid_grant`.
- **Resource.** `resource=<base>/api/mcp/admin` on the exchange is 400 `invalid_target`. `resource=<base>/api/mcp` succeeds.
- **Refresh.**
  - Refresh without `scope` keeps `books:read`.
  - The old refresh token still works until the new access token is first used. After that it is `invalid_grant`, and the connection is revoked (reuse).
  - Two refreshes with the same refresh token back to back both return 200 (concurrent refresh, D11).
- **Re-approve (Review Focus 4).** Approve, refresh once, use the new token, then approve again. Presenting the first refresh token gets `invalid_grant`, and the new connection stays live with working tokens.
- **Lapse.** Lapse the membership. The access token gets 401 `invalid_token` on `/api/mcp`, with the `resource_metadata` challenge. The refresh is `invalid_grant` and the connection is revoked. Renewing the membership still leaves the refresh `invalid_grant`.
- **Wrong client.** Refreshing with another client's `client_id` is `invalid_grant`.
- **Revoke.** Revoking with the right `client_id` gives 200, and the access token then gets 401. Revoking with another client's id gives 403.
- **Rate limit.** The 31st token request in a minute from one IP gets 429. From an Anthropic-range IP it does not.
- **Sign-out.** After the member signs out of the site (`POST /auth/sign_out`), the access token still works.

`token_gate_test.rb` covers each refusal branch in isolation, plus the not-found pass-through.

- [ ] **Step 2: Verify they fail. Step 3: Implement. Step 4: Run** `bin/rails test test/lib/services/oauth test/integration/oauth test/controllers/oauth`, then the full `bin/rails test` and `bundle exec standardrb`. Expected: all green, no new warnings.
- [ ] **Step 5: Commit** `OAuth token endpoint: exchange, refresh rotation, reuse and lapse refusal, revoke`

---

### Task 8: Docs and launch steps

**Files:**
- Modify: `docs/features/mcp-server.md` (a "Signing in with OAuth" section), `docs/features/public-api.md` (one paragraph: OAuth tokens work only on `/api/mcp`; REST keeps personal tokens), `docs/launch-todo.md`

**Interfaces:**
- Produces: documentation only. Use the `avoid-ai-writing` skill on the new prose.

- [ ] **Step 1: `mcp-server.md`.** Describe:
  - the flow: discovery → DCR → authorize → token;
  - the connection record and its server-stamped id;
  - audience binding by path;
  - rotation and reuse (P-e);
  - lapse → 401 → re-sign-in;
  - the budgets (P-h), naming config keys, not numbers;
  - what increments 2 and 3 add.
  
  Name the edge change only as "a rule in the private Cloudflare repo"; give no details.
- [ ] **Step 2: `launch-todo.md`.** Add a section "MCP sign-in (OAuth)" with three steps:
  1. Apply the edge change for the `/.well-known/oauth-*` paths (the private repo's PR) **before the first claude.ai connection**.
  2. Confirm that `config.hosts` and the MCP transport's `allowed_hosts` include the production books hostname.
  3. At the thegreatestbooks.org switch (§7), members re-add the connector with the new URL. Connections survive, but claude.ai drops `Authorization` across redirects (D17).
- [ ] **Step 3: Commit** `Document MCP OAuth sign-in and its launch steps`

---

### Task 9 (controller, not a subagent): the edge change and acceptance

- [ ] **Step 1: Prepare the edge change** in `../the-greatest-cloudflare`, following that repo's `AGENTS.md` (pull → edit → diff, guards).
  - First check `git status` there and do not disturb another branch's work.
  - The change gives the `/.well-known/oauth-*` paths the treatment `/api/*` already has, with a guard that a machine client gets the document and not a challenge.
  - Commit it on a new branch, local only. Push and open its PR only when Shane says so. Never run `cfrules apply`.
  - Nothing about it goes in this repo.
- [ ] **Step 2: Acceptance against the dev server.** First check the port with the `AGENTS.md` check.
  - **Claude Code:** `claude mcp add --transport http tgb-dev https://<dev books host>/api/mcp`, then `/mcp` → Authenticate. Sign in, approve, and ask a books question.
  - **Codex:** `codex mcp add` with the URL, then `codex mcp login`.
  
  Record the outcome (client version, what happened) in the ledger. claude.ai acceptance waits for production and for Shane applying Step 1's PR (spec increment 1 "Done when").
