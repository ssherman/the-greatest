# MCP Server Increment 2 (Admin Endpoint) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `POST /api/mcp/admin` on the books host serves the admin API's operations as MCP tools to `books:admin:*` tokens. A read-only admin sees only read tools. A merge-scoped admin can dry-run and then run a category merge from Claude Code, and the API's audit line is written.

**Architecture:** Increment 1 built everything generic: the catalogue generator, the dispatcher, the server factory and `Api::McpController`. Increment 2 adds `x-mcp` blocks to `config/api/v1/admin_openapi.yaml` and a controller subclass serving the `:admin` document. It also adds the books admin prompt and instructions to `Mcp::Sites::Books`. Three hardening changes come first because the admin tools depend on them:
- the generator validates `x-mcp` strictly;
- a composite's safety hints are derived from its operations;
- the dispatcher sends an explicit `null` in a JSON body, because PATCH uses `null` to clear a field.

**Tech Stack:** Rails 8, `mcp` gem 1.9.0 (locked), Minitest + Mocha, openapi_first (test contracts).

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-server-design.md`. This is its increment 2: D3, D6, D8 and D14 (admin parts), plus the increment table's row 2. It also carries the increment-1 final review's MUSTs, recorded in project memory: strict `x-mcp` validation and composite annotations derived from operations. Increment 3 (`/developers` section, `docs/features/mcp-server.md`) is not built here.

## Global Constraints

- Endpoint `POST /api/mcp/admin`, document `:admin`, required scope `"#{Current.domain}:admin:read"`, which is `books:admin:read` on books (D3). It is routed only inside the books `DomainConstraint` block's `namespace :api`, next to `/api/mcp`. `GET` and `DELETE` return 405 (D2).
- The admin controller subclasses `Api::McpController`. It gets no new transport, factory or logging code: it changes only `mcp_document` and `required_scope`.
- Name the controller `Api::McpAdminController` (`app/controllers/api/mcp_admin_controller.rb`). Never create an `Api::Mcp` module: inside `module Api` it would shadow `::Mcp`.
- `x-mcp` on every admin operation except `getAdminOpenapi`.
- `destructive: true` on exactly these six operations, and nowhere else: `mergeCategories`, `mergeBook`, `mergeAuthor`, `deleteAdminCategory`, `untagBook`, `untagAuthor`. That is every merge and every DELETE.
- The listing is scope-filtered by the existing `Catalog#tools_for` (D8).
  - A `books:admin:read` token lists exactly: `search_admin_books`, `search_admin_authors`, `search_admin_categories`, `get_admin_category`.
  - A `books:admin:write` token additionally lists: `create_admin_category`, `update_admin_category`, `tag_book`, `untag_book`, `tag_author`, `untag_author`.
  - A `books:admin:merge` token lists all 14.
- The admin usage prompt (D14) adds this rule to the public usage rules: "dry-run every merge and delete first, show the user the dry-run result, and only then run it". The admin server's `instructions` is a one-paragraph version of it.
- Generic code (`app/lib/mcp/` outside `sites/`, plus the controllers) must not mention books. Root-anchor `::Books::`, `::Mcp::` and `::Api::` inside nested namespaces. The gem is `MCP` and ours is `Mcp`.
- Never copy Cloudflare zone details into this repo.
- Lint: `bundle exec standardrb`. Never run brakeman. Create controllers with the generator. Tests mirror namespaces. Run all commands from `web-app/`.

## Review Focus

1. **Clearing a field with `null`.** `update_admin_category(id:, parent_id: null)` or `description: null` must reach the API as JSON `null` and clear the field. The CategoryWrite contract says "null clears it". Increment 1 drops every nil argument, so today this is silently a no-op 200. Test in Task 2.
2. **A merge called without `dry_run`.** The API defaults `dry_run` to false, so a tool call without it really merges. Each merge and delete tool's description must say so and tell the model to call with `dry_run: true` first. Test in Task 3.
3. **A non-numeric `id`** (`get_admin_category(id: "abc")`). The routes constrain `id` to `\d+`, so this is a router 404. The agent must get `not_found`, never `internal_error`. Test in Task 4.
4. **A partial category merge.** One source fails mid-loop and the API answers 422 with `merged`, `failed` and `not_attempted`. All three must reach the agent in the `isError` result, so it can tell the user what happened instead of retrying blindly. Test in Task 4.
5. **A string-of-digits id** (`source_id: "42"`, `category_id: "7"`). The API accepts these (`oneOf` integer or digit-string). With the gem's validation off they must pass through and succeed. Test in Task 4.

---

### Task 1: Catalogue hardening: strict `x-mcp`, and composite annotations from operations

**Files:**
- Modify: `web-app/app/lib/mcp/catalog.rb` (`generate`)
- Modify: `web-app/app/lib/mcp/composite.rb` (`ANNOTATIONS`, `build_tool`)
- Modify: `web-app/app/lib/mcp/operation.rb` (add `#annotations`)
- Test: `web-app/test/lib/mcp/catalog_test.rb`, `web-app/test/lib/mcp/composite_test.rb`

**Interfaces:**
- Produces:
  - `Mcp::Operation#annotations -> Hash`, with keys `read_only_hint`, `idempotent_hint`, `destructive_hint`, `open_world_hint`. It follows the existing method table in `Catalog`: GET is read-only and idempotent; PUT and DELETE are idempotent; POST and PATCH are not. `destructive_hint` is `destructive`, and `open_world_hint` is always false. `Catalog#build_tool` uses it (merging `title:`), so there is one table.
  - `Mcp::Composite.annotations(catalog) -> Hash` over the declared operations:
    - `read_only_hint` and `idempotent_hint` are true only when every operation's hint is;
    - `destructive_hint` is true when any operation's is;
    - `open_world_hint` is false.

    Remove `Composite::ANNOTATIONS`.
  - New `GenerationError` cases in `Catalog#generate`, each message naming the operation id:
    - `x-mcp` present but not a Hash;
    - `destructive` present but not exactly `true` or `false`;
    - `destructive: true` on a GET;
    - an unknown key in `x-mcp`. The allowed keys are `name`, `description` and `destructive`.

- [ ] **Step 1: Write the failing tests**

`catalog_test.rb`, using the existing inline fixture-document helper:
- `test "a non-Hash x-mcp fails generation"`: `x-mcp: true` raises `GenerationError` matching `/listWidgets: x-mcp must be a mapping/`.
- `test "a non-boolean destructive fails generation"`: `destructive: "true"` raises a `GenerationError` matching `/destructive must be true or false/`.
- `test "destructive on a GET fails generation"` raises `/a GET cannot be destructive/`.
- `test "an unknown x-mcp key fails generation"`: `{description: "...", destrutive: true}` raises `/unknown x-mcp key: destrutive/`.
- `test "destructive: false is accepted"` on a POST; the tool's `destructiveHint` is false.

`composite_test.rb`, with a test-only `Mcp::Composite` subclass over a fixture catalogue:
- A composite over two GETs gets `{readOnlyHint: true, idempotentHint: true, destructiveHint: false, openWorldHint: false}`.
- A composite over a GET plus a `destructive: true` POST gets `readOnlyHint: false`, `idempotentHint: false` and `destructiveHint: true`.
- `FindBook`'s tool annotations are unchanged: read-only, idempotent, not destructive.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/catalog_test.rb test/lib/mcp/composite_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

Validation goes at the top of `Catalog#generate`, before the description check. `Composite.build_tool` passes `annotations(catalog).merge(title: title)`.

- [ ] **Step 4: Run them, then `test/lib/mcp/`, and watch them pass**

Run: `bin/rails test test/lib/mcp/`
Expected: PASS. The real public catalogue still generates.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/catalog.rb app/lib/mcp/composite.rb app/lib/mcp/operation.rb test/lib/mcp/catalog_test.rb test/lib/mcp/composite_test.rb
git commit -m "MCP: validate x-mcp strictly and derive composite hints from their operations"
```

---

### Task 2: The dispatcher sends `null` in a JSON body

**Files:**
- Modify: `web-app/app/lib/mcp/dispatcher.rb` (argument handling and header comment)
- Test: `web-app/test/lib/mcp/dispatcher_test.rb`

**Interfaces:**
- Consumes: the existing `Mcp::Dispatcher.call(operation, arguments, principal:, request:)`.
- Produces: the same signature, with one behaviour change.
  - A nil argument whose location is `:body` is kept and sent as JSON `null`.
  - A nil argument whose location is `:path` or `:query` is still omitted.
  - An unknown argument is still rejected, nil or not.

  **Ruling:** spec D9 and the increment-1 null ruling were about query parameters. The admin API's PATCH contract says `null` clears a field. Dropping nil there would make clearing impossible and turn a clear into a silent no-op 200. If this is wrong, a model that sends `null` meaning "leave alone" clears the field. Task 3's `update_admin_category` description says exactly how `null` and omission differ.

- [ ] **Step 1: Write the failing tests**

All use the `ApiTokenSecrets::ADMIN` principal.
- `test "a null body argument is sent as JSON null and clears the field"`:
  1. Give a fixture books category a parent: `category.update!(parent: other)`.
  2. Dispatch a hand-built PATCH `/api/v1/admin/categories/{id}` operation with `{id: category.id, parent_id: nil}`. The operation has `parent_id` at `:body`.
  3. Assert 200 and `category.reload.parent_id` is nil.
- `test "a null body argument is in the JSON sent"`: capture `env["rack.input"]` through a `Rails.application.routes` stub (`.with { |env| ... }`). The parsed body equals `{"parent_id" => nil}`.
- The existing "null arguments are omitted" query test still passes unchanged.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/dispatcher_test.rb`
Expected: FAIL. The parent is still set, because the body was `{}`.

- [ ] **Step 3: Implement**

Apply the nil-dropping per location instead of `.compact` on all arguments. Update the header comment to explain why body nulls are kept.

- [ ] **Step 4: Run `test/lib/mcp/` and watch it pass**

Run: `bin/rails test test/lib/mcp/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/dispatcher.rb test/lib/mcp/dispatcher_test.rb
git commit -m "MCP dispatcher: send null in a JSON body, so a PATCH can clear a field"
```

---

### Task 3: `x-mcp` on every admin operation

**Files:**
- Modify: `web-app/config/api/v1/admin_openapi.yaml`
- Test: `web-app/test/lib/mcp/admin_catalog_test.rb` (new)

**Interfaces:**
- Consumes: `Mcp::Catalog.for(document: :admin, domain: :books)` and Task 1's validation.
- Produces: 14 admin tools. Their names are the default `operationId.underscore`: `search_admin_books`, `search_admin_authors`, `search_admin_categories`, `create_admin_category`, `get_admin_category`, `update_admin_category`, `delete_admin_category`, `merge_categories`, `merge_book`, `merge_author`, `tag_book`, `untag_book`, `tag_author`, `untag_author`. Task 4's listing tests use these names.

- [ ] **Step 1: Write the failing tests**

`admin_catalog_test.rb` (`ActiveSupport::TestCase`), on `catalog = Mcp::Catalog.for(document: :admin, domain: :books)`:
- `test "every admin operation but getAdminOpenapi is a tool"`.
- `test "exactly the merges and DELETEs are destructive"`: the set of `operation_id`s with `destructive` equals `%w[mergeCategories mergeBook mergeAuthor deleteAdminCategory untagBook untagAuthor]`.
- `test "every input schema is valid JSON Schema 2020-12"`, as in `catalog_test.rb`.
- `test "body and path arguments are flattened"`:
  - `tag_book` has `id` at `:path` and `category_id` at `:body`, and both are required.
  - `untag_book` has both at `:path`.
  - `delete_admin_category` has `dry_run` at `:query`.
  - `merge_categories` has `source_ids` and `dry_run` at `:body`.
- `test "merge and delete descriptions tell the model to dry-run first"`: each destructive tool that takes `dry_run` (the three merges and `delete_admin_category`) has a description matching `/dry_run/` and `/first/i`.
- `test "update_admin_category says how null and omission differ"`: its description matches `/omit/i` and `/null/`.
- `test "no public operation is in the admin catalogue"`: every path starts with `/api/v1/admin/`.
- `test "the public catalogue is unchanged"`: `Mcp::Catalog.for(document: :public, domain: :books).operations.size == 17`.

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/lib/mcp/admin_catalog_test.rb`
Expected: FAIL. The catalogue is empty.

- [ ] **Step 3: Write the `x-mcp` blocks**

The rules are the same as increment 1 (spec D6): 1–3 sentences per tool, written for a model choosing between tools, without restating the parameter list. Each must be accurate against the admin OpenAPI operation text and `docs/features/public-api.md` "Admin permissions". It names:
- **where ids come from:** the `search_admin_*` tools return integer ids, and every admin write takes ids, not slugs;
- **what is permanent:** merges fold the source in and delete it; a category delete removes every link to the category;
- **how to undo:** an untag is undone by tagging again.

Additional rules per tool:
- **The three merges and `delete_admin_category`:**
  - `dry_run` defaults to false, so call with `dry_run: true` first;
  - show the user the dry-run result;
  - run again with `dry_run: false` only after the user agrees.
- **`merge_categories`:** a failure part-way returns 422 with `merged`, `failed` and `not_attempted`. Report all three; do not retry blindly.
- **`update_admin_category`:**
  - omit a key to leave it unchanged;
  - `null` clears `description` or `parent_id`;
  - `category_type` is one of `genre`, `location`, `subject`, `theme`, `audience`.

Use the same YAML shape as the public document (`x-mcp:` → `description: >-`, plus `destructive: true` on the six).

- [ ] **Step 4: Run it, then the API contract and catalogue suites, and watch them pass**

Run: `bin/rails test test/lib/mcp/ test/integration/api/ test/controllers/api/`
Expected: PASS. openapi_first still validates every admin response.

- [ ] **Step 5: Commit**

```bash
git add config/api/v1/admin_openapi.yaml test/lib/mcp/admin_catalog_test.rb
git commit -m "MCP: admin tools from the admin OpenAPI document"
```

---

### Task 4: `POST /api/mcp/admin`

**Files:**
- Create via `bin/rails generate controller api/mcp_admin --skip-routes --no-helper`: `web-app/app/controllers/api/mcp_admin_controller.rb` and `web-app/test/controllers/api/mcp_admin_controller_test.rb`. Delete any empty `app/views/api/mcp_admin/`. Change the superclass to `::Api::McpController`.
- Modify: `web-app/config/routes.rb`. Add the two routes next to the `/api/mcp` ones.
- Test: `web-app/test/controllers/api/mcp_admin_controller_test.rb`

**Interfaces:**
- Consumes: `Api::McpController` (`mcp_document` class attribute; private `required_scope`; actions `create` and `method_not_allowed`) and Task 3's tool names.
- Produces:
  - `Api::McpAdminController < ::Api::McpController`, with `self.mcp_document = :admin` and a private `required_scope` returning `"#{Current.domain}:admin:read"`.
  - Routes: `post "mcp/admin", to: "mcp_admin#create", as: :mcp_admin` and `match "mcp/admin", to: "mcp_admin#method_not_allowed", via: [:get, :delete]`.

- [ ] **Step 1: Write the failing tests**

`mcp_admin_controller_test.rb` (`ActionDispatch::IntegrationTest`, `host! "dev-new.thegreatestbooks.org"`). Reuse the `rpc` and `modern_rpc` helper shapes from `test/controllers/api/mcp_controller_test.rb`. If they are copied, extract them into `test/support/mcp_rpc_helpers.rb`, included in both tests, rather than duplicating them.

Tokens:
- `ApiTokenSecrets::ADMIN_READ` (books:admin:read);
- `ApiTokenSecrets::ADMIN` (books:admin:merge);
- a write-only token minted in setup with `Services::Api::Tokens.generate(user: users(:admin_user), name: "write", scopes: ["books:admin:write"], expires_at: 1.day.from_now)`;
- `ApiTokenSecrets::MEMBER`.

Tests:
- **Listing per scope.** `tools/list` returns exactly the read set for `ADMIN_READ`, the read and write sets for the write token, and all 14 for `ADMIN` (Global Constraints). In each set, `destructiveHint` is true for exactly the destructive tools.
- **An unlisted tool.** `ADMIN_READ` calling `merge_categories` gets JSON-RPC error `-32602`. The API is never reached: `::Api::V1::Admin::Books::CategoriesController.any_instance.expects(:merge).never`.
- **Wrong tokens and hosts.**
  - `MEMBER` gets 403 `insufficient_scope`, with a detail naming `books:admin:read`.
  - No token gets 401.
  - The music host gets a 404.
  - GET and DELETE get 405.
- **Dry-run, then merge**, with `ADMIN` and two fixture books categories, source and target (for example `categories(:books_novels_genre)` into `categories(:books_fiction_genre)`; check the fixtures for books genres):
  1. `merge_categories` with `{id: target.id, source_ids: [source.id], dry_run: true}` gives `isError: false`, and the source is still active.
  2. The same call with `dry_run: false` merges the source.
  3. The `event=api_admin_category_merge` audit line was logged, with the principal's `user_id`. Use `Rails.logger.stubs(:info)` plus `expects(:info).with(regexp_matches(...))`.
- **Review Focus 3:** `get_admin_category` with `{id: "abc"}` gives `isError` with code `not_found`.
- **Review Focus 4:** use three sources and make the second fail with `::Categories::ItemCounter.stubs(:call).returns(nil).then.raises(RuntimeError, "boom")`, the pattern in `test/controllers/api/v1/admin/books/category_destructive_test.rb:145-148`. The `isError` text carries `merged`, `failed` and `not_attempted`.
- **Review Focus 5:** `tag_book` with `{id: book.id.to_s, category_id: category.id.to_s}` succeeds, and the link exists.
- **Review Focus 1, end to end:** `update_admin_category` with `{id:, parent_id: nil}` clears the parent.
- **The modern lifecycle:** a `modern_rpc` `tools/call search_admin_categories` gives 200 and no `Mcp-Session-Id`.
- **Rate limiting:** one MCP POST is one rate-limit hit (`Services::Api::RateLimiter.expects(:hit).once`), with an admin-tier verdict returned.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/controllers/api/mcp_admin_controller_test.rb`
Expected: FAIL. There is no route.

- [ ] **Step 3: Implement the controller and routes**

The class comment says the subclass changes only the document and the scope. The route comment says the admin endpoint is separate so admin tool descriptions never reach member clients (D3).

- [ ] **Step 4: Run them, then the MCP and API suites, and watch them pass**

Run: `bin/rails test test/controllers/api/ test/lib/mcp/ test/integration/api/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/mcp_admin_controller.rb config/routes.rb test/controllers/api/mcp_admin_controller_test.rb test/support/
git commit -m "MCP: serve /api/mcp/admin to books admin tokens"
```

---

### Task 5: The admin usage prompt and instructions

**Files:**
- Create: `web-app/config/mcp/books/admin_usage.md`, `web-app/config/mcp/books/admin_instructions.md`
- Modify: `web-app/app/lib/mcp/sites/books.rb` (the `:admin` branches of `instructions`, `prompts`, `resources` and `composites`)
- Test: `web-app/test/lib/mcp/sites/books_test.rb`, `web-app/test/controllers/api/mcp_admin_controller_test.rb`

**Interfaces:**
- Consumes: `Mcp::Sites::Books` (increment 1) and the server factory's per-document calls.
- Produces:
  - `Mcp::Sites::Books.instructions(:admin) -> String` (one paragraph).
  - `prompts(:admin) -> [ADMIN_USAGE_PROMPT]`, named `usage`, like the public one. Each endpoint has its own `usage`.
  - `resources(:admin) -> [RankingMethodology]`, because admins reason about rankings too.
  - `composites(:admin) -> []`. `find_book`'s operations are not in the admin catalogue.

- [ ] **Step 1: Write the failing tests**

`books_test.rb`:
- The admin usage text contains `"dry-run"` (or `dry_run`), `"show the user"`, `"only then"`, `"permanent"`, and `"ids"`, the last of these from the instruction to take ids from the search tools.
- `instructions(:admin)` is one paragraph and mentions dry-running first.
- `composites(:admin) == []`.
- The public `prompts(:public)` and `instructions(:public)` are unchanged; compare against the files.

`mcp_admin_controller_test.rb`:
- `prompts/get usage` on `/api/mcp/admin` returns the admin text.
- `initialize` (or `server/discover`) `instructions` is the admin paragraph.
- `resources/read` on the methodology URI answers.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/sites/ test/controllers/api/mcp_admin_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Write the texts and the `:admin` branches**

The admin usage text keeps the public rules that apply to admin results: answer from tool results and never invent. It adds these, each accurate against the admin operations:
- **Order of operations:** dry-run every merge and delete first, show the user the dry-run result, and only then run it with `dry_run: false`, after the user agrees;
- **Ids:** take ids from the `search_admin_*` tools and never guess an id;
- **Permanence:** merges and deletes are permanent; an untag is undone by tagging again;
- **Partial merges:** report `merged`, `failed` and `not_attempted` exactly;
- **Edits:** omit a key to leave it, and `null` clears it.

The instructions are the one-paragraph version. Plain, direct prose, read once at class load like the public texts.

- [ ] **Step 4: Run the whole suite and lint**

Run: `bin/rails test`, then `bundle exec standardrb`, then `CI=1 bin/rails zeitwerk:check`.
Expected: all green, with no new warning lines.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/sites/books.rb config/mcp/books/ test/lib/mcp/sites/books_test.rb test/controllers/api/mcp_admin_controller_test.rb
git commit -m "MCP: the admin usage prompt and instructions for books"
```

---

### Task 6: Acceptance against the dev server (controller-run, not a subagent)

The spec's increment-2 "Done when": a `books:admin:read` token lists no write or merge tools; a `books:admin:merge` token can dry-run and run a category merge from Claude Code; and the audit log line appears. The run uses two throwaway categories it creates, so no real category is merged.

- [ ] **Step 1:** Run `yarn build:all`, then check port 3000 is free or this worktree's (the AGENTS.md check). If another checkout holds it, stop and tell Shane. Start `bin/rails server` in the background.
- [ ] **Step 2:** Mint two one-day tokens for user 1141 (Shane's dev account, which is eligible for every admin scope): one `books:admin:read`, one `books:admin:merge`. Write the secrets only to scratchpad files with mode 600.
- [ ] **Step 3:** With the read token, use `curl` to send `tools/list` to `https://dev-new.thegreatestbooks.org/api/mcp/admin`. It must list exactly the four read tools.
- [ ] **Step 4:** With the merge token, run `claude -p --strict-mcp-config --mcp-config <scratch file> --allowedTools mcp__greatest-books-admin` from a script file, with the prompt on stdin. The prompt asks it to:
  1. create two `genre` categories named "MCP Acceptance A" and "MCP Acceptance B";
  2. dry-run merging B into A and report the dry-run result;
  3. merge for real;
  4. dry-run deleting A, then delete it.

  Because `-p` cannot ask the user, the prompt itself states that the user approves running each step after its dry run.
- [ ] **Step 5:** Check three things:
  - the answer reports each dry run before the matching real call;
  - `server.log` has `event=api_mcp` lines plus the `event=api_admin_category_merge outcome=succeeded` and `event=api_admin_category_delete` audit lines, all with `user_id=1141`;
  - both throwaway categories end as soft-deleted, with no live rows left behind.
- [ ] **Step 6:** Revoke both tokens (destroy the two rows created in step 2), delete the scratch secret files, and stop the server.
