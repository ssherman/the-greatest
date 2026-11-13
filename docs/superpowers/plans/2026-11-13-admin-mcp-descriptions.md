# Admin MCP Descriptions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let an admin agent read and fix book and author descriptions over MCP, with the same five actions the admin description panel has: list, add, edit, delete, set preferred.

**Why (Shane, 2026-11-13):** an agent dismissing a duplicate found book 120812 ("How To Win Friends, Influence People" by sparrowette, a 2012 Naruto fanfic) carrying an AI-generated summary of Carnegie's 1936 book, and could not fix it. Kept deliberately small: descriptions only. Book/author field edits (e.g. that book's wrong 1936 year) are the next, separate piece.

**Architecture:** Same shape as #481/#484. A new controller `Api::V1::Admin::Books::DescriptionsController` documented in `config/api/v1/admin_openapi.yaml` with `x-mcp` blocks, so `Mcp::Catalog` generates the tools. The write logic in `Admin::DescriptionsController` (create defaults, update, destroy, set_preferred) moves into one service both controllers call, so the page and the API cannot drift.

**Spec:** none (small change approved in chat, 2026-11-13). This plan is the description; rulings below are Claude's calls.

## Global Constraints

- Run commands from `web-app/`. Never run brakeman. Lint `bundle exec standardrb`. Never run two test suites at once in one worktree.
- Controller tests assert behaviour only (status, JSON, DB state); API problem `detail` substrings may be asserted.
- Minitest 6: `assert_nil`.
- Raw admin endpoints: refuse only bad data or missing permission. No server text tells the agent to ask the user first; `admin_usage.md` gets one line adding the description tools to the "Match decisions and identifiers" exemption.
- Books domain only: describables `Books::Book` and `Books::Author`.
- Parity with the admin page: new descriptions are `kind: summary`, `locale: en`, `rank: normal`. Writable fields: `content`, `source`, `source_name`, `source_url`, `license`. `source_name` only when `source` is `other` (the model validates this).
- Patterns: `app/controllers/api/v1/admin/books/identifiers_controller.rb` (book/author paired routes, `require_scopes`, policy checks, `render_problem`), its resource and tests; pins at 29 admin tools in `test/lib/mcp/admin_catalog_test.rb`, `test/lib/mcp/tool_directory_test.rb`, `test/controllers/api/mcp_admin_controller_test.rb`, `test/controllers/api/v1/admin/openapi_controller_test.rb`, `test/integration/api/v1/admin_contract_coverage_test.rb`.

## Rulings (Claude's calls)

- The agent chooses `source` (required). The tool descriptions say: text the agent writes itself → `ai_generated`; text copied from a source → that source plus `source_url`.
- `source: wikipedia` requires `source_url` (400 otherwise) and defaults `license` to `cc_by_sa_4` when omitted (Wikipedia text is CC BY-SA). Applies to the API only; the admin page is unchanged.
- One description per (describable, kind, locale, source, source_name): adding a second with the same source is a 422 naming the existing description id ("edit it instead") — this is the model's uniqueness rule surfaced, not a new rule.
- Delete and set-preferred work on any description of a book/author. Set-preferred keeps the existing transaction (clear other preferred of the same kind/locale, then mark this one).
- Content length: reuse `Correction::MAX_TEXT_VALUE_LENGTH` (100,000) as the cap; 400 above it.
- Cache: do exactly what the admin page's writes do today. If they trigger no cache refresh of the public book/author page, note that in the report and do not add one here.

## Review Focus

1. Set preferred on a description when another is already preferred: exactly one preferred afterwards, and `shown_description_id` on the list response points at it.
2. A description id that belongs to a music/games record or does not exist → 404 (descriptions are polymorphic; the API must not touch other domains).
3. Adding a second description with the same source → 422 with the existing id, nothing created.
4. Deleting the shown description: the list's `shown_description_id` falls back per `Descriptions::Resolver` (preferred, else source priority).
5. A deprecated description is listed but never shown.

---

### Task 1: Shared description service + read endpoints

**Files:**
- Create: `app/lib/services/descriptions/admin_write.rb`, `app/controllers/api/v1/admin/books/descriptions_controller.rb`, `app/lib/api/v1/admin/books/description_resource.rb`
- Modify: `app/controllers/admin/descriptions_controller.rb` (call the service for create/update/destroy/set_preferred; behaviour unchanged), `config/routes.rb`, `config/api/v1/admin_openapi.yaml`, pins
- Test: `test/lib/services/descriptions/admin_write_test.rb`, `test/controllers/api/v1/admin/books/descriptions_controller_test.rb`; existing `test/controllers/admin/descriptions_controller_test.rb` stays green

**Interfaces:**
- `Services::Descriptions::AdminWrite.create(describable:, attrs:) → Result` (sets summary/en/normal), `.update(description:, attrs:) → Result`, `.destroy(description:) → Result`, `.set_preferred(description:) → Result`. Result per AGENTS.md; `errors` from validations; `data[:code]` `:invalid` or `:conflict` (uniqueness).
- Reads: `GET /api/v1/admin/books/{id}/descriptions` → `get_book_descriptions`, `GET /api/v1/admin/authors/{id}/descriptions` → `get_author_descriptions` (scope `books:admin:read`). Response `{data: [rows], shown_description_id: id|null}`; rows ordered rank desc then source as the page does; row `{id, kind, locale, rank, source, source_name, source_url, license, content, retrieved_at, created_at, updated_at}`. `shown_description_id` = `book.primary_description(kind: :summary)&.id`.

- [ ] Failing tests: service create/update/destroy/set_preferred incl. one-preferred invariant (Review Focus 1) and uniqueness conflict; list for book and author with `shown_description_id` (incl. deprecated never shown — Review Focus 5); 404 unknown book/author; read scope OK; non-admin 403.
- [ ] Implement service; switch the admin controller to it (its tests green unchanged); endpoints + OpenAPI + x-mcp; pins 29 → 31.
- [ ] Run the new tests, `test/controllers/admin/descriptions_controller_test.rb`, `test/lib/mcp`, `test/controllers/api` — PASS. Commit.

### Task 2: Write endpoints, docs

**Files:**
- Modify: the Task 1 controller, routes, OpenAPI, pins, `config/mcp/books/admin_usage.md`, `docs/features/mcp-server.md` (and the descriptions feature doc if one exists under docs/features)
- Test: the Task 1 controller test, contract coverage

**Interfaces:**
- `POST /api/v1/admin/books/{id}/descriptions`, `POST /api/v1/admin/authors/{id}/descriptions` → `add_book_description` / `add_author_description` (scope `books:admin:write`, policy `update?`). Body `{content, source, source_name?, source_url?, license?}` → 201 `{data: row, shown_description_id}`.
- `PATCH /api/v1/admin/descriptions/{id}` → `update_description` (write, `update?` on its describable): any subset of the writable fields → 200 row.
- `POST /api/v1/admin/descriptions/{id}/prefer` → `set_preferred_description` (write, `update?`) → 200 `{data: row, shown_description_id}`.
- `DELETE /api/v1/admin/descriptions/{id}` → `delete_description` (scope `books:admin:merge`, policy `destroy?`, destructive) → 200 `{data: <deleted row>, shown_description_id}`.
- Description lookup for update/prefer/delete: 404 unless the description's describable is a `Books::Book` or `Books::Author` (Review Focus 2).

- [ ] Failing tests: add (201; bad source 400; `other` without source_name 400; wikipedia without source_url 400; wikipedia license default; same-source second add 422 with existing id — Review Focus 3; content over the cap 400); update (partial; validation 400); prefer (one preferred, shown id moves); delete (row gone; shown id falls back — Review Focus 4); music/games or missing description → 404; scopes (write vs merge); policy refusals 403 with no change.
- [ ] Implement via the Task 1 service; OpenAPI + x-mcp (tool text: what is shown on the site and why — preferred, else source priority manual > ai_generated > goodreads > wikipedia > openlibrary > publisher > other; agent-written text → `ai_generated`; delete is permanent); pins 31 → 36, destructive set gains `deleteDescription`; contract coverage for every status.
- [ ] `admin_usage.md`: add the description tools to the "Match decisions and identifiers" exemption sentence (one line). Docs: tools + rulings.
- [ ] Full `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check` — green. Commit.
