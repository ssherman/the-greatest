# Categories API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public read API for book categories, plus admin endpoints to search, create, update, tag/untag, merge and delete them, all through the same domain services the admin UI uses.

**Architecture:** One `categories` resource with a `type` filter. Public endpoints live in `Api::V1::Books` (scope `books:read`); admin endpoints in `Api::V1::Admin::Books` (scopes `books:admin:read|write|merge`). Rules now inside admin controllers move into services under `app/lib/categories/` (`Editor`, `ItemLinker`, merge preconditions), and the admin UI calls them too.

**Tech Stack:** Rails 8, ActionController::API, Alba, openapi_first, Minitest + fixtures + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-02-categories-api-design.md`. Also read `docs/features/public-api.md` (permission model, admin endpoints) and `docs/features/books-categories.md`.

## Global Constraints

- Rails commands run from `web-app/`. Docs live in project-root `docs/`.
- Controllers via `bin/rails generate controller <path> --skip-routes --no-helper --no-assets --no-template-engine`.
- Root-anchor every `::Books::`/`::Categories::` constant inside `Api::V1::*` and `Categories::*` modules.
- Admin endpoints use numeric ids; id params (path and body) are parsed strictly: a JSON integer or a `/\A\d+\z/` string parsed base-10, ≥ 1, else 400 `invalid_parameter`. Reuse the existing `parse_id` in `app/controllers/api/v1/admin/books/mergeable.rb` (extract it to a shared concern if a second controller needs it).
- Admin paths and the scopes `books:admin:*` never appear in `config/api/v1/openapi.yaml` or on `/developers` (existing test guards this).
- Never wrap `Categories::Merger#merge` or `Categories::Deleter#delete` in an outer transaction.
- Every new public operation and every new admin operation is in its document and in its contract coverage test (`contract_coverage_test.rb` / `admin_contract_coverage_test.rb`).
- Problem responses via `render_problem(::Api::Problem.new(code, detail:))`; existing codes only (`invalid_parameter` 400, `insufficient_scope`/`forbidden` 403, `not_found` 404, `unprocessable` 422).
- Done = `bin/rails test` green with no new warning lines, `bundle exec standardrb` clean, `CI=1 bin/rails zeitwerk:check` clean.

## Review Focus

1. **A slug that names a deleted, unmerged category** must 404 on public `show` and `/books`, not leak a deleted category. Test in Task 2.
2. **Tagging the same category twice** succeeds with no change, through the API and the admin UI (today the UI shows a uniqueness error). Test in Task 5.
3. **A batch merge whose target is also listed in `source_ids`, or with a duplicate source id**, is refused (422) before anything merges. Test in Task 7.
4. **Renaming a category to its own name with different case** ("fantasy" → "Fantasy") is not refused by the twin guard. Test in Task 4.
5. **`type=location` on the public list** returns locations (the site's word "settings" is a 400). Test in Task 2.

---

### Task 1: The `books:admin:write` scope

**Files:**
- Modify: `web-app/app/lib/api/scopes.rb`
- Test: `web-app/test/lib/api/scopes_test.rb`, `web-app/test/lib/services/api/authenticator_test.rb` (only if it pins merge's expansion)

**Interfaces:**
- Produces: scope `"books:admin:write"` — `admin: true`, `implies: ["books:admin:read"]`, eligible when `!user.service? && ::Books::BookPolicy.new(user, ::Books::Book).update?`, description "Create and edit book categories and tag books and authors". `"books:admin:merge"` changes to `implies: ["books:admin:write"]`.

- [ ] **Step 1: Failing tests**: write eligibility for global admin, global editor, books DomainRole editor/moderator/admin (eligible), books viewer, member, service account with admin role (not eligible); `Scopes.effective(["books:admin:merge"], admin)` includes `books:admin:write`, `books:admin:read`, `books:read`; registry order test updated to `["books:read", "music:read", "games:read", "books:admin:read", "books:admin:write", "books:admin:merge"]`.
- [ ] **Step 2: Run** `bin/rails test test/lib/api/scopes_test.rb` → FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** `bin/rails test test/lib/api/ test/lib/services/api/ test/controllers/developers/ test/integration/api/` → PASS (the tokens form now lists the new scope, unticked).
- [ ] **Step 5: Commit** `API scopes: books:admin:write; merge implies write`

---

### Task 2: Public category endpoints and their developer docs

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/books/categories_controller.rb`, `.../books/category_books_controller.rb`
- Create: `web-app/app/lib/api/v1/books/category_resource.rb`
- Modify: `web-app/config/routes.rb` (public books API block), `web-app/config/api/v1/openapi.yaml`, `web-app/test/integration/api/v1/contract_coverage_test.rb`, `web-app/app/views/developers/show.html.erb` (only if its prose lists the available resources), `web-app/test/controllers/developers_controller_test.rb`
- Test: generated controller tests

**Interfaces:**
- Routes: `get "categories", to: "categories#index"`, `get "categories/:slug", to: "categories#show", as: :category`, `get "categories/:slug/books", to: "category_books#index", as: :category_books` (inside `scope module: :books`).
- `Api::V1::Books::CategoryResource` (Alba): `id, slug, name, category_type, description, parent` (`{id, slug, name}` or null), `book_count` (from `params[:book_count]` or the row's `ranked_count`, default 0).
- `index`: `type` param — absent → `Books::BrowseQuery::TYPES.first`; present and not in `Books::BrowseQuery::TYPES` → 400 `invalid_parameter` "type must be one of genre, audience, location, subject"; `sort` same rule against `Books::BrowseQuery::SORTS`. Relation = `Books::BrowseQuery.categories(ranking_configuration: ::Books::RankingConfiguration.default_primary, type:, sort:)`, rendered with `render_ranked_page`, `book_count` = `row.ranked_count`. No primary configuration → empty page.
- `show` and `category_books#index` resolve the category with a private `public_category!(slug)`: `::Books::Category.active.find_by(slug:) || ::Books::CategorySlugResolver.call(slug)`, else raise `ActiveRecord::RecordNotFound` (model `Books::Category`). `show` computes `book_count` as the count of ranked items on the primary configuration whose book carries the category (one COUNT query).
- `category_books#index`: `::Books::RankedBooksQuery.call(ranking_configuration: primary, categories: [category])`, rendered exactly like `Api::V1::Books::BooksController#index` (same `BookResource`, rank param, envelope), path `/api/v1/categories/#{category.slug}/books`.
- OpenAPI: three operations tagged `x-domain: books`, with member-facing `summary`/`description` per spec §Documentation (what `type` accepts and that the site calls locations "settings"; old and merged slugs resolve; what `book_count` means; how `/categories/{slug}/books` relates to `/books`). Responses: index 200/400/401/403/429; show 200/401/403/404/429; books 200/400/401/403/404/429.

- [ ] **Step 1: Failing tests**:
  - index returns the same ids, in order, as `BrowseQuery.categories` for `type=subject`; `type=settings` → 400; `type=location` → 200 with locations; `sort=name` orders by name.
  - show by current slug, by a friendly_id history slug, by a merged category's slug (returns the target) → 200 with the live id; a deleted, unmerged category's slug → 404; a theme category → 200 (show accepts any active books category); `book_count` equals ranked books carrying it.
  - category books returns only books in the category, in rank order, with the `/books` item shape; unknown slug → 404; `page=0` → 400.
  - developers page test: the three operation paths appear on `/developers`.
  - public document still contains no `/api/v1/admin` (existing test stays green).
  - contract coverage entries for every documented response.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/ test/integration/api/ test/controllers/developers_controller_test.rb` → FAIL.
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run** the same + `CI=1 bin/rails zeitwerk:check` → PASS. Then `yarn build:all`, start `bin/rails server` (check port 3000 is this worktree's first, per AGENTS.md), open `https://dev-new.thegreatestbooks.org/developers` and confirm the three operations render with their descriptions; stop the server.
- [ ] **Step 5: Commit** `Public API: categories list, show and ranked books`

---

### Task 3: Admin category search and detail

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/admin/books/categories_controller.rb` (index, show only in this task)
- Create: `web-app/app/lib/api/v1/admin/books/category_resource.rb`
- Modify: `web-app/config/routes.rb` (admin block), `web-app/config/api/v1/admin_openapi.yaml`, `web-app/test/integration/api/v1/admin_contract_coverage_test.rb`
- Test: generated controller test

**Interfaces:**
- Routes (admin books block): `get "categories", to: "categories#index"`, `get "categories/:id", to: "categories#show", constraints: {id: /\d+/}`.
- `Api::V1::Admin::Books::CategoryResource` (Alba): public fields + `alternative_names, deleted, merged_into` (`{id, name}` or null), `item_count`, `book_link_count`, `author_link_count`, `children_count`, `import_source, created_at, updated_at`. Trait `:full` adds `children` (`[{id, slug, name}]`) and `ancestors` (location chain, root first; `[]` otherwise). Per-page link and children counts come in through `params` (one grouped query each per page).
- `index`: `q` optional; `type` optional, any `Category.category_types` key valid for books (`genre location subject theme audience`), else 400; `status` in `active` (default) `deleted` `merged` `all`, else 400. Base scope `::Books::Category`; `deleted` = `deleted: true, merged_into_id: nil`; `merged` = `.merged`. With `q`: `where(CategorySearchQuery::NAME_OR_ALIAS_SQL, pattern:)` ordered by `Books::BrowseQuery.name_match_quality_sql(q, escaped)` then name (make `name_match_quality_sql` public if it is private). Without `q`: ordered by name. Paginated with `render_page(..., query: {q:, type:, status:}.compact)`.
- `show`: `::Books::Category.find(id)` (any status), `:full` trait.

- [ ] **Step 1: Failing tests**: `q` matches a name substring and an alternative-name substring; exact match ranks above prefix above substring; `status=merged` returns only merged; `status=bogus` → 400; `type=theme` ok, `type=game_mode` → 400; member token → 403 `insufficient_scope`; viewer `ADMIN_READ` token → 200; show includes children and the ancestor chain for a nested location; paging links carry `q`; contract coverage entries.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/admin/ test/integration/api/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** same + zeitwerk → PASS.
- [ ] **Step 5: Commit** `Admin API: category search and detail`

---

### Task 4: Create and update categories

**Files:**
- Create: `web-app/app/lib/categories/editor.rb`, `web-app/app/lib/categories/name_guard.rb`
- Modify: `web-app/app/controllers/admin/books/categories_controller.rb` (`update` calls `Categories::Editor`), `web-app/app/controllers/api/v1/admin/books/categories_controller.rb` (create, update), routes, admin OpenAPI, admin coverage test
- Test: `web-app/test/lib/categories/editor_test.rb`, `.../name_guard_test.rb`, admin API controller test, existing `test/controllers/admin/books/categories_controller_test.rb` stays green

**Interfaces:**
- `Categories::Editor.call(category:, attributes:) -> Result` (`Result = Struct.new(:success?, :data, :errors, keyword_init: true)`): assigns, saves; on success enqueues `::Categories::ReconcileAncestorsJob.perform_async` when `(saved_change_to_parent_id? || saved_change_to_category_type?) && (location? || category_type_before_last_save == "location")`; data = category; errors = `category.errors.full_messages`. Works for a new record too (create).
- `Categories::NameGuard.conflict(category) -> Category | nil`: another active category of the same STI `type` (`id != category.id`) whose `LOWER(name) = LOWER(category.name)` or whose `alternative_names` contains it case-insensitively. Returns nil when the name is unchanged except for case on a persisted category (Review Focus 4).
- API: `POST /api/v1/admin/categories` and `PATCH /api/v1/admin/categories/{id}`, scope `books:admin:write`, policy `Books::CategoryPolicy#create?` / `#update?` on the record (403 `forbidden` otherwise). Body keys `name, category_type, description, alternative_names (array of strings), parent_id`; unknown keys ignored; `category_type` must be a books type (`genre location subject theme audience`) else 400. NameGuard conflict → 422 `unprocessable` "Another category already uses that name: #{id} (name|alias)". Editing a deleted or merged category → 422. Editor failure → 422 with its messages. Success: create 201, update 200, admin `:full` shape.
- Admin UI `update` keeps its responses; only the save+enqueue moves into `Editor`. The UI does not use NameGuard.

- [ ] **Step 1: Failing tests**: Editor enqueues the job for a reparented location and for a location retyped away, not for a genre rename (`Sidekiq::Testing.fake!` + job count); rename keeps the id and the old slug resolves; NameGuard finds a name twin and an alias twin, ignores deleted/merged categories, ignores a case-only change of the same record; API create 201; duplicate → 422 naming the id; `parent_id` making a cycle → 422 with the model message; PATCH on a merged category → 422; member and `ADMIN_READ` tokens → 403; contract coverage entries.
- [ ] **Step 2: Run** `bin/rails test test/lib/categories/ test/controllers/api/v1/admin/ test/controllers/admin/books/ test/integration/api/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** same → PASS.
- [ ] **Step 5: Commit** `Categories: Editor + API create/update with twin guard`

---

### Task 5: The tagging service and the admin UI

**Files:**
- Create: `web-app/app/lib/categories/item_linker.rb`
- Modify: `web-app/app/controllers/admin/category_items_controller.rb` (create/destroy call the service; turbo responses unchanged), `web-app/app/views/admin/category_items/index.html.erb` (no Remove on inherited rows; "via <names>" label)
- Test: `web-app/test/lib/categories/item_linker_test.rb`, existing `test/controllers/admin/category_items_controller_test.rb`, admin E2E for item categories (find the existing spec under `web-app/e2e/tests/books/admin/` that adds/removes a category on a book and extend it)

**Interfaces:**
- `Categories::ItemLinker.link(item:, category:) -> Result` and `.unlink(item:, category:) -> Result`. Result data = the item's category items after the change (`includes(:category)`), errors = messages. Refusals (Result failure, `errors.first` = message):
  - different site: "That category belongs to a different section." (same check as today's `ensure_category_domain_matches`, moved here)
  - deleted, unmerged: "That category has been deleted."
  - merged: "That category was merged into #{canonical.name} (#{canonical.id})." (nil canonical → the deleted message)
  - unlink of an `inherited` row: "#{category.name} comes from #{names}; remove that instead." with `names` = every direct location on the item whose ancestor chain contains the category, joined with ", ".
  - unlink of a category the item doesn't have: failure "That item doesn't have that category." (API maps it to 404).
- Link: existing inherited row → `source: :admin`; existing direct row → success, no change; else create with `source: :admin`. After link or unlink on a `::Books::Book`: `::Categories::AncestorReconciler.call(item_ids: [item.id])`.
- `ItemLinker.inherited_from(item:, category:) -> Array<Category>` — the direct locations behind an inherited row; the view uses it for the "via" label (N+1-safe: compute for the page's inherited rows in one pass).
- Admin controller: on failure, the same flash the controller shows today, with the service's message.

- [ ] **Step 1: Failing tests** (service): each refusal above; inherited upgrade; idempotent re-add returns success with one row; reconcile called for books, not for authors (Mocha `expects`); unlink of inherited names both locations when two direct locations share the ancestor; works for a `Music::Category` on a `Music::Album` (cross-domain service). Controller: re-adding an existing direct link now responds with the success turbo stream (Review Focus 2); view: an inherited row renders "via Paris" and no Remove button.
- [ ] **Step 2: Run** `bin/rails test test/lib/categories/item_linker_test.rb test/controllers/admin/category_items_controller_test.rb` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** same + `bin/rails test test/controllers/admin/` → PASS. Run the extended admin E2E spec (port 3000 check first; `yarn build:all`; `bin/rails server`; stop after) → PASS.
- [ ] **Step 5: Commit** `Categories: ItemLinker shared by the admin UI; inherited tags labelled`

---

### Task 6: Tag and untag through the API

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/admin/books/book_categories_controller.rb`, `.../author_categories_controller.rb` (or one controller with a shared concern; implementer's choice, no duplicated logic)
- Modify: routes, admin OpenAPI, admin coverage test
- Test: generated controller tests

**Interfaces:**
- Routes: `post "books/:id/categories"`, `delete "books/:id/categories/:category_id"`, same for `authors`, ids digits-only.
- Scope `books:admin:write`; policy `Books::CategoryPolicy#update?` on the category and `Books::BookPolicy#update?` / `Books::AuthorPolicy#update?` on the item (403 `forbidden` naming which).
- POST body `{category_id}` (strict id). Item not found / category not found → 404 naming which. ItemLinker failure → 422 with its message, except "doesn't have that category" → 404. Success 200: `{data: [{id, slug, name, category_type, source}]}` sorted by name.
- One structured log line per successful link/unlink: `event=api_admin_category_link` with `action`, token id, user id, item type/id, category id.

- [ ] **Step 1: Failing tests**: tag a book → 200 and the category listed with `source: "admin"`; tag twice → 200, one row; tag with a merged category → 422 naming the canonical id; untag → 200 and gone; untag inherited → 422 naming the location; untag a category the book lacks → 404; a `Music::Category` id → 422; author tag/untag; `ADMIN_READ` token → 403 `insufficient_scope`; contract coverage entries.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/admin/ test/integration/api/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** same + zeitwerk → PASS.
- [ ] **Step 5: Commit** `Admin API: tag and untag books and authors`

---

### Task 7: Batch merge and delete

**Files:**
- Modify: `web-app/app/lib/categories/merger.rb` (expose preconditions), `web-app/app/controllers/api/v1/admin/books/categories_controller.rb` (merge, destroy), routes, admin OpenAPI, admin coverage test
- Test: `web-app/test/lib/categories/merger_test.rb`, admin API controller test

**Interfaces:**
- `Categories::Merger.refusal(source:, target:) -> String | nil` (class method) holds today's `refuse_invalid!` checks and messages; `refuse_invalid!` becomes `raise Refused, msg if (msg = self.class.refusal(source:, target:))`. Existing merger tests stay green.
- Routes: `post "categories/:id/merge"`, `delete "categories/:id"` (digits-only).
- Both require `books:admin:merge` (the controller has mixed scopes: set `required_scope` per action, e.g. a `before_action` that picks the scope by `action_name`; the base `require_scope!` must still run exactly once and never be skipped).
- Merge body `{source_ids: [...], dry_run: bool}`: 1..50 strict ids, no duplicates, target not among them → else 400 `invalid_parameter`. Load target and every source (404 naming the first missing id); policy `destroy?` on each (403 naming it); `Merger.refusal` for each source → if any, 422 `unprocessable` with detail listing every `"#{id}: #{message}"`. `dry_run` → 200 `{data: {target: <admin shape>, sources: [{id, name, book_link_count, author_link_count}]}, meta: {dry_run: true}}`. Real: merge each in order; on an exception or `Refused` part-way, stop and return 422 whose body has `merged: [ids], failed: {id, message}, not_attempted: [ids]`; success 200 `{data: {target: <admin shape, reloaded>, merged: [ids]}, meta: {dry_run: false}}`. Log `event=api_admin_category_merge outcome=succeeded|failed` per source.
- Delete: `?dry_run=true|false` (default false). Already deleted → 422. Dry run → 200 `{data: {category: <admin shape>, book_links_removed: n, author_links_removed: n}, meta: {dry_run: true}}`. Real → `::Categories::Deleter.new(category:, soft: true).delete`; `Refused` → 422 with its message; success 200 same shape with `dry_run: false`. Log `event=api_admin_category_delete`. The OpenAPI description says soft delete removes all the category's links and cannot be undone with them.

- [ ] **Step 1: Failing tests**: merging 3 sources moves their links to the target and soft-deletes each with `merged_into`; dry run changes nothing; a protected category among sources → 422 listing it and **nothing merged**; target in `source_ids` → 400; duplicate source id → 400; 51 sources → 400; a mid-batch failure (stub the second `Merger#merge` to raise) → 422 with `merged: [first]`, `failed`, `not_attempted: [third]`, and the first stays merged; policy refusal on one source → 403 naming it; delete dry run reports link counts and changes nothing; delete removes the links and sets `deleted`; protected → 422; already deleted → 422; a write-only token → 403 `insufficient_scope` (in the test: create a user with a books `DomainRole` editor, mint `["books:admin:write"]` with `Services::Api::Tokens.generate(..., expires_at: 30.days.from_now)`); contract coverage entries (the 403 entry can use `ApiTokenSecrets::ADMIN_READ`).
- [ ] **Step 2: Run** `bin/rails test test/lib/categories/merger_test.rb test/controllers/api/v1/admin/ test/integration/api/` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** same + zeitwerk → PASS.
- [ ] **Step 5: Commit** `Admin API: batch category merge and soft delete`

---

### Task 8: Docs and full verification

**Files:**
- Modify: `docs/features/public-api.md`, `docs/features/books-categories.md`

- [ ] **Step 1:** `public-api.md`: the three public category endpoints, the admin category endpoints, the `books:admin:write` scope and that merge implies it, and the soft-delete warning. `books-categories.md`: the admin UI and the API share `Categories::Editor` and `Categories::ItemLinker`; inherited tags can't be removed directly and are labelled "via"; re-adding a tag is a no-op. Check every factual claim against the code.
- [ ] **Step 2:** `bin/rails test` → green, no warning lines beyond AGENTS.md's two known sources.
- [ ] **Step 3:** `bundle exec standardrb` → no offenses; `CI=1 bin/rails zeitwerk:check` → clean.
- [ ] **Step 4: Commit** `Docs: categories API`
