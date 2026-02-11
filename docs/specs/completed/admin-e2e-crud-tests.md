# Admin E2E CRUD Tests

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-10
- **Started**: 2026-02-10
- **Completed**: 2026-02-10
- **Developer**: Claude

## Overview
Add full CRUD E2E test coverage to the games admin interface. Current E2E tests only verify pages load (Read); this spec adds Create, Update, and Delete test flows for all games admin entities. Also adds sidebar navigation tests for the games domain.

**Scope**: Games admin E2E tests only (Companies, Platforms, Series, Categories). Games entity excluded from create/edit E2E tests because its form depends on OpenSearch-backed autocomplete components (parent_game, series) that may not be available in all dev environments.

**Non-goals**:
- Music admin CRUD tests (existing read-only tests are sufficient for now)
- Testing autocomplete/search interactions (requires OpenSearch running)
- Testing image upload or category_items (complex modal flows — separate spec)
- Testing join table management (GameCompanies, GamePlatforms)

## Context & Links
- Related: `docs/specs/completed/games-admin-interface.md` (parent spec, completed)
- Existing E2E patterns: `web-app/e2e/tests/music/admin/` (read-only reference)
- Page objects: `web-app/e2e/pages/games/admin/`
- Fixtures: `web-app/e2e/fixtures/games-auth.ts`
- Config: `web-app/e2e/playwright.config.ts`
- E2E guide: `docs/testing.md`, `docs/features/e2e-testing.md`

## Interfaces & Contracts

### Test Flows Per Entity

#### Companies (simplest — no autocomplete dependencies)
| Flow | Steps | Assertions |
|---|---|---|
| Create | Index → New → fill name, country, year_founded, description → Submit | Redirected to show page, name displayed |
| Create validation | New → Submit empty form | Error messages visible, stays on form |
| Edit | Show → Edit → change name → Submit | Redirected to show page, updated name displayed |
| Delete | Show → Delete → Confirm dialog | Redirected to index, company no longer in table |

#### Platforms
| Flow | Steps | Assertions |
|---|---|---|
| Create | Index → New → fill name, abbreviation, platform_family → Submit | Redirected to show page, name displayed |
| Edit | Show → Edit → change name → Submit | Redirected to show page, updated name displayed |
| Delete | Show → Delete → Confirm dialog | Redirected to index, platform no longer in table |

#### Series
| Flow | Steps | Assertions |
|---|---|---|
| Create | Index → New → fill name, description → Submit | Redirected to show page, name displayed |
| Edit | Show → Edit → change name → Submit | Redirected to show page, updated name displayed |
| Delete | Show → Delete → Confirm dialog | Redirected to index, series no longer in table |

#### Categories
| Flow | Steps | Assertions |
|---|---|---|
| Create | Index → New → fill name, category_type → Submit | Redirected to show page, name displayed |
| Edit | Show → Edit → change name → Submit | Redirected to show page, updated name displayed |
| Delete (soft) | Show → Delete → Confirm dialog | Redirected to index, category no longer visible |

#### Sidebar Navigation (Games Domain)
| Flow | Steps | Assertions |
|---|---|---|
| Nav link | Dashboard → click sidebar link | URL matches, heading visible |
| All links | Test each: Games, Companies, Platforms, Series, Categories, Penalties, Users | Each navigates correctly |

### Form Fields Reference

```text
Companies:  name* (text), country (text, 2 chars), year_founded (number), description (textarea)
Platforms:  name* (text), abbreviation (text), platform_family* (select)
Series:     name* (text), description (textarea)
Categories: name* (text), category_type* (select), parent_id (select), description (textarea)
(* = required)
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Authenticated as admin via games-auth.setup.ts (storage state reuse)
- Dev database may be empty — tests must not depend on pre-existing seed data

**Postconditions:**
- Created records appear in index tables
- Updated records reflect new values on show pages
- Deleted records no longer appear in index tables (categories soft-deleted)
- No test data cleanup needed (dev database is shared, tests create unique-named records)

**Edge cases:**
- Use unique names with timestamps to avoid collisions: `"E2E Test Company ${Date.now()}"`
- Delete confirmation dialog must be accepted (Playwright `page.on('dialog')` or Turbo's `data-turbo-confirm`)
- Turbo Drive may cause stale page state — use `waitForURL` or `waitForLoadState` after form submissions
- Empty database renders empty state (no `<table>`) with a duplicate "New X" link — use `.first()` on "New X" locators

### Non-Functionals
- Tests run sequentially (1 worker) against `https://dev.thegreatest.games`
- Each test should complete in < 10 seconds
- No flaky selectors — use roles, labels, placeholders, and `data-testid` attributes

## Implementation Todos

### 1. Extend Page Objects with CRUD Methods ✅
- [x] Created `CategoriesPage` page object with index/table/search locators
- [x] Updated `games-auth.ts` fixtures to include `CategoriesPage`
- [x] CRUD form interactions handled inline in test specs using Playwright role/label locators (no need for page object methods — follows spec golden examples pattern)

### 2. Companies CRUD Tests ✅
- [x] `e2e/tests/games/admin/companies-crud.spec.ts` — create, create-validation, edit, delete tests (7 tests total)

### 3. Platforms CRUD Tests ✅
- [x] `e2e/tests/games/admin/platforms-crud.spec.ts` — create, edit, delete tests (6 tests total)

### 4. Series CRUD Tests ✅
- [x] `e2e/tests/games/admin/series-crud.spec.ts` — create, edit, delete tests (6 tests total)

### 5. Categories CRUD Tests ✅
- [x] `e2e/tests/games/admin/categories-crud.spec.ts` — new file, full CRUD + read tests (6 tests total)

### 6. Sidebar Navigation Tests ✅
- [x] `e2e/tests/games/admin/sidebar-nav.spec.ts` — new file, tests all 7 sidebar links (Games, Companies, Platforms, Series, Categories, Penalties, Users)

### 7. Bug Fixes (discovered during testing) ✅
- [x] Fixed `dashboard-page.ts` — quick link card locators didn't match actual rendered text
- [x] Fixed `playwright.config.ts` — music `setup` project was missing `baseURL`
- [x] Fixed `games-crud.spec.ts` — removed tests that assumed pre-existing seed data
- [x] All existing read-only tests reworked to not depend on seed data

## Acceptance Criteria

- [x] Companies: create, edit, delete flows pass E2E
- [x] Platforms: create, edit, delete flows pass E2E
- [x] Series: create, edit, delete flows pass E2E
- [x] Categories: full CRUD (list, show, create, edit, delete) passes E2E
- [x] Sidebar navigation tests pass for all games admin links
- [x] All existing games admin E2E tests still pass
- [x] All existing music admin E2E tests still pass
- [x] No flaky tests (stable locators, proper waits)

### Golden Examples

**Create flow (companies):**
```text
1. companiesPage.goto()                          → /admin/companies
2. page.getByRole('link', { name: 'New Company' }).first().click()  → /admin/companies/new
3. page.getByLabel(/Name/).fill('E2E Test Co 1707500000')
4. page.getByLabel(/Country/).fill('US')
5. page.getByRole('button', { name: 'Create Company' }).click()
6. expect(page).toHaveURL(/\/admin\/companies\/e2e-test-co/)
7. expect(page.getByRole('heading', { name: /E2E Test Co/ })).toBeVisible()
```

**Delete flow (Turbo confirm):**
```text
1. Navigate to show page
2. page.on('dialog', dialog => dialog.accept())   // handle turbo_confirm
3. page.getByRole('button', { name: 'Delete' }).click()
4. expect(page).toHaveURL(/\/admin\/companies$/)
```

---

## Agent Hand-Off

### Constraints
- Follow existing E2E patterns in `web-app/e2e/tests/music/admin/`
- Use page object model pattern from `web-app/e2e/pages/games/admin/`
- Import from `web-app/e2e/fixtures/games-auth.ts` (not `@playwright/test`)
- Use unique names with timestamps to avoid test data collisions
- Respect snippet budget (≤40 lines per snippet)

### Required Outputs
- Updated page objects in `web-app/e2e/pages/games/admin/`
- New/updated test specs in `web-app/e2e/tests/games/admin/`
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → collect existing E2E CRUD patterns if any exist elsewhere
2) codebase-analyzer → verify form field selectors match actual view markup

### Test Seed / Fixtures
- No new fixtures needed — tests create their own records with unique names
- Tests are resilient to empty databases (no seed data dependency)

---

## Implementation Notes (living)
- Approach taken: CRUD tests create their own records with `Date.now()` timestamps for uniqueness, then test edit/delete on those newly created records. Tests are fully self-contained and do not depend on pre-existing seed data.
- Important decisions:
  - Did NOT add CRUD helper methods to page objects. Inline Playwright locators (`page.getByLabel`, `page.getByRole`) are simpler and more readable for one-time form fills.
  - Each CUD test creates its own record first to ensure test isolation.
  - Delete tests register `page.on('dialog')` handler before clicking Delete to handle `data-turbo-confirm` dialogs.
  - Platform/Category create tests use `selectOption({ index: 1 })` for enum selects to pick the first non-blank option.
  - Validation test only on Companies (simplest entity) — other entities follow same Rails form pattern.
  - Used `.first()` on "New X" link locators because empty state renders a duplicate CTA button.
  - Removed table/row existence assertions from read-only tests since dev database may be empty.

### Key Files Touched (paths only)
- `e2e/pages/games/admin/categories-page.ts` (NEW)
- `e2e/pages/games/admin/dashboard-page.ts` (UPDATED — fixed quick link card locators)
- `e2e/fixtures/games-auth.ts` (UPDATED — added CategoriesPage)
- `e2e/playwright.config.ts` (UPDATED — added baseURL to music setup project)
- `e2e/tests/games/admin/companies-crud.spec.ts` (UPDATED — added CRUD tests, fixed for empty DB)
- `e2e/tests/games/admin/platforms-crud.spec.ts` (UPDATED — added CRUD tests, fixed for empty DB)
- `e2e/tests/games/admin/series-crud.spec.ts` (UPDATED — added CRUD tests, fixed for empty DB)
- `e2e/tests/games/admin/games-crud.spec.ts` (UPDATED — fixed for empty DB)
- `e2e/tests/games/admin/categories-crud.spec.ts` (NEW — 6 tests)
- `e2e/tests/games/admin/sidebar-nav.spec.ts` (NEW — 7 tests)

### Challenges & Resolutions
- **Empty dev database**: All index pages rendered empty state (no `<table>`) with duplicate "New X" links causing strict mode violations. Fixed by using `.first()` on "New X" locators and removing assertions that assumed pre-existing data.
- **Dashboard locator mismatch**: Quick link card text in `dashboard-page.ts` didn't match actual rendered text ("Manage video games" vs "Manage game catalog"). Fixed locators to match actual view content.
- **Music auth setup missing baseURL**: The `setup` project in `playwright.config.ts` had no `baseURL`, causing `page.goto('/')` to fail with "Cannot navigate to invalid URL". Fixed by adding `baseURL: 'https://dev.thegreatestmusic.org'`.
- **Form labels with asterisks**: Labels render `Name *` with a nested `<span>` for the asterisk. Solved with regex `getByLabel(/Name/)`.
- **Series singular/plural conflict**: Rails uses `admin_games_series_index_path` for index. URL regex `/admin/series$/` handles the distinction.

### Deviations From Plan
- Did not add `clickNewButton()`, `fillForm(data)`, `submitForm()`, `clickEdit()`, `clickDelete()` methods to existing page objects. Instead, CRUD interactions use inline Playwright locators directly in tests.
- Removed table visibility and row count assertions from read-only tests (index page loads, New button visible) since dev database may be empty.
- Added bug fixes to pre-existing tests and config that were also broken (dashboard locators, music auth baseURL, games-crud empty state).

## Acceptance Results
- **Date**: 2026-02-10
- **Verifier**: Full `yarn test:e2e` suite
- **Results**: 90 passed (50 music + 40 games), 0 failures, 62.7s total runtime

## Future Improvements
- Add Games entity CRUD E2E tests once OpenSearch autocomplete is mockable
- Add music admin CRUD E2E tests following same pattern
- Add join table (GameCompanies, GamePlatforms) E2E tests
- Add image upload E2E tests
- Add search interaction E2E tests (typing in search, verifying filtered results)

## Related PRs
-

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
