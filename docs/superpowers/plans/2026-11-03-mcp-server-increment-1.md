# MCP Server Increment 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `POST /api/mcp` on the books host serves an MCP server whose tools are generated from `config/api/v1/openapi.yaml` and run the real API controllers in-process, so Claude Code with a member's personal access token can answer "what are the top 10 Russian novels of the 19th century, and which lists put them there?".

**Architecture:** An `Api::McpController` inherits `Api::V1::BaseController`, so the API's own authentication, rate limit and scope check run once, before any MCP server is built. It builds one stateless `MCP::Server` per request from a catalogue generated at boot from the OpenAPI document's `x-mcp` blocks. Each tool call goes through `Mcp::Dispatcher`, which calls `Rails.application.routes.call` with the already-authenticated principal in the Rack env, and `Mcp::ToolResult` maps the API response onto an MCP tool result. The books-specific parts (one composite tool, a prompt, a resource and the server instructions) live in one site module. Everything else is generic.

**Tech Stack:** Rails 8, `mcp` gem (`~> 1.8`; 1.9.0 is current and was read for this plan), openapi_first 4.2 (test contracts), json_schemer 2.5, Minitest + Mocha.

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-server-design.md` (decisions D1–D15). This plan is its increment 1. The admin endpoint (`/api/mcp/admin`, admin `x-mcp` blocks, admin usage prompt) is increment 2. The `/developers` section and `docs/features/mcp-server.md` are increment 3. Neither is built here.

## Global Constraints

- Gem: `gem "mcp", "~> 1.8"` (spec D1). Record the resolved version in the Task 3 report.
- Transport, exactly: `MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true, enable_json_response: true, serve_subscriptions_listen: false, allowed_hosts: <the current site's hosts from Rails.application.config.domains>)`. Never pass `token_verifier:` (D4).
- Server configuration: `MCP::Configuration.new(validate_tool_call_arguments: false, exception_reporter: ...)` (D9). The gem's missing-required check still runs, and its wording is accepted.
- Env keys, verbatim: `"the_greatest.api.principal"` and `"the_greatest.api.dispatched"` (D12). There is no `HTTP_` prefix, so no client header can set them.
- Endpoint path `/api/mcp`, routed only inside the books `DomainConstraint` block's `namespace :api` (D3). `GET` and `DELETE` answer 405 and never reach the transport (D2).
- Required scope for `/api/mcp` is `"#{Current.domain}:read"`. Generic MCP code (`app/lib/mcp/` outside `sites/`, and the controller) must not mention books (spec "Architecture").
- Inside nested namespaces, root-anchor app constants: `::Api::`, `::Books::`, `::Mcp::`. The gem's namespace is `MCP` and ours is `Mcp`. They are different constants, so never write a bare `Mcp` where `MCP` is meant, or the reverse.
- Tool results: 2xx gives the JSON body as one text content item with the top-level `links` member removed. Errors give `isError: true` with the problem body (D11). REST paging does not leak: the tool argument is `limit`, never `per_page` (anti-goals).
- No tool reaches data except through `Mcp::Dispatcher` (anti-goal 1). Composite tools call only the dispatcher (D13).
- Never copy Cloudflare zone details into this repo. Say "the edge" (memory rule).
- Lint: `bundle exec standardrb`. Never run brakeman. Use generators for controllers (`bin/rails generate controller`). Tests mirror namespaces.
- All commands run from `web-app/`.

## Review Focus

1. **A malformed or non-object JSON body** (`{"jsonrpc":`, `[]`, `"x"`) on `POST /api/mcp`: the client expects the transport's JSON-RPC error (parse error / invalid request), not a 500 from Rails' params parser or the logging line. Test in Task 5.
2. **`null` for an optional argument** (`{"category_id": null}`): models send it routinely. Treat it as omitted, not as `category_id=` (which the API rejects as blank). Test in Task 3.
3. **A slug containing `/` or `.`** (`get_book(slug: "a/b")`, `slug: "x.json"`): it must reach `getBook` as that literal slug and come back `not_found`. It must not route to `listBookLists` or trip the format constraint. Test in Task 3.
4. **`find_book` with no match, or with search down**: the result is an `isError` not-found, or the search tool's own `search_unavailable` error. It must not raise on an empty `data`. Test in Task 6.
5. **An array or hash argument value** (`category_id: ["a", "b"]`): it reaches the API as the bracketed query form and comes back as the API's 400 `invalid_parameter`, the same as REST. Test in Task 3.

---

### Task 1: Dispatch seams: the authenticator and rate limiter honour a dispatched request

**Files:**
- Create: `web-app/app/lib/api/dispatched_request.rb`
- Modify: `web-app/app/lib/services/api/authenticator.rb` (`call`)
- Modify: `web-app/app/controllers/concerns/api/rate_limited.rb` (`enforce_rate_limit!`)
- Test: `web-app/test/lib/api/dispatched_request_test.rb`, `web-app/test/lib/services/api/authenticator_test.rb` (exists; add cases), `web-app/test/controllers/api/v1/books/books_controller_test.rb` (add one header-spoof case)

**Interfaces:**
- Produces:
  - `::Api::DispatchedRequest::PRINCIPAL_KEY = "the_greatest.api.principal"`
  - `::Api::DispatchedRequest::DISPATCHED_KEY = "the_greatest.api.dispatched"`
  - `::Api::DispatchedRequest.mark(env, principal) -> env`, which sets both keys.
  - `::Api::DispatchedRequest.principal(env) -> ::Api::Principal | nil`
  - `::Api::DispatchedRequest.dispatched?(env) -> Boolean`

- [ ] **Step 1: Write the failing tests**

`authenticator_test.rb`:
- `test "a dispatched request returns the env principal without a token lookup or record_use"`: build a principal, then `env = Rack::MockRequest.env_for("/")` plus `::Api::DispatchedRequest.mark(env, principal)`, with no Authorization header. `Services::Api::Tokens.expects(:authenticate).never`, `Services::Api::Tokens.expects(:record_use).never`. Assert `result.success?` and `assert_same principal, result.data`.
- `test "a principal under any other env key is ignored"`: set `env["HTTP_THE_GREATEST_API_PRINCIPAL"] = principal` (what a `The-Greatest-Api-Principal` header becomes), with no Authorization header. Assert `result.errors == [:unauthenticated]`.

`dispatched_request_test.rb`:
- `mark` sets both keys. `principal` and `dispatched?` read them back. `dispatched?` is false on a bare env.

`books_controller_test.rb`:
- `test "a header named like the dispatch keys does not authenticate"`: `get "/api/v1/books", headers: {"The-Greatest-Api-Principal" => "1", "The-Greatest-Api-Dispatched" => "true"}`. Assert 401 `unauthenticated`.
- `test "a dispatched request is not counted against the rate limit"`: build the env with `Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/v1/books")` and `mark` it with a principal for `regular_user_token`. `Services::Api::RateLimiter.expects(:hit).never`. `status, = Rails.application.routes.call(env)`. Assert `status == 200`.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/api/dispatched_request_test.rb test/lib/services/api/authenticator_test.rb test/controllers/api/v1/books/books_controller_test.rb`
Expected: FAIL (`NameError: uninitialized constant Api::DispatchedRequest`).

- [ ] **Step 3: Implement**

- `Api::DispatchedRequest` is a plain module of constants plus the three methods. Its header comment says why the keys have no `HTTP_` prefix.
- `Authenticator#call` returns `success(principal)` first thing when `::Api::DispatchedRequest.principal(@request.env)` is present, before the header check.
- `enforce_rate_limit!` returns immediately when `::Api::DispatchedRequest.dispatched?(request.env)`. It sets no headers: the outer MCP response carries them.
- Update the two classes' header comments to say that the MCP dispatcher is the only writer of these keys.

- [ ] **Step 4: Run the tests and watch them pass**

Same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/api/dispatched_request.rb app/lib/services/api/authenticator.rb app/controllers/concerns/api/rate_limited.rb test/lib/api/dispatched_request_test.rb test/lib/services/api/authenticator_test.rb test/controllers/api/v1/books/books_controller_test.rb
git commit -m "API: authenticate and count a dispatched request once"
```

---

### Task 2: Per-operation scopes in both OpenAPI documents, plus the scope contract test (D7)

**Files:**
- Modify: `web-app/config/api/v1/openapi.yaml` (every operation)
- Modify: `web-app/config/api/v1/admin_openapi.yaml` (every operation)
- Modify: `web-app/app/lib/api/openapi_document.rb` (add `operations`)
- Test: `web-app/test/integration/api/v1/operation_scope_contract_test.rb` (new), `web-app/test/lib/api/openapi_document_test.rb` (new)

**Interfaces:**
- Produces:
  - `::Api::OpenapiDocument::Operation = Struct.new(:http_method, :path, :operation_id, :path_item, :definition, keyword_init: true)`, with `#scope -> String | nil`. `scope` is the single scope in `definition["security"]`, which is `[{"bearerAuth" => [scope]}]`. It is nil for `security: []`.
  - `::Api::OpenapiDocument.operations(source) -> Array<Operation>`, where `source` is a document Hash (`raw` or `for_host` output). It iterates `paths`, skips the non-method keys (`parameters`, `x-domain`, `summary`, …), and keeps HTTP methods only.

- [ ] **Step 1: Write the failing tests**

`operation_scope_contract_test.rb` (`ActiveSupport::TestCase`):
- For each document in `[:public, :admin]` and each `Operation` in `operations(raw(document))`:
  1. Build a sample URL. Replace `{id}` and `{category_id}` with `1` and any other `{param}` with `x`, then prefix it with `https://dev-new.thegreatestbooks.org`. `.json` paths are used as-is.
  2. Call `Rails.application.routes.recognize_path(url, method: op.http_method)`. Then `controller = "#{r[:controller]}_controller".camelize.constantize`.
  3. The enforced scope is `controller.action_scopes ? controller.action_scopes[r[:action]] : controller.required_scope`, or nil when `controller` is not an `::Api::V1::BaseController` subclass.
  4. Assert `op.scope == enforced`, with a message naming `operationId`.
- `test "every operation declares security explicitly"`: every operation has a `security` key. That holds for `getOpenapi` (`[]`) too.
- `test "getOpenapi is the only public operation without a scope"`.

`openapi_document_test.rb`:
- `operations(raw(:public))` includes `searchBooks` with `http_method == "get"` and `path == "/api/v1/search/books"`.
- No `Operation` has an `http_method` of `parameters` or `x-domain`.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/integration/api/v1/operation_scope_contract_test.rb test/lib/api/openapi_document_test.rb`
Expected: FAIL (`NoMethodError: operations`).

- [ ] **Step 3: Declare the scopes and add `operations`**

- Public document: put `security: [{bearerAuth: ["books:read"]}]` on every operation except `getOpenapi`, which keeps `security: []`.
- Admin document: put each operation's scope as the routed controller enforces it. `getAdminOpenapi` and the three search operations are `books:admin:read`. Category show is `books:admin:read`. Create, update, tag and untag are `books:admin:write`. The merges and delete are `books:admin:merge`. Read `require_scope(s)` in `app/controllers/api/v1/admin/**` for the truth. The contract test is the check.
- Leave the document-level `security` as it is.

- [ ] **Step 4: Run them, then the whole API suite, and watch them pass**

Run: `bin/rails test test/integration/api/v1/operation_scope_contract_test.rb test/lib/api/openapi_document_test.rb test/integration/api/v1/ test/controllers/api/ test/controllers/developers_controller_test.rb`
Expected: PASS. openapi_first must still accept every response. The `/developers` page renders from these documents, so its tests must stay green.

- [ ] **Step 5: Commit**

```bash
git add config/api/v1/openapi.yaml config/api/v1/admin_openapi.yaml app/lib/api/openapi_document.rb test/integration/api/v1/operation_scope_contract_test.rb test/lib/api/openapi_document_test.rb
git commit -m "API: declare each operation's scope, with a contract test"
```

---

### Task 3: The gem, `Mcp::Operation`, `Mcp::Dispatcher` and `Mcp::ToolResult`

**Files:**
- Modify: `web-app/Gemfile` (`gem "mcp", "~> 1.8"`), `web-app/Gemfile.lock`
- Create: `web-app/app/lib/mcp/operation.rb`, `web-app/app/lib/mcp/dispatcher.rb`, `web-app/app/lib/mcp/tool_result.rb`
- Test: `web-app/test/lib/mcp/dispatcher_test.rb`, `web-app/test/lib/mcp/tool_result_test.rb`

**Interfaces:**
- Consumes: `::Api::DispatchedRequest.mark` (Task 1).
- Produces:
  - `Mcp::Operation = Struct.new(:operation_id, :tool_name, :title, :description, :http_method, :path, :scope, :destructive, :arguments, :input_schema, keyword_init: true)`
    - `http_method` is lowercase (`"get"`).
    - `path` is the OpenAPI template (`"/api/v1/books/{slug}"`).
    - `arguments` is `Hash{String => Mcp::Operation::Argument}`.
    - `Mcp::Operation::Argument = Struct.new(:location, :wire_name, keyword_init: true)`, with `location` in `:path | :query | :body`.
  - `Mcp::Dispatcher.call(operation, arguments, principal:, request:) -> Mcp::Dispatcher::Response`
    - `arguments` is a Hash with Symbol or String keys.
    - `request` is the outer `ActionDispatch::Request`.
    - `Mcp::Dispatcher::Response = Struct.new(:status, :body, keyword_init: true)`. `body` is the parsed JSON (Hash or Array), or nil when the response body is empty or not JSON.
  - `Mcp::ToolResult.from(response) -> MCP::Tool::Response`
  - `Mcp::ToolResult.error(body_hash) -> MCP::Tool::Response` (`isError: true`), which Task 6 reuses.

- [ ] **Step 1: Add the gem**

Run: `bundle add mcp --version "~> 1.8"`, then `bundle exec ruby -e 'require "mcp"; puts MCP::VERSION'`.
Expected: prints a 1.x version of at least 1.8.2.

- [ ] **Step 2: Write the failing tests**

`dispatcher_test.rb` (`ActionDispatch::IntegrationTest`, so the parity test can issue the REST request with `get`. `host! "dev-new.thegreatestbooks.org"`):

Helpers:
- `outer_request(remote_ip: "203.0.113.9")` builds `ActionDispatch::Request.new(Rack::MockRequest.env_for("https://dev-new.thegreatestbooks.org/api/mcp", "action_dispatch.request_id" => "req-123"))` and sets `env["action_dispatch.remote_ip"] = remote_ip`.
- `principal` comes from `Services::Api::Authenticator.call(request_with_bearer(ApiTokenSecrets::MEMBER)).data`.
- The operations are built by hand: `get_book` (GET `/api/v1/books/{slug}`, with `slug` mapped to `:path`) and `list_books` (GET `/api/v1/books`, with `limit` mapped to query `per_page`, plus `page` and `category_id` mapped to query).

Tests:
- `test "a read returns the REST body for the same arguments"`. Dispatch `list_books` with `{limit: 2, page: 1}`. Then `get "/api/v1/books?per_page=2&page=1", headers: bearer(ApiTokenSecrets::MEMBER)`. Assert the dispatch's `status == 200` and that its `body` equals `response.parsed_body`.
- `test "path arguments are percent-encoded, including . and /"`. Dispatch `get_book` with `{slug: "a/b"}` and with `{slug: "x.json"}`. Each gives `status == 404` and `body["code"] == "not_found"`. Assert that both reached `books#show`: subscribe to `process_action.action_controller` and check `payload[:controller] == "Api::V1::Books::BooksController"` and `payload[:action] == "show"`. Without the encoding, `a/b` would route to `book_lists#index`.
- `test "null arguments are omitted"`. `{category_id: nil}` gives 200, the same as no argument.
- `test "an array argument reaches the API as its 400"`. `{category_id: ["a", "b"]}` gives 400 and `body["code"] == "invalid_parameter"`.
- `test "an unknown argument is an invalid_parameter error without dispatching"`. **Ruling:** spec D9 says an unknown argument should come back as the API's 400. But the REST controllers ignore unknown query parameters, so forwarding one would silently drop it. The dispatcher therefore answers with the API's own problem code instead. If that is wrong, the cost is one branch. `{bogus: 1}` gives 400, `body == {"code" => "invalid_parameter", "detail" => "Unknown argument: bogus"}`, and `Rails.application.routes.expects(:call).never`.
- `test "the inner request sees the outer remote_ip and request id"`. Capture them with `ActiveSupport::Notifications.subscribe("process_action.action_controller")` and `payload[:request]`. Assert `remote_ip == "203.0.113.9"` and `request_id == "req-123"`.
- `test "a dispatch counts no rate-limit hit and no token use"`. `Services::Api::RateLimiter.expects(:hit).never` and `Services::Api::Tokens.expects(:record_use).never`.
- `test "a body operation sends JSON"`. Build `create_category` by hand: POST `/api/v1/admin/categories`, with `name` and `category_type` (two `CategoryWrite` properties) mapped to `:body`, using the `ApiTokenSecrets::ADMIN` principal. Send `{name: "Mcp Test Genre", category_type: "genre"}`. Assert `status == 201` and `body["data"]["name"] == "Mcp Test Genre"`, which proves the JSON body arrived.
- `test "an exception in the controller becomes internal_error with the request id, reported"`. `Api::V1::Books::BooksController.any_instance.stubs(:show).raises(RuntimeError, "boom")`, plus `Rails.error.expects(:report)`. Assert `status == 500`, `body == {"code" => "internal_error", "detail" => "The tool failed unexpectedly.", "request_id" => "req-123"}`, and that `"boom"` appears nowhere in the body.
- `test "a no-route response has a nil body"`. An operation whose path is `/api/v1/nope` gives `status == 404` and `body` nil.

`tool_result_test.rb`:
- A 2xx response with `{"data" => [1], "meta" => {}, "links" => {"self" => "x"}}` gives `to_h[:isError] == false` and `JSON.parse(to_h[:content].first[:text]) == {"data" => [1], "meta" => {}}`.
- A 404 problem body gives `isError: true` with the whole problem as the JSON text (`code`, `detail`, and the extras kept).
- A 404 with a nil body gives `{"code" => "not_found"}`. A 502 with a nil body gives `{"code" => "internal_error"}`.
- A 503 `search_unavailable` problem keeps its code.

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/`
Expected: FAIL (`uninitialized constant Mcp::Dispatcher`).

- [ ] **Step 4: Implement**

`Mcp::Dispatcher.call` does the following:
1. Stringify keys and drop nil values.
2. Return the unknown-argument response for any key not in `operation.arguments`.
3. Interpolate path arguments with `ERB::Util.url_encode(value.to_s).gsub(".", "%2E")`.
4. Build the query with `Rack::Utils.build_nested_query` from the `:query` arguments under their `wire_name`. Build the body as JSON from the `:body` arguments.
5. `env = Rack::MockRequest.env_for(path_with_query, method: operation.http_method.upcase, input: json_or_nil, "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json", "HTTP_HOST" => request.host_with_port, "HTTPS" => request.ssl? ? "on" : "off")`.
6. Copy `action_dispatch.remote_ip` and `action_dispatch.request_id` from `request.env`.
7. `env.merge!(Rails.application.env_config)`, then `::Api::DispatchedRequest.mark(env, principal)`.
8. `status, headers, body = Rails.application.routes.call(env)`. Read the body with `each`, `close` it, and parse it as JSON when the Content-Type is JSON (`application/json` or `application/problem+json`), else nil.
9. Rescue `StandardError` around the call: `Rails.error.report(error)` and return the internal_error response above.

The header comment explains why `env_config` is merged and why `remote_ip` is copied (spec D10).

`Mcp::ToolResult` builds `MCP::Tool::Response.new([{type: "text", text: JSON.generate(payload)}], error: ...)`.

- [ ] **Step 5: Run the tests and watch them pass**

Run: `bin/rails test test/lib/mcp/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock app/lib/mcp/ test/lib/mcp/
git commit -m "MCP: dispatch a tool call through the router to the real API controller"
```

---

### Task 4: `Mcp::Catalog`: tools generated from `x-mcp`, plus `x-mcp` on every public operation

**Files:**
- Create: `web-app/app/lib/mcp/catalog.rb`
- Modify: `web-app/config/api/v1/openapi.yaml` (an `x-mcp` block on every operation except `getOpenapi`)
- Test: `web-app/test/lib/mcp/catalog_test.rb`

**Interfaces:**
- Consumes: `::Api::OpenapiDocument.operations` and `Operation#scope` (Task 2). `Mcp::Operation`, `Mcp::Dispatcher`, `Mcp::ToolResult` (Task 3).
- Produces:
  - `Mcp::Catalog.for(document:, domain:) -> Mcp::Catalog`. It is memoised per `[document, domain]` outside development, like `OpenapiDocument.raw`, and built from `::Api::OpenapiDocument.for_host(::Api::Host.base_url(domain), domain:, document:)`.
  - `Mcp::Catalog.new(source_hash)`, which raises `Mcp::Catalog::GenerationError < StandardError`.
  - `#operations -> Array<Mcp::Operation>`
  - `#fetch(operation_id) -> Mcp::Operation` (raises `KeyError`)
  - `#tool(operation_id) -> Class<MCP::Tool>`
  - `#tools_for(principal) -> Array<Class<MCP::Tool>>`: the tools whose `operation.scope` the principal satisfies (`principal.scope?`).
  - The tool's `call` reads `server_context[:principal]` and `server_context[:request]`. The server context is the Hash `{principal:, request:}`, built in Task 5.

Generation rules (spec D6, D9):

| Field | Rule |
| --- | --- |
| `tool_name` | `x-mcp.name`, else `operationId.underscore` |
| `description` | `x-mcp.description` (missing → `GenerationError` naming the operation) |
| `title` | the operation's `summary` |
| `scope` | `Operation#scope`; nil on an `x-mcp` operation → `GenerationError` (fail closed) |
| `destructive` | `x-mcp.destructive == true` |
| annotations | every hint set explicitly: GET → `read_only_hint: true, idempotent_hint: true, destructive_hint: false`; PUT and DELETE → `read_only_hint: false, idempotent_hint: true, destructive_hint: destructive`; POST and PATCH → `read_only_hint: false, idempotent_hint: false, destructive_hint: destructive`; always `open_world_hint: false`, `title:` the summary |
| input schema | `{"type" => "object", "properties" => ..., "required" => [...], "additionalProperties" => false}` from path-item parameters, operation parameters and the `application/json` request-body properties, with every `$ref` (parameters and schemas, recursively) resolved inline from `components`. A parameter's `description` overrides its schema's. `required` holds path parameters, query parameters marked `required: true` and the body's `required`. Omit `required` when it is empty. |
| renames | `per_page` becomes `limit` (`RENAMES = {"per_page" => "limit"}`, wire name kept) |
| collision | the same argument name from two locations → `GenerationError` naming both |
| no `x-mcp` | not a tool |

- [ ] **Step 1: Write the failing tests**

`catalog_test.rb`. A small inline fixture document (a Hash built in the test) exercises the rules. The real public document is then checked as a whole.

Fixture-document tests:
- One tool per `x-mcp` operation, and none for an operation without `x-mcp`.
- The default name is `list_widgets` from `listWidgets`, and `x-mcp.name` overrides it.
- `$ref` parameters are resolved: no `"$ref"` string anywhere in `input_schema.to_s`.
- `per_page` appears as `limit`, with the same `minimum`, `maximum` and `default`. `operation.arguments["limit"].wire_name == "per_page"`.
- `required` lists the path parameter and the required query parameter.
- `additionalProperties == false`.
- A body operation's properties are flattened next to its path parameter, and `arguments["name"].location == :body`.
- A collision raises `GenerationError` with a message containing both locations.
- A missing description raises. A missing scope raises.
- The annotations on GET, on POST without destructive, and on DELETE with `destructive: true` match the table. `tool.annotations_value.to_h[:destructiveHint]` is false for the GET.

Real-document tests (`Mcp::Catalog.for(document: :public, domain: :books)`):
- `test "every public operation but getOpenapi is a tool"`: the set of `operation_id`s equals the document's operation ids minus `getOpenapi`.
- `test "no admin path is in the public catalogue"`: no operation path starts with `/api/v1/admin`.
- `test "every input schema is valid JSON Schema 2020-12"`: `JSONSchemer.validate_schema(schema)` has no errors, for every tool. The gem also validates on construction, so `tool(...)` not raising is part of this.
- `test "tool names are unique"`.
- `test "tools_for filters by scope"`: a `books:read` principal sees every tool, and a `music:read`-only principal sees none.
- `test "every description is written for a model"`: each is at least 60 characters and none equals the summary.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/catalog_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement `Mcp::Catalog`, then write the `x-mcp` blocks**

- The tool block is `|server_context:, **args|`: `::Mcp::ToolResult.from(::Mcp::Dispatcher.call(operation, args, principal: server_context[:principal], request: server_context[:request]))`.
- `x-mcp.description` (D6) is written for a model choosing between tools. It says what the tool returns, when to use it, and when to prefer a neighbour. For example: `search_books` for a title, `get_book` once you have a slug, `list_books` with `country_id`, `year` and `category_id` for "top N … from …", and `list_categories` to discover category and country slugs. Name the paging rule once in `list_books`: `limit` is at most 100, and `meta.total_count` gives the size.
- Keep each description to 1–3 sentences. Do not restate the parameter list, which the schema carries.

- [ ] **Step 4: Run them, then Task 2's contract test, and watch them pass**

Run: `bin/rails test test/lib/mcp/ test/integration/api/v1/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/catalog.rb config/api/v1/openapi.yaml test/lib/mcp/catalog_test.rb
git commit -m "MCP: generate the tool catalogue from the OpenAPI document"
```

---

### Task 5: `POST /api/mcp`: server factory, controller, routes and logging

**Files:**
- Create: `web-app/app/lib/mcp/server_factory.rb`, `web-app/app/lib/mcp/sites.rb` (registry; `Mcp::Sites::None` only for now)
- Create, via generator: `bin/rails generate controller api/mcp --skip-routes --no-helper`. This gives `web-app/app/controllers/api/mcp_controller.rb` and `web-app/test/controllers/api/mcp_controller_test.rb`. Delete the empty `app/views/api/mcp/` directory it creates.
- Modify: `web-app/config/routes.rb` (inside the books block's `namespace :api`, outside `namespace :v1`)
- Test: `web-app/test/controllers/api/mcp_controller_test.rb`, `web-app/test/lib/mcp/server_factory_test.rb`

**Interfaces:**
- Consumes: `Mcp::Catalog.for`, `#tools_for` (Task 4).
- Produces:
  - `Mcp::Sites.for(domain) -> site`. A site responds to `instructions(document) -> String | nil`, `prompts(document) -> Array<Class<MCP::Prompt>>`, `resources(document) -> Array<Class<MCP::Resource>>` and `composites(document) -> Array<Class<Mcp::Composite>>`. `Mcp::Sites::None` returns nil or `[]` for every one.
  - `Mcp::Sites::REGISTRY = {}` (a Hash from domain Symbol to site module). Task 6 adds `books:`.
  - `Mcp::ServerFactory.build(document:, domain:, principal:, request:) -> MCP::Server`:
    - `name: "the-greatest-#{domain}"`, plus `version:` and `instructions:`.
    - `tools: catalog.tools_for(principal) + site.composites(document).select { |c| c.visible_to?(principal, catalog) }.map { |c| c.tool(catalog) }`.
    - `prompts:` and `resources:` from the site.
    - `server_context: {principal:, request:}`.
    - `configuration: MCP::Configuration.new(validate_tool_call_arguments: false, exception_reporter: ->(error, _context) { Rails.error.report(error) })`.
  - `Api::McpController < ::Api::V1::BaseController`:
    - `class_attribute :mcp_document, default: :public`. Increment 2 subclasses it for `:admin`.
    - A private `required_scope` override returning `"#{Current.domain}:read"`.
    - Actions `create` and `method_not_allowed`.
  - Routes: `post "mcp", to: "mcp#create", as: :mcp` and `match "mcp", to: "mcp#method_not_allowed", via: [:get, :delete]`.

- [ ] **Step 1: Write the failing tests**

`mcp_controller_test.rb` (`ActionDispatch::IntegrationTest`, `host! "dev-new.thegreatestbooks.org"`). The helper is `rpc(method, params = {}, id: 1, token: ApiTokenSecrets::MEMBER)`. It posts `{jsonrpc: "2.0", id:, method:, params:}.to_json` to `/api/mcp` with `Content-Type: application/json`, `Accept: application/json, text/event-stream` and the bearer header. Tests:
- `initialize` (with `protocolVersion: "2025-06-18"`, `capabilities: {}`, `clientInfo: {name: "test", version: "1"}`) gives 200 with `result.serverInfo.name == "the-greatest-books"`, no `Mcp-Session-Id` header, `Content-Type` starting with `application/json`, and `Cache-Control == "private, no-store"`. A second `initialize` also gives 200.
- `notifications/initialized` (no id) gives 202 with an empty body.
- `tools/list` includes `get_book`, `list_books` and `search_books`, and no tool name contains `per_page`.
- `tools/call get_book` on the war-and-peace slug gives `result.isError == false`, and its parsed text equals the REST `GET /api/v1/books/<slug>` body (parity, D11).
- `tools/call get_book` on `no-such-book` gives `isError == true`, with the same `code` and `detail` as the REST 404.
- `tools/call list_books` with `{limit: 0}` gives `isError` with the API's `invalid_parameter` and the same `detail` as REST `?per_page=0`.
- `tools/call list_books` with `{bogus: 1}` gives an `isError` `invalid_parameter`.
- `tools/call get_book` with `{}` gives the gem's `isError` text `"Missing required arguments: slug"`.
- An unknown tool gives a JSON-RPC error with code `-32602`.
- No token gives 401 with `code == "unauthenticated"` and `WWW-Authenticate: Bearer`. `NON_MEMBER` gives 403 `membership_required`. `MUSIC_ONLY` gives 403 `insufficient_scope`. `with_exhausted_limit` gives 429 with the `X-RateLimit-*` headers.
- `test "one MCP request is one rate-limit hit and one record_use"`: for `tools/call list_books`, `Services::Api::RateLimiter.expects(:hit).once` (returning a passing verdict) and `Services::Api::Tokens.expects(:record_use).once`.
- `GET /api/mcp` and `DELETE /api/mcp` with a token give 405 with `Allow: POST`.
- Review Focus 1: the bodies `{"jsonrpc":`, `[]` and `"x"` each give a 4xx JSON-RPC error body (`error.code` present), never a 500.
- The route is not served on the music host: `host! <music domain>`, then `post "/api/mcp"` gives 404.
- Logging: `Rails.logger.stubs(:info)`, then `Rails.logger.expects(:info).with(regexp_matches(%r{\Aevent=api_mcp rpc_method=tools/call tool=get_book user_id=\d+\z}))` for a `get_book` call. A `tools/list` logs `rpc_method=tools/list tool=-`. An unparsable body logs `rpc_method=- tool=-`. The token never appears.

`server_factory_test.rb`:
- `build` registers exactly `catalog.tools_for(principal)` when the site has no composites.
- `configuration.validate_tool_call_arguments` is false.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/controllers/api/mcp_controller_test.rb test/lib/mcp/server_factory_test.rb`
Expected: FAIL (no route).

- [ ] **Step 3: Implement**

`create` does the following:
1. Log the request (D15). Parse `request.raw_post` with `JSON.parse` and rescue `JSON::ParserError`. Read `method`, plus `params.name` for `tools/call`, using `-` for anything missing or when the body is not a Hash. Log `event=api_mcp rpc_method=%s tool=%s user_id=%d`.
2. Build the server with `::Mcp::ServerFactory.build(document: mcp_document, domain: Current.domain, principal: current_principal, request:)`.
3. Build the transport per Global Constraints. `allowed_hosts` is `Rails.application.config.domains.fetch(Current.domain).split(",")`.
4. `status, headers, body = transport.handle_request(request)`.
5. Copy every header except `Cache-Control` onto `response.headers`.
6. Join the body (`each`, then `close` if it responds to it). An empty body gives `head status`. Otherwise `render body: text, status:, content_type: "application/json"`.

The class header comment states why the transport's `token_verifier` is unused (D4) and why GET and DELETE never reach it (D2).

`method_not_allowed` sets `response.headers["Allow"] = "POST"` and calls `head :method_not_allowed`. The before_actions still run, so an unauthenticated GET is a 401. That is accepted.

- [ ] **Step 4: Run them and watch them pass**

Run: `bin/rails test test/controllers/api/mcp_controller_test.rb test/lib/mcp/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/server_factory.rb app/lib/mcp/sites.rb app/controllers/api/mcp_controller.rb config/routes.rb test/controllers/api/mcp_controller_test.rb test/lib/mcp/server_factory_test.rb
git commit -m "MCP: serve /api/mcp on the books host"
```

---

### Task 6: The books site: `find_book`, the `usage` prompt, the `ranking-methodology` resource and the instructions

**Files:**
- Create: `web-app/app/lib/mcp/composite.rb` (base class)
- Create: `web-app/app/lib/mcp/sites/books.rb`, `web-app/app/lib/mcp/sites/books/find_book.rb`
- Create: `web-app/config/mcp/books/instructions.md`, `web-app/config/mcp/books/usage.md`, `web-app/config/mcp/books/ranking_methodology.md`
- Modify: `web-app/app/lib/mcp/sites.rb` (`REGISTRY = {books: ::Mcp::Sites::Books}`)
- Test: `web-app/test/lib/mcp/sites/books_test.rb`, `web-app/test/lib/mcp/sites/books/find_book_test.rb`, plus additions to `web-app/test/controllers/api/mcp_controller_test.rb`

**Interfaces:**
- Consumes: `Mcp::Catalog#fetch`, `Mcp::Dispatcher.call`, `Mcp::ToolResult.error` (Tasks 3 and 4), and `Mcp::Sites` (Task 5).
- Produces:
  - `Mcp::Composite` (base class, generic):
    - `self.operation_ids -> Array<String>`, which a subclass declares with `operations "searchBooks", "getBook", "listBookLists"`.
    - `self.visible_to?(principal, catalog) -> Boolean`: every operation's scope is satisfied.
    - `self.tool(catalog) -> Class<MCP::Tool>`, built from the subclass's `tool_name`, `description`, `input_schema` and `self.run(catalog, args, principal:, request:) -> MCP::Tool::Response`. Memoise it per catalog.
    - `dispatch(catalog, operation_id, args, principal:, request:)`, which forwards to `Mcp::Dispatcher.call(catalog.fetch(operation_id), ...)`. It is the only data access a composite has.
  - `Mcp::Sites::Books`: `instructions(:public)`, `prompts(:public)`, `resources(:public)` and `composites(:public) == [FindBook]`. Any other document returns nil or `[]` until increment 2.

`find_book(title)` (D13):
1. `searchBooks` with `{q: title, limit: 1}`. A non-2xx response is returned as `ToolResult.from` of that response, which covers the 503.
2. An empty `data` is returned as `ToolResult.error({"code" => "not_found", "detail" => "No book matches \"#{title}\""})`.
3. Otherwise `getBook` with `{slug:}` and `listBookLists` with `{slug:, limit: 100}`.
4. The 2xx result is `{"book" => <getBook body "data">, "lists" => <listBookLists body "data">, "lists_total_count" => <its meta total_count>}`. Any non-2xx step returns that step's error.

- [ ] **Step 1: Write the failing tests**

`find_book_test.rb`, with `::Search::Books::Search::BookGeneral` stubbed the way `book_searches_controller_test.rb` does it (`hits(...)`):
- A match gives `book.slug == war_and_peace.slug`, a `lists` Array and an Integer `lists_total_count`.
- Review Focus 4: no hits gives `isError` `not_found` with the detail naming the title. `BookGeneral.stubs(:call).raises(Faraday::ConnectionFailed.new("down"))` gives `isError` `search_unavailable`.
- `test "every operation a composite uses exists in its endpoint's catalogue"`: for each site in `Mcp::Sites::REGISTRY` and each composite of `:public`, call `Mcp::Catalog.for(document: :public, domain:).fetch(id)` for every id.
- `visible_to?` is true for a `books:read` principal and false for `music:read`-only.

`books_test.rb`:
- `usage` prompt text includes each D14 rule as a phrase: "cite", "url", "rank order", "total_count", and "never invent a rank".
- The resource `uri == "greatest://books/ranking-methodology"`, with `mime_type == "text/markdown"`. Its contents run between 300 and 600 words.
- `instructions(:public)` is one paragraph (no blank line) and mentions citing `url`.

Additions to `mcp_controller_test.rb`:
- `prompts/get usage` answers.
- `resources/list` includes the methodology URI, and `resources/read` on it returns its text.
- `tools/call find_book` with search stubbed counts one rate-limit hit (`RateLimiter.expects(:hit).once`).
- `initialize`'s `result.instructions` is present.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/sites/ test/controllers/api/mcp_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement, and write the three texts**

- The prompt is `MCP::Prompt.define(name: "usage", description: ...)`, returning `MCP::Prompt::Result.new(messages: [MCP::Prompt::Message.new(role: "user", content: MCP::Content::Text.new(text))])`.
- The resource is a class subclassing `MCP::Resource`, with `uri`, `resource_name "ranking-methodology"`, `mime_type "text/markdown"` and `def self.contents(server_context: nil)` returning the file text.
- Read the files once at class load.
- The methodology text, ~400 words of prose (D14), says how lists are weighted into the ranking, what a ranking configuration is, and what `rank` means. It comes from `docs/features/rankings.md` and `docs/features/public-api.md`. It must not claim anything those docs do not say.
- The usage text states the D14 rules. The instructions are its one-paragraph version.

- [ ] **Step 4: Run them, then the whole suite and lint**

Run: `bin/rails test test/lib/mcp/ test/controllers/api/`, then `bin/rails test` and `bundle exec standardrb`, then `CI=1 bin/rails zeitwerk:check`.
Expected: all green, with no new warning lines.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/ config/mcp/ test/lib/mcp/ test/controllers/api/mcp_controller_test.rb
git commit -m "MCP: find_book, the usage prompt and the ranking methodology for books"
```

---

### Task 7: Acceptance against the dev server (controller-run, not a subagent)

The spec's increment-1 "Done when" is goal 7. This task touches the shared dev server and dev database, so the controller runs it.

- [ ] **Step 1:** Run `yarn build:all`, then confirm port 3000 is free or this worktree's (the AGENTS.md check). If another checkout holds it, stop and tell Shane.
- [ ] **Step 2:** Start `bin/rails server` in the background.
- [ ] **Step 3:** Mint a `books:read` token in development with `Services::Api::Tokens.generate(user:, name: "mcp-acceptance", scopes: ["books:read"])` for an active member. This writes one `api_tokens` row and nothing else.
- [ ] **Step 4:** Write a scratchpad `--mcp-config` JSON for `https://dev-new.thegreatestbooks.org/api/mcp` with the bearer header. Run `claude -p --strict-mcp-config --mcp-config <file> "What are the top 10 Russian novels of the 19th century, and which lists put them there? Cite each book's url."`. This changes no user-level Claude config.
- [ ] **Step 5:** Check the answer. It should cite `url`s and contain no invented ranks, and the server log should show `event=api_mcp rpc_method=tools/call` lines.
- [ ] **Step 6:** Record the working `claude mcp add --transport http greatest-books <url>/api/mcp --header "Authorization: Bearer $TOKEN"` command in the PR description for increment 3's `/developers` section.
- [ ] **Step 7:** Revoke the token and stop the server.
