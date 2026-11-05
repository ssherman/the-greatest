# MCP server

Spec: `docs/superpowers/specs/2026-11-02-mcp-server-design.md` (decisions are numbered D1 to D15 there; code comments cite them). Code is the source of truth; this page is the map. Read `docs/features/public-api.md` first, because every MCP tool is an API operation.

## What it is

An MCP server inside the Rails app, built with the `mcp` gem (`Gemfile`: `~> 1.8`; the lockfile has 1.9.0). A member's AI assistant, such as Claude Code, connects with the same personal access token the REST API uses and works with the catalogue through tools.

| Endpoint | Who | Tools |
|---|---|---|
| `POST /api/mcp` | a token with `<domain>:read` (`books:read`), which needs an active membership or a service account | the public OpenAPI document's operations that carry `x-mcp`, plus `find_book` |
| `POST /api/mcp/admin` | a token with `<domain>:admin:read` (`books:admin:read`) or more | the admin document's operations, filtered to what the token's scopes allow |

Both are routed on the books host only (`config/routes.rb`, inside the books `DomainConstraint`). On music and games they are a routing 404, because those sites have no API operations yet. The admin tools are a separate endpoint so their descriptions never reach a member's client: `/api/mcp` serves only the public document, whatever the token holds.

No tool exists that is not an API operation. A tool call runs the real API controller in-process, so authorization, validation, serialization and error bodies are the REST API's own.

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
- **`per_page` is exposed as `limit`**, with the same bounds (`Mcp::Catalog::RENAMES`). REST paging names do not leak into tools, and `links` is dropped from results. The argument keeps its wire name, so the dispatcher sends `per_page`. A query parameter named `limit` would collide with the renamed one and fails generation.
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

Claude Code, public endpoint (the same command is on `/developers`):

```
export THE_GREATEST_TOKEN=tg_...
claude mcp add --transport http --scope user the-greatest-books https://thegreatestbooks.org/api/mcp \
  --header "Authorization: Bearer $THE_GREATEST_TOKEN"
```

`--header` is variadic, so it goes after the URL. The shell expands `$THE_GREATEST_TOKEN` when the command runs, so the variable must be exported first, and rotating the token means running the command again.

Admin endpoint:

```
claude mcp add --transport http --scope user the-greatest-books-admin https://thegreatestbooks.org/api/mcp/admin \
  --header "Authorization: Bearer $THE_GREATEST_ADMIN_TOKEN"
```

An admin scope can only be held by someone the policy allows (`Api::Scopes::ALL`), and `ApiToken` rejects an admin-scoped token without an expiry, so an admin token always expires. Mint it at `/developers/tokens`.

- **The 2026-07-28 lifecycle.** Claude Code speaks the stateless lifecycle of protocol version 2026-07-28: no `initialize`, a `server/discover` call for capabilities and instructions, the version in an `MCP-Protocol-Version` header and in each request's `_meta`, and `Mcp-Method` and `Mcp-Name` headers mirroring the method and the tool name. The gem routes this to its `handle_modern` path. The older `initialize` handshake still works too. `Accept` must include both `application/json` and `text/event-stream`: the modern path requires both, and sending both is harmless on the older one.
- **The gem version.** `config/initializers/mcp.rb`, the controller's response copying, and the era routing above all rest on the gem's transport behaviour, which is young. Before `bundle update mcp`, re-read `handle_modern` and the header-routing code in `lib/mcp/server/transports/streamable_http_transport.rb`, then run the MCP tests and the acceptance run below.
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

## Edge

The endpoints live under `/api/` so they get the edge's existing treatment of API paths. A path outside `/api/` would meet protections written for browsers, which a machine client cannot pass. The edge rules live in the private `the-greatest-cloudflare` repo, which is the source of truth, and this public repo describes none of them. Adding a hostname or a new path outside `/api/` for MCP would be an edge change made there.

## Testing

- `test/lib/api/dispatched_request_test.rb`, `test/lib/services/api/authenticator_test.rb` (the dispatched-principal seam), and `test/lib/mcp/`: `catalog_test.rb`, `admin_catalog_test.rb`, `dispatcher_test.rb`, `composite_test.rb`, `server_factory_test.rb`, `tool_result_test.rb`, `tool_directory_test.rb`, `sites/books_test.rb`, `sites/books/find_book_test.rb`.
- `test/controllers/api/mcp_controller_test.rb` and `mcp_admin_controller_test.rb`: JSON-RPC over Rack (`initialize`, `tools/list`, `tools/call`, prompts, resources, the modern lifecycle, 401, 403, 429, 405, one hit per request, parity with REST, malformed bodies, the log line). `test/support/mcp_rpc_helpers.rb` has the helpers, including `modern_rpc`.
- `test/integration/api/v1/operation_scope_contract_test.rb`: every operation's declared scope equals its controller's.
- `test/controllers/developers_controller_test.rb` and `e2e/tests/books/developers.spec.ts`: the MCP section of `/developers`.
- **Acceptance runs** (not automated): PR #447 recorded Claude Code, given only the URL and a token, answering "what are the top 10 Russian novels of the 19th century, and which lists put them there?" from tool results, citing each book's `url`. PR #449 recorded a `books:admin:read` token listing exactly the 4 read tools, and Claude Code with a merge token creating two throwaway categories, dry-running and then running a merge, then a delete, with the audit lines written. Repeat them after a gem update or a change to the dispatcher.

## Not yet

- **OAuth sign-in** for the Claude apps (claude.ai, Desktop, mobile), which cannot send a custom header: `docs/superpowers/specs/2026-11-02-mcp-oauth-design.md`. Today the credential is a personal access token.
- **Music and games tools.** They need API operations with `x-mcp` blocks first, and the MCP routes added to those hosts.
- **REST follow-ups** that tool users meet: book and author merges parse `dry_run` leniently (`null`, `""` and `0` mean a real merge, where category merge and delete return a 400), and the four protected categories can still be renamed, re-parented or retyped through the category PATCH. Until fixed, only the admin prompt guards against both.
