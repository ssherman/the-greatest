# MCP sign-in (OAuth) — increment 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An admin adds `https://<books host>/api/mcp/admin` to claude.ai (or Claude Code or Codex), signs in, approves the admin scopes their account holds, and runs admin tools. The connection must be re-approved 30 days after it was approved.

**Architecture:** Increment 1 built everything around one resource registry, `::Oauth::Resources`. This increment adds a second entry, `mcp_admin` → `/api/mcp/admin`, whose scopes are the domain's `*:admin:*` scopes. Most of the work then follows from the registry:
- the authenticator's audience check;
- the 401 challenge;
- the discovery documents;
- `resource` inference;
- the authorize page.

On top of that, this increment adds:
- one shared "does this connection still have a usable scope for its resource" check, used by the authenticator and the token gate;
- the 30-day admin refresh limit in `TokenGate`;
- discovery routes built from the registry;
- refusal pages that give the real reason.

**Tech Stack:** Rails 8.1, Doorkeeper 5.9.9, Minitest + fixtures + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md`, **increment 2**. Its "done when" is: an admin connects claude.ai to `/api/mcp/admin` and runs a dry-run merge. Read increment 1's plan for context: `docs/superpowers/plans/2026-11-06-mcp-oauth-increment-1.md` (decisions P-a…P-l still hold). Background: `docs/features/mcp-server.md` ("Signing in with OAuth").

## Global Constraints

- Run Rails commands from `web-app/`. Lint with `bundle exec standardrb`. Never run rubocop or brakeman. Run one `bin/rails test` process at a time per worktree. Never run a destructive command against the development database.
- This increment adds no migration. If one seems necessary, stop and report.
- **Root-anchor constants.** Inside `Services::Oauth`, write `::Oauth::Resources`, `::Api::Scopes` and `::OauthConnection`.
- **Domain-neutral.** Resource scopes come from `Current.domain` or an explicit `domain` argument, never the literal `books`. URLs come from `Api::Host.base_url`.
- **The member endpoint is unchanged.** Every `/api/mcp` behaviour pinned by increment 1's tests stays as it is.
- **REST is untouched.** An OAuth token is still a 401 on every `/api/v1/*` route, and REST 401 challenges are byte-for-byte as today.
- **Audience binding holds both ways.** A `mcp` token is a 401 on `/api/mcp/admin`, and a `mcp_admin` token is a 401 on `/api/mcp`. A separate connector entry per endpoint is the intended use.
- **Existing tests that must change**, and only these. Each one pinned increment 1's "admin is not a resource yet":
  - `test/controllers/api/mcp_controller_test.rb`: "the admin endpoint's 401 keeps the bare Bearer challenge".
  - `test/controllers/oauth/metadata_controller_test.rb`: "the admin endpoint has no protected resource document", plus the exact AS `scopes_supported`.
  - `test/lib/oauth/resources_test.rb`: `for_path`/`for_url` returning nil for admin, and "infer is mcp … while no admin resource exists".
  - `test/controllers/oauth/authorizations_controller_test.rb`: "the admin endpoint is not a resource in this increment".
  
  Any other existing test that has to change: stop and report.
- Controller tests assert behaviour, never copy. Stub nothing in Doorkeeper.
- **Never copy Cloudflare zone details into this repo.** The existing `/.well-known/oauth-` edge rule already covers the new admin discovery path, so this increment needs no edge change.
- A clean `bin/rails test` prints no new warnings.

## Decisions this plan makes (spec leaves them to the builder)

- **Q-a. Admin resource scopes** are every registered scope that is `Api::Scopes.admin?` and starts with `"#{domain}:"`, in registry order. On books that is `books:admin:read`, `books:admin:write`, `books:admin:merge`. `Resource#scopes(domain)` branches on `admin`.
- **Q-b. Usable scopes.** `::Oauth::Resources.usable_scopes(connection, domain)` returns `Api::Scopes.effective(connection.scopes, connection.user)` when that set intersects the connection's resource scopes, and `[]` otherwise.
  - A demoted admin's admin connection becomes `[]`, even though `effective` still yields an implied `books:read` for a member. So the client gets a 401 and re-prompts (D12, goal 2) instead of a 403 from `McpAdminController`'s scope check.
  - The principal's scopes are the full effective set, `books:read` included, so admin tools that dispatch to `books:read` endpoints still work.
- **Q-c. The 30-day limit** is `config.x.api.oauth_admin_approval_lifetime = 30.days` in `config/initializers/api.rb`.
  - It applies to refresh only: an access token already issued lives out its hour.
  - Past the limit, a refresh is `invalid_grant` and the connection is **not** revoked. The admin signs in again, and approving resets `approved_at` (D5).
  - Exactly at the limit is still allowed; one second past is refused.
- **Q-d. Refusal reasons on the authorize page.** When nothing is grantable, the controller sets `@refusal`:
  - `:admin_required`: the resource is admin.
  - `:membership_required`: the resource is not admin, and the user holds none of its scopes.
  - `:scope_unavailable`: the member asked only for scopes this endpoint does not offer.
  
  One `ineligible` template renders per-reason copy. Only `:membership_required` links to `/membership`. A `data-testid="oauth-refusal-<reason>"` hook on the card replaces `oauth-ineligible`; update the three tests that use it.
- **Q-e. Discovery routes come from the registry.** `config/routes.rb` loops over `::Oauth::Resources::ALL` and draws `get resource.metadata_path` → `oauth/metadata#protected_resource` with `defaults: {resource_key: resource.key}`. The root `/.well-known/oauth-protected-resource` stays pinned to `mcp`, as D8 requires. A routing test ties every registry entry to its route.
- **Q-f. The approval screen** lists each granted scope's `Api::Scopes.description`. For an admin connection it adds one line, which is exact copy: "Admin access must be approved again after 30 days." Nothing else changes on the page.

## Review Focus

1. **A demoted admin's admin connection.** It is a 401 `invalid_token` with the admin challenge on the next request, never a 403. Its refresh is `invalid_grant` and revokes the connection, and re-promoting does not revive it. Owners: Task 1 (401), Task 2 (refresh).
2. **Cross-endpoint use.** A `mcp_admin` token on `/api/mcp` is a 401. A `mcp` token on `/api/mcp/admin` is a 401 with the admin challenge, so the client re-prompts for the admin resource. Owner: Task 1.
3. **No `resource` but admin scopes.** An authorize request with no `resource` and `scope=books:admin:read` becomes an admin connection. With `scope=books:read` it is a member connection. Owner: Task 4.
4. **The 30-day boundary.** A refresh at 29 days 23 hours succeeds. One a minute past 30 days is `invalid_grant`, and the connection stays live. After re-approval the refresh works again. Owner: Task 2.
5. **An admin with only `books:admin:read`** (a books viewer) is granted only that scope. The approval screen lists only it, and a write tool call is a 403 `insufficient_scope`, the existing step-up signal. Owners: Task 4 (grant), Task 1 (403).

---

### Task 1: The admin resource, usable scopes, authenticator and challenge

**Files:**
- Modify: `app/lib/oauth/resources.rb`, `app/lib/services/api/authenticator.rb`
- Test: `test/lib/oauth/resources_test.rb`, `test/lib/services/api/authenticator_test.rb`, `test/controllers/api/mcp_controller_test.rb`; add a fixture `oauth_connections.admin_mcp` (user `admin_user`, application `claude_code`, resource `mcp_admin`, scopes the three admin scopes)

**Interfaces:**
- Produces:
  - `ALL["mcp_admin"] = Resource(key: "mcp_admin", path: "/api/mcp/admin", admin: true)`.
  - `Resource#scopes(domain)` (Q-a).
  - `::Oauth::Resources.usable_scopes(connection, domain) -> Array<String>` (Q-b).
  - `infer` now returns `mcp_admin` for any admin scope; its code needs no change.
  - The authenticator's OAuth branch uses `usable_scopes(token.connection, Current.domain)` and fails `:invalid_token` when it is empty.
  - `Api::Authentication#bearer_challenge` is unchanged. Through `for_path` it now emits `resource_metadata="<base>/.well-known/oauth-protected-resource/api/mcp/admin", scope="books:admin:read books:admin:write books:admin:merge"` for `/api/mcp/admin`.

- [ ] **Step 1: Write the failing tests.**
  - `resources_test`:
    - `fetch("mcp_admin").scopes(:books) == ["books:admin:read", "books:admin:write", "books:admin:merge"]`;
    - `for_path("/api/mcp/admin")` and `for_url(base + "/api/mcp/admin", base)` are `mcp_admin`;
    - `infer(["books:admin:merge"])` is `mcp_admin`; `infer(["books:read"])` and `infer([])` are `mcp`;
    - `all_scopes(:books)` is `["books:read", "books:admin:read", "books:admin:write", "books:admin:merge"]`;
    - `usable_scopes`: for `admin_mcp` it includes the three admin scopes; after the admin's role is removed (as the existing admin-policy tests demote a user) it is `[]`, even if the user has a membership; for `member_mcp` it is `["books:read"]`.
  - `authenticator_test`:
    - an `admin_mcp` token on `/api/mcp/admin` gives an `:admin` tier principal whose scopes include `books:admin:merge` and `books:read`;
    - the same token on `/api/mcp` and on `/api/v1/books` is `:invalid_token`;
    - a `member_mcp` token on `/api/mcp/admin` is `:invalid_token`;
    - after demotion, the `admin_mcp` token is `:invalid_token`.
  - `mcp_controller_test`:
    - replace "the admin endpoint's 401 keeps the bare Bearer challenge" with an exact-header test of the admin challenge above;
    - a live `admin_mcp` token can `tools/list` on `/api/mcp/admin` and sees `merge_book`;
    - a connection holding only `books:admin:read` (a `books_viewer`-style user; check the role fixtures) can call `search_admin_books`, but `merge_book` with `dry_run: true` is answered with the existing insufficient-scope result;
    - an `admin_mcp` token can call `merge_book` with `dry_run: true` (spec "done when").

- [ ] **Step 2: Verify they fail. Step 3: Implement.** Update the class comments: increment 1's note "registers `mcp` only" becomes the two-entry truth.
- [ ] **Step 4: Run** the three files, then `bin/rails test test/controllers/api test/lib/oauth test/lib/services`. Expected: PASS.
- [ ] **Step 5: Commit** `OAuth: the admin MCP endpoint is a resource; usable scopes decide 401`

---

### Task 2: Token gate — usable scopes and the 30-day admin limit

**Files:**
- Modify: `app/lib/services/oauth/token_gate.rb`, `config/initializers/api.rb`
- Test: `test/lib/services/oauth/token_gate_test.rb`, `test/integration/oauth/flow_test.rb`, `test/config/api_config_test.rb`

**Interfaces:**
- Consumes: `::Oauth::Resources.usable_scopes` and `.fetch` (Task 1).
- Produces:
  - `config.x.api.oauth_admin_approval_lifetime = 30.days`.
  - In `check_refresh`, after the revoked checks and before the lapse check: if the connection's resource is admin and `connection.approved_at < lifetime.ago`, return `invalid_grant` without revoking.
  - The lapse check becomes `usable_scopes(connection, @domain).empty?`, which still revokes the connection.

- [ ] **Step 1: Write the failing tests.**
  - `token_gate_test`:
    - an `admin_mcp` refresh 29 days 23 hours after `approved_at` is allowed;
    - one at 30 days and 1 minute is `:invalid_grant`, and the connection's `revoked_at` stays nil;
    - a `member_mcp` refresh at 400 days is allowed;
    - a demoted admin's refresh is `:invalid_grant` and revokes the connection.
  - `flow_test` (the full admin flow, through the real endpoints):
    - DCR, then authorize with `resource=<base>/api/mcp/admin` and no scope, as `admin_user`, then Approve, then exchange: the token response's `scope` is `"books:admin:read books:admin:write books:admin:merge"`, and `tools/call` `merge_book` with `dry_run: true` succeeds;
    - `travel 31.days`: the refresh is `invalid_grant`; approve again, exchange, and the new refresh works;
    - demote the admin: `/api/mcp/admin` gives a 401 with the admin challenge, the refresh is `invalid_grant`, re-promote, and the refresh is still `invalid_grant`.
  - `api_config_test`: the lifetime is an `ActiveSupport::Duration` greater than zero.
- [ ] **Step 2: Verify they fail. Step 3: Implement. Step 4: Run** `bin/rails test test/lib/services/oauth test/integration/oauth test/config`. Expected: PASS.
- [ ] **Step 5: Commit** `OAuth: admin connections refresh for 30 days; refusal follows usable scopes`

---

### Task 3: Discovery for the admin resource

**Files:**
- Modify: `config/routes.rb` (around line 720: the `.well-known` routes), `app/controllers/oauth/metadata_controller.rb` only if a lookup must change
- Test: `test/controllers/oauth/metadata_controller_test.rb`

**Interfaces:**
- Consumes: `::Oauth::Resources::ALL`, `Resource#metadata_path` (Task 1).
- Produces:
  - the Q-e routes;
  - `GET /.well-known/oauth-protected-resource/api/mcp/admin` returns `{resource: base + "/api/mcp/admin", authorization_servers: [base], scopes_supported: [the three admin scopes], bearer_methods_supported: ["header"]}`;
  - AS metadata `scopes_supported` is `["books:read", "books:admin:read", "books:admin:write", "books:admin:merge", "offline_access"]`.

- [ ] **Step 1: Write the failing tests.**
  - The admin PRM document's exact contents, which replaces "the admin endpoint has no protected resource document".
  - The exact AS `scopes_supported`; the key set is unchanged.
  - "every registered resource has its metadata route": for each `::Oauth::Resources::ALL` entry, `GET resource.metadata_path` is a 200 whose `resource` is `resource.url(base)`.
  - The root PRM document still describes `/api/mcp`.
- [ ] **Step 2: Verify they fail. Step 3: Implement. Step 4: Run** `bin/rails test test/controllers/oauth/metadata_controller_test.rb`, then `bin/rails routes -g well-known` to check one route per resource plus the root and the AS route. Expected: PASS.
- [ ] **Step 5: Commit** `OAuth discovery: admin resource metadata; routes drawn from the registry`

---

### Task 4: The authorize page for admin access

**Files:**
- Modify: `app/controllers/oauth/authorizations_controller.rb`, `app/views/oauth/authorizations/ineligible.html.erb`, `app/views/oauth/authorizations/new.html.erb`
- Create: `e2e/tests/books/admin/oauth-admin-authorize.spec.ts`
- Modify: `e2e/tests/books/account/oauth-authorize.spec.ts` (one added test)
- Test: `test/controllers/oauth/authorizations_controller_test.rb`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: `@refusal` (Q-d) and the Q-f line on the approval screen. The `oauth-refusal-<reason>` test ids replace `oauth-ineligible`.

- [ ] **Step 1: Write the failing tests** (`authorizations_controller_test`).
  - **Admin, explicit resource.** `admin_user` with `resource=<base>/api/mcp/admin` and no scope gets the approval screen. Approve creates a connection with resource `mcp_admin` and scopes the three admin scopes, and the grant's scopes match.
  - **Admin, inferred resource (Review Focus 3).** No `resource` and `scope=books:admin:read` gives a `mcp_admin` connection with `["books:admin:read"]`. No `resource` and `scope=books:read` gives a `mcp` connection.
  - **Books viewer (Review Focus 5).** A user holding only `books:admin:read` who asks for all three gets a connection with `["books:admin:read"]`.
  - **Refusal reasons:**
    - a member with no admin role asking for the admin resource sees `oauth-refusal-admin_required`, and the POST is 403 with no code;
    - a non-member on `mcp` sees `oauth-refusal-membership_required`;
    - a member with `resource=<base>/api/mcp` and `scope=books:admin:merge` sees `oauth-refusal-scope_unavailable`.
  - Replace "the admin endpoint is not a resource in this increment". Switch the three `oauth-ineligible` assertions to the matching reason hooks.
  - Keep the existing forged-fields tests passing unchanged. A forged `resource_key=mcp_admin` must still not bind an admin connection.
- [ ] **Step 2: Verify they fail. Step 3: Implement.** daisyUI 5 only. Per-reason headings and copy:
  - `:admin_required`: "Admin access needed" / "This app is asking for admin access to <site>, and your account does not have it."
  - `:membership_required`: keeps today's heading and copy.
  - `:scope_unavailable`: "Access not available" / "This app asked for access that this address does not offer."
- [ ] **Step 4: E2E.**
  - `admin/oauth-admin-authorize.spec.ts` (admin storage state): register a client, open authorize with the admin `resource`, and see the approval screen. It lists the merge scope's description and the 30-day line. Approve lands on the callback with `code` and `state`. Use the increment 1 specs' real loopback listener pattern on a port not already used: 43104.
  - `account/oauth-authorize.spec.ts` gets one added test: asking for the admin resource shows "Admin access needed", with no membership link.
  - Check port 3000 is this worktree's with the `AGENTS.md` check. If another checkout holds it, stop and report; never kill it. Then run `yarn build:all`, start `bin/rails server`, run the two specs plus the three increment 1 OAuth specs, and stop the server.
- [ ] **Step 5: Run** `bin/rails test test/controllers/oauth` and the E2E above. Expected: PASS.
- [ ] **Step 6: Commit** `OAuth authorize: admin approval, refusal reasons, 30-day notice`

---

### Task 5: Docs and the full run

**Files:**
- Modify: `docs/features/mcp-server.md` ("Signing in with OAuth": the admin resource, usable scopes, the 30-day limit by config key, a separate connector per endpoint), `docs/launch-todo.md` §13 (one acceptance line: an admin connects claude.ai to `/api/mcp/admin` and runs a dry-run merge)

- [ ] **Step 1: Write the doc changes.** Use the `avoid-ai-writing` skill. Code wins over this plan where they differ. No Cloudflare details.
- [ ] **Step 2: Full verification.** From `web-app/`: `bin/rails test` (0 failures, no new warnings), `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`.
- [ ] **Step 3: Commit** `Document admin MCP sign-in`

Manual acceptance after merge (Shane): add `https://<books host>/api/mcp/admin` as a second claude.ai connector, sign in as an admin, approve, and ask for a dry-run merge of two duplicate books.
