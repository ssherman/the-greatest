# MCP Server Increment 3 (Docs) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A member can connect an MCP client to The Greatest Books from the docs alone. `/developers` on the books host gets an MCP section with the URL, the Claude Code command, and the tool list rendered from the catalogue. `docs/features/mcp-server.md` documents the feature, and `docs/features/public-api.md` links to it.

**Architecture:** The section is a new part of `/developers`, which is edge-cached and identical for every visitor. A small generic `Mcp::ToolDirectory` lists every tool an endpoint can offer, catalogue tools plus the site's composites, without a principal. The page renders that list for the `:public` document only. The admin endpoint is never mentioned on `/developers`, because the public page never mentions an admin path (the OpenAPI document rule). It is documented only in `docs/features/mcp-server.md`.

**Tech Stack:** Rails 8 views (ERB, Tailwind 4 + daisyUI 5 `prose`), Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-mcp-server-design.md`. This is the increment table's row 3 and the "Left to the builder" line on how the `/developers` tool list is rendered. Increments 1 (PR #447) and 2 (PR #449) are merged.

## Global Constraints

- `/developers` stays identical for every visitor. It must never read `current_user`; the existing signed-in/signed-out test covers the new section.
- The public page never mentions `/api/mcp/admin` or any admin tool. Increment row 3 says admin tools are listed only for the admin document, never the public one, and there is no admin docs page.
- The section renders only on a host whose public MCP catalogue has tools: books today. On music and games, where `/api/mcp` is not routed, there is no MCP section.
- The MCP URL is `"#{Api::Host.base_url}/api/mcp"`, built from config, never from `request.host` (the `Api::Host` rule).
- The Claude Code command, with the host interpolated from `Api::Host.base_url`, is exactly:
  `claude mcp add --transport http --scope user the-greatest-books https://<host>/api/mcp --header "Authorization: Bearer $THE_GREATEST_TOKEN"`
  This is the verified syntax: `--header` is variadic, so it comes after the URL. The variable is the one the page's quick start already uses.
- Every claim on the page and in the docs must be true of the merged code: `app/controllers/api/mcp_controller.rb`, `app/lib/mcp/`, and `config/mcp/books/`.
- Never put Cloudflare zone details (rule names, limits, challenged ranges or paths) in the new docs. Say "the edge" and "the rules live in the private repo".
- DaisyUI 5 classes only (`AGENTS.md`; `test/lint/daisyui_v4_classes_test.rb`). Run `bundle exec standardrb`. Run all commands from `web-app/`.

## Review Focus

1. **The music or games host.** `/developers` there must render no MCP section and no link to a URL that 404s on that host. Test in Task 2.
2. **The admin endpoint leaking onto the public page.** No `/api/mcp/admin` and no admin tool name (`merge_categories`, `search_admin_books`) may appear in `/developers`, even though the admin catalogue now has tools. Test in Task 2.
3. **Copying the command.** The page shows the command in a `<pre><code>` block, and the URL is the real host, not a placeholder. Test in Task 2, and in the E2E in Task 4.
4. **A model-facing description containing HTML-like text.** Tool descriptions come from YAML and contain backticks and `<`. They must render as escaped text, never as markup. Test in Task 2.
5. **The existing copy's claim "A token cannot sign in to the site and cannot write anything".** It is false now that admin tokens exist (admin scopes write and merge). A reader connecting an admin token from the docs must not be told it is read-only. Fix and test in Task 2.

---

### Task 1: `Mcp::ToolDirectory`

**Files:**
- Create: `web-app/app/lib/mcp/tool_directory.rb`
- Test: `web-app/test/lib/mcp/tool_directory_test.rb`

**Interfaces:**
- Consumes: `Mcp::Catalog.for(document:, domain:)`, `#operations` (each an `Mcp::Operation` with `tool_name`, `title`, `description` and `destructive`), `Mcp::Sites.for(domain).composites(document)`, and each composite's `tool_name`, `title`, `description` and `annotations(catalog)`.
- Produces:
  - `Mcp::ToolDirectory::Entry = Struct.new(:name, :title, :description, :destructive, keyword_init: true)`
  - `Mcp::ToolDirectory.entries(document:, domain:) -> Array<Entry>`. It returns every tool the endpoint can offer, catalogue tools first in catalogue order and then the site's composites, whatever any principal's scopes. It is generic and never mentions books. A composite's `destructive` is its derived `destructiveHint`.

- [ ] **Step 1: Write the failing tests**

`tool_directory_test.rb`:
- `test "the public books directory is every catalogue tool plus find_book"`. The names equal `Mcp::Catalog.for(document: :public, domain: :books).operations.map(&:tool_name) + ["find_book"]`, and the size is 18.
- `test "the admin books directory is the 14 admin tools, six destructive"`.
- `test "a host with no API operations has an empty directory"`. `entries(document: :public, domain: :music)` is `[]`.
- `test "each entry carries the tool's own title and description"`. The `get_book` entry's description equals `catalog.fetch("getBook").description`.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/lib/mcp/tool_directory_test.rb`
Expected: FAIL with `NameError`.

- [ ] **Step 3: Implement it**

The header comment says it exists for documentation pages, which have no principal, and that it is not a listing for a request (that is `ServerFactory`, filtered by scope).

- [ ] **Step 4: Run them and watch them pass**

Run: `bin/rails test test/lib/mcp/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/mcp/tool_directory.rb test/lib/mcp/tool_directory_test.rb
git commit -m "MCP: a principal-free directory of an endpoint's tools, for docs"
```

---

### Task 2: The MCP section on `/developers`

**Files:**
- Modify: `web-app/app/controllers/developers_controller.rb` (`show`)
- Modify: `web-app/app/views/developers/show.html.erb`
- Test: `web-app/test/controllers/developers_controller_test.rb`

**Interfaces:**
- Consumes: `Mcp::ToolDirectory.entries(document: :public, domain: Current.domain)` (Task 1).
- Produces:
  - `@mcp_tools` (`Array<Mcp::ToolDirectory::Entry>`) and `@mcp_url` (`String`).
  - Anchors: `<h2 id="mcp">` and one `id="mcp-tool-<name>"` element per tool.
  - The command block is `<pre id="mcp-command"><code>…</code></pre>`.

  Task 4's E2E uses these anchors.

**Section content.** It goes between "Endpoints on this site" and "Pagination". The heading is "Use it from an AI assistant (MCP)". Every line must be true of the merged code:
- **The URL** (`@mcp_url`), and that it is an MCP server for AI assistants such as Claude Code. Each tool is one of the endpoints above, answered with the same data and the same errors.
- **Access:** it uses the same membership token as the REST API, which needs the `books:read` scope.
- **Rate limits:** each MCP request counts once against the same limits as REST. One tool call is one request, including `find_book`.
- **The Claude Code command**, in `#mcp-command`, exactly as in Global Constraints.
- **Other clients:** Streamable HTTP and stateless, so there is no session to keep. Send `POST` with `Authorization: Bearer <token>`, `Content-Type: application/json` and `Accept: application/json, text/event-stream`.
- **Prompts and resources:** the server also offers a `usage` prompt and a `ranking-methodology` resource, and sends short instructions on connect.
- **The tool list:** for each entry, `<div id="mcp-tool-<name>">` with `<code>name</code>`, the title, and the description as escaped text. The destructive badge is not shown, since no public tool is destructive.

**Copy fix (Review Focus 5).** In "Authentication", replace "A token cannot sign in to the site and cannot write anything." with "A member's token only reads: it cannot sign in to the site or change anything." Do not mention admin scopes or tokens on this page.

- [ ] **Step 1: Write the failing tests**

Add to `developers_controller_test.rb`:
- `test "the books page documents the MCP server"`:
  - `assert_select "h2#mcp"`;
  - `assert_select "pre#mcp-command code", text: /claude mcp add --transport http --scope user the-greatest-books https:\/\/dev-new\.thegreatestbooks\.org\/api\/mcp --header "Authorization: Bearer \$THE_GREATEST_TOKEN"/`;
  - one `#mcp-tool-<name>` for each of the 18 public entries.
- `test "the MCP tool list is the catalogue, so it cannot drift"`: the set of `[id^=mcp-tool-]` ids equals the directory names.
- `test "music and games have no MCP section"`: for `:music` and `:games`, `assert_select "#mcp", 0` and the body does not include `/api/mcp`.
- `test "the public page never mentions the admin endpoint or an admin tool"`: on books, `refute_includes response.body, "/api/mcp/admin"`, and each of the 14 admin directory names is absent from the body.
- `test "tool descriptions render as text, not markup"`:
  1. Stub `Mcp::ToolDirectory.entries` to return one entry whose description is `"<b>bold</b> & \`code\`"`.
  2. `assert_includes response.body, "&lt;b&gt;bold&lt;/b&gt;"`.
  3. `assert_select "#mcp-tool-x b", 0`.
- `test "the authentication copy no longer says every token is read-only"`: `refute_includes response.body, "cannot write anything"`, and `assert_includes response.body, "A member&#39;s token only reads"`. Use whatever escaping ERB produces, e.g. `assert_match(/A member.s token only reads/, response.body)`.
- The existing "identical signed out and signed in" test must still pass. It now covers the new section.

- [ ] **Step 2: Run them and watch them fail**

Run: `bin/rails test test/controllers/developers_controller_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement the controller assigns and the section**

Follow the page's existing markup:
- `prose` text;
- a `not-prose` `<dl>` for the list, like the endpoints list;
- `<pre><code>` for code.

Add `mcp` to the comment's anchor list at the top of the view.

- [ ] **Step 4: Run the developers tests, the lint and the daisyUI guard**

Run: `bin/rails test test/controllers/developers_controller_test.rb test/lint/`, then `bundle exec standardrb`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/developers_controller.rb app/views/developers/show.html.erb test/controllers/developers_controller_test.rb
git commit -m "Developers page: how to connect an MCP client, and the tools it gets"
```

---

### Task 3: `docs/features/mcp-server.md`, and a cross-link from `public-api.md`

**Files:**
- Create: `docs/features/mcp-server.md` (project root `docs/`, not `web-app/docs/`)
- Modify: `docs/features/public-api.md`: a one-line pointer near the top, and the "Not yet" line, which still says "OAuth/MCP"

**Interfaces:**
- Consumes: the merged code and the three specs (`2026-11-02-mcp-server-design.md`, `2026-11-02-mcp-oauth-design.md`, `2026-11-02-public-api-web-parity-design.md`).
- Produces: documentation only. Follow `docs/documentation.md`'s rule: a feature doc, not per-class docs, and code is the source of truth.

**`mcp-server.md` sections**, each true of the code. Read the files named.

1. **What it is.** `POST /api/mcp` (members, `<domain>:read`) and `POST /api/mcp/admin` (`<domain>:admin:read`, scope-filtered admin tools), books host only. Link the spec.
2. **How a request flows.**
   - The `Api::McpController` before_action chain;
   - one stateless `MCP::Server` per request;
   - `Mcp::ServerFactory`;
   - the transport options;
   - why GET and DELETE are 405;
   - why the transport's `token_verifier` is unused.
3. **Tools.**
   - Generated from `x-mcp` (`Mcp::Catalog`): the allowed keys and their validation, the input-schema flattening, the `per_page` to `limit` rename, and the hints table (`Mcp::Operation#annotations`).
   - The scope filter.
   - Composites (`Mcp::Composite`, `find_book`).
   - `Mcp::Sites` for per-site prompts, resources and instructions.
   - `Mcp::ToolDirectory` for docs.
4. **Dispatch.** `Mcp::Dispatcher`:
   - the env it builds;
   - percent-encoding;
   - nil handling (path and query omitted, body sent as `null`);
   - unknown and blank arguments;
   - the `the_greatest.api.*` env keys and why they cannot be forged;
   - one auth, one `record_use` and one rate-limit hit per MCP request;
   - result mapping (`Mcp::ToolResult`).
5. **Adding a tool.** Add an `x-mcp` block to the operation, with `description` written for a model. Add `destructive: true` on merges and deletes. The scope comes from the operation's `security`. Name the tests that will catch mistakes: the catalogue tests and the scope contract test.
6. **Clients.**
   - The Claude Code command for both endpoints. The admin one uses an expiring admin token.
   - The 2026-07-28 lifecycle Claude Code uses (`server/discover`, `Mcp-Method`, `_meta`), and that `Accept` must include both types.
   - The gem version, and to re-read `handle_modern` before a `bundle update mcp`.
7. **Admin safety.** The dry-run protocol; untag is not an undo; protected categories; the books admin prompt and instructions (`config/mcp/books/`); the audit lines.
8. **Logging.** `event=api_mcp document=… rpc_method=… tool=… user_id=…`, with values sanitised and the token never logged.
9. **Edge.** Under `/api/` for the edge's existing API treatment. The rules live in the private `the-greatest-cloudflare` repo. No details.
10. **Testing.** Name the test files, and the acceptance runs recorded in PRs #447 and #449.
11. **Not yet.**
    - OAuth sign-in for the Claude apps (its spec);
    - music and games tools;
    - the REST follow-ups (lenient `dry_run` in book and author merges; the protected categories can still be renamed or re-parented through the API).

**`public-api.md`:**
- Near the top: "MCP: `docs/features/mcp-server.md` — every operation with an `x-mcp` block is also an MCP tool."
- In "Not yet": drop "MCP" (keep "OAuth", linking the OAuth spec).

- [ ] **Step 1: Write the docs**

- [ ] **Step 2: Check the claims**

Grep the docs for every class, path, env key and log field they name. Each must exist in `web-app/` at HEAD. Then confirm no Cloudflare zone details are in the new doc: `grep -inE "rate limit of|challenge|ruleset|requests per" docs/features/mcp-server.md` should match nothing beyond the generic edge sentence.

- [ ] **Step 3: Commit**

```bash
git add docs/features/mcp-server.md docs/features/public-api.md
git commit -m "Docs: the MCP server"
```

---

### Task 4: Playwright E2E and the gate (controller-run)

The dev server and port 3000 are shared, so the controller runs this task, not a subagent. Writing the spec file can be delegated with Task 2's context, but running it is the controller's job.

**Files:**
- Modify: `web-app/e2e/tests/books/developers.spec.ts`

- [ ] **Step 1: Add tests to the signed-out describe block**
  - `'the documentation page explains how to connect an MCP client'`:
    - go to `/developers`;
    - expect the heading `/MCP/` (level 2) to be visible;
    - expect `#mcp-command` to contain `claude mcp add --transport http --scope user the-greatest-books https://dev-new.thegreatestbooks.org/api/mcp`;
    - expect `#mcp-tool-find_book` and `#mcp-tool-search_books` to be visible.
  - `'the MCP endpoint refuses a request without a token'`: `page.request.post('/api/mcp', {data: {jsonrpc: '2.0', id: 1, method: 'tools/list'}, headers: {Accept: 'application/json, text/event-stream'}})` returns 401 with `www-authenticate` `Bearer`.
- [ ] **Step 2: Run `yarn build:all`.** Check port 3000 belongs to this worktree or is free (the AGENTS.md check), and stop if another checkout holds it. Start `bin/rails server` and run `yarn test:e2e e2e/tests/books/developers.spec.ts`. Expected: all pass.
- [ ] **Step 3: Run the gate.** Run `bin/rails test` (whole suite), `bundle exec standardrb` and `CI=1 bin/rails zeitwerk:check`. All must be green, with no new warning lines.
- [ ] **Step 4: Commit the spec and stop the server**

```bash
git add e2e/tests/books/developers.spec.ts
git commit -m "E2E: the developers page's MCP section"
```
