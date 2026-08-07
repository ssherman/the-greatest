# Cloudflare Challenge Hand-off Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Cloudflare answers an async request with a bot challenge, hand off to a real page navigation so the visitor can solve it, instead of the request dying silently.

**Architecture:** One new side-effect JS module wraps `window.fetch`. Turbo calls `window.fetch` by property lookup at call time, so the wrapper sits upstream of every Turbo Drive visit, form submission, and frame load, plus the eleven hand-rolled `fetch()` calls in the codebase. When a response carries `cf-mitigated: challenge`, the wrapper either navigates to the challenged URL (document navigations) or reloads the current page (everything else), and returns a never-settling promise so no caller acts on challenge HTML.

**Tech Stack:** Vanilla ES modules bundled by Rollup into per-domain IIFE bundles; Hotwire Turbo 8.0.16; Playwright for behaviour that only exists in a browser; Minitest + ViewComponent::TestCase for the Ruby-side regression guard.

**Spec:** `docs/superpowers/specs/2026-08-07-cloudflare-challenge-turbo-handoff-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. `pwd` first if unsure.
- Lint Ruby with `bundle exec standardrb` — **not** `bin/rubocop`. Do not run brakeman.
- Full Ruby suite: `bin/rails test`. It must be green before any commit.
- `app/assets/builds/` is **gitignored** (`.gitignore:36`). JS changes therefore produce no build artifact in any commit, but `yarn build` **must** be run before any Playwright run or the browser will execute stale JS.
- **Do not use `bin/dev`.** Foreman self-terminates without a TTY: its Tailwind watcher exits and takes the whole process group with it. Start the stack as `yarn build:all` then `bin/rails server` (from `web-app/`), plus `./run_caddy.sh` from the **project root** — Playwright's books baseURL is `https://dev-new.thegreatestbooks.org`, which `Caddyfile:31` terminates and reverse-proxies to `localhost:3000`. Rails alone is not enough. Before trusting a Playwright result, confirm what is actually serving port 3000.
- E2E: `yarn test:e2e`. The `books` Playwright project is **unauthenticated**, uses baseURL `https://dev-new.thegreatestbooks.org`, and matches `books/(?!admin/)(?!account/).*`, so a spec at `e2e/tests/books/` needs no auth fixture. Config runs `workers: 1, fullyParallel: false`, and each test gets a fresh browser context, so `sessionStorage` never leaks between tests.
- Scope a single spec file with `npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/<file> --project=books`.
- **No code comments** except short "why" notes for genuinely non-obvious decisions, matching the register already used in `app/lib/books/filter_facets_query.rb`. Never comment what the code plainly says.
- `data-testid` values are kebab-case, and only where role/text/label cannot target the element.
- The `sessionStorage` key is exactly `cf-challenge-handoff` and the guard window is exactly `30000` ms. Tests hardcode both.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

---

### Task 1: Regression guard for adding a second genre

The reported bug looked like "the modal drops the second genre". It was not — the 403 came from Cloudflare. But the E2E suite has never covered adding a genre *on top of an applied one*, which is the exact motion that surfaced it. Close that gap first, before touching any production code, so the correct behaviour is pinned independently of the Cloudflare work.

**This test passes on the very first run. That is the expected outcome, not a problem.** It characterises behaviour that is already correct. Do not "fix" anything to make it fail, and do not modify any Ruby or JS in this task.

**Files:**
- Modify: `e2e/tests/books/filters.spec.ts` (append one test inside the existing `test.describe('Books filters', ...)` block, after the `applying a genre navigates to its canonical filter URL` test at line 32)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Later tasks do not depend on this file.

- [ ] **Step 1: Write the test**

Append inside the existing `describe` block:

```ts
  test('applying a second genre keeps the first', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    await page.getByRole('button', { name: 'Filters' }).click();

    const others = page.locator('input[name="category_slugs[]"]:not([value="novels"])');
    await others.first().waitFor();
    const second = await others.first().getAttribute('value');

    await others.first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    const expected = ['novels', second!].sort().join(',');
    await expect(page).toHaveURL(`/the-greatest/${expected}/books`);
    await expect(page.getByTestId('filter-chip')).toHaveCount(2);
  });
```

`Books::FilterPath#slugs` sorts slugs before joining, so the expected path is the sorted pair. JS `Array#sort` and Ruby `Array#sort` agree for lowercase ASCII slugs with hyphens.

- [ ] **Step 2: Build the JS bundle and start the stack**

From `web-app/`:

```bash
yarn build:all
bin/rails server
```

From the project root, in a second shell:

```bash
./run_caddy.sh
```

Leave both running for the remaining tasks. Confirm Rails is the process actually answering on port 3000, and that `https://dev-new.thegreatestbooks.org` resolves through Caddy, before continuing.

- [ ] **Step 3: Run the test — expect PASS**

```bash
npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/filters.spec.ts --project=books -g "second genre"
```

Expected: **PASS**. If it fails, stop and report — that would mean a real second bug in the filter feature, which contradicts the spec's findings and needs a decision before proceeding.

- [ ] **Step 4: Commit**

```bash
git add e2e/tests/books/filters.spec.ts
git commit -m "$(cat <<'EOF'
Cover applying a second books genre on top of an applied one

The suite covered applying a first genre but never adding one to an
existing filter, which is the motion that surfaced the Cloudflare
challenge bug. The behaviour is already correct; pin it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Regression guard against a duplicated genre input

`Books::FilterFacetsComponent#genre_options` concatenates the selected genres onto `facets.genres`. If the facet query ever stopped excluding what is already selected, a selected genre would render twice — once checked, once unchecked. `Books::FilterFacetsQuery` excludes it today (`app/lib/books/filter_facets_query.rb:48` for genres, `:60` for countries), so this is a guard, not a fix.

**This test also passes on the first run.** Same instruction as Task 1: do not change production code to make it fail.

This belongs in the component test, not a controller test — per CLAUDE.md, controller tests assert status codes and params, never markup.

**Files:**
- Modify: `test/components/books/filter_facets_component_test.rb` (append after the existing `a selected genre renders checked so it can be unchecked` test)

**Interfaces:**
- Consumes: the file's existing `render_component` helper and fixtures `categories(:books_novels_genre)`, `ranking_configurations(:books_global)`.
- Produces: nothing.

- [ ] **Step 1: Write the test**

Append inside `module Books; class FilterFacetsComponentTest`:

```ruby
    test "a selected genre renders exactly one input" do
      render_component(categories: [categories(:books_novels_genre)])

      assert_selector "input[name='category_slugs[]'][value=novels]", count: 1, visible: :all
    end
```

- [ ] **Step 2: Run the test — expect PASS**

```bash
bin/rails test test/components/books/filter_facets_component_test.rb
```

Expected: **PASS**, whole file green.

- [ ] **Step 3: Lint**

```bash
bundle exec standardrb test/components/books/filter_facets_component_test.rb
```

Expected: no offenses.

- [ ] **Step 4: Commit**

```bash
git add test/components/books/filter_facets_component_test.rb
git commit -m "$(cat <<'EOF'
Pin that a selected books genre renders exactly one input

genre_options concatenates selected genres onto facets.genres, so a
genre would render twice if FilterFacetsQuery ever stopped excluding
what is already selected.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Detect the challenge and hand off a document navigation

The core fix. A challenged Turbo Drive form submission must take the whole page to the challenged URL so Cloudflare can render its interstitial.

**Files:**
- Create: `app/javascript/services/cloudflare_challenge.js`
- Modify: `app/javascript/application.js` (add one import)
- Create: `e2e/tests/books/cloudflare-challenge.spec.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: a side-effect-only module — no exports. Importing it replaces `window.fetch`. Task 4 and Task 5 extend the same three functions defined here: `methodOf(input, init)`, `headersOf(input, init)`, and `handOffToNavigation(url, input, init)`.

- [ ] **Step 1: Write the failing test**

Create `e2e/tests/books/cloudflare-challenge.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

const CHALLENGE_BODY =
  '<html><body><h1 data-testid="stub-challenge">Just a moment...</h1></body></html>';

async function stubChallenge(page: import('@playwright/test').Page, urlPattern: string) {
  await page.route(urlPattern, (route) =>
    route.fulfill({
      status: 403,
      contentType: 'text/html',
      headers: { 'cf-mitigated': 'challenge' },
      body: CHALLENGE_BODY,
    }),
  );
}

test.describe('Cloudflare challenge hand-off', () => {
  test('a challenged filter navigation takes the whole page to the challenged URL', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    await page.getByRole('button', { name: 'Filters' }).click();

    const others = page.locator('input[name="category_slugs[]"]:not([value="novels"])');
    await others.first().waitFor();
    const second = await others.first().getAttribute('value');
    const expectedPath = `/the-greatest/${['novels', second!].sort().join(',')}/books`;

    await stubChallenge(page, `**${expectedPath}`);

    await others.first().check();
    await page.getByRole('button', { name: 'Apply' }).click();

    await expect(page.getByTestId('stub-challenge')).toBeVisible();
    await expect(page).toHaveURL(expectedPath);
  });
});
```

The route is registered *after* `page.goto` and scoped to the one exact path, so neither the initial page load nor Turbo's hover prefetching can collide with it. The form GETs `/filters?...`, Rails 303s to the comma path, `fetch` follows the redirect, and the stub answers there — so `response.url` is the comma path, which is what the hand-off must navigate to. Stubbing the navigation as well as the fetch mirrors reality: Cloudflare challenges both, and the visitor sees the interstitial.

- [ ] **Step 2: Run it to verify it fails**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books
```

Expected: FAIL. The stub heading never appears and the URL stays `/the-greatest/novels/books`, because Turbo currently discards the 403 — exactly the reported bug.

- [ ] **Step 3: Write the module**

Create `app/javascript/services/cloudflare_challenge.js`:

```js
const originalFetch = window.fetch.bind(window)

function methodOf(input, init) {
  const method = init?.method ?? (input instanceof Request ? input.method : null)
  return (method ?? "GET").toUpperCase()
}

function headersOf(input, init) {
  const raw = init?.headers ?? (input instanceof Request ? input.headers : null)
  if (!raw) return new Headers()
  return raw instanceof Headers ? raw : new Headers(raw)
}

function handOffToNavigation(url, input, init) {
  window.location.assign(url)
  return true
}

window.fetch = async (input, init) => {
  const response = await originalFetch(input, init)
  if (response.headers.get("cf-mitigated") !== "challenge") return response

  if (handOffToNavigation(response.url, input, init)) {
    return new Promise(() => {})
  }

  return response
}
```

`methodOf` and `headersOf` are unused this task and wired up in Task 4, and `handOffToNavigation` accepts `input`/`init` it does not yet read. Define all three with their final signatures now so Task 4 only changes one function body.

Returning a never-settling promise is deliberate: Turbo's `FetchRequest#perform` awaits it, so `turbo:before-fetch-response` never fires and Turbo never gets the chance to discard the 403 or render challenge HTML under a mismatched CSP nonce. Its progress bar stays up while the browser navigates, which reads correctly as loading.

- [ ] **Step 4: Import it**

In `app/javascript/application.js`, add the import immediately after the Turbo import so the wrapper is installed before Turbo issues any request. Turbo reads `window.fetch` at call time (`node_modules/@hotwired/turbo/dist/turbo.es2017-esm.js:668`), so ordering after the import is safe, but keeping it adjacent documents the relationship:

```js
// Entry point for the build script in your package.json
import "@hotwired/turbo-rails"
import "./services/cloudflare_challenge"
import "./controllers"
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books
```

Expected: PASS.

- [ ] **Step 6: Verify nothing else in the books suite regressed**

```bash
npx playwright test --config=e2e/playwright.config.ts --project=books
```

Scoped to the books project deliberately — the full suite needs the music and games auth setups and is the final gate in Task 5, not a per-task check. Expected: no new failures versus the pre-task baseline. If the baseline was not green, record which specs were already red before this task rather than assuming they are new.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/services/cloudflare_challenge.js app/javascript/application.js e2e/tests/books/cloudflare-challenge.spec.ts
git commit -m "$(cat <<'EOF'
Hand off Cloudflare-challenged fetches to a full page navigation

A challenge page must be rendered and solved by the browser, so
Cloudflare answers fetch() with a bare 403 that Turbo discards
silently -- clicking Apply in the books filter modal did nothing.

Wrap window.fetch, detect cf-mitigated: challenge, and navigate the
whole page to the challenged URL so the interstitial can render.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Reload instead of navigating for non-document requests

Navigating to the challenged URL is only right when the visitor actually asked to go there. Three GET cases where it is wrong:

- The modal's lazy `books_filter_options` frame. Navigating there dumps the visitor on a bare `/filters/options` page — it renders with `layout "books/application"`, so it is a plausible-looking dead end instead of the book grid.
- Hand-rolled JSON GETs. `autocomplete_controller.js:53` sends `Accept: application/json`; navigating there renders raw JSON.
- Unsafe methods. A POST endpoint cannot be replayed as a GET navigation at all.

All three reload the current page instead, obtaining clearance where the visitor already is.

The discriminator, verified against the installed Turbo: `FrameController#prepareRequest` sets `Turbo-Frame: <frame id>` (`turbo.es2017-esm.js:6517`), while a frame explicitly declines to intercept a `_top` target (`:6800`). The filters form targets `_top`, so it goes down the Drive path and sends no such header — it keeps `assign`. Turbo's `FetchMethod` values are **lowercase** (`:689`), so the case-insensitive comparison in `methodOf` is load-bearing: a bare `=== "GET"` would misroute every Turbo GET into the reload branch.

**Files:**
- Modify: `app/javascript/services/cloudflare_challenge.js`
- Modify: `e2e/tests/books/cloudflare-challenge.spec.ts`

**Interfaces:**
- Consumes: `methodOf(input, init)` and `headersOf(input, init)` from Task 3.
- Produces: `isDocumentNavigation(input, init)` returning a boolean. Task 5 does not use it.

- [ ] **Step 1: Write the failing tests**

Add to `e2e/tests/books/cloudflare-challenge.spec.ts`, inside the existing `describe`. A reload is detected by setting a marker on `window`, then confirming a fresh JS context wiped it. The `load` promise is created **before** the trigger so the navigation cannot be missed in a race:

```ts
  async function expectReload(
    page: import('@playwright/test').Page,
    trigger: () => Promise<unknown>,
  ) {
    await page.evaluate(() => {
      window.__notReloaded = true;
    });

    const load = page.waitForEvent('load');
    await trigger();
    await load;

    expect(await page.evaluate(() => window.__notReloaded ?? null)).toBeNull();
  }

  test('a challenged frame load reloads the current page instead of navigating to the frame URL', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/filters/options', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { headers: { Accept: 'text/html', 'Turbo-Frame': 'books_filter_options' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  test('a challenged JSON fetch reloads the current page', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/filters/options', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { headers: { Accept: 'application/json' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });

  test('a challenged POST reloads the current page instead of navigating to the endpoint', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/user_lists', page.url()).href;
    await stubChallenge(page, target);

    await expectReload(page, () =>
      page.evaluate((url) => {
        fetch(url, { method: 'POST', headers: { Accept: 'text/html' } });
      }, target),
    );

    await expect(page).toHaveURL('/the-greatest/novels/books');
  });
```

Two things are deliberate and must not be "tidied":

- The `fetch` calls inside `page.evaluate` are **not** awaited. A challenged request returns a never-settling promise, so awaiting it would hang until the test timed out. The outer `page.evaluate` still resolves because its callback returns immediately.
- Reload detection uses `page.waitForEvent('load')` rather than polling `page.evaluate`. Polling across a navigation can throw "Execution context was destroyed" instead of returning a value, which would be intermittently flaky.

These three tests intercept `/filters/options` and `/user_lists` with a stub, so they never reach Rails — no route, fixture, or authenticated user needs to exist for them.

TypeScript needs the marker declared. Add at the top of the file, after the imports:

```ts
declare global {
  interface Window {
    __notReloaded?: boolean;
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books
```

Expected: the three new tests FAIL, and Task 3's test still passes. Task 3's implementation navigates unconditionally, so `load` does fire and the marker is wiped — the failure lands on the final `toHaveURL`, which reports `/filters/options` or `/user_lists` instead of `/the-greatest/novels/books`. That is precisely the wrong-destination bug these tests exist to prevent.

- [ ] **Step 3: Add the method and header dispatch**

In `app/javascript/services/cloudflare_challenge.js`, replace `handOffToNavigation` with:

```js
const SAFE_METHODS = ["GET", "HEAD"]

function isDocumentNavigation(input, init) {
  if (!SAFE_METHODS.includes(methodOf(input, init))) return false

  const headers = headersOf(input, init)
  if (headers.has("Turbo-Frame")) return false

  return (headers.get("Accept") ?? "").includes("text/html")
}

function handOffToNavigation(url, input, init) {
  if (isDocumentNavigation(input, init)) {
    window.location.assign(url)
  } else {
    window.location.reload()
  }

  return true
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books
```

Expected: all four tests PASS.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/services/cloudflare_challenge.js e2e/tests/books/cloudflare-challenge.spec.ts
git commit -m "$(cat <<'EOF'
Reload rather than navigate for non-document challenged requests

Navigating to the challenged URL is only correct when the visitor asked
to go there. A challenged lazy frame would land them on a bare
/filters/options page, a challenged JSON fetch on raw JSON, and a POST
endpoint cannot be replayed as a GET at all.

Treat a request as a document navigation only when it is GET/HEAD,
carries no Turbo-Frame header, and accepts text/html.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Guard against a hand-off loop

An unsolvable challenge — a blocked clearance cookie, a privacy extension, a misconfigured rule — would otherwise reload forever, which presents as a dead site and burns Cloudflare requests. The worst case is a request that fires automatically on page load: reload, fire, challenge, reload.

The guard keys on **URL**, not on time alone. Solving a challenge and then immediately having a *different* request challenged — landing on a page, then its lazy `/filters/options` frame — is legitimate and must still hand off. Only the same URL repeating inside the window is a loop. When the guard declines, the response falls through to the caller and fails exactly as it does today, which is strictly better than looping.

**Files:**
- Modify: `app/javascript/services/cloudflare_challenge.js`
- Modify: `e2e/tests/books/cloudflare-challenge.spec.ts`

**Interfaces:**
- Consumes: `handOffToNavigation(url, input, init)` from Tasks 3 and 4.
- Produces: nothing further.

- [ ] **Step 1: Write the failing test**

Add to `e2e/tests/books/cloudflare-challenge.spec.ts`, inside the existing `describe`:

```ts
  test('the same URL does not hand off twice inside the guard window', async ({ page }) => {
    await page.goto('/the-greatest/novels/books');
    const target = new URL('/the-greatest/classics/books', page.url()).href;
    await stubChallenge(page, target);

    await page.evaluate(
      ([key, url]) => {
        sessionStorage.setItem(key, JSON.stringify({ url, at: Date.now() }));
      },
      ['cf-challenge-handoff', target],
    );

    const status = await page.evaluate(async (url) => {
      const response = await fetch(url, { headers: { Accept: 'text/html' } });
      return response.status;
    }, target);

    expect(status).toBe(403);
    await expect(page.getByTestId('stub-challenge')).toHaveCount(0);
    await expect(page).toHaveURL('/the-greatest/novels/books');
  });
```

Here the fetch **is** awaited, and must be: the whole point is that the guard declines, so the wrapper returns the real response instead of a never-settling promise. Observing `403` proves the fall-through path.

- [ ] **Step 2: Run it to verify it fails**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books -g "guard window"
```

Expected: FAIL. Without the guard the wrapper navigates, so `page.evaluate` never returns a status and the test times out or reports the stub heading visible.

- [ ] **Step 3: Add the guard**

In `app/javascript/services/cloudflare_challenge.js`, add above `handOffToNavigation`:

```js
const HANDOFF_KEY = "cf-challenge-handoff"
const HANDOFF_WINDOW_MS = 30000

function recentlyHandedOff(url) {
  try {
    const last = JSON.parse(sessionStorage.getItem(HANDOFF_KEY))
    return last?.url === url && Date.now() - last.at < HANDOFF_WINDOW_MS
  } catch {
    return false
  }
}

function recordHandOff(url) {
  try {
    sessionStorage.setItem(HANDOFF_KEY, JSON.stringify({url, at: Date.now()}))
  } catch {
    return
  }
}
```

`sessionStorage` throws in some privacy modes, and a storage failure must never prevent the hand-off itself — so `recordHandOff` swallows it and `recentlyHandedOff` degrades to "not recently", which loses only the loop protection.

Then add the early return at the top of `handOffToNavigation`:

```js
function handOffToNavigation(url, input, init) {
  if (recentlyHandedOff(url)) return false

  recordHandOff(url)

  if (isDocumentNavigation(input, init)) {
    window.location.assign(url)
  } else {
    window.location.reload()
  }

  return true
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
yarn build && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/cloudflare-challenge.spec.ts --project=books
```

Expected: all five tests PASS.

- [ ] **Step 5: Run the full verification gate**

```bash
bin/rails test
bundle exec standardrb
yarn test:e2e
```

Expected: Ruby suite green, no lint offenses, no new E2E failures versus the pre-task baseline. Report actual output — do not claim green without it.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/services/cloudflare_challenge.js e2e/tests/books/cloudflare-challenge.spec.ts
git commit -m "$(cat <<'EOF'
Stop a Cloudflare hand-off from looping on an unsolvable challenge

A challenge that can never be solved -- blocked clearance cookie,
privacy extension, misconfigured rule -- would reload forever if the
challenged request fires on page load.

Decline a second hand-off for the same URL within 30s and let the
response fall through to fail as it did before. Keying on URL keeps the
legitimate case working: solving a challenge and then having a
different request challenged must still hand off.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Manual verification against production

The synthesized challenges prove the mechanism; only production proves the integration, because the stub cannot reproduce Cloudflare's real clearance-cookie behaviour. After deploy, from a network or country that your rules challenge:

1. Go to `https://new.thegreatestbooks.org/`, apply one genre.
2. Reopen the modal, add a second genre, Apply.
3. Expected: the Cloudflare interstitial renders. After solving it, the browser lands on the two-genre path with both chips — rather than the button doing nothing.

## Out of scope

Confirming what this plan deliberately does not touch: any Cloudflare dashboard change; Turnstile pre-clearance and in-place request retry; preserving form state across a challenge; refactoring the eleven hand-rolled `fetch()` call sites to a shared helper (the wrapper already covers them); and the two adjacent Hotwire/Cloudflare issues noted in the spec (Rocket Loader incompatibility, stripped 4xx bodies breaking 422 validation rendering).
