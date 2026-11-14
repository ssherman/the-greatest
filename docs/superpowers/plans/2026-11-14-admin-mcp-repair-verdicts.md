# Admin MCP Repair Verdicts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let an admin agent work the repair-verdict queue (list, get, approve, reject, correct, bulk approve) over REST and MCP, with a Copy prompt on the page.

**Architecture:**
- The page's approve, reject and bulk-approve logic, and its filter, move into `Services::Books::RepairVerdicts::{Review,Filter}`.
- A new `Api::V1::Admin::Books::RepairVerdictsController` calls them, and `CorrectMatch` from #501.
- The endpoints are documented with `x-mcp` blocks in `config/api/v1/admin_openapi.yaml`.
- A `reviewed_via` column records `admin_ui` or `api`.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, Alba, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-14-admin-mcp-repair-verdicts-design.md`

## Global Constraints

- **Running things:**
  - Run commands from `web-app/`.
  - Never run brakeman.
  - Lint with `bundle exec standardrb`.
  - Never run two test suites at once in one worktree.
  - `bin/rails db:migrate` runs annotaterb. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. If the annotation diff shows columns this branch's `schema.rb` lacks, delete only those lines.
  - Use generators for the migration.
- **Tests:**
  - Controller tests assert behaviour only: status, JSON, DB state. They may assert API problem `detail` substrings, and never assert HTML or copy.
  - Use `assert_nil` (Minitest 6).
  - Root-anchor `::Books::` inside `Api::V1::Admin::Books` and `Services::Books`.
- **Raw endpoints:** refuse only bad data or missing permission.
- **Patterns to copy:**
  - `app/controllers/api/v1/admin/books/match_decisions_controller.rb`: `require_scopes`, `StrictIds`, `enum_param!`, `render_page`, `render_problem`.
  - `app/lib/services/match_decisions/filter.rb`.
  - `Services::AgentPrompts` and `config/mcp/books/prompts/match_decisions.md.erb`, with the Copy prompt markup in `app/views/admin/match_decisions_base/index.html.erb` and `e2e/tests/books/admin/match-decisions-copy-prompt.spec.ts`.
- **Scopes:**
  - list and get: `books:admin:read`
  - reject and correct: `books:admin:write`
  - approve and bulk approve: `books:admin:merge`
- **`reviewed_via`:** enum `{admin_ui: 0, api: 1}`, nullable. It is set by every review path, from `Current.acting_via` in the API and `"admin_ui"` on the page.
- **Admin tool-count pins** (40 → 46): `test/lib/mcp/admin_catalog_test.rb`, `test/lib/mcp/tool_directory_test.rb`, `test/controllers/api/mcp_admin_controller_test.rb`, the path-order list in `test/controllers/api/v1/admin/openapi_controller_test.rb`, and `test/integration/api/v1/admin_contract_coverage_test.rb`.

## Rulings (Claude's calls)

- **Superseded verdicts:** API approve and reject refuse them with a 422, and bulk approve skips them. The page itself is unchanged.
- **Bulk approve's `ids`:** 1–100 integers, otherwise 400. The response is `{approved_ids: [...], skipped_ids: [...]}`.
- **`source_rows`** in `get` is capped at 20, with `source_row_count` giving the full number. Each row is `{import_id, row_number, title, author, isbn13, goodreads_book_id}`, from the row's own columns.
- **Correct** passes `reviewed_via` through a new `via:` keyword on `CorrectMatch.call`, default `"admin_ui"`. Its refusals are 422 with the message as the problem `detail`.

## Review Focus

1. **Approve on a non-proposed verdict:** 422, nothing changed.
2. **Reject on an applied `mark_provisional`:** the book's provisional flag is reverted and `applied_at` is cleared, exactly as the page did. A page test pins this before the move.
3. **Correct on an applied or superseded match:** 422 with CorrectMatch's message. Correct with both `book_id` and `create`, or with neither, is 422.
4. **Bulk approve with a mix of ids** (proposed, already approved, superseded, nonexistent): only the proposed and current ones are approved, and the rest are listed as skipped.
5. **The list default is `status=proposed`,** and superseded verdicts never appear.

---

### Task 1: Shared Review and Filter services, `reviewed_via`; the page uses them

**Files:**
- **Generate:** a migration adding `reviewed_via:integer` to `books_repair_verdicts`.
- **Create:**
  - `app/lib/services/books/repair_verdicts/review.rb`
  - `app/lib/services/books/repair_verdicts/filter.rb`
- **Modify:**
  - `app/models/books/repair_verdict.rb` (`enum :reviewed_via, {admin_ui: 0, api: 1}, prefix: true`)
  - `app/controllers/admin/books/repair_verdicts_controller.rb` (approve, reject, bulk_approve and filtered_scope call the services; the page passes `via: "admin_ui"`)
  - `app/lib/services/books/goodreads_reimport/correct_match.rb` (`via:` keyword, which sets `reviewed_via`)
- **Test:**
  - `test/lib/services/books/repair_verdicts/review_test.rb`
  - `test/lib/services/books/repair_verdicts/filter_test.rb`
  - the existing `test/controllers/admin/books/repair_verdicts_controller_test.rb` and `correct_match_test.rb` stay green

**Interfaces (produces):**
- `Services::Books::RepairVerdicts::Review.approve(verdict:, user:, via:) → Result` fails with `data[:code] = :not_proposed` unless the verdict is proposed.
- `.reject(verdict:, user:, via:) → Result` fails with `:already_rejected`. For an applied `mark_provisional` it runs `MarkProvisional.revert`, the ranking refresh and `applied_at: nil`, as the page does now. `data[:reverted]` is true when it reverted something, and `data[:applied]` is true when the verdict had already been applied.
- `.bulk_approve(ids:, user:, via:) → Result` with `data: {approved_ids:, skipped_ids:}`. It approves only proposed and current verdicts.
- Every success sets `status`, `decided_by_user_id`, `reviewed_at` and `reviewed_via`.
- `Services::Books::RepairVerdicts::Filter.call(scope = ::Books::RepairVerdict.current, kind:, decided_by:, confidence:, guess:) → Relation` is the page's `filtered_scope`, with invalid values ignored. Status is applied by the callers.
- The constants `KINDS`, `STATUSES`, `DECIDED_BY` and `CONFIDENCES` live on Filter.
- The page keeps its "approve all matching" path through `Filter` plus `bulk_approve` over those ids. Its behaviour is unchanged; batch the ids if the count is large.

- [ ] **Write the failing tests:**
  - Review approve, reject, bulk_approve, each with the via and user stamped
  - Focus 1
  - Focus 2: the reject revert, with a page test pinned before moving the code
  - Focus 4, at service level
  - the Filter cases
  - `CorrectMatch` with `via: "api"` sets `reviewed_via`
- [ ] **Implement:** run the migration, check the annotation, switch the page.
- [ ] **Run** the new tests, `test/controllers/admin/books/repair_verdicts_controller_test.rb` and `test/lib/services/books/goodreads_reimport`: they PASS. Then commit.

### Task 2: Read endpoints

**Files:**
- **Create:**
  - `app/controllers/api/v1/admin/books/repair_verdicts_controller.rb`
  - `app/lib/api/v1/admin/books/repair_verdict_resource.rb` (the list row)
  - `app/lib/api/v1/admin/books/repair_verdict_detail_resource.rb`
- **Modify:** `config/routes.rb`, `config/api/v1/admin_openapi.yaml`, and the pins (40 → 42).
- **Test:** `test/controllers/api/v1/admin/books/repair_verdicts_controller_test.rb` and contract coverage.

**Interfaces:**
- **List:** `GET /api/v1/admin/repair_verdicts` → `list_repair_verdicts`.
  - Filters: `kind`, `status` (default `proposed`), `decided_by`, `confidence`, `guess` (`true` only).
  - An unknown enum value is 400, through `enum_param!`.
  - Newest first, paginated.
  - Row keys: `id, kind, status, decided_by, confidence, summary, reason, guess, reviewed_at, applied_at, created_at`.
- **Get:** `GET /api/v1/admin/repair_verdicts/{id}` → `get_repair_verdict`.
  - Row keys, plus `payload, ai_chat_id, reviewed_by ({id, name} | null), reviewed_via, superseded_at, books, authors, candidate_books, match_decision ({id, outcome} | null), source_rows, source_row_count`.
  - A book is `{id, slug, title, first_published_year, authors: [AuthorSummaryResource]}`.
  - Load everything without N+1.

- [ ] **Write the failing tests:**
  - the list default, filters, superseded excluded (Focus 5)
  - get with candidates for a `reimport_match` fixture or a created record, and get of a `merge_books` verdict
  - 404, 403 for the member scope, 400 for a bad enum
- [ ] **Implement:** the endpoints, the OpenAPI entries with `x-mcp`, and the pins 40 → 42.
- [ ] **Run** the new tests, `test/lib/mcp`, `test/controllers/api` and `test/integration/api`: they PASS. Then commit.

### Task 3: Write endpoints

**Files:**
- **Modify:**
  - the Task 2 controller
  - `config/routes.rb` (put `bulk_approve` before `/{id}` routes, or constrain the id)
  - `config/api/v1/admin_openapi.yaml`
  - the pins (42 → 46)
  - `config/mcp/books/admin_usage.md` (the exemption line)
- **Test:** the Task 2 controller test, contract coverage, and an MCP-level test in `test/controllers/api/mcp_admin_controller_test.rb` for `correct_repair_verdict` with `create: true`.

**Interfaces:**
- **Approve:** `POST .../{id}/approve` → `approve_repair_verdict` (merge scope).
- **Reject:** `POST .../{id}/reject` → `reject_repair_verdict` (write scope). Its description says that rejecting a `reimport_match` strands its readers, and to use `correct_repair_verdict`.
- **Correct:** `POST .../{id}/correct` → `correct_repair_verdict` (write scope). The body is `{book_id}` or `{create: true}`.
- **Bulk approve:** `POST /api/v1/admin/repair_verdicts/bulk_approve` → `bulk_approve_repair_verdicts` (merge scope). The body is `{ids: [...]}`.
- **Responses:** approve, reject and correct return the Task 2 detail shape. Bulk approve returns `{approved_ids, skipped_ids}`.
- **Status codes:** refusals are 422, a superseded verdict is 422 on approve and reject, and a missing verdict is 404.

- [ ] **Write the failing tests:**
  - Focus 1, 3 and 4 at the API
  - a reject of an applied `mark_provisional` (Focus 2) returns 200, with the book no longer provisional
  - `reviewed_via == "api"` on every write
  - the scope 403s
  - `ids` of 0 or 101 elements, or non-integers: 400
  - the MCP-level correct test
- [ ] **Implement:** the endpoints, the OpenAPI entries with `x-mcp`, the pins 42 → 46, and the `admin_usage.md` exemption.
- [ ] **Run** the new tests, `test/lib/mcp`, `test/controllers/api` and `test/integration/api`: they PASS. Then commit.

### Task 4: Copy prompt, docs, full suite

**Files:**
- **Create:** `config/mcp/books/prompts/repair_verdicts.md.erb`.
- **Modify:**
  - `app/lib/services/agent_prompts.rb` (the `repair_verdicts` queue and its counts)
  - `app/controllers/admin/books/repair_verdicts_controller.rb` (`@agent_prompt` on the index)
  - `app/views/admin/books/repair_verdicts/index.html.erb` (the button, copying the match-decisions markup)
  - `docs/features/mcp-server.md`
  - `docs/features/goodreads-reimport.md` (a line on the tools)
- **Test:**
  - `test/lib/services/agent_prompts_test.rb` (or wherever its tests live)
  - the page controller test (index assigns the prompt; behaviour only)
  - `e2e/tests/books/admin/repair-verdicts-copy-prompt.spec.ts`, modelled on `match-decisions-copy-prompt.spec.ts`

**Interfaces:**
- **Template variables:** `mcp_url`, `pending_high`, `pending_medium` and `pending_low` (current, proposed `reimport_match` by confidence).
- **Template content:**
  - Work through `list_repair_verdicts` with `kind=reimport_match`.
  - For each verdict, read `get_repair_verdict` and compare the CSV `facts` with each candidate book, using web search when unsure.
  - If the AI's answer is right, approve. If it is wrong, correct it to the right book id, or to `create: true` when none of the books is the work.
  - Never reject a `reimport_match`.
  - Use bulk approve only for verdicts you have each read.
  - Nothing applies until the apply task runs.

- [ ] **Write the failing tests:** the AgentPrompts render with the counts, the page assigns the prompt, and the E2E.
- [ ] **Implement.**
- [ ] **Run the E2E:** check that port 3000 belongs to this worktree first (AGENTS.md); if another checkout holds it, report back instead of running. Then run the full `bin/rails test` alone, and `bundle exec standardrb`. All must be clean. Commit.
