# MCP server — design

Date: 2026-11-02. Builds on the public API (`docs/superpowers/specs/2026-09-12-public-api-framework-design.md`),
admin permissions (`docs/superpowers/specs/2026-11-01-api-admin-permissions-design.md`), the categories API
(`docs/superpowers/specs/2026-11-02-categories-api-design.md`) and **depends on** the web-parity API spec
(`docs/superpowers/specs/2026-11-02-public-api-web-parity-design.md`). Read `docs/features/public-api.md`
first.

Supersedes two earlier assumptions: the September spec's "the MCP server is a separate Python app calling
the API" (also recorded in memory), and the draft "Books MCP Server (/mcp) — Design Spec" Shane brought to
this session, whose tools called query objects and serializers directly. What survives from that draft:
the gem, per-request stateless servers, a dedicated MCP path (now `/api/mcp`, see D3), auth/rate-limit parity, error mapping, the usage
prompt and methodology resource.

## Intent

An MCP client (Claude Code, the Claude API's MCP connector, our own agent later) connects to the site
and works with the catalogue: members read it, admins also manage it ("merge these categories", "tag this
book as Gothic"). Shane's requirements, in his words: use the stable `mcp` Ruby gem inside Rails rather
than an external service; "avoid code duplication, and write it in a generic way"; "admin users should
have different mcp endpoints and permissions than just paid users".

## Goals

1. `POST /api/mcp` on the books host answers MCP `initialize`, `tools/list`, `tools/call`, `prompts/*`,
   `resources/*` for a member's `books:read` personal access token.
2. `POST /api/mcp/admin` does the same for a `books:admin:*` token, with the admin tools.
3. Every tool is an API operation. The tool catalogue is generated from the two OpenAPI documents, and a
   tool call runs the real API controller in-process. No tool logic exists outside the API except the
   thin composite tools (below), and those are built only from the same dispatches.
4. Auth, membership, scope, rate-limit, validation, policy and error outcomes are the API's own, by
   construction.
5. Works on production Puma (several processes behind nginx and Cloudflare) with no sticky sessions and
   no in-process session state.
6. Generic across sites: music and games get MCP tools when their API operations exist and carry
   `x-mcp`, with no MCP-specific code per site.
7. Acceptance: Claude Code, given only the `/api/mcp` URL and a token, answers "what are the top 10 Russian
   novels of the 19th century, and which lists put them there?" from tool results, citing `url`s.

## Non-goals

- OAuth sign-in. It is the third spec, `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md`, and it is
  what lets the Claude apps (claude.ai, Desktop, mobile) connect. This spec ships personal access tokens as
  bearer, which Claude Code (`--header`) and Codex (`bearer_token_env_var`) accept. Nothing here may block
  OAuth: the 401 path and the authenticator are the seams the OAuth spec extends.
- Server-initiated requests (sampling, elicitation), notifications, subscriptions, resource templates.
  Stateless mode rules them out and nothing needs them.
- Music and games tools (no API operations yet).
- New API capabilities. Anything a tool needs that the API lacks goes into an API spec first.
- Free-tier access. MCP is a membership benefit exactly as the API is: `books:read` already requires an
  active membership (or a service account).

## Anti-goals

- **A tool that reaches data or actions the API does not expose.** Structurally impossible here: the
  only way a tool touches the app is the dispatcher, which can only call a route.
- **A second place that decides what a token may do.** `Services::Api::Authenticator` and `Api::Scopes`
  decide; the MCP layer reads `principal.scope?`.
- **Counting one MCP request more than once** against the rate limit, or skipping the count.
- **A hand-maintained tool list** that can drift from the OpenAPI documents.
- **REST paging leaking into tools**: no `links`, and `limit` rather than `per_page`.

## Decisions

| # | Decision | Why |
| --- | --- | --- |
| D1 | `gem "mcp"`, `~> 1.8` (1.8.2 read from source on 2026-11-02). Inside the Rails app. | Official SDK; Rails is already the API and the token audience, so no token forwarding or second deploy. |
| D2 | One `MCP::Server` per request, built in a controller. Transport: `StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true, serve_subscriptions_listen: false, allowed_hosts: <this site's hosts>)`, then `status, headers, body = transport.handle_request(request)` — the gem's documented controller pattern, with two corrections the builder check found: Rails' `render` ignores `headers:` (copy them onto `response.headers`), and a notification (every client sends `notifications/initialized`) comes back `[202, {}, []]`, so an empty body must be `head status`, not `render json: nil` (which renders `"null"`). `GET` and `DELETE` are routed to a controller action answering 405 and never reach the transport (in stateless mode the transport answers `DELETE` with 200). | The gem's mount pattern keeps sessions in process memory and needs `workers 0` or sticky routing. Stateless JSON mode issues no session id and works multi-process. Keep DNS-rebinding protection on with the site's hosts rather than disabling it (builder: read hosts from `Rails.application.config.domains`). |
| D3 | Two endpoints per site: `/api/mcp` (document `:public`, requires `<domain>:read`) and `/api/mcp/admin` (document `:admin`, requires `books:admin:read`). Routed only on hosts that have API operations (books today). Under `/api/` so they inherit the edge's existing treatment of API paths (Cloudflare skips its own bot and rate-limit protections for `/api/*`; see `app/controllers/api/v1/openapi_controller.rb:8`). A path outside `/api/` would hit the site's browser-oriented edge protections, which a machine client cannot pass. Edge rules live in a separate private repo and are not described here. *(My call, settled after the builder check; the URL is published on `/developers`, so it is hard to change later.)* | Shane: admins get different endpoints. Keeps admin tool descriptions out of member clients entirely. |
| D4 | The MCP controllers inherit `Api::V1::BaseController`, so `set_current_domain`, `prevent_caching`, `authenticate!`, `enforce_rate_limit!` and `require_scope!` run before any server is built. The transport's own `token_verifier` is not used. | One authenticator, one set of 401/403/429 bodies and headers. An unauthenticated or over-quota request never builds a server. |
| D5 | **Tools are generated** at boot from `Api::OpenapiDocument` (per document, per domain via `for_host`'s `x-domain` filtering), one tool per operation carrying an `x-mcp` block. Memoised outside development, like `OpenapiDocument.raw`. | The documents are hand-maintained and already validated against every integration test; they are the contract. |
| D6 | `x-mcp` on an operation holds: `name` (optional; default the `operationId` in snake_case), `description` (required; written for a model: when to use this tool and when to prefer a neighbour), `destructive` (optional boolean). Read-only/idempotent hints derive from the HTTP method, and every annotation is set explicitly: the gem's `Tool::Annotations` defaults `destructive_hint` to true (`tool/annotations.rb:8`), which would flag every POST and PATCH. An operation without `x-mcp` is not a tool (e.g. `getOpenapi`). | Model-facing text lives next to the operation it describes, in the one file. |
| D7 | Each operation's required scope becomes machine-readable: per-operation `security: [{bearerAuth: ["<scope>"]}]` in the OpenAPI documents (valid in OpenAPI 3.1 for any scheme). A contract test asserts, for every operation, that the declared scope equals the scope the routed controller enforces (`required_scope` / `action_scopes`). | `tools/list` on `/api/mcp/admin` must show only what the token may call (a `books:admin:read` token never sees merge tools). Declaring it in the document also documents it for REST users; the test keeps it honest. |
| D8 | The per-request server is built with only the tools whose operation scope the principal satisfies (`principal.scope?`). Calling an unlisted tool is the gem's JSON-RPC "Tool not found" (-32602). The dispatched controller still enforces its scope and policies on every listed tool. *(My call: the gem has no tools-list hook, and overriding `MCP::Server#list_tools` to list a subset while registering all is not worth it.)* | The controller remains the enforcement; the filtered registration only keeps tools out of sight. |
| D9 | **Input schema** = path parameters + query parameters + request-body properties, flattened into one object schema, `$ref`s resolved from `components`, `additionalProperties: false`. `page` stays; `per_page` is exposed as `limit` with the same bounds. Name collisions between a path/query parameter and a body property fail generation loudly. The servers run with the gem's argument validation **off** (`configuration: MCP::Configuration.new(validate_tool_call_arguments: false)`, builder confirms the exact keyword) so bounds, enums and unknown keys reach the API and come back as its own 400s. The gem's missing-required check runs regardless (`server.rb:1316-1321`) and answers in its own words; that one difference is accepted and tested. *(My call.)* | Agents read one flat, strict schema; validation outcomes stay the API's (goal 4). Failing at boot beats a silently shadowed argument. |
| D10 | **Dispatch** (`Mcp::Dispatcher`, builder's name): build a Rack env with `Rack::MockRequest.env_for` for the operation's method and interpolated path (query string or JSON body as the operation takes), set `HTTP_HOST`/`HTTPS` from the outer request, copy `action_dispatch.remote_ip` and `action_dispatch.request_id` from the outer env, merge `Rails.application.env_config` (it carries `action_dispatch.parameter_filter`; without it the inner "Parameters:" log line is unfiltered), set two server-only env keys (below), then call `Rails.application.routes.call(env)`. Path arguments are percent-encoded before interpolation (a slug containing `/` or `.` must not route to another operation or trip the format constraint). | Routing and `DomainConstraint` still apply (so the host must be set), but the middleware stack and the "Started" log line are skipped; the inner "Processing by…/Completed" lines are still written, which is wanted. `request.remote_ip` comes from the `RemoteIp` middleware, which is skipped, so the IP must be copied or the inner request sees the wrong visitor. |
| D11 | **Result mapping.** 2xx: the response body as JSON text content (`{type: "text", text: json}`), with `links` removed. Any 4xx or 5xx with a problem body (including the web-parity spec's 503 `search_unavailable`): a tool result with `isError: true` carrying the problem body (`code`, `detail`, and any extra members such as a partial merge's `merged`/`failed`/`not_attempted`). A non-JSON error response — notably the router's no-route `[404, {"X-Cascade" => "pass"}, ["Not Found"]]` — becomes `isError: true`, `{code: "not_found"}` for a 404 and `internal_error` otherwise. An exception escaping the controller: `isError: true`, `{code: "internal_error", request_id}`, reported through `Rails.error.report`, never a stack trace. | Transport-level failures stay HTTP (D4); tool-level failures stay in the protocol so the agent can read and recover. Exceptions escape because `ShowExceptions` is in the skipped middleware; unrescued, the gem would turn them into a bare JSON-RPC -32603. |
| D12 | **Authenticate and count once.** The outer request authenticates and counts one rate-limit hit per MCP POST (initialize, list and call alike). The dispatcher puts the already-built principal in `env["the_greatest.api.principal"]` and sets `env["the_greatest.api.dispatched"] = true`. `Services::Api::Authenticator` returns the env principal when present (no second token lookup or `record_use`); `Api::RateLimited` skips its hit for a dispatched request. | Both keys lack the `HTTP_` prefix, so no client header can set them. Without the second key, the inner `enforce_rate_limit!` would count again. A composite tool's several dispatches count as the one MCP request. |
| D13 | **Composite tools** are an explicit allowlist of hand-written tools under the MCP namespace that may call only the dispatcher, naming operations by `operationId`. A test asserts every `operationId` a composite uses exists in its endpoint's catalogue. Its listing scope is the union of its operations' scopes. v1 ships one: `find_book(title)` → `search_books` (top hit) → `get_book` + `list_book_lists`, returned as one payload. | Operation-shaped tools are the known weakness of OpenAPI-generated MCP servers; this fixes the commonest multi-hop ("tell me about War and Peace") without a second implementation. More composites are added by later plans, one at a time. |
| D14 | **Prompts and resources** per endpoint. `/api/mcp`: a `usage` prompt (answer from tool results, cite each book's `url`, keep rank order, say when `total_count` exceeds what was fetched, never invent a rank) and a `ranking-methodology` resource (how lists are weighted into the ranking, what a ranking configuration is, what `rank` means; prose, ~400 words). `/api/mcp/admin`: an admin `usage` prompt that adds "dry-run every merge and delete first, show the user the dry-run result, and only then run it". The server's `instructions` field carries a one-paragraph version of the usage prompt so clients that ignore prompts still get it. | Generated descriptions alone do not make a generic client competent. The methodology is prose about the site, not data, so it does not breach "nothing the API does not expose". |
| D15 | Logging: tag each `/api/mcp*` request with the JSON-RPC method, the tool name for calls, and the principal's user id (never the token). Dispatched controllers keep their own audit lines (`event=api_admin_merge ...`), which already carry `token_id` and `user_id`. | Lets API logs split MCP traffic from REST without new audit code. |

## Architecture

```
POST /api/mcp  or  /api/mcp/admin    (books host)
  └─ Mcp controller < Api::V1::BaseController
       set_current_domain → prevent_caching → authenticate! → enforce_rate_limit! (1 hit) → require_scope!
       └─ MCP::Server.new(tools: catalogue.visible_to(principal) + composites, prompts:, resources:,
                          instructions:, server_context: {principal:, outer_request:})
            └─ StreamableHTTPTransport (stateless, JSON) .handle_request
                 └─ tools/call → generated tool → Mcp::Dispatcher
                      └─ Rails.application.routes.call(env with principal + dispatched flag)
                           └─ the real Api::V1::... controller (auth short-circuits, no rate-limit hit)
```

Names (`Mcp::Catalog`, `Mcp::Dispatcher`, controller class and file layout) are the builder's, following
`app/lib/` conventions and the root-anchoring rule (`::Books::` inside nested namespaces). Generic code
must not mention books; the books-specific parts are the `x-mcp` blocks, the composite tool, and the
prompt/resource text.

## Increments

Each is its own PR with its own plan in `docs/superpowers/plans/`.

| # | Delivers | Depends on | Done when |
| --- | --- | --- | --- |
| 1 | Gem; catalogue generator; dispatcher; the authenticator and rate-limiter seams (D12); per-operation `security` scopes + contract test (D7); `/api/mcp`; `x-mcp` on every public operation; `find_book`; `usage` prompt, `ranking-methodology` resource, `instructions` | Web-parity spec increment 1 merged (search + filters). The generator and dispatcher can be built before it lands. | Goal 7 passes in Claude Code against the dev server; parity and seam tests below pass. |
| 2 | `/api/mcp/admin`; `x-mcp` on every admin operation, `destructive: true` on merges and deletes; scope-filtered listing; admin `usage` prompt | Increment 1 | A `books:admin:read` token lists no write or merge tools; a `books:admin:merge` token can dry-run and run a category merge from Claude Code, and the audit log line appears. |
| 3 | `/developers` MCP section: URL, the Claude Code command, a tool list rendered from the catalogue; `docs/features/mcp-server.md`; `docs/features/public-api.md` cross-link | Increment 1 (admin tools are listed only on the admin document's page, never the public one) | A member can connect from the docs alone. Playwright spec for the new section. |

Later increments (web-parity increments 2–3 landing) need only `x-mcp` blocks on the new operations.

## Testing

Minitest, like the rest of `web-app/test`.

- **Catalogue.** Every operation with `x-mcp` yields exactly one tool; none without it does. Every
  generated input schema is valid JSON Schema (the gem depends on `json_schemer`). Collision detection
  fails generation. The public catalogue contains no admin operation.
- **Scope contract (D7).** For every operation in both documents, declared scope == enforced scope.
- **Parity.** For a representative read operation (with filters), the tool result's JSON equals the REST
  response body for the same arguments, minus `links`. For a 404 and a 400, the tool error carries the
  same `code` and `detail` as the REST problem.
- **Resources.** `resources/read` serves only class-based resources unless a read handler is set (`server.rb:1441-1462`); the methodology resource must be readable over Rack.
- **Seams.**
  - A tool call is one rate-limit hit, including a composite.
  - A request carrying a header that resembles the env keys (for example `The-Greatest-Api-Principal`)
    authenticates normally.
  - A dispatched request sees the outer `remote_ip`.
  - `record_use` runs once per MCP request.
- **Over Rack** (`post "/api/mcp"` with JSON-RPC bodies and a minted token):
  - `initialize`, `tools/list`, `tools/call`, `prompts/get` and `resources/read` all answer.
  - The response has no `Mcp-Session-Id`, `Content-Type` is `application/json`, and
    `Cache-Control` is `private, no-store`.
  - A second `initialize` succeeds.
  - No token gives a 401 with the REST body; a non-member gets a 403 `membership_required`;
    over quota gives a 429 with the rate-limit headers.
  - `notifications/initialized` gives a 202 with an empty body.
  - `GET` and `DELETE` give a 405.
  - On `/api/mcp/admin`, the listing is scope-filtered, an unlisted tool is "Tool not found", and a member token gets a 403.
  - A missing required argument gives the gem's error; an out-of-range `limit` or an unknown argument gives the API's 400 problem.
- **Exceptions.** A controller that raises yields `internal_error` with the request id, not a 500.
- **Manual smoke** (part of acceptance): MCP Inspector against the dev server; Claude Code with
  `claude mcp add --transport http greatest-books <url>/api/mcp --header "Authorization: Bearer $TOKEN"`;
  record the working command on `/developers`. The transport's Origin check refuses browser-based clients such as MCP Inspector in direct mode unless `allowed_origins` includes them; use Inspector's proxy mode, or allow its origin in development only.

## Left to the builder

- Class and file names; where the generator lives.
- Whether a tool result also carries `structuredContent`/`outputSchema` derived from the response schema
  (text JSON is required; structured content is optional).
- How `page`/`limit` map for operations without paging (none are exposed).
- The `x-mcp` description wording for each operation, and the prompt and resource text, following D6 and D14.
- How the `/developers` tool list is rendered (from the catalogue at request time is fine; it is edge-cached).
