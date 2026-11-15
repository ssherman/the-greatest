# Admin MCP: Series Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin agent list, inspect, create, rename, soft-delete and merge book series and fix their book memberships through the admin API/MCP, with deletes and merges that the Goodreads enrichment respects.

**Architecture:** `books_series` gains category-style `deleted` + `merged_into_id`. Services under `Services::Books::SeriesEdits` (not `Services::Books::Series`, which would shadow the `::Books::Series` model inside `Services::Books`) hold every rule; the admin series pages and new API controllers both call them. `ApplySeries` resolves a Goodreads series id through `Books::Series#canonical`. Nine OpenAPI operations with x-mcp blocks become MCP tools.

**Tech Stack:** Rails 8, PostgreSQL, Minitest + fixtures + Mocha, Alba, OpenAPI 3 (`config/api/v1/admin_openapi.yaml`), Playwright.

**Spec:** `docs/superpowers/specs/2026-11-14-admin-mcp-series-design.md`

## Global Constraints

- All Rails commands from `web-app/`. Lint `bundle exec standardrb`. Never run brakeman. Never set ANNOTATERB_SKIP_ON_DB_TASKS; the migration task runs annotaterb (via `bin/rails db:migrate`) and commits the annotation diff. No destructive commands against the development DB.
- Root-anchor model references inside `Services::Books` / `Api::V1::Admin::Books` (`::Books::Series`, `::Books::SeriesBook`, `::Books::Book`).
- Operations (tool name = underscored operationId):

  | Method + path | operationId | Scope | destructive |
  |---|---|---|---|
  | `GET /api/v1/admin/series` | `listAdminSeries` | `books:admin:read` | no |
  | `GET /api/v1/admin/series/{id}` | `getAdminSeries` | `books:admin:read` | no |
  | `POST /api/v1/admin/series` | `createAdminSeries` | `books:admin:write` | no |
  | `PATCH /api/v1/admin/series/{id}` | `updateAdminSeries` | `books:admin:write` | no |
  | `DELETE /api/v1/admin/series/{id}` | `deleteAdminSeries` | `books:admin:merge` | yes |
  | `POST /api/v1/admin/series/{id}/merge` | `mergeAdminSeries` | `books:admin:merge` | yes |
  | `POST /api/v1/admin/series/{id}/books` | `addSeriesBook` | `books:admin:write` | no |
  | `PATCH /api/v1/admin/series/{id}/books/{book_id}` | `updateSeriesBook` | `books:admin:write` | no |
  | `DELETE /api/v1/admin/series/{id}/books/{book_id}` | `removeSeriesBook` | `books:admin:write` | yes |

- Writes also check `::Books::SeriesPolicy` (`create?`, `update?`, `destroy?`) for the token's user; 403 otherwise.
- Admin catalogue: 49 → 51 after Task 3, 58 after Task 4. Destructive tools: 14 → 17 after Task 4.
- Status split: malformed body / wrong JSON type / bad id / empty PATCH body → 400; well-formed but refused (unknown key, unknown book, duplicate link, representative not in series, Goodreads id held by another series, editing a deleted or merged series, invalid merge) → 422; missing series, or a book not in the series on update/remove → 404.
- Bodies are read from `request.raw_post.to_s` like `FieldUpdate#json_body`, so `null` survives.
- `position` is `decimal(8,2)`: accepts a JSON integer or float with at most 2 decimals in −999999.99..999999.99, or null; serialised as a JSON number (not a string). `numbered` boolean. `position_label` string or null (blank → nil).
- Merge: 1–50 `source_ids`, no repeats, not the target; `dry_run` boolean, default false. Delete: `dry_run` boolean, default false (query or JSON body, matching how `deleteAdminCategory` takes it).
- Goodreads series id identifier: `identifier_type: :books_series_goodreads_id`, value is the id as a string, `source: :admin` when set through these tools.
- Every series listing excludes deleted series unless `include_deleted=true`.
- Controller tests assert behaviour (status, records, JSON keys), never copy.

## Review Focus

1. A Goodreads id whose series was merged into a target that was later deleted must not link the book anywhere (no link to a deleted series) → Task 1 test `apply skips a series merged into a deleted target`.
2. Merging two series that share a book keeps exactly one link, the target's, with the target's position → Task 1 test `merge keeps the target's link for a shared book`.
3. A JSON `position` of `1.5` must store 1.5 and come back as the number 1.5, and `"3"` (string) or `1.234` must be 400 → Task 4 tests `position accepts a decimal` and `position rejects strings and 3 decimals`.
4. Removing a book that is the series' representative clears the representative (API and page) → Task 2 test `remove clears the representative`.
5. Creating a series with a Goodreads id another series holds (including a soft-deleted one) is 422, and nothing is created → Task 2 test `create refuses a goodreads id another series holds` (service) and Task 4 contract 422.

---

### Task 1: Soft delete, merge, and the enrichment

**Files:**
- Create: migration `AddDeletedAndMergedIntoToBooksSeries` (via `bin/rails generate migration`), `web-app/app/lib/services/books/series_edits/delete.rb`, `web-app/app/lib/services/books/series_edits/merge.rb`
- Modify: `web-app/app/models/books/series.rb`, `web-app/app/lib/services/books/goodreads_enrichment/apply_series.rb`, `web-app/test/fixtures/books/series.yml` (add a deleted and a merged row if needed)
- Test: `web-app/test/lib/services/books/series_edits/delete_test.rb`, `.../merge_test.rb`, `web-app/test/models/books/series_test.rb`, `web-app/test/lib/services/books/goodreads_enrichment/apply_series_test.rb`

**Interfaces:**
- Produces:
  - Columns `books_series.deleted boolean NOT NULL DEFAULT false` (indexed), `books_series.merged_into_id bigint` (indexed, FK to `books_series.id`, `on_delete: :nullify`).
  - `Books::Series`: `belongs_to :merged_into, class_name: "Books::Series", optional: true`; scopes `active` (`deleted: false`), `merged` (`merged_into_id NOT NULL`); `#canonical` → self when not deleted; the merge target when deleted, merged, and the target is not deleted; else nil.
  - `Services::Books::SeriesEdits::Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)` (one shared struct for every SeriesEdits service; `code` ∈ `:not_found`, `:unprocessable`).
  - `SeriesEdits::Delete.call(series:, dry_run: false) -> Result`; data `{series:, book_count:}` (book_count = links that are/would be removed). Refuses (`:unprocessable`) an already-deleted series: `"Series #{id} is already deleted."`.
  - `SeriesEdits::Merge.refusal(source:, target:) -> String | nil`; `SeriesEdits::Merge.call(target:, source:, dry_run: false) -> Result`; data `{moved: Integer, dropped: Integer}` (links moved to target; source links dropped because the book is already in the target). Refusal messages: `"A series can't be merged into itself."`, `"Deleted series can't be merged."` (source or target deleted), `"Merged series can't be merge targets."`.
  - `ApplySeries` fact reason `"deleted_series"` when the Goodreads id resolves (via `canonical`) to nothing.

- [ ] **Step 1: Migration and model.** Generate the migration, run `bin/rails db:migrate` (annotaterb runs; keep only this branch's columns in the annotation diff). Add association, scopes and `#canonical`. Model tests: `canonical returns self for a live series`, `canonical follows a merge to a live target`, `canonical is nil for a junk delete`, `canonical is nil when the merge target was deleted`.
- [ ] **Step 2: Failing service tests.** Delete: `delete removes the links and keeps the row and its identifiers`, `delete clears the representative`, `dry run changes nothing and reports book_count`, `deleting a deleted series is unprocessable`. Merge: `merge moves links and marks the source deleted and merged_into the target`, `merge keeps the target's link for a shared book` (target link's position/numbered/label unchanged, source link gone, `dropped` 1), `merge repoints series previously merged into the source`, `merge keeps the target's representative, else adopts the source's when that book moved`, `merge keeps the source's goodreads identifier on the source`, `dry run changes nothing and reports moved and dropped`, and one test per refusal.
- [ ] **Step 3: Run them** — expect NameError.
- [ ] **Step 4: Implement** `Delete` and `Merge`. Lock series rows in id order inside a transaction and re-check state after locking (as `Categories::Merger#merge` / `Categories::Deleter#soft_delete` do). Merge moves links with `update_all(series_id: target.id)` for books not already in the target and deletes the rest.
- [ ] **Step 5: ApplySeries.** Resolve `identifier.identifiable.canonical`; nil → `fact(entry, label, false, "deleted_series")` with no link and no new series. Tests: `apply links to the merge target`, `apply skips a junk-deleted series`, `apply skips a series merged into a deleted target`, and the existing tests still pass.
- [ ] **Step 6: Run** the four test files plus `test/lib/services/books/goodreads_enrichment` — PASS. `bundle exec standardrb` clean.
- [ ] **Step 7: Commit** `Series: soft delete, merge, and the Goodreads enrichment follows them`.

---

### Task 2: Create, update and membership services; admin pages use them

**Files:**
- Create: `web-app/app/lib/services/books/series_edits/create.rb`, `update.rb`, `membership.rb`
- Modify: `web-app/app/controllers/admin/books/series_controller.rb`, `web-app/app/controllers/admin/books/series_books_controller.rb`, `web-app/app/views/admin/books/series/show.html.erb` (deleted/merged notice + link to target)
- Test: `web-app/test/lib/services/books/series_edits/{create,update,membership}_test.rb`, `web-app/test/controllers/admin/books/series_controller_test.rb`, `web-app/test/controllers/admin/books/series_books_controller_test.rb`

**Interfaces:**
- Consumes: Task 1's `Result`, `Delete`, columns and scopes.
- Produces (all return `SeriesEdits::Result`; `data` is the series for Create/Update, the `Books::SeriesBook` row for Membership add/update, the removed row for remove):
  - `SeriesEdits::Create.call(attrs:) -> Result` — attrs `"title"` (required), `"goodreads_series_id"` (optional String).
  - `SeriesEdits::Update.call(series:, attrs:) -> Result` — attrs any of `"title"`, `"representative_book_id"` (Integer or nil), `"goodreads_series_id"` (String; only when the series has none, else `:unprocessable` `"Series #{id} already has Goodreads series id #{value}."`).
  - `SeriesEdits::Membership.add(series:, book_id:, attrs: {})`, `.update(series:, book_id:, attrs:)`, `.remove(series:, book_id:)` — attrs `"position"` (BigDecimal/Numeric or nil), `"numbered"` (Boolean), `"position_label"` (String or nil).
  - Messages: Goodreads id taken `"Goodreads series id #{value} already belongs to series #{other_id}."`; representative not in series `"Book #{book_id} is not in this series."`; deleted/merged series edit `"Series #{id} is deleted."` / `"Series #{id} was merged into series #{target_id}."`; duplicate link `"Book #{book_id} is already in this series; edit that entry instead."`; unknown book `"No book #{book_id}."`; not in series on update/remove → code `:not_found`, `"Book #{book_id} is not in this series."`.

- [ ] **Step 1: Failing service tests.** Create: `create with a title`, `create stores a goodreads id as an admin-sourced identifier`, `create refuses a goodreads id another series holds` (also when that series is soft-deleted; nothing created), `create without a title is unprocessable`. Update: `update renames`, `representative must be a book in the series`, `null clears the representative`, `goodreads id can be set when missing`, `goodreads id cannot replace an existing one`, `a deleted series cannot be edited`, `a merged series cannot be edited`. Membership: `add`, `add refuses a duplicate`, `add refuses an unknown book`, `update is partial`, `null clears position and position_label`, `blank position_label stores nil`, `remove clears the representative`, `update and remove of a book not in the series are not_found`, `add/update/remove on a deleted series are unprocessable`.
- [ ] **Step 2: Run** — expect NameError.
- [ ] **Step 3: Implement** the three services. The Goodreads-id check looks across all series (`Identifier.where(identifier_type: :books_series_goodreads_id, value:)`), deleted ones included. Create runs in a transaction so a failed identifier leaves no series.
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Admin pages adopt the services.** `SeriesController`: `create`/`update` call `Create`/`Update` (the page form still sends only `title`); `destroy` calls `Delete` (soft); `index` lists `active` only; `show` of a deleted or merged series renders with a notice naming the target (link to it) and hides edit controls. `SeriesBooksController`: `create`/`update`/`destroy` call `Membership` (keyed by the row's `book_id`), keeping current turbo_stream/html responses; `make_representative` calls `Update` with `representative_book_id`. Controller tests: `destroy soft-deletes and keeps the row`, `index hides deleted series`, `show of a merged series is ok`, `create of a duplicate book is unprocessable`, existing tests still pass.
- [ ] **Step 6: Run** `bin/rails test test/lib/services/books/series_edits test/controllers/admin/books` and `bundle exec standardrb`.
- [ ] **Step 7: Commit** `Series: shared create, update and membership services behind the admin pages`.

---

### Task 3: Read endpoints and get_admin_book series

**Files:**
- Create: `web-app/app/controllers/api/v1/admin/books/series_controller.rb` (index, show), `web-app/app/lib/api/v1/admin/books/series_resource.rb`, `web-app/app/lib/api/v1/admin/books/series_detail_resource.rb`
- Modify: `web-app/config/routes.rb` (admin API block near the categories routes), `web-app/config/api/v1/admin_openapi.yaml`, `web-app/app/lib/api/v1/admin/books/book_detail_resource.rb`, `web-app/app/controllers/api/v1/admin/books/books_controller.rb` (preload)
- Test: `web-app/test/controllers/api/v1/admin/books/series_controller_test.rb`, `web-app/test/controllers/api/v1/admin/books/books_controller_test.rb`, the pin and coverage tests named in Task 4 Step 6

**Interfaces:**
- Consumes: Task 1 columns/scopes.
- Produces:
  - `SeriesResource` row: `id, slug, title, book_count, goodreads_series_id, deleted, merged_into_id` (book_count from one grouped count query per page, not per row).
  - `SeriesDetailResource`: row fields + `representative_book` (`{id, title}` or null) + `books`: `[{id, slug, title, first_published_year, authors: [{id, name}], position, numbered, position_label}]` ordered `position NULLS LAST, books_series_books.id`. Used by Task 4 for write responses.
  - `get_admin_book` gains `series: [{id, title, position, numbered, position_label}]` (live series only, ordered by title).
  - OpenAPI schemas `AdminSeries`, `AdminSeriesDetail`, `AdminSeriesBook`.

- [ ] **Step 1: Failing tests.** Index: default excludes deleted; `include_deleted=true` includes them; `q` matches title case-insensitively; `max_books=1` returns only single-book series; `min_books=2`; `sort=book_count` orders by count desc then id; bad `sort` or non-integer `min_books` → 400; paging like `GET /api/v1/admin/categories`; read scope 200, member token 403. Show: books ordered with nulls last; `position` is a JSON number (`1.5` → `1.5`); a merged series returns `deleted: true, merged_into_id`; unknown id 404. `get_admin_book` returns `series` for a fixture book in a series.
- [ ] **Step 2: Run** — expect routing failures.
- [ ] **Step 3: Implement** routes, controller (`require_scope "books:admin:read"`, paging via the helper the categories index uses), resources, preload in books#show.
- [ ] **Step 4: OpenAPI** for `listAdminSeries` and `getAdminSeries` (x-mcp descriptions: what a legit series is in one line, that listings hide deleted series, how to find single-book series), plus the `getAdminBook` `series` property. Update pins 49 → 51 and contract coverage for both operations.
- [ ] **Step 5: Run** `bin/rails test test/controllers/api test/lib/mcp test/integration/api` and `bundle exec standardrb` — PASS.
- [ ] **Step 6: Commit** `Admin API + MCP: list and get series; get_admin_book shows series`.

---

### Task 4: Write endpoints

**Files:**
- Modify: `web-app/app/controllers/api/v1/admin/books/series_controller.rb` (create, update, destroy, merge); Create: `web-app/app/controllers/api/v1/admin/books/series_books_controller.rb`
- Modify: `web-app/config/routes.rb`, `web-app/config/api/v1/admin_openapi.yaml`
- Test: `web-app/test/controllers/api/v1/admin/books/series_controller_test.rb`, `.../series_books_controller_test.rb`, `web-app/test/integration/api/v1/admin_contract_coverage_test.rb`, `web-app/test/integration/api/v1/operation_scope_contract_test.rb` (sample_url for `{book_id}` if needed), `web-app/test/controllers/api/v1/admin/openapi_controller_test.rb`, `web-app/test/lib/mcp/admin_catalog_test.rb`, `web-app/test/lib/mcp/tool_directory_test.rb`, `web-app/test/controllers/api/mcp_admin_controller_test.rb`

**Interfaces:**
- Consumes: Task 1 `Delete`, `Merge`; Task 2 `Create`, `Update`, `Membership`; Task 3 `SeriesDetailResource`.
- Produces: responses — create 201 / update 200 / membership 200: `{data: SeriesDetailResource}`; delete: `{data: {id, deleted: true, book_count}}` (dry run adds `meta: {dry_run: true}` and changes nothing); merge: `{data: {target: SeriesDetailResource, sources: [{id, title, moved, dropped}]}}` (dry run same shape + `meta: {dry_run: true}`). Merge runs sources in order and, like `mergeCategories`, reports `merged`, `failed`, `not_attempted` if one fails part way — follow `CategoriesController#run_merges`.

- [ ] **Step 1: Failing controller tests**, one per rule in Global Constraints' status split, including: create 201 with and without `goodreads_series_id`; create taken Goodreads id 422; update rename; update empty body 400; update unknown key 422; update `representative_book_id` not in series 422; update of a merged series 422; `position accepts a decimal` (1.5 stored and returned as 1.5); `position rejects strings and 3 decimals` (`"3"` → 400, `1.234` → 400); membership add duplicate 422, unknown book 422, update/remove book not in series 404, `null` clears position; delete dry run changes nothing; delete soft-deletes; merge dry run; merge with a source equal to target 400; merge refusal 422; read/write tokens on merge-scoped operations 403; MCP-level test calling `merge_admin_series` with `dry_run: true`.
- [ ] **Step 2: Run** — expect routing failures.
- [ ] **Step 3: Implement** routes and controllers. Reuse `StrictIds` for ids, the categories controller's dry-run and `source_ids` parsing patterns, and raw-body parsing with typed values (non-string title → 400; title blank → 422 via the service).
- [ ] **Step 4: OpenAPI** for the seven operations with x-mcp blocks. Descriptions carry: run `dry_run: true` before delete and merge; deletes and merges stick against the Goodreads enrichment; a deleted series keeps its Goodreads id; removing one book from a live series may be undone by the next enrichment if Goodreads still lists it; search before create and pass the Goodreads series id when known; `merge_admin_series` `id` is the series that survives. Mark the three destructive operations.
- [ ] **Step 5: Run** focused tests — PASS.
- [ ] **Step 6: Pins and coverage.** Counts 51 → 58, destructive 14 → 17 (add `delete_admin_series`, `merge_admin_series`, `remove_series_book` to the sorted list), openapi path list, every documented status of the seven operations in `EXERCISES`.
- [ ] **Step 7: Verify** full `bin/rails test` and `bundle exec standardrb`.
- [ ] **Step 8: Commit** `Admin API + MCP: create, edit, delete and merge series; manage series books`.

---

### Task 5: Copy prompt, E2E, docs

**Files:**
- Create: `web-app/config/mcp/books/prompts/series.md.erb`, `web-app/e2e/tests/books/admin/series-copy-prompt.spec.ts`
- Modify: `web-app/app/lib/services/agent_prompts.rb` (queue `:series` + counts), `web-app/app/controllers/admin/books/series_controller.rb` (`@agent_prompt` on index), `web-app/app/views/admin/books/series/index.html.erb` (Copy prompt button, same markup as repair_verdicts index), `web-app/config/mcp/books/admin_usage.md`, `docs/features/mcp-server.md`
- Test: `web-app/test/lib/services/agent_prompts_test.rb`, `web-app/test/controllers/admin/books/series_controller_test.rb`

**Interfaces:**
- Consumes: the nine tool names.
- Produces: `Services::AgentPrompts.call(domain: :books, queue: :series)` → String with counts `live_series`, `single_book_series`, `books_in_several_series`.

- [ ] **Step 1: Prompt text.** Write `series.md.erb` from the spec's "Cleanup rules for the prompt" verbatim in substance, plus the workflow: list with `list_admin_series` (start with `max_books=1` and with titles that look like publisher lines), inspect with `get_admin_series` and `get_admin_book`, dry-run before every `delete_admin_series` / `merge_admin_series`, prefer delete over removing books one by one for junk series, search with `list_admin_series q=` and `search_admin_books` before `create_admin_series`, report what was changed at the end. Show the counts at the top.
- [ ] **Step 2: AgentPrompts test** `series prompt renders the counts and names the tools`; controller test `index assigns a prompt`. Run — FAIL, implement, PASS.
- [ ] **Step 3: E2E** `series-copy-prompt.spec.ts`, modelled on `repair-verdicts-copy-prompt.spec.ts`. Before running, confirm port 3000 belongs to this worktree (AGENTS.md snippet); if it doesn't, stop and report. Run `yarn test:e2e e2e/tests/books/admin/series-copy-prompt.spec.ts` plus the existing series-related admin spec if one exists.
- [ ] **Step 4: Docs.** `admin_usage.md`: add the nine series tools to the ask-first exemption sentence and one paragraph: dry-run before delete/merge, deletes and merges stick, a single-book removal may be undone by the enrichment. `docs/features/mcp-server.md`: the nine tools, counts 49 → 58, the soft-delete/merge model and the known gaps from the spec.
- [ ] **Step 5: Verify** full `bin/rails test`, `bundle exec standardrb`.
- [ ] **Step 6: Commit** `Series: Copy prompt for the cleanup agent, E2E and docs`.
