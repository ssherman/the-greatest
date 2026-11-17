# Library API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let members read and change their own book lists over the public REST API and MCP
(`/api/mcp`): nine operations under `/api/v1/my/…`, behind two new scopes, with a 50-book batch
cap, a 1,000-change daily budget and all-or-nothing batches.

**Architecture:**
- **Shared services.** Batch services (`Services::UserLists::AddItems`, `RemoveItems`,
  `UpdateItem`) run the existing per-item services inside one owner-locked transaction.
  `Services::UserLists::OwnerMutation` holds the lock and the reading-goal purge, and the web
  controller uses it too.
- **Budget.** `Services::Api::LibraryBudget` counts book changes per user per UTC day on the
  rate-limit store.
- **Controllers** live in `Api::V1::Books::My`, and the MCP tools come from their `x-mcp` blocks.

**Tech Stack:** Rails 8, Postgres, Alba resources, Minitest + Mocha, openapi_first contract tests,
`mcp` gem catalogue built from OpenAPI.

**Spec:** `docs/superpowers/specs/2026-11-16-library-api-design.md`

## Global Constraints

**Commands and style**
- Run Rails commands from `web-app/`; docs live in `docs/` at the repo root.
- Lint with `bundle exec standardrb`. Never run brakeman, and never set
  `ANNOTATERB_SKIP_ON_DB_TASKS`. This plan has no migration.
- Generate new controllers with
  `bin/rails generate controller api/v1/books/my/<name> --skip-routes --no-helper --no-assets`,
  then replace the body and delete any generated view folder.
- Inside `Api::V1::Books`, root-anchor model and service references (`::Books::…`, `::UserList`,
  `::Services::…`).
- Controller tests assert behaviour (status, keys, ids, outcomes, database state), never copy.
- Minitest 6: use `assert_nil`, never `assert_equal nil`.

**Scopes**
- `books:library:read` has the description "Read your book lists on The Greatest Books".
- `books:library:write` has the description "Add, move and remove books on your lists, and create,
  edit and delete your custom lists", and implies `books:library:read`.
- Both are `admin: false` with `eligible: READER`.
- Registry order: `books:read, books:library:read, books:library:write, music:read, games:read, books:admin:read, books:admin:write, books:admin:merge`.

**Limits** (`config/initializers/api.rb`)

| Setting | Value |
|---|---|
| `config.x.api.library_changes_per_day` | 1_000 |
| `config.x.api.library_batch_max` | 50 |
| `config.x.api.max_custom_lists` | 500 |
| List `name` | 1–100 characters |
| List `description` | at most 1,000 characters |

**Addressing**
- `{list}` is a numeric id or one of `favorites read reading want_to_read`.
- Anything else, or another user's list, is a 404 `not_found` problem.
- Books are catalogue slugs: `::Books::Book.catalog.find_by(slug:)`.

**Outcomes:** the enum is exactly `added moved already_present updated removed not_present`.

**Statuses** (existing `Api::Problem` codes only)

| Status | Problem code | When |
|---|---|---|
| 400 | `invalid_parameter` | Malformed input. |
| 404 | `not_found` | Unknown list or books. |
| 422 | `unprocessable` | A rule is broken. |
| 429 | `rate_limited` | Request limit or library budget. |

**Write responses:**
- Batch writes return `{data: [{book:, outcome:}...], meta: {list: <UserList>, library_changes_remaining: Integer}}`.
- `data` is in request order, after removing duplicate slugs.

## Review Focus

1. **A batch that fails partway changes nothing.** When the third of three books fails, the first
   two are not on the list, no purge job is enqueued, and the budget is back where it was. Tests in
   Task 2 (service) and Task 5 (endpoint).
2. **The Reading → Read move inside a batch.** Adding two books to `read` when one is on `reading`
   gives outcomes `moved` and `added`. The moved book leaves `reading` with today's date, and
   exactly one `PurgeCachedPagesJob` is enqueued after commit. Test in Task 2.
3. **The budget boundary.** With 990 used, a 20-book call is a 429 that changes nothing and leaves
   the count at 990. A 10-book call then succeeds with `library_changes_remaining == 0`. Tests in
   Task 3 and Task 5.
4. **A default list that doesn't exist yet, and other users' lists.**
   - `GET /api/v1/my/lists/reading/books` for a user without a reading list is a 200, and the list
     now exists.
   - Another user's list id is a 404, never a 403.

   Tests in Task 4.
5. **Moving a book on a list with a hidden provisional book.**
   - The allowed range is 1 to the total item count.
   - Positions stay contiguous 1..N after the move.
   - `manually_ordered` becomes true.

   Test in Task 2.

---

### Task 1: Scopes, OAuth offer and test tokens

**Files:**
- Modify: `web-app/app/lib/api/scopes.rb`. Add the two scopes from Global Constraints, in that
  registry order.
- Modify: `web-app/app/lib/oauth/resources.rb`. `Resource#scopes(domain)` for a non-admin resource
  returns every non-admin scope starting with `"#{domain}:"`, in registry order. Books gets
  `["books:read", "books:library:read", "books:library:write"]`; music stays `["music:read"]`.
- Modify: `web-app/test/support/api_token_secrets.rb`. Add `LIBRARY = "tg_#{"l" * 40}"` and
  `LIBRARY_READ = "tg_#{"k" * 40}"`.
- Modify: `web-app/test/fixtures/api_tokens.yml`. Add two tokens, both for `regular_user`:
  - `regular_user_library_token`, with scopes `["books:read", "books:library:write"]` and secret
    `LIBRARY`;
  - `regular_user_library_read_token`, with scopes `["books:read", "books:library:read"]` and
    secret `LIBRARY_READ`.
- Test: `web-app/test/lib/api/scopes_test.rb`, `web-app/test/lib/oauth/resources_test.rb`,
  `web-app/test/controllers/oauth/metadata_controller_test.rb`. Also update any pins in
  `test/controllers/developers/*`, `test/controllers/oauth/authorizations_controller_test.rb` or
  `test/controllers/developers_controller_test.rb` that list scopes.

**Interfaces:**
- Produces: the scope strings `books:library:read` and `books:library:write`, and the fixtures
  `ApiTokenSecrets::LIBRARY` and `ApiTokenSecrets::LIBRARY_READ`. Later tasks use these for auth.

- [ ] **Step 1: Write failing tests.**
  - `Scopes.all` equals the registry order in Global Constraints.
  - `Scopes.eligible_for(users(:regular_user))` includes both library scopes.
  - `Scopes.eligible_for(users(:user_with_expired_membership))` includes neither.
  - `Scopes.satisfies?(["books:library:write"], "books:library:read")` is true.
  - `Scopes.satisfies?(["books:admin:merge"], "books:library:read")` is false.
  - `Oauth::Resources.fetch("mcp").scopes("books") == ["books:read", "books:library:read", "books:library:write"]`.
  - `Oauth::Resources.fetch("mcp").scopes("music") == ["music:read"]`.
  - The admin resource's scopes are unchanged.
  - The `/.well-known/oauth-protected-resource/api/mcp` metadata lists the three books scopes in
    `scopes_supported`.
- [ ] **Step 2: Run** `bin/rails test test/lib/api/scopes_test.rb test/lib/oauth test/controllers/oauth test/controllers/developers test/controllers/developers_controller_test.rb`.
  Expected: FAIL on the new assertions.
- [ ] **Step 3: Implement** the scopes, the resource change and the fixtures.
- [ ] **Step 4: Run the Step 2 command, plus `test/controllers/api test/lib/mcp`.** Expected:
  PASS. Fix any scope-list pins that the new scopes legitimately change.
- [ ] **Step 5: Commit:** `git commit -m "Scopes: books:library:read and books:library:write, offered on /api/mcp"`

### Task 2: Shared write path — OwnerMutation and the batch services

**Files:**
- Create: `web-app/app/lib/services/user_lists/owner_mutation.rb`
- Create: `web-app/app/lib/services/user_lists/add_items.rb`, `remove_items.rb`, `update_item.rb`
- Modify: `web-app/app/models/user_list.rb`. Add `move_item!(item, to_position)`.
- Modify: `web-app/app/controllers/user_list_items_controller.rb`.
  `mutate_with_books_goal_invalidation` delegates to `OwnerMutation` and keeps its non-book early
  return, so music, games and movies still take no lock.
- Test: new `web-app/test/lib/services/user_lists/{owner_mutation,add_items,remove_items,update_item}_test.rb`
  and `web-app/test/models/user_list_test.rb`. Also run
  `web-app/test/controllers/user_list_items_controller_test.rb` unchanged as the regression check.

**Interfaces:**
- Produces:
  - **`Services::UserLists::OwnerMutation.call(owner:) { |tracker| ... } -> block value`.**
    - It runs the block inside `owner.with_lock`, which is the batch's transaction.
    - `tracker.track(mutation_result)` records a successful `MutationResult` whose
      `data[:listable]` is a `::Books::Book`, by calling
      `tracker.change(old_completed_on:, new_completed_on:)`. Task 6's list delete calls `change`
      directly for each dated item. For each change it calls
      `CompletionChangeInvalidator.call(user: owner, old_completed_on:, new_completed_on:, enqueue: false)`
      inside the lock.
    - After the lock it enqueues one `Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls.uniq)`
      through `ActiveRecord::Base.current_transaction.after_commit`, only when `urls` is non-empty.
    - An exception from the block propagates, so the lock's transaction rolls back and nothing is
      enqueued.
  - **`Services::UserLists::BatchFailed < StandardError`,** with a `#errors -> Array<String>`.
  - **`Services::UserLists::AddItems.call(user_list:, listables:, completed_on: nil) -> MutationResult`.**
    - `data` is `{outcomes: [{listable:, outcome:}]}`.
    - Each listable goes through `AddItem`:
      - a success with `transitioned` is `moved`, otherwise `added`;
      - the failure `["Item already in list"]` is `already_present`;
      - any other failure raises `BatchFailed`, which becomes `MutationResult.failure(errors)`.
    - When `completed_on` is a Date, every named item whose date differs goes through
      `UpdateCompletion`. An `already_present` book whose date changes becomes `updated`.
    - `completed_on` on a list without `completed_on_enabled?` is
      `failure(["Completion dates are not enabled for this list"])`.
  - **`Services::UserLists::RemoveItems.call(user_list:, listables:) -> MutationResult`.** The
    outcomes are `removed`, or `not_present` when the list doesn't hold the book. Any `RemoveItem`
    failure rolls the whole batch back.
  - **`Services::UserLists::UpdateItem.call(item:, completed_on: :unchanged, position: :unchanged) -> MutationResult`.**
    - `completed_on` (a Date or nil) goes through `UpdateCompletion`.
    - `position` goes through `user_list.move_item!`.
    - Both run under `OwnerMutation`.
  - **`UserList#move_item!(item, to_position)`.**
    - It accepts `to_position` from 1 to `user_list_items.count`, counting every item including
      hidden provisional ones. Anything else raises `ArgumentError`.
    - It shifts the rows between the old and new positions by one with a single `update_all`, then
      sets the item's position.
    - It sets `manually_ordered: true`.
    - Positions stay contiguous 1..N.
  - Every batch service runs inside `OwnerMutation` and takes `today: Date.current` the way
    `AddItem` does.

- [ ] **Step 1: Write failing tests.** Use `users(:regular_user)`'s `:regular_user_books_read`
  list, a `reading` list created in the test, and `books_books(:war_and_peace)`,
  `(:crime_and_punishment)` and one more fixture book (check `test/fixtures/books/books.yml`).
  - **`add_items`:**
    - Three new books give outcomes `[added, added, added]`, in order, at positions 1–3.
    - Re-adding one gives `already_present`, and no row is created.
    - Review Focus 2: with `crime_and_punishment` on `reading`, adding
      `[war_and_peace, crime_and_punishment]` to `read` gives `[added, moved]`. Crime and Punishment
      is gone from `reading` and its `completed_on` is today. Exactly one `PurgeCachedPagesJob` is
      enqueued (`Sidekiq::Testing.fake!`) when the invalidator returns urls (stub it to return
      `["/x"]`).
    - `completed_on: Date.new(2024, 3, 1)` with one book already on `read` (dated nil) gives
      `updated` for that book and dates both.
    - `completed_on` on the favorites list is a failure, and nothing is written.
    - Review Focus 1: stub `AddItem.call` to fail with `["boom"]` on the third listable. The result
      is a failure, the first two are not on the list, and no purge is enqueued.
  - **`remove_items`:**
    - `[on_list, not_on_list]` gives `[removed, not_present]`, and the remaining positions are
      contiguous.
    - A stubbed `RemoveItem` failure on the second rolls back the first.
  - **`update_item`:**
    - Setting `completed_on` to a date, then to nil, sets and clears it.
    - `position` moves the item.
  - **`move_item!`** (Review Focus 5): a list of 4 items where item 3's book is provisional
    (`provisional: true`).
    - Moving item 4 to position 1 gives positions 1..4 contiguous, in order 4,1,2,3, and
      `manually_ordered` true.
    - `to_position` 5 or 0 raises `ArgumentError`.
  - **`owner_mutation`:**
    - It tracks only Book listables.
    - An exception in the block re-raises and enqueues nothing.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/user_lists test/models/user_list_test.rb`.
  Expected: FAIL (`NameError` on the new classes).
- [ ] **Step 3: Implement** the services and `move_item!`, then switch the web controller's helper
  to `OwnerMutation`.
- [ ] **Step 4: Run the Step 2 command, plus `test/controllers/user_list_items_controller_test.rb`.**
  Expected: PASS, with the web controller tests unchanged.
- [ ] **Step 5: Commit:** `git commit -m "User lists: owner-locked batch services shared by web and API"`

### Task 3: Library budget

**Files:**
- Modify: `web-app/config/initializers/api.rb`. Add the three settings from Global Constraints,
  each with a one-line comment.
- Create: `web-app/app/lib/services/api/library_budget.rb`
- Test: `web-app/test/lib/services/api/library_budget_test.rb`

**Interfaces:**
- Produces: `Services::Api::LibraryBudget`.
  - Methods:
    - `.reserve(user, count, now: Time.current) -> Reservation`
    - `.release(user, count, now: Time.current) -> nil`
    - `.remaining(user, now: Time.current) -> Integer`
  - `Reservation = Struct.new(:ok, :remaining, :limit, :reset_at, keyword_init: true)` with
    `ok?`.
  - The store is `Rails.application.config.x.rate_limit_store`.
  - The key is `"api:library:u:#{user.id}:d:#{now.utc.to_date.iso8601}"`, and it expires at the
    next UTC midnight plus 1 second. `reset_at` is that midnight.
  - `reserve` increments by `count`. When the new total is over the limit, it decrements by `count`
    and returns `ok: false`, with `remaining` being the count before this call subtracted from the
    limit.
  - A nil from `increment` fails open (`ok: true, remaining: limit`), as `RateLimiter#increment`
    does.

- [ ] **Step 1: Write failing tests.** Use the test MemoryStore and `travel_to` for the day.
  - Reserving 10 leaves `remaining` at 990.
  - Review Focus 3: after reserving 990, reserving 20 is `ok? == false`, `remaining == 10`, and
    `remaining(user)` stays 10. Reserving 10 is then `ok?` with `remaining == 0`.
  - `release(user, 5)` gives 5 back.
  - The next UTC day starts at 1,000.
  - Two users don't share a count.
  - A store whose `increment` returns nil gives `ok? == true`.
- [ ] **Step 2: Run** `bin/rails test test/lib/services/api/library_budget_test.rb`. Expected:
  FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it again; expect PASS.**
- [ ] **Step 5: Commit:** `git commit -m "API: daily library change budget"`

### Task 4: Read endpoints — `list_my_lists`, `list_my_list_books`, `list_my_book_lists`

**Files:**
- Create: `web-app/app/controllers/concerns/api/library.rb`, the `Api::Library` concern.
- Create: these controllers, which include the concern:
  - `web-app/app/controllers/api/v1/books/my/lists_controller.rb` (`index` here; Task 6 adds
    create, update and destroy);
  - `web-app/app/controllers/api/v1/books/my/list_books_controller.rb` (`index` here; Task 5 adds
    the writes);
  - `web-app/app/controllers/api/v1/books/my/book_lists_controller.rb` (`index`).
- Create: `web-app/app/lib/api/v1/books/user_list_resource.rb` (Alba).
- Modify: `web-app/config/routes.rb`. Inside the API's `scope module: :books`, add
  `scope "my", module: :my, as: :my do … end` with these GET routes:
  - `lists` → `lists#index`
  - `lists/:list/books` → `list_books#index`
  - `books/:slug/lists` → `book_lists#index`
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - the three paths, with operationIds `listMyLists`, `listMyListBooks` and `listMyBookLists`;
  - schemas `UserList`, `UserListCollection`, `UserListBook`, `UserListBookCollection`,
    `BookListMembership` and `BookListMembershipCollection`;
  - parameters `my_list` (path `{list}`, string) and `my_list_books_sort`.
- Test:
  - `web-app/test/controllers/api/v1/books/my/{lists,list_books,book_lists}_controller_test.rb`;
  - `test/integration/api/v1/contract_coverage_test.rb`;
  - `test/integration/api/v1/operation_scope_contract_test.rb`;
  - both path lists in `test/controllers/api/v1/openapi_controller_test.rb`;
  - `test/lib/mcp/tool_directory_test.rb` (29 → 32 entries, 28 → 31 non-composite);
  - `test/lib/mcp/catalog_test.rb`;
  - `test/controllers/api/mcp_controller_test.rb`.

**Interfaces:**
- Produces (`Api::Library`, private helpers that Tasks 5 and 6 reuse):
  - **`library_user`**: `current_principal.user`.
  - **`find_my_list!(raw) -> ::Books::UserList | nil`.**
    - A digit string matches `library_user.user_lists.where(type: "Books::UserList").find_by(id:)`.
    - A default name runs `EnsureDefaults.call(user:, domain: :books, existing:)` and picks the list
      whose `list_type` matches.
    - Anything else renders a 404 `not_found` problem ("No list …") and returns nil.
  - **`book_count_for(lists) -> {list_id => Integer}`.** One grouped query over
    `::Books::UserList.catalog_items(UserListItem.where(user_list_id:))`.
  - **`ranks_for(book_ids)`.** Copy it from `ListItemsController` (primary ranking, one query).
- Produces: `Api::V1::Books::UserListResource`.
  - Attributes, in this order: `id, name, list_type, default, description, public, book_count`
    (from `params[:book_count]`), `created_at, updated_at, url, api_url, books_api_url`.
  - `url` is `"#{Api::Host.base_url}/my/lists/#{id}"`.
  - `api_url` is `/api/v1/my/lists/#{id}`, and `books_api_url` is that plus `/books`.
- Scopes:
  - `require_scope "books:library:read"` on all three controllers' `index`.
  - Task 5 and Task 6 switch to `require_scopes` maps.

**Behaviour:**
- **`list_my_lists`:**
  - It runs EnsureDefaults first.
  - The order is default lists by `list_type_before_type_cast`, then custom lists by
    `name.downcase`, the `/my/lists` order.
  - It's paged with `render_page`. The relation has to be a relation: order defaults first with
    `ORDER BY (list_type = 4), list_type, LOWER(name)`.
- **`list_my_list_books`:**
  - The rows are the list's catalogue items (`Books::UserList.catalog_items`), with includes as in
    `ListItemsController`.
  - Each row is `{position, added_at: item.created_at, completed_on, book: BookResource(rank:)}`.
  - `sort` is one of `position` (`position ASC`, the default), `added` (`created_at DESC, id DESC`)
    or `completed_on` (`completed_on DESC NULLS LAST, position ASC`).
  - `sort=completed_on` on a list without completion dates is a 400.
  - `links` carry `sort`.
- **`list_my_book_lists`:**
  - An unknown catalogue slug is a 404.
  - The rows are the user's `Books::UserList` items for that book:
    `{list: UserList, position, added_at, completed_on}`, in the `list_my_lists` order.
- **`x-mcp` descriptions:**
  - `list_my_lists`: these are the token holder's own lists; the four default list names can be
    used as `list` in the other library tools.
  - `list_my_list_books`: the `sort` options; books not yet in the catalogue are not shown, so
    positions can skip numbers.
  - `list_my_book_lists`: answers "is this book on my read list?".

- [ ] **Step 1: Write failing tests** (auth `bearer(ApiTokenSecrets::LIBRARY_READ)`).
  - **`lists`:**
    - 200 lists the user's four default books lists first, in favorites, read, reading,
      want_to_read order, then custom ones by name.
    - The reading and want_to_read lists are created by the call.
    - Another user's lists and music lists are absent.
    - `book_count` excludes a provisional book.
  - **`list_books`:**
    - `read` and the numeric id give the same list.
    - Review Focus 4:
      - `reading` for a user without one is a 200, and the list now exists;
      - another user's list id is a 404;
      - `bogus` is a 404.
    - `sort=added` and `sort=completed_on` orders are right.
    - `sort=completed_on` on favorites is a 400.
    - A provisional book is absent.
    - `rank` is the primary rank.
  - **`book_lists`:** a book on read and on a custom list returns both, with `completed_on`. An
    unknown slug is a 404.
  - **Scope:** `bearer(ApiTokenSecrets::MEMBER)` (books:read only) is a 403 `insufficient_scope`.
  - **Contract coverage:** 200, 400 (where a parameter can be bad), 401, 403, 404 and 429 for
    each, like the `lists/{id}/items` entries.
  - **MCP:**
    - `tools/list` with `MEMBER` doesn't include `list_my_lists`, and with `LIBRARY_READ` it does.
    - One `tools/call` of `list_my_list_books` with `{"list": "read"}` returns 200 data.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/my test/integration/api/v1 test/lib/mcp test/controllers/api`.
  Expected: FAIL.
- [ ] **Step 3: Implement** the concern, resource, controllers, routes and OpenAPI.
- [ ] **Step 4: Run the Step 2 command; expect PASS.**
- [ ] **Step 5: Commit:** `git commit -m "Public API + MCP: read a member's book lists"`

### Task 5: Book writes — `add_my_list_books`, `update_my_list_book`, `remove_my_list_books`

**Files:**
- Create: `web-app/app/controllers/concerns/api/json_body.rb`. Move `json_body`, `bad_body` and
  `unknown_fields(unknown, allowed)` from
  `app/controllers/api/v1/admin/books/series_writes.rb` into it, and include it in `SeriesWrites`.
  Ruling: the other admin controllers' differently shaped copies stay as they are.
- Modify: `web-app/app/controllers/concerns/api/library.rb`. Add the helpers listed below.
- Modify: `web-app/app/controllers/api/v1/books/my/list_books_controller.rb`. Add `create`,
  `update` and `destroy`, with `require_scopes` read for index and write for the rest.
- Modify: `web-app/config/routes.rb`:
  - `post "lists/:list/books"` → `list_books#create`
  - `patch "lists/:list/books/:slug"` → `list_books#update`
  - `delete "lists/:list/books"` → `list_books#destroy`
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - operationIds `addMyListBooks`, `updateMyListBook` and `removeMyListBooks`;
  - schema `LibraryWriteResult`;
  - request bodies:
    - `{books: array of string, 1–50 items, completed_on?: date}`;
    - `{completed_on?: date | null, position?: integer >= 1}`.
  - `removeMyListBooks` has `x-mcp destructive: true` and its `books` is a comma-separated query
    string, like `category_id`.
- Test: `web-app/test/controllers/api/v1/books/my/list_books_controller_test.rb`, contract coverage,
  the operation scope contract, the openapi path lists, and the MCP pins (32 → 35 entries,
  31 → 34 non-composite).

**Interfaces:**
- Consumes: `AddItems`, `RemoveItems` and `UpdateItem` (Task 2), `LibraryBudget` (Task 3),
  `find_my_list!` (Task 4).
- Produces (`Api::Library`):
  - **`book_slugs!(raw) -> Array<String> | nil`.**
    - It accepts an Array of Strings (body) or a comma-separated String (query).
    - It strips each slug and removes duplicates, keeping the first occurrence.
    - It requires 1..`library_batch_max` slugs. Otherwise it renders a 400 naming `books` and
      returns nil.
  - **`catalog_books!(slugs) -> Array<::Books::Book> | nil`.** Books come back in slug order. Any
    unknown slug renders a 404 whose detail lists every unknown slug, and returns nil.
  - **`completed_on!(raw, allow_nil:) -> Date | nil | :absent`.** Only an ISO `YYYY-MM-DD` no later
    than `Date.current` is accepted; anything else renders a 400.
  - **`with_budget(count) { ... } -> rendered`.**
    - It reserves `count`. When that's refused, it renders the 429 `rate_limited` with detail
      `"Daily library limit of 1000 book changes reached; N remaining. Retry after S seconds."`
      and `Retry-After` until `reset_at`.
    - Otherwise it yields. When the block's response status isn't 2xx, or it raises, it releases
      `count`.
  - **`write_result(list, outcomes, status: :ok)`** renders the batch response from Global
    Constraints:
    - `book` is the slug;
    - `meta.list` is `UserListResource` with a fresh `book_count`;
    - `library_changes_remaining` comes from `LibraryBudget.remaining`.
- Validation order for each write: body/query (400) → list (404) → rules (422) → books (404) →
  budget (429) → service (a failure is a 422 whose detail is the joined errors).
- **The rules (422):**
  - an unknown body key, reported through `unknown_fields`;
  - `completed_on` when `list.completed_on_enabled?` is false;
  - on `update`, a book that isn't on the list;
  - a `position` past `user_list_items.count`.
  - A non-integer or < 1 `position` is a 400.
  - On `update`, a body with neither field is a 400.
- **Budget count:** the number of unique books named. Update counts 1.

- [ ] **Step 1: Write failing tests** (auth `bearer(ApiTokenSecrets::LIBRARY)` unless stated):
  - **`add_my_list_books`:**
    - `POST /api/v1/my/lists/read/books`, `{books: [war_and_peace, crime_and_punishment]}`, gives
      200, outcomes in order, `meta.list.book_count == 2` and `meta.library_changes_remaining == 998`.
    - Duplicate slugs count once.
    - 51 slugs is a 400. `books: []` is a 400. `books: "x"` (not an array) is a 400.
    - Two unknown slugs are a 404 naming both, and nothing is written.
    - `completed_on: "2999-01-01"` is a 400.
    - `completed_on` on favorites is a 422.
    - `{books: [...], color: "red"}` is a 422.
    - `bearer(ApiTokenSecrets::LIBRARY_READ)` is a 403.
  - Review Focus 1: stub `Services::UserLists::AddItems.call` to return
    `MutationResult.failure(["boom"])`. The response is a 422, and `LibraryBudget.remaining` is
    unchanged.
  - Review Focus 3: pre-reserve 990 with `LibraryBudget.reserve`.
    - A 20-book call is a 429 with a `Retry-After` header, and nothing is written.
    - A 10-book call is a 200 with `library_changes_remaining == 0`.

    Build the books with `Books::Book.create!` in the test if there aren't 20 fixtures.
  - **`update_my_list_book`:**
    - `PATCH …/read/books/war-and-peace {completed_on: "2024-03-01"}` is a 200 with outcome
      `updated`.
    - `{completed_on: null}` clears it.
    - `{position: 1}` moves the book.
    - `{position: 99}` is a 422.
    - `{}` is a 400.
    - A book that isn't on the list is a 422.
  - **`remove_my_list_books`:** `DELETE …/read/books?books=war-and-peace,crime-and-punishment` with
    one on the list gives `[removed, not_present]` and counts 2 against the budget.
  - **Contract coverage:** every documented status for each of the three. The 429 has two exercises
    in the test body, the request limit and the budget, but there's one EXERCISES entry per status
    (use the budget one).
  - **MCP:**
    - `tools/call` of `add_my_list_books` with `{"list": "want_to_read", "books": ["<slug>"]}`
      returns outcome `added`.
    - `remove_my_list_books` is annotated `destructive_hint: true`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/my test/controllers/api/v1/admin test/integration/api/v1 test/lib/mcp test/controllers/api`.
  Expected: FAIL on the new tests.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the Step 2 command; expect PASS** (the admin series tests still pass after the
  helper move).
- [ ] **Step 5: Commit:** `git commit -m "Public API + MCP: add, update and remove books on a member's list"`

### Task 6: List writes — `create_my_list`, `update_my_list`, `delete_my_list`

**Files:**
- Modify: `web-app/app/controllers/api/v1/books/my/lists_controller.rb`. Add `create`, `update`
  and `destroy`, with `require_scopes` read for index and write for the rest.
- Modify: `web-app/config/routes.rb`:
  - `post "lists"` → `lists#create`
  - `patch "lists/:list"` → `lists#update`
  - `delete "lists/:list"` → `lists#destroy`
- Modify: `web-app/config/api/v1/openapi.yaml`:
  - operationIds `createMyList`, `updateMyList` and `deleteMyList` (`x-mcp destructive: true`);
  - schema `UserListCreated`, which is `{data: UserList, meta: {results: [...], library_changes_remaining}}`;
  - `UserListDetail`, which is `{data: UserList}`.
- Test: `web-app/test/controllers/api/v1/books/my/lists_controller_test.rb`, contract coverage, the
  operation scope contract, the openapi path lists, and the MCP pins (35 → 38 entries, 34 → 37
  non-composite).

**Interfaces:**
- Consumes: the Task 4 and Task 5 helpers, plus `AddItems`.

**Behaviour:**
- **`create`:**
  - The body keys are `name` (required), `description`, `public` (a boolean; anything else is a
    400) and `books` (optional).
  - The field limits come from Global Constraints. A blank name is a 400.
  - The user's `Books::UserList` custom count at `max_custom_lists` is a 422.
  - With `books`: validate, then check the budget for their count, then create the list and run
    `AddItems` in one transaction under `OwnerMutation`. A failure rolls the list back too.
  - It returns 201 `UserListCreated`. `results` is `[]` when there were no books.
- **`update`:**
  - The body keys are any of `name`, `description` and `public`. An empty body is a 400.
  - `name` on a default list is a 422.
  - It returns 200 `UserListDetail`.
- **`destroy`:**
  - A default list is a 422.
  - Otherwise it destroys the list (`dependent: :destroy` takes the items) under `OwnerMutation`,
    calling `tracker.change(old_completed_on: date, new_completed_on: nil)` for each dated item.
  - It returns 200 `UserListDetail` with the list as it was. `book_count` is taken before the
    destroy.
  - It costs no budget.

- [ ] **Step 1: Write failing tests:**
  - **`create`:**
    - `{name: "Summer 2027"}` gives 201, `list_type == "custom"` and `public == false`.
    - With 2 books, both are on the list and `library_changes_remaining == 998`.
    - With an unknown slug it's a 404, and no list is created.
    - A 101-character name is a 400.
    - `public: "yes"` is a 400.
    - With 500 custom lists (insert them with `insert_all` in the test) it's a 422.
  - **`update`:**
    - Renaming a custom list works.
    - `public: true` on `favorites` works.
    - Renaming `read` is a 422.
    - Another user's list is a 404.
  - **`destroy`:**
    - A custom list with items is gone, along with its items.
    - `favorites` is a 422.
    - A `read` list can't be deleted (422).
    - `bearer(ApiTokenSecrets::LIBRARY_READ)` is a 403.
  - **Contract coverage:** every documented status.
  - **MCP:**
    - `delete_my_list` has `destructive_hint: true`.
    - `create_my_list` appears for `LIBRARY` and not for `LIBRARY_READ`.
- [ ] **Step 2: Run** `bin/rails test test/controllers/api/v1/books/my test/integration/api/v1 test/lib/mcp test/controllers/api`.
  Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the Step 2 command; expect PASS.**
- [ ] **Step 5: Commit:** `git commit -m "Public API + MCP: create, edit and delete a member's custom lists"`

### Task 7: Instructions and docs, then the full suite

**Files:**
- Modify: `web-app/config/mcp/books/instructions.md`. Add the library paragraph, with every point
  in the spec's "MCP instructions" section. Keep any phrases pinned by
  `test/lib/mcp/sites/books_test.rb` true.
- Modify:
  - `docs/features/public-api.md`: the nine endpoints, the scopes, the budget and the batch rules.
  - `docs/features/mcp-server.md`: the nine tools, and the note that existing connections must
    reconnect to get them.
  - `docs/features/user-lists.md`: an API section; a note on the shared `OwnerMutation` path and
    `move_item!`; and a change to the Phase B note so it says the API already renames, deletes and
    reorders.
- Modify: `web-app/app/views/developers/show.html.erb`, only if it lists scopes by hand rather than
  from `Api::Scopes`.

- [ ] **Step 1: Edit the files above.**
- [ ] **Step 2: Run** `bin/rails test test/lib/mcp/sites/books_test.rb`. Expected: PASS.
- [ ] **Step 3: Run the full suite and the linter.** From `web-app/`, run `bin/rails test` and
  `bundle exec standardrb`. Expected: 0 failures, 0 errors, no new warning lines; standardrb
  clean. Also run `CI=1 bin/rails zeitwerk:check`, because the new `My` controller namespace has to
  load eagerly.
- [ ] **Step 4: Commit:** `git commit -m "Library API: instructions and docs"`
