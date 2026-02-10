# Playwright E2E Testing Suite

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-09
- **Started**: 2026-02-09
- **Completed**: 2026-02-09
- **Developer**: AI Agent (Claude)

## Overview
Add a Node.js-based Playwright end-to-end testing suite to The Greatest, running against local dev instances (`https://dev.thegreatestmusic.org`, `https://dev.thegreatest.games`, etc.) with real Firebase email/password authentication. The initial scope covers the **Music domain** (public pages and admin flows). No CI integration yet; tests run locally only.

**Non-goals**: Replacing the existing Minitest suite, testing other domains (Movies/Games/Books) in this phase, CI/CD integration, visual regression testing.

## Context & Links
- Existing test suite: Minitest + Mocha + Capybara + Selenium (`test/test_helper.rb`, `test/application_system_test_case.rb`)
- Current system tests: 1 file (`test/system/admin/music/songs/wizard_review_step_test.rb`)
- CI workflow: `web-app/.github/workflows/ci.yml` (not touched in this task)
- Domain config: `config/initializers/domain_config.rb`
- Music admin routes: `config/routes.rb:55-221`
- Auth controller: `app/controllers/auth_controller.rb`
- Firebase auth service: `app/javascript/services/firebase_auth_service.js`
- Authentication Stimulus controller: `app/javascript/controllers/authentication_controller.js`
- Official Playwright docs: https://playwright.dev/docs/intro
- Playwright auth patterns: https://playwright.dev/docs/auth
- Playwright POM pattern: https://playwright.dev/docs/pom

## Interfaces & Contracts

### Technology Stack
- **Test runner**: `@playwright/test` (Node.js, TypeScript)
- **Browsers**: Chromium (primary), Firefox and WebKit optional via config
- **Auth**: Real Firebase email/password login via a dedicated test account
- **Target**: Local dev instances (not a test-mode Rails server)

### Test Account
| Field | Value |
|---|---|
| Email | Stored in `e2e/.env` as `PLAYWRIGHT_ADMIN_EMAIL` |
| Password | Stored in `e2e/.env` as `PLAYWRIGHT_ADMIN_PASSWORD` |
| Provider | Firebase email/password (`password` provider) |
| Role | Admin (must have `admin` DomainRole for music domain) |

> The test account must be created manually in Firebase Console and as a User record in the local dev database with appropriate admin roles before tests can run.

### Directory Structure
```
web-app/
  e2e/
    playwright.config.ts          # Playwright configuration
    tsconfig.json                 # TypeScript config for e2e tests
    .env                          # PLAYWRIGHT_ADMIN_EMAIL, PLAYWRIGHT_ADMIN_PASSWORD (gitignored)
    auth/
      auth.setup.ts               # Global auth setup: login + save storage state
    fixtures/
      auth.ts                     # Custom test fixture extending base with auth
    pages/                        # Page Object Models
      music/
        home-page.ts              # Music homepage POM
        admin/
          login-page.ts           # Login/auth modal POM
          dashboard-page.ts       # Admin dashboard POM
          artists-page.ts         # Admin artists index POM
          albums-page.ts          # Admin albums index POM
          songs-page.ts           # Admin songs index POM
    tests/
      music/
        public/
          homepage.spec.ts        # Public homepage tests
          navigation.spec.ts      # Public nav/routing tests
          albums-browse.spec.ts   # Public album browsing
          songs-browse.spec.ts    # Public song browsing
        auth/
          login.spec.ts           # Firebase email/password login flow
          logout.spec.ts          # Logout flow
        admin/
          dashboard.spec.ts       # Admin dashboard tests
          artists-crud.spec.ts    # Admin artists index/show
          albums-crud.spec.ts     # Admin albums index/show
          songs-crud.spec.ts      # Admin songs index/show
          sidebar-nav.spec.ts     # Admin sidebar navigation
    .auth/                        # Generated auth state (gitignored)
      user.json
  package.json                    # Updated with @playwright/test + scripts
  .gitignore                      # Updated with Playwright artifacts
```

### Configuration

**`e2e/playwright.config.ts`** contract:
```typescript
// reference only
import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(__dirname, '.env') });

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,        // sequential by default for local dev
  retries: 0,
  workers: 1,                  // single worker against live local instance
  reporter: 'html',
  use: {
    baseURL: 'https://dev.thegreatestmusic.org',
    ignoreHTTPSErrors: true,   // local dev may use self-signed certs
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: { mode: 'retain-on-failure' },
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        storageState: '.auth/user.json',
      },
      dependencies: ['setup'],
    },
  ],
});
```

**Key design decisions**:
- `fullyParallel: false` and `workers: 1` — tests run against a shared live database; parallelism would cause data conflicts
- `storageState` reuse — login once in `auth.setup.ts`, all subsequent tests reuse the session via saved cookies/localStorage
- `ignoreHTTPSErrors: true` — local dev domains may use self-signed certificates
- No `webServer` config — the Rails server is started manually by the developer

### Authentication Flow (auth.setup.ts)

The setup project authenticates via the real Firebase email/password flow:

1. Navigate to `https://dev.thegreatestmusic.org`
2. Click the Login button (`#navbar_login_button`)
3. Wait for the auth modal dialog to open
4. Enter email and password in the Firebase email/password form
5. Submit and wait for the Login button to change to "Logout" (confirms session created)
6. Save browser storage state to `.auth/user.json`

This saved state is reused by all test projects, avoiding re-login per test.

> **Important**: Only the `login.spec.ts` test should exercise the full login flow directly. All other tests consume the pre-authenticated `storageState`.

### Page Object Model Contract

Each POM class encapsulates page-specific locators and actions:

```typescript
// reference only — e2e/pages/music/admin/dashboard-page.ts
export class DashboardPage {
  readonly page: Page;
  readonly heading: Locator;
  readonly artistsCard: Locator;
  readonly albumsCard: Locator;
  readonly songsCard: Locator;

  constructor(page: Page) { /* locator setup */ }
  async goto() { /* navigate to /admin */ }
  async getStatCount(card: string): Promise<string> { /* read stat */ }
}
```

**Locator strategy** (in priority order):
1. `page.getByRole()` — accessible roles (buttons, links, headings)
2. `page.getByText()` — visible text content
3. `page.getByLabel()` — form labels
4. `page.getByTestId()` — `data-testid` attributes (add sparingly to views when needed)
5. `page.locator()` — CSS selectors (last resort)

### Schemas (package.json additions)
```json
{
  "devDependencies": {
    "@playwright/test": "^1.50.0",
    "dotenv": "^16.4.0"
  },
  "scripts": {
    "test:e2e": "npx playwright test --config=e2e/playwright.config.ts",
    "test:e2e:ui": "npx playwright test --config=e2e/playwright.config.ts --ui",
    "test:e2e:headed": "npx playwright test --config=e2e/playwright.config.ts --headed",
    "test:e2e:debug": "npx playwright test --config=e2e/playwright.config.ts --debug",
    "test:e2e:codegen": "npx playwright codegen https://dev.thegreatestmusic.org"
  }
}
```

## Behaviors (pre/postconditions)

### Preconditions
- Local Rails dev server running and accessible at `https://dev.thegreatestmusic.org`
- Local database has real data (artists, albums, songs, ranking configurations)
- Test account (per `PLAYWRIGHT_ADMIN_EMAIL`) exists in Firebase and in local User table with admin DomainRole for music
- `PLAYWRIGHT_ADMIN_EMAIL` and `PLAYWRIGHT_ADMIN_PASSWORD` set in `e2e/.env`
- Playwright browsers installed (`npx playwright install chromium`)

### Postconditions/Effects
- Tests do NOT create, modify, or delete data in the local database (read-only browsing + admin index/show pages)
- Auth setup creates a session that is saved and reused
- Failed tests produce screenshots and optionally video/trace in `e2e/test-results/`

### Edge Cases & Failure Modes
- **Server not running**: Tests fail fast with a connection error; `playwright.config.ts` does not auto-start the server
- **Invalid credentials**: `auth.setup.ts` fails, all dependent tests skip
- **Self-signed cert errors**: Handled by `ignoreHTTPSErrors: true`
- **Stale auth state**: If `.auth/user.json` is stale (session expired), delete it and re-run; setup will re-authenticate
- **Domain routing**: Tests must use the correct hostname; Playwright's `baseURL` handles this for music domain
- **Turbo navigation**: Use web-first assertions (`toBeVisible()`, `toHaveURL()`) that auto-wait, not manual `waitForTimeout()`

### Non-Functionals
- **Performance**: No explicit budgets; tests run against local dev with real data
- **Security**: `e2e/.env` containing test password is gitignored; no secrets committed
- **Responsiveness**: Tests run at desktop viewport (1280x720 default); mobile testing is a future improvement

## Acceptance Criteria

### Setup & Configuration
- [ ] `@playwright/test` and `dotenv` added to `package.json` devDependencies
- [ ] `e2e/playwright.config.ts` created with correct baseURL, single worker, and auth project setup
- [ ] `e2e/tsconfig.json` created for TypeScript compilation
- [ ] `e2e/.env` gitignored and documented in README or setup instructions
- [ ] `.gitignore` updated to exclude `e2e/.auth/`, `e2e/test-results/`, `e2e/playwright-report/`
- [ ] `yarn test:e2e` runs the full suite; `yarn test:e2e:ui` opens the UI mode

### Authentication Tests
- [ ] `auth.setup.ts` logs in via Firebase email/password and saves storage state to `e2e/.auth/user.json`
- [ ] `login.spec.ts` tests the full login flow (open modal, enter credentials, verify session)
- [ ] `logout.spec.ts` tests clicking Logout and verifying the user is signed out

### Public Music Page Tests
- [ ] `homepage.spec.ts` verifies the music homepage loads, shows featured albums and songs
- [ ] `navigation.spec.ts` verifies navbar links (Albums, Songs, Artists, Lists) route correctly
- [ ] `albums-browse.spec.ts` verifies album ranking pages load with content
- [ ] `songs-browse.spec.ts` verifies song ranking pages load with content

### Admin Music Page Tests
- [ ] `dashboard.spec.ts` verifies admin dashboard loads with stat cards (Artists, Albums, Songs, Categories)
- [ ] `artists-crud.spec.ts` verifies admin artists index loads with table, show page loads
- [ ] `albums-crud.spec.ts` verifies admin albums index loads with table, show page loads
- [ ] `songs-crud.spec.ts` verifies admin songs index loads with table, show page loads
- [ ] `sidebar-nav.spec.ts` verifies all admin sidebar links navigate correctly

### Page Object Models
- [ ] POMs created for: music homepage, login modal, admin dashboard, admin artists, admin albums, admin songs
- [ ] POMs use accessible locator strategies (role, text, label) over CSS selectors

### Golden Examples

**Auth setup flow:**
```text
Input: Navigate to https://dev.thegreatestmusic.org, click Login, enter PLAYWRIGHT_ADMIN_EMAIL / PLAYWRIGHT_ADMIN_PASSWORD
Output: .auth/user.json created with session cookies and Firebase localStorage tokens
```

**Admin dashboard smoke test:**
```text
Input: Navigate to https://dev.thegreatestmusic.org/admin (authenticated)
Output: Page shows heading "Dashboard", stat cards for Artists/Albums/Songs/Categories with numeric counts
```

**Public homepage test:**
```text
Input: Navigate to https://dev.thegreatestmusic.org (unauthenticated)
Output: Page shows "The Greatest Music" branding, featured albums section, featured songs section
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.
- Tests are read-only against local dev — no CRUD mutations in initial test suite.
- Use TypeScript for all test files.
- Use Page Object Model pattern for reusable page interactions.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- All Acceptance Criteria pass when running `yarn test:e2e` against local dev.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> find existing auth modal HTML structure, admin sidebar link selectors, navbar structure
2) codebase-analyzer -> verify music domain routing and admin page structure for POM locators
3) web-search-researcher -> Playwright best practices for Firebase auth testing, dotenv + Playwright config
4) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- No fixtures needed — tests run against live local dev data.
- Requires manual setup:
  - Firebase account matching `PLAYWRIGHT_ADMIN_EMAIL` with known password
  - Rails User record with admin DomainRole for music domain
  - `e2e/.env` file with `PLAYWRIGHT_ADMIN_EMAIL=<email>` and `PLAYWRIGHT_ADMIN_PASSWORD=<password>`

---

## Implementation Notes
- **Approach**: Built the full suite following the spec structure — config files first, then auth setup, POMs, and test specs. Used accessible locators (getByRole, getByText) as primary strategy with `data-testid` attributes added to views where needed for disambiguation.
- **Important decisions**:
  - Used `path.join(__dirname, ...)` for storageState paths to avoid CWD vs config-relative ambiguity
  - Added explicit timeouts (10-15s) on auth-related assertions due to async Firebase state propagation after page reloads
  - Logout test performs a fresh login rather than relying on saved storageState (see Challenges below)
  - Scoped `e2e/.env` password values must be quoted if they contain `#` (dotenv treats unquoted `#` as inline comment)

### Key Files Touched (paths only)

**Modified existing files:**
- `web-app/package.json` — added `@playwright/test`, `dotenv` devDependencies + 5 test scripts
- `web-app/.gitignore` — added Playwright artifact patterns (`e2e/.auth/`, `e2e/.env`, `e2e/test-results/`, `e2e/playwright-report/`)
- `web-app/app/views/admin/shared/_sidebar.html.erb` — added `data-testid="admin-sidebar"`
- `web-app/app/views/admin/music/artists/show.html.erb` — added `data-testid="back-button"`
- `web-app/app/views/admin/music/albums/show.html.erb` — added `data-testid="back-button"`
- `web-app/app/views/admin/music/songs/show.html.erb` — added `data-testid="back-button"`

**New files (22):**
- `web-app/e2e/playwright.config.ts`
- `web-app/e2e/tsconfig.json`
- `web-app/e2e/.env.example`
- `web-app/e2e/.env` (gitignored)
- `web-app/e2e/auth/auth.setup.ts`
- `web-app/e2e/fixtures/auth.ts`
- `web-app/e2e/pages/music/home-page.ts`
- `web-app/e2e/pages/music/admin/login-page.ts`
- `web-app/e2e/pages/music/admin/dashboard-page.ts`
- `web-app/e2e/pages/music/admin/artists-page.ts`
- `web-app/e2e/pages/music/admin/albums-page.ts`
- `web-app/e2e/pages/music/admin/songs-page.ts`
- `web-app/e2e/tests/music/public/homepage.spec.ts`
- `web-app/e2e/tests/music/public/navigation.spec.ts`
- `web-app/e2e/tests/music/public/albums-browse.spec.ts`
- `web-app/e2e/tests/music/public/songs-browse.spec.ts`
- `web-app/e2e/tests/music/auth/login.spec.ts`
- `web-app/e2e/tests/music/auth/logout.spec.ts`
- `web-app/e2e/tests/music/admin/dashboard.spec.ts`
- `web-app/e2e/tests/music/admin/artists-crud.spec.ts`
- `web-app/e2e/tests/music/admin/albums-crud.spec.ts`
- `web-app/e2e/tests/music/admin/songs-crud.spec.ts`
- `web-app/e2e/tests/music/admin/sidebar-nav.spec.ts`

### Challenges & Resolutions
1. **dotenv `#` comment stripping** — Password in `.env` contained `#`, which dotenv interpreted as an inline comment. Fix: quote the value (`PLAYWRIGHT_ADMIN_PASSWORD="pass#word"`).
2. **Firebase IndexedDB not captured by storageState** — Playwright's `storageState` saves cookies and localStorage but not IndexedDB, where Firebase Auth v9+ persists client-side auth state. The Rails session cookie (captured) is sufficient for admin page access, but the navbar Login/Logout button depends on Firebase client-side state. Fix: logout test performs a fresh login first instead of relying on saved state.
3. **Ambiguous locators on dashboard page** — Sidebar links for "Artists", "Albums", "Songs" conflicted with identically-named links in the dashboard's Rankings card. Fix: added `data-testid="admin-sidebar"` to `<aside>` and scoped sidebar locators to it.
4. **Icon-only back buttons** — Show page back buttons are SVG arrows with no text, making `getByRole('link', { name: /back/ })` impossible. Fix: added `data-testid="back-button"` to the three show pages.
5. **Modal close button ambiguity** — `getByRole('button', { name: 'Close' })` matched both the visible "Close" button and the backdrop's "close" button (case-insensitive). Fix: scoped to `.modal-box` container.

### Deviations From Plan
- **Logout test uses fresh login** instead of saved storageState, due to the IndexedDB limitation described above. The spec assumed storageState would fully restore auth state, but Firebase's persistence mechanism prevents this.
- **Added `data-testid` attributes to 4 existing views** — not in the original spec, but necessary for reliable E2E selectors. Added sparingly, only where accessible locators were insufficient.
- **Added `e2e/.env.example`** — not in the original spec, but useful for onboarding.

## Acceptance Results
- **Date**: 2026-02-09
- **Verifier**: Developer + AI Agent
- **Result**: 50/50 tests passing in 46.2s against local dev
- **Command**: `yarn test:e2e` from `web-app/`
- **Coverage**: Auth setup (1), login flow (3), logout flow (1), public pages (15), admin pages (30)

## Future Improvements
- Add CI/CD integration (GitHub Actions with Playwright browser caching)
- Expand to Movies, Games, Books domains
- Add mobile viewport testing (responsive)
- Add visual regression testing with `toHaveScreenshot()`
- Test CRUD mutations (create/edit/delete) in admin with database cleanup strategy
- Add cross-browser projects (Firefox, WebKit)
- Implement test data seeding via Rails API endpoint or rake task for isolated test data

## Related PRs
- (pending)

## Documentation Updated
- [x] `docs/features/e2e-testing.md` — new feature doc covering full E2E setup, running, and writing tests
- [x] `docs/testing.md` — added E2E testing section, `data-testid` guidance, comparison table
- [x] `docs/dev-core-values.md` — added section 8.5 on E2E testability requirements
