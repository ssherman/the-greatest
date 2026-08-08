# Turbo-Frame-Trapped Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `/my/lists/:id` rendering "Content missing" when a user clicks an item, and add a reusable test assertion that catches this class of bug anywhere it recurs.

**Architecture:** Turbo scopes every `<a>` inside a `<turbo-frame>` to that frame, so a link to a page without a matching frame is discarded. The `list_items` frame on the user-list show page gets `target="_top"`, flipping the default so links escape unless they opt back in; pagination opts back in via pagy's `anchor_string`. A pure HTML-analysis module (`TurboFrameLinks`) plus a thin integration assertion (`assert_no_frame_trapped_links`) pin the invariant, and a Playwright test proves the real click path in a real browser.

**Tech Stack:** Rails 8, Turbo (`@hotwired/turbo-rails` 8.0.x), pagy 43, Minitest + fixtures + Mocha, Nokogiri 1.19 (HTML5 parser), Playwright.

**Spec:** `docs/superpowers/specs/2026-08-08-turbo-frame-trapped-links-design.md`

## Global Constraints

- Run **all** Rails/yarn commands from `web-app/`. Docs live in `docs/` at the project root.
- Work happens in the git worktree `.claude/worktrees/turbo-frame-trapped-links` on branch `worktree-turbo-frame-trapped-links`. `web-app/.env` and `web-app/config/master.key` are already symlinked in.
- Lint with `bundle exec standardrb`, **never** `bin/rubocop`. Do **not** run brakeman.
- **Never** run a destructive command against the development database. The test database is shared with the main checkout; `bin/rails test` sets `RAILS_ENV=test` itself.
- No code comments unless they explain something non-obvious. The comments in this plan's code blocks are load-bearing — keep them.
- Do not use `bin/dev` — foreman self-terminates without a TTY. Use `yarn build:all` + `bin/rails server`.
- Domain hosts come from `Rails.application.config.domains[:music | :books | :games]` — never hardcode hostnames in Ruby tests.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `web-app/test/support/turbo_frame_links.rb` (create) | Pure HTML analysis: given a page body, return the links whose Turbo navigation is scoped to a frame. No HTTP, no Rails — unit-testable in isolation. |
| `web-app/test/support/turbo_frame_links_test.rb` (create) | Unit tests for the above, driven by hand-written HTML. |
| `web-app/test/test_helper.rb` (modify) | Requires the support module; adds `assert_no_frame_trapped_links` to `ActionDispatch::IntegrationTest` — the thin HTTP layer that follows what the module returns. |
| `web-app/app/views/my_lists/show.html.erb` (modify) | The fix: `target: "_top"` on the frame, `anchor_string` on both pagy navs. |
| `web-app/test/controllers/my_lists_controller_test.rb` (modify) | Applies the guard to all four listable types × three view modes. |
| `web-app/test/controllers/music/albums/lists_controller_test.rb` (modify) | Pins the album public list page, which is correct today. |
| `web-app/test/controllers/music/songs/lists_controller_test.rb` (modify) | Pins the song public list page, which is correct today. |
| `web-app/e2e/tests/books/account/my-lists.spec.ts` (modify) | Browser proof: clicking a book title from a user list lands on the book page. |
| `CLAUDE.md` (modify) | Records the convention so the next frame doesn't repeat this. |

The analysis logic and the HTTP assertion are split deliberately. Once the bug is fixed the assertion finds zero links to follow on every page in the suite, so without unit tests against known-bad HTML a broken analyser would pass everywhere silently.

---

### Task 1: The `TurboFrameLinks` analyser

**Files:**
- Create: `web-app/test/support/turbo_frame_links.rb`
- Create: `web-app/test/support/turbo_frame_links_test.rb`
- Modify: `web-app/test/test_helper.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `TurboFrameLinks.trapped_candidates(html, host: nil) -> Array<TurboFrameLinks::Candidate>`, where `Candidate = Data.define(:href, :frame_id)` — `href` is the anchor's raw `href` string, `frame_id` is the id of the Turbo frame the click would navigate. Task 2 consumes this.

Background: Turbo decides which frame a click navigates by reading, in order, the anchor's `data-turbo-frame`, then the enclosing frame's `target`, then the enclosing frame's own `id`. `_top` means "navigate the whole page". This module reproduces that resolution and returns only the anchors that would stay inside a frame.

- [ ] **Step 1: Capture the test-suite baseline**

Run: `bin/rails test 2>&1 | tail -5`

Record the `N runs, N assertions` line somewhere you can refer back to. Every later "full suite" step compares against it. A *drop* in the runs count means a file stopped loading, which Minitest reports very quietly.

- [ ] **Step 2: Write the failing unit test**

Create `web-app/test/support/turbo_frame_links_test.rb`:

```ruby
require "test_helper"

class TurboFrameLinksTest < ActiveSupport::TestCase
  def candidates(html, **options)
    TurboFrameLinks.trapped_candidates(html, **options)
  end

  def pairs(result)
    result.map { |candidate| [candidate.href, candidate.frame_id] }
  end

  test "a link inside a frame is scoped to that frame" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items"><a href="/book/war-and-peace">W&amp;P</a></turbo-frame>
    HTML

    assert_equal [["/book/war-and-peace", "list_items"]], pairs(result)
  end

  test "a link outside every frame is unscoped" do
    assert_empty candidates(%(<a href="/book/war-and-peace">W&amp;P</a>))
  end

  test "a link that targets _top escapes its frame" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/book/war-and-peace" data-turbo-frame="_top">W&amp;P</a>
      </turbo-frame>
    HTML
  end

  test "a frame that targets _top releases every link inside it" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items" target="_top">
        <a href="/book/war-and-peace">W&amp;P</a>
      </turbo-frame>
    HTML
  end

  test "an explicit data-turbo-frame overrides the frame's own target" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items" target="_top">
        <a href="/my/lists/1/page/2" data-turbo-frame="list_items">2</a>
      </turbo-frame>
    HTML

    assert_equal [["/my/lists/1/page/2", "list_items"]], pairs(result)
  end

  test "the nearest enclosing frame wins when frames are nested" do
    result = candidates(<<~HTML)
      <turbo-frame id="outer">
        <turbo-frame id="inner"><a href="/nested">n</a></turbo-frame>
      </turbo-frame>
    HTML

    assert_equal ["inner"], result.map(&:frame_id)
  end

  test "a link inside a table inside a frame is still attributed to the frame" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items">
        <table><tbody><tr><td><a href="/song/time">Time</a></td></tr></tbody></table>
      </turbo-frame>
    HTML

    assert_equal ["list_items"], result.map(&:frame_id)
  end

  test "data-turbo=false opts a link out of Turbo entirely" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/my/lists/1.csv" data-turbo="false">Download</a>
      </turbo-frame>
    HTML
  end

  test "fragment, mailto and tel links are not followable" do
    assert_empty candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="#top">top</a>
        <a href="mailto:someone@example.com">mail</a>
        <a href="tel:+15551234567">call</a>
      </turbo-frame>
    HTML
  end

  test "an absolute link to another host is not followable" do
    assert_empty candidates(<<~HTML, host: "dev.thegreatestmusic.org")
      <turbo-frame id="list_items"><a href="https://example.com/x">x</a></turbo-frame>
    HTML
  end

  test "an absolute link to the current host is followable" do
    result = candidates(<<~HTML, host: "dev.thegreatestmusic.org")
      <turbo-frame id="list_items">
        <a href="https://dev.thegreatestmusic.org/album/animals">Animals</a>
      </turbo-frame>
    HTML

    assert_equal ["list_items"], result.map(&:frame_id)
  end

  test "repeated href and frame pairs collapse to a single candidate" do
    result = candidates(<<~HTML)
      <turbo-frame id="list_items">
        <a href="/album/animals"><span>cover</span></a>
        <a href="/album/animals">Animals</a>
      </turbo-frame>
    HTML

    assert_equal 1, result.size
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/support/turbo_frame_links_test.rb`
Expected: every test errors with `NameError: uninitialized constant TurboFrameLinks`.

- [ ] **Step 4: Write the analyser**

Create `web-app/test/support/turbo_frame_links.rb`:

```ruby
# frozen_string_literal: true

# Finds the links on a rendered page whose Turbo navigation is scoped to a
# <turbo-frame>. Turbo navigates the frame a link sits in, not the page, so a
# link pointing at a document without that frame renders "Content missing"
# instead of navigating.
#
# Deliberately pure and HTTP-free: assert_no_frame_trapped_links (test_helper)
# supplies the requests. Once a page is fixed this returns nothing for it, so
# the unit tests here are the only thing proving the resolution logic works.
module TurboFrameLinks
  Candidate = Data.define(:href, :frame_id)

  UNFOLLOWABLE_SCHEMES = %w[mailto tel javascript].freeze

  # Turbo resolves a click's target frame in this order:
  #   the anchor's data-turbo-frame, the frame's target, the frame's own id.
  # "_top" means the whole page, so those anchors are safe and omitted.
  def self.trapped_candidates(html, host: nil)
    anchors = Nokogiri::HTML5(html).css("a[href]")

    candidates = anchors.filter_map do |anchor|
      frame = anchor.ancestors("turbo-frame").first
      next if frame.nil?
      next if anchor["data-turbo"] == "false"

      target = anchor["data-turbo-frame"] || frame["target"] || frame["id"]
      next if target == "_top"

      href = anchor["href"].to_s.strip
      next unless followable?(href, host)

      Candidate.new(href: href, frame_id: target)
    end

    candidates.uniq
  end

  # Only same-document GET navigations can be replayed by the assertion.
  def self.followable?(href, host)
    return false if href.empty? || href.start_with?("#")
    return false if UNFOLLOWABLE_SCHEMES.any? { |scheme| href.downcase.start_with?("#{scheme}:") }
    return true unless href.match?(%r{\A(https?:)?//})
    return false if host.nil?

    URI.parse(href).host == host
  rescue URI::InvalidURIError
    false
  end
  private_class_method :followable?
end
```

- [ ] **Step 5: Require the module from `test_helper.rb`**

In `web-app/test/test_helper.rb`, add the require immediately after the existing `require "webmock/minitest"` (line 6):

```ruby
require_relative "support/turbo_frame_links"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/support/turbo_frame_links_test.rb`
Expected: PASS, 12 runs, 0 failures, 0 errors.

- [ ] **Step 7: Lint**

Run: `bundle exec standardrb test/support/ test/test_helper.rb`
Expected: no offenses. If there are any, run `bundle exec standardrb --fix` on those paths and re-run Step 6.

- [ ] **Step 8: Commit**

```bash
git add web-app/test/support web-app/test/test_helper.rb
git commit -m "Add TurboFrameLinks analyser for frame-scoped links"
```

---

### Task 2: The integration assertion, the red proof, and the fix

**Files:**
- Modify: `web-app/test/test_helper.rb`
- Modify: `web-app/test/controllers/my_lists_controller_test.rb`
- Modify: `web-app/app/views/my_lists/show.html.erb:70`, `:81`, `:114`

**Interfaces:**
- Consumes: `TurboFrameLinks.trapped_candidates(html, host:)` and `TurboFrameLinks::Candidate#href` / `#frame_id` from Task 1.
- Produces: `assert_no_frame_trapped_links(path)` on `ActionDispatch::IntegrationTest`. It issues its own requests and therefore overwrites `response` — callers must not assert on `response` afterwards, so it always gets its own test case. Task 3 consumes it.

This is the core red/green cycle: the guard is written first and must genuinely fail against the current markup before the fix goes in.

- [ ] **Step 1: Add the assertion to `test_helper.rb`**

In `web-app/test/test_helper.rb`, inside the existing `module ActionDispatch / class IntegrationTest` block, add this method after `sign_in_as`:

```ruby
    # Fails when a link on `path` would navigate a Turbo Frame that its
    # destination doesn't contain — Turbo drops the response and writes
    # "Content missing" into the frame instead of navigating.
    #
    # Issues its own requests and so clobbers `response`; give it its own test.
    def assert_no_frame_trapped_links(path)
      get path
      assert_response :success, "expected #{path} to render before inspecting its frames"

      TurboFrameLinks.trapped_candidates(response.body, host: host).each do |candidate|
        get candidate.href
        3.times do
          break unless response.redirect?
          follow_redirect!
        end

        assert_response :success,
          "#{candidate.href} (linked inside frame ##{candidate.frame_id} on #{path}) " \
          "returned #{response.status}"

        assert Nokogiri::HTML5(response.body).at_css(%(turbo-frame[id="#{candidate.frame_id}"])),
          "Frame-trapped link on #{path}: <a href=\"#{candidate.href}\"> navigates frame " \
          "##{candidate.frame_id}, but that page contains no such frame, so Turbo renders " \
          "\"Content missing\". Fix it with target: \"_top\" on the frame, or " \
          "data-turbo-frame: \"_top\" on the link."
      end
    end
```

- [ ] **Step 2: Add the guard tests**

In `web-app/test/controllers/my_lists_controller_test.rb`, append these four tests at the end of the class (before the final `end`). The `setup` block already sets the music host, so the books and games tests override it before signing in — matching the ordering the existing books tests use.

```ruby
  # --- Turbo frame integrity ---
  #
  # Every link inside the list_items frame has to break out of it: the book,
  # album, game and song show pages have no list_items frame, so a link scoped
  # to the frame renders "Content missing". See CLAUDE.md, "Turbo Frames trap
  # links".

  test "no link in an albums list is trapped in the list_items frame" do
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(@albums_favorites, view_mode: mode)
    end
  end

  test "no link in a songs list is trapped in the list_items frame" do
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_music_songs_favorites), view_mode: mode
      )
    end
  end

  test "no link in a books list is trapped in the list_items frame" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_books_favorites), view_mode: mode
      )
    end
  end

  test "no link in a games list is trapped in the list_items frame" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_games_favorites), view_mode: mode
      )
    end
  end
```

- [ ] **Step 3: Run the guard tests and verify they FAIL**

Run: `bin/rails test test/controllers/my_lists_controller_test.rb -n "/trapped in the list_items frame/"`

Expected: 4 runs, **4 failures**, each reporting `Frame-trapped link on /my/lists/...` and naming a `/book/`, `/album/`, `/game/` or `/song/` href scoped to frame `#list_items`.

This is the whole point of the task — do not proceed until you have seen these four failures. If a failure instead reads `returned 404`, stop and report it: a fixture destination that doesn't render is a separate real finding, not something to work around.

- [ ] **Step 4: Apply the fix**

In `web-app/app/views/my_lists/show.html.erb`, line 70, add `target: "_top"`:

```erb
  <%= turbo_frame_tag "list_items", target: "_top", data: {turbo_action: "advance"} do %>
```

Then opt pagination back into the frame. Line 81:

```erb
        <div class="flex justify-center mb-6"><%== @pagy.series_nav(anchor_string: 'data-turbo-frame="list_items"') %></div>
```

And line 114:

```erb
        <div class="flex justify-center mt-6"><%== @pagy.series_nav(anchor_string: 'data-turbo-frame="list_items"') %></div>
```

This is the same `anchor_string` pattern `app/views/admin/ranked_items/index.html.erb:82` already uses. Change nothing else — `Books::CardComponent`, `UserLists::Show::ItemComponent#title_link` and `Music::Songs::ListItemComponent` are intentionally left alone.

- [ ] **Step 5: Run the guard tests and verify they PASS**

Run: `bin/rails test test/controllers/my_lists_controller_test.rb -n "/trapped in the list_items frame/"`
Expected: 4 runs, 0 failures, 0 errors.

- [ ] **Step 6: Run the whole user-list test file**

Run: `bin/rails test test/controllers/my_lists_controller_test.rb`
Expected: 0 failures, 0 errors. Nothing in this file asserts on the frame's markup, so nothing should regress.

- [ ] **Step 7: Lint**

Run: `bundle exec standardrb test/test_helper.rb test/controllers/my_lists_controller_test.rb`
Expected: no offenses.

- [ ] **Step 8: Commit**

```bash
git add web-app/test/test_helper.rb web-app/test/controllers/my_lists_controller_test.rb web-app/app/views/my_lists/show.html.erb
git commit -m "Let links escape the list_items frame on user list pages"
```

---

### Task 3: Pin the music public list pages and document the convention

**Files:**
- Modify: `web-app/test/controllers/music/albums/lists_controller_test.rb`
- Modify: `web-app/test/controllers/music/songs/lists_controller_test.rb`
- Modify: `CLAUDE.md` (project root, **not** `web-app/CLAUDE.md`)

**Interfaces:**
- Consumes: `assert_no_frame_trapped_links(path)` from Task 2.
- Produces: nothing consumed by later tasks.

These two pages use the same `list_items` frame id and are correct today — every link inside them already carries `data-turbo-frame="_top"`. The guard pins that so it stays true. Both test classes already `host! "dev.thegreatestmusic.org"` in `setup` and both pages are public, so no sign-in is needed.

- [ ] **Step 1: Add the guard to the albums list test**

In `web-app/test/controllers/music/albums/lists_controller_test.rb`, append inside the `ListsControllerTest` class:

```ruby
      test "no link on a list page is trapped in the list_items frame" do
        list = lists(:music_albums_list)

        assert_no_frame_trapped_links "/albums/lists/#{list.id}"
      end
```

- [ ] **Step 2: Add the guard to the songs list test**

In `web-app/test/controllers/music/songs/lists_controller_test.rb`, append inside the `ListsControllerTest` class:

```ruby
      test "no link on a list page is trapped in the list_items frame" do
        list = lists(:music_songs_list)

        assert_no_frame_trapped_links "/songs/lists/#{list.id}"
      end
```

- [ ] **Step 3: Run both new tests**

Run: `bin/rails test test/controllers/music/albums/lists_controller_test.rb test/controllers/music/songs/lists_controller_test.rb`
Expected: 0 failures, 0 errors. These pass on the first run — they are pins, not fixes. If either fails, it has found a real trapped link on a music list page: fix it the same way (`target: "_top"` on that frame plus `anchor_string` on its pagy nav) and note it in the final report.

- [ ] **Step 4: Document the convention in `CLAUDE.md`**

In the project-root `CLAUDE.md`, under the **Frontend** heading, append this paragraph after the existing text:

```markdown
**Turbo Frames trap links.** Every `<a>` inside a `turbo_frame_tag` navigates *that frame*, so a
link to another page renders "Content missing". Put `target: "_top"` on any frame whose contents
link off-page, and opt pagination back in with
`@pagy.series_nav(anchor_string: 'data-turbo-frame="<frame_id>"')`. The
`assert_no_frame_trapped_links` integration assertion guards this.
```

- [ ] **Step 5: Run the full suite and lint**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. Compare the **runs** count against the pre-change baseline plus the tests added here (12 in Task 1, 4 in Task 2, 2 in Task 3) — a drop in runs means something failed to load rather than failed to pass.

Run: `bundle exec standardrb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add web-app/test/controllers/music CLAUDE.md
git commit -m "Pin music list pages against frame-trapped links; document the convention"
```

---

### Task 4: Playwright proof in a real browser

**Files:**
- Modify: `web-app/e2e/tests/books/account/my-lists.spec.ts`

**Interfaces:**
- Consumes: `process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID`, set in `web-app/e2e/.env` and populated by `bin/rails e2e:books_public_list`. That task creates "E2E Public Books", a custom `Books::UserList` owned by the Playwright account holding three books — the exact surface the bug was reported on.
- Produces: nothing.

The file's existing tests run under the `books-account` Playwright project (authenticated, `https://dev-new.thegreatestbooks.org`). `playwright.config.ts` loads `e2e/.env` through dotenv at the top level, so the env var is available without any config change.

- [ ] **Step 1: Make sure the e2e list fixture exists**

Run: `bin/rails e2e:books_public_list`
Expected: prints `PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID=<n>` and `PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID=<n>`. Confirm the first value matches `PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID` in `web-app/e2e/.env`; update the file if it doesn't.

- [ ] **Step 2: Write the failing E2E tests**

At the top of `web-app/e2e/tests/books/account/my-lists.spec.ts`, below the existing import, add:

```typescript
const publicListId = process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID!;
```

Then append a new describe block at the end of the file:

```typescript
test.describe('Books My Lists item links', () => {
  // The list lives inside a #list_items Turbo Frame. Without target="_top" the
  // click is scoped to that frame, the book page has no such frame, and Turbo
  // writes "Content missing" instead of navigating.
  for (const [label, viewMode] of [['grid', 'grid_view'], ['list', 'list_view']] as const) {
    test(`a book title in ${label} view navigates to the book page`, async ({ page }) => {
      await page.goto(`/my/lists/${publicListId}?view_mode=${viewMode}`);

      const link = page.locator('#list_items a[href^="/book/"]').first();
      const title = (await link.innerText()).trim();
      await link.click();

      await expect(page).toHaveURL(/\/book\//);
      await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
      await expect(page.getByText('Content missing')).toHaveCount(0);
    });
  }
});
```

- [ ] **Step 3: Verify the tests fail against the unfixed view**

Temporarily undo the fix by editing `web-app/app/views/my_lists/show.html.erb` line 70 back to its original form — delete `target: "_top", ` so it reads:

```erb
  <%= turbo_frame_tag "list_items", data: {turbo_action: "advance"} do %>
```

Do **not** use `git stash` for this. The stash stack is shared with the main checkout and every other worktree, and a one-token edit is easier to reverse than a stash entry.

Then build, serve, and run the spec:

```bash
yarn build:all
bin/rails server            # leave running in another shell; do NOT use bin/dev
yarn test:e2e --project=books-account -g "navigates to the book page"
```

Expected: both tests FAIL — the URL stays on `/my/lists/...` and "Content missing" is on the page. That is the reported bug, reproduced in a real browser.

- [ ] **Step 4: Restore the fix**

Put `target: "_top", ` back on line 70:

```erb
  <%= turbo_frame_tag "list_items", target: "_top", data: {turbo_action: "advance"} do %>
```

Verify nothing else drifted:

```bash
git diff --stat web-app/app/views/my_lists/show.html.erb
```

Expected: no output — the file matches the commit from Task 2.

- [ ] **Step 5: Run the E2E tests and verify they pass**

```bash
yarn test:e2e --project=books-account -g "navigates to the book page"
```

Expected: 2 passed.

- [ ] **Step 6: Run the whole books-account project for regressions**

```bash
yarn test:e2e --project=books-account
```

Expected: 0 failures. The existing add-to-list spec touches the same widget, so this catches any interaction between the frame change and the add flow.

- [ ] **Step 7: Commit**

```bash
git add web-app/e2e/tests/books/account/my-lists.spec.ts
git commit -m "Add E2E coverage for item links on user list pages"
```

---

## Definition of done

- `bin/rails test` — 0 failures, 0 errors, runs count up by 18.
- `bundle exec standardrb` — no offenses.
- `yarn test:e2e --project=books-account` — 0 failures.
- The four `my_lists` guard tests were observed failing before the fix and passing after (Task 2, Steps 3 and 5).
- The two E2E tests were observed failing against the unfixed view and passing after (Task 4, Steps 3 and 5).
