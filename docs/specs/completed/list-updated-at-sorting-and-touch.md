# Add updated_at Column & Sorting to Admin List Index Pages + Touch on ListItem Changes

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-03-04
- **Started**: 2026-03-04
- **Completed**: 2026-03-04
- **Developer**: Claude

## Overview
Add an `updated_at` column to the admin list index pages (games, albums, songs) with sortable asc/desc toggle. Additionally, automatically touch the parent `List#updated_at` whenever a `ListItem` is created, updated, or destroyed. This allows admins to see which lists were most recently worked on.

**Non-goals**: No changes to public-facing pages. No changes to the list show/edit/new pages.

## Context & Links
- Source files (authoritative):
  - `app/controllers/admin/lists_base_controller.rb` — shared index/sorting logic
  - `app/components/admin/lists/table_component.rb` — shared table ViewComponent
  - `app/components/admin/lists/table_component.html.erb` — shared table template
  - `app/models/list_item.rb` — ListItem model (needs `touch: true`)
  - `app/models/list.rb` — List model (parent)
  - `app/controllers/admin/list_items_controller.rb` — CRUD for list items
  - `app/controllers/concerns/list_items_actions.rb` — wizard list item actions

## Interfaces & Contracts

### Domain Model (diffs only)
- **No migration needed** — `lists.updated_at` already exists.
- **ListItem model change**: Add `touch: true` to `belongs_to :list`.

### Endpoints
No new endpoints. Existing list index endpoints gain a new sort option:

| Verb | Path | Change | Params |
|---|---|---|---|
| GET | `/admin/games/lists` | Accept `sort=updated_at` | `sort`, `direction`, `status`, `q` |
| GET | `/admin/albums/lists` | Accept `sort=updated_at` | `sort`, `direction`, `status`, `q` |
| GET | `/admin/songs/lists` | Accept `sort=updated_at` | `sort`, `direction`, `status`, `q` |

### Behaviors (pre/postconditions)

**Sorting**:
- Precondition: `sort=updated_at` with `direction=asc|desc` passed as query params.
- Postcondition: Lists are ordered by `lists.updated_at` in the requested direction.
- Default sort remains `lists.name ASC` when no sort param is provided.
- The `updated_at` column header toggles direction on click, matching the existing pattern for other sortable columns (ID, Name, Year, Created).

**Touch on ListItem changes**:
- Precondition: A `ListItem` is created, updated, or destroyed.
- Postcondition: The parent `List#updated_at` is set to the current timestamp.
- This applies to ALL paths that modify list items:
  - `Admin::ListItemsController` (create, update, destroy, destroy_all)
  - `ListItemsActions` concern (verify, destroy, metadata, bulk_verify, bulk_skip, bulk_delete)
  - Domain-specific controllers (link, skip, re_enrich, queue_import actions)
- Edge case: `bulk_delete` uses `destroy_all` which triggers callbacks, so `touch: true` covers it.
- Edge case: `bulk_verify` uses `update_all` which does NOT trigger callbacks. This is acceptable — `update_all` bypasses AR callbacks by design and the touch from individual `update!` calls in the same action will cover it.

### Non-Functionals
- No new queries — `updated_at` is already loaded with the list record.
- Sort uses the existing `ORDER BY` pattern with qualified column name `lists.updated_at`.
- No N+1 concerns — column data comes from the already-loaded list record.

## Acceptance Criteria
- [x] `updated_at` column visible on admin list index for games, albums, and songs
- [x] `updated_at` column is sortable with asc/desc toggle (arrow indicators match existing columns)
- [x] Sort direction persists through pagination
- [x] Creating a list item updates the parent list's `updated_at`
- [x] Updating a list item updates the parent list's `updated_at`
- [x] Destroying a list item updates the parent list's `updated_at`
- [x] Date format matches the existing `Created` column format (`"Mon DD, YYYY"`)
- [x] Existing sort columns continue to work as before
- [x] E2E smoke tests for `updated_at` sorting pass for all 3 list types (games, albums, songs)

### Golden Examples

**Sort toggle behavior:**
```text
Input: Click "Updated" column header (no current sort on updated_at)
Output: Lists sorted by updated_at ASC, down arrow shown

Input: Click "Updated" column header again (currently sorted updated_at ASC)
Output: Lists sorted by updated_at DESC, up arrow shown
```

**Touch behavior:**
```text
Input: ListItem created for List id=5
Output: List id=5 updated_at changes to current time

Input: ListItem destroyed from List id=5
Output: List id=5 updated_at changes to current time
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → confirm sort toggle pattern in TableComponent (already explored)
2) codebase-analyzer → verify all ListItem mutation paths are covered by `touch: true`

### Implementation Steps

**Step 1: Add `touch: true` to ListItem**
- File: `app/models/list_item.rb`
- Change: `belongs_to :list` → `belongs_to :list, touch: true`

**Step 2: Add `updated_at` to sortable columns**
- File: `app/controllers/admin/lists_base_controller.rb`
- Change: Add `"updated_at" => "lists.updated_at"` to the `allowed_columns` hash in `sortable_column`

**Step 3: Add `updated_at` column to TableComponent template**
- File: `app/components/admin/lists/table_component.html.erb`
- Change: Add a new `<th>` with sort link for `updated_at` (between Created and Actions columns), and a corresponding `<td>` in the body row using `time_tag list.updated_at, list.updated_at.strftime("%b %d, %Y")`
- Follow the exact same pattern as the existing `created_at` column sort header

**Step 4: Write tests**
- File: `test/models/list_item_test.rb` — test that creating/updating/destroying a list item touches the parent list's `updated_at`
- E2E smoke tests for `updated_at` sorting across all 3 list types, matching each file's existing style:
  - File: `test/controllers/admin/games/lists_controller_test.rb` — add `test "should sort by updated_at"` (per-test `sign_in_as`, `assert_response :success`)
  - File: `test/controllers/admin/music/albums/lists_controller_test.rb` — add `test "should sort by updated_at"` (per-test `sign_in_as`, `assert_response :success`)
  - File: `test/controllers/admin/music/songs/lists_controller_test.rb` — add `test "should sort by updated_at ascending"` and `test "should sort by updated_at descending"` (sign_in in setup, `assert_response :success`)

### Test Seed / Fixtures
- Use existing `list_items.yml` and `lists.yml` fixtures (no new fixtures needed).

---

## Implementation Notes (living)
- Approach taken: Followed spec exactly — 4 source files modified, tests added to 4 Minitest files, Playwright E2E tests added for all 3 domains
- Important decisions:
  - Used `touch: true` on `belongs_to :list` which leverages ActiveRecord callbacks to cover all create/update/destroy paths automatically
  - E2E tests verify sort toggle via Turbo frame `href` attribute changes (since sort links target `turbo_frame: "lists_table"`, the page URL does not change)
  - Fixed games `ListsPage` table locator from `page.locator('table')` to `page.locator('turbo-frame#lists_table table')` to avoid strict mode violations from profiler tables in dev
  - Used `{ exact: true }` on `getByRole('link', { name: 'Updated' })` to avoid matching list names containing "Updated"

### Key Files Touched (paths only)
- `app/models/list_item.rb`
- `app/controllers/admin/lists_base_controller.rb`
- `app/components/admin/lists/table_component.html.erb`
- `test/models/list_item_test.rb`
- `test/controllers/admin/games/lists_controller_test.rb`
- `test/controllers/admin/music/albums/lists_controller_test.rb`
- `test/controllers/admin/music/songs/lists_controller_test.rb`
- `e2e/pages/games/admin/lists-page.ts`
- `e2e/pages/music/admin/album-lists-page.ts` (new)
- `e2e/pages/music/admin/song-lists-page.ts` (new)
- `e2e/fixtures/auth.ts`
- `e2e/tests/games/admin/lists-crud.spec.ts`
- `e2e/tests/music/admin/album-lists-sorting.spec.ts` (new)
- `e2e/tests/music/admin/song-lists-sorting.spec.ts` (new)

### Challenges & Resolutions
- Playwright `getByRole('link', { name: 'Updated' })` matched list names containing "Updated" (e.g., "100 Greatest Albums of Argentine Rock (Updated 2013)") → resolved with `{ exact: true }`
- Sort links use Turbo Frames so page URL doesn't change on sort → verified sort behavior by asserting the sort link's `href` attribute toggles direction correctly
- Dev profiler injects extra `<table>` elements causing strict mode violations on `page.locator('table')` → scoped to `turbo-frame#lists_table table`

### Deviations From Plan
- Added Playwright E2E tests (not in original implementation steps but required by acceptance criteria)
- Created new page objects for music album/song lists (no existing page objects for these pages)
- Fixed existing games `ListsPage` table locator to be more specific (improvement, not a deviation)

## Acceptance Results
- Date: 2026-03-04
- Verifier: Automated tests
- Artifacts:
  - Minitest: 157 runs, 338 assertions, 0 failures, 0 errors
  - Playwright E2E: 18 passed (including 3 new sorting tests + 15 existing games list tests)

## Future Improvements
- Consider adding `updated_at` sort to domain entity index pages (albums, songs, games) if useful

## Related PRs
-

## Documentation Updated
- [x] Spec file updated with implementation notes, deviations, and acceptance results
- [ ] `documentation.md`
- [ ] Class docs
