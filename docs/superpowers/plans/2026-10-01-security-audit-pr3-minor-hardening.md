# Security audit PR 3: minor hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the audit's eight minor findings (L3, L6, I1, I4, I5, I6, I7, I13) in one PR that merges to `main` and deploys on its own.

**Architecture:** Each fix is small, local, and independent of the others:
- The auth endpoints accept only JSON.
- Two Stimulus controllers stop building HTML strings.
- User lists: only the owner edits; the owner or a global admin deletes.
- Two admin searches escape LIKE wildcards.
- Search query text drops to debug logging.
- Cover-art downloads get a size cap.
- News-post uploads get the image allowlist.
- A layout that cannot compile is deleted.

Three of the fixes get a lint-style regression test, because the repo has no JS unit runner and the failure they guard against is a pattern in source rather than a behaviour.

**Tech Stack:** Rails 8.1, Pundit, Minitest 6 + Mocha + WebMock, Stimulus, Active Storage, the Down gem, Rollup.

**Spec:** `docs/superpowers/specs/2026-10-01-security-audit-fixes-design.md`, section "PR 3 — minor hardening". Read that section before starting any task.

**Branch / worktree:** `security-audit-pr3-minor-hardening` in
`/home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes`. It was cut from `origin/main` at `9cc34f72`, with PRs 1 and 2 merged and deployed. It has no upstream until its first push.

## Global Constraints

- **Merging to `main` deploys to production** (music and games are live). Nothing in this plan pushes or opens a PR; that is Shane's call (Task 7).
- Rails commands run from `web-app/`. Tests: `bin/rails test <path>`; full suite `bin/rails test`. Lint: `bundle exec standardrb` (not rubocop). Never run brakeman.
- **Minitest 6:** `assert_equal nil, x` is a hard failure. Use `assert_nil`.
- Controller tests assert behaviour (status, params, records, `@controller.view_assigns`), never HTML or copy.
- Check fixture names before using them: `users(:admin_user)`, `users(:editor_user)`, `users(:regular_user)`, `user_lists(:regular_user_music_albums_favorites)` (private), `news_posts(:books_december_update)`, `ranking_configurations(:games_global)`, and `test/fixtures/files/test_image.png`.
- **`web-app/node_modules` is a symlink into the main checkout.** Never run `yarn install` or `npm install` in this worktree. `yarn build` only reads node_modules and writes the gitignored `app/assets/builds/`, so it is allowed.
- Git: use `git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes …`. A session guard refuses `cd <dir> && git …`. Each commit message below ends with the line `<Co-Authored-By trailer>`. Replace it with the exact `Co-Authored-By:` line your harness's attribution instructions give you.
- The repo is public. Commit messages describe the fix, never an attack path.
- **No Cloudflare changes. No movies work.**

## Review Focus

These are spec-implied inputs that the obvious tests would miss, most likely first. Each one is pinned by a test in the task named.

1. **Real callers must keep working under the JSON-only gate.** A `Content-Type` with a charset parameter (`application/json; charset=utf-8`) must still pass, and the bodiless JSON `sign_out` the JS sends must still sign out. → Task 1 tests the charset form, and the existing "rotates the session id on sign out" test covers bodiless JSON.
2. **A cross-site `enctype="text/plain"` form**, the CORS-simple type that is closest to JSON, must be refused, and a refused `sign_out` must leave the session signed in. → Task 1.
3. **`?q[]=x` reaches the admin search as an Array.** `sanitize_sql_like` needs a String, so without a `to_s` guard this becomes a 500. → Task 3 tests both controllers.
4. **News posts saved before the I7 check may already hold another image type.** They must stay editable, so only newly attached files are checked. → Task 5.
5. **A cover image over 10 MB** must leave the album with no image and must not raise out of the job. → Task 4 tests the music job end to end through WebMock.

---

### Task 1: Auth endpoints accept JSON only (L3)

**Files:**
- Modify: `web-app/app/controllers/auth_controller.rb` (add a `before_action` after line 11 and a private method)
- Test: `web-app/test/controllers/auth_controller_test.rb` (append tests)

**Interfaces:**
- Consumes: nothing.
- Produces: `AuthController#require_json_request` (private). Non-JSON requests to `sign_in`, `sign_out` and `check_provider` get `415` with body `{"success": false, "error": "Unsupported Media Type"}`.

Facts already checked:
- Every caller sends `Content-Type: application/json`:
  - `firebase_auth_service.js:171` (sign_in) and `:231` (sign_out)
  - `authentication_controller.js:442` (check_provider) and `:595` (sign_out)
  - `test/test_helper.rb:137` (`sign_in_as(..., stub_auth: true)` uses `as: :json`)
- No E2E spec posts to these paths directly.
- `request.media_type` strips parameters, so `application/json; charset=utf-8` reads as `application/json`.

- [ ] **Step 1: Write the failing tests.** Append inside the test class, before the final `end`:

```ruby
  # L3: these three actions skip the CSRF token (edge-cached pages cannot carry
  # one), so JSON is what keeps a cross-site HTML form out: a form can send
  # urlencoded, multipart or text/plain without a CORS preflight, never JSON.
  test "sign_in refuses a form-encoded body and signs nobody in" do
    post auth_sign_in_path, params: {jwt: FirebaseTokenHelper.token({"sub" => "uid-l3-form", "email" => "l3.form@example.com"})}

    assert_response :unsupported_media_type
    assert_nil session[:user_id]
  end

  test "sign_in refuses a text/plain body" do
    post auth_sign_in_path,
      params: {jwt: FirebaseTokenHelper.token({"sub" => "uid-l3-text", "email" => "l3.text@example.com"})}.to_json,
      headers: {"CONTENT_TYPE" => "text/plain"}

    assert_response :unsupported_media_type
    assert_nil session[:user_id]
  end

  test "sign_in accepts JSON with a charset parameter" do
    post auth_sign_in_path,
      params: {jwt: FirebaseTokenHelper.token({"sub" => "uid-l3-charset", "email" => "l3.charset@example.com"})}.to_json,
      headers: {"CONTENT_TYPE" => "application/json; charset=utf-8"}

    assert_response :success
    assert session[:user_id]
  end

  test "sign_out refuses a form post and leaves the visitor signed in" do
    post auth_sign_in_path, params: {
      jwt: FirebaseTokenHelper.token({"sub" => "uid-l3-out", "email" => "l3.out@example.com"})
    }, as: :json
    signed_in_id = session[:user_id]
    assert signed_in_id

    post auth_sign_out_path

    assert_response :unsupported_media_type
    assert_equal signed_in_id, session[:user_id]
  end

  test "check_provider refuses a form-encoded body" do
    post auth_check_provider_path, params: {email: users(:google_user).email}

    assert_response :unsupported_media_type
  end
```

- [ ] **Step 2: Run them and confirm they fail.**

Run: `cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bin/rails test test/controllers/auth_controller_test.rb`
Expected: the four "refuses" tests FAIL. They get 401, 200 or a success JSON instead of 415, and the sign_out one ends signed out. The charset test passes already.

- [ ] **Step 3: Implement.** In `auth_controller.rb`, directly after line 11 (`skip_before_action :verify_authenticity_token, ...`), add:

```ruby
  # The CSRF token is skipped above because edge-cached pages cannot carry a
  # per-session one. What keeps a cross-site HTML form out instead is the body
  # type: a form can post urlencoded, multipart or text/plain without a CORS
  # preflight, but not application/json, and this app never answers a
  # preflight. Every caller (firebase_auth_service.js, authentication_controller.js)
  # sends JSON.
  before_action :require_json_request, only: [:sign_in, :sign_out, :check_provider]
```

In the `private` section, above `render_rate_limited`, add:

```ruby
  def require_json_request
    return if request.media_type == "application/json"

    render json: {success: false, error: "Unsupported Media Type"}, status: :unsupported_media_type
  end
```

- [ ] **Step 4: Run the file and confirm it passes.**

Run: `bin/rails test test/controllers/auth_controller_test.rb`
Expected: all tests pass, including the existing JSON ones and the rate-limit tests.

- [ ] **Step 5: Mutation check.** Temporarily change `return if request.media_type == "application/json"` to `return`. Rerun the file: the four refusal tests must fail. Restore the line and rerun until green. Record both outputs in your report.

- [ ] **Step 6: Run everything that signs in.** Run `bin/rails test test/controllers test/integration`. Many tests sign in through `sign_in_as`, which posts JSON. Expected: 0 failures.

- [ ] **Step 7: Lint and commit.**

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bundle exec standardrb app/controllers/auth_controller.rb test/controllers/auth_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/app/controllers/auth_controller.rb web-app/test/controllers/auth_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Auth endpoints accept JSON only

sign_in, sign_out and check_provider skip the CSRF token because cached
pages cannot carry one. They now answer 415 to anything but
application/json, which a cross-site form cannot send without a
preflight. Every JS caller already sends JSON.

<Co-Authored-By trailer>"
```

---

### Task 2: Build DOM without HTML strings (L6)

**Files:**
- Modify: `web-app/app/javascript/controllers/authentication_controller.js:178-181` (call site) and `:253-264` (`buildUserInfoHTML`)
- Modify: `web-app/app/javascript/controllers/wizard_step_controller.js:97-108` (`showError`)
- Create: `web-app/test/lint/untrusted_text_dom_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `buildUserInfo(user)`, which replaces `buildUserInfoHTML(user)` and returns an `HTMLElement`. Its only caller is line 180.

Context: the repo has no JS unit test runner (Playwright E2E only). The regression test is therefore a lint test, in the style of `test/lint/`, that fails if either file writes an HTML string again. The model for the rewrite is `app/javascript/controllers/shared/form_token_controller.js:94`. Tailwind scans `app/javascript/**/*.js`, so the class names below stay in the build.

- [ ] **Step 1: Write the failing lint test** at `web-app/test/lint/untrusted_text_dom_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# These controllers put text they do not control into the page: the signed-in
# user's displayName and photoURL (set by the user at their identity provider),
# and an import job's error message. They must build DOM with createElement /
# textContent / setAttribute, never by assigning an HTML string, which would
# parse whatever markup that text contains.
class UntrustedTextDomTest < ActiveSupport::TestCase
  FILES = %w[
    app/javascript/controllers/authentication_controller.js
    app/javascript/controllers/wizard_step_controller.js
  ].freeze

  HTML_STRING_SINK = /\.(?:innerHTML|outerHTML)\s*=(?!=)|insertAdjacentHTML/

  FILES.each do |relative|
    test "#{relative} writes no HTML strings" do
      source = File.read(Rails.root.join(relative))
      offending = source.each_line.with_index(1).select { |line, _| line.match?(HTML_STRING_SINK) }
      assert_empty offending.map { |line, number| "#{relative}:#{number}: #{line.strip}" },
        "build these elements with createElement/textContent/setAttribute instead"
    end
  end
end
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bin/rails test test/lint/untrusted_text_dom_test.rb`
Expected: 2 failures, one naming `authentication_controller.js:180` and one naming `wizard_step_controller.js:100`.

- [ ] **Step 3: Rewrite `authentication_controller.js`.** Change line 180 from `this.userInfoTarget.innerHTML = this.buildUserInfoHTML(user)` to:

```js
      this.userInfoTarget.replaceChildren(this.buildUserInfo(user))
```

Replace the whole `buildUserInfoHTML(user) { ... }` method, including its `// Build user info HTML` comment, with:

```js
  // Built with createElement/textContent rather than an HTML string:
  // displayName and photoURL come from the identity provider, and the user
  // sets both.
  buildUserInfo(user) {
    const container = document.createElement('div')
    container.className = 'flex items-center'

    if (user.photoURL) {
      const photo = document.createElement('img')
      photo.setAttribute('src', user.photoURL)
      photo.setAttribute('alt', 'Profile')
      photo.className = 'w-8 h-8 rounded-full mr-2'
      container.append(photo)
    }

    const name = document.createElement('span')
    name.className = 'text-sm font-medium'
    name.textContent = user.displayName || user.email
    container.append(name)

    return container
  }
```

- [ ] **Step 4: Rewrite `showError` in `wizard_step_controller.js`.** Replace the whole method with:

```js
  // Built with createElement/textContent rather than an HTML string: the
  // message comes from the import job and can contain anything.
  showError(error) {
    const errorDiv = document.createElement('div')
    errorDiv.className = 'alert alert-error mt-4'

    const svgNS = 'http://www.w3.org/2000/svg'
    const icon = document.createElementNS(svgNS, 'svg')
    icon.setAttribute('class', 'stroke-current shrink-0 h-6 w-6')
    icon.setAttribute('fill', 'none')
    icon.setAttribute('viewBox', '0 0 24 24')
    const path = document.createElementNS(svgNS, 'path')
    path.setAttribute('stroke-linecap', 'round')
    path.setAttribute('stroke-linejoin', 'round')
    path.setAttribute('stroke-width', '2')
    path.setAttribute('d', 'M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z')
    icon.append(path)

    const message = document.createElement('span')
    message.textContent = error || 'An error occurred during processing'

    errorDiv.append(icon, message)
    this.element.appendChild(errorDiv)
  }
```

- [ ] **Step 5: Run the lint test and confirm it passes,** then confirm the bundles still build:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bin/rails test test/lint/untrusted_text_dom_test.rb && yarn build 2>&1 | tail -5
grep -rn 'buildUserInfoHTML' app/javascript   # expect: no output
```

Expected: 2 runs, 0 failures; `yarn build` finishes without errors.

- [ ] **Step 6: Run the other lint tests** (Stimulus manifest, bundle coverage, etc.): `bin/rails test test/lint`. Expected: 0 failures.

- [ ] **Step 7: Lint and commit.**

```bash
bundle exec standardrb test/lint/untrusted_text_dom_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/app/javascript/controllers/authentication_controller.js web-app/app/javascript/controllers/wizard_step_controller.js web-app/test/lint/untrusted_text_dom_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Build the profile chip and wizard error with DOM APIs, not HTML strings

The signed-in user's name and photo URL, and an import job's error
message, are now set with textContent/setAttribute. A lint test keeps
both controllers off innerHTML.

<Co-Authored-By trailer>"
```

---

### Task 3: User-list edit/delete rules (I1) and escaped admin searches (I4)

**Files:**
- Modify: `web-app/app/policies/user_list_policy.rb`
- Test: `web-app/test/policies/user_list_policy_test.rb`
- Modify: `web-app/app/controllers/admin/users_controller.rb:7`
- Modify: `web-app/app/controllers/admin/ranking_configurations_controller.rb:111-113`
- Test: `web-app/test/controllers/admin/users_controller_test.rb`, `web-app/test/controllers/admin/games/ranking_configurations_controller_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `UserListPolicy#update?` (owner only; `edit?` follows it through `ApplicationPolicy`) and `#destroy?` (owner or global admin).

Facts already checked:
- `UserListPolicy` today inherits `update?` and `destroy?` from `ApplicationPolicy`, which returns true for any global admin or editor. No controller calls them yet, so the hole is latent.
- `Admin::RankingConfigurationsController` is the base for the books, games, music, music albums, music artists and music songs controllers. One test through the games subclass covers the shared method.
- The house pattern for searches is `params[:q].to_s.presence` and then `sanitize_sql_like` (see `admin/corrections_controller.rb:170-177`). The `to_s` matters because `?q[]=x` arrives as an Array.

- [ ] **Step 1: Write the failing tests.**

Append to `test/policies/user_list_policy_test.rb` (inside the class):

```ruby
  test "update? and destroy? allow the owner" do
    assert UserListPolicy.new(@user, @list).update?
    assert UserListPolicy.new(@user, @list).destroy?
  end

  test "update? and edit? refuse a global admin or editor who does not own the list" do
    [users(:admin_user), users(:editor_user)].each do |staff|
      refute UserListPolicy.new(staff, @list).update?, "#{staff.email} must not update another user's list"
      refute UserListPolicy.new(staff, @list).edit?, "#{staff.email} must not edit another user's list"
    end
  end

  # Decided 2026-10-01 (Shane): an admin can delete anything, a user list included.
  test "destroy? allows a global admin on a list they do not own" do
    assert UserListPolicy.new(users(:admin_user), @list).destroy?
  end

  test "destroy? refuses a global editor who does not own the list" do
    refute UserListPolicy.new(users(:editor_user), @list).destroy?
  end

  test "update? and destroy? refuse an anonymous visitor" do
    refute UserListPolicy.new(nil, @list).update?
    refute UserListPolicy.new(nil, @list).destroy?
  end
```

Append to `test/controllers/admin/users_controller_test.rb` (inside the class):

```ruby
  test "a percent sign in the search is a literal, not a wildcard" do
    get admin_users_url(q: "%")
    assert_response :success
    assert_equal [], @controller.view_assigns["users"].map(&:id)
  end

  test "an array search parameter does not error" do
    get admin_users_url(q: ["admin"])
    assert_response :success
  end
```

Append to `test/controllers/admin/games/ranking_configurations_controller_test.rb`, inside the class next to the other search tests:

```ruby
      test "a percent sign in the search is a literal, not a wildcard" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(q: "%")
        assert_response :success
        assert_equal [], @controller.view_assigns["ranking_configurations"].map(&:id)
      end

      test "an array search parameter does not error" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_games_ranking_configurations_path(q: ["Global"])
        assert_response :success
      end
```

Before relying on `[]`, check that no fixture user email and no games ranking configuration name contains a literal `%`: `grep -n '%' test/fixtures/users.yml test/fixtures/ranking_configurations.yml`. ERB tags such as `<%=` are not matches. If a real `%` exists, assert that the result excludes a known `%`-free record instead, and say so in your report.

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `bin/rails test test/policies/user_list_policy_test.rb test/controllers/admin/users_controller_test.rb test/controllers/admin/games/ranking_configurations_controller_test.rb`

Expected:
- The "update? and edit? refuse" test and the "destroy? refuses a global editor" test fail, because `ApplicationPolicy` lets staff through. The admin-can-destroy test already passes, and it pins Shane's rule that an admin can delete anything.
- Both `%` tests fail, because every row matches.
- The array tests may pass today, since `"%#{["admin"]}%"` interpolates without raising. That is fine: they pin the `to_s` guard that Step 3 needs.

- [ ] **Step 3: Implement.**

`app/policies/user_list_policy.rb`: replace the stale comment line `# update?/destroy? are added in Phase B (user-lists-02f).` with `# update? is owner-only; destroy? is the owner or a global admin (admins can delete anything). Editors get neither.`. Then add, after `show?`:

```ruby
  def update?
    owner?
  end

  def destroy?
    owner? || global_admin?
  end
```

`global_admin?` comes from `ApplicationPolicy` (`user&.admin?`). Do not use `global_role?`, which also passes editors.

`owner?` already returns false for a nil user, because `record.user_id == nil&.id` compares against nil and the list's `user_id` is never nil.

`app/controllers/admin/users_controller.rb`, line 7 becomes:

```ruby
    # to_s first: ?q[]=x arrives as an Array, and sanitize_sql_like needs a String.
    search = params[:q].to_s.presence
    @users = @users.where("email ILIKE ?", "%#{::User.sanitize_sql_like(search)}%") if search
```

`app/controllers/admin/ranking_configurations_controller.rb`, `load_ranking_configurations_for_index` becomes:

```ruby
  def load_ranking_configurations_for_index
    # to_s first: ?q[]=x arrives as an Array, and sanitize_sql_like needs a String.
    search = params[:q].to_s.presence
    if search
      @ranking_configurations = ranking_configuration_class
        .where("name ILIKE ?", "%#{::RankingConfiguration.sanitize_sql_like(search)}%")
    else
      sort_column = sortable_column(params[:sort])

      @ranking_configurations = ranking_configuration_class.all
        .order(sort_column)
    end

    @pagy, @ranking_configurations = pagy(@ranking_configurations, limit: 25)
  end
```

- [ ] **Step 4: Run the tests and confirm they pass,** including every ranking-configuration controller test:

```bash
bin/rails test test/policies/user_list_policy_test.rb test/controllers/admin/users_controller_test.rb test/controllers/admin/games/ranking_configurations_controller_test.rb
bin/rails test test/controllers/admin   # every admin subclass shares the changed method
```

Expected: 0 failures.

- [ ] **Step 5: Mutation check.** Revert just the `sanitize_sql_like(...)` wrapper in `users_controller.rb` (keep `search`), and confirm the users `%` test fails. Restore it. Then delete `update?` from the policy and confirm the staff test fails. Restore it. Record both runs in your report.

- [ ] **Step 6: Lint and commit.**

```bash
bundle exec standardrb app/policies/user_list_policy.rb app/controllers/admin/users_controller.rb app/controllers/admin/ranking_configurations_controller.rb test/policies/user_list_policy_test.rb test/controllers/admin/users_controller_test.rb test/controllers/admin/games/ranking_configurations_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/app/policies/user_list_policy.rb web-app/app/controllers/admin/users_controller.rb web-app/app/controllers/admin/ranking_configurations_controller.rb web-app/test/policies/user_list_policy_test.rb web-app/test/controllers/admin/users_controller_test.rb web-app/test/controllers/admin/games/ranking_configurations_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "User lists: owner edits, owner or admin deletes; escape LIKE wildcards

UserListPolicy#update? is owner-only and #destroy? is the owner or a global
admin; global editors no longer inherit the staff bypass on personal lists.
The admin users and ranking-configuration searches treat % and _ as
literals and accept an array q without erroring.

<Co-Authored-By trailer>"
```

---

### Task 4: Search query text at debug (I5); capped cover downloads (I6)

**Files:**
- Modify (11 lines, one per file): every `Rails.logger.info "... search query: #{query_definition.inspect}"` under `web-app/app/lib/search/`:
  - `games/search/game_by_title_and_developers.rb:21`, `games/search/game_general.rb:20`
  - `books/search/book_by_title_and_authors.rb:29`, `books/search/book_general.rb:21`, `books/search/author_general.rb:20`, `books/search/author_by_name.rb:31`
  - `music/search/song_general.rb:20`, `music/search/song_by_title_and_artists.rb:21`, `music/search/artist_general.rb:20`, `music/search/album_general.rb:20`, `music/search/album_by_title_and_artists.rb:21`
- Create: `web-app/test/lint/search_query_logging_test.rb`
- Modify: `web-app/app/sidekiq/music/cover_art_download_job.rb:33`, `web-app/app/sidekiq/games/cover_art_download_job.rb:50`
- Test: `web-app/test/sidekiq/music/cover_art_download_job_test.rb`, `web-app/test/sidekiq/games/cover_art_download_job_test.rb`

**Interfaces:** none.

Facts already checked:
- Production logs at `info` (`config/environments/production.rb:57`), so `debug` lines are dropped there.
- The repo's idiom for debug logging is the block form: `Rails.logger.debug { "..." }` (see `app/lib/viaf/cluster.rb:52`). The block also skips the `inspect` cost at info level.
- `amazon/base_product_service.rb:211` already calls `Down.download(image_url, max_size: 10 * 1024 * 1024)`.
- The music job test stubs HTTP with WebMock. The games job test stubs `Down.download` with Mocha.

- [ ] **Step 1: Write the failing tests.**

`web-app/test/lint/search_query_logging_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# query_definition carries the visitor's search text. Production logs at info,
# so logging it at info or above writes every search into the server logs.
# Debug is fine: it is off in production.
class SearchQueryLoggingTest < ActiveSupport::TestCase
  SEARCH_FILES = Dir[Rails.root.join("app/lib/search/**/*.rb")]

  test "no search class logs a query definition above debug" do
    offending = SEARCH_FILES.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.include?("query_definition") && line.match?(/logger\.(?:info|warn|error|fatal|unknown)\b/)
        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offending
  end

  # Guards the test above against passing vacuously (an empty glob, or the
  # lines removed rather than lowered).
  test "the search classes still log their query definitions at debug" do
    debug_lines = SEARCH_FILES.sum do |path|
      File.readlines(path).count { |line| line.include?("query_definition") && line.include?("logger.debug") }
    end

    assert_operator debug_lines, :>=, 11
  end
end
```

Append to `test/sidekiq/games/cover_art_download_job_test.rb`, inside the class. Its `setup` already gives `@game` (`games_games(:breath_of_the_wild)`) the IGDB id `7346`:

```ruby
  test "perform caps the download at 10 MB" do
    cover_search = mock
    cover_search.expects(:find_by_game_id).with(7346).returns(success: true, data: [{"image_id" => "abc123"}])
    cover_search.expects(:image_url).with("abc123", size: ::Games::Igdb::Search::CoverSearch::SIZE_1080P)
      .returns("https://images.igdb.com/igdb/image/upload/t_1080p/abc123.jpg")
    ::Games::Igdb::Search::CoverSearch.stubs(:new).returns(cover_search)

    tempfile = Tempfile.new(["cover", ".jpg"])
    tempfile.write("fake image data")
    tempfile.rewind
    Down.expects(:download)
      .with("https://images.igdb.com/igdb/image/upload/t_1080p/abc123.jpg", max_size: 10 * 1024 * 1024)
      .returns(tempfile)

    Games::CoverArtDownloadJob.new.perform(@game.id)
  ensure
    tempfile&.close
    tempfile&.unlink
  end
```

Append to `test/sidekiq/music/cover_art_download_job_test.rb`, inside the class. Its `setup` gives `@album` (`music_albums(:dark_side_of_the_moon)`, which has a MusicBrainz release-group identifier) and `@job`:

```ruby
    test "perform skips a cover larger than 10 MB without raising" do
      @album.images.where(primary: true).destroy_all
      musicbrainz_id = @album.identifiers.find_by!(identifier_type: :music_musicbrainz_release_group_id).value

      stub_request(:get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front")
        .to_return(status: 200, body: "x" * (10 * 1024 * 1024 + 1), headers: {"Content-Type" => "image/jpeg"})

      assert_no_difference -> { Image.count } do
        @job.perform(@album.id)
      end
      assert_requested :get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front"
    end
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `bin/rails test test/lint/search_query_logging_test.rb test/sidekiq/music/cover_art_download_job_test.rb test/sidekiq/games/cover_art_download_job_test.rb`

Expected:
- The lint "no search class..." test fails, listing 11 lines.
- The "still log at debug" test fails with a count of 0.
- The games test fails with an unexpected invocation (no `max_size`).
- The music test fails because an Image is created from the 10 MB + 1 body.

- [ ] **Step 3: Implement.**

In each of the 11 files, change `Rails.logger.info "<Label> search query: #{query_definition.inspect}"` to `Rails.logger.debug { "<Label> search query: #{query_definition.inspect}" }`. Keep each label exactly as it is.

In both jobs, change the download call to pass the cap:

```ruby
      tempfile = Down.download(cover_art_url, max_size: 10 * 1024 * 1024)   # music
      tempfile = Down.download(cover_url, max_size: 10 * 1024 * 1024)       # games
```

Down raises `Down::TooLarge` past the cap. Each job's existing `rescue => e` logs it and moves on, and its `ensure` handles a nil `tempfile` safely.

- [ ] **Step 4: Run the tests and confirm they pass,** together with the search and job suites:

```bash
bin/rails test test/lint/search_query_logging_test.rb test/sidekiq/music/cover_art_download_job_test.rb test/sidekiq/games/cover_art_download_job_test.rb test/lib/search
```

Expected: 0 failures.

- [ ] **Step 5: Lint and commit.**

```bash
bundle exec standardrb app/lib/search app/sidekiq/music/cover_art_download_job.rb app/sidekiq/games/cover_art_download_job.rb test/lint/search_query_logging_test.rb test/sidekiq/music/cover_art_download_job_test.rb test/sidekiq/games/cover_art_download_job_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/app/lib/search web-app/app/sidekiq/music/cover_art_download_job.rb web-app/app/sidekiq/games/cover_art_download_job.rb web-app/test/lint/search_query_logging_test.rb web-app/test/sidekiq/music/cover_art_download_job_test.rb web-app/test/sidekiq/games/cover_art_download_job_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Log search queries at debug; cap cover-art downloads at 10 MB

Visitors' search text no longer reaches the production logs. The music
and games cover-art jobs pass max_size to Down, as the Amazon image
download already does.

<Co-Authored-By trailer>"
```

---

### Task 5: News-post uploads use the image allowlist (I7)

**Files:**
- Modify: `web-app/app/models/image.rb` (extract the allowlist constant)
- Modify: `web-app/app/models/news_post.rb` (new validation)
- Test: `web-app/test/models/news_post_test.rb`, `web-app/test/controllers/admin/books/news_posts_controller_test.rb`

**Interfaces:**
- Produces: `Image::ALLOWED_CONTENT_TYPES` (frozen Array of Strings: `image/jpeg image/png image/webp image/gif`).

Facts already checked:
- **Active Storage sniffs the content type from the bytes and the filename** (Marcel) when a blob is built from an upload or an `io:` hash. A real SVG body is therefore `image/svg+xml` whatever the client declares, and tests must use real SVG bytes.
- **The update action attaches body images on valid records only.** `Admin::NewsPostsBaseController#update` calls `attach_body_images` only after `valid?`. Its comment at lines 73–86 anticipates exactly this validation: when `attach` saves eagerly and the save fails, the change stays pending, and the following `save` fails too and renders the edit form with a 422.
- **The dev database (a production restore) holds no news-post attachments.** The check still covers new attachments only, so a post saved before it, holding another type, stays editable.

- [ ] **Step 1: Write the failing tests.**

Append to `test/models/news_post_test.rb`, inside the class:

```ruby
  SVG_BYTES = %(<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>)

  test "refuses a share image outside the image allowlist" do
    post = NewsPost.new(domain: :books, title: "Svg share", body: "x", user: users(:admin_user))
    post.share_image.attach(io: StringIO.new(SVG_BYTES), filename: "share.svg", content_type: "image/svg+xml")

    assert_not post.valid?
    assert_includes post.errors[:share_image], "must be a JPEG, PNG, WebP, or GIF"
  end

  test "refuses a body image outside the image allowlist" do
    post = NewsPost.new(domain: :books, title: "Svg body", body: "x", user: users(:admin_user))
    post.body_images.attach(io: StringIO.new(SVG_BYTES), filename: "inline.svg", content_type: "image/svg+xml")

    assert_not post.valid?
    assert_includes post.errors[:body_images], "must be a JPEG, PNG, WebP, or GIF"
  end

  test "accepts allowlisted images" do
    post = NewsPost.new(domain: :books, title: "Png images", body: "x", user: users(:admin_user))
    post.share_image.attach(io: File.open(file_fixture("test_image.png")), filename: "share.png")
    post.body_images.attach(io: File.open(file_fixture("test_image.png")), filename: "inline.png")

    assert post.valid?, post.errors.full_messages.to_sentence
  end

  # The check covers new uploads only: a post saved before it existed may hold
  # another type, and must stay editable.
  test "an already-stored attachment of another type does not block saving the post" do
    post = news_posts(:books_december_update)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(SVG_BYTES), filename: "old.svg", content_type: "image/svg+xml")
    ActiveStorage::Attachment.create!(name: "body_images", record: post, blob: blob)

    post.reload.title = "Retitled"
    assert post.save, post.errors.full_messages.to_sentence
  end
```

Append to `test/controllers/admin/books/news_posts_controller_test.rb`, inside the class next to the other attachment tests:

```ruby
      test "update refuses a body image outside the image allowlist and attaches nothing" do
        post_record = news_posts(:books_december_update)
        svg = Rack::Test::UploadedFile.new(
          StringIO.new(%(<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>)),
          "image/svg+xml", original_filename: "inline.svg"
        )

        patch admin_books_news_post_path(post_record), params: {
          news_post: {title: post_record.title, body: post_record.body, body_images: [svg]}
        }

        assert_response :unprocessable_entity
        assert_equal 0, post_record.reload.body_images.count
      end
```

If `Rack::Test::UploadedFile.new(StringIO, ...)` is not accepted by the Rack::Test version installed, write the SVG bytes to a `Tempfile` with an `.svg` extension and pass its path instead. Note what you did in your report.

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `bin/rails test test/models/news_post_test.rb test/controllers/admin/books/news_posts_controller_test.rb`

Expected:
- The two "refuses" model tests and the controller test fail: the SVG is accepted.
- "accepts allowlisted images" and "already-stored attachment" pass.

- [ ] **Step 3: Implement.**

`app/models/image.rb`: add the constant just below `class Image < ApplicationRecord`, above `belongs_to :parent`:

```ruby
  # Raster formats only. NewsPost uploads share this list. SVG is not on it,
  # because a stored SVG is a document that can carry script.
  ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze
```

In `acceptable_image_format`, replace `allowed_types = %w[image/jpeg image/png image/webp image/gif]` and the `.in?(allowed_types)` that uses it with `.in?(ALLOWED_CONTENT_TYPES)`. Leave the HEIC branch and both messages as they are.

`app/models/news_post.rb`: add `validate :uploaded_images_are_allowed_types` after `validates :domain, presence: true`. Then add this method at the end of the class, before the final `end`:

```ruby
  private

  # New uploads only. A post saved before this check existed may already hold
  # another type, and it must stay editable.
  def uploaded_images_are_allowed_types
    attachments = []
    attachments << share_image.attachment if share_image.attached?
    attachments.concat(body_images.attachments.to_a) if body_images.attached?

    attachments.select(&:new_record?).each do |attachment|
      next if attachment.blob.content_type.in?(Image::ALLOWED_CONTENT_TYPES)

      errors.add(attachment.name.to_sym, "must be a JPEG, PNG, WebP, or GIF")
    end
  end
```

`should_generate_new_friendly_id?`, `to_param` and the other one-liners above it are public and must stay public, so put `private` immediately before this new method and after every existing method. Check this when you read the file.

- [ ] **Step 4: Run the tests and confirm they pass,** along with everything that touches images or news posts:

```bash
bin/rails test test/models/news_post_test.rb test/models/image_test.rb test/controllers/admin/books/news_posts_controller_test.rb test/controllers/news_posts_controller_test.rb
```

Expected: 0 failures.

- [ ] **Step 5: Mutation check.** Temporarily make the validation check every attachment instead of only new ones: remove `.select(&:new_record?)`. The "already-stored attachment" test must fail. Restore. Record both runs.

- [ ] **Step 6: Lint and commit.**

```bash
bundle exec standardrb app/models/image.rb app/models/news_post.rb test/models/news_post_test.rb test/controllers/admin/books/news_posts_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/app/models/image.rb web-app/app/models/news_post.rb web-app/test/models/news_post_test.rb web-app/test/controllers/admin/books/news_posts_controller_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "News-post uploads accept the same image types as Image

Share and body images must be JPEG, PNG, WebP or GIF, checked against
Image::ALLOWED_CONTENT_TYPES. Only new uploads are checked, so existing
posts stay editable.

<Co-Authored-By trailer>"
```

---

### Task 6: Delete the layout that cannot compile (I13)

**Files:**
- Delete: `web-app/app/views/layouts/application.html.erb`
- Create: `web-app/test/lint/erb_templates_compile_test.rb`

**Interfaces:** none.

Facts already checked (2026-10-01):
- **The layout cannot compile.** `ApplicationController.render(html: "x", layout: "application")` raises `ActionView::SyntaxErrorInTemplate`, because the text after each `<% when %>` is emitted between `case` and `when`.
- **Nothing renders it successfully.** Every page that tried would 500. Controllers that would fall back to it (`AuthController`, `UserListsController`, `ReviewsController` and others) render JSON, turbo streams, redirects or explicitly laid-out templates, and the full suite passes. With the file gone, Rails renders those controllers' HTML without a layout rather than raising.
- **`ViewComponentsController` declares `layout "application"`,** but the repo has no component previews (`test/components/previews` does not exist).
- **It is the only broken template.** A compile check of all 469 ERB templates under `app/views` and `app/components` found exactly this one.

- [ ] **Step 1: Write the lint test** at `web-app/test/lint/erb_templates_compile_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Every ERB template must at least compile. A template that cannot compile
# only fails when something renders it, so a rarely used one can sit broken
# indefinitely. layouts/application.html.erb did, until 2026-10. This compiles
# each template's generated Ruby without rendering it.
class ErbTemplatesCompileTest < ActiveSupport::TestCase
  TEMPLATES = Dir[Rails.root.join("app/{views,components}/**/*.erb")]

  test "every ERB template under app/views and app/components compiles" do
    # Guards against an empty glob passing vacuously.
    assert_operator TEMPLATES.size, :>, 100

    handler = ActionView::Template::Handlers::ERB.new
    failures = TEMPLATES.filter_map do |path|
      source = File.read(path)
      virtual_path = path.delete_prefix("#{Rails.root}/app/views/")
      template = ActionView::Template.new(source, path, handler, locals: [], format: :html, virtual_path: virtual_path)
      RubyVM::InstructionSequence.compile("def __erb_compile_check(local_assigns, output_buffer)\n#{handler.call(template, source)}\nend")
      nil
    rescue SyntaxError => e
      "#{Pathname(path).relative_path_from(Rails.root)}: #{e.message.lines.first.strip}"
    end

    assert_empty failures
  end
end
```

- [ ] **Step 2: Run it and confirm it fails.**

Run: `bin/rails test test/lint/erb_templates_compile_test.rb`
Expected: 1 failure, listing `app/views/layouts/application.html.erb` and nothing else.

- [ ] **Step 3: Delete the layout.**

```bash
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes rm -q web-app/app/views/layouts/application.html.erb
grep -rn 'layout "application"\|layout: "application"' /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app/app   # expect: no output
```

- [ ] **Step 4: Run the lint test and the whole suite.** Removing a layout affects every controller that falls back to it, so run the full suite:

```bash
bin/rails test test/lint/erb_templates_compile_test.rb
bin/rails test
```

Expected: the lint test passes, and the full suite has 0 failures and 0 errors.

- [ ] **Step 5: Mutation check.** Restore the deleted file with `git -C … checkout HEAD -- web-app/app/views/layouts/application.html.erb`. The lint test must fail and name it. Then `git rm` it again. Record both runs.

- [ ] **Step 6: Lint and commit.**

```bash
bundle exec standardrb test/lint/erb_templates_compile_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes add web-app/test/lint/erb_templates_compile_test.rb
git -C /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes commit -m "Delete the application layout that could not compile

layouts/application.html.erb had text between case and when, so any
render of it raised. Nothing rendered it successfully. A lint test now
compiles every ERB template under app/views and app/components.

<Co-Authored-By trailer>"
```

---

### Task 7: Whole-branch verification and hand-off (controller, plus Shane)

The controller runs Steps 1–2. Steps 3–4 need Shane.

- [ ] **Step 1:** Run the full suite and lint on the branch head:

```bash
cd /home/shane/dev/the-greatest/.claude/worktrees/security-audit-fixes/web-app && bin/rails test 2>&1 | tail -3 && bundle exec standardrb
```

- [ ] **Step 2:** `git -C … diff --stat origin/main...HEAD` must show only the files named in Tasks 1–6 plus this plan.
- [ ] **Step 3 (needs Shane's OK):** push and open the PR.
- [ ] **Step 4 (Shane, after deploy):** in a browser, sign in on music or games and check:
  - The account chip shows your name and photo.
  - Sign-out works.
  - The email/password "use Google instead" hint still appears for a Google-account address. That is `check_provider`.

  `curl` is challenged by Cloudflare, so this cannot be checked from the terminal.
