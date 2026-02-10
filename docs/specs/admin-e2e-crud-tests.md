# Admin E2E CRUD Tests

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2026-02-10
- **Started**:
- **Completed**:
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
- Related: `docs/specs/games-admin-interface.md` (parent spec, in progress)
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
| All links | Test each: Games, Companies, Platforms, Series, Categories | Each navigates correctly |

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
- Dev database has seed data for browsing (companies, platforms, series, categories)

**Postconditions:**
- Created records appear in index tables
- Updated records reflect new values on show pages
- Deleted records no longer appear in index tables (categories soft-deleted)
- No test data cleanup needed (dev database is shared, tests create unique-named records)

**Edge cases:**
- Use unique names with timestamps to avoid collisions: `"E2E Test Company ${Date.now()}"`
- Delete confirmation dialog must be accepted (Playwright `page.on('dialog')` or Turbo's `data-turbo-confirm`)
- Turbo Drive may cause stale page state — use `waitForURL` or `waitForLoadState` after form submissions

### Non-Functionals
- Tests run sequentially (1 worker) against `https://dev.thegreatest.games`
- Each test should complete in < 10 seconds
- No flaky selectors — use roles, labels, placeholders, and `data-testid` attributes

## Implementation Todos

### 1. Extend Page Objects with CRUD Methods
- [ ] Add `clickNewButton()`, `fillForm(data)`, `submitForm()`, `clickEdit()`, `clickDelete()` to each page object
- [ ] Add form field locators (inputs, selects, textareas, submit button)
- [ ] Add flash message / success assertion helpers

### 2. Companies CRUD Tests
- [ ] `e2e/tests/games/admin/companies-crud.spec.ts` — add create, create-validation, edit, delete tests

### 3. Platforms CRUD Tests
- [ ] `e2e/tests/games/admin/platforms-crud.spec.ts` — add create, edit, delete tests

### 4. Series CRUD Tests
- [ ] `e2e/tests/games/admin/series-crud.spec.ts` — add create, edit, delete tests

### 5. Categories CRUD Tests
- [ ] `e2e/tests/games/admin/categories-crud.spec.ts` — new file, full CRUD + read tests

### 6. Sidebar Navigation Tests
- [ ] `e2e/tests/games/admin/sidebar-nav.spec.ts` — new file, test all sidebar links

## Acceptance Criteria

- [ ] Companies: create, edit, delete flows pass E2E
- [ ] Platforms: create, edit, delete flows pass E2E
- [ ] Series: create, edit, delete flows pass E2E
- [ ] Categories: full CRUD (list, show, create, edit, delete) passes E2E
- [ ] Sidebar navigation tests pass for all games admin links
- [ ] All existing games admin E2E tests still pass
- [ ] All existing music admin E2E tests still pass
- [ ] No flaky tests (stable locators, proper waits)

### Golden Examples

**Create flow (companies):**
```text
1. companiesPage.goto()                          → /admin/companies
2. page.getByRole('link', { name: 'New Company' }).click()  → /admin/companies/new
3. page.getByLabel('Name').fill('E2E Test Co 1707500000')
4. page.getByLabel('Country').fill('US')
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
- Existing dev database seed data sufficient for read/navigate tests

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `e2e/pages/games/admin/companies-page.ts`
- `e2e/pages/games/admin/platforms-page.ts`
- `e2e/pages/games/admin/series-page.ts`
- `e2e/tests/games/admin/companies-crud.spec.ts`
- `e2e/tests/games/admin/platforms-crud.spec.ts`
- `e2e/tests/games/admin/series-crud.spec.ts`
- `e2e/tests/games/admin/categories-crud.spec.ts`
- `e2e/tests/games/admin/sidebar-nav.spec.ts`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Add Games entity CRUD E2E tests once OpenSearch autocomplete is mockable
- Add music admin CRUD E2E tests following same pattern
- Add join table (GameCompanies, GamePlatforms) E2E tests
- Add image upload E2E tests
- Add search interaction E2E tests (typing in search, verifying filtered results)

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
