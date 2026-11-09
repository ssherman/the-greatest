# MCP server

Spec: `docs/superpowers/specs/2026-11-02-mcp-server-design.md` (decisions are numbered D1 to D15 there; code comments cite them). Code is the source of truth; this page is the map. Read `docs/features/public-api.md` first, because every MCP tool reaches data only through API operations.

## What it is

An MCP server inside the Rails app, built with the `mcp` gem (`Gemfile`: `~> 1.8`; the lockfile has 1.9.0). A member's AI assistant, such as Claude Code, connects with the same personal access token the REST API uses, or signs in through a browser (see "Signing in with OAuth"), and works with the catalogue through tools.

| Endpoint | Who | Tools |
|---|---|---|
| `POST /api/mcp` | a token with `<domain>:read` (`books:read`). Who may hold it: an active member or a service account, or a non-member books admin through `books:admin:read`, which implies `books:read` (`Api::Scopes::ALL`) | the public OpenAPI document's operations that carry `x-mcp`, plus `find_book` |
| `POST /api/mcp/admin` | a token with `<domain>:admin:read` (`books:admin:read`) or more | the admin document's operations, filtered to what the token's scopes allow |

Both are routed on the books host only (`config/routes.rb`, inside the books `DomainConstraint`). On music and games they are a routing 404, because those sites have no API operations yet. The admin tools are a separate endpoint so their descriptions never reach a member's client: `/api/mcp` serves only the public document, whatever the token holds.

Every tool reaches data only through API operations; composites such as `find_book` combine several. A tool call runs the real API controller in-process, so authorization, validation, serialization and error bodies are the REST API's own.

## How a request flows

```
POST /api/mcp  or  /api/mcp/admin
  Api::McpController < Api::V1::BaseController
    set_current_domain, prevent_caching, authenticate!, enforce_rate_limit!, require_scope!
    Mcp::ServerFactory.build  ->  MCP::Server (one per request)
    StreamableHTTPTransport#handle_request
      tools/call -> generated tool -> Mcp::Dispatcher -> Rails.application.routes.call
        -> the real Api::V1::... controller
```

Files: `app/controllers/api/mcp_controller.rb`, `app/controllers/api/mcp_admin_controller.rb`, `app/lib/mcp/server_factory.rb`, `config/routes.rb`.

- **The before_action chain is the REST one.** `Api::McpController` inherits `Api::V1::BaseController`, so the domain, the `private, no-store` header, the bearer token, the rate limit and the scope check all run before any MCP server is built. An unauthenticated, forbidden or over-quota request therefore costs no server and gets the REST bodies and headers (401, 403, 429 with the rate-limit headers), not a JSON-RPC error. `required_scope` is `"#{Current.domain}:read"`; `Api::McpAdminController` overrides it to `"#{Current.domain}:admin:read"` and changes only `mcp_document` (`:admin`). Everything else is shared.
- **One stateless `MCP::Server` per request.** `Mcp::ServerFactory.build` makes it from the catalogue for `(document, domain)`, filtered to the principal's scopes, plus the site's composites, prompts, resources and instructions. The server context is `{principal:, request:}`; each tool call hands both to the dispatcher. A server is cheap, and there is no session state, so any Puma process behind any proxy can answer any request. The gem's own mount pattern keeps sessions in process memory, which would need one worker or sticky routing.
- **Transport options** (`McpController#transport`): `stateless: true` (no `Mcp-Session-Id` is issued), `enable_json_response: true` (a plain JSON body, not an event stream, except where the transport picks one itself), `serve_subscriptions_listen: false`, and `allowed_hosts` set to the site's hosts from `Rails.application.config.domains`. With the gem's DNS-rebinding protection on, a request must carry one of those hosts, and an `Origin` header, when present, must be same-origin. No `allowed_origins` is passed, so browser-based clients that send a foreign `Origin` are refused; command-line clients send none.
- **The response** is copied from the transport onto the Rails response: its headers (except `Cache-Control`, so `private, no-store` stays) and its `Content-Type`, whichever it chose. An empty body, which is a notification's 202, is sent as `head`, because rendering nothing would produce the text `null`.
- **GET and DELETE are 405** with `Allow: POST`, answered by `#method_not_allowed` and never handed to the transport. There is no stream to GET, and in stateless mode the transport would answer DELETE with a 200 for a session that does not exist.
- **The transport's `token_verifier` is not used.** There is one authenticator, `Services::Api::Authenticator`, and the controller chain has already run it. A second verifier would be a second place that decides what a token may do.
- **Nothing in the controller reads `params`.** The body is a JSON-RPC document that the transport parses itself, so a malformed one reaches it and is answered as a JSON-RPC error, not as a Rails parameter-parsing failure.
- **Errors in a server are reported twice over on purpose.** `Mcp::ServerFactory` passes an `exception_reporter` to the server, and `config/initializers/mcp.rb` sets the gem's global one, because the transport reports through the global configuration. Both forward to `Rails.error`.

## Tools

### Generated from `x-mcp` (`Mcp::Catalog`)

`app/lib/mcp/catalog.rb`, `app/lib/mcp/operation.rb`. The two OpenAPI documents (`config/api/v1/openapi.yaml`, `admin_openapi.yaml`) are the contract and the only tool list. An operation with an `x-mcp` block becomes one tool; one without it (`getOpenapi`, `getAdminOpenapi`) does not. The catalogue is built per `(document, domain)` through `Api::OpenapiDocument.for_host`, so a host sees only the operations routed on it, and is memoised outside development (like the document itself).

Generation fails loudly (`Mcp::Catalog::GenerationError`) rather than build a tool that is wrong:

- **The `x-mcp` keys** are `name`, `description` and `destructive`, and nothing else; an unknown key is an error. `description` is required. `name` defaults to the `operationId` in snake_case. `destructive` must be the boolean `true` or `false`, and a GET cannot be destructive. A string `"true"` would otherwise read as not destructive and mark a merge as safe.
- **The tool's title** is the operation's `summary`, which must be present. Tool names and `operationId`s must be unique.
- **The scope** comes from the operation's own `security` block. An `x-mcp` operation with no scope is an error, because a tool without one would be listed to everyone.
- **The input schema** is one flat, strict object (`additionalProperties: false`): the path parameters, the query parameters and the properties of the `application/json` request body, with every `$ref` resolved inline (the gem accepts same-document refs only, and a flat schema reads better to a model anyway). A parameter's description is merged into its schema. Required means path parameters, required query parameters and the body's `required` members. A header or cookie parameter, a body that is not an object with properties, a body without `application/json`, an unresolvable or self-referring `$ref`, and the same name arriving from two places (path, query or body) are all errors.
- **`per_page` is exposed as `limit`**, with the same bounds (`Mcp::Catalog::RENAMES`). REST paging names do not leak into tools, and `links` is dropped from results. The argument keeps its wire name, so the dispatcher sends `per_page`. An operation that takes both `per_page` and its own `limit` would collide on the renamed name and fails generation; an operation with only its own `limit` (`listSimilarBooks`) generates fine.
- **The gem's argument validation is off** (`validate_tool_call_arguments: false` in `Mcp::ServerFactory`), so bounds, enums and unknown keys reach the API and come back as its own 400 problems. The gem still checks that required arguments are present and answers in its own words; that one difference is accepted.
- **Safety hints** are set explicitly on every tool, because the gem defaults `destructive_hint` and `open_world_hint` to true, which would flag every POST. `Mcp::Operation#annotations` is the one table:

  | Operation | read_only | idempotent | destructive |
  |---|---|---|---|
  | GET | true | true | false |
  | PUT or DELETE | false | true | `x-mcp.destructive` |
  | POST or PATCH | false | false | `x-mcp.destructive` |

  `open_world_hint` is always false, and the tool's `title` rides along in the annotations.

### The scope filter

`Mcp::Catalog#tools_for(principal)` keeps the tools whose operation scope the principal satisfies (`principal.scope?`), using the effective scopes the authenticator computed. An unlisted tool is not registered, so calling it is the gem's JSON-RPC "Tool not found" (-32602) and never reaches the API. The dispatched controller still enforces its own scope and policy on every call that is listed, so the filter hides tools and the controller is the enforcement. On the admin endpoint a read-scope token lists 4 tools (the searches and `get_admin_category`), a write-scope token 10, and a merge-scope token all 14. `test/controllers/api/mcp_admin_controller_test.rb` pins this.

### Composites (`Mcp::Composite`, `find_book`)

`app/lib/mcp/composite.rb`, `app/lib/mcp/sites/books/find_book.rb`. A composite answers one question with several operations ("tell me about War and Peace"), the multi-hop case that operation-shaped tools handle poorly. It is an allowlist entry, not a second implementation: a subclass declares the `operations` it uses by `operationId`, and reaches data only through `dispatch`, which runs the real controller and refuses an operation it did not declare.

- Its listing scope is the union of its operations' scopes: it is offered only to a principal who could call every one.
- Its safety hints are derived from those operations (`Composite.annotations`), so one that reaches a write cannot call itself read-only.
- Its tool is built once per catalogue (`Catalog#cached`).
- Nothing validates a composite's arguments for it, so it refuses unknown and blank ones in the dispatcher's `invalid_parameter` shape.

`find_book(title)` is the only one. It runs `searchBooks` (`q`, limit 1, the best match), then `getBook` and `listBookLists` (up to 100 lists) for that slug, and returns `{book, lists, lists_total_count}`. No match is a `not_found` error. It is on the public endpoint only; the admin endpoint has no composite.

### Per-site content (`Mcp::Sites`)

`app/lib/mcp/sites.rb`, `app/lib/mcp/sites/books.rb`, `config/mcp/books/*.md`. Everything in `Mcp::` is generic except this. A site module answers `instructions`, `prompts`, `resources` and `composites` for a document; a domain with no entry gets `Mcp::Sites::None`, so a site whose API operations carry `x-mcp` serves tools with no per-site code. Books supplies:

- the server `instructions` (`instructions.md`, `admin_instructions.md`), sent at `initialize` and in `server/discover` for clients that ignore prompts;
- a `usage` prompt per document (`usage.md`, `admin_usage.md`);
- the `ranking-methodology` resource (`greatest://books/ranking-methodology`, `ranking_methodology.md`), served by both endpoints;
- the `find_book` composite on the public document.

The texts are read once when `Mcp::Sites::Books` loads, so editing one needs a restart. Tests pin what they must say (`test/lib/mcp/sites/books_test.rb`), so a rewording that drops a rule fails.

### The tool directory (`Mcp::ToolDirectory`)

`app/lib/mcp/tool_directory.rb`. A list of every tool an endpoint can offer, with no principal: `Entry(name, title, description, destructive, composite)`, catalogue tools in catalogue order and then the site's composites. It exists so documentation pages, which render the same for every visitor, can list tools. It is built from the same catalogue and composites as the factory, so a page cannot drift from the endpoint. It is not a per-request listing. `/developers` uses it for its MCP section (books only; hosts whose catalogue is empty have none) and never lists the admin document.

## Dispatch

`app/lib/mcp/dispatcher.rb`, `app/lib/api/dispatched_request.rb`, `app/lib/services/api/authenticator.rb`, `app/controllers/concerns/api/rate_limited.rb`.

`Mcp::Dispatcher.call(operation, arguments, principal:, request:)` runs one tool call as the REST request it stands for. It builds a Rack env with `Rack::MockRequest.env_for` and hands it to `Rails.application.routes.call`. Routing and the host constraint still apply, but the middleware stack is skipped, which the dispatcher makes up for:

- **The env.** The operation's method and interpolated path, plus the query string or a JSON body; `HTTP_ACCEPT` of `application/json`; the outer request's `HTTP_HOST` and `HTTPS`; its `REMOTE_ADDR`. `action_dispatch.remote_ip` and `action_dispatch.request_id` are copied from the outer request, because the `RemoteIp` middleware did not run and the inner request would otherwise see the wrong visitor. `Rails.application.env_config` is merged in because it carries `action_dispatch.parameter_filter`; without it the inner "Parameters:" log line would print tokens in the clear.
- **Percent-encoding.** A path argument is `ERB::Util.url_encode`d and its `.` becomes `%2E`. A slug can hold `/` (which would route to a different operation) or `.` (which trips the format constraint).
- **Nil.** A nil path or query argument is omitted: it is an unset filter, not a value. A nil body argument is sent as JSON `null`, because the admin PATCH uses `null` to clear a field (`parent_id`, `description`), and dropping it would turn a clear into a silent 200. A nil path argument counts as missing.
- **Unknown and blank arguments.** An argument the tool does not declare is a 400 `invalid_parameter` answered without calling the API, nil or not; one that is the wire name of a renamed argument says what to use instead (`per_page (use limit)`). A blank path value is "Missing argument", because it would interpolate to an empty segment and the router collapses those into a different operation.
- **One authentication, one `record_use`, one rate-limit hit per MCP POST**, however many tool calls or dispatches it makes (a `tools/list` counts as one, and so does `find_book`). The outer controller authenticated and counted the request. The dispatcher stamps the env with `Api::DispatchedRequest.mark`: the principal under `the_greatest.api.principal` and `the_greatest.api.dispatched` set to true. `Services::Api::Authenticator` returns that principal with no second token lookup, and `Api::RateLimited` skips its hit, so the inner request sets no rate-limit headers (the outer response carries them).
- **Why those keys cannot be forged.** Rack builds every request header as `HTTP_<NAME>`, and neither key has that prefix, so no client header, however it is named, lands under them. Only server code that holds the env can set them, and the dispatcher is the only caller of `mark`. `test/lib/api/dispatched_request_test.rb` pins the missing prefix, and the authenticator test checks that a principal under any other env key is ignored.
- **Exceptions.** `ShowExceptions` is skipped, so an exception from a controller escapes `routes.call`. The dispatcher rescues it, reports it through `Rails.error`, and answers a generic `internal_error` with the outer request id and never the exception message. It also restores the execution context's controller, which the inner controller sets and never restores.

### Result mapping (`Mcp::ToolResult`)

`app/lib/mcp/tool_result.rb`. A 2xx becomes a text content block holding the response body as JSON, with `links` removed (an empty body is `{}`). Any other status becomes the same block with `isError: true` carrying the problem body (`code`, `detail`, and members such as a partial merge's `merged`, `failed`, `not_attempted`), so the agent can read the problem and recover. A response that is not JSON, such as the router's no-route 404, becomes `not_found` for a 404 and `internal_error` otherwise. Failures stay inside the protocol; only transport problems (auth, quota, a bad Host or Accept) are HTTP statuses.

## Adding a tool

The API operation comes first; anything a tool needs that the API lacks goes into an API change.

1. Add an `x-mcp` block to the operation in `openapi.yaml` or `admin_openapi.yaml`. Write `description` for a model: when to use the tool and when to prefer a neighbour, what the ids mean, what to report back. Add `name` only to override the snake_cased `operationId`.
2. Add `destructive: true` to merges and deletes (and to anything else that removes data, as the untags do). For a destructive operation whose `dry_run` defaults to false, the description must say to dry-run first, show the user, and run it only after they agree.
3. Check the operation has a `summary` (the tool's title) and a `security` scope. The scope is read from `security`, and the scope contract test checks it matches the one the routed controller enforces.
4. Run the tests. The ones that catch mistakes:
   - `test/lib/mcp/catalog_test.rb` (generation rules, every public operation but `getOpenapi` is a tool, unique names, valid JSON Schema, no `per_page`, descriptions written for a model) and `test/lib/mcp/admin_catalog_test.rb` (the same for the admin document, plus the pinned list of tool names and of destructive tools: add yours there);
   - `test/integration/api/v1/operation_scope_contract_test.rb`, which fails when a declared scope differs from the controller's;
   - `test/lib/mcp/tool_directory_test.rb`, which pins the number of public and admin tools;
   - `test/controllers/api/mcp_controller_test.rb` and `mcp_admin_controller_test.rb` for the scope tiers.

A composite is separate: a subclass of `Mcp::Composite` listed by its site module's `composites`, with a test that every operation it names exists in the catalogue.

## Clients

Claude Code, public endpoint. `/developers` prints this command with the real host, built from `Api::Host.base_url`; `<books host>` stands for it here:

```
export THE_GREATEST_TOKEN=tg_...
claude mcp add --transport http --scope user the-greatest-books https://<books host>/api/mcp \
  --header "Authorization: Bearer $THE_GREATEST_TOKEN"
```

`--header` is variadic, so it goes after the URL. The shell expands `$THE_GREATEST_TOKEN` when the command runs, so the variable must be exported first, and the client stores the value it saw then. To change the token (for example after revoking a leaked one), run `claude mcp remove --scope user the-greatest-books` and then the add command again.

Admin endpoint:

```
export THE_GREATEST_ADMIN_TOKEN=tg_...
claude mcp add --transport http --scope user the-greatest-books-admin https://<books host>/api/mcp/admin \
  --header "Authorization: Bearer $THE_GREATEST_ADMIN_TOKEN"
```

An admin scope can only be held by someone the policy allows (`Api::Scopes::ALL`), and `ApiToken` rejects an admin-scoped token without an expiry, so an admin token always expires. Mint it at `/developers/tokens`.

- **The 2026-07-28 lifecycle.** Claude Code speaks the stateless lifecycle of protocol version 2026-07-28: no `initialize`, a `server/discover` call for capabilities and instructions, the version in an `MCP-Protocol-Version` header and in each request's `_meta`, and `Mcp-Method` and `Mcp-Name` headers mirroring the method and the tool name. The gem routes this to its `handle_modern` path. The older `initialize` handshake still works too. `Accept` must include both `application/json` and `text/event-stream`: the modern path requires both, and sending both is harmless on the older one.
- **The gem version.** `config/initializers/mcp.rb`, the controller's response copying, and the era routing above all rest on the gem's transport behaviour, which is young. Before `bundle update mcp`, re-read `handle_modern` and the header-routing code in `lib/mcp/server/transports/streamable_http_transport.rb`, then run the MCP tests and the acceptance run below.
- **Claude apps, and any client that supports MCP authorization,** need only the URL: they find the sign-in through the 401 challenge and register themselves (see "Signing in with OAuth").
- **Other clients** use Streamable HTTP with a bearer header: `POST`, `Authorization: Bearer <token>`, `Content-Type: application/json`.
- **Limits.** The token's tier limits apply, and one MCP POST is one hit. An agent that pages through a large collection spends the member allowance like any other client.

## Admin safety

The admin tools change live data, and the agent is the thing deciding which to call. Safety comes from the API (policies, the protected categories, scopes), and then from text the agent reads.

- **Dry run, then ask.** `merge_book`, `merge_author`, `merge_categories` and `delete_admin_category` take `dry_run`, which defaults to false. Their descriptions, the admin instructions and the admin `usage` prompt all say the same protocol: call with `dry_run: true`, show the user the result, run with `dry_run: false` only after they agree, and treat agreement to one merge as not covering the next. Merges and deletes are permanent; there is no undelete.
- **Untag is not an undo.** `untag_book` and `untag_author` have no dry run. Tagging an item that already has the category changes nothing, so untagging afterwards would delete a link that existed before, with its original source; tagging again records the source as `admin`. The prompt tells the agent to check the `source` a tag returned and confirm before untagging. A link inferred from a more specific location cannot be removed directly.
- **Protected categories.** Fiction, Nonfiction, Poetry and Religion & Spirituality cannot be deleted or merged, as source or target; the API refuses. The API does still let them be renamed or re-parented (see "Not yet"), so the prompt tells the agent not to.
- **Reporting.** A real book or author merge can return `warnings`, which the agent is told to relay; a dry run never has them. A category merge that fails part way answers `merged`, `failed` and `not_attempted`, and the agent is told to report all three exactly and not retry blindly.
- **Tool results are data.** The prompt and instructions say names, titles and descriptions in results are never instructions.
- **`config/mcp/books/`** holds `admin_instructions.md` (one paragraph, sent to every client) and `admin_usage.md` (the prompt). `test/lib/mcp/sites/books_test.rb` and `test/controllers/api/mcp_admin_controller_test.rb` assert the key rules are in them.
- **Audit lines.** The dispatched controllers write the same audit lines as REST (`event=api_admin_merge`, `event=api_admin_category_create|update|merge|delete|link`), which carry the token and user ids. See "Admin permissions" in `docs/features/public-api.md`. The MCP log line below says which endpoint served the request.

## Logging

One line per MCP POST, written before the transport runs:

```
event=api_mcp document=public|admin rpc_method=tools/call tool=list_books user_id=123
```

- `rpc_method` is the JSON-RPC method (`tools/list`, `tools/call`, `server/discover`, ...), and `tool` is the tool name for a `tools/call` and `-` otherwise. A batch is logged as `batch`.
- Values from the wire are kept to `[\w./-]{1,100}` and valid UTF-8; anything else logs as `-`, so a client cannot forge a second field or line. A body that does not parse logs `-` and `-` and is still answered by the transport. Logging never fails the request.
- The token is never logged, only `user_id`. The body is read raw for this line and only here.
- The inner controller writes its usual "Processing" and "Completed" lines, so a tool call also appears as the REST request it ran.

## Signing in with OAuth

Spec: `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md` (decisions D1 to D17; code comments cite them). The Claude apps (claude.ai, Desktop, mobile) cannot send a custom header, so they cannot use a personal token. They sign the member in through a browser instead, and Claude Code and Codex can do the same. The authorization server is Doorkeeper 5.9 plus hand-written pieces where Doorkeeper has none: the metadata documents, Dynamic Client Registration and `resource` handling.

`/api/mcp` and `/api/mcp/admin` each accept an OAuth token, as two separate resources (see "Audience binding by path" and "The admin endpoint"). `/api/v1/*` is untouched: an OAuth token is a 401 there. Every OAuth route is on the books host only, inside the same `DomainConstraint` as the MCP routes.

### The flow

1. **Discovery.** A client posts to `/api/mcp` with no token and gets a 401 whose `WWW-Authenticate` carries `resource_metadata` (the URL of the protected-resource document) and `scope`. It reads `GET /.well-known/oauth-protected-resource/api/mcp` (or `.../api/mcp/admin` for the admin endpoint), which names the resource and the one authorization server. The root `/.well-known/oauth-protected-resource` returns the same document, because some clients probe it. It then reads `GET /.well-known/oauth-authorization-server` for the endpoints. `Oauth::MetadataController` serves both with `public, max-age=3600`, and every URL in them comes from `Api::Host.base_url`, never `request.host`. The metadata does not advertise RFC 9207 `iss`, so Codex uses its per-server callback path, which registration records.
2. **Registration.** The client has never seen this server, so it registers itself with `POST /api/oauth/register` (RFC 7591, `Oauth::RegistrationsController`). Every client is public: no secret is generated, and PKCE is the proof. A redirect URI is valid when it is `https` with a host, or `http` on `localhost`, `127.0.0.1` or `[::1]`, with no fragment and no credentials. The controller creates an `OauthApplication` and returns its `client_id`. `client_name` is shown to the member, so control and formatting characters are refused: a name must not disguise who is asking.
3. **Authorize.** The client sends the member's browser to `GET /oauth/authorize` (`Oauth::AuthorizationsController`, a Doorkeeper subclass, so it gets the site layout and session sign-in). PKCE is required and only `S256` is accepted. The page works through these states in order. An unknown client or unregistered redirect URI is an error page, never a redirect. A signed-out visitor sees a prompt that opens the login modal, and the layout's widget reloads the same URL after sign-in. A request Doorkeeper refuses (bad scope, `plain` PKCE) redirects to the client with an error, as does an unknown `resource` (`invalid_target`). When nothing can be granted, the page says why and offers a Return form that denies. The reason is `admin_required` (the resource is the admin endpoint and the user is not an admin), `membership_required` (a member endpoint and the user holds none of its scopes; only this one links to `/membership`) or `scope_unavailable` (the client asked only for scopes this endpoint does not offer). Otherwise the approval screen shows the client's name, the host the member will be sent to, the site and each granted scope with its description. An admin approval adds one line: "Admin access must be approved again after 30 days." Approve is a `POST` and Deny a `DELETE` on the same URL, both forms with `data-turbo="false"`, because Turbo Drive swallows the cross-origin redirect that ends the flow. The page is never cached.
4. **Token.** The client posts the code and its verifier to `POST /api/oauth/token` and gets an access token (one hour) and a refresh token. The code lives ten minutes. `POST /api/oauth/revoke` revokes one token row.

The scopes granted are the requested ones (all of the resource's scopes when `scope` is absent), limited to `Api::Scopes.mintable_by(user)` and to the resource's own scopes (`"#{domain}:read"` for `mcp`, every `"#{domain}:admin:*"` scope for `mcp_admin`). With no `resource`, a request that names any admin scope becomes an admin connection and anything else a member one. `offline_access` is accepted and dropped, because refresh tokens are always issued. A `resource` sent on authorize must equal a registered resource's URL exactly. At the token endpoint, a `resource` that differs from the approval's is a 400 `invalid_target`.

### The connection record

`OauthConnection` is the app's own record of one approval: one row per (user, client, resource), holding the approved scopes, `approved_at`, `last_used_at` and `revoked_at`. Every grant and token belongs to exactly one connection, through a `connection_id` column that Doorkeeper copies from grant to token to refreshed token (`custom_access_token_attributes`). The server stamps it on Approve. A `connection_id`, `resource` or timestamp sent by the client on the authorize request or the Approve form is ignored: the controller drops the first and recomputes the rest.

Approving again for the same (user, client, resource) reuses the row, resets `approved_at`, clears any revocation, and first revokes everything issued under the earlier approval, so a forgotten token does not outlive the consent that replaced it. `Services::Oauth::Connections` owns the lifecycle. `revoke!` ends a connection and every live token and grant under it. `last_used_at` is written at most every five minutes.

The model classes are our own (`OauthApplication`, `OauthAccessGrant`, `OauthAccessToken`), each including the Doorkeeper mixin, so they can hold the association and be annotated. Token secrets are stored hashed.

### Audience binding by path

The connection stores its resource as a key (`mcp`), not a URL. `Oauth::Resources` maps keys to paths, and `Services::Api::Authenticator` maps the request path to a resource with `Resources.for_path`, an exact match. A token whose connection is for a different resource is refused. `/api/v1/*` maps to no registered resource, so an OAuth token is a 401 `invalid_token` there. A `mcp` token is a 401 on `/api/mcp/admin` and a `mcp_admin` token is a 401 on `/api/mcp`, so each endpoint needs its own connector entry in the client. A later endpoint is one more entry in `Resources::ALL`; discovery routes are drawn from that registry, and the root `/.well-known/oauth-protected-resource` stays pinned to `mcp`. Storing a key means the host can change without touching rows (launch todo, section 13).

The authenticator tries a personal token first, because `tg_...` is recognised by its shape without a database read, and then an OAuth token (`Services::Oauth::AccessTokens.find_live`: not revoked, not expired, connection live, resource matching). Either way the result is the same `Api::Principal`, with effective scopes from `Api::Scopes.effective` over the connection's approved scopes, so a demoted member's connection shrinks on the next request. `Oauth::Resources.usable_scopes(connection, domain)` returns those effective scopes only when they still intersect the connection's resource scopes, and `[]` otherwise. A demoted admin's admin connection therefore gets a 401 `invalid_token` with the admin challenge (the client re-prompts), never a 403 from the scope check. Calls dispatched in-process by the MCP server never reach this lookup: they carry the outer request's principal.

### The admin endpoint

`mcp_admin` offers the domain's admin scopes (on books `books:admin:read`, `books:admin:write`, `books:admin:merge`), limited to what the user may mint, so an admin holding only `books:admin:read` is granted only that scope and a write tool call is a 403 `insufficient_scope`. The principal carries the full effective set, so admin tools that dispatch to `books:read` endpoints still work. The 401 challenge on `/api/mcp/admin` carries its own `resource_metadata` URL and the admin scopes.

Admin approvals expire for refresh after `config.x.api.oauth_admin_approval_lifetime` (30 days, `config/initializers/api.rb`), counted from `approved_at`. Past it a refresh is `invalid_grant` and the connection is not revoked: the admin signs in again, and approving resets `approved_at`. Exactly 30 days is still allowed. The limit applies to refresh only; an access token already issued lives out its hour. A demoted admin's refresh is `invalid_grant` and revokes the connection, and promoting the user again does not revive it.

### Refresh, rotation and reuse

`Oauth::TokensController` runs `Services::Oauth::TokenGate` before Doorkeeper sees the request, so a refusal creates no row and leaves nothing to clean up. The gate refuses with `invalid_grant` or `invalid_target`. An unknown refresh token passes through and Doorkeeper answers `invalid_grant`, so a probe cannot tell unknown from revoked.

- **Rotation.** A refresh issues a new token row and keeps the old refresh token valid, with no time limit, until the new access token is first used. That also covers a client that refreshes twice at once. Doorkeeper revokes the old one only inside its own token lookup, which this app does not use, so `AccessTokens.record_use` calls `revoke_previous_refresh_token!` on every authenticated request. Without that call rotation would never happen. A refresh without `scope` keeps the approved scopes.
- **Reuse.** Presenting a refresh token that is already revoked means two parties hold it, so the gate revokes the whole connection and the member must approve again. The exception is a token created before the connection's current `approved_at`: a re-approval revoked it, so it is only stale. Replaying it gets `invalid_grant` and leaves the new approval alone.
- **Revoke.** A token row carries both an access and a refresh secret. Revoking the row at `/api/oauth/revoke` and then refreshing with it trips the reuse rule. The cost is a disconnect that the member fixes by approving again.

### Lapse

When a member's membership ends, the connection row stays but its effective scopes become empty. A request with their access token is a 401 `invalid_token` carrying the `resource_metadata` challenge, not the personal-token path's 403 `membership_required`. An agent cannot act on a 403, but a 401 sends it back through sign-in, where the authorize page tells the member the reason and links to `/membership`. A refresh for a lapsed member is `invalid_grant` and also revokes the connection, so renewing later does not revive it: the member approves again. Every 401 from `/api/mcp` carries `resource_metadata` and `scope`. A 403 `insufficient_scope` is unchanged.

### Rate-limit budgets

`config/initializers/api.rb`, counted by `Services::Api::RateLimiter` per visitor IP per minute, before any parsing or lookup:

- `config.x.api.unauthenticated_per_minute` for the existing pre-auth 401 window;
- `config.x.api.oauth_register_per_minute` for registration, the tightest because the endpoint is open by design;
- `config.x.api.oauth_token_per_minute` for the token endpoint.

Hosted connectors reach the server from a few addresses shared by many members, and a per-IP window would throttle them together. `config.x.api.connector_egress_ranges` lists the vendor-published ranges (Anthropic's two, with their sources in a comment), and `config.x.api.connector_range_per_minute` gives each window a larger budget keyed on the range instead of the address. Each range is its own key, so all Anthropic traffic shares one budget per window. This is a budget, not a skip: a full skip would hand anyone on those ranges an unbounded channel for junk tokens. Another vendor is one entry in each map. ChatGPT is not a goal, and its ranges are not configured. Per-account limits still apply after authentication.

### Edge for the discovery documents

The discovery documents sit at the RFC-fixed `/.well-known/oauth-*` paths, outside `/api/`, so they do not inherit the edge's treatment of API paths, and a connector's backend cannot solve a challenge. A rule in the private Cloudflare repo gives them that treatment. It must be applied after this code is deployed and before the first claude.ai connection (`docs/launch-todo.md`, section 13). This repo records none of its details.

### Increments

Increments 1 (`/api/mcp`) and 2 (`/api/mcp/admin`, admin approval and the 30-day refresh limit) are built. Increment 3 adds Connected apps on `/developers/tokens` (a member sees and revokes connections, even after a lapse), a job that prunes registered clients with no grant after 30 days, and per-client connection instructions on `/developers`. Until then there is no page for revoking a connection.

### Testing

`test/controllers/oauth/` (metadata, registration, authorization), `test/integration/oauth/flow_test.rb` (the flow over HTTP: PKCE, rotation, reuse, lapse, audience binding), `test/lib/oauth/`, `test/lib/services/oauth/`, and the model tests for the four OAuth models. The Playwright specs `e2e/tests/books/oauth-authorize.spec.ts`, `account/oauth-authorize.spec.ts` and `member/oauth-authorize.spec.ts` run a real loopback listener to prove the browser lands on the callback with `code` and `state`. Acceptance (not automated): Claude Code and Codex connect by sign-in against the dev server, and claude.ai against production once the launch steps are done.

## Edge

The endpoints live under `/api/` so they get the edge's existing treatment of API paths. The edge rules live in the private `the-greatest-cloudflare` repo, which is the source of truth, and this public repo describes none of them. The OAuth discovery paths are the one exception to "under `/api/`"; see "Edge for the discovery documents" above.

## Testing

- `test/lib/api/dispatched_request_test.rb`, `test/lib/services/api/authenticator_test.rb` (the dispatched-principal seam), and `test/lib/mcp/`: `catalog_test.rb`, `admin_catalog_test.rb`, `dispatcher_test.rb`, `composite_test.rb`, `server_factory_test.rb`, `tool_result_test.rb`, `tool_directory_test.rb`, `sites/books_test.rb`, `sites/books/find_book_test.rb`.
- `test/controllers/api/mcp_controller_test.rb` and `mcp_admin_controller_test.rb`: JSON-RPC over Rack (`initialize`, `tools/list`, `tools/call`, prompts, resources, the modern lifecycle, 401, 403, 429, 405, one hit per request, parity with REST, malformed bodies, the log line). `test/support/mcp_rpc_helpers.rb` has the helpers, including `modern_rpc`.
- `test/integration/api/v1/operation_scope_contract_test.rb`: every operation's declared scope equals its controller's.
- `test/controllers/developers_controller_test.rb` and `e2e/tests/books/developers.spec.ts`: the MCP section of `/developers`.
- **Acceptance runs** (not automated): PR #447 recorded Claude Code, given only the URL and a token, answering "what are the top 10 Russian novels of the 19th century, and which lists put them there?" from tool results, citing each book's `url`. PR #449 recorded a `books:admin:read` token listing exactly the 4 read tools, and Claude Code with a merge token creating two throwaway categories, dry-running and then running a merge, then a delete, with the audit lines written. Repeat them after a gem update or a change to the dispatcher.

## Not yet

- **Connected apps and client pruning**: increment 3 of `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md` (see "Signing in with OAuth").
- **Music and games tools.** They need API operations with `x-mcp` blocks first, and the MCP routes added to those hosts.
- **REST follow-ups** that tool users meet: book and author merges parse `dry_run` leniently (`null`, `""` and `0` mean a real merge, where category merge and delete return a 400), and the four protected categories can still be renamed, re-parented or retyped through the category PATCH. Until fixed, only the admin prompt guards against both.
