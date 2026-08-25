# Books Fixed Header and Mobile Nav Drawer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the books top navigation always visible while scrolling, and replace the mobile hamburger dropdown with a slide-out drawer.

**Architecture:** The books layout body becomes a daisyUI drawer. The header, main, footer and modals move inside `.drawer-content`; the mobile nav panel becomes a sibling `.drawer-side`. The header gets `sticky top-0 z-30`. A small Stimulus controller fills the four behavioural gaps daisyUI's pure-CSS drawer leaves open.

**Tech Stack:** Rails 8, daisyUI 5.7.21, Tailwind CSS v4, Stimulus, Turbo Drive, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-25-books-fixed-header-design.md`

## Global Constraints

- **Scope is books only.** Do not modify the music, games, movies, or admin layouts.
- **Run all commands from `web-app/`.** Prefix every Ruby command with `mise exec --`.
- **Never introduce `overflow-hidden`, `overflow-auto`, `overflow-scroll`, or `h-screen`** on `<body>`, `.drawer`, `.drawer-content`, or anything between them and the header. Any of these silently kills `position: sticky` on the header. If horizontal clipping is ever needed, use `overflow-x: clip`.
- **daisyUI is 5.7.21.** These v4 classes were removed and fail silently: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Menu state modifiers were renamed: use `menu-active`, `menu-disabled`, `menu-focus` — never bare `active`/`disabled`/`focus`.
- **Do not put `data-turbo-permanent`** on the drawer, the toggle, or the panel. It is the one thing that would wedge the drawer open across navigations.
- **Do not override `.drawer-side`'s `height: 100dvh`.**
- **The `is-drawer-open:` / `is-drawer-close:` variants only match inside `.drawer-side` and its descendants.** They cannot style the hamburger, which lives in `.drawer-content`.
- Linter is `bundle exec standardrb` (NOT `bin/rubocop`). Do not run brakeman.
- Commit after each task. Do not push or open a PR without asking.

## Task Order Rationale

The drawer lands **before** the header becomes sticky, deliberately. The drawer works fine under a non-sticky header and immediately fixes an overflow bug that exists today. Doing it the other way round would leave an intermediate commit where the mobile menu's lower portion is unreachable.

---

### Task 1: Replace the mobile dropdown with a drawer

**Files:**
- Modify: `app/views/layouts/books/application.html.erb`
- Modify: `app/views/books/shared/_nav_links.html.erb`
- Modify: `test/controllers/news_posts_controller_test.rb:540-551`
- Test: `test/controllers/books/layout_test.rb` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: DOM ids and hooks that Tasks 2 and 3 rely on — checkbox `#books-nav-drawer`, panel `#books-nav-drawer-panel`, the wrapper `div.drawer`, and `div.drawer-content`. The nav links partial gains a `variant:` local accepting `:horizontal` (default) or `:vertical`.

- [ ] **Step 1: Write the failing layout test**

Create `test/controllers/books/layout_test.rb`:

```ruby
require "test_helper"

module Books
  class LayoutTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
    end

    # The nav links partial is rendered twice -- once in the desktop bar, once
    # in the drawer panel. A plain assert_select passes when one copy is
    # missing, which is exactly the edit this guards against.
    test "nav links render in both the desktop bar and the drawer panel" do
      get "/"

      assert_response :success
      assert_select ".navbar-center a[href=?]", "/authors", count: 1
      assert_select "#books-nav-drawer-panel a[href=?]", "/authors", count: 1
    end

    test "the drawer panel is a sibling of the drawer content, not inside it" do
      get "/"

      assert_select "div.drawer > div.drawer-content"
      assert_select "div.drawer > div.drawer-side #books-nav-drawer-panel"
      assert_select "div.drawer-content #books-nav-drawer-panel", count: 0
    end

    test "the hamburger is a label pointing at the drawer toggle" do
      get "/"

      assert_select "label[for=?]", "books-nav-drawer"
      assert_select "input#books-nav-drawer[type=?]", "checkbox"
    end

    # The overlay label is the only way to close the drawer without JavaScript.
    test "the drawer has an overlay label that closes it" do
      get "/"

      assert_select ".drawer-side label.drawer-overlay[for=?]", "books-nav-drawer"
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `mise exec -- bin/rails test test/controllers/books/layout_test.rb`

Expected: FAIL — all four tests, because `div.drawer`, `#books-nav-drawer`, and `#books-nav-drawer-panel` do not exist yet.

- [ ] **Step 3: Add the `variant` local to the nav links partial**

The same partial feeds a horizontal menu (where daisyUI floats the submenu as a dropdown) and a vertical menu (where it expands inline). The dropdown-specific classes must not apply in the vertical case.

Edit `app/views/books/shared/_nav_links.html.erb`. Add this as the first line:

```erb
<%# `variant` controls the "Lists" submenu only. :horizontal keeps the floating
    dropdown styling used by the desktop bar; :vertical drops it so the submenu
    expands inline inside the drawer panel, which is what makes this read better
    than the legacy site's floating-menu-over-a-panel. %>
<% variant = local_assigns.fetch(:variant, :horizontal) %>
```

Then replace the submenu `<ul>` opening tag. Change:

```erb
    <ul class="bg-base-100 rounded-box z-[1] w-max max-w-[calc(100vw-2rem)] p-2 shadow">
```

to:

```erb
    <ul class="<%= "bg-base-100 rounded-box z-[1] w-max max-w-[calc(100vw-2rem)] p-2 shadow" if variant == :horizontal %>">
```

Leave every `<li>` in the partial exactly as it is. In particular do not touch the four `id="navbar_my_lists"` / `navbar_my_searches` / `navbar_my_reviews` / `navbar_members` entries — `user_list_state_controller.js` and `membership_state_controller.js` find both copies with `querySelectorAll`, and that keeps working as long as the ids survive.

- [ ] **Step 4: Restructure the layout body**

Edit `app/views/layouts/books/application.html.erb`. Replace everything from `<body ...>` to `</body>` with the following. The `<head>` is unchanged.

```erb
  <body class="bg-base-200"
        data-controller="user-list-state membership-state"
        data-domain="<%= Current.domain %>"
        data-signed-in="<%= signed_in? %>">
    <div class="drawer">
      <%# The checkbox holds open/closed state. `lg:hidden` keeps it out of the
          desktop tab order. It is NOT a Stimulus controller root -- the
          controller mounts on .drawer so it can reach the content wrapper. %>
      <input id="books-nav-drawer" type="checkbox" class="drawer-toggle lg:hidden" />

      <div class="drawer-content">
        <a href="#main" class="sr-only focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:z-50 btn btn-sm btn-primary">Skip to content</a>

        <nav class="navbar bg-base-300" aria-label="Main">
          <div class="navbar-start">
            <label for="books-nav-drawer"
                   id="books-nav-drawer-button"
                   class="btn btn-ghost drawer-button lg:hidden"
                   aria-label="Open navigation menu">
              <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h8m-8 6h16" />
              </svg>
            </label>
            <%= link_to "/", class: "btn btn-ghost text-xl" do %>
              <span class="text-2xl mr-2">📚</span>
              <%= domain_name %>
            <% end %>
          </div>
          <div class="navbar-center hidden lg:flex">
            <ul class="menu menu-horizontal px-1">
              <%= render "books/shared/nav_links", variant: :horizontal %>
            </ul>
          </div>
          <div class="navbar-end">
            <%# Mobile: icon link to the search page %>
            <%= link_to books_search_path, class: "btn btn-ghost btn-square md:hidden", aria: { label: "Search" } do %>
              <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
              </svg>
            <% end %>

            <%# Desktop: full search input. The value is echoed back only on the
                search page itself -- /lists takes its own `q` for list search, and
                without this guard that query would surface in the global box. %>
            <div class="mr-4 hidden md:block">
              <%= form_with url: books_search_path, method: :get, data: { turbo: false }, class: "flex" do |f| %>
                <%= f.search_field :q,
                    value: (params[:q] if request.path == books_search_path),
                    placeholder: "Search books...",
                    class: "input w-64",
                    autocomplete: "off",
                    "aria-label": "Search books" %>
                <button type="submit" class="btn btn-square btn-ghost" aria-label="Search">
                  <svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
                  </svg>
                </button>
              <% end %>
            </div>

            <button class="btn btn-primary" onclick="login_modal.showModal()" id="navbar_login_button">Login</button>
          </div>
        </nav>

        <main id="main" class="container mx-auto px-4 py-8">
          <%= yield %>
        </main>

        <footer class="footer footer-center p-10 bg-base-300 text-base-content">
          <nav class="grid grid-flow-col gap-4">
            <%= link_to "Genres", books_genres_path, class: "link link-hover" %>
            <%= link_to "Origins", books_countries_path, class: "link link-hover" %>
            <%= link_to "Lists", books_lists_path, class: "link link-hover" %>
          </nav>
          <aside>
            <p>Copyright © 2026 - All rights reserved by <%= domain_name %></p>
          </aside>
        </footer>

        <%= render UserLists::ModalComponent.new %>
        <%= render Reviews::ModalComponent.new %>
        <%= render Toast::RegionComponent.new %>
        <%= render "shared/user_list_icon_template" %>

        <!-- Login Modal -->
        <dialog id="login_modal" class="modal">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Sign In</h3>
            <%= render Authentication::WidgetComponent.new(reload_after_auth: true) %>
            <div class="modal-action">
              <form method="dialog">
                <button class="btn">Close</button>
              </form>
            </div>
          </div>
          <form method="dialog" class="modal-backdrop">
            <button>close</button>
          </form>
        </dialog>
      </div>

      <%# `lg:hidden` is load-bearing, not cosmetic: `display:none` does not
          clear `:checked`, and `.drawer-toggle:checked ~ .drawer-side` still
          matches. Without it, opening the drawer on a phone and rotating past
          the lg breakpoint strands a fixed full-height panel over the desktop
          layout. Task 2 adds a matchMedia uncheck as the belt to this braces. %>
      <div class="drawer-side z-40 lg:hidden">
        <label for="books-nav-drawer" aria-label="Close navigation menu" class="drawer-overlay"></label>
        <div id="books-nav-drawer-panel" class="bg-base-100 min-h-full w-80 p-4">
          <ul class="menu w-full">
            <%= render "books/shared/nav_links", variant: :vertical %>
          </ul>
        </div>
      </div>
    </div>
  </body>
```

Two things to note about what changed and what did not:
- `z-40` on `.drawer-side` overrides daisyUI's default `z-index: 10`. Task 3 gives the header `z-30`, and the drawer must paint above it.
- The old `<div class="dropdown">` wrapper and its `<ul class="menu menu-sm dropdown-content ...">` are gone entirely. Do not leave a stub behind.

- [ ] **Step 5: Run the layout test to verify it passes**

Run: `mise exec -- bin/rails test test/controllers/books/layout_test.rb`

Expected: PASS, 4 runs, 0 failures.

- [ ] **Step 6: Run the news posts test to observe the expected breakage**

Run: `mise exec -- bin/rails test test/controllers/news_posts_controller_test.rb`

Expected: FAIL — 1 failure, `the books nav links to the news section on both mobile and desktop`. The books drawer panel is outside `.navbar`, so the count is 1 where the test wants 2. This failure is correct and expected; the next step fixes the assertion, not the markup.

- [ ] **Step 7: Rescope the news posts assertion**

Edit `test/controllers/news_posts_controller_test.rb`. Replace the body of the loop (the `assert_select` at line 549 and the comment above it) so the whole `each` block reads:

```ruby
  }.each do |host, domain|
    test "the #{domain} nav links to the news section on both mobile and desktop" do
      host! host

      get news_path

      assert_response :success

      if domain == :books
        # Books renders its mobile nav in a daisyUI drawer, which is a sibling
        # of .navbar rather than a child. Asserting each location separately
        # still catches an edit that updates only one copy.
        assert_select ".navbar-center a[href=?]", "/news", count: 1
        assert_select ".drawer-side a[href=?]", "/news", count: 1
      else
        # `.navbar`, not `nav`: music and games use <div class="navbar">.
        # Scoped to the bar so the footer's own links cannot satisfy it.
        assert_select ".navbar a[href=?]", "/news", count: 2
      end
    end
  end
```

- [ ] **Step 8: Run the news posts test to verify it passes**

Run: `mise exec -- bin/rails test test/controllers/news_posts_controller_test.rb`

Expected: PASS, 80 runs, 0 failures.

- [ ] **Step 9: Run the lint and books suites**

Run: `mise exec -- bin/rails test test/lint/`

Expected: PASS. In particular `daisyui_v4_classes_test.rb` (no removed classes introduced) and `stimulus_manifest_test.rb` (no controller referenced yet, so nothing changed).

Run: `mise exec -- bin/rails test test/controllers/books/`

Expected: PASS, 295 runs, 0 failures (291 baseline + 4 new).

- [ ] **Step 10: Lint**

Run: `mise exec -- bundle exec standardrb`

Expected: no offenses.

- [ ] **Step 11: Commit**

```bash
git add app/views/layouts/books/application.html.erb app/views/books/shared/_nav_links.html.erb test/controllers/books/layout_test.rb test/controllers/news_posts_controller_test.rb
git commit -m "Replace the books mobile nav dropdown with a daisyUI drawer"
```

---

### Task 2: Stimulus controller for drawer behaviour

**Files:**
- Create: `app/javascript/controllers/books/nav_drawer_controller.js`
- Modify: `app/javascript/manifests/books_web.js`
- Modify: `app/views/layouts/books/application.html.erb`
- Test: `e2e/tests/books/nav-drawer.spec.ts` (create)

**Interfaces:**
- Consumes: from Task 1 — `#books-nav-drawer` (checkbox), `#books-nav-drawer-panel`, `div.drawer`, `div.drawer-content`, `#books-nav-drawer-button` (label).
- Produces: Stimulus identifier `books--nav-drawer`, registered in `books_web.js`. Targets: `toggle`, `content`, `button`. No public methods other targets depend on.

daisyUI ships no JavaScript for the drawer. Four gaps need closing, and the first is a real bug rather than a polish item.

- [ ] **Step 1: Write the failing E2E test**

Create `e2e/tests/books/nav-drawer.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

// The books Playwright project runs Desktop Chrome, which is above the `lg`
// breakpoint where the drawer is hidden. Every test here must set a phone
// viewport explicitly or it will assert against the desktop bar instead.
const PHONE = { width: 390, height: 844 };

test.describe('Books mobile nav drawer', () => {
  test.use({ viewport: PHONE });

  test('the hamburger opens the panel', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();

    await page.locator('#books-nav-drawer-button').click();

    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();
    await expect(page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' })).toBeVisible();
  });

  test('Escape closes the panel', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();

    await page.keyboard.press('Escape');

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
  });

  test('the hamburger reports its expanded state', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#books-nav-drawer-button')).toHaveAttribute('aria-expanded', 'false');

    await page.locator('#books-nav-drawer-button').click();

    await expect(page.locator('#books-nav-drawer-button')).toHaveAttribute('aria-expanded', 'true');
  });

  test('clicking a link navigates and leaves the drawer closed', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();

    await page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' }).click();

    await expect(page).toHaveURL(/\/authors/);
    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
  });

  // The regression test that matters. Turbo's page snapshot is cloneNode(true),
  // and the HTML spec propagates an input's *checkedness* into the clone. So
  // the outgoing page is cached with the toggle checked, and Back restores the
  // drawer open -- with the page behind it still scroll-locked by daisyUI's
  // :root:has(.drawer-toggle:checked) rule.
  test('going back does not restore an open drawer or a locked page', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await page.locator('#books-nav-drawer-panel').getByRole('link', { name: 'Authors' }).click();
    await expect(page).toHaveURL(/\/authors/);

    await page.goBack();

    await expect(page.locator('#books-nav-drawer-panel')).not.toBeVisible();
    await expect(page.locator('#books-nav-drawer')).not.toBeChecked();
    // Prove the page still scrolls -- the scroll lock is the harmful half.
    await expect
      .poll(async () => page.evaluate(() => getComputedStyle(document.documentElement).overflow))
      .not.toBe('hidden');
  });

  // Measured on the current markup: tabbing past the last panel link walks to
  // BODY, then the toggle, then a link in the navbar behind the overlay. The
  // controller sets `inert` on .drawer-content to stop that.
  test('background content is inert while the drawer is open', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('.drawer-content')).not.toHaveAttribute('inert', /.*/);

    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer-panel')).toBeVisible();

    await expect(page.locator('.drawer-content')).toHaveAttribute('inert', '');
    // The Login button lives in the navbar, behind the overlay.
    await expect(page.locator('#navbar_login_button')).not.toBeFocused();
    await page.keyboard.press('Tab');
    await expect(page.locator('#navbar_login_button')).not.toBeFocused();
  });

  // `display:none` does not clear `:checked`. Without the matchMedia uncheck,
  // widening past `lg` while open leaves the panel state stuck on.
  test('crossing the lg breakpoint while open resets the drawer', async ({ page }) => {
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await expect(page.locator('#books-nav-drawer')).toBeChecked();

    await page.setViewportSize({ width: 1280, height: 800 });

    await expect(page.locator('#books-nav-drawer')).not.toBeChecked();
    await expect(page.locator('.drawer-content')).not.toHaveAttribute('inert', /.*/);
  });

  test('the whole menu is reachable in landscape with Lists expanded', async ({ page }) => {
    await page.setViewportSize({ width: 844, height: 390 });
    await page.goto('/');
    await page.locator('#books-nav-drawer-button').click();
    await page.locator('#books-nav-drawer-panel').getByText('Lists', { exact: true }).click();

    const lastLink = page.locator('#books-nav-drawer-panel a').last();
    await lastLink.scrollIntoViewIfNeeded();

    await expect(lastLink).toBeInViewport();
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Make sure a dev server is running on port 3000 first (`mise exec -- bin/rails server -p 3000`; do not use `bin/dev`, it self-terminates without a TTY).

Run: `yarn test:e2e --project=books nav-drawer`

Expected, and confirm this exact split before writing any controller code:

- PASS: `the hamburger opens the panel` and `the whole menu is reachable in landscape` — Task 1's CSS-only drawer already does both.
- FAIL: `Escape closes the panel`, `the hamburger reports its expanded state`, `clicking a link navigates and leaves the drawer closed`, `going back does not restore an open drawer or a locked page`, `background content is inert while the drawer is open`, `crossing the lg breakpoint while open resets the drawer`.

If the Back test passes here, the bug is not reproducing — stop and find out why rather than writing a fix for nothing.

- [ ] **Step 3: Write the controller**

Create `app/javascript/controllers/books/nav_drawer_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="books--nav-drawer"
//
// daisyUI's drawer is pure CSS: a hidden checkbox holds the open/closed state
// and a <label> toggles it. That works with JavaScript disabled, which is why
// this controller augments it rather than replacing it. Four gaps are left:
//
//   1. Turbo caches the checkbox CHECKED. PageSnapshot#clone is cloneNode(true),
//      and the HTML standard propagates an input's checkedness into the clone.
//      Open the drawer, follow a link, press Back: the drawer is restored open
//      AND the page behind is scroll-locked, because daisyUI keys its lock off
//      :root:has(.drawer-toggle:checked). This is the one that bites users.
//   2. Escape does not close it.
//   3. Focus is not contained -- tabbing past the last panel link walks into
//      page content hidden behind the overlay.
//   4. `display:none` does not clear `:checked`, so crossing the lg breakpoint
//      while open strands the panel over the desktop layout. The `lg:hidden`
//      on .drawer-side handles the visual half; this handles the state.
//
// Forward navigation needs no help: Turbo replaces <body> with freshly parsed
// HTML, and a morph refresh syncs the checkbox property from the new document.
const DESKTOP = "(min-width: 64rem)" // Tailwind `lg`

export default class extends Controller {
  static targets = ["toggle", "content", "button"]

  connect() {
    this.close()

    this.onKeydown = this.onKeydown.bind(this)
    this.onBeforeCache = this.close.bind(this)
    this.onToggleChange = this.syncState.bind(this)
    this.onBreakpointChange = this.onBreakpointChange.bind(this)

    document.addEventListener("keydown", this.onKeydown)
    document.addEventListener("turbo:before-cache", this.onBeforeCache)
    this.toggleTarget.addEventListener("change", this.onToggleChange)

    this.desktop = window.matchMedia(DESKTOP)
    this.desktop.addEventListener("change", this.onBreakpointChange)

    this.syncState()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("turbo:before-cache", this.onBeforeCache)
    this.toggleTarget.removeEventListener("change", this.onToggleChange)
    this.desktop.removeEventListener("change", this.onBreakpointChange)
    // Leave no inert wrapper behind if we are torn down while open.
    this.contentTarget.removeAttribute("inert")
  }

  // Close when a link inside the panel is clicked. Forward navigation would
  // reset the checkbox anyway, but this gives immediate feedback and covers
  // links that never swap the body: in-page anchors and Turbo frame targets.
  closeOnNavigate(event) {
    if (event.target.closest("a")) this.close()
  }

  close() {
    if (this.hasToggleTarget) this.toggleTarget.checked = false
    this.syncState()
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.isOpen) this.close()
  }

  onBreakpointChange(event) {
    if (event.matches) this.close()
  }

  get isOpen() {
    return this.hasToggleTarget && this.toggleTarget.checked
  }

  // Single place that mirrors checkbox state onto the things CSS cannot reach:
  // the label's aria-expanded, and `inert` on the background content.
  syncState() {
    const open = this.isOpen

    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute("aria-expanded", open ? "true" : "false")
    }

    if (this.hasContentTarget) {
      if (open) {
        this.contentTarget.setAttribute("inert", "")
      } else {
        this.contentTarget.removeAttribute("inert")
      }
    }
  }
}
```

- [ ] **Step 4: Register the controller**

Edit `app/javascript/manifests/books_web.js`. Add, keeping the file's alphabetical-by-identifier ordering:

```javascript
import Books__NavDrawerController from "../controllers/books/nav_drawer_controller"
application.register("books--nav-drawer", Books__NavDrawerController)
```

It goes in `books_web.js` and **not** `web_shared.js`: the only markup referencing it is `app/views/layouts/books/application.html.erb`, which `stimulus_manifest_test.rb` classifies as domain `books`. Registering it in `web_shared.js` would ship it to music, games and movies, where nothing references it.

- [ ] **Step 5: Wire the controller into the layout**

Edit `app/views/layouts/books/application.html.erb`.

Put the controller on the drawer wrapper so it can reach both the toggle and the content wrapper:

```erb
    <div class="drawer"
         data-controller="books--nav-drawer"
         data-action="click->books--nav-drawer#closeOnNavigate">
```

Add the toggle target to the checkbox:

```erb
      <input id="books-nav-drawer" type="checkbox" class="drawer-toggle lg:hidden"
             data-books--nav-drawer-target="toggle" />
```

Add the content target:

```erb
      <div class="drawer-content" data-books--nav-drawer-target="content">
```

Add the button target and the initial ARIA state to the hamburger label:

```erb
            <label for="books-nav-drawer"
                   id="books-nav-drawer-button"
                   class="btn btn-ghost drawer-button lg:hidden"
                   data-books--nav-drawer-target="button"
                   aria-controls="books-nav-drawer-panel"
                   aria-expanded="false"
                   aria-label="Open navigation menu">
```

- [ ] **Step 6: Rebuild the bundles**

Run: `mise exec -- yarn build:all`

Expected: exits 0. Plain `bin/rails test` does not build the bundles, so a stale bundle will make the E2E fail for the wrong reason.

- [ ] **Step 7: Run the E2E test to verify it passes**

Run: `yarn test:e2e --project=books nav-drawer`

Expected: PASS, 8 tests.

- [ ] **Step 8: Run the Stimulus manifest lint**

Run: `mise exec -- bin/rails test test/lint/stimulus_manifest_test.rb`

Expected: PASS. This proves the new controller is both referenced and registered, and that it did not leak into the other domains' bundles.

- [ ] **Step 9: Commit**

```bash
git add app/javascript/controllers/books/nav_drawer_controller.js app/javascript/manifests/books_web.js app/views/layouts/books/application.html.erb e2e/tests/books/nav-drawer.spec.ts
git commit -m "Close the books nav drawer on Escape, navigation, and Turbo cache"
```

---

### Task 3: Pin the header

**Files:**
- Modify: `app/views/layouts/books/application.html.erb`
- Modify: `app/views/books/books/show.html.erb:13`
- Modify: `e2e/tests/books/nav-drawer.spec.ts`

**Interfaces:**
- Consumes: from Task 1 — `div.drawer-content` and the `<nav class="navbar">` inside it; `.drawer-side` already carries `z-40`.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing E2E tests**

Append to `e2e/tests/books/nav-drawer.spec.ts`, outside the existing `describe` block:

```typescript
test.describe('Books header stays visible', () => {
  test('the header is still at the top of the viewport after scrolling', async ({ page }) => {
    await page.goto('/');

    const before = await page.locator('nav.navbar').boundingBox();
    expect(before?.y).toBe(0);

    await page.evaluate(() => window.scrollBy(0, 1500));

    const after = await page.locator('nav.navbar').boundingBox();
    expect(after?.y).toBe(0);
    await expect(page.locator('#navbar_login_button')).toBeInViewport();
  });

  test('the header stays visible on a phone too', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');

    await page.evaluate(() => window.scrollBy(0, 1500));

    const box = await page.locator('nav.navbar').boundingBox();
    expect(box?.y).toBe(0);
  });

  // The sidebar card on a book page is sticky in its own right. At the old
  // top-8 (32px) it sat 32px under the 64px header.
  test('the book detail sidebar card does not hide under the header', async ({ page }) => {
    await page.goto('/');
    const firstBook = page.locator('a[href^="/book/"]').first();
    await firstBook.click();
    await expect(page).toHaveURL(/\/book\//);

    await page.evaluate(() => window.scrollBy(0, 1200));

    const nav = await page.locator('nav.navbar').boundingBox();
    const card = await page.locator('main .sticky').first().boundingBox();
    expect(card!.y).toBeGreaterThanOrEqual(nav!.y + nav!.height);
  });
});
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `yarn test:e2e --project=books nav-drawer`

Expected: the three new tests FAIL — the header scrolls away, so `y` is negative rather than 0, and the card overlaps the header.

- [ ] **Step 3: Pin the header**

Edit `app/views/layouts/books/application.html.erb`. Change the nav opening tag from:

```erb
        <nav class="navbar bg-base-300" aria-label="Main">
```

to:

```erb
        <%# sticky, not fixed: sticky reserves its own space, so no compensating
            padding-top on the body. z-30 sits under .drawer-side's z-40 so the
            open drawer and its dimmed overlay cover the header. %>
        <nav class="navbar bg-base-300 sticky top-0 z-30" aria-label="Main">
```

- [ ] **Step 4: Give the skip-link target clearance**

In the same file, change:

```erb
        <main id="main" class="container mx-auto px-4 py-8">
```

to:

```erb
        <main id="main" class="container mx-auto px-4 py-8 scroll-mt-20">
```

Without this, "Skip to content" scrolls `#main` flush to the viewport top, where the header covers it.

- [ ] **Step 5: Lift the book detail sidebar card**

Edit `app/views/books/books/show.html.erb` line 13. Change:

```erb
    <div class="card bg-base-100 shadow-xl sticky top-8">
```

to:

```erb
    <div class="card bg-base-100 shadow-xl sticky top-20">
```

`top-20` is 80px, clearing the 64px header with 16px to spare. This is the only books view using `sticky` — do not go looking for others.

- [ ] **Step 6: Rebuild and run the E2E tests**

Run: `mise exec -- yarn build:all`

Then: `yarn test:e2e --project=books nav-drawer`

Expected: PASS, 11 tests.

- [ ] **Step 7: Verify sticky did not get killed by a wrapper**

Run this check against the running dev server and confirm every value is the safe one:

```bash
node -e "const{chromium}=require('@playwright/test');(async()=>{const b=await chromium.launch({args:['--ignore-certificate-errors']});const p=await(await b.newContext({ignoreHTTPSErrors:true})).newPage();await p.goto('https://dev-new.thegreatestbooks.org/');console.log(await p.evaluate(()=>['body','.drawer','.drawer-content'].map(s=>{const e=document.querySelector(s);const c=getComputedStyle(e);return s+': overflow='+c.overflow+' transform='+c.transform+' filter='+c.filter+' contain='+c.contain;}).join('\n')));await b.close();})()"
```

Expected: every line reads `overflow=visible transform=none filter=none contain=none`. Anything else means a wrapper is about to break the sticky header silently.

- [ ] **Step 8: Run the full Rails suite**

Run: `mise exec -- bin/rails db:test:prepare test`

Expected: PASS, 0 failures, 0 errors. Watch the warning output — a clean run emits no warnings beyond `weighted_list_rank`'s position `puts` and npm/yarn noise during `test:prepare`. A new warning line is a regression.

- [ ] **Step 9: Lint**

Run: `mise exec -- bundle exec standardrb`

Expected: no offenses.

- [ ] **Step 10: Commit**

```bash
git add app/views/layouts/books/application.html.erb app/views/books/books/show.html.erb e2e/tests/books/nav-drawer.spec.ts
git commit -m "Pin the books header so it stays visible while scrolling"
```

---

## Manual verification before merge

Two things automated tests here cannot settle.

- [ ] **iOS scroll lock, on a real iPhone.** Open the drawer on a books page and try to scroll the page behind the overlay. It must not move. daisyUI locks scrolling via root-level `overflow: hidden`, which is the approach that avoids the classic iOS scroll-position jump, but no authoritative confirmation was found that it holds on current iOS Safari, and Playwright on Linux cannot prove it. If it fails, only background-scroll-while-open is affected; the drawer still opens, closes and navigates.

- [ ] **Signed-in nav on a phone.** Sign in and open the drawer. Four extra links (My Lists, My Searches, My Reviews, Members) are revealed client-side, taking the panel to roughly 541px. Confirm all of them are reachable, and confirm the same in landscape. The E2E suite runs signed out, so it never sees these.
