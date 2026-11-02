# API Admin Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins hold admin API scopes (search, merge) through tokens whose power is capped by the owner's current role, while members keep only the base public read API.

**Architecture:** `Api::Scopes` gains per-scope eligibility rules (built on the existing policies) and an `admin` flag. The authenticator computes effective scopes as *expanded token scopes ∩ eligible scopes* on every request. Admin endpoints live under `/api/v1/admin/` in `Api::V1::Admin::Books`, documented in a separate OpenAPI file that only admin tokens can fetch.

**Tech Stack:** Rails 8, ActionController::API, Alba, openapi_first, Minitest + fixtures + Mocha, OpenSearch (existing `Search::Books::Search::*General`), Playwright.

**Spec:** `docs/superpowers/specs/2026-11-01-api-admin-permissions-design.md`. Read it, plus `docs/features/public-api.md`, before Task 1.

## Global Constraints

- All Rails commands run from `web-app/`.
- Every `Books::` reference inside `Api::V1::Admin::Books`, `Services::Books` or `Actions::Admin::Books` is root-anchored (`::Books::Book`); a bare one resolves to the enclosing namespace and raises.
- Controllers via the generator: `bin/rails generate controller <path> --skip-routes --no-helper --no-assets --no-template-engine`, then delete any generated action stubs you don't need. The generator's test file is the test file.
- Admin paths and scopes must never appear in `config/api/v1/openapi.yaml` or on `/developers`.
- Never wrap `Books::Book::Merger#call` / `Books::Author::Merger#call` in a transaction (see the comment on `Books::Book::Merger#call`).
- Problem responses go through `render_problem(::Api::Problem.new(code, detail:))`; the type URL anchors on `/developers#errors-<code>`, which renders every `Api::Problem::DEFINITIONS` entry, so new codes appear there automatically.
- After adding anything under `app/lib/api` or `app/controllers/api`: `CI=1 bin/rails zeitwerk:check`.
- Done means: `bin/rails test` green with no new warning lines, `bundle exec standardrb` clean.
- No migrations in this plan, so no annotation changes. If one is added, annotaterb runs with it.

## Review Focus

1. **A demoted owner's token**: a token minted with `books:admin:merge` whose owner drops to a books viewer keeps `books:admin:read` + `books:read` and gets 403 on merge. Covered in Task 2.
2. **The fixture formerly named "non-member"**: `non_member_token` belongs to `books_viewer_user`, who becomes eligible for `books:read` through the viewer role. Every contract/controller test using `ApiTokenSecrets::NON_MEMBER` would silently stop proving "membership required". Task 1 moves the fixture to `user_with_expired_membership`.
3. **An admin without a membership reaching `/developers/tokens`** while a non-member with no role is still redirected to `/membership`. Covered in Task 3.
4. **Merge with `source_id` equal to the target, a missing source, a non-integer `source_id`, a missing body**: 422, 404, 400, 400 respectively, nothing deleted. Covered in Task 5.
5. **Search with a blank or missing `q`**: 400, not an empty 200 and not a full-table page. Covered in Task 4.

---

### Task 1: Scope registry with eligibility rules

**Files:**
- Modify: `web-app/app/lib/api/scopes.rb`
- Modify: `web-app/test/fixtures/api_tokens.yml` (`non_member_token.user` → `user_with_expired_membership`)
- Test: `web-app/test/lib/api/scopes_test.rb`

**Interfaces:**
- Produces:
  - `Api::Scopes::Scope = Struct.new(:name, :description, :admin, :implies, :eligible, keyword_init: true)`. `member_mintable` is removed. `eligible` is a lambda `->(user) { bool }`. `admin` is a boolean.
  - New scopes: `"books:admin:read"` (`implies: ["books:read"]`, `admin: true`, eligible when `::Books::BookPolicy.new(user, ::Books::Book).index?`) and `"books:admin:merge"` (`implies: ["books:admin:read"]`, `admin: true`, eligible when `...destroy?`). Merge's description says it permanently deletes records.
  - Read scopes: `admin: false`, eligible when `user.member? || user.service?`.
  - `Api::Scopes.eligible_for(user) -> Array<String>`: every scope whose own rule passes, **plus** every scope implied (transitively) by one that passes. A non-member books viewer therefore gets `books:read` through `books:admin:read`. Service accounts get the read scopes only (their role is `:user` with no DomainRole, so the admin rules fail naturally).
  - `Api::Scopes.mintable_by(user)` = `eligible_for(user)` (kept as the name the form and `ApiToken` already call).
  - `Api::Scopes.effective(granted, user) -> Array<String>`: `(granted ∪ expand(each granted)) ∩ eligible_for(user)`, only known scopes.
  - `Api::Scopes.admin?(scope) -> bool`.
  - `satisfies?`, `expand`, `known?`, `fetch`, `description`, `all` unchanged.

- [ ] **Step 1: Write the failing tests** (replace the `Account` struct tests, which rely on `member_mintable`; use real fixture users)

```ruby
test "registers the admin scopes" do
  assert_equal ["books:read", "music:read", "games:read", "books:admin:read", "books:admin:merge"], Scopes.all
  assert Scopes.admin?("books:admin:merge")
  refute Scopes.admin?("books:read")
end

test "a member is eligible for the read scopes only" do
  assert_equal ["books:read", "music:read", "games:read"], Scopes.eligible_for(users(:regular_user)).sort_by { Scopes.all.index(_1) }
end

test "a non-member with no role is eligible for nothing" do
  assert_empty Scopes.eligible_for(users(:user_with_expired_membership))
end

test "a global admin without a membership is eligible for every books scope, but not other sites' reads" do
  admin = users(:admin_user)
  admin.memberships.destroy_all
  assert_equal ["books:read", "books:admin:read", "books:admin:merge"].sort, Scopes.eligible_for(admin).sort
end

test "a books viewer may read admin data but not merge" do
  eligible = Scopes.eligible_for(users(:books_viewer_user))
  assert_includes eligible, "books:admin:read"
  assert_includes eligible, "books:read"
  refute_includes eligible, "books:admin:merge"
end

test "a games-only editor gains no books admin scope" do
  refute_includes Scopes.eligible_for(users(:games_editor_user)), "books:admin:read"
end

test "a service account gets the read scopes and no admin scope" do
  assert_equal ["books:read", "music:read", "games:read"], Scopes.eligible_for(users(:agent_runner_service_account))
end

test "effective expands implied scopes before intersecting" do
  viewer = users(:books_viewer_user)
  assert_equal ["books:read", "books:admin:read"].sort, Scopes.effective(["books:admin:merge"], viewer).sort
end

test "effective drops scopes the user no longer qualifies for and unknown scopes" do
  assert_equal ["books:read"], Scopes.effective(["books:read", "books:admin:merge", "retired:scope"], users(:regular_user))
end
```

Also add tests for global editor (`editor_user`, eligible for merge) and a books `DomainRole` admin created in the test (eligible for merge). Keep the existing `satisfies?` hierarchy tests, updating their `Scope.new` calls to the new members.

- [ ] **Step 2: Run** `bin/rails test test/lib/api/scopes_test.rb`. Expected: FAIL (unknown scope / `NoMethodError: eligible_for`).

- [ ] **Step 3: Implement the registry changes** in `app/lib/api/scopes.rb` per the Interfaces block. Update the file's header comment, which currently says write/admin scopes are not defined yet. Move `non_member_token` to `user_with_expired_membership` in `test/fixtures/api_tokens.yml` and update the fixture file's header comment if it names the owner.

- [ ] **Step 4: Run** `bin/rails test test/lib/api/ test/models/api_token_test.rb test/integration/api/ test/controllers/api/ test/controllers/developers/`. Expected: PASS. Any failure here comes from the `member_mintable` removal or the fixture move. Fix the caller, don't restore the old field.

- [ ] **Step 5: Commit** `git commit -m "API scopes: eligibility rules and the books admin scopes"`

---

### Task 2: Effective scopes in the authenticator, admin tier

**Files:**
- Modify: `web-app/app/lib/services/api/authenticator.rb`
- Modify: `web-app/config/initializers/api.rb` (add `admin: {per_minute: 600, per_day: 200_000}` to `rate_limits`)
- Test: `web-app/test/lib/services/api/authenticator_test.rb`, `web-app/test/lib/services/api/rate_limiter_test.rb` (only if it enumerates tiers)

**Interfaces:**
- Consumes: `Api::Scopes.effective(granted, user)`, `Api::Scopes.admin?(scope)` (Task 1).
- Produces: `Api::Principal#scopes` = effective scopes. `Api::Principal#tier` ∈ `:system` (service account), `:admin` (any effective scope is admin), `:member` (otherwise).
  Failure rule: `:membership_required` when effective scopes are empty **and** `!user.member?` (for service accounts, the effective set is never empty in practice; keep the same rule). Everything else in the authenticator is unchanged.

- [ ] **Step 1: Write the failing tests**

```ruby
test "an admin without a membership authenticates as an admin principal" do
  admin = users(:admin_user)
  admin.memberships.destroy_all
  secret = Services::Api::Tokens.generate(user: admin, name: "mcp", scopes: ["books:admin:merge"], expires_at: 30.days.from_now).data[:secret]
  result = Authenticator.call(request_with(secret))
  assert result.success?
  assert_equal :admin, result.data.tier
  assert_equal ["books:read", "books:admin:read", "books:admin:merge"].sort, result.data.scopes.sort
end

test "demotion takes effect on the next request" do
  # books DomainRole admin mints a merge token, then is set to viewer
  # → success, scopes == ["books:read", "books:admin:read"], tier :admin
end

test "an admin-scoped token whose owner lost every role and membership is :membership_required" do
  # global admin mints, then role -> :user and memberships destroyed → errors == [:membership_required]
end

test "a lapsed member's read token is still :membership_required" do
  # existing test at line ~71 must keep passing unchanged
end
```

Use the file's existing request-building helper; the names above are placeholders for it.

- [ ] **Step 2: Run** `bin/rails test test/lib/services/api/authenticator_test.rb`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement** in `Authenticator#call`: compute `scopes = ::Api::Scopes.effective(token.scopes, user)`, apply the failure rule above, set the tier, build the principal with `scopes:`. Add the `admin` rate-limit entry.

- [ ] **Step 4: Run** `bin/rails test test/lib/services/api/ test/integration/api/ test/controllers/api/`. Expected: PASS.

- [ ] **Step 5: Commit** `git commit -m "API authenticator: effective scopes capped by the owner's current role"`

---

### Task 3: Minting admin tokens

**Files:**
- Modify: `web-app/app/models/api_token.rb` (new validation)
- Modify: `web-app/app/controllers/developers/tokens_controller.rb` (gate)
- Modify: `web-app/app/views/developers/tokens/_form.html.erb` (only if needed: a one-line note under the scopes that admin scopes require an expiry)
- Test: `web-app/test/models/api_token_test.rb`, `web-app/test/controllers/developers/tokens_controller_test.rb`
- Create: `web-app/e2e/tests/books/admin/api-tokens.spec.ts`
- Modify: `web-app/e2e/tests/books/member/developers-tokens.spec.ts`

**Interfaces:**
- Consumes: `Api::Scopes.mintable_by`, `Api::Scopes.admin?`.
- Produces:
  - `ApiToken` validation `admin_scopes_require_expiry`: when any scope is admin and `expires_at` is nil, error on `:expires_at` reading "must be set for tokens with admin scopes". Runs on every save, like the existing scope validation.
  - `TokensController`: replace `before_action -> { require_membership!(:api) }` with a private `require_api_access!` that returns when `current_user && ::Api::Scopes.mintable_by(current_user).any?`, else calls `require_membership!(:api)` (keeps today's redirect and message for everyone else).

- [ ] **Step 1: Write the failing tests**
  - Model: an admin's token with `["books:admin:read"]` and no expiry is invalid with that message; with `expires_at: 30.days.from_now` it is valid; a member's `["books:read"]` with no expiry stays valid; a member's `["books:admin:read"]` is invalid with "not available to this account".
  - Controller: `admin_user` with memberships destroyed gets 200 on `GET /developers/tokens`; `user_with_expired_membership` is redirected to the membership path (existing assertion style); an admin `POST` with `scopes: ["books:admin:merge"], expires_in: ""` re-renders with the expiry error and creates nothing; with `expires_in: "30"` creates one token.

- [ ] **Step 2: Run** `bin/rails test test/models/api_token_test.rb test/controllers/developers/tokens_controller_test.rb`. Expected: new tests FAIL.

- [ ] **Step 3: Implement** the validation and the gate.

- [ ] **Step 4: Run** the same command. Expected: PASS.

- [ ] **Step 5: E2E.** `admin/api-tokens.spec.ts` (runs in the admin project, like the other `books/admin` specs): on `/developers/tokens` the checkboxes labelled with `books:admin:read` and `books:admin:merge` are visible; create a token with name `E2E admin token`, `books:admin:merge` checked and expiry 30 days; the secret appears; revoke it (clean up before and after, the way `member/developers-tokens.spec.ts` does). In `member/developers-tokens.spec.ts` add: no `books:admin:merge` checkbox is present. Before running, check port 3000 belongs to this worktree (AGENTS.md snippet), then `yarn build:all`, `bin/rails server`, `yarn test:e2e --project=<admin project> e2e/tests/books/admin/api-tokens.spec.ts`, plus the member project's spec. Expected: PASS. If the member project can't run (it needs `PLAYWRIGHT_MEMBER_EMAIL`), say so in the report rather than skipping silently.

- [ ] **Step 6: Commit** `git commit -m "API tokens: admins can mint admin scopes, which must expire"`

---

### Task 4: Admin base, admin search, admin OpenAPI document

**Files:**
- Create (generator): `web-app/app/controllers/api/v1/admin/books/base_controller.rb`, `.../admin/books/books_controller.rb`, `.../admin/books/authors_controller.rb`, `web-app/app/controllers/api/v1/admin/openapi_controller.rb`
- Create: `web-app/app/lib/api/v1/admin/books/book_resource.rb`, `.../admin/books/author_resource.rb`
- Create: `web-app/config/api/v1/admin_openapi.yaml`
- Modify: `web-app/app/lib/api/openapi_document.rb`
- Modify: `web-app/config/routes.rb` (inside the books `DomainConstraint` API block)
- Modify: `web-app/test/test_helper.rb` (register the admin document), `web-app/test/support/api_conformance.rb` (`api:` keyword)
- Create: `web-app/test/support/api_token_secrets.rb` entries + `web-app/test/fixtures/api_tokens.yml` entries (see below)
- Create: `web-app/test/integration/api/v1/admin_contract_coverage_test.rb`
- Test: generated controller tests

**Interfaces:**
- Consumes: `Api::V1::BaseController` (`require_scope`, `render_page`), `Api::Scopes` (Task 1), authenticator (Task 2).
- Produces:
  - Routes (books host, inside `namespace :api … namespace :v1`): `namespace :admin do get "openapi", to: "openapi#show"; scope module: :books do get "books", to: "books#index"; get "authors", to: "authors#index"; post "books/:id/merge", to: "book_merges#create", constraints: {id: /\d+/}; post "authors/:id/merge", to: "author_merges#create", constraints: {id: /\d+/} end end`. The merge routes point at Task 5's controllers; add them in Task 5 if the route file won't load without the controllers.
  - `Api::V1::Admin::Books::BaseController < ::Api::V1::BaseController` with `require_scope "books:admin:read"`.
  - `Api::V1::Admin::OpenapiController < ::Api::V1::BaseController`, `require_scope "books:admin:read"`, renders `::Api::OpenapiDocument.for_host(::Api::Host.base_url, domain: Current.domain, document: :admin)`. Not cached (the base controller's `prevent_caching` already applies).
  - `Api::OpenapiDocument.for_host(base_url, domain:, document: :public)`; `PATHS = {public: "config/api/v1/openapi.yaml", admin: "config/api/v1/admin_openapi.yaml"}`; memoise per document.
  - `Api::V1::Admin::Books::BookResource` (Alba): `id, slug, title, subtitle, book_kind, provisional, first_published_year, rank` (rank = `primary_ranked_item&.rank`, may be null), `authors` via `::Api::V1::Books::AuthorSummaryResource`.
  - `Api::V1::Admin::Books::AuthorResource` (Alba): `id, slug, name, kind, provisional, birth_year, death_year, rank` (from `primary_ranked_item`), `book_count` (passed in via `params: {book_counts:}`, computed once per page with one grouped query on `::Books::BookAuthor`).
  - Search: `q` required. Blank or missing → `invalid_parameter` 400 with detail "q is required". Ids come from `::Search::Books::Search::BookGeneral.call(q, size: 1000, book_kind: nil, include_provisional: true)` (authors: `AuthorGeneral.call(q, size: 1000)`), then `::Books::Book.where(id: ids).in_order_of(:id, ids)` with `includes(:authors, :primary_ranked_item)`, passed to `render_page(relation, path: "/api/v1/admin/books")`. Provisional records are included (no `.catalog`). Empty hits → `render_page(nil, …)`, which renders an empty page.
  - Test tokens: add `ApiTokenSecrets::ADMIN = "tg_#{"a" * 40}"` and `ApiTokenSecrets::ADMIN_READ = "tg_#{"r" * 40}"`, fixtures `admin_merge_token` (user `admin_user`, scopes `["books:admin:merge"]`, `expires_at` 30 days ahead) and `books_viewer_admin_read_token` (user `books_viewer_user`, `["books:admin:read"]`, 30 days ahead).
  - `assert_api_response_conform(status:, api: :default)`; the admin document is registered with `test.register(<admin yaml>, as: :admin)`. Check the installed openapi_first's `register` signature (`bundle exec gem contents openapi_first` / its source) before relying on `as:`.

- [ ] **Step 1: Write the admin OpenAPI document** for the two search operations and `/api/v1/admin/openapi.json` (paths tagged `x-domain: books`; responses 200/400/401/403/429 for search, 200/401/403/429 for the document; reuse the public document's component shapes by copying the ones needed, since cross-file `$ref` is not set up). Merge operations come in Task 5.

- [ ] **Step 2: Write the failing tests**
  - `admin_contract_coverage_test.rb`: same structure as `contract_coverage_test.rb` (EXERCISES map vs `OpenapiFirst::Test[:admin].routes`, every documented response reachable and conforming with `api: :admin`). 403 is exercised with the member token (`ApiTokenSecrets::MEMBER`); 400 with `?q=`. Stub search with Mocha: `::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:war_and_peace).id.to_s, score: 1.0}])` (check `extract_hits_with_scores`' real shape and match it).
  - Add a test to the **public** coverage file or `openapi_controller_test.rb`: the public document's paths contain nothing starting `/api/v1/admin`.
  - Controller tests: ordered results follow the search order; `book_kind: nil, include_provisional: true` are passed (`BookGeneral.expects(:call).with("war", size: 1000, book_kind: nil, include_provisional: true)`); a provisional book is returned; missing `q` and `q=%20` → 400; member token → 403 `insufficient_scope`; viewer read token → 200; on the music host the route does not exist (404).

- [ ] **Step 3: Run** `bin/rails test test/integration/api/ test/controllers/api/`. Expected: new tests FAIL.

- [ ] **Step 4: Implement** routes, controllers, resources, the document loader change and the test registration.

- [ ] **Step 5: Run** the same command plus `CI=1 bin/rails zeitwerk:check`. Expected: PASS, zeitwerk "All is good!".

- [ ] **Step 6: Commit** `git commit -m "Admin API: book and author search, admin OpenAPI document"`

---

### Task 5: Merge endpoints

**Files:**
- Create: `web-app/app/lib/services/books/admin_merge.rb`
- Create (generator): `web-app/app/controllers/api/v1/admin/books/book_merges_controller.rb`, `.../author_merges_controller.rb`
- Modify: `web-app/app/lib/api/problem.rb` (add `forbidden: [403, "Forbidden"]`, `unprocessable: [422, "Unprocessable"]`)
- Modify: `web-app/config/api/v1/admin_openapi.yaml`, `web-app/config/routes.rb` (if not done in Task 4), `admin_contract_coverage_test.rb`
- Test: `web-app/test/lib/services/books/admin_merge_test.rb`, generated controller tests

**Interfaces:**
- Consumes: Task 4's base controller and resources; `::Books::Book::Merger`, `::Books::Author::Merger`; `::Books::BookPolicy`, `::Books::AuthorPolicy`.
- Produces:
  - `Services::Books::AdminMerge.call(source:, target:, dry_run: false) -> Result` (`Result = Struct.new(:success?, :data, :errors, keyword_init: true)`). Source and target must be the same class (`::Books::Book` or `::Books::Author`); it picks the matching merger. `source.id == target.id` → failure, errors `["Cannot merge a record with itself"]`. Dry run → success with no merger call. Merger failure → failure with the merger's errors. Success data: `{warnings: [{code: String, detail: String}]}`.
  - Warnings, read from `merger.stats` after a successful merge:
    - `post_commit_error` present → `{code: "post_commit_error", detail: "Search reindexing, ranking recalculation and the generated favorites rebuild could not be scheduled (<error>); they will need to be re-run."}`. For authors the detail omits "and the generated favorites rebuild", matching `Actions::Admin::Books::MergeAuthor`.
    - books only: `book_authors_not_transferred` > 0 → `{code: "book_authors_not_transferred", detail: "<n> author(s) did not transfer because the surviving book already has its own."}`. `credits_not_transferred` > 0 works the same way.
  - The admin actions (`MergeBook`, `MergeAuthor`) are **not** changed. They keep their UI wording. This service is the API's interpreter of the same `stats` keys; a comment in it names both actions so a future stats change updates all three.
  - Controllers: `require_scope "books:admin:merge"`. `create`: `source_id = params.require(:source_id)`, must be an integer (`Integer(…, exception: false)`, else `invalid_parameter` 400). `dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) || false`. Load the target with `find(params[:id])` and the source with `find(source_id)` (404 via the existing rescue). Authorize `destroy?` on **both** with the policy (`::Books::BookPolicy.new(current_principal.user, record).destroy?`), else `forbidden` 403 "Your account may not delete this record". Build both summaries **before** calling the service. Service failure → `unprocessable` 422 with the errors joined. Success → 200:
    ```json
    {"data": {"survivor": <Admin BookResource/AuthorResource>, "deleted": <same, captured pre-merge>},
     "meta": {"dry_run": false},
     "warnings": []}
    ```
    After a real (non-dry-run) success, log `Rails.logger.info` with `event: "api_admin_merge"`, `token_id`, `user_id`, `record_type`, `source_id`, `target_id` (match the structured-log style used elsewhere in the app if one exists; otherwise a single `key=value` line).
  - The JSON body is `{"source_id": <int>, "dry_run": <bool>}`, sent `as: :json` in tests.

- [ ] **Step 1: Write the failing service tests**: dry run calls no merger (`::Books::Book::Merger.expects(:new).never`) and returns empty warnings; same id fails; a real book merge with fixtures deletes the source; a stubbed merger whose `stats` has `post_commit_error: "Redis down"` yields that warning; `book_authors_not_transferred: 2` yields the count warning; mismatched classes raise `ArgumentError`.

- [ ] **Step 2: Run** `bin/rails test test/lib/services/books/admin_merge_test.rb`. Expected: FAIL.

- [ ] **Step 3: Implement** `Services::Books::AdminMerge`. Run again. Expected: PASS.

- [ ] **Step 4: Write the failing controller tests** (both controllers): admin token merges, 200, source gone, response `deleted.id` is the source id; `dry_run: true` → 200, both records still exist, `meta.dry_run` true; read-only admin token (`ADMIN_READ`) → 403 `insufficient_scope`; member token → 403; same id → 422, nothing deleted; missing source → 404; `source_id: "abc"` → 400; no body → 400; a policy refusal (stub `::Books::BookPolicy#destroy?` to false for one record) → 403 `forbidden`; the log line is written once for a real merge and not for a dry run. Add 200/400/403/404/422 entries for both operations to the admin document and the admin coverage map.

- [ ] **Step 5: Run** `bin/rails test test/controllers/api/ test/integration/api/`. Expected: FAIL on the new tests.

- [ ] **Step 6: Implement** the problems, controllers, routes and document entries. Run again plus `CI=1 bin/rails zeitwerk:check`. Expected: PASS.

- [ ] **Step 7: Commit** `git commit -m "Admin API: book and author merges with dry run and warnings"`

---

### Task 6: Documentation and full verification

**Files:**
- Modify: `docs/features/public-api.md` (project root `docs/`)

- [ ] **Step 1: Document** in `docs/features/public-api.md`: the permission model (the three checks, the eligibility table, expand-then-intersect, demotion taking effect on the next request), admin scopes and their must-expire rule, the `admin` rate-limit tier, the four admin endpoints and `/api/v1/admin/openapi.json`, and the fact that admin paths are kept out of the public document. Keep it at the level of the existing sections. No per-class doc files.

- [ ] **Step 2: Run** `bin/rails test`. Expected: green, and no warning lines beyond the two known upstream sources in AGENTS.md.

- [ ] **Step 3: Run** `bundle exec standardrb`. Expected: no offenses.

- [ ] **Step 4: Commit** `git commit -m "Docs: API admin permissions"`
