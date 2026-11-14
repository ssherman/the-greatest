# Admin MCP: Book Authors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the admin API and MCP add, update and remove a book's authors, exactly as the admin book page does.

**Architecture:** One service, `Services::Books::BookAuthors::Edit`, holds the add/update/remove rules. The admin page controller (`Admin::Books::BookAuthorsController`) and a new API controller (`Api::V1::Admin::Books::BookAuthorsController`) both call it. Three OpenAPI operations with x-mcp blocks become MCP tools automatically through `Mcp::Catalog`.

**Tech Stack:** Rails 8, Minitest + fixtures, Alba resources, OpenAPI 3 (`config/api/v1/admin_openapi.yaml`).

**Spec:** `docs/superpowers/specs/2026-11-14-admin-mcp-book-authors-design.md`

## Global Constraints

- All Rails commands run from `web-app/`. Lint is `bundle exec standardrb`. Never run brakeman.
- Endpoints, tool names (from x-mcp `name`, else the underscored operationId):
  - `POST /api/v1/admin/books/{id}/authors` → operationId `addBookAuthor` → `add_book_author`
  - `PATCH /api/v1/admin/books/{id}/authors/{author_id}` → `updateBookAuthor` → `update_book_author`
  - `DELETE /api/v1/admin/books/{id}/authors/{author_id}` → `removeBookAuthor` → `remove_book_author`
- All three: security `books:admin:write`, plus `::Books::BookPolicy#update?` on the book (403 otherwise). `remove_book_author` has `x-mcp: destructive: true`; the other two do not.
- Admin catalogue goes 46 → 49; destructive tools 13 → 14.
- Writable fields: `role` (enum names `author`, `editor`), `position` (positive integer, or `null`), `credited_as` (string, or `null`; blank/whitespace stores nil). `author_id` only on add.
- Add: `position` defaults to `(max position on the book, nil counted as 0) + 1`. Author already on the book → 422 whose detail says to use `update_book_author`. Unknown author id → 422.
- Update: partial; empty body → 400; unknown key or unknown role → 422; wrong JSON type → 400; book lacks that author → 404.
- Remove: book lacks that author → 404. Removing the last author is allowed.
- Status mapping elsewhere: no such book → 404; non-integer path id is rejected by the route constraint (`/\d+/`).
- Every success responds `{data: [<entry>, ...]}`, the book's full author list ordered by `position` (nulls last), then row id. Entry keys in this order: `id`, `slug`, `name` (the author), `role`, `position`, `credited_as`.
- `get_admin_book`'s `authors` entries use the same entry shape and order.
- Body parsing reads `request.raw_post.to_s` (not params), as `FieldUpdate#json_body` does, so `null` is preserved and ParamsWrapper is avoided.
- Controller tests assert behaviour (status, records, JSON keys), never copy.
- Never commit to main. Never set ANNOTATERB_SKIP_ON_DB_TASKS (no migration in this plan).

## Review Focus

1. Update sending `{"position": null}` or `{"credited_as": null}` must clear the field, not be ignored or 400 → Task 2 test `update clears credited_as and position with null`.
2. An add without a position on a book whose existing rows all have `position: nil` must give position 1, not crash on `nil + 1` → Task 1 test `add defaults position to 1 when existing rows have none`.
3. A `role` given as an integer (`0`) or a non-enum string must not reach `update!` and raise `ArgumentError` (500) → Task 2 tests `wrong-type role is 400` and `unknown role is 422`.
4. The page's create form posts `position` as `""` when left blank; that must default to the end, not store nil → Task 1 test via the page controller `create without position appends`.
5. Adding/updating with `position: 0` or negative must be refused (400), since the page form has `min: 1` → Task 2 test `position must be a positive integer`.

---

### Task 1: Shared service and page controller

**Files:**
- Create: `web-app/app/lib/services/books/book_authors/edit.rb`
- Modify: `web-app/app/controllers/admin/books/book_authors_controller.rb`
- Test: `web-app/test/lib/services/books/book_authors/edit_test.rb`, `web-app/test/controllers/admin/books/book_authors_controller_test.rb`

**Interfaces:**
- Produces:
  - `Services::Books::BookAuthors::Edit.add(book:, author_id:, attrs: {}) -> Result`
  - `Services::Books::BookAuthors::Edit.update(book:, author_id:, attrs:) -> Result`
  - `Services::Books::BookAuthors::Edit.remove(book:, author_id:) -> Result`
  - `Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)`; `data` is the `Books::BookAuthor` row on success; `code` on failure is one of `:not_found` (book lacks the author, for update/remove), `:unprocessable` (duplicate, unknown author, validation failure). `attrs` keys are strings `"role"`, `"position"`, `"credited_as"`, already typed by the caller.
  - Duplicate message, exact: `"Author #{author_id} is already on this book. Use update_book_author to change the role, position or credited_as."`
  - Unknown author message: `"No author #{author_id}."`; not-on-book message: `"Book #{book.id} has no author #{author_id}."`

- [ ] **Step 1: Write failing service tests** in `edit_test.rb` (module `Services::Books::BookAuthors`, class `EditTest < ActiveSupport::TestCase`). Use fixtures `books_books(:war_and_peace)` (has `tolstoy` at position 1) and another author from `test/fixtures/books/authors.yml` that is not on it. Tests:
  - `add appends at the end by default` → new row position 2, role `author`.
  - `add defaults position to 1 when existing rows have none` → set existing row's position to nil first; new row position 1.
  - `add keeps a given role, position and credited_as`.
  - `add refuses an author already on the book` → `!success?`, code `:unprocessable`, error equals the duplicate message, no new row.
  - `add refuses an unknown author` → code `:unprocessable`, `"No author 999999999."`.
  - `add stores blank credited_as as nil`.
  - `update changes only the given fields` → update role to `editor`; position and credited_as unchanged.
  - `update with nil clears credited_as and position`.
  - `update on an author not on the book is not_found`.
  - `remove deletes the row and leaves the author record` ; `remove the last author is allowed` ; `remove on an author not on the book is not_found`.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/book_authors/edit_test.rb` — expect NameError failures.
- [ ] **Step 3: Implement the service.** Find the row by `book.book_authors.find_by(author_id:)`. Catch `ActiveRecord::RecordNotUnique` on add as the duplicate case too (race). Blank `credited_as` → nil. Do not wrap in extra callbacks: `BookAuthor`'s `after_commit` already queues the reindex.
- [ ] **Step 4: Run** the service test — PASS.
- [ ] **Step 5: Page controller uses the service.** `create` calls `Edit.add(book:, author_id: params[:books_book_author][:author_id], attrs:)`, where `attrs` is the permitted `role`, `position`, `credited_as` with a blank `position` dropped (so it defaults to the end) and a present one cast to integer. `update` keeps `set_book_author` (route is by row id), and calls `Edit.update(book: @book_author.book, author_id: @book_author.author_id, attrs:)`, where a blank `position` becomes nil. `destroy` calls `Edit.remove`. On failure, render the existing error turbo stream / alert with `result.errors.join(", ")`. Keep the existing responses and notices otherwise.
- [ ] **Step 6: Add page tests** to `book_authors_controller_test.rb`: `create without position appends` (posts `position: ""`, new row position is max+1) and `create of an author already on the book is unprocessable` (turbo_stream format → 422, no new row). Run the whole file — PASS.
- [ ] **Step 7: Commit** `Book authors: shared Edit service behind the admin page`.

---

### Task 2: API endpoints, MCP tools, get_admin_book fields, docs

**Files:**
- Create: `web-app/app/controllers/api/v1/admin/books/book_authors_controller.rb`, `web-app/app/lib/api/v1/admin/books/book_author_entry_resource.rb`
- Modify: `web-app/config/routes.rb` (admin API block, next to the `books/:id/categories` routes ~line 758), `web-app/config/api/v1/admin_openapi.yaml`, `web-app/app/lib/api/v1/admin/books/book_detail_resource.rb`, `web-app/config/mcp/books/admin_usage.md`, `docs/features/mcp-server.md`
- Test: `web-app/test/controllers/api/v1/admin/books/book_authors_controller_test.rb`, `web-app/test/controllers/api/v1/admin/books/books_controller_test.rb`, `web-app/test/integration/api/v1/admin_contract_coverage_test.rb`, `web-app/test/controllers/api/v1/admin/openapi_controller_test.rb`, `web-app/test/lib/mcp/admin_catalog_test.rb`, `web-app/test/lib/mcp/tool_directory_test.rb`, `web-app/test/controllers/api/mcp_admin_controller_test.rb`

**Interfaces:**
- Consumes: Task 1's `Services::Books::BookAuthors::Edit` and its `Result#code`.
- Produces: `Api::V1::Admin::Books::BookAuthorEntryResource` (Alba; built from a `Books::BookAuthor` with `author` loaded) rendering `id, slug, name, role, position, credited_as`; OpenAPI schema `AdminBookAuthor` with those properties.

- [ ] **Step 1: Write failing controller tests** (`BookAuthorsControllerTest < ActionDispatch::IntegrationTest`, follow `book_categories_controller_test.rb` for token headers). Cover:
  - add 200 returns the list with the new author last, position 2; add with `role: "editor", credited_as: "X"`.
  - add duplicate 422; add unknown author 422; add missing/non-integer `author_id` 400.
  - update role 200; `update clears credited_as and position with null`; empty body 400; unknown key 422; `unknown role is 422` (`"translator"`); `wrong-type role is 400` (`0`); `position must be a positive integer` (`0` → 400, `"2"` → 400); author not on book 404.
  - remove 200 and the row is gone; remove not on book 404; unknown book 404 for all three.
  - read token 403 on all three; a write token whose user fails `BookPolicy#update?` → 403 (follow how `book_categories_controller_test.rb` tests the policy, if it does; otherwise stub the policy with Mocha).
  - log line `event=api_admin_book_author action=<add|update|remove>` with token_id, user_id, book_id, author_id (assert presence of `event=api_admin_book_author` only).
- [ ] **Step 2: Run** — expect routing failures.
- [ ] **Step 3: Implement** routes (`post "books/:id/authors"`, `patch "books/:id/authors/:author_id"`, `delete "books/:id/authors/:author_id"`, constraints `/\d+/` on both ids, controller `book_authors`), the controller (include `::Api::V1::Admin::StrictIds`; `require_scope "books:admin:write"`; parse the body from `request.raw_post.to_s` the way `FieldUpdate#json_body` does — reuse that module if it fits without forcing its field-update flow, else a private copy of `json_body`; type-check each field and raise/return 400 via `::Api::Page::InvalidParameter` like `FieldUpdate#typed_value!`; check roles against `::Books::BookAuthor.roles.keys` for 422; map `Result#code` to `::Api::Problem`). Response `{data: book.book_authors.reload.includes(:author).sort_by { [position || Float::INFINITY, id] }.map { entry }}` — or an equivalent SQL `ORDER BY position NULLS LAST, id`.
- [ ] **Step 4: Run** the controller test — PASS.
- [ ] **Step 5: get_admin_book.** Change `BookDetailResource#authors` to render `BookAuthorEntryResource` for each of the book's `book_authors` in the same order. Add to `books_controller_test.rb`: show returns `role`, `position`, `credited_as` for war_and_peace's tolstoy (`"author"`, `1`, `"Lev Tolstoy"`).
- [ ] **Step 6: OpenAPI.** Add the two paths after `/api/v1/admin/authors/{id}/categories/{category_id}` (end of `paths`), each with `x-domain: books`, a summary, a description stating the rules in Global Constraints, an x-mcp block (description tells the agent: ids come from `get_admin_book` / `search_admin_authors`; a 422 on add for an existing author means use `update_book_author`; remove is the only way to drop a wrong author and re-adding it later restores it), `$ref` the `id` parameter and an `author_id` path parameter (add a component parameter if none exists), request bodies, and responses 200/400/401/403/404/422/429 as each operation can return them, with the rate-limit headers like neighbouring operations. Add `AdminBookAuthor` and make the `getAdminBook` response schema's `authors` items reference it.
- [ ] **Step 7: Pins and coverage.** Update counts 46 → 49 in `admin_catalog_test.rb`, `tool_directory_test.rb` (title text too; add `remove_book_author` to the destructive list, "fourteen destructive"), `mcp_admin_controller_test.rb`; append the two paths to `openapi_controller_test.rb`'s path list; add every documented status of the three operations to `admin_contract_coverage_test.rb`'s `EXERCISES` (use `books_books(:war_and_peace)` and `books_authors(:tolstoy)`; for 200 on add use an author not on the book; for 200 on remove, remove-then-the-test-transaction-rolls-back is fine). Add one MCP-level test in `mcp_admin_controller_test.rb` calling `add_book_author` through `tools/call` and asserting the row exists.
- [ ] **Step 8: Docs.** In `admin_usage.md`, add `add_book_author`, `update_book_author` and `remove_book_author` to the ask-first exemption sentence in "Match decisions and identifiers". In `docs/features/mcp-server.md`, add the three tools wherever the admin tool list and counts appear (46 → 49), with one line on keying by author id and the Goodreads-replay re-link gap from the spec.
- [ ] **Step 9: Verify** `bin/rails test test/controllers/api test/lib/mcp test/integration/api` and `bundle exec standardrb` — PASS / no offenses.
- [ ] **Step 10: Commit** `Admin API + MCP: add, update and remove book authors`.

---

## Finish

Full `bin/rails test` and `bundle exec standardrb` green before the final review. No E2E: there is no new page, and the page's only change (default position) is covered by its controller test.
