# E2E Testing Suite (Playwright)

## Overview
End-to-end testing suite for The Greatest using Playwright with TypeScript. Tests run against local dev instances with real Firebase email/password authentication. The initial scope covers the **Music domain** — public pages, auth flows, and admin pages. Implemented February 2026.

## Technology Stack
- **Test runner**: `@playwright/test` (Node.js, TypeScript)
- **Browser**: Chromium (default), Firefox and WebKit configurable
- **Auth**: Real Firebase email/password login via dedicated test account
- **Target**: Local dev instances (not a test-mode Rails server)
- **Package manager**: Yarn

## Architecture

### How It Works
Tests run against the live local development server at `https://dev.thegreatestmusic.org`. There is no test-mode Rails server — the developer starts their normal dev server and runs tests against it.

Authentication uses a real Firebase email/password account. The auth setup project logs in once via the browser, saves the session cookies to disk, and all subsequent tests reuse that saved session. Admin tests access pages via the Rails session cookie; public tests don't need auth at all.

### Key Design Decisions
- **Single worker, sequential execution** — tests run against a shared live database; parallelism would cause data conflicts
- **StorageState reuse** — login once in `auth.setup.ts`, all subsequent tests reuse the session via saved cookies
- **Read-only tests** — no CRUD mutations; tests only browse and verify page content
- **Page Object Model** — reusable page classes encapsulate locators and actions
- **No CI integration** — local-only for now; CI is a future improvement

### Firebase Auth + StorageState Limitation
Playwright's `storageState` captures cookies and localStorage but **not IndexedDB**, which is where Firebase Auth v9+ persists its client-side auth state. This means:
- **Admin page tests work** — they rely on the Rails session cookie, which IS captured
- **Navbar Login/Logout button** — will show "Login" even with saved storageState, because the Firebase SDK doesn't find its IndexedDB state
- **Logout test** — performs a fresh login before testing logout, rather than relying on saved state

## Directory Structure
```
web-app/
  e2e/
    playwright.config.ts          # Playwright configuration
    tsconfig.json                 # TypeScript config for e2e tests
    .env                          # PLAYWRIGHT_ADMIN_EMAIL, PLAYWRIGHT_ADMIN_PASSWORD (gitignored)
    auth/
      auth.setup.ts               # Global auth setup: login + save storage state
    fixtures/
      auth.ts                     # Custom test fixture extending base with page objects
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
        public/                   # Public page tests (no auth needed)
          homepage.spec.ts
          navigation.spec.ts
          albums-browse.spec.ts
          songs-browse.spec.ts
        auth/                     # Auth flow tests (fresh login per test)
          login.spec.ts
          logout.spec.ts
        admin/                    # Admin page tests (use saved session)
          dashboard.spec.ts
          artists-crud.spec.ts
          albums-crud.spec.ts
          songs-crud.spec.ts
          sidebar-nav.spec.ts
    .auth/                        # Generated auth state (gitignored)
      user.json
```

## Test Coverage (50 tests)

### Auth (4 tests)
- Full Firebase email/password login flow
- Auth modal UI (steps, buttons, Google sign-in option)
- Modal close behavior
- Logout flow (login then logout)

### Public Music Pages (15 tests)
- Homepage: hero section, branding, featured albums grid, featured songs table
- Navigation: navbar dropdowns (Albums, Songs), Artists link, Lists link, hero CTAs
- Album browsing: all-time rankings, decade pages
- Song browsing: all-time rankings, decade pages

### Admin Pages (31 tests)
- Dashboard: welcome heading, 4 stat cards with numeric counts, quick link cards, recent artists
- Artists: index page, table, search, New Artist button, show page navigation
- Albums: index page, table, search, New Album button, show page navigation
- Songs: index page, table, search, New Song button, show page navigation
- Sidebar navigation: all 11 sidebar links navigate to correct URLs

## Prerequisites

### 1. Local Dev Server
The Rails dev server must be running and accessible at `https://dev.thegreatestmusic.org`.

### 2. Firebase Test Account
Create a dedicated test account:
1. In Firebase Console, create an email/password user
2. In the local Rails database, create a `User` record for that email with admin `DomainRole` for the music domain
3. Verify you can manually log in at `https://dev.thegreatestmusic.org` with these credentials

### 3. Environment File
Create `web-app/e2e/.env` (gitignored):
```env
PLAYWRIGHT_ADMIN_EMAIL=your-test-account@example.com
PLAYWRIGHT_ADMIN_PASSWORD="your-password-here"
```
**Important**: Quote the password value if it contains `#` or other special characters — dotenv treats unquoted `#` as an inline comment delimiter.

### 4. Install Dependencies
```bash
cd web-app
yarn install
npx playwright install chromium
```

## Running Tests

```bash
cd web-app

# Run the full suite (headless)
yarn test:e2e

# Run with visible browser
yarn test:e2e:headed

# Open Playwright UI mode (interactive test runner)
yarn test:e2e:ui

# Debug mode with inspector
yarn test:e2e:debug

# Run a specific test file
npx playwright test --config=e2e/playwright.config.ts tests/music/public/homepage.spec.ts

# Run tests matching a grep pattern
npx playwright test --config=e2e/playwright.config.ts -g "Admin Dashboard"

# Generate test code interactively
yarn test:e2e:codegen
```

## Page Object Model Pattern

Each POM class encapsulates page-specific locators and actions:

```typescript
// e2e/pages/music/admin/dashboard-page.ts
export class DashboardPage {
  readonly page: Page;
  readonly heading: Locator;

  constructor(page: Page) {
    this.page = page;
    this.heading = page.getByRole('heading', { name: 'Welcome to Music Admin' });
  }

  async goto() {
    await this.page.goto('/admin');
  }
}
```

**Locator strategy** (in priority order):
1. `page.getByRole()` — accessible roles (buttons, links, headings)
2. `page.getByText()` — visible text content
3. `page.getByTestId()` — `data-testid` attributes (used for sidebar, back buttons)
4. `page.getByPlaceholder()` / `page.getByLabel()` — form inputs
5. `page.locator()` — CSS selectors (last resort)

### Data Test IDs in Views
The following `data-testid` attributes were added to support E2E tests:
- `data-testid="admin-sidebar"` — on `<aside>` in `app/views/admin/shared/_sidebar.html.erb`
- `data-testid="back-button"` — on back arrow links in artist/album/song show pages

## Custom Test Fixture

Tests import from `fixtures/auth.ts` instead of `@playwright/test` directly. This provides pre-constructed page objects:

```typescript
import { test, expect } from '../../../fixtures/auth';

test('displays dashboard', async ({ dashboardPage }) => {
  await dashboardPage.goto();
  await expect(dashboardPage.heading).toBeVisible();
});
```

Available fixtures: `homePage`, `loginPage`, `dashboardPage`, `artistsPage`, `albumsPage`, `songsPage`.

## Troubleshooting

### "Invalid email or password" in auth setup
- Check that the Firebase account exists and credentials match `e2e/.env`
- If the password contains `#`, ensure it's quoted: `PLAYWRIGHT_ADMIN_PASSWORD="pass#word"`

### Auth setup passes but admin tests fail
- Verify the User record in your local database has an admin DomainRole for the music domain
- Check that the Rails session cookie domain matches `dev.thegreatestmusic.org`

### Stale auth state
- Delete `e2e/.auth/user.json` and re-run — the setup will re-authenticate

### Connection refused
- Ensure the Rails dev server is running at `https://dev.thegreatestmusic.org`
- `ignoreHTTPSErrors: true` is set in config for self-signed certificates

### Tests pass locally but navbar shows "Login" on auth tests
- This is expected. StorageState doesn't capture Firebase IndexedDB. The Rails session cookie handles admin page access. Auth-specific tests (login/logout) perform fresh Firebase logins.

## Future Improvements
- CI/CD integration (GitHub Actions with Playwright browser caching)
- Expand to Movies, Games, Books domains
- Mobile viewport testing (responsive)
- Visual regression testing with `toHaveScreenshot()`
- CRUD mutation tests with database cleanup strategy
- Cross-browser projects (Firefox, WebKit)
- Test data seeding via Rails API endpoint or rake task

## Related Files
- `web-app/package.json` — devDependencies and test scripts
- `web-app/.gitignore` — Playwright artifact exclusions
- `web-app/e2e/playwright.config.ts` — Playwright configuration
- `app/views/admin/shared/_sidebar.html.erb` — `data-testid="admin-sidebar"`
- `app/views/admin/music/artists/show.html.erb` — `data-testid="back-button"`
- `app/views/admin/music/albums/show.html.erb` — `data-testid="back-button"`
- `app/views/admin/music/songs/show.html.erb` — `data-testid="back-button"`
- [Playwright E2E Spec](../specs/playwright-e2e-testing-suite.md) — Original implementation spec
