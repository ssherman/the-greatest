# Admin MCP: Create Author Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `create_author`, enrich a hand-made author when it gets its first book, stop `reject_repair_verdict` on re-import matches, and put the pen-name and namesake rules in the duplicates Copy prompt.

**Architecture:** A shared `Services::Books::Authors::AdminCreate` backs the admin "New author" page and a new `create` action on the admin API authors controller. `Services::Books::BookAuthors::Edit.add` starts `Workflows::Books::AuthorEnrichment` after commit when the author has never had a run. `Services::Books::RepairVerdicts::Review.reject` refuses `reimport_match`.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, OpenAPI 3, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-15-admin-mcp-create-author-design.md`

## Global Constraints

- Rails commands from `web-app/`. `bundle exec standardrb`. Never brakeman. No destructive dev-DB commands. Root-anchor `::Books::*` in namespaced code.
- `POST /api/v1/admin/authors`, operationId `createAdminAuthor` (tool `create_admin_author`), scope `books:admin:write`, policy `::Books::AuthorPolicy#create?`; not destructive. Catalogue 58 → 59.
- Body read raw (`request.raw_post.to_s`) like `FieldUpdate`. Fields: `name` (string, required, non-blank), `alternate_names` (array of strings), `birth_year`, `death_year` (integers −3000..3000, or null), `wikidata_qid` (string matching `/\AQ\d+\z/`).
- Status split: malformed JSON / wrong type / missing `name` / bad QID format → 400; unknown key, blank name, model validation failure → 422; QID held by another author → 409 with a detail naming the holder's id and name. Responds 201 with `AuthorDetailResource`.
- A given QID is stored through `Services::Books::Identifiers::AdminWrite.add(record:, identifier_type: "books_author_wikidata_qid", value:)` (source `admin`, starts the enrichment) in the same transaction as the author; if that refuses, nothing is created.
- Enrich-on-first-book: "never had a run" means no `WorkflowRun` with `workflow` equal to the author-enrichment workflow name and `enrichable` the author. Start with `initiated_by: "first_book_link"` after the link commits (never inside a rolled-back transaction).
- `reject` on a `reimport_match` verdict: failure code `:reimport_match`, message `"A re-import match can't be rejected; correct it with correct_repair_verdict instead."`; API → 422; the admin page shows no Reject control for that kind and refuses a hand-made request with the same message.
- Controller tests assert behaviour, never copy.

## Review Focus

1. A QID held by a soft-gone or merged-away author: an author deleted by merge no longer exists, so its identifier is gone — but a QID held by ANY existing author row (including provisional) is a 409 → Task 1 test `create refuses a qid a provisional author holds`.
2. Two `add_book_author` calls for the same new author must start at most one run (the second sees the first) → Task 2 test `a second first-book link does not start a second run`.
3. A failed link (duplicate, unknown author) must start no run → Task 2 test `a refused add starts no run`.
4. Creating an author with a QID and then linking a book must not start a second run (the QID add already started one) → Task 2 test `an author created with a qid is not re-enriched on its first book`.
5. `alternate_names` with blanks or duplicates is normalised the way the model already normalises → Task 1 test `alternate names are normalised`.

---

### Task 1: AdminCreate service, admin page, create_admin_author endpoint

**Files:**
- Create: `web-app/app/lib/services/books/authors/admin_create.rb`
- Modify: `web-app/app/controllers/admin/books/authors_controller.rb` (`create` uses the service), `web-app/app/controllers/api/v1/admin/books/authors_controller.rb` (`create`), `web-app/config/routes.rb`, `web-app/config/api/v1/admin_openapi.yaml`
- Test: `web-app/test/lib/services/books/authors/admin_create_test.rb`, `web-app/test/controllers/admin/books/authors_controller_test.rb`, `web-app/test/controllers/api/v1/admin/books/authors_controller_test.rb`, pins (`test/lib/mcp/admin_catalog_test.rb`, `test/lib/mcp/tool_directory_test.rb`, `test/controllers/api/mcp_admin_controller_test.rb`, `test/controllers/api/v1/admin/openapi_controller_test.rb` only if paths change — `/api/v1/admin/authors` already exists, so add the `post` to it), `test/integration/api/v1/admin_contract_coverage_test.rb`

**Interfaces:**
- Produces: `Services::Books::Authors::AdminCreate.call(attrs:, wikidata_qid: nil) -> Result(success?, data: {author:}, errors:, code:)`; `code` ∈ `:conflict` (QID held; `data: {holder:}`), `:unprocessable`.

- [ ] **Step 1: Failing service tests** — `creates an author`, `alternate names are normalised`, `stores a qid as an admin identifier and starts the enrichment` (Mocha expectation on `Workflows::Books::AuthorEnrichment.start`), `create refuses a qid another author holds` (conflict, holder in data, nothing created), `create refuses a qid a provisional author holds`, `a blank name is unprocessable`.
- [ ] **Step 2: Run** — expect NameError. **Step 3: Implement** (transaction; QID holder check via `Identifier.find_by(identifier_type: :books_author_wikidata_qid, value:)`; then `AdminWrite.add`; any refusal raises to roll back). **Step 4: Run** — PASS.
- [ ] **Step 5: Admin page** `create` calls the service (page form has no QID field; behaviour otherwise unchanged). Keep existing page tests green.
- [ ] **Step 6: API** — failing controller tests for each status in the split (201 body shape matches `get_admin_author`; 400 missing name / wrong types / bad QID format; 422 unknown key / blank name; 409 detail contains the holder's id; read token 403). Implement (reuse `FieldUpdate#json_body`/typing helpers where they fit). OpenAPI `post` on `/api/v1/admin/authors` with x-mcp text: search first with `search_admin_authors`; pass `wikidata_qid` when known (it pins the right person; without it the author is enriched once it gets its first book); 409 names the author who already has that QID — that is probably the same person, so link books to them instead.
- [ ] **Step 7: Pins** 58 → 59, contract coverage for every documented status. **Step 8: Run** `bin/rails test test/controllers/api test/lib/mcp test/integration/api test/lib/services/books/authors test/controllers/admin/books`, standardrb. **Step 9: Commit** `Admin API + MCP: create_admin_author; the admin page uses the same service`.

---

### Task 2: Enrich on first book; reject refuses re-import matches

**Files:**
- Modify: `web-app/app/lib/services/books/book_authors/edit.rb`, `web-app/app/lib/services/books/repair_verdicts/review.rb`, `web-app/app/controllers/api/v1/admin/books/repair_verdicts_controller.rb` (map `:reimport_match` → 422 if not already generic), `web-app/app/views/admin/books/repair_verdicts/` (hide Reject for `reimport_match`), `web-app/config/api/v1/admin_openapi.yaml` (rejectRepairVerdict text)
- Test: `web-app/test/lib/services/books/book_authors/edit_test.rb`, `web-app/test/lib/services/books/repair_verdicts/review_test.rb`, `web-app/test/controllers/api/v1/admin/books/repair_verdicts_controller_test.rb`, `web-app/test/controllers/admin/books/repair_verdicts_controller_test.rb`

**Interfaces:**
- Consumes: Task 1's service (for the QID test).

- [ ] **Step 1: Failing tests** — Edit: `the first book link starts an author enrichment after commit` (Mocha expects `AuthorEnrichment.start(author, initiated_by: "first_book_link")` once), `a second first-book link does not start a second run` (a run row now exists), `a refused add starts no run`, `an author with an earlier run is not re-enriched`, `an author created with a qid is not re-enriched on its first book`. Review: `reject refuses a reimport_match` (code and message as Global Constraints; verdict unchanged). API: reject of a reimport_match → 422. Page: reject of a reimport_match → refused, verdict unchanged.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** The start happens after commit (`ActiveRecord.after_all_transactions_commit` or equivalent; check how `BookEnrichment.start`'s dispatch waits for the outer commit and follow it). **Step 4: Run** — PASS, standardrb. **Step 5: Commit** `Hand-made authors are enriched on their first book; re-import matches can't be rejected`.

---

### Task 3: Duplicates prompt rules, docs, full verification

**Files:**
- Modify: `web-app/config/mcp/books/prompts/duplicates.md.erb`, `web-app/config/mcp/books/admin_usage.md` (add `create_admin_author` to the ask-first exemption), `docs/features/mcp-server.md` (59 tools, create_admin_author, enrich-on-first-book, reject refusal)
- Test: `web-app/test/lib/services/agent_prompts_test.rb` (prompt names `create_admin_author`, `update_book_author`, `reject_match_decision_link`)

- [ ] **Step 1:** Add the spec's goal-4 rules to the duplicates prompt, for author pairs, verbatim in substance, including checking the new author's match decisions after linking books. **Step 2:** agent_prompts test; run. **Step 3:** docs. **Step 4:** full `bin/rails test`, standardrb; if any admin page view changed, run the existing repair-verdicts E2E spec after the AGENTS.md port-3000 check (stop and report if another checkout holds it). **Step 5: Commit** `Duplicates prompt: pen-name and namesake rules; docs`.
