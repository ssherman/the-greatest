# Admin MCP Duplicate Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four admin API endpoints + MCP tools over the books duplicate queue (list, get, merge, dismiss), a record of who/how every pair was resolved, and a Copy prompt button on the queue page.

**Architecture:** New controller `Api::V1::Admin::Books::DuplicateCandidatesController` documented in `config/api/v1/admin_openapi.yaml` with `x-mcp` blocks, so `Mcp::Catalog` generates the tools as it does every other admin tool. Who/how is carried in `Current` (`acting_user`, `acting_via`), set by the admin and admin-API base controllers and read by `Services::DuplicateCandidates::RecordMerge`, the one place every merger marks a pair. The prompt is a Markdown file rendered into the page.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, `mcp` gem via the existing `Mcp::Catalog`, Stimulus `clipboard_copy_controller`, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-09-admin-mcp-duplicates-design.md`

## Global Constraints

- Run all commands from `web-app/`. Never run brakeman. Lint is `bundle exec standardrb`.
- Generators for new models/controllers/migrations; annotaterb runs on `db:migrate` — never set `ANNOTATERB_SKIP_ON_DB_TASKS`. The dev DB is shared: delete annotation lines for columns this branch's `schema.rb` lacks.
- Controller tests assert behaviour only (status, JSON values, DB state), never HTML/CSS/copy.
- Minitest 6: `assert_nil`, not `assert_equal nil`.
- The endpoints are raw: they refuse only bad data or missing permission. No server text tells the agent to ask the user before a queue merge/dismiss.
- `note` is optional on merge and dismiss.
- Books domain only: item types `Books::Book` (API name `book`) and `Books::Author` (API name `author`).
- Admin API host in tests: `host! "dev-new.thegreatestbooks.org"`; tokens `ApiTokenSecrets::ADMIN` etc. as in `test/controllers/api/v1/admin/books/book_merges_controller_test.rb`; response conformance via `assert_api_response_conform(status:, api: :admin)`.
- Movies is out of scope.

## Review Focus

1. A pair whose records were re-keyed by another merge between list and merge: `merge` with a `target_id` no longer in the pair → 422, nothing merged (Task 4 test).
2. A pair row destroyed by `RecordMerge` (collapsed onto the survivor): get/merge/dismiss → 404 whose detail says to re-list (Tasks 3, 4 tests).
3. A pair with one side already deleted: list/get show that side as `missing: true`; merge → 422; dismiss works (Tasks 3, 4 tests).
4. A merge that fails inside the merger rolls back: the pair stays pending with no `resolved_by`/`resolved_via` (Task 1 test — the stamp is inside the merger's transaction).
5. Merges with no request context (Goodreads replay jobs, console): the pair is marked merged with `resolved_by`/`resolved_via` nil, no error (Task 1 test).

---

### Task 1: Record who and how every pair is resolved

**Files:**
- Create: migration `AddResolvedViaToDuplicateCandidates` (`resolved_via :integer`, nullable, no default)
- Modify: `app/models/duplicate_candidate.rb` (enum), `app/models/current.rb`, `app/lib/services/duplicate_candidates/record_merge.rb`, `app/controllers/admin/base_controller.rb`, `app/controllers/api/v1/admin/books/base_controller.rb`, `app/controllers/admin/duplicate_candidates_base_controller.rb` (dismiss)
- Test: `test/lib/services/duplicate_candidates/record_merge_test.rb`, `test/controllers/admin/books/duplicate_candidates_controller_test.rb`, `test/controllers/api/v1/admin/books/book_merges_controller_test.rb`

**Interfaces:**
- Produces: `DuplicateCandidate` `enum :resolved_via, {admin_ui: 0, api: 1}, prefix: :resolved_via`; `Current.acting_user` (User or nil), `Current.acting_via` (`"admin_ui"`/`"api"` or nil). `RecordMerge#mark_pair_merged` sets `resolved_by_id` and `resolved_via` from `Current`.

- [ ] **Step 1: Failing tests**
  - `RecordMergeTest`: "stamps resolved_by and resolved_via from Current" — inside `Current.set(acting_user: users(<an admin fixture>), acting_via: "api") { RecordMerge.call(...) }`, the pair is `merged`, `resolved_by` is that user, `resolved_via_api?` true.
  - `RecordMergeTest`: "with no Current context the pair is merged with nil who/how" — `assert_nil pair.resolved_by_id`, `assert_nil pair.resolved_via`.
  - `DuplicateCandidatesControllerTest` (admin UI, books): merge sets `resolved_by` = signed-in user and `resolved_via_admin_ui?`; dismiss sets the same.
  - `BookMergesControllerTest`: merging a queued pair through `POST /api/v1/admin/books/:id/merge` sets the pair `resolved_via_api?` and `resolved_by` = the token's user.
  - `RecordMergeTest` (Review Focus 4): inside `ActiveRecord::Base.transaction { Current.set(...) { RecordMerge.call(...) }; raise ActiveRecord::Rollback }`, the pair is afterwards still `pending` with `assert_nil pair.reload.resolved_by_id` — the stamp is one `update_all` inside the merger's transaction.
- [ ] **Step 2:** Run them; expect failures (no column / no Current attributes).
- [ ] **Step 3:** `bin/rails generate migration AddResolvedViaToDuplicateCandidates resolved_via:integer`, `bin/rails db:migrate` (annotaterb runs), `RAILS_ENV=test bin/rails db:test:prepare`. Add the enum. Add `attribute :acting_user, :acting_via` to `Current`.
- [ ] **Step 4:** `before_action` in `Admin::BaseController` (after authentication) setting `Current.acting_user = current_user; Current.acting_via = "admin_ui"`. Same in `Api::V1::Admin::Books::BaseController` with `current_principal.user` and `"api"` (it runs after the parent's authentication callbacks). Extend `mark_pair_merged`'s `update_all` with `resolved_by_id: Current.acting_user&.id, resolved_via: DuplicateCandidate.resolved_vias[Current.acting_via]`. The queue page's `dismiss` adds `resolved_via: :admin_ui`.
- [ ] **Step 5:** Run the tests above plus `bin/rails test test/lib/services/duplicate_candidates test/controllers/admin test/controllers/api/v1/admin` — PASS.
- [ ] **Step 6:** Commit (migration, schema.rb, annotated model + fixture header, code, tests).

### Task 2: Queue page shows and filters by how a pair was resolved

**Files:**
- Modify: `app/controllers/admin/duplicate_candidates_base_controller.rb` (`index`), `app/views/admin/duplicate_candidates_base/index.html.erb`, `app/views/admin/duplicate_candidates_base/_pair.html.erb`
- Test: `test/controllers/admin/books/duplicate_candidates_controller_test.rb`

**Interfaces:**
- Consumes: `resolved_via` enum (Task 1).
- Produces: `index` accepts `via` ∈ `DuplicateCandidate.resolved_vias.keys` (anything else ignored); applies only when `status` is not `pending`.

- [ ] **Step 1: Failing test** — "via=api narrows the merged tab": two merged pairs, one `api`, one `admin_ui`; `get admin_books_duplicate_candidates_path(status: "merged", via: "api")` → 200 and `assigns`-free check: the response contains the api pair's `dom_id` and not the other's (use `assert_select "##{dom_id(pair)}"` only if the pair partial already renders an id; otherwise add `id: dom_id(pair)` to the row in Step 3 — an id is behaviour for targeting, not copy).
- [ ] **Step 2:** Run; FAIL.
- [ ] **Step 3:** Filter in `index`; on non-pending tabs render a small "All / Admin page / API" link group carrying `status` and `via`; append "via API"/"via admin page" to `_pair`'s resolution line. Use daisyUI 5 classes only.
- [ ] **Step 4:** Run the controller test file — PASS.
- [ ] **Step 5:** Commit.

### Task 3: List and get endpoints

**Files:**
- Create: `app/controllers/api/v1/admin/books/duplicate_candidates_controller.rb`, `app/lib/api/v1/admin/books/duplicate_candidate_resource.rb`
- Modify: `config/routes.rb` (beside the other `/api/v1/admin` books routes), `config/api/v1/admin_openapi.yaml` (paths `/api/v1/admin/duplicate_candidates`, `/api/v1/admin/duplicate_candidates/{id}`, schemas `AdminDuplicateCandidate`, `AdminDuplicateCandidateDetail`)
- Test: `test/controllers/api/v1/admin/books/duplicate_candidates_controller_test.rb`, pin tests `test/lib/mcp/admin_catalog_test.rb` (14 → 16, names), `test/lib/mcp/tool_directory_test.rb` (admin count 14 → 16), plus any other pin the suite flags (contract coverage, openapi controller).

**Interfaces:**
- Produces: operationIds `listDuplicateCandidates` (tool `list_duplicate_candidates`), `getDuplicateCandidate` (tool `get_duplicate_candidate`), scope `books:admin:read`, not destructive. `DuplicateCandidateResource.new(pair, records:, summaries:, detail: false).to_h`. Controller private helpers `domain_scope` (pairs with `item_type` in `["Books::Book", "Books::Author"]`), `find_pair` (404 detail: `"No pending or resolved duplicate pair #{id}; it may have been folded into another pair by a merge. List the queue again."`), `ITEM_TYPES = {"book" => "Books::Book", "author" => "Books::Author"}`.
- Pair JSON: `id`, `item_type` (`book`/`author`), `raised_by` (the `source` enum), `status`, `occurrences`, `evidence`, `created_at`, `resolution` (`nil` when pending, else `{resolved_at, resolved_by (email or nil), resolved_via, note}`), `records` — an array of two: `{id, missing: false, title, creators, year, ranked_position, list_count, identifiers, ...}` from `FinderBase#summarize_all`, or `{id, missing: true}`.
- Detail (get) adds to each present record — books: `subtitle`, `alternate_titles`, `description` (first 500 chars), `lists` (names + ids of up to 25 lists it is on); authors: `alternate_names`, `description` (first 500 chars), `books` (up to 25: id, title, rank). And `match_decision`: `nil` or `{id, finder, outcome, confidence, reason}`.

- [ ] **Step 1: Failing tests** (pairs built with `DuplicateCandidate.create!` from books fixtures, ids in order):
  - list defaults to pending, both types; `status=merged` and `item_type=author` filter; bad `status`/`item_type` → 400; conforms to the admin document.
  - each listed pair carries both records with `title` and `missing: false`; a pair whose `item_b` was deleted shows `missing: true` for it (Review Focus 3).
  - get returns detail fields for a book pair and an author pair; includes `match_decision` when linked.
  - get on an unknown id → 404 with "List the queue again" in `detail` (Review Focus 2); get on a music pair's id → 404.
  - a read-scope token can list/get; a token without admin scopes → 403.
  - summaries are batched: list of 3 book pairs runs `summarize_all` once per item type (`expects(:summarize_all).once` on the finder class instance, or assert query count is flat between 1 and 3 pairs).
- [ ] **Step 2:** Run; FAIL.
- [ ] **Step 3:** Implement. Paginate with `render_page` (path `/api/v1/admin/duplicate_candidates`); records and summaries loaded per page with `DataImporters::FinderRegistry.entry_for_model(type)` exactly as `Admin::DuplicateCandidatesBaseController#load_pair_records` does — extract that loader into a shared class `Services::DuplicateCandidates::PairRecords.call(pairs) → {records:, summaries:}` and have the admin controller use it too, so the logic lives once. `text`/`enum_param!` for filters. `x-mcp` descriptions: say what each returns, that ids are integers, that `records` order is by id, and that a 404 means re-list.
- [ ] **Step 4:** Run the new test file and `test/lib/mcp test/controllers/api test/controllers/admin/books/duplicate_candidates_controller_test.rb` — PASS after bumping pins.
- [ ] **Step 5:** Commit.

### Task 4: Merge and dismiss endpoints

**Files:**
- Modify: `app/controllers/api/v1/admin/books/duplicate_candidates_controller.rb` (`merge`, `dismiss`; `require_scopes` map: `index`/`show` `books:admin:read`, `merge` `books:admin:merge`, `dismiss` `books:admin:write`), `config/routes.rb` (member `post :merge`, `post :dismiss`), `config/api/v1/admin_openapi.yaml`, `config/mcp/books/admin_usage.md`
- Test: the Task 3 test file, `test/lib/mcp/admin_catalog_test.rb` (16 → 18; `mergeDuplicateCandidate` added to `DESTRUCTIVE`; `dismissDuplicateCandidate` not destructive), `test/lib/mcp/tool_directory_test.rb`, `test/lib/mcp/sites/books_test.rb` / `test/controllers/api/mcp_admin_controller_test.rb` if they pin `admin_usage.md` text.

**Interfaces:**
- Consumes: Task 1 stamping (merge stamps through `RecordMerge`; dismiss stamps itself), Task 3 resource and `find_pair`.
- Produces: `POST /api/v1/admin/duplicate_candidates/{id}/merge` body `{target_id: int (required), note: string|null, dry_run: bool (default false)}` → 200 `{data: {survivor, deleted, pair}, meta: {dry_run}, warnings}` (survivor/deleted shaped as `merge_book`/`merge_author` return them); `POST .../{id}/dismiss` body `{note: string|null}` → 200 `{data: {pair}}`. Tools `merge_duplicate_candidate` (destructive), `dismiss_duplicate_candidate`.

- [ ] **Step 1: Failing tests**
  - merge: real merge deletes the other record, pair `merged`, `resolved_via_api?`, `resolved_by` = token user, `resolution_note` = note; `meta.dry_run` false.
  - merge `dry_run: true` changes nothing (`Merger.expects(:new).never`), pair still pending.
  - merge without `note` succeeds and leaves `resolution_note` nil.
  - merge refusals: pair not pending → 422; `target_id` not one of the pair's ids → 422 "not in this pair" (Review Focus 1); one side missing → 422; missing `target_id` or non-integer → 400; unknown pair → 404 (Review Focus 2); token lacking `books:admin:merge` → 403; user whose policy denies `destroy?` → 403.
  - merge of an author pair uses the author merger and returns author resources.
  - dismiss: pair `not_duplicate`, `resolved_at` set, `resolved_by` = token user, `resolved_via_api?`, note stored; works when a side is missing (Review Focus 3); not pending → 422; token lacking `books:admin:write` → 403; user without books write role → 403 (`BookPolicy`/`AuthorPolicy#update?` with the pair's type).
  - catalog pins: names, count, destructive set.
- [ ] **Step 2:** Run; FAIL.
- [ ] **Step 3:** Implement `merge` reusing `Services::Books::AdminMerge` and the existing `Mergeable` building blocks — extract what `Mergeable#create` does after it has `source`/`target` (policy check, `AdminMerge.call`, logging, response) into a method both share, rather than copying it. After a successful real merge, `pair.reload` is not possible if `RecordMerge` destroyed it — the named pair itself is the (source, target) pair, so it is marked merged, not destroyed; then `update!(resolution_note: note)` on it. Log `event=api_admin_duplicate action=<merge|dismiss> outcome=... pair_id=... user_id=... token_id=...`. `dismiss` sets `status: :not_duplicate, resolved_at: Time.current, resolved_by: current_principal.user, resolved_via: :api, resolution_note: note`.
- [ ] **Step 4:** `x-mcp` descriptions — merge: "Merges the pair: `target_id` (one of the pair's two record ids) survives and the other record is PERMANENTLY DELETED, with no undelete. `dry_run: true` validates without changing anything. `note` is optional and shown to admins reviewing the queue. A 422 saying the target is not in this pair, or a 404, means another merge changed the queue: list it again." Dismiss: "Marks the pair as not duplicates. `note` is optional and shown to admins." Mark merge `destructive: true`.
- [ ] **Step 5:** Add to `admin_usage.md`, after the "Merges and deletes" section, exactly one short section:

  ```markdown
  ## The duplicate queue

  `list_duplicate_candidates`, `get_duplicate_candidate`, `merge_duplicate_candidate` and `dismiss_duplicate_candidate` work through pairs our importers flagged as possible duplicates. They are meant for an agent deciding each pair itself: the ask-first rule above does not apply to them. `merge_duplicate_candidate` is still permanent.
  ```
- [ ] **Step 6:** Run the Task 3/4 tests and `bin/rails test test/lib/mcp test/controllers/api` — PASS.
- [ ] **Step 7:** Commit.

### Task 5: Copy prompt button, docs, E2E

**Files:**
- Create: `config/mcp/books/prompts/duplicates.md.erb`, `e2e/tests/books/admin/duplicates-copy-prompt.spec.ts`
- Modify: `app/controllers/admin/duplicate_candidates_base_controller.rb` (expose `@agent_prompt` for books only — a domain with no prompt file renders no button), `app/views/admin/duplicate_candidates_base/index.html.erb`, `docs/features/mcp-server.md`, `docs/features/import-finder.md`
- Test: `test/controllers/admin/books/duplicate_candidates_controller_test.rb` (index still 200 with the prompt; no behaviour beyond that), the E2E spec.

**Interfaces:**
- Consumes: tool names from Tasks 3–4; `@counts` already in `index`; `Api::Host.base_url`.
- Produces: the prompt rendered with locals `mcp_url` (`"#{Api::Host.base_url}/api/mcp/admin"`), `pending_books`, `pending_authors` (pending counts per item type — `@counts` is per status only, so add one grouped count).

- [ ] **Step 1:** Write `duplicates.md.erb` with the spec's "Starting content" section, in order: the job (with `mcp_url` and the two pending counts), the method per pair (including "You are authorised to merge and dismiss without asking me. If you genuinely cannot tell, skip it and say why."), the five house rules verbatim from the spec, the note guidance, and the end-of-run report. Plain second person, no headings deeper than `##`.
- [ ] **Step 2:** In the index, a "Copy prompt" button (`btn btn-sm`) in the page header with `data-controller="clipboard-copy"`, the rendered prompt in a hidden `<textarea data-clipboard-copy-target="source" readonly>` (a textarea keeps newlines in `.value`), `data-testid="copy-agent-prompt"` on the button.
- [ ] **Step 3: E2E** — admin storage state, books host, open the duplicates page, grant clipboard permissions, click the button, read `navigator.clipboard.readText()`, assert it contains `/api/mcp/admin` and `list_duplicate_candidates`. Check port 3000 belongs to this worktree before running (AGENTS.md snippet); stop and report if it does not.
- [ ] **Step 4:** Docs: `mcp-server.md` — the four tools, the queue exception in `admin_usage.md`, the Copy prompt workflow. `import-finder.md` — `resolved_via`, `Current.acting_user/acting_via`, the API path, the `via` filter.
- [ ] **Step 5:** `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`, the E2E spec — all green. Commit.
