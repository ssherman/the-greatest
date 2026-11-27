# Admin MCP List Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin agent add, edit and remove the rows of a books list, and request a new book through the book-submission pipeline (optionally landing it on a books list), with row changes recorded in list audits.

**Architecture:** Row writes are a service (`Services::Lists::AdminItems`) behind three actions on the existing admin `ListItemsController`. New books come in through `BookSubmission`, which gains an `origin` (reader/admin) and an admin target (`list_id` + `list_position`). A new `AdminRequest` service is the admin front door; `CreateBook` and `ProcessSubmission` branch on origin. Any admin path that puts a provisional book on a list promotes it first (`Services::Books::PromoteProvisionalBook`). MCP tools are generated from `config/api/v1/admin_openapi.yaml` operations carrying `x-mcp`.

**Tech Stack:** Rails 8, Minitest + fixtures + Mocha, Alba resources, OpenAPI-driven MCP catalog, Sidekiq.

**Spec:** `docs/superpowers/specs/2026-11-26-admin-mcp-list-items-design.md`

Work in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/admin-mcp-list-items` (branch `worktree-admin-mcp-list-items`). Its five gitignored files are already copied. Run Rails commands from `web-app/`.

## Global Constraints

- Books only: every new endpoint refuses a list that is not a `Books::List` with 404 (`"No books list N."`), as the existing read does.
- Inside `Api::V1::Admin::Books`, root-anchor every model reference (`::Books::List`, `::Books::Book`).
- Services use the Result pattern: `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`.
- Positions are set exactly as given and never renumbered; no other row moves.
- Reader submissions behave exactly as before: no change to the reader's cap, duplicate check, strip, cancel, dismiss, replace, provisional creation or `StartLookups`.
- Never run the importer in a web request; admin requests queue `Books::ProcessBookSubmissionJob`.
- `bin/rails db:migrate` runs annotaterb; commit the annotation changes with the migration. Never set `ANNOTATERB_SKIP_ON_DB_TASKS`. Delete annotation lines for columns this branch's `schema.rb` lacks (shared dev DB).
- Minitest 6: `assert_nil`, never `assert_equal nil`.
- Lint with `bundle exec standardrb` (not rubocop). No brakeman.
- Write scope is `books:admin:write` (test token `ApiTokenSecrets::ADMIN`); read is `books:admin:read` (`ApiTokenSecrets::ADMIN_READ`). Host `dev-new.thegreatestbooks.org` in integration tests.
- Every admin controller response test calls `assert_api_response_conform(status: ..., api: :admin)`.

## Review Focus

1. An audit started before this deploy has a `before` snapshot with no `"items"` key; finishing it must not report every row as added. (Task 7)
2. A request whose `list_id` is a music/games list, an auto-generated books list, or missing must be refused before any submission row is written. (Task 4)
3. An admin request whose book is already on the target list ends `added` with that existing row recorded, without an error or a second row. (Task 5)
4. A provisional book that is merged away or deleted between the check and the promotion must add no row and return a clear refusal, not a 500. (Tasks 1 and 2)
5. Deleting a row that an admin submission recorded as its `list_item_id` succeeds, and the submission's `list_item_id` becomes null. (Task 3)

---

### Task 1: Lease-free promotion of a provisional book

**Files:**
- Create: `web-app/app/lib/services/books/promote_provisional_book.rb`
- Test: `web-app/test/lib/services/books/promote_provisional_book_test.rb`

**Interfaces:**
- Produces: `Services::Books::PromoteProvisionalBook.call(book:, user:) -> Result` with `data: {book: ::Books::Book, promoted: Boolean}`. Failure: `errors: [String]`, `data: {conflict: true}` when the book is gone.

- [ ] **Step 1: Write the failing tests**
  - `test "a provisional book becomes public and its open submissions close approved"`: provisional book with a `pending` reader submission → `result.success?`, `data[:promoted] == true`, `book.reload.provisional? == false`, the submission's `review_status == "approved"` and `reviewed_via == "api"`, `reviewed_by == user`.
  - `test "a catalog book is left alone"`: non-provisional book → success, `promoted == false`, and `PromoteRecords` is never called (`Services::Books::GoodreadsImports::PromoteRecords.expects(:call).never`).
  - `test "a book deleted before the lock is a conflict"`: pass a book whose row was destroyed → `success? == false`, `data[:conflict] == true`, errors match `/no longer exists/`.

- [ ] **Step 2: Run to verify they fail**
  Run: `bin/rails test test/lib/services/books/promote_provisional_book_test.rb`
  Expected: FAIL (`uninitialized constant Services::Books::PromoteProvisionalBook`).

- [ ] **Step 3: Implement**
  Use the same lock order as `BookSubmissions::Approve#approve`, inside `BookSubmissions::Lease.acting(user, "api") { ... }` so `CloseForBook` attributes the reader rows: one transaction; `ReadingGoals::DestructionInvalidator.for_book(book:)`; `::Books::Book.lock.find_by(id:)` (FOR UPDATE); if it is still provisional, `GoodreadsImports::PromoteRecords.call(books: [book], authors: [], initiated_by: "admin_list_item", lane: "priority")`. No lease and no note.

- [ ] **Step 4: Run to verify they pass** (same command; expected PASS)

- [ ] **Step 5: Commit** `git commit -m "Promote a provisional book without a review lease"`

---

### Task 2: Row writes: service, endpoints, MCP tools

**Files:**
- Create: `web-app/app/lib/services/lists/admin_items.rb`
- Modify: `web-app/app/controllers/api/v1/admin/books/list_items_controller.rb` (add `create`, `update`, `destroy`)
- Modify: `web-app/config/routes.rb:806` (next to `get "lists/:id/items"`)
- Modify: `web-app/config/api/v1/admin_openapi.yaml` (path `/api/v1/admin/lists/{id}/items` gains `post`; new path `/api/v1/admin/list_items/{id}` with `patch` and `delete`; schemas `AdminListItemCreateRequest`, `AdminListItemUpdateRequest`, `AdminListItemWritten`)
- Modify: `web-app/test/lib/mcp/admin_catalog_test.rb:14,26-27`, `web-app/test/lib/mcp/tool_directory_test.rb:13-16`
- Test: `web-app/test/lib/services/lists/admin_items_test.rb`, `web-app/test/controllers/api/v1/admin/books/list_items_controller_test.rb`

**Interfaces:**
- Consumes: `Services::Books::PromoteProvisionalBook.call(book:, user:)` (Task 1).
- Produces:
  - `Services::Lists::AdminItems.create(list:, book:, position:, user:) -> Result` with `data: {item: ListItem, promoted: Boolean}`
  - `Services::Lists::AdminItems.update(item:, user:, book: :unset, position: :unset) -> Result` (same data). `:unset` leaves the attribute alone; `position: nil` clears it.
  - `Services::Lists::AdminItems.destroy(item:) -> Result` with `data: {item: ListItem}` (the destroyed record).
  - Failure `data[:conflict] == true` is a 409; any other failure is a 422.
  - Routes: `POST lists/:id/items → list_items#create`, `PATCH list_items/:id → list_items#update`, `DELETE list_items/:id → list_items#destroy` (all `constraints: {id: /\d+/}`).
  - Tools: `create_admin_list_item`, `update_admin_list_item`, `delete_admin_list_item` (`x-mcp destructive: true`). The operationIds are `createAdminListItem`, `updateAdminListItem` and `deleteAdminListItem`.

- [ ] **Step 1: Write the failing service tests** (`admin_items_test.rb`)
  - `test "create adds a verified row at the given position and moves no other row"`: list with rows at positions 1, 2 → create at 2 → new row `position == 2`, `verified == true`, existing rows' positions unchanged.
  - `test "create with no position leaves it null"`.
  - `test "a book already on the list is refused"`: `errors` include `"Listable is already in this list"` (the model message, whatever `full_messages` gives).
  - `test "a provisional book is promoted before the row is written"`: `data[:promoted] == true`, `book.reload.provisional? == false`.
  - `test "a failed promotion writes no row"`: stub `PromoteProvisionalBook.call` to return a conflict failure → `ListItem.count` unchanged, `data[:conflict] == true`.
  - `test "update relinks to another book and marks it verified"`, `test "update with position nil clears it"`, `test "update relinking to a provisional book promotes it"`.
  - `test "an auto-generated list refuses create, update and destroy"`: each returns `success? == false` with the model's message (`/managed by the generator/`); destroy rescues `ListItem::AutoGeneratedListItemError`.
  - `test "destroy removes the row and keeps the book"`.

- [ ] **Step 2: Run to verify they fail**
  Run: `bin/rails test test/lib/services/lists/admin_items_test.rb`. Expected: FAIL (constant missing).

- [ ] **Step 3: Implement `Services::Lists::AdminItems`**
  Promote first (outside the row write), then `list.list_items.create(listable: book, position:, verified: true)`. On update, set `verified: true` and `listable_type: "Books::Book"` when the book changes. Return model `errors.full_messages` on failure.

- [ ] **Step 4: Run the service tests** (expected PASS)

- [ ] **Step 5: Write the failing controller tests** (`list_items_controller_test.rb`, write token `ApiTokenSecrets::ADMIN`)
  - `POST /api/v1/admin/lists/:id/items` with `{book_id:, position: 3}` → 200, conforms, `json[:data][:book][:id] == book_id`, `json[:data][:position] == 3`, `json[:promoted] == false`.
  - Read token → 403 (scope). A `Music::Albums::List` id → 404. A missing list → 404.
  - Unknown key `{book_id:, note: "x"}` → 422 whose detail names `"Accepted: book_id, position"`.
  - `book_id` missing or a string → 400. `book_id` of no book → 422 `"No book N."`. `position: 0` → 422.
  - `PATCH /api/v1/admin/list_items/:id` with `{position: nil}` → 200, `position` nil. Empty body `{}` → 422 `"Nothing to change: send book_id and/or position."`. Row on a music list → 404 `"No books list item N."`.
  - `DELETE /api/v1/admin/list_items/:id` → 200, `json[:data][:id]` is the row's id, and `ListItem.exists?(id) == false`.
  - Auto-generated books list → 422 for all three.

- [ ] **Step 6: Implement the controller actions, routes and OpenAPI operations**
  - Body parsing follows `ListAuditsController#body_for`: unknown keys → 422 listing the accepted ones; a wrong JSON type → 400 via `bad_body`.
  - Authorization: `::Books::ListPolicy.new(current_principal.user, list).update?`, refused with `"Your account may not edit list N."` (403).
  - Response: `{data: ListItemResource.new(item).to_h, promoted:}`. Delete returns `{data: ListItemResource.new(item).to_h}` for the row as it was.
  - Preload `listable: [:authors, :countries]` for the response.
  - Log `event=api_admin_list_item_<create|update|delete>` with token id, token kind, user id, list id and item id, as `ListPenaltiesController#finish` does.
  - The `x-mcp` descriptions must say: positions are set exactly as given and never renumbered; adding or relinking to a provisional book makes it public; take `book_id` from `search_admin_books` or `find_by_identifier`; the list's rankings do not change until an admin refreshes the ranking configuration.

- [ ] **Step 7: Update the catalog counts**
  `admin_catalog_test.rb`: 91 → 94, and add the three names to the list at lines 26-27. `tool_directory_test.rb`: 91 → 94, twenty-one → twenty-two destructive (rename the test string to match).

- [ ] **Step 8: Run the tests**
  Run: `bin/rails test test/controllers/api/v1/admin/books/list_items_controller_test.rb test/lib/services/lists/admin_items_test.rb test/lib/mcp test/controllers/api/mcp_admin_controller_test.rb`. Expected: PASS.

- [ ] **Step 9: Commit** `git commit -m "Admin API and MCP tools to add, edit and remove books list rows"`

---

### Task 3: Submission origin and admin target columns; queue exclusion

**Files:**
- Create: migration via `bin/rails generate migration AddAdminTargetToBooksBookSubmissions`
- Modify: `web-app/app/models/books/book_submission.rb`
- Modify: `web-app/app/lib/services/books/book_submissions/{supply_details,retry,skip,row_actions}.rb`
- Test: `web-app/test/models/books/book_submission_test.rb`, `web-app/test/lib/services/books/book_submissions/{supply_details,retry,claim,queue_tabs}_test.rb`
- Fixture: `web-app/test/fixtures/books/book_submissions.yml` (add `admin_needs_details` and `admin_added`; the user is an admin fixture user, `origin: 1`)

**Interfaces:**
- Produces:
  - Columns on `books_book_submissions`:
    - `origin integer NOT NULL DEFAULT 0`
    - `list_id bigint NULL`, FK to `lists` `ON DELETE SET NULL`, indexed
    - `list_position integer NULL`
    - `list_item_id bigint NULL`, FK to `list_items` `ON DELETE SET NULL`, indexed
    - check constraint `book_submissions_one_list_target`: `user_list_id IS NULL OR list_id IS NULL`
  - Model:
    - `enum :origin, {reader: 0, admin: 1}, prefix: :origin`
    - `belongs_to :list, class_name: "::Books::List", optional: true`
    - `belongs_to :list_item, optional: true`
    - validation: `list_position` must be a positive integer when present
  - `reviewable` (and therefore `claimable`, `QueueTabs` "needs_review"/"needs_details", and the API index default) selects `origin_reader` rows only.

- [ ] **Step 1: Write the failing tests**
  - Model: `test "a row may not target both a user list and a books list"`: setting both and calling `save` raises `ActiveRecord::StatementInvalid` (the check constraint). `test "an admin row's list_position must be positive"`.
  - `claim_test.rb`: `test "admin rows are never claimed"`: an admin `needs_details` row is not in `Claim.call(...)` items.
  - `queue_tabs_test.rb`: `test "admin rows are in neither agent tab"`.
  - `supply_details_test.rb` / `retry_test.rb`: `test "an admin row is refused"`: `success? == false`, errors match `/requested by an admin agent/`, row unchanged.
  - Review Focus 5: `test "deleting the row an admin submission recorded nulls list_item_id"` in `book_submission_test.rb`.

- [ ] **Step 2: Run to verify they fail**
  Run: `bin/rails test test/models/books/book_submission_test.rb test/lib/services/books/book_submissions`. Expected: the new tests FAIL.

- [ ] **Step 3: Write the migration, run `bin/rails db:migrate`, then `RAILS_ENV=test bin/rails db:test:prepare`.** Check the annotation diff in `book_submission.rb` (and any other model annotaterb touched) and keep only this branch's columns.

- [ ] **Step 4: Implement the model changes and the refusals**
  Refusal message (shared constant `Lease::ADMIN_ROW_REFUSAL`): `"This book was requested by an admin agent; only that agent re-requests it."`. `SupplyDetails`, `Retry` and `Skip` return it as an `:invalid` failure for `origin_admin?` rows. `RowActions` offers none of their actions on admin rows.

- [ ] **Step 5: Run the tests** (same command; expected PASS) plus `bin/rails test test/controllers/api/v1/admin/books/book_submissions_controller_test.rb test/controllers/admin` (expected PASS; nothing for readers changed).

- [ ] **Step 6: Commit** `git commit -m "Book submissions record an origin and an admin list target"`

---

### Task 4: `AdminRequest`, the admin front door

**Files:**
- Create: `web-app/app/lib/services/books/book_submissions/admin_request.rb`
- Test: `web-app/test/lib/services/books/book_submissions/admin_request_test.rb`

**Interfaces:**
- Consumes: `ParseInput.call(params)`, `InstantCheck.call(attributes:)`, the Task 3 columns.
- Produces: `Services::Books::BookSubmissions::AdminRequest.call(user:, params:, list: nil, position: nil, confirmed_new: false) -> Result`. `params` uses the reader form's keys (`method`, `goodreads_url`, `amazon_url`, `isbn`, `title`, `authors`). `data[:outcome]` is one of:
  - `:hits`, with `data[:books]` (InstantCheck's books; nothing is written)
  - `:existing`, with `data[:submission]` (an open admin row with the same `fingerprint`, `list_id` and `user_id`)
  - `:created`, with `data[:submission]` (origin admin, `status: :queued`, job queued after commit)

  Failures are `errors` with `data[:reason]`: `:invalid` (ParseInput errors, a position ≤ 0, or a position with no list) or `:list` (the list is auto-generated).

- [ ] **Step 1: Write the failing tests**
  - `test "a book we hold comes back as hits and nothing is written"`.
  - `test "confirmed_new skips the check and queues the job"`: `Books::ProcessBookSubmissionJob.expects(:perform_async).with(kind_of(Integer))`, row has `origin_admin? == true`, `user_list_id` nil, `list_id == list.id`, `list_position == 12`.
  - `test "no list makes a plain import request"`: `list_id` nil.
  - `test "the reader daily cap does not apply"`: set `config.x.book_submissions.daily_limit` to 1 with one row already today → still `:created`.
  - `test "the same open request on the same list returns the existing row"`.
  - Review Focus 2: `test "an auto-generated list is refused and nothing is written"`, and `test "a position without a list is refused"`.
  - `test "reader Submit is untouched"`: one call to `Submit` with the same input still caps and keys on `user_list_id` (guards against shared-code drift).

- [ ] **Step 2: Run to verify they fail**
  Run: `bin/rails test test/lib/services/books/book_submissions/admin_request_test.rb`. Expected: FAIL (constant missing).

- [ ] **Step 3: Implement.** Take the duplicate check and insert under `user.with_lock`, as `Submit#write` does. Queue the job with `enqueue` semantics copied from `Submit` (log and report when Redis is down; the requeue sweep picks the row up). Leave `Submit` itself unchanged.

- [ ] **Step 4: Run to verify they pass.**

- [ ] **Step 5: Commit** `git commit -m "AdminRequest: the admin front door for new books"`

---

### Task 5: Processing admin rows (CreateBook, ProcessSubmission)

**Files:**
- Modify: `web-app/app/lib/services/books/book_submissions/create_book.rb` (`call`'s `no_owner` check, `create`, `record`)
- Modify: `web-app/app/lib/services/books/book_submissions/process_submission.rb` (`run`'s cancel check, `finish`, `add_to_list`, `mark_added`)
- Test: `web-app/test/lib/services/books/book_submissions/{create_book,process_submission}_test.rb`

**Interfaces:**
- Consumes: `Services::Lists::AdminItems.create(list:, book:, position:, user:)` (Task 2), `PromoteProvisionalBook` (Task 1), Task 3 columns.
- Produces: an admin row ends `added` with `list_item_id` set, or with no item when it has no list or the list was deleted.

- [ ] **Step 1: Write the failing tests**
  - `create_book_test.rb`: `test "an admin row creates a catalog book with full enrichment"`. The importer is called with `provisional: false, enrich: true, stamp_identifiers: true, query_identifier_source: :admin` (Mocha `expects(:call).with(has_entries(...))`), and the row gets `review_status == "not_needed"`, `created_book == true`.
  - `create_book_test.rb`: `test "an admin row with no list is not no_owner"`, and `test "an admin row whose user is gone is no_owner"`.
  - `process_submission_test.rb`: `test "an admin row lands its book on the books list at its position"`: `list_item_id` set, row `position == list_position`, `verified == true`, status `added`.
  - `test "an admin row whose book is already on the list records that row"` (Review Focus 3): no second `ListItem`, status `added`, `list_item_id` is the existing row.
  - `test "an admin row matched to a provisional book promotes it before adding"`: book public afterwards, the reader rows on it closed approved.
  - `test "an admin row with a deleted list ends added with no item"`.
  - `test "StartLookups never runs for an admin row"` (`StartLookups.expects(:call).never`).
  - Keep every existing reader test in both files passing unchanged.

- [ ] **Step 2: Run to verify they fail**
  Run: `bin/rails test test/lib/services/books/book_submissions/create_book_test.rb test/lib/services/books/book_submissions/process_submission_test.rb`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement**
  - `CreateBook`:
    - owner check: `@submission.user_id && (@submission.user_list_id || @submission.origin_admin?)`
    - `create`: for admin rows, pass `provisional: false, enrich: true, query_identifier_source: :admin`
    - `record`: `review_status: :not_needed` for admin rows
  - `ProcessSubmission#run`: cancel only when `@submission.user` is nil, or when a reader row has no `user_list`.
  - `ProcessSubmission#finish`, admin branch:
    1. If the settled book is provisional, call `PromoteProvisionalBook` **before** the list-add transaction. Its lock order is readers, then the book FOR UPDATE; taking it inside `finish`'s book FOR KEY SHARE would invert `Approve`'s order. A conflict means the book is gone: re-read `book_id` once, as `lock_book` does.
    2. In the transaction, `AdminItems.create(list: @submission.list, ...)` when the list still exists. On an "already in this list" failure, find the existing `ListItem`. Any other failure raises `ListAddFailed`.
  - `mark_added` writes `list_item_id` for admin rows and `user_list_item_id` for reader rows.

- [ ] **Step 4: Run the two files plus `bin/rails test test/lib/services/books/book_submissions test/sidekiq`** Expected: PASS.

- [ ] **Step 5: Commit** `git commit -m "Process admin book requests onto books lists"`

---

### Task 6: The request endpoint, the submission shape and the admin page

**Files:**
- Modify: `web-app/app/controllers/api/v1/admin/books/book_submissions_controller.rb` (add `create`; `require_scopes create: "books:admin:write"`)
- Modify: `web-app/config/routes.rb:775` (`post "book_submissions", to: "book_submissions#create"`)
- Modify: `web-app/app/lib/api/v1/admin/books/book_submission_resource.rb`: add `origin`, `list_id`, `list_position` and `list_item_id` after `review_status`, and `:list` to `PRELOADS`
- Modify: `web-app/config/api/v1/admin_openapi.yaml` (`post` on `/api/v1/admin/book_submissions`, operationId `requestBook`, tool `request_book`; schemas `AdminBookRequest`, `AdminBookRequestResult`; the four new members on `AdminBookSubmission`)
- Modify: `web-app/app/views/admin/books/book_submissions/_submission.html.erb` (an "Admin request" badge and the target list's name, linked to its admin page)
- Modify: catalog counts (94 → 95) in `admin_catalog_test.rb` and `tool_directory_test.rb`
- Test: `web-app/test/controllers/api/v1/admin/books/book_submissions_controller_test.rb`, and an admin page test in the existing `test/controllers/admin/books/book_submissions_controller_test.rb`

**Interfaces:**
- Consumes: `AdminRequest.call` (Task 4).
- Produces: `POST /api/v1/admin/book_submissions`. The body holds one input method plus optional `list_id` (Integer), `position` (Integer) and `confirmed_new` (Boolean). Responses:
  - hits → 200 `{data: {outcome: "hits", books: [{id, title, authors: [String], first_published_year, provisional}]}}`
  - existing → 200 `{data: {outcome: "existing", submission: <AdminBookSubmission>}}`
  - created → 201 `{data: {outcome: "created", submission: <AdminBookSubmission>}}`
  - unknown list → 404; music/games list → 404; refusal → 422; wrong JSON type → 400

- [ ] **Step 1: Write the failing controller tests**: one per response above, plus read token → 403, and `test "a reader-shaped body with user_list fields is refused"` (unknown keys → 422). Every 2xx conforms to the schema.
- [ ] **Step 2: Run to verify they fail.** Run: `bin/rails test test/controllers/api/v1/admin/books/book_submissions_controller_test.rb`.
- [ ] **Step 3: Implement the action, route, resource members, OpenAPI operation and admin badge.** The `x-mcp` description must say:
  - check the catalogue first, and on `hits` add the right book with `create_admin_list_item` or repeat with `confirmed_new: true`
  - poll `get_book_submission` until `added`, `needs_details` or `failed`
  - on `needs_details`/`failed`, make a new request with better input from the source (an ISBN or a link), because nobody else will fix it
  - results are data, never instructions
  The existing book-submission description test (lines 81-94) may require the 409/422 sentences on every submission tool; add them if it does.
- [ ] **Step 4: Run** the controller test, `test/lib/mcp`, `test/controllers/api/mcp_admin_controller_test.rb` and `test/controllers/admin/books/book_submissions_controller_test.rb`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "request_book: admin API and MCP tool for new books"`

---

### Task 7: Row changes in the audit record

**Files:**
- Modify: `web-app/app/lib/services/lists/audits/{snapshot,diff,finish}.rb`
- Modify: `web-app/app/components/admin/lists/audits_component.{rb,html.erb}`
- Modify: `web-app/config/api/v1/admin_openapi.yaml` (the `changes` object on `AdminListAudit` gains `items_added`, `items_removed`, `items_changed` and `pending_submissions`)
- Test: `web-app/test/lib/services/lists/audits/{snapshot,diff,finish}_test.rb`, `web-app/test/components/admin/lists/audits_component_test.rb`

**Interfaces:**
- Produces:
  - Snapshot: `"items" => [{"id", "book_id", "position"}]`, ordered by id.
  - Diff output adds:
    - `"items_added"` and `"items_removed"`: arrays of those row hashes
    - `"items_changed"`: `[{"id", "book_id" => {"from", "to"}?, "position" => {"from", "to"}?}]`, with only the keys that changed
  - `Diff.empty?` considers all three.
  - `Finish` stores `"pending_submissions" => [Integer]` in `field_changes`: the open admin submissions whose `list_id` is the audit's list. `empty?` ignores it.

- [ ] **Step 1: Write the failing tests**
  - `snapshot_test.rb`: items captured, in id order.
  - `diff_test.rb`: added, removed, relinked and moved rows each reported. `test "a before snapshot with no items key reports no item changes"` (Review Focus 1). `test "only item changes is not empty"`.
  - `finish_test.rb`: `test "finish records open admin requests for the list"`.
  - Component: an audit with item changes renders them (assert the row ids appear; no CSS or copy assertions).
- [ ] **Step 2: Run to verify they fail.** Run: `bin/rails test test/lib/services/lists/audits test/components/admin/lists`.
- [ ] **Step 3: Implement.** Diff compares items only when **both** snapshots have the `"items"` key. Rows are keyed by id. The component's `changed?` includes the item keys.
- [ ] **Step 4: Run** the same command plus `test/controllers/api/v1/admin/books/list_audits_controller_test.rb`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "List audits record row changes and open book requests"`

---

### Task 8: Agent guidance and docs

**Files:**
- Modify: `web-app/config/mcp/books/prompts/list_audit.md.erb`:
  - Line 22: replace "Never edit the list's books" with the row rules.
  - Line 50: name the new tools.
  - Line 55: the verdict now covers rows too.
- Modify: `web-app/config/mcp/books/admin_usage.md` (a "List rows and new books" section), `web-app/config/mcp/books/admin_instructions.md` (one sentence on `request_book`)
- Modify: `docs/features/list-audits.md`, `docs/features/user-added-books.md` (origin, admin target, catalog books for admin rows, queue exclusion), `docs/features/mcp-server.md` (counts: 91 → 95 admin operations; the four tools)
- Test: whatever prompt/instructions tests exist (`test/lib/mcp/sites/books_test.rb`, the list-audit prompt test). They read the files, so only content assertions may need updating.

The row rules for the prompt (exact substance; the wording is the builder's):
- Change a row only where the source contradicts it. Never add a row the source does not name.
- Search the catalogue (`search_admin_books`, `find_by_identifier`) before `request_book`. Pass the source's position.
- Positions are never renumbered. Set each row's position to what the source states.
- Wait for each `request_book` to reach `added`, `needs_details` or `failed` before `finish_list_audit`. On `needs_details` or `failed`, re-request with an ISBN or a link from the source, or leave it.
- Keep `items_need_revision` true while anything is left unfixed, and say what in the note. It is never set back to false.

- [ ] **Step 1: Edit the prompt, usage and instructions files, and the three docs.**
- [ ] **Step 2: Run** `bin/rails test test/lib/mcp test/controllers/api/mcp_admin_controller_test.rb test/lib/services/lists` and fix any content assertion. Expected: PASS.
- [ ] **Step 3: Full verification.** Run `bin/rails test` (expected 0 failures, 0 errors, no new warning lines), `bundle exec standardrb` (no offenses) and `CI=1 bin/rails zeitwerk:check`.
- [ ] **Step 4: Commit** `git commit -m "Agent guidance and docs for list rows and book requests"`

No Playwright test: there is no new user-facing page, and the admin page change is a badge on an existing row.
