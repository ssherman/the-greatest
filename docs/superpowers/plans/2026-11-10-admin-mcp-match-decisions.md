# Admin MCP Match Decisions + Identifiers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nine admin API endpoints + MCP tools — match decisions (list, get, review, reject link) and identifiers (book identifiers, author identifiers, find by identifier, add, remove) — plus who/how on reviews and a Copy prompt button on the match decisions page.

**Architecture:** Same shape as #481: controllers under `Api::V1::Admin::Books`, documented in `config/api/v1/admin_openapi.yaml` with `x-mcp` blocks so `Mcp::Catalog` generates the tools. Who/how via `Current.acting_user`/`acting_via` (already set by `Admin::BaseController` and `Api::V1::Admin::Books::BaseController`), read by `MatchDecision#review!`. Admin-sourced author Wikidata/VIAF ids become authoritative in the resolvers' held-id stage.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, `mcp` gem via `Mcp::Catalog`, Stimulus `clipboard_copy_controller`, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-10-admin-mcp-match-decisions-design.md`

## Global Constraints

- Run all commands from `web-app/`. Never run brakeman. Lint: `bundle exec standardrb`.
- Generators for migrations/controllers; `db:migrate` runs annotaterb — never set `ANNOTATERB_SKIP_ON_DB_TASKS`; on the shared dev DB delete only annotation lines for columns this branch's schema.rb lacks.
- Controller tests assert behaviour only (status, JSON values, DB state), never HTML/CSS/copy. API problem `detail` substrings are the agent-facing contract and may be asserted.
- Minitest 6: `assert_nil`. Never run two test suites in one worktree at once.
- Raw admin endpoints: refuse only bad data or missing permission; no server text tells the agent to ask the user first.
- Books domain only. Enum mapping methods: `DuplicateCandidate.resolved_via` style — "via" is uncountable, so `MatchDecision.reviewed_via` (no `reviewed_vias`).
- Patterns to copy: `app/controllers/api/v1/admin/books/duplicate_candidates_controller.rb`, `app/lib/api/v1/admin/books/duplicate_candidate_resource.rb`, `app/controllers/api/v1/admin/strict_ids.rb` (`parse_id`), `text_param!`/`enum_param!`/`render_page`/`render_problem` on `Api::V1::BaseController`, the duplicate-candidate tests (`test/controllers/api/v1/admin/books/duplicate_candidates_controller_test.rb`) for host/tokens/`assert_api_response_conform(status:, api: :admin)`.
- Admin tool pins today: 18 (after #481). They live in `test/lib/mcp/admin_catalog_test.rb`, `test/lib/mcp/tool_directory_test.rb`, `test/controllers/api/mcp_admin_controller_test.rb`, `test/controllers/api/v1/admin/openapi_controller_test.rb`, `test/integration/api/v1/admin_contract_coverage_test.rb` (EXERCISES).

## Review Focus

1. `review_match_decision` with `verdict: rejected` on a matched Wikidata/VIAF decision → 422 pointing at `reject_match_decision_link`, decision unchanged (Task 3 test).
2. A resolver re-run after an admin added a Wikidata QID whose label/years do not corroborate: the admin id is kept as the match and no second QID is stamped (Task 5 test).
3. `add_identifier` of an author Wikidata/VIAF value listed by `RejectedRecords` for that author → 422; of a different value when one is held → 422 (Task 5 tests).
4. `get_book_identifiers` on a book with more than one page of edition identifiers pages correctly, own rows first (Task 4 test).
5. Reject cascades: the sibling decisions the reject service marks are stamped `reviewed_via: api` and `reviewed_by` the token user (Task 3 test).

---

### Task 1: Who/how on reviews, admin source, queue filter

**Files:**
- Create: migration `AddReviewedViaToMatchDecisions` (`reviewed_via :integer`, nullable, no default)
- Modify: `app/models/match_decision.rb` (enum + `review!`), `app/models/identifier.rb` (source `admin: 8`), `app/controllers/admin/match_decisions_base_controller.rb` (`via` filter on reviewed), `app/views/admin/match_decisions_base/index.html.erb` (+ row "via …"), `show.html.erb` review line
- Test: `test/models/match_decision_test.rb`, `test/controllers/admin/books/match_decisions_controller_test.rb`

**Interfaces:**
- Produces: `enum :reviewed_via, {admin_ui: 0, api: 1}, prefix: :reviewed_via`; `MatchDecision#review!(by:, note: nil)` also sets `reviewed_via: Current.acting_via` (nil outside a request); `Identifier` source `admin` (value 8). Admin index accepts `via` ∈ `MatchDecision.reviewed_via.keys`, applied only when `reviewed` is `reviewed` or `all`.

- [ ] **Step 1: Failing tests** — model: `review!` inside `Current.set(acting_user:, acting_via: "api")` sets `reviewed_via_api?`; outside sets nil. Admin controller: page review stamps `reviewed_via_admin_ui?`; page reject (stub `RejectExternalLink`'s HTTP-free path or use an existing reject test setup) stamps `admin_ui`; `via=api` with `reviewed=reviewed` narrows the list (assert on row ids/data attributes, not copy). `Identifier.new(source: :admin)` valid.
- [ ] **Step 2:** Run; FAIL.
- [ ] **Step 3:** Migration via generator, `db:migrate`, `RAILS_ENV=test bin/rails db:test:prepare`; enum; `review!` change; identifier source; filter + "All / Admin page / API" `join` link group on reviewed views, mirroring `app/views/admin/duplicate_candidates_base/index.html.erb`.
- [ ] **Step 4:** Run `test/models/match_decision_test.rb test/controllers/admin` and `test/lib/services/books/authors` — PASS.
- [ ] **Step 5:** Commit.

### Task 2: Match decision read endpoints

**Files:**
- Create: `app/controllers/api/v1/admin/books/match_decisions_controller.rb`, `app/lib/api/v1/admin/books/match_decision_resource.rb`
- Modify: `config/routes.rb`, `config/api/v1/admin_openapi.yaml`, pin tests
- Test: `test/controllers/api/v1/admin/books/match_decisions_controller_test.rb`

**Interfaces:**
- Produces: `listMatchDecisions` → `list_match_decisions`, `getMatchDecision` → `get_match_decision` (scope `books:admin:read`). Controller helpers `domain_scope` (`MatchDecision.where(finder: FinderRegistry.for_domain(:books).map(&:finder))`), `find_decision` (404 detail `"No match decision #{id} in the books queue."`). Filters: `entity` (registry `label.parameterize`: `book`, `author`, `wikidata-link`, `viaf-link`), `outcome`, `confidence`, `decided_by`, `reviewed` (`pending` default/`reviewed`/`all`), `verify` (`hide` default/`include`); bad values → 400 via `enum_param!`. Order `created_at desc, id desc`.
- Row JSON: `id, entity, finder, outcome, confidence, decided_by, reason, created_at, subject {id, type, label}|null, record {id, type, label}|null, review {reviewed_at, reviewed_by, reviewed_via, note, verdict}|null` (label = title or name).
- Detail adds `query` (the snapshot), `selected_index`, `candidates` (each snapshot as stored plus `current` = record summary from `FinderBase#summarize_all` when `record_type/record_id` is one of ours and still exists, else null).
- Reuse the filter logic: extract `Admin::MatchDecisionsBaseController#filtered_scope` into `Services::MatchDecisions::Filter.call(scope, params) → relation` used by both, so the two cannot drift.

- [ ] **Step 1: Failing tests** — list default pending + hides verify; each filter narrows; bad filter 400; row has subject/record labels; get returns query, candidates with `current` for an existing record and null for a deleted one; 404 unknown id and 404 for a games/music finder's decision; read token OK, non-admin token 403; conforms to the admin document.
- [ ] **Step 2:** FAIL. **Step 3:** Implement + OpenAPI + x-mcp (say what each returns, that `entity` values are those four, that the queue shrinks as decisions are reviewed so list again from page 1). Bump pins 18 → 20.
- [ ] **Step 4:** `bin/rails test test/controllers/api test/lib/mcp test/controllers/admin` — PASS. **Step 5:** Commit.

### Task 3: Review and reject-link endpoints

**Files:**
- Modify: the Task 2 controller (`review`, `reject_link`; `require_scopes` index/show read, review write, reject_link merge), routes, OpenAPI, `config/mcp/books/admin_usage.md`, pins
- Test: Task 2 test file

**Interfaces:**
- Produces: `POST .../match_decisions/{id}/review` body `{verdict: "confirmed"|"rejected"|null, note: string|null (≤1000)}` → 200 `{data: <detail row>}`; `POST .../{id}/reject_link` body `{note: string|null (≤1000)}` → 200 `{data: {decision: <row>, rejected: [ids], reverted: [...], descriptions_deprecated: n}}` from `RejectExternalLink`'s result. Tools `review_match_decision` (not destructive), `reject_match_decision_link` (destructive).

- [ ] **Step 1: Failing tests**
  - review sets reviewed_at/by, verdict, note, `reviewed_via_api?`; already reviewed → 422; bad verdict → 400; no verdict OK.
  - review `rejected` on a matched Wikidata decision → 422 whose detail names `reject_match_decision_link`; decision unchanged (Review Focus 1). `rejected` on an author-finder decision → 200.
  - reject_link calls the real service (stub only its enrichment start / external calls the way the existing reject tests do); identifier gone, decision `verdict_rejected?`, its note is `"Link rejected. — <note>"` when a note is sent; cascaded sibling decisions stamped `reviewed_via_api?` + token user (Review Focus 5); service refusal (unmatched decision, VIAF/Wikidata only) → 422 with the service message; token without `books:admin:merge` → 403; user without books delete role → 403.
  - catalogue pins 20 → 22, destructive set gains `rejectMatchDecisionLink`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Append the API note after the service returns, on this decision only (`update_columns(review_note: "#{decision.review_note} — #{note}")`). Policy for reject: books delete role (`require_domain_delete!` semantics via the books policy `destroy?`).
- [ ] **Step 4:** Add to `admin_usage.md`, after "The duplicate queue":

  ```markdown
  ## Match decisions and identifiers

  `list_match_decisions`, `get_match_decision`, `review_match_decision`, `reject_match_decision_link` and the identifier tools are, like the duplicate queue tools, meant for an agent deciding itself: the ask-first rule does not apply to them. `reject_match_decision_link` and `remove_identifier` are permanent.
  ```
- [ ] **Step 5:** Run Task 2/3 tests + `test/lib/mcp test/controllers/api test/lib/services/books/authors` — PASS. Commit.

### Task 4: Identifier read endpoints

**Files:**
- Create: `app/controllers/api/v1/admin/books/identifiers_controller.rb` (book/author index + find), `app/lib/api/v1/admin/books/identifier_resource.rb`
- Modify: routes, OpenAPI, pins
- Test: `test/controllers/api/v1/admin/books/identifiers_controller_test.rb`

**Interfaces:**
- Produces: `getBookIdentifiers` → `get_book_identifiers` (`GET /api/v1/admin/books/{id}/identifiers`, optional `scope=work`), `getAuthorIdentifiers` → `get_author_identifiers` (`GET /api/v1/admin/authors/{id}/identifiers`), `findByIdentifier` → `find_by_identifier` (`GET /api/v1/admin/identifiers?type=&value=`). Row: `{id, identifier_type, value, source, created_at, edition: null|{id, title, edition_type, publication_year}}`. Book list order: own rows first, then editions' by edition id then identifier id; paged with `render_page`. Find returns `{data: [{record_type: "book"|"edition"|"author"|"series", id, label, book: {id, title}|null (for editions)}]}`; `type` must be a `books_*` identifier type (400 otherwise), `value` stripped, required.
- `IDENTIFIER_TYPES = Identifier.identifier_types.keys.grep(/\Abooks_/)`; per-kind write sets (used in Task 5): `BOOK_TYPES = grep(/\Abooks_work_/)`, `AUTHOR_TYPES = grep(/\Abooks_author_/)`.

- [ ] **Step 1: Failing tests** — book identifiers include own and edition rows, own first; `scope=work` only own; a book with 2 pages of rows (set `per_page` small) pages correctly (Review Focus 4); author identifiers; 404 unknown book/author; find by an ISBN held by two editions of different books returns both with their books; find by author QID; bad type 400; missing value 400; read scope OK.
- [ ] **Step 2:** FAIL. **Step 3:** Implement + OpenAPI + x-mcp. Pins 22 → 25. **Step 4:** tests PASS. **Step 5:** Commit.

### Task 5: Add and remove identifiers; admin ids authoritative

**Files:**
- Create: `app/lib/services/books/identifiers/admin_write.rb` (validation/normalisation + add/remove + enrichment trigger)
- Modify: identifiers controller (`create`, `destroy`), routes, OpenAPI, pins; `app/lib/services/books/authors/resolve_wikidata.rb#held_stage`, `app/lib/services/books/authors/resolve_viaf.rb#held_stage` (and `fact_sheet.rb` if it would stamp a second id beside an admin one)
- Test: identifiers controller test, `test/lib/services/books/identifiers/admin_write_test.rb`, resolver tests

**Interfaces:**
- Produces: `POST /api/v1/admin/books/{id}/identifiers` and `POST /api/v1/admin/authors/{id}/identifiers` body `{identifier_type, value}` → 201 new / 200 existing `{data: <row>, also_held_by: [<find rows>]}`; `DELETE /api/v1/admin/{books|authors}/{id}/identifiers/{identifier_id}` → 200 `{data: <deleted row>}`. Tools `add_book_identifier`, `add_author_identifier` (scope `books:admin:write`), `remove_book_identifier`, `remove_author_identifier` (scope `books:admin:merge`, destructive). (Four tools, not two: one path each, matching the existing tag/untag naming.)
- `Services::Books::Identifiers::AdminWrite.add(record:, identifier_type:, value:) → Result` / `.remove(record:, identifier:) → Result`. Normalisation: Wikidata `/\AQ\d+\z/i` → upcase; VIAF `/\A\d+\z/`; ISBN-13 13 digits + checksum, ISBN-10 10 chars + checksum (hyphens/spaces stripped); ISNI 16 chars `[0-9X]`, spaces stripped; others stripped, non-blank, ≤255. Errors: wrong type for the record kind → `:invalid` (400); bad format → `:invalid` (400) naming the expected form; author Wikidata/VIAF with a different value already held → `:conflict` (422, "remove <value> first"); value listed by `Services::Books::Authors::RejectedRecords.new(author).identifier?(type, value)` → `:conflict` (422). Source `admin`. Author Wikidata/VIAF add or remove → `Workflows::Books::AuthorEnrichment.start(author, initiated_by: "admin_identifier", options: {refresh: true}, supersede: true)`.
- Resolvers: in `held_stage`, a held candidate whose identifier row is `source_admin?` is accepted without `corroborated?`, reason "The Wikidata id an admin set, Q…" (VIAF likewise).

- [ ] **Step 1: Failing tests**
  - service: each format rule (valid normalises, invalid refused), wrong kind refused, idempotent add returns existing, conflict on a different held QID, refusal of a rejected value (Review Focus 3), enrichment started for author QID/VIAF add and remove (`Workflows::Books::AuthorEnrichment.expects(:start)`), not for book identifiers.
  - controller: 201/200/400/422/404 (identifier of another record) paths; `also_held_by` lists another record with the same value; scopes; log line not asserted.
  - resolvers (Review Focus 2): author holds an admin-sourced QID whose candidate fails `corroborated?` → verdict matched on that QID, decided_by identifier; a non-admin held QID that fails corroboration still falls through (existing behaviour).
  - pins 25 → 29; destructive set gains the two removes.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `bin/rails test test/controllers/api test/lib/mcp test/lib/services/books` — PASS. **Step 5:** Commit.

### Task 6: Copy prompt, docs, E2E

**Files:**
- Create: `config/mcp/books/prompts/match_decisions.md.erb`, `e2e/tests/books/admin/match-decisions-copy-prompt.spec.ts`
- Modify: `app/lib/services/duplicate_candidates/agent_prompt.rb` → generalise into `Services::AgentPrompts.call(domain:, queue:)` under `app/lib/services/agent_prompts.rb` (queue `:duplicates` | `:match_decisions`; per-queue locals: duplicates keeps `pending_books`/`pending_authors`; match decisions `pending_wikidata`, `pending_viaf`, `pending_authors` from `MatchDecision.needing_review.where(verify: false)` by finder), update the duplicates controller and its test, add `@agent_prompt` + button to `app/views/admin/match_decisions_base/index.html.erb` (same markup as the duplicates index), `docs/features/mcp-server.md`, `docs/features/import-finder.md`
- Test: `test/lib/services/agent_prompts_test.rb` (replaces the duplicates prompt test), E2E

- [ ] **Step 1:** Write `match_decisions.md.erb` from the spec's "Copy prompt" section: the job with `mcp_url` and the three counts; the per-kind steps verbatim in substance (tool names `review_match_decision`, `reject_match_decision_link`, `add_author_identifier`, `find_by_identifier`, `search_admin_authors`, `merge_author`); the house rules (placeholder/place authors deliberate, translators are not authors, never link a person to a same-name different person); "You are authorised to act without asking me. If you genuinely cannot tell, skip it and say why."; the end report.
- [ ] **Step 2:** Generalise the prompt service; unit tests: each queue renders the MCP URL and its counts; nil for a domain without the file.
- [ ] **Step 3:** Button on the match decisions index; E2E like `e2e/tests/books/admin/duplicates-copy-prompt.spec.ts` asserting the clipboard contains `/api/mcp/admin` and `review_match_decision`. Port-3000 rule from AGENTS.md: start the server from this worktree only if 3000 is free; never kill another checkout's server; stop yours after.
- [ ] **Step 4:** Docs: tools, `reviewed_via`, `source: admin` authority, the prompt.
- [ ] **Step 5:** `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, the E2E — green. Commit.
