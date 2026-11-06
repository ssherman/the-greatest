# Cached Per-User State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed-in page view makes zero Rails requests in the common case and never more than one, by caching per-user state in localStorage, updating it from the visitor's own writes, and re-checking at most hourly with a conditional request.

**Architecture:** `/user_list_state` becomes the one combined state endpoint (lists, memberships, membership status) with a payload-digest ETag so an unchanged re-check is a bodyless 304. `user_list_state_controller.js` owns the browser cache: it re-checks only when the entry is missing, older than an hour, or invalidated by a same-device change marker cookie, and never on a page that already costs a request by loading. `membership_state_controller.js` and `csv_export_controller.js` read from it instead of fetching `/membership_state`.

**Tech Stack:** Rails 8, Minitest + Mocha + fixtures, Stimulus, Playwright.

**Spec:** `docs/superpowers/specs/2026-10-28-cached-user-state-design.md`

## Global Constraints

- Run Rails/yarn commands from `web-app/`. Lint with `bundle exec standardrb`. No brakeman.
- A signed-in **page load** makes at most one Rails request; clicks (writes, opening the list modal, Download CSV) are outside that budget.
- Re-check interval: **one hour** (`RECHECK_AFTER_MS = 60 * 60 * 1000`).
- No Set-Cookie and no per-visitor byte on an edge-cacheable response (`request.session_options[:skip]` true). Markers that vary only by page/action (identical for every visitor of that page) are fine.
- CSRF tokens are never written to localStorage.
- The cache entry is discarded when its `user_id` differs from `tg_uid`, on sign-out, on 401, and on sign-in.
- `tg_uid` and the change-marker cookie are presentation hints, never trusted server-side.
- `/membership_state` keeps working unchanged (old edge-cached pages still call it during the deploy window); new JS no longer calls it.
- **This machine is under heavy load from another agent.** Run E2E scoped to the files a task touches, serially: `npx playwright test --config=e2e/playwright.config.ts --workers=1 --timeout=120000 <files>` (after `bin/rails e2e:prepare`). A timeout under load is not a product failure until it reproduces on a re-run of that one test; record re-runs in the report. Check port 3000 is free (AGENTS.md command) before starting `bin/rails server`; never kill another checkout's server.
- Minitest 6 (`assert_nil`). Controller tests assert behaviour, not markup. Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never commit to `main`.

## Review Focus

1. **A book page (or any page that already costs a request) when the hourly re-check is due** must make exactly one Rails request, and the re-check must happen on the next ordinary page. Pinned in Task 4 (E2E).
2. **A shared browser**: user A's cached lists/membership must never render after user B signs in. Pinned in Task 4 (E2E) and Task 3 (`user_id` check retained).
3. **An unchanged re-check returns 304 with no body and still renews the session.** Pinned in Task 1.
4. **Membership granted or expiring changes the ETag** even though no list changed (expiry is time-based, not a row write). Pinned in Task 1.
5. **A write from the list modal on a page with no cache entry** still works (fetches state + CSRF on interaction) and does not count against the page-load budget. Pinned in Task 4 (E2E on a book page right after sign-in).

---

### Task 1: Combined state endpoint with ETag/304

**Files:**
- Modify: `web-app/app/controllers/user_list_state_controller.rb`
- Test: `web-app/test/controllers/user_list_state_controller_test.rb`

**Interfaces:**
- Produces: `GET /user_list_state` JSON gains `membership: { member: Boolean, plan:, source:, current_period_end: (iso8601|null) }` (same values and nil semantics as `MembershipStateController#show`) alongside the existing `version, domain, user_id, lists, memberships, csrf_token`. Response carries an `ETag` that is a digest of the payload **excluding `csrf_token` and `version`**; a request whose `If-None-Match` matches gets `304` with no body. `renew_current_session` still runs on both 200 and 304.

- [ ] **Step 1: Write failing tests** in `user_list_state_controller_test.rb`:
  - `"includes membership status"`: a member fixture user (check `test/fixtures/memberships.yml` for a granting membership) → `json["membership"]["member"] == true`; a non-member → `false` and `current_period_end` nil.
  - `"sends an ETag and answers 304 when it matches"`: GET, capture `response.headers["ETag"]`, GET again with `headers: {"If-None-Match" => etag}` → `assert_response :not_modified`, `assert_empty response.body`.
  - `"the ETag changes when an item is added, an item is removed, and a list is created"`: one assertion per change, each comparing ETags before/after.
  - `"the ETag changes when membership is granted and when it expires"`: grant → differs; `travel` past `current_period_end` → differs (no row write).
  - `"a 304 still renews a session last active over a day ago"`: travel 2 days, conditional GET → 304, `last_active_at` moved.
  - `"the ETag does not depend on the CSRF token"`: two GETs in different sessions for the same user and state → same ETag.
- [ ] **Step 2: Run** `bin/rails test test/controllers/user_list_state_controller_test.rb`. Expected: FAIL.
- [ ] **Step 3: Implement.** Build the payload hash without `csrf_token`/`version`; `fresh_when(etag: payload)` (Rails digests it); render `payload.merge(version:, csrf_token: form_authenticity_token)` only when not fresh. Keep `prevent_caching`; confirm the 304 path keeps `Cache-Control: no-store`.
- [ ] **Step 4: Run** the file, then `bin/rails test test/controllers/`. Expected: PASS.
- [ ] **Step 5: Commit** `user_list_state carries membership and answers conditional requests`.

### Task 2: Change-marker cookie and the "page already costs a request" signal

**Files:**
- Create: `web-app/app/controllers/concerns/user_state_change_marker.rb`, `web-app/test/controllers/user_state_change_marker_test.rb`
- Modify: `web-app/app/controllers/user_lists_controller.rb`, `web-app/app/controllers/user_list_items_controller.rb`, `web-app/app/controllers/membership_controller.rb` (`thanks`), the three public layouts `web-app/app/views/layouts/{books,music,games}/application.html.erb` (movies is out of scope — leave it), `web-app/app/components/reviews/widget_component*` (the widget's root element), `web-app/app/views/books/reading_goals/show.html.erb`

**Interfaces:**
- Produces: `UserStateChangeMarker::COOKIE = :tg_state_mark`; `mark_user_state_changed -> void` (private; sets `tg_state_mark` to `SecureRandom.hex(8)`, plain, `SameSite=Lax`, Secure in production, path `/`, 1-year expiry; **no-op when `request.session_options[:skip]`**). Called after a successful write in `UserListsController#create`, `UserListItemsController#create/#destroy/#update_completion`, and in `MembershipController#thanks`.
- Produces: uncached responses render `<meta name="tg-page-request" content="1">` in the three layouts' `<head>` (condition: `!request.session_options[:skip]`). Cacheable pages that make their own state request on load carry `data-tg-page-request` on an element: the review widget root and the public reading-goal page's state element.

- [ ] **Step 1: Write failing tests:** `"a list item write sets tg_state_mark"`, `"each write sets a different value"`, `"membership thanks sets tg_state_mark"`, `"a cacheable page sets no tg_state_mark"` (reuse the `with_routing` probe pattern from `test/controllers/session_authentication_test.rb`: a probe action that calls `skip_session_for_caching` then `mark_user_state_changed`; assert no Set-Cookie), `"an uncached page carries the tg-page-request meta and a cacheable page does not"` (assert on the presence of the meta tag only — behaviour, not copy: `/my/lists` vs a books cacheable page).
- [ ] **Step 2: Run** the new test file. Expected: FAIL.
- [ ] **Step 3: Implement** the concern (include it in `ApplicationController`), the call sites, the layout meta, and the two `data-tg-page-request` attributes.
- [ ] **Step 4: Run** `bin/rails test`. Expected: PASS, no new warnings.
- [ ] **Step 5: Commit** `Change-marker cookie for same-device writes; mark pages that already cost a request`.

### Task 3: Browser cache policy

**Files:**
- Modify: `web-app/app/javascript/controllers/user_list_state_controller.js`, `web-app/app/javascript/controllers/membership_state_controller.js`, `web-app/app/javascript/controllers/csv_export_controller.js`, `web-app/app/javascript/controllers/user_list_widget_controller.js`, `web-app/app/javascript/controllers/user_list_modal_controller.js`, `web-app/app/javascript/controllers/user_list_add_item_controller.js` (only if it reads state)

**Interfaces:**
- Consumes: Task 1's payload/ETag; Task 2's `tg_state_mark` cookie, `meta[name="tg-page-request"]`, `[data-tg-page-request]`.
- Produces in `user_list_state_controller.js`:
  - `STATE_SCHEMA = 3`; stored entry adds `etag`, `checkedAt` (ms), `seenMark` (the `tg_state_mark` value when last checked or last locally applied), and `membership`.
  - `pageCostsRequest() -> boolean` — true if `meta[name="tg-page-request"]` or any `[data-tg-page-request]` exists.
  - `isStale() -> boolean` — no entry, `Date.now() - checkedAt > RECHECK_AFTER_MS`, or current `tg_state_mark` cookie ≠ `seenMark`.
  - `connect()`: hydrate; if signed in and `isStale()` and `!pageCostsRequest()`, `refresh({ conditional: true })`; otherwise no request.
  - `refresh({ conditional })`: sends `If-None-Match: entry.etag` when conditional and an entry exists. 304 → set `checkedAt = Date.now()`, `seenMark = current mark`, persist, no dispatch of new data. 200 → replace entry (store `etag` from the response header), dispatch `user-list-state:updated`. 401 → existing clearing behaviour.
  - `ensureState() -> Promise` — if no entry, `refresh({ conditional: false })`. Called by widgets/modal on first interaction.
  - `ensureCsrf()` — if no token in memory, `refresh({ conditional: false })` (a 304 carries no token).
  - `applyMutation(...)` additionally sets `seenMark` to the current `tg_state_mark` value (the server just set it for this very write).
  - `_onAuthSuccess`: clear the entry (the page reloads anyway).
- `membership_state_controller.js`: no fetch. Reveals `#navbar_members` from `state.membership.member` on `user-list-state:loaded`/`updated`; hides on `user-list-state:cleared`, `auth:signout`, or no `tg_uid`. Keep the "hidden is the safe default" behaviour.
- `csv_export_controller.js`: on click, `await stateCtrl.refresh({ conditional: true })`, then decide from the (possibly unchanged) entry's `membership.member`; a 401 still opens the sign-in modal.
- Widgets/modal: when there is no entry, render empty (as today when not hydrated) and call `ensureState()` on first interaction.

- [ ] **Step 1:** Implement per the Interfaces block. Read every comment in these controllers first; several encode past bugs (shared-browser user check, CSRF never persisted, Turbo restore re-running `connect()`).
- [ ] **Step 2: Build** `yarn build:all`. Expected: success, no Rollup warnings. Run `bin/rails test test/lint/`. Expected: PASS.
- [ ] **Step 3: Commit** `Browser caches per-user state; re-checks hourly within a one-request budget`.

### Task 4: E2E on books, music and games; docs

**Files:**
- Create: `web-app/e2e/support/state-requests.ts`, `web-app/e2e/tests/{books,music,games}/auth/state-requests.spec.ts`
- Modify: `docs/features/authentication.md` (or the feature doc that describes `/user_list_state`; find it with `grep -rln user_list_state docs/features`)

**Interfaces:**
- Produces: `countStateRequests(page) -> { get(): number }` — records requests to `/user_list_state`, `/membership_state`, `/review_state` (Rails state endpoints) from the moment it is attached. `ageCache(page, ms)` — rewrites the localStorage entry's `checkedAt` to `Date.now() - ms`.
- Each spec: `test.use({ storageState: { cookies: [], origins: [] } })`, `signIn` with `credentials('USER')` on books and `credentials('ADMIN')` on music/games (as the existing sign-in-state specs do).

- [ ] **Step 1: Write tests** in each domain spec:
  - `"ordinary pages make no state requests within the hour"`: sign in, load one ordinary page (fills the entry), attach the counter, visit three more ordinary pages → `0`.
  - `"an aged cache makes exactly one conditional request"`: `ageCache(page, 61 * 60 * 1000)`, load an ordinary page → `1`, and the request carried `If-None-Match`.
  - `"the Members link shows without a /membership_state request"` (books: use the MEMBER account): → link visible, counter shows 0 `/membership_state`.
  - Books only: `"a book page makes exactly one state request even when the re-check is due"`: age the cache, open a book show page → exactly 1 (the `/review_state`); then an ordinary page → 1 `/user_list_state`.
  - Books only: `"adding to a list from a book page right after sign-in works"`: sign in from a book page, add the book to a list via the widget → succeeds; reload → the widget shows it without a `/user_list_state` request on that book page.
  - `"a different user on the same browser never sees the first user's state"`: sign in as A, load a page, sign out, sign in as B → the cached entry's `user_id` is B's and A's lists are not rendered.
- [ ] **Step 2: Run** (serially, see Global Constraints) the three new specs plus `e2e/tests/*/auth/sign-in-state.spec.ts` and `e2e/tests/books/rankings-csv-export.spec.ts`. Expected: new specs pass; existing ones pass or fail only for the known dev-data reasons recorded in PR #422 (soft-deleted `novels` category, missing CsvExport blob).
- [ ] **Step 3: Docs.** Describe the cache policy (hourly, budget rule, change marker, 304) where `/user_list_state` is documented; note `/membership_state` is legacy and why it still exists.
- [ ] **Step 4: Run** `bin/rails test` and `bundle exec standardrb`. Expected: PASS.
- [ ] **Step 5: Commit** `E2E: per-user state stays within one request per page; docs`.
