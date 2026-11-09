# MCP OAuth Increment 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member can connect an MCP client from the `/developers` docs alone, see and revoke that connection on `/developers/tokens` (even after their membership lapses), and the OAuth tables stop growing without bound.

**Architecture:** A "Connected apps" section on the existing tokens page, with its own small `Developers::ConnectionsController#destroy` that calls the existing `Services::Oauth::Connections.revoke!`. The tokens page's gate widens from "can mint" to "can mint OR has a live connection"; minting stays gated. A daily Sidekiq job prunes unused DCR clients, used/expired authorization codes and token rows nothing can ever check again, and keeps the revoked token rows reuse detection reads. Two carried hardening items: IPv6 callers are counted per /64 in every per-IP window, and the token/revoke endpoint sets `no-store` before Doorkeeper can render.

**Tech Stack:** Rails 8, Doorkeeper 5.9.9, Sidekiq + sidekiq-cron (`config/schedule.yml`), Turbo Streams, DaisyUI 5, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md` (increment 3; decisions D5, D6, D11, D14). Increments 1 and 2 are merged (#457, #471).

## Global Constraints

- Run Rails/yarn commands from `web-app/`. Lint is `bundle exec standardrb`. Never run brakeman.
- Jobs are generated with `bin/rails generate sidekiq:job <name>` and live in `app/sidekiq/`. Controllers with `bin/rails generate controller`.
- Controller tests assert behaviour (status, records, redirects, element ids), never copy or CSS.
- Every new user-facing flow gets a Playwright test. E2E ports: before `yarn test:e2e`, confirm port 3000 belongs to this worktree (AGENTS.md snippet); never kill another checkout's server.
- Inside `Services::Oauth` and `Developers`, root-anchor `::Oauth::`, `::Api::` constants (namespace shadowing).
- Never use Doorkeeper's `doorkeeper:db:cleanup` task or `Doorkeeper::StaleRecordsCleaner` for tokens: it deletes revoked rows, which reuse detection (D11) needs.
- No zone/edge details in this repo. Movies is out of scope.
- `/developers` is edge-cached and identical for every visitor: never read `current_user` there, and it must not mention `/api/mcp/admin` (`developers_controller_test.rb` already refutes it).

## Review Focus

1. **A lapsed member with a live connection opens `/developers/tokens`** → sees Connected apps and can revoke, but cannot create or revoke personal tokens (create/destroy still redirect to `/membership`). Pinned in Task 1 and Task 2.
2. **Revoking another user's connection id, or an already-revoked one** → 404, nothing changes. Pinned in Task 2.
3. **Pruning a connection that is live but has a rotated (revoked) refresh token created after `approved_at`** → the row survives, and presenting that refresh token afterwards still revokes the connection. Pinned in Task 3.
4. **Two IPv6 addresses in the same /64 registering clients** → share one `oauth_register` budget; an IPv4-mapped IPv6 address is counted as its IPv4. Pinned in Task 4.
5. **A connection whose application has several redirect URIs, or whose resource key left the registry** → the row renders (hosts joined, resource shown by key) and Revoke still works. Pinned in Task 1 and Task 2.

---

### Task 1: Connected apps list and the widened page gate

**Files:**
- Modify: `web-app/app/controllers/developers/tokens_controller.rb`
- Create: `web-app/app/views/developers/tokens/_connections.html.erb`
- Modify: `web-app/app/views/developers/tokens/index.html.erb`
- Modify: `web-app/app/models/oauth_connection.rb` (one helper method, see below)
- Test: `web-app/test/controllers/developers/tokens_controller_test.rb`, `web-app/test/models/oauth_connection_test.rb`

**Interfaces:**
- Produces: partial `developers/tokens/connections` taking local `connections:`; its root is `<section id="developers_connections">`, one `<tr id="<%= dom_id(connection) %>">` per connection. Task 2's Turbo Stream replaces `developers_connections` with this partial.
- Produces: `OauthConnection.listed` scope = `live.includes(:application).order(approved_at: :desc, id: :desc)`; `TokensController` sets `@connections = current_user.oauth_connections.listed` on `index`. Task 2 reuses the scope.
- Produces: `TokensController#can_mint?` (private, helper_method) = `::Api::Scopes.mintable_by(current_user).any?`.
- Produces: `OauthConnection#redirect_hosts -> Array<String>`: unique hosts of `application.redirect_uri.split` in order, `URI(uri).host` (so `localhost`, `127.0.0.1`, `[::1]`… loopback ports are not shown; hosts only); an unparsable URI is skipped.

- [ ] **Step 1: Write failing tests**

In `tokens_controller_test.rb` (the existing gate tests stay as they are):

```ruby
test "a lapsed member with a live connection sees the page" do
  user = users(:user_with_expired_membership)
  connection = OauthConnection.create!(user: user, application: oauth_applications(:claude_ai),
    resource: "mcp", scopes: ["books:read"], approved_at: 2.days.ago)
  sign_in_as(user, stub_auth: true)

  get developers_tokens_path

  assert_response :success
  assert_select "#developers_connections ##{ActionView::RecordIdentifier.dom_id(connection)}", 1
  assert_select "#developers_token_form", 0
  assert_select "#developers_tokens", 0
end

test "a lapsed member whose only connection is revoked is still redirected" do
  user = users(:user_with_expired_membership)
  OauthConnection.create!(user: user, application: oauth_applications(:claude_ai), resource: "mcp",
    scopes: ["books:read"], approved_at: 2.days.ago, revoked_at: 1.day.ago)
  sign_in_as(user, stub_auth: true)

  get developers_tokens_path

  assert_redirected_to membership_path
end

test "a lapsed member with a live connection still cannot create a token" do
  # create the connection as above, sign in, POST developers_tokens_path with valid params
  # assert_redirected_to membership_path; assert no ApiToken created
end

test "a member sees only their own live connections" do
  sign_in_as(users(:regular_user), stub_auth: true)
  revoked = OauthConnection.create!(user: users(:regular_user), application: oauth_applications(:claude_ai),
    resource: "mcp", scopes: ["books:read"], approved_at: 3.days.ago, revoked_at: 1.day.ago)

  get developers_tokens_path

  assert_select "#developers_connections tbody tr", 1   # member_mcp fixture
  assert_select "##{ActionView::RecordIdentifier.dom_id(oauth_connections(:member_mcp))}", 1
  assert_select "##{ActionView::RecordIdentifier.dom_id(revoked)}", 0
  assert_select "##{ActionView::RecordIdentifier.dom_id(oauth_connections(:admin_mcp))}", 0
end

test "a connection whose resource left the registry still renders" do
  oauth_connections(:member_mcp).update_column(:resource, "retired")
  sign_in_as(users(:regular_user), stub_auth: true)

  get developers_tokens_path

  assert_response :success
  assert_select "##{ActionView::RecordIdentifier.dom_id(oauth_connections(:member_mcp))}", 1
end
```

In `oauth_connection_test.rb`:

```ruby
test "redirect_hosts lists each host once, in order, skipping unparsable URIs" do
  app = OauthApplication.create!(name: "Multi", confidential: false, scopes: "",
    redirect_uri: "https://claude.ai/api/mcp/auth_callback\nhttps://claude.com/cb\nhttps://claude.ai/other")
  connection = OauthConnection.new(application: app)
  assert_equal ["claude.ai", "claude.com"], connection.redirect_hosts
end

test "redirect_hosts shows a loopback host without its port" do
  assert_equal ["localhost"], oauth_connections(:member_mcp).redirect_hosts
end
```

- [ ] **Step 2: Run them, confirm they fail**

Run: `bin/rails test test/controllers/developers/tokens_controller_test.rb test/models/oauth_connection_test.rb`
Expected: the new tests fail (redirect to membership; missing `#developers_connections`; `NoMethodError redirect_hosts`).

- [ ] **Step 3: Implement**

- `require_api_access!` → allowed when `current_user && (can_mint? || current_user.oauth_connections.live.exists?)`, else `require_membership!(:api)`. Add `before_action :require_mint_access!, only: [:create, :destroy]` that calls `require_membership!(:api)` unless `current_user && can_mint?` (so the personal-token write actions keep today's rule exactly).
- `index` sets `@connections` from one private `connections` method. The token create/destroy streams do not render the section, so they do not need it.
- `index.html.erb`: when `can_mint?`, render the existing tokens list, `#developers_new_token`, and the form, exactly as now. When not, render one paragraph saying creating tokens needs membership with a link to `membership_path`, and none of the three. Then, in both cases, render `developers/tokens/connections`.
- `_connections.html.erb`: `<section id="developers_connections" class="mb-10">`, heading "Connected apps", one sentence saying these are AI assistants and other apps you signed in to and that revoking one signs it out. Empty state: a short "No apps are connected." line. Otherwise a `.table` inside `.overflow-x-auto` with columns: App (`connection.application.name`, with `[overflow-wrap:anywhere]`), Signs in through (`redirect_hosts.join(", ")`), Access (`::Oauth::Resources::ALL[connection.resource]` → "Admin" when `admin`, "Member" otherwise; an unknown key shows the raw key), Scopes (`scopes.join(", ")`), Approved (`approved_at.to_date.to_fs(:long)`), Last used (`time_ago_in_words … ago` or "Never"), and an empty actions cell (Task 2 fills it). Mirror `_list.html.erb`'s markup and its DaisyUI 5 classes; no removed v4 classes.
- `OauthConnection#redirect_hosts` as in Interfaces (rescue `URI::InvalidURIError` per URI).

- [ ] **Step 4: Run tests, confirm pass**

Run: `bin/rails test test/controllers/developers/ test/models/oauth_connection_test.rb`
Expected: all green, including the existing tokens tests.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/controllers/developers app/models/oauth_connection.rb test/controllers/developers test/models/oauth_connection_test.rb
git add -A app/controllers/developers app/views/developers app/models/oauth_connection.rb test/controllers/developers test/models/oauth_connection_test.rb
git commit -m "Show Connected apps on /developers/tokens, including to a lapsed member"
```

---

### Task 2: Revoke a connection, end to end

**Files:**
- Create (generator): `web-app/app/controllers/developers/connections_controller.rb` (`bin/rails generate controller developers/connections --skip-routes --no-helper --no-assets`; delete any generated view dir it creates if unused)
- Create: `web-app/app/views/developers/connections/destroy.turbo_stream.erb`
- Modify: `web-app/config/routes.rb` (inside `namespace :developers`, next to `resources :tokens`)
- Modify: `web-app/app/views/developers/tokens/_connections.html.erb` (the Revoke button)
- Modify: `web-app/e2e/helpers/oauth-client.ts`
- Test: `web-app/test/controllers/developers/connections_controller_test.rb`, `web-app/e2e/tests/books/member/connected-apps.spec.ts`

**Interfaces:**
- Consumes: Task 1's partial `developers/tokens/connections` (local `connections:`), `#developers_connections`, `dom_id(connection)` rows.
- Consumes: `Services::Oauth::Connections.revoke!(connection, at: Time.current)` (existing; revokes the connection and every live token and grant under it).
- Produces: route `resources :connections, only: [:destroy]` → `developers_connection_path(connection)`, `DELETE`.
- Produces (E2E helper): `registerClient(request, port, options)` gains `options.clientName?: string` (default stays `'E2E client'`), and the returned `OauthClient` gains `verifier: string` and `clientName: string`.

- [ ] **Step 1: Write failing controller tests**

```ruby
module Developers
  class ConnectionsControllerTest < ActionDispatch::IntegrationTest
    TURBO = {"Accept" => "text/vnd.turbo-stream.html, text/html"}.freeze
    setup { host! Rails.application.config.domains[:books].to_s.split(",").first }

    test "a member revokes their connection and every token under it" do
      connection = oauth_connections(:member_mcp)
      token = OauthAccessToken.create!(application: connection.application, connection: connection,
        resource_owner_id: connection.user_id, scopes: "books:read", expires_in: 3600)
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_connection_path(connection), headers: TURBO

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert connection.reload.revoked?
      assert token.reload.revoked?
      assert_select "turbo-stream[action=replace][target=developers_connections]", 1
    end

    test "a lapsed member can revoke their connection" do
      # user_with_expired_membership + a live connection created in the test; delete; assert revoked
    end

    test "another user's connection is a 404 and stays live" do
      sign_in_as(users(:regular_user), stub_auth: true)
      delete developers_connection_path(oauth_connections(:admin_mcp)), headers: TURBO
      assert_response :not_found
      assert_not oauth_connections(:admin_mcp).reload.revoked?
    end

    test "an already-revoked connection is a 404 and keeps its revoked_at" do
      connection = oauth_connections(:member_mcp)
      connection.update_columns(revoked_at: 2.days.ago)
      sign_in_as(users(:regular_user), stub_auth: true)
      assert_no_changes -> { connection.reload.revoked_at } do
        delete developers_connection_path(connection), headers: TURBO
      end
      assert_response :not_found
    end

    test "a connection whose resource left the registry can still be revoked" do
      oauth_connections(:member_mcp).update_column(:resource, "retired")
      sign_in_as(users(:regular_user), stub_auth: true)
      delete developers_connection_path(oauth_connections(:member_mcp)), headers: TURBO
      assert oauth_connections(:member_mcp).reload.revoked?
    end

    test "a signed-out visitor is redirected to the membership page" do
      delete developers_connection_path(oauth_connections(:member_mcp)), headers: TURBO
      assert_redirected_to membership_path
      assert_not oauth_connections(:member_mcp).reload.revoked?
    end

    test "the response is never cached" do
      # member delete; assert_includes response.headers["Cache-Control"], "no-store"
    end
  end
end
```

Check the `OauthAccessToken.create!` attributes against `db/schema.rb` (`oauth_access_tokens`) and the existing fixtures/tests in `test/lib/services/oauth/connections_test.rb`; reuse whatever helper those tests use to build a token.

- [ ] **Step 2: Run, confirm failure**

Run: `bin/rails test test/controllers/developers/connections_controller_test.rb`
Expected: fail on the missing route / controller.

- [ ] **Step 3: Implement**

- `Developers::ConnectionsController < ApplicationController`, `include Cacheable`, `before_action :prevent_caching`, and a sign-in gate: signed out → `redirect_to membership_path, alert: "Sign in to your membership to open that page."` (the MembershipGated wording; no membership check: D14). `destroy`: `current_user.oauth_connections.live.find(params[:id])` (404 otherwise), `::Services::Oauth::Connections.revoke!(connection)`, `@connections = current_user.oauth_connections.listed` (Task 1's scope), `render :destroy, formats: [:turbo_stream]`.
- `destroy.turbo_stream.erb`: `turbo_stream.replace "developers_connections"` rendering `developers/tokens/connections`. It must not touch `#developers_new_token` (same rule as token destroy).
- Revoke button in the row's actions cell: `button_to "Revoke", developers_connection_path(connection), method: :delete, class: "btn btn-sm btn-outline", "aria-label": "Revoke #{connection.application.name}", form: {data: {turbo_confirm: "Revoke #{connection.application.name}? It is signed out immediately and has to sign in again."}}`.

- [ ] **Step 4: Run, confirm pass**

Run: `bin/rails test test/controllers/developers/`
Expected: green.

- [ ] **Step 5: Write the E2E spec**

`e2e/tests/books/member/connected-apps.spec.ts` (project `books-member`, loopback port **43105**, unused by other specs). Install the `page.on('dialog', d => d.accept())` handler in `beforeEach`. Each run uses a unique name, `E2E connected app ${Date.now()}`, so leftovers from a crashed run never match; `afterEach` revokes the row if still present.

```ts
test('approve a client, see it under Connected apps, revoke it, and its code stops working', async ({ page, request }) => {
  const client = await registerClient(request, 43105, { clientName });
  await page.goto(client.authorizeUrl);
  await page.getByTestId('oauth-approve').click();
  await page.waitForURL(client.callbackPattern);
  const code = new URL(page.url()).searchParams.get('code')!;

  await page.goto('/developers/tokens');
  const row = page.locator('#developers_connections tr', { hasText: clientName });
  await expect(row).toContainText('127.0.0.1');
  await expect(row).toContainText('books:read');

  await row.getByRole('button', { name: `Revoke ${clientName}` }).click();
  await expect(page.locator('#developers_connections tr', { hasText: clientName })).toHaveCount(0);

  // Revoke ends the unexchanged code too (Connections.revoke! revokes grants).
  const token = await request.post('/api/oauth/token', { form: {
    grant_type: 'authorization_code', code, redirect_uri: client.redirectUri,
    client_id: client.clientId, code_verifier: client.verifier } });
  expect(token.status()).toBe(400);
  expect((await token.json()).error).toBe('invalid_grant');
});
```

Plus a phone-width check (`page.setViewportSize({ width: 375, height: 800 })`): the Connected apps table does not make the page scroll horizontally (`document.documentElement.scrollWidth <= 375`).

- [ ] **Step 6: Run the E2E spec**

Check port 3000 belongs to this worktree (AGENTS.md snippet). If free: `yarn build:all` then start `bin/rails server` in the background. Run: `yarn test:e2e e2e/tests/books/member/connected-apps.spec.ts e2e/tests/books/member/oauth-authorize.spec.ts e2e/tests/books/oauth-authorize.spec.ts e2e/tests/books/account/oauth-authorize.spec.ts e2e/tests/books/member/developers-tokens.spec.ts`
Expected: all pass. If port 3000 is another checkout's, stop and report it.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/controllers/developers app/models/oauth_connection.rb test/controllers/developers
git add -A app/controllers/developers app/views/developers app/models/oauth_connection.rb config/routes.rb test/controllers/developers e2e
git commit -m "Revoke a connected app from /developers/tokens"
```

---

### Task 3: Prune the OAuth tables

**Files:**
- Create (generator): `bin/rails generate sidekiq:job oauth/prune` → `web-app/app/sidekiq/oauth/prune_job.rb`, `web-app/test/sidekiq/oauth/prune_job_test.rb`
- Create: `web-app/app/lib/services/oauth/pruner.rb`, `web-app/test/lib/services/oauth/pruner_test.rb`
- Modify: `web-app/config/schedule.yml`, `web-app/config/initializers/api.rb`

**Interfaces:**
- Consumes: `OauthConnection` (`live` scope, `approved_at`, `revoked_at`), `OauthAccessToken`, `OauthAccessGrant`, `OauthApplication` (`has_many :connections`).
- Produces: `Services::Oauth::Pruner.call(now: Time.current) -> Result` with `data: {applications:, grants:, tokens:}` (Integer counts deleted). `Oauth::PruneJob#perform` calls it and logs one line `event=oauth_prune applications=N grants=N tokens=N`.
- Produces config: `config.x.api.oauth_unused_client_lifetime = 30.days` (D6), `config.x.api.oauth_grant_retention = 1.day`.

**What is deleted, and why (the rules the tests pin):**

| Rows | Deleted when | Why it is safe |
| --- | --- | --- |
| `oauth_applications` | `created_at < now - oauth_unused_client_lifetime` and **no `oauth_connections` row at all** (live or revoked) | D6 "no grant after 30 days". A connection is created on Approve, before the first grant, so an app with none never got one. Grants could not be used as the test: they are pruned below. |
| `oauth_access_grants` | `created_at < now - oauth_grant_retention` | Codes live 10 minutes. Replaying a deleted code is `invalid_grant`, the same answer as a used one. |
| `oauth_access_tokens` under a **revoked** connection | always | `TokenGate` refuses a revoked connection; a deleted refresh token gets Doorkeeper's `invalid_grant`, an access token the authenticator's 401. Same answers. |
| `oauth_access_tokens` under a **live** connection with `created_at < connection.approved_at` | always | Stale from before a re-approval: TokenGate already answers `invalid_grant` without revoking; unknown gives the same. |
| `oauth_access_tokens` under a live connection, `created_at >= approved_at`, **revoked** | **never** | Reuse detection (D11) needs them: presenting one revokes the connection. |
| Live, unrevoked tokens | never | They are the connection's working refresh tokens, expired access part or not. |

Connections are never deleted (no row is). Delete in batches (`in_batches(of: 1_000).delete_all`), never `destroy` (no callbacks needed; `OauthApplication` has `dependent: :destroy` but an app being pruned has no connections). Revoked-connection tokens and stale tokens are found with a join on `oauth_connections`, not by loading connections.

- [ ] **Step 1: Write failing tests** in `pruner_test.rb` (travel_to a fixed time; build rows in the test):

- `"deletes an unused client older than the lifetime and keeps a younger one"`: app created 31 days ago with no connections → gone; app created 29 days ago → kept; `result.data[:applications] == 1`.
- `"keeps an old client that has a connection, even a revoked one"`.
- `"deletes grants older than the retention and keeps recent ones"`: grant created 2 days ago → gone; 5 minutes ago → kept.
- `"deletes every token of a revoked connection"`.
- `"deletes tokens created before a live connection's approved_at"`.
- `"keeps a revoked token created after approved_at on a live connection"` — the Review Focus #3 test: after `Pruner.call`, the row exists, and `Services::Oauth::TokenGate.call` with `grant_type: "refresh_token"` and that row's plaintext refresh token revokes the connection. Use however `test/lib/services/oauth/token_gate_test.rb` builds a token with a known plaintext refresh token (secrets are hashed).
- `"keeps live unrevoked tokens, expired access part included"`.

`prune_job_test.rb`: `"runs the pruner"` (an old unused app is gone after `Oauth::PruneJob.new.perform`).

- [ ] **Step 2: Run, confirm failure**

Run: `bin/rails test test/lib/services/oauth/pruner_test.rb test/sidekiq/oauth/prune_job_test.rb`
Expected: `NameError` for `Services::Oauth::Pruner`.

- [ ] **Step 3: Implement** the pruner (Result struct as in `Services::Oauth::Connections`), the job, the two config values in `config/initializers/api.rb` next to `oauth_admin_approval_lifetime` (comment cites D6 and that the grant retention is far above Doorkeeper's 10-minute code life), and a `config/schedule.yml` entry:

```yaml
oauth_prune:
  class: Oauth::PruneJob
  cron: "45 3 * * *"
  description: "Delete unused OAuth clients, old authorization codes and token rows no check can reach; keeps revoked rows reuse detection needs"
```

Check `config/schedule.yml` is validated by an existing test (grep `schedule.yml` under `test/`); if so, it must still pass.

- [ ] **Step 4: Run, confirm pass**

Run: `bin/rails test test/lib/services/oauth/ test/sidekiq/oauth/ test/integration/oauth/`
Expected: green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/oauth app/sidekiq/oauth test/lib/services/oauth test/sidekiq/oauth config/initializers/api.rb
git add -A app/lib/services/oauth app/sidekiq/oauth test/lib/services/oauth test/sidekiq/oauth config/initializers/api.rb config/schedule.yml
git commit -m "Prune unused OAuth clients, old codes and unreachable token rows daily"
```

---

### Task 4: IPv6 /64 rate-limit keying and `no-store` on every token-endpoint answer

**Files:**
- Modify: `web-app/app/lib/services/api/rate_limiter.rb` (`ip_budget`)
- Modify: `web-app/app/controllers/oauth/tokens_controller.rb`
- Test: `web-app/test/lib/services/api/rate_limiter_test.rb`, `web-app/test/controllers/oauth/tokens_controller_test.rb`

**Interfaces:**
- Consumes/produces: `RateLimiter.hit_ip(window, ip)` and `peek_ip` keep their signatures. Only the counter subject changes for IPv6 outside connector ranges.

- [ ] **Step 1: Write failing tests**

Rate limiter (use the test file's existing memory-store setup and config stubbing):

- `"two IPv6 addresses in one /64 share an oauth_register budget"`: with `oauth_register_per_minute` = 2, hit `2001:db8:1:2::1` twice and `2001:db8:1:2:ffff::9` once → the third verdict `exceeded?`.
- `"IPv6 addresses in different /64s have separate budgets"`: `2001:db8:1:2::1` ×2 and `2001:db8:1:3::1` ×1 → not exceeded.
- `"an IPv4-mapped IPv6 address counts as its IPv4 address"`: `::ffff:203.0.113.5` and `203.0.113.5` share a budget.
- `"the unauthenticated window also groups IPv6 by /64"` (hit_unauthenticated + peek_unauthenticated agree).
- `"an unparsable address is still counted under its own string"` (no exception).

Tokens controller:

- `"a revoke Doorkeeper refuses is not cacheable"`: `post "/api/oauth/revoke"` with no `client_id` and a random `token` (whatever request reproduces Doorkeeper's own 403/401 refusal; find it by trying) → assert the status is not 200 and `Cache-Control` includes `no-store`.

- [ ] **Step 2: Run, confirm failure**

Run: `bin/rails test test/lib/services/api/rate_limiter_test.rb test/controllers/oauth/tokens_controller_test.rb`

- [ ] **Step 3: Implement**

- In `ip_budget`, after the connector-range branch, replace `ip` in the subject with `subject_address(ip)`: parse with `IPAddr`; IPv4-mapped → `native.to_s`; other IPv6 → `"#{address.mask(64)}/64"`; IPv4 → `to_s`; `IPAddr::Error` → `ip.to_s`. The `:unauthenticated` subject becomes `"anon:#{subject_address(ip)}"` (same prefix as today, so IPv4 keys are unchanged). Comment: one host can rotate through a whole /64, so a per-address window does not bind an IPv6 caller.
- In `Oauth::TokensController`, replace `before_action :prevent_caching` with `prepend_before_action :prevent_caching`, placed on the line **after** `prepend_before_action :enforce_token_rate_limit!`. A later prepend runs first, so the chain becomes prevent_caching → rate limit → Doorkeeper's callbacks, and every answer, Doorkeeper's own refusals included, is `no-store`. The explicit `prevent_caching` call inside `enforce_token_rate_limit!` is then redundant: remove it.

- [ ] **Step 4: Run, confirm pass**

Run: `bin/rails test test/lib/services/api/ test/controllers/oauth/ test/integration/oauth/ test/controllers/api/`
Expected: green.

- [ ] **Step 5: Lint and commit**

```bash
bundle exec standardrb app/lib/services/api/rate_limiter.rb app/controllers/oauth test/lib/services/api test/controllers/oauth
git add app/lib/services/api/rate_limiter.rb app/controllers/oauth/tokens_controller.rb test/lib/services/api/rate_limiter_test.rb test/controllers/oauth/tokens_controller_test.rb
git commit -m "Count IPv6 callers per /64 and keep every token-endpoint answer out of caches"
```

---

### Task 5: Per-client connection instructions on /developers, and the docs

**Files:**
- Modify: `web-app/app/views/developers/show.html.erb` (the `#mcp` section)
- Modify: `web-app/test/controllers/developers_controller_test.rb`, `web-app/e2e/tests/books/developers.spec.ts`
- Modify: `docs/features/mcp-server.md`, `docs/launch-todo.md` (§13)

**Interfaces:**
- Consumes: `@mcp_url` (already `"#{base_url}/api/mcp"`, no trailing slash). Nothing new in the controller.
- Produces element ids: `#mcp-connect` (h3), `#mcp-exact-url`, `#mcp-claude-apps`, `#mcp-claude-code-oauth` (pre), `#mcp-codex` (pre), `#mcp-revoke`. The existing `#mcp-command` and `#mcp-token-setup` stay, under a "With a token instead" sub-heading, with their content unchanged (existing tests pin them).

Page content, in the MCP section after the intro and before the tools list:

- `h3#mcp-connect` "Connect by signing in". One paragraph: most clients need only the address; they open a browser, you sign in to the site and approve; this needs membership; no token to copy.
- `p#mcp-exact-url`: use the address exactly as `<code><%= @mcp_url %></code>`, with no trailing slash; an address ending in `/` is not the server and the client will not find the sign-in.
- `#mcp-claude-apps`: claude.ai and the Claude desktop and mobile apps: Settings → Connectors → Add custom connector, paste the address, leave the OAuth fields empty, then Connect and sign in.
- `pre#mcp-claude-code-oauth`: `claude mcp add --transport http --scope user the-greatest-books <%= @mcp_url %>`, then a sentence: in Claude Code run `/mcp`, choose the-greatest-books and Authenticate.
- `pre#mcp-codex`: two lines, `codex mcp add the-greatest-books --url <%= @mcp_url %>` and `codex mcp login the-greatest-books`; a sentence that remote servers need a recent Codex CLI and that `--url` is what makes it a remote server.
- `p#mcp-revoke`: connected apps are listed at `/developers/tokens` (link), where Revoke signs one out; the app asks you to sign in again next time. Access lasts while the membership does.
- Then `h3` "With a token instead" followed by the existing token paragraphs and `#mcp-command`, unchanged.
- No mention of the admin endpoint. No `current_user`.

- [ ] **Step 1: Failing tests**

`developers_controller_test.rb`, extend the books MCP test (or add one):

```ruby
test "the books page explains connecting by sign-in, for each client" do
  get developers_path
  url = "https://dev-new.thegreatestbooks.org/api/mcp"
  assert_select "h3#mcp-connect", 1
  assert_select "#mcp-exact-url code", text: url
  assert_select "pre#mcp-claude-code-oauth code", text: "claude mcp add --transport http --scope user the-greatest-books #{url}"
  assert_select "pre#mcp-codex code", text: /codex mcp add the-greatest-books --url #{Regexp.escape(url)}\s+codex mcp login the-greatest-books/
  assert_select "#mcp-revoke a[href=?]", developers_tokens_path
  assert_select "#mcp-claude-apps", 1
end
```

(Use the file's existing host setup; the existing "identical signed in and out" and "no /api/mcp/admin" tests must stay green.)

`developers.spec.ts`: in the existing books MCP test, assert `#mcp-claude-code-oauth` and `#mcp-codex` contain `https://dev-new.thegreatestbooks.org/api/mcp` and that neither contains `/api/mcp/` followed by nothing (`not.toContainText('/api/mcp/ ')` is not reliable; instead read `textContent` and assert it does not match `/\/api\/mcp\/(\s|$)/`).

- [ ] **Step 2: Run, confirm failure**

Run: `bin/rails test test/controllers/developers_controller_test.rb`

- [ ] **Step 3: Implement the view**, prose plain and short, matching the page's voice.

- [ ] **Step 4: Run, confirm pass**

Run: `bin/rails test test/controllers/developers_controller_test.rb` and (port check first) `yarn test:e2e e2e/tests/books/developers.spec.ts`.

- [ ] **Step 5: Docs**

- `docs/features/mcp-server.md`, "Signing in with OAuth": add a `### Connected apps` subsection (the section on `/developers/tokens`, who sees it: anyone with a mintable scope or a live connection; minting still needs a mintable scope; Revoke calls `Connections.revoke!`; `Developers::ConnectionsController`), a `### Pruning` subsection (the table of rules from Task 3 in prose, the job name and schedule, and the warning not to use Doorkeeper's cleanup task), and one line under "Rate-limit budgets" that IPv6 is counted per /64. Rewrite `### Increments` to say all three are built; remove the "Until then there is no page for revoking a connection" sentence and the "Connected apps and client pruning" bullet from "Not yet". Update `### Testing` with the new test files and the E2E spec. Update "Clients" (line ~152) to point at the `/developers` instructions.
- `docs/launch-todo.md` §13: add step 5, **Acceptance from the docs alone**: following only `/developers`, connect claude.ai, Claude Code and Codex to `https://<books host>/api/mcp` by signing in; ask each one question; then Revoke each on `/developers/tokens` and confirm each asks to sign in again. Record the result in the PR or the feature doc's acceptance line.

- [ ] **Step 6: Commit**

```bash
git add app/views/developers/show.html.erb test/controllers/developers_controller_test.rb e2e/tests/books/developers.spec.ts ../docs/features/mcp-server.md ../docs/launch-todo.md
git commit -m "Document connecting each MCP client by sign-in on /developers"
```

---

### Final verification (controller, after Task 5)

- `bin/rails test` (full suite) green with no new warning lines; `bundle exec standardrb` clean; `CI=1 bin/rails zeitwerk:check`.
- E2E: the OAuth specs, `member/connected-apps.spec.ts`, `member/developers-tokens.spec.ts`, `books/developers.spec.ts`.
- Manual acceptance (Shane, after deploy): launch-todo §13 step 5.
