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

The instructions a member follows are on `/developers`, under "Connect by signing in" (claude.ai and the Claude apps, Claude Code, Codex), with the token route under "With a token instead". The page is edge-cached and identical for every visitor, so it never mentions the admin endpoint. The address must be used exactly as printed, with no trailing slash: an address ending in `/` is not the resource, and the client will not find the sign-in. Codex needs a recent CLI for remote servers, and `--url` is what makes `codex mcp add` register one.

Claude Code with a token, public endpoint. `/developers` prints this command with the real host, built from `Api::Host.base_url`; `<books host>` stands for it here:

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

## The duplicate queue

Four admin tools work the books duplicate queue (`duplicate_candidates`; see `docs/features/import-finder.md`): `list_duplicate_candidates` and `get_duplicate_candidate` (scope `books:admin:read`), `merge_duplicate_candidate` (`books:admin:merge`; body `target_id` (survives) and `source_id` (deleted), which must be exactly the pair's two record ids, optional `note` up to 1000 characters, optional `dry_run`) and `dismiss_duplicate_candidate` (`books:admin:write`; body `record_ids`, the pair's two ids, optional `note`). Both refuse with 422 when the ids are not exactly the pair's, because a merge elsewhere re-keys pending pairs in place and an agent must not act on a pair that changed under it. They are the one exception to the "dry run, then ask" protocol above: `config/mcp/books/admin_usage.md` has a "The duplicate queue" section telling the agent it decides each pair itself. `merge_duplicate_candidate` is still permanent, and dry run is optional.

The admin endpoint is `/api/mcp/admin`. Every resolution made through these tools is stamped with the token's user, the note, and `resolved_via: api`.

### Copy prompt

The books duplicates and match decisions admin pages each have a **Copy prompt** button. It copies a starting prompt, rendered at page load by `Services::AgentPrompts.call(domain:, queue:)` (queue `:duplicates` or `:match_decisions`) from `config/mcp/books/prompts/<queue>.md.erb` with the admin MCP URL (`Api::Host.base_url` plus `/api/mcp/admin`) and the pending book and author counts, into a hidden textarea that `clipboard_copy_controller` reads. A domain with no prompt file gets no button. The house rules live in that file, not in server text, so Shane trims the pasted prompt as needed; the file is the starting point.

The workflow: click Copy prompt, paste it into the agent, adjust, send. The agent lists pending pairs, researches each, and merges or dismisses with a note. Afterwards the resolved tabs on the same page show the pairs and notes, and the `via` filter narrows them to API resolutions.

E2E: `e2e/tests/books/admin/duplicates-copy-prompt.spec.ts` clicks the button and checks the clipboard.

## The match decisions queue and identifiers

The books match decisions page (`/admin/match_decisions`) lists decisions the importers and the Wikidata/VIAF resolvers flagged for a person. Admin tools work it, and the same tools read and change identifiers.

Match decision tools:

- `list_match_decisions` and `get_match_decision` (`books:admin:read`). Filters: `entity` (`book`, `author`, `wikidata-link`, `viaf-link`), `outcome`, `confidence`, `decided_by`, `reviewed` (pending by default), `verify` (hidden by default). `Services::MatchDecisions::Filter` is shared with the page, so both see the same queue.
- `review_match_decision` (`books:admin:write`): `verdict` (`confirmed` or `rejected`) and `note`. Already reviewed is 422. `rejected` on a matched Wikidata/VIAF decision is refused 422, because it would ban the record while the link stayed; use `reject_match_decision_link`.
- `reject_match_decision_link` (`books:admin:merge`): runs `Services::Books::Authors::RejectExternalLink`, the same service as the page's reject. It is permanent: it removes the link, reverts the facts it produced and re-runs enrichment. An optional `note` is appended to "Link rejected.".

Identifier tools:

- `get_book_identifiers` and `get_author_identifiers` (`books:admin:read`), paged; a book lists its own rows then its editions' (`scope=work` for its own only).
- `find_by_identifier` (`books:admin:read`): `type` and `value`; capped at 100 results with a `truncated` flag.
- `add_book_identifier` and `add_author_identifier` (`books:admin:write`): stored with `source: admin`. An author's Wikidata or VIAF id added this way is authoritative: the resolvers accept it without name or year corroboration and enrichment re-runs. Re-adding one the author already holds from another source promotes it to admin (`promoted: true`). On a book, `source: admin` is provenance only: verification, the Goodreads replay and the import matcher may replace or ignore it. Refused if the author holds a different id of that type (remove it first) or the value was rejected for this author.
- `remove_book_identifier` and `remove_author_identifier` (`books:admin:merge`): permanent. `open_library` and `worldcat` rows are verified evidence the Goodreads matcher reads. `RevertFacts` never deletes admin rows.

Who and how: `match_decisions.reviewed_via` (`admin_ui` or `api`) is stamped by `MatchDecision#review!` from `Current.acting_via`, including the reviews a reject cascades to. The page has a "Reviewed via" filter on reviewed decisions. The admin MCP document now has 46 tools (the description tools below, the book and author field tools in "Book and author field edits" and the repair verdict tools in "Repair verdicts" included).

The match decisions Copy prompt (`config/mcp/books/prompts/match_decisions.md.erb`) carries the per-kind workflow and the house rules (placeholder and place authors are deliberate, translators are not authors, never link same-name different people). E2E: `e2e/tests/books/admin/match-decisions-copy-prompt.spec.ts`.

## Repair verdicts

The books repair verdicts page (`/admin/repair_verdicts`) holds the Goodreads replay's findings, mostly `reimport_match` verdicts proposed for review (see `docs/features/goodreads-reimport.md`). Six admin tools work it. `Services::Books::RepairVerdicts::Filter` and `Review` are shared with the page, so both see the same queue and stamp `reviewed_via` (`admin_ui` or `api`).

- `list_repair_verdicts` (`books:admin:read`). Filters: `kind`, `status` (`proposed` by default), `decided_by`, `confidence`, `guess`.
- `get_repair_verdict` (`books:admin:read`). The payload with `facts`, `ai` and `candidate_book_ids`, plus `candidate_books`, `books` and `source_rows`.
- `approve_repair_verdict` (`books:admin:merge`). An approved merge destroys a row on the next apply, so approving takes the merge scope, as the page takes the delete gate.
- `reject_repair_verdict` (`books:admin:write`).
- `correct_repair_verdict` (`books:admin:write`). Body `{book_id}` or `{create: true}`; it runs `Services::Books::GoodreadsReimport::CorrectMatch` and approves the corrected answer.
- `bulk_approve_repair_verdicts` (`books:admin:merge`). Body `{ids: [...]}`, 1 to 100.

Nothing applies on approval: the matching apply task acts on approved verdicts later (`books:goodreads_reimport:apply` for re-import kinds, `books:goodreads_replay:apply` for replay kinds). The Copy prompt on the page (`config/mcp/books/prompts/repair_verdicts.md.erb`, queue `:repair_verdicts` in `Services::AgentPrompts`, counts of proposed `reimport_match` verdicts by confidence) tells the agent to approve or correct each one, never reject a `reimport_match`, and bulk approve only what it has read. E2E: `e2e/tests/books/admin/repair-verdicts-copy-prompt.spec.ts`.

## Description tools

An agent can read and fix the descriptions of books and authors with the same five actions as the admin description panel. `Api::V1::Admin::Books::DescriptionsController` is a thin mapper over `Services::Descriptions::AdminWrite`, which the admin page (`Admin::DescriptionsController`) calls too, so the two cannot drift.

- `get_book_descriptions` and `get_author_descriptions` (`books:admin:read`): every description of every kind and locale, rank descending then source (the page sorts the same way), plus `shown_description_id`, the English summary the public page shows (`Descriptions::Resolver`: a preferred description wins, else source priority manual > ai_generated > goodreads > wikipedia > openlibrary > publisher > other; a deprecated one is listed, never shown).
- `add_book_description` and `add_author_description` (`books:admin:write`): body `content`, `source` (required), `source_name`, `source_url`, `license`. Created as `summary`, `en`, `normal` like the page. Returns 201 with the row and `shown_description_id`.
- `update_description` (`books:admin:write`): any subset of those fields. Kind, locale and rank are not editable.
- `set_preferred_description` (`books:admin:write`): demote-then-promote in one transaction, so exactly one description per record, kind and locale is preferred.
- `delete_description` (`books:admin:merge`, destructive): permanent; returns the deleted row and the `shown_description_id` the record has afterwards.

Rulings:

- The agent picks `source`. The tool text says to use `ai_generated` for text it wrote itself, and otherwise the source the text came from.
- `source: wikipedia` needs `source_url` (400) and defaults `license` to `cc_by_sa_4` when omitted. This is the API's rule only; the admin page is unchanged. On update the URL requirement applies when the source is being set to wikipedia and no URL is held.
- One description per record, kind, locale, source and (for `other`) source name. A second one is 422 naming the existing description's id; the agent edits that one instead. A validation failure (bad source, `other` without `source_name`, content over `Correction::MAX_TEXT_VALUE_LENGTH`) is 400.
- Update, prefer and delete find the description by id only when its describable is a `Books::Book` or `Books::Author`; a music or games description, or a missing id, is 404.
- Setting `source` to something other than `other` without sending `source_name` drops the old name, as the page does.
- Policies: `update?` on the book or author for add, update and prefer; `destroy?` for delete. Each write logs `event=api_admin_description` with field names only, never the text.
- Cache: the admin page's writes trigger no cache refresh of the public page, so these do not either.

## Book and author field edits

An agent can read and edit a book's or author's own fields. `Api::V1::Admin::Books::BooksController` and `AuthorsController` map them onto `Services::Books::AdminUpdate` and `Services::Books::Authors::AdminUpdate`, the same save the admin edit pages run (the body checks live in `Api::V1::Admin::FieldUpdate`).

- `get_admin_book` and `get_admin_author` (`books:admin:read`): the record with exactly the editable fields plus `cleared_fields`. Book: `title`, `subtitle`, `sort_title`, `first_published_year`, `book_kind`, `original_language`, `alternate_titles`. Author: `name`, `sort_name`, `kind`, `birth_year`, `death_year`, `exclude_from_rankings`, `alternate_names`.
- `update_book` and `update_author` (`books:admin:write`, plus the policy's `update?`): `PATCH` with any subset of those fields (the language is sent as `original_language_id`). Returns 200 with the detail shape under `data` and `changed`, the field names whose value changed.

Rulings:

- A partial PATCH changes only what it sends. An empty body, or a value of the wrong JSON type, is 400; years are integers from -3000 to 3000. An unknown key, an unknown enum name (`book_kind`, `kind`) or an `original_language_id` with no Language row is 422, as is a failed validation (for example a blank title). Nothing is written on a refusal.
- Alternate lists are arrays of strings, stripped with blanks dropped, and replace the old list when sent.
- Clearable fields are `subtitle`, `first_published_year` and `original_language_id` on a book and `birth_year` and `death_year` on an author. `null` or `""` blanks one and writes a `cleared_fields` row (`cleared_via: api`, `cleared_by` the token's owner), even when the field was already blank. Enrichment (`ApplyBookFacts`, the Goodreads apply, the author fact sheet) leaves a field with a row blank and records `human_cleared`; setting a value deletes the row. See `docs/features/books_enrichment.md`.
- Each write logs `event=api_admin_field_update` with field names only, never the values.

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

`mcp_admin` offers the domain's admin scopes (on books `books:admin:read`, `books:admin:write`, `books:admin:merge`), limited to what the user may mint, so an admin holding only `books:admin:read` is granted only that scope. The write tools are not listed for that connection, so calling one is a JSON-RPC -32602 ("Tool not found"), and the REST controller behind them enforces the scope again. The principal carries the full effective set, so admin tools that dispatch to `books:read` endpoints still work. The 401 challenge on `/api/mcp/admin` carries its own `resource_metadata` URL and the admin scopes.

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

An IPv6 caller is counted per /64, not per address (an IPv4-mapped IPv6 address counts as the IPv4 one), in every per-IP window, because a single host usually controls a whole /64 and could otherwise rotate through addresses. Every token-endpoint answer is sent `no-store`, including the ones Doorkeeper's callbacks produce.

Hosted connectors reach the server from a few addresses shared by many members, and a per-IP window would throttle them together. `config.x.api.connector_egress_ranges` lists the vendor-published ranges (Anthropic's two, with their sources in a comment), and `config.x.api.connector_range_per_minute` gives each window a larger budget keyed on the range instead of the address. Each range is its own key, so all Anthropic traffic shares one budget per window. This is a budget, not a skip: a full skip would hand anyone on those ranges an unbounded channel for junk tokens. Another vendor is one entry in each map. ChatGPT is not a goal, and its ranges are not configured. Per-account limits still apply after authentication.

### Edge for the discovery documents

The discovery documents sit at the RFC-fixed `/.well-known/oauth-*` paths, outside `/api/`, so they do not inherit the edge's treatment of API paths, and a connector's backend cannot solve a challenge. A rule in the private Cloudflare repo gives them that treatment. It must be applied after this code is deployed and before the first claude.ai connection (`docs/launch-todo.md`, section 13). This repo records none of its details.

### Connected apps

`/developers/tokens` has a Connected apps section, rendered from `_connections.html.erb`. It lists the member's live connections (`OauthConnection.listed`): the app's name, the host it signs in through (`#redirect_hosts`), member or admin access, scopes, when it was approved and when it was last used. The page opens for anyone who can mint a token or has a live connection, so a member whose membership lapsed can still see and revoke what they connected. Creating and deleting personal tokens still needs a mintable scope (`require_mint_access!`).

Revoke is `DELETE /developers/connections/:id`, handled by `Developers::ConnectionsController`. It needs sign-in but not membership. It finds the row through `current_user.oauth_connections.live`, so another member's id, or one already revoked, is a 404. It calls `Services::Oauth::Connections.revoke!` and answers with a Turbo Stream that replaces `#developers_connections`. The app's next request fails and it sends the member back through sign-in.

### Pruning

`Oauth::PruneJob` runs `Services::Oauth::Pruner` as the `oauth_prune` schedule, daily at 03:45. It deletes:

- registered apps older than `oauth_unused_client_lifetime` (30 days) that have no connection row at all, meaning nobody ever finished signing in;
- authorization codes older than `oauth_grant_retention` (1 day);
- every token of a revoked connection;
- tokens on a live connection created before its `approved_at`, which no longer matter.

It keeps all connections, every live token, and revoked tokens created at or after a live connection's `approved_at`. Those are what reuse detection looks up: a replayed refresh token must still be found, or the replay would look like an unknown token and the connection would not be revoked. Those revoked rows are never pruned, so each active connection keeps adding roughly one row per refresh (about 24 a day at the one-hour token life) for as long as it stays approved. A cap is possible later. Do not use Doorkeeper's own cleanup task (`doorkeeper:db:cleanup`, `StaleRecordsCleaner`). It deletes revoked rows and breaks that detection.

### Increments

All three increments are built. Increment 1 is `/api/mcp`. Increment 2 is `/api/mcp/admin`, admin approval and the 30-day refresh limit. Increment 3 is Connected apps with Revoke, the daily prune, per-IPv6-/64 rate limiting, and the per-client sign-in instructions on `/developers`.

### Testing

`test/controllers/oauth/` (metadata, registration, authorization), `test/integration/oauth/flow_test.rb` (the flow over HTTP: PKCE, rotation, reuse, lapse, audience binding), `test/lib/oauth/`, `test/lib/services/oauth/`, `test/controllers/developers/connections_controller_test.rb` and `tokens_controller_test.rb` (Connected apps, Revoke, the page gate), `test/lib/services/oauth/pruner_test.rb` and `test/sidekiq/oauth/prune_job_test.rb`, the IPv6 cases in `test/lib/services/api/rate_limiter_test.rb`, and the model tests for the four OAuth models. The Playwright specs `e2e/tests/books/oauth-authorize.spec.ts`, `account/oauth-authorize.spec.ts` and `member/oauth-authorize.spec.ts` run a real loopback listener to prove the browser lands on the callback with `code` and `state`. `e2e/tests/books/member/connected-apps.spec.ts` connects an app and revokes it from `/developers/tokens`, and `e2e/tests/books/developers.spec.ts` checks the sign-in instructions carry the exact address. Acceptance (not automated): Claude Code and Codex connect by sign-in against the dev server, and claude.ai against production once the launch steps are done.

## Edge

The endpoints live under `/api/` so they get the edge's existing treatment of API paths. The edge rules live in the private `the-greatest-cloudflare` repo, which is the source of truth, and this public repo describes none of them. The OAuth discovery paths are the one exception to "under `/api/`"; see "Edge for the discovery documents" above.

## Testing

- `test/lib/api/dispatched_request_test.rb`, `test/lib/services/api/authenticator_test.rb` (the dispatched-principal seam), and `test/lib/mcp/`: `catalog_test.rb`, `admin_catalog_test.rb`, `dispatcher_test.rb`, `composite_test.rb`, `server_factory_test.rb`, `tool_result_test.rb`, `tool_directory_test.rb`, `sites/books_test.rb`, `sites/books/find_book_test.rb`.
- `test/controllers/api/mcp_controller_test.rb` and `mcp_admin_controller_test.rb`: JSON-RPC over Rack (`initialize`, `tools/list`, `tools/call`, prompts, resources, the modern lifecycle, 401, 403, 429, 405, one hit per request, parity with REST, malformed bodies, the log line). `test/support/mcp_rpc_helpers.rb` has the helpers, including `modern_rpc`.
- `test/integration/api/v1/operation_scope_contract_test.rb`: every operation's declared scope equals its controller's.
- `test/controllers/developers_controller_test.rb` and `e2e/tests/books/developers.spec.ts`: the MCP section of `/developers`.
- **Acceptance runs** (not automated): PR #447 recorded Claude Code, given only the URL and a token, answering "what are the top 10 Russian novels of the 19th century, and which lists put them there?" from tool results, citing each book's `url`. PR #449 recorded a `books:admin:read` token listing exactly the 4 read tools, and Claude Code with a merge token creating two throwaway categories, dry-running and then running a merge, then a delete, with the audit lines written. Repeat them after a gem update or a change to the dispatcher.

## Not yet

- **Music and games tools.** They need API operations with `x-mcp` blocks first, and the MCP routes added to those hosts.
- **REST follow-ups** that tool users meet: book and author merges parse `dry_run` leniently (`null`, `""` and `0` mean a real merge, where category merge and delete return a 400), and the four protected categories can still be renamed, re-parented or retyped through the category PATCH. Until fixed, only the admin prompt guards against both.
