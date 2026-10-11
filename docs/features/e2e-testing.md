# E2E Testing Suite (Playwright)

## Overview
End-to-end testing suite for The Greatest using Playwright with TypeScript. Tests run against local dev instances with real Firebase email/password authentication. The suite covers music, games and books (512 tests as of 2026-10-11); music was the first domain, February 2026.

## Technology Stack
- **Test runner**: `@playwright/test` (Node.js, TypeScript)
- **Browser**: Chromium (default), Firefox and WebKit configurable
- **Auth**: Real Firebase email/password login via three dedicated test accounts (admin, normal user, member)
- **Target**: Local dev instances (not a test-mode Rails server)
- **Package manager**: Yarn

## Architecture

### How It Works
Tests run against the live local development server through its three dev hosts (`dev.thegreatestmusic.org`, `dev.thegreatest.games`, `dev-new.thegreatestbooks.org`). There is no test-mode Rails server — the developer starts their normal dev server and runs tests against it.

Authentication uses three real Firebase email/password accounts: an **admin** (global admin on every
domain), a **normal user** (signed in, never admin, never a member) and a **member** (a plain user with
a comped membership). Five setup projects sign them in through the real login modal and save storage
state; a `seed` project then runs `bin/rails e2e:prepare`, which rebuilds everything database-side
from those rows (roles, membership, seeded reviews and lists, Stripe sandbox plans, the rate limiter)
and writes `e2e/.auth/seed.json`. Every test project depends on `seed`, so a production-dump refresh
needs **no manual E2E steps**: the next run recreates the accounts' rows and state itself.

`prepare` also empties every Books list the normal user owns, seeds the normal user's 30 reviews (every
third a quarter under its star), removes all three accounts' own reviews from the scratch book
`headlong-hall` (its preflight fails, naming the reviewer, if anyone else has a review there), and
clears the corrections spec's marker subtitle from `headlong-hall` (only when the subtitle equals the
marker).

### Key Design Decisions
- **Single worker, sequential execution** — tests run against a shared live database; parallelism would cause data conflicts
- **StorageState reuse** — five sign-in setup projects (plus the `seed` project) run once; every test project reuses its saved session
- **Tests clean up after themselves** — specs create and remove their own rows on the three e2e accounts; `e2e:prepare` resets the rest on every run
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
    .env                          # PLAYWRIGHT_{ADMIN,USER,MEMBER}_{EMAIL,PASSWORD} (gitignored)
    auth/
      auth.setup.ts               # Admin sign-in (music): save storage state
      games-auth.setup.ts
      books-auth.setup.ts
      books-user-auth.setup.ts
      books-member-auth.setup.ts
      seed.setup.ts               # Runs bin/rails e2e:prepare, writes .auth/seed.json
    support/
      sign-in.ts                  # Shared login-modal sign-in helper
      seed.ts                     # Reads ids from .auth/seed.json
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
      user.json                   # admin, music
      games-user.json             # admin, games
      books-user.json             # admin, books
      books-normal-user.json      # normal user, books
      books-member.json           # member, books
      seed.json
```

## Test Coverage
512 tests across music, games and books as of 2026-10-11; `yarn test:e2e --list` is the current inventory.

## Prerequisites

### 1. Local Dev Server
The Rails dev server must be running and reachable at all three dev hosts (`dev.thegreatestmusic.org`, `dev.thegreatest.games`, `dev-new.thegreatestbooks.org`).

### 2. The three Firebase accounts (one-time)

Create three email/password users in the Firebase console (Authentication → Users → Add user). The
suite never signs up: a signup creates a real account in the shared production Firebase project.

| Account | Role on every run | Membership | Drives |
|---------|-------------------|------------|--------|
| admin   | global `admin`    | none, enforced | music, games, `books-admin` |
| user    | `user`            | none, enforced | `books-account` |
| member  | `user`            | comped, active | `books-member` |

Nothing else to do by hand. The first run's sign-ins create the `User` rows and `e2e:prepare` sets
every cell of that table, cancelling any membership the admin or user holds and comping the member.
`prepare` refuses an email that resolves to an account with a Stripe membership (a real customer),
refuses duplicate emails, and lists any famous slug the specs assume that the catalog no longer has.

### 3. Environment file

`web-app/e2e/.env` (gitignored; copy `e2e/.env.example`):

```env
PLAYWRIGHT_ADMIN_EMAIL=...
PLAYWRIGHT_ADMIN_PASSWORD="..."
PLAYWRIGHT_USER_EMAIL=...
PLAYWRIGHT_USER_PASSWORD="..."
PLAYWRIGHT_MEMBER_EMAIL=...
PLAYWRIGHT_MEMBER_PASSWORD="..."
```

Quote a password containing `#`. There are no ids in this file any more: specs read seeded ids from
`e2e/.auth/seed.json` through `e2e/support/seed.ts`, inside a test or `beforeAll`.

### Per-spec seeds

Some admin specs seed their own rows through rake tasks and clean up after themselves
(`e2e:import_finder_seed`/`_cleanup`, `e2e:reject_link_seed`/`_state`/`_cleanup`,
`e2e:provisional_seed`/`_cleanup`, `e2e:goodreads_import_seed`/`_cleanup`,
`e2e:repair_verdicts_seed`/`_cleanup`, `e2e:list_wizard_cleanup`). All are idempotent. The contact
spec runs `e2e:rate_limit_reset` first, because the contact form allows five anonymous sends per IP
per hour.

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

`yarn test:e2e` installs Chromium for the pinned Playwright version first (a no-op when present), so a
Playwright upgrade cannot kill the suite before its first page.

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

### The seed project fails
Read its output: `e2e:prepare` prints one line per step and aborts with the refusing step's message
(no User for an email → that sign-in failed; a Stripe membership → wrong email in `.env`; catalog
preflight → a slug the specs assume has changed). Fix the cause; there is no manual rake step to run.

### Stale auth state
- The setups sign in on every run anyway; deleting `e2e/.auth/*.json` (all of them) only forces a clean slate before the next run

### Connection refused
- Ensure the Rails dev server is running and all three dev hosts (`dev.thegreatestmusic.org`, `dev.thegreatest.games`, `dev-new.thegreatestbooks.org`) resolve to it
- `ignoreHTTPSErrors: true` is set in config for self-signed certificates

### Tests pass locally but navbar shows "Login" on auth tests
- This is expected. StorageState doesn't capture Firebase IndexedDB. The Rails session cookie handles admin page access. Auth-specific tests (login/logout) perform fresh Firebase logins.

## Future Improvements
- CI: a staging stack (Rails, Sidekiq, Redis, OpenSearch, Caddy, restored database) with a self-hosted
  runner. Out of scope on 2026-10-10; this suite needs no changes to run there.
- Cross-browser projects (Firefox, WebKit)

## Related Files
- `web-app/package.json` — devDependencies and test scripts
- `web-app/.gitignore` — Playwright artifact exclusions
- `web-app/e2e/playwright.config.ts` — Playwright configuration
- `app/views/admin/shared/_sidebar.html.erb` — `data-testid="admin-sidebar"`
- `app/views/admin/music/artists/show.html.erb` — `data-testid="back-button"`
- `app/views/admin/music/albums/show.html.erb` — `data-testid="back-button"`
- `app/views/admin/music/songs/show.html.erb` — `data-testid="back-button"`
- [Playwright E2E Spec](../specs/playwright-e2e-testing-suite.md) — Original implementation spec
