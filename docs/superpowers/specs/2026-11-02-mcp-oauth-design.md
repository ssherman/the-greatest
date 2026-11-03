# MCP sign-in (OAuth) — design

Date: 2026-11-02. Third of three related specs, built in this order:

1. `docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md` — the API gains search and the web's filters.
2. `docs/superpowers/specs/2026-11-02-mcp-server-design.md` — `/api/mcp` and `/api/mcp/admin`, tools generated
   from the API, personal access tokens as bearer.
3. **This spec** — the "click a link to sign in" flow, so every standard MCP client can connect.

Read the MCP spec first; this one only adds how a client gets a token. Also read
`docs/features/authentication.md` (Firebase → Rails `Session`) and the admin permissions spec
(`docs/superpowers/specs/2026-11-01-api-admin-permissions-design.md`).

## Intent

Shane: "i would like to support all the standard mcp servers... codex, claude, claude code/cli". He
described the flow he expects from paid-membership MCP servers he uses (Robinhood's): in Claude there is
an option to authenticate, he clicks a URL, signs in, and is connected; when auth fails, the client makes
him click the link and authenticate again.

That flow is OAuth 2.1 as the MCP authorization spec defines it. The Claude apps (claude.ai web, Desktop,
mobile) can only connect that way: their custom-connector UI has no place for a personal bearer token.
Claude Code and Codex support it too, and also accept a static bearer header, which keeps working.

## Goals

1. A member adds `https://<books host>/api/mcp` in claude.ai, Claude Desktop, Claude Code or Codex, is sent
   to a sign-in link, signs in with the site's normal sign-in, approves, and is connected. No client id,
   secret or token is pasted anywhere.
2. Tokens refresh silently. When a refresh fails, or the member revokes access, or the membership lapses,
   the client gets a 401 (never a bare 403) and asks the member to sign in again; the sign-in page then
   explains what is wrong (for example, the membership has lapsed).
3. An admin adds `/api/mcp/admin` the same way and is offered only the admin scopes their account is
   eligible for. A member's grant can never be used on the admin endpoint.
4. Members see and revoke connected apps on `/developers/tokens`, next to their personal tokens.
5. OAuth tokens become `Api::Principal`s in `Services::Api::Authenticator`; nothing downstream changes.
6. ChatGPT's connectors work as a side effect (same standards); not an acceptance criterion.

## Non-goals

- Client ID Metadata Documents (CIMD). The 2025-11-25 MCP spec prefers them, but Doorkeeper supports them
  only on unreleased `main`, and Claude, Claude Code and Codex all fall back to Dynamic Client Registration
  when the server does not advertise CIMD. Add CIMD when Doorkeeper releases it.
- OpenID Connect (ID tokens, `openid-configuration` as the primary discovery document).
- OAuth for the REST API. OAuth access tokens are audience-bound to an MCP endpoint; REST clients keep
  personal access tokens.
- Third-party apps beyond MCP clients, an app directory, or a developer console for registering clients.
- Music and games MCP endpoints (none exist yet), though nothing here may assume books.

## Anti-goals

- **A second authority on what a token may do.** An OAuth grant's effective scopes are computed by
  `Api::Scopes.effective(granted, user)`, exactly like a personal token: a demoted admin's or lapsed
  member's grant shrinks on the next request.
- **A second sign-in system.** The authorization page uses the site's existing Firebase → Rails session
  sign-in; it never collects a password itself.
- **Signing out of the site disconnecting MCP clients.** Ending a site session leaves OAuth grants alone
  (a real bug another operator hit; claude-ai-mcp#228).
- **Locking every claude.ai user out together.** All claude.ai traffic arrives from Anthropic's published
  ranges, and expired tokens produce 401s as a matter of course.
- **Advertising a capability the server does not honour** (the research found clients that reject a server
  for advertising, for example, `iss` support and then omitting it from one response).

## Research findings (2026-11-02)

From a sourced web survey; sources are listed at the end. Claude's docs carry no dates, so the date is
when they were read.

| | claude.ai / Desktop / mobile | Claude Code | Codex CLI + IDE |
| --- | --- | --- | --- |
| Registration | Anthropic-held credentials (directory only), then CIMD, then **DCR** (or a pasted client id) | Its own CIMD, else **DCR**, else `--client-id` | CIMD if advertised, else **DCR** |
| Redirect URI | `https://claude.ai/api/mcp/auth_callback` (a `claude.com` variant is rumoured, unverified) | `http://localhost:<ephemeral port>/callback` | `http://127.0.0.1:<port>/callback`, or `/callback/<id>` when the server lacks RFC 9207 |
| Discovery | Needs a **401** with `WWW-Authenticate` `resource_metadata`; PRM `resource` must **exactly** equal the URL typed; uses only the first authorization server; RFC 8414 before OIDC | RFC 9728 then RFC 8414 | RFC 9728 (since rust-v0.142) |
| PKCE / resource | Always S256; sends RFC 8707 `resource` on authorize and token | S256 | PKCE; `resource` only if configured |
| Refresh | Reactive on 401 and proactive before expiry; expects rotation and `invalid_grant`; token endpoint must answer within 10 s | Refresh, reconnect, retry once; else prompts re-authentication | Historically weak; concurrent refreshes have been reported |
| Static bearer | No (org-wide beta header only) | `--header` | `bearer_token_env_var` |
| Traffic from | **Anthropic cloud**: `160.79.104.0/21` (connector doc) and `153.61.208.0/20` (platform IP page) | The user's machine | The user's machine |

## Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | **Doorkeeper 5.9.x (stable)** is the authorization server: authorization-code grant, PKCE required (`force_pkce`) and restricted to S256 (`pkce_code_challenge_methods %w[S256]`; the default also accepts `plain`), public clients (`token_endpoint_auth_method: none`; the generated migration's `secret null: false` must be changed to nullable), refresh tokens with rotation (D11). | Proven token, PKCE and revocation handling. 6.0 is a release candidate; `main` is unreleased. `Api::Scopes` and `Api::Principal` were written expecting Doorkeeper. |
| D2 | **Hand-written** where 5.9 lacks it: RFC 8414 AS metadata, RFC 9728 protected-resource metadata, RFC 7591 Dynamic Client Registration, RFC 8707 `resource` handling. | No released gem provides DCR; every Rails MCP write-up the research found hand-writes these (a few dozen lines each). The `mcp` gem's `ProtectedResourceMetadata` may build the PRM document (builder's call). |
| D3 | **Two protected resources, one authorization server.** `https://<host>/api/mcp` and `https://<host>/api/mcp/admin` each have their own PRM document (`resource` = that exact URL) listing the scopes for that endpoint: `books:read` for `/api/mcp`, the `books:admin:*` scopes for `/api/mcp/admin`. A grant records its `resource`; the authenticator accepts an OAuth token only on the endpoint whose URL is its resource. | Goal 3. Audience binding is what MCP's authorization spec requires, and it makes a member grant structurally useless on the admin endpoint. |
| D4 | **The authorization page** is a normal site page on the books host. Signed out: the existing sign-in widget, then back to the same request. Signed in, not eligible (no effective scope for the requested resource, e.g. a lapsed member on `/api/mcp`, a non-admin on `/api/mcp/admin`): an explanation with a link to membership, and the client gets `access_denied`. Eligible: an approval screen naming the client and **showing its redirect host** (MCP spec MUST), the site and the scopes, with Approve and Deny. The scopes granted are those requested ∩ `Api::Scopes.mintable_by(user)` ∩ the resource's scopes; an absent `scope` means all of the resource's scopes the user may hold. | One sign-in system (anti-goal). Same eligibility rules as minting a personal token. |
| D5 | **A connection** is one (user, client, resource) row, the app's own record next to Doorkeeper's tables: approved scopes, `approved_at`, `last_used_at`, revoked state. Approve creates it, or re-approves an existing one: `approved_at` is reset and the connection's older tokens are revoked. Every access and refresh token belongs to exactly one connection, stamped server-side at Approve (never from request params: Doorkeeper's `custom_access_token_attributes` are sliced raw from the authorize request, so `resource`, the connection id and timestamps must be set by our code). **Admin connections can only be refreshed for 30 days after `approved_at`**; after that the admin signs in again. Member connections refresh indefinitely. Access tokens last one hour for both. *(My call, settled after the builder check.)* | Doorkeeper has no long-lived grant record (its `oauth_access_grants` are 10-minute codes), and Connected apps, the admin clock, revocation and pruning all need one. Extends the existing rule that admin tokens must expire. |
| D6 | **Dynamic Client Registration** at `POST /api/oauth/register`: JSON body; creates public clients only; validates `redirect_uris` (https, or http **only** for loopback: `localhost`, `127.0.0.1`, `[::1]`); `invalid_client_metadata` errors; rate-limited per IP with its own window (it is open by design). Registered clients that have no grant after 30 days are pruned by a periodic job. | All three clients fall back to DCR. Pruning keeps an open endpoint from growing the table without bound. |
| D7 | **Redirect matching**: exact for https URIs; for loopback http URIs, the **port is ignored** and the path is matched exactly, for `localhost` as well as IP literals. | Claude Code uses `http://localhost:<ephemeral>/callback` and re-registers or reuses across ports. Doorkeeper 5.9 has no configuration hook for this: matching is hard-coded in `Doorkeeper::OAuth::Helpers::URIChecker.matches?`, whose loopback rule uses `IPAddr` only. The builder prepends a module to it (with a test pinned to the Doorkeeper version, so an upgrade that changes it fails loudly). Also `force_ssl_in_redirect_uri` defaults to true outside development and must become a proc that allows http loopback only. |
| D8 | **Endpoints** (all on the books host): `GET /.well-known/oauth-protected-resource/api/mcp`, `.../api/mcp/admin`, and the root `/.well-known/oauth-protected-resource` (which Claude also probes; it describes `/api/mcp`); `GET /.well-known/oauth-authorization-server`; authorize at a site path (builder's name, e.g. `/oauth/authorize`, a browser page); `POST /api/oauth/token`, `POST /api/oauth/register`, `POST /api/oauth/revoke`. The issuer is `https://<host>` (no path), so its metadata lives at the root well-known path. | Machine-to-machine endpoints sit under `/api/` and inherit the Cloudflare skip rule. The well-known paths are fixed by the RFCs, so they need their own Cloudflare rule (Shane's step, D13). The authorize page is a browser page, so normal site protection is fine. |
| D9 | **AS metadata** advertises: `issuer`, the endpoints, `response_types_supported: ["code"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`, `code_challenge_methods_supported: ["S256"]`, `token_endpoint_auth_methods_supported: ["none"]`, `scopes_supported` (including `offline_access`, configured as an accepted scope), `revocation_endpoint`. It does **not** advertise `client_id_metadata_document_supported` or `authorization_response_iss_parameter_supported`, unless the builder implements RFC 9207 `iss` on every success **and error** authorization response, in which case it advertises it and tests both. | Anti-goal: never advertise what is not honoured. Without RFC 9207, Codex falls back to a per-server callback path, which DCR handles. |
| D10 | **The 401** from `/api/mcp*` (no token, invalid, expired) gains `resource_metadata="<that endpoint's PRM URL>"` and `scope="<that endpoint's scopes>"` in `WWW-Authenticate`. The body stays `Api::Problem`. REST 401s are unchanged. A 403 `insufficient_scope` keeps `error="insufficient_scope", scope="..."` (Claude steps up on it). | Claude starts sign-in only on a 401 with this header; a tool error with `isError` never triggers it. |
| D11 | **Token endpoint behaviour**: form-urlencoded; refresh without `scope` keeps the original scopes; a dead refresh token is `invalid_grant`. **Missing `resource`**: inferred from the requested scopes (any `books:admin:*` scope → `/api/mcp/admin`, else `/api/mcp`); clients take their scopes from the 401's `scope=` or the PRM, so a client sent to the admin endpoint asks for admin scopes. **Rotation**: Doorkeeper's `previous_refresh_token` behaviour, where the old refresh token stays valid until the new access token is first used. Doorkeeper does that revocation only inside its own `Token.authenticate`, so our authenticator (D12) must call `revoke_previous_refresh_token!` on an OAuth token's first use, or rotation silently never happens. **Reuse detection**: presenting a refresh token that is already revoked revokes the whole connection (OAuth 2.1's recommendation for public clients). **Refusal**: a refresh for a connection that is revoked, past its admin 30 days, or whose user now has no effective scope for its resource is `invalid_grant`, and the lapsed case also revokes the connection, so renewing a membership later does not revive it. Doorkeeper's only refresh hook runs after the new token row exists, so a refusal raises a `DoorkeeperError` *and* revokes that row. *(My calls, settled after the builder check.)* | Each of these was a real client failure in the research (claude-ai-mcp#228; Codex concurrent refresh, which the untimed grace handles because Doorkeeper takes no lock; Codex omitting `resource`), or a hole the builder check found. |
| D12 | **Authenticator**: `Services::Api::Authenticator` resolves a bearer value as a personal token first, then as a Doorkeeper access token (not revoked, not expired, its connection not revoked, resource == this request's MCP endpoint), building the same `Api::Principal` (`token:` holds whichever record it was; the three audit lines that read `token.id` must say which kind). Effective scopes come from `Api::Scopes.effective` over the connection's approved scopes. **An OAuth token whose user has no effective scope for its resource is a 401 `invalid_token`**, not the personal-token path's 403 `membership_required`, so the client re-prompts and the authorize page explains (D4). Personal tokens keep today's 403. | Goal 5. The one seam stays the one seam. A 403 carries no sign-in challenge, so a lapsed member would be stuck. |
| D13 | **Connector egress ranges get their own budget, not a skip.** Every per-IP window this spec touches (the pre-auth 401 window, DCR, the token endpoint) keys a request from a published connector egress range (Anthropic's two ranges, OpenAI's published list) on the **range**, with a separate, much larger per-minute limit, instead of on the IP. Ranges and limits live in Rails config next to the other API tunables, with source URLs in a comment. Per-account limits still apply after authentication. *(My call, settled after the builder check.)* | A per-IP limit would lock out every claude.ai user together. A full skip would hand any Claude API customer (whose MCP connector shares `153.61.208.0/20`) an unbounded channel for junk tokens, which the window exists to bound (`config/initializers/api.rb:17-18`). |
| D14 | **Connected apps** on `/developers/tokens`: one row per live connection: client name, redirect host, scopes, resource (member or admin), approved and last used, and Revoke (revokes the connection and all its tokens). Any signed-in user with a live connection can see and revoke them, even without the membership the page's token minting needs (today `require_api_access!` sends such users to the membership page, `tokens_controller.rb:66-70`). | Goal 4. A lapsed member must still be able to disconnect an app. |
| D15 | **Edge change, in the private Cloudflare repo** (`../the-greatest-cloudflare`, the `cfrules` tool): the RFC-fixed `/.well-known/oauth-*` paths must get the same edge treatment `/api/*` already has, with a guard that a machine client reaches them rather than a challenge. Increment 1's plan prepares it as its own PR in that repo, following that repo's `AGENTS.md` (pull → edit → diff, guards). Running `apply` against the live zone is Shane's. Its details stay in that repo: it is private on purpose, and this spec is in a public one. `docs/launch-todo.md` gets two steps: apply the edge change before the first claude.ai connection, and confirm `config.hosts` and the transport's `allowed_hosts` include the production hostname. | claude.ai's backend cannot solve a challenge. Machine-to-machine OAuth endpoints are already under `/api/` (D8); only the well-known documents are not. |
| D17 | **The resource is stored as an endpoint key** (`mcp`, `mcp_admin`), not a full URL; the PRM `resource` and the issuer are computed from the request host. When books moves to thegreatestbooks.org (`docs/launch-todo.md` §7), connections keep working, but members must re-add the connector with the new URL, because claude.ai drops `Authorization` across redirects. That goes in the launch todo. *(My call; books is not live, so very few connections will exist before the switch.)* | The host changes once, at launch. |
| D16 | **Content Security Policy**: if a CSP is ever enabled, `form-action` must allow the registered redirect hosts, or Chrome blocks the redirect to claude.ai after Approve. Today the app's CSP initializer is commented out; the plan adds a test that the authorize flow's final redirect is not blocked, so turning CSP on later fails loudly. | A pitfall a Rails write-up hit. |

## Testing

- Every RFC endpoint over Rack: PRM documents (exact `resource`), AS metadata (exact advertised set),
  DCR (good/bad metadata, loopback-only http, rate limit), the full authorization-code + PKCE flow with a
  signed-in session, refresh (rotation, grace window, scope kept, `invalid_grant`), revocation.
- Redirect matching: a `localhost` port change is accepted, a different path is refused, a different https
  host is refused.
- Audience: a `/api/mcp` grant is a 401 on `/api/mcp/admin` and on `/api/v1/*`.
- Eligibility: a non-member is refused at approval; a member whose membership lapses after approval gets a
  401 `invalid_token` on the next request, their refresh is `invalid_grant`, and the connection is revoked
  (renewal does not revive it); a demoted admin's connection loses the admin scopes on the next request.
- Rotation: after a refresh, the old refresh token works until the new access token is first used, then
  `invalid_grant`; presenting a revoked refresh token revokes the connection; two concurrent refreshes
  both succeed.
- Server-set attributes: an authorize request carrying `resource`, connection or timestamp params cannot
  bind a connection to the admin endpoint or move its 30-day clock; scopes are recomputed on the Approve POST.
- Missing `resource` with admin scopes → an admin connection; without → `/api/mcp`.
- PKCE `plain` is refused.
- A lapsed member can see and revoke Connected apps.
- Signing out of the site leaves grants working.
- The 401 `WWW-Authenticate` on `/api/mcp*` carries `resource_metadata` and `scope`; REST 401s unchanged.
- The egress-range budget: requests from inside a configured range share the range's larger budget on
  the pre-auth window, DCR and the token endpoint; an address outside it keeps its own per-IP window.
- Playwright: the authorization page (signed out → sign in → approve; deny; non-member), and Connected apps
  revoke.
- Manual acceptance, all four, recorded on `/developers`: claude.ai custom connector; Claude Desktop; Claude
  Code (`claude mcp add --transport http ... /api/mcp`, then `/mcp` → Authenticate); Codex
  (`codex mcp login`). Each must reconnect by itself after the access token expires, and must prompt sign-in
  again after Revoke.

## Increments

| # | Delivers | Done when |
| --- | --- | --- |
| 1 | Doorkeeper; connections; AS + PRM metadata; DCR; authorize page (sign-in, approval, refusal); token, refresh, rotation and revoke; authenticator and 401 changes; egress-range budgets; `/api/mcp` only | Claude Code and Codex connect by sign-in against the dev server; claude.ai connects against production after Shane's D15 steps |
| 2 | `/api/mcp/admin` resource and admin approval; 30-day admin refresh limit | An admin connects claude.ai to `/api/mcp/admin` and runs a dry-run merge |
| 3 | Connected apps on `/developers/tokens`; DCR client pruning job; `/developers` connection instructions per client | A member can connect from the docs alone and revoke from the page |

## Left to the builder

- Doorkeeper configuration details, table names, controller names and paths for the authorize page.
- How the authorize page hands the user through sign-in and back (the existing widget plus a return path;
  no new sign-in UI).
- Whether to implement RFC 9207 `iss` (D9 says what follows from either choice).
- The approval screen's copy and layout (daisyUI 5 conventions in `AGENTS.md`).
- The DCR rate limit and the egress-range budgets.

## Sources (read 2026-11-02)

Anthropic: claude.com/docs/connectors/building/authentication.md, …/lazy-authentication.md,
…/troubleshooting.md; code.claude.com/docs/en/mcp; claude.ai/oauth/claude-code-client-metadata;
platform.claude.com/docs/en/api/ip-addresses; github.com/anthropics/claude-ai-mcp/issues/228;
github.com/anthropics/claude-code/issues/37747. OpenAI: learn.chatgpt.com/docs/extend/mcp,
learn.chatgpt.com/docs/config-file/config-reference, developers.openai.com/apps-sdk/build/auth,
github.com/openai/codex/issues/27165, developers.openai.com/api/docs/guides/ip-addresses. MCP spec:
modelcontextprotocol.io/specification/2025-11-25/basic/authorization. Ruby: ruby.sdk.modelcontextprotocol.io/server/authorization,
Doorkeeper CHANGELOG, Fleetio and Visuality Rails MCP OAuth write-ups (2026-03). Codex version-specific
claims came from third-party changelogs and are unverified.
