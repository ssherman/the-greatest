# Games Admin Ranking Configurations CRUD

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2026-02-12
- **Started**: 2026-02-12
- **Completed**: 2026-02-12
- **Developer**: Claude

## Overview
Implement admin CRUD interface for `Games::RankingConfiguration` with maximum code reuse from the existing music ranking configuration admin. This involves **extracting shared infrastructure** from the music-specific implementation into domain-agnostic base classes, then building a thin games-specific layer on top.

**Scope**: Games ranking configuration admin + shared extraction.
**Non-goals**: Movies/Books ranking config admin (future specs), public-facing games rankings pages, games list wizard.

## Context & Links
- Related: `docs/specs/completed/077-custom-admin-phase-6-ranking-configs.md` (music implementation)
- Related: `docs/specs/games-list-admin.md` (games list admin - already implemented)
- Source: `app/controllers/admin/music/ranking_configurations_controller.rb` (current music base)
- Source: `app/controllers/admin/ranked_lists_controller.rb` (already global)
- Source: `app/controllers/admin/music/ranked_items_controller.rb` (music-scoped, needs extraction)
- Docs: `docs/features/rankings.md`, `docs/testing.md`, `docs/dev-core-values.md`

## Interfaces & Contracts

### Domain Model (no migrations needed)
All models already exist via STI:
- `Games::RankingConfiguration` → `app/models/games/ranking_configuration.rb`
- `RankedItem` (polymorphic, item_type: `Games::Game`) → `app/models/ranked_item.rb`
- `RankedList` (list_type: `Games::List`) → `app/models/ranked_list.rb`
- `Games::Game` → `app/models/games/game.rb`
- `Games::List` → `app/models/games/list.rb`

No new database tables or migrations required.

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|------|------|---------|-------------|------|
| GET | /admin/ranking_configurations | Index (paginated, searchable, sortable) | q, sort, page | admin/editor/domain |
| GET | /admin/ranking_configurations/new | New form | | admin/editor/domain |
| POST | /admin/ranking_configurations | Create | ranking_configuration fields | admin/editor/domain |
| GET | /admin/ranking_configurations/:id | Show with lazy-loaded ranked items/lists | | admin/editor/domain |
| GET | /admin/ranking_configurations/:id/edit | Edit form | | admin/editor/domain |
| PATCH | /admin/ranking_configurations/:id | Update | ranking_configuration fields | admin/editor/domain |
| DELETE | /admin/ranking_configurations/:id | Destroy | | admin/editor/domain |
| POST | /admin/ranking_configurations/:id/execute_action | Single-record action | action_name | admin/editor/domain |
| POST | /admin/ranking_configurations/index_action | Bulk action | action_name, ranking_configuration_ids[] | admin/editor/domain |

> Source of truth: `config/routes.rb` — routes added inside the games domain constraint block.

### Schemas (JSON)

**Strong parameters (shared in base controller):**
```json
{
  "type": "object",
  "required": ["name"],
  "properties": {
    "name": { "type": "string", "maxLength": 255 },
    "description": { "type": "string" },
    "global": { "type": "boolean" },
    "primary": { "type": "boolean" },
    "archived": { "type": "boolean" },
    "published_at": { "type": "string", "format": "date-time" },
    "algorithm_version": { "type": "integer" },
    "exponent": { "type": "number", "minimum": 0, "maximum": 10 },
    "bonus_pool_percentage": { "type": "number", "minimum": 0, "maximum": 100 },
    "min_list_weight": { "type": "integer", "minimum": 1 },
    "list_limit": { "type": "integer" },
    "apply_list_dates_penalty": { "type": "boolean" },
    "max_list_dates_penalty_age": { "type": "integer" },
    "max_list_dates_penalty_percentage": { "type": "integer", "minimum": 1, "maximum": 100 },
    "primary_mapped_list_id": { "type": "integer" },
    "secondary_mapped_list_id": { "type": "integer" },
    "primary_mapped_list_cutoff_limit": { "type": "integer" }
  },
  "additionalProperties": false
}
```

### Behaviors (pre/postconditions)

**Index:**
- Precondition: User is admin, editor, or has games domain access
- Search: `name ILIKE ?` when `q` param present
- Sort: Whitelist of allowed columns (name, algorithm_version, published_at, created_at, id)
- Pagination: Pagy, 25 items per page

**Create/Update:**
- Precondition: User has `manage?` permission via policy
- Postcondition: Only one `primary` config per type allowed (model validation)
- Postcondition: Global configs cannot have user_id, user configs must have user_id
- Error: Render form with `:unprocessable_entity` on validation failure

**Destroy:**
- Precondition: User has `manage?` permission
- Postcondition: Cascading destroy of ranked_items and ranked_lists
- Redirect to index with notice

**Execute Action (BulkCalculateWeights):**
- Precondition: At least one config selected (or all used when none selected)
- Postcondition: `BulkCalculateWeightsJob` enqueued for each config
- Returns turbo_stream flash update

**Execute Action (RefreshRankings):**
- Precondition: Exactly one config
- Postcondition: `CalculateRankingsJob` enqueued
- Returns turbo_stream flash update

### Non-Functionals
- N+1 prevention: `includes(:primary_mapped_list, :secondary_mapped_list, ...)` on show
- Ranked items/lists loaded via lazy Turbo Frames (show page loads instantly)
- Sort column SQL injection prevented via whitelist
- Pagination: 25 items per page for all paginated views
- Background jobs for weight calculation and ranking refresh (no request timeouts)

## Architecture: Shared Extraction + Games Layer

### Step 1: Extract Shared Base Controller

**Refactor** the existing `Admin::Music::RankingConfigurationsController` into a domain-agnostic shared base.

**New file**: `app/controllers/admin/ranking_configurations_controller.rb`

**Inherits from**: `Admin::BaseController`

**Contains**: All CRUD logic currently in `Admin::Music::RankingConfigurationsController`:
- `index`, `show`, `new`, `create`, `edit`, `update`, `destroy`
- `execute_action`, `index_action`
- `load_ranking_configurations_for_index`, `sortable_column`, `ranking_configuration_params`

**Abstract methods** (subclasses must implement):
- `ranking_configuration_class` — returns the STI model class
- `ranking_configurations_path` — index route helper
- `ranking_configuration_path(config)` — show route helper
- `table_partial_path` — turbo frame table partial
- `policy_class` — Pundit policy class for authorization
- `domain_name` — string like `"music"` or `"games"` for auth check

**Key change**: Replace hardcoded `Music::RankingConfigurationPolicy` with `policy_class` method. Replace hardcoded `Actions::Admin::Music::` namespace with `Actions::Admin::`.

**Auth**: The base controller provides domain-aware authentication:
```ruby
# reference only
def authenticate_admin!
  return if current_user&.admin? || current_user&.editor?
  unless current_user&.can_access_domain?(domain_name)
    redirect_to domain_root_path, alert: "Access denied. You need permission for #{domain_name} admin."
  end
end
```

### Step 2: Refactor Music Controller to Inherit from Shared Base

**Modify**: `app/controllers/admin/music/ranking_configurations_controller.rb`

**Change from**: `< Admin::Music::BaseController` (with all CRUD logic)
**Change to**: `< Admin::RankingConfigurationsController` (thin wrapper)

**Provides**:
- `layout "music/admin"`
- `domain_name` → `"music"`
- `policy_class` → `Music::RankingConfigurationPolicy`
- Still abstract: `ranking_configuration_class`, `ranking_configurations_path`, `ranking_configuration_path`, `table_partial_path`

**Existing subclasses unchanged**: `Admin::Music::Albums::RankingConfigurationsController`, `Admin::Music::Songs::RankingConfigurationsController`, `Admin::Music::Artists::RankingConfigurationsController` still inherit from `Admin::Music::RankingConfigurationsController` exactly as they do today.

### Step 3: Extract Shared Actions

**Move**: `Actions::Admin::Music::BulkCalculateWeights` → `Actions::Admin::BulkCalculateWeights`
**Move**: `Actions::Admin::Music::RefreshRankings` → `Actions::Admin::RefreshRankings`

These actions are already domain-agnostic (they call `BulkCalculateWeightsJob.perform_async(config.id)` and `config.calculate_rankings_async` — no music-specific logic).

**Base controller** changes `action_class` resolution from:
```ruby
"Actions::Admin::Music::#{params[:action_name]}".constantize
```
to:
```ruby
"Actions::Admin::#{params[:action_name]}".constantize
```

**Delete** the old music-namespaced action files after moving.

### Step 4: Create Games Controller

**New file**: `app/controllers/admin/games/ranking_configurations_controller.rb`

**Inherits from**: `Admin::RankingConfigurationsController`

**Provides**:
- `layout "games/admin"`
- `domain_name` → `"games"`
- `policy_class` → `Games::RankingConfigurationPolicy`
- `ranking_configuration_class` → `::Games::RankingConfiguration`
- `ranking_configurations_path` → `admin_games_ranking_configurations_path`
- `ranking_configuration_path(config)` → `admin_games_ranking_configuration_path(config)`
- `table_partial_path` → `"admin/games/ranking_configurations/table"`

Games is flat (no sub-namespaces like albums/songs), so this is the final controller — no subclasses needed.

### Step 5: Create Games Policy

**New file**: `app/policies/games/ranking_configuration_policy.rb`

Identical structure to `Music::RankingConfigurationPolicy` with `domain = "games"`.

### Step 6: Extend Ranked Items Controller (Music → Global)

**Move**: `app/controllers/admin/music/ranked_items_controller.rb` → `app/controllers/admin/ranked_items_controller.rb`

**Change from**: `< Admin::Music::BaseController`
**Change to**: `< Admin::BaseController`

**Add** games type handling for eager loading:
```ruby
# reference only
case @ranking_configuration.type
when "Music::Albums::RankingConfiguration", "Music::Songs::RankingConfiguration"
  @ranked_items = @ranked_items.includes(item: :artists)
when "Games::RankingConfiguration"
  @ranked_items = @ranked_items.includes(item: :companies)
end
```

**Update routes**: Move ranked_items from music admin namespace to global admin namespace (alongside ranked_lists).

### Step 7: Extend Ranked Items View

**Modify**: `app/views/admin/ranked_items/index.html.erb` (moved from `admin/music/ranked_items/`)

**Add** a `Games::RankingConfiguration` branch to the item display:
- Game title linked to `admin_games_game_path(ranked_item.item)`
- Companies listed (linked to `admin_games_company_path`)

### Step 8: Extend Ranked Lists Controller

**Modify**: `app/controllers/admin/ranked_lists_controller.rb`

**Add** games redirect case to `redirect_path`:
```ruby
# reference only
when /^Games::/
  admin_games_ranking_configuration_path(@ranking_configuration)
```

### Step 9: Create Games Views

**New files** (following music albums pattern with games-specific path helpers):
- `app/views/admin/games/ranking_configurations/index.html.erb`
- `app/views/admin/games/ranking_configurations/_table.html.erb`
- `app/views/admin/games/ranking_configurations/show.html.erb`
- `app/views/admin/games/ranking_configurations/new.html.erb`
- `app/views/admin/games/ranking_configurations/edit.html.erb`
- `app/views/admin/games/ranking_configurations/_form.html.erb`

These are structurally identical to the music albums views but with:
- `admin_games_ranking_configurations_path` instead of `admin_albums_ranking_configurations_path`
- `admin_games_ranking_configuration_path` instead of `admin_albums_ranking_configuration_path`
- `edit_admin_games_ranking_configuration_path` instead of `edit_admin_albums_ranking_configuration_path`
- `execute_action_admin_games_ranking_configuration_path` instead of `execute_action_admin_albums_ranking_configuration_path`

### Step 10: Add Routes

**Modify**: `config/routes.rb` — inside the games domain constraint block:

```ruby
# reference only — inside games admin namespace
resources :ranking_configurations do
  member do
    post :execute_action
  end
  collection do
    post :index_action
  end
end
```

**Also**: Move ranked_items routes from music admin to global admin (alongside ranked_lists):
```ruby
# reference only — inside global admin namespace
scope "ranking_configuration/:ranking_configuration_id", as: "ranking_configuration" do
  resources :penalty_applications, only: [:index, :create]
  resources :ranked_lists, only: [:index, :create]
  resources :ranked_items, only: [:index]  # ← moved from music admin
end
```

### Step 11: Update Sidebar Navigation

**Modify**: `app/views/admin/shared/_sidebar.html.erb`

Add a "Rankings" entry under the Games section linking to `admin_games_ranking_configurations_path`.

## Acceptance Criteria
- [x] Shared base controller `Admin::RankingConfigurationsController` extracted from music
- [x] Music ranking config admin still works identically after refactoring (no regression)
- [x] `Admin::Games::RankingConfigurationsController` provides full CRUD
- [x] `/admin/ranking_configurations` on games domain shows index with search, sort, pagination
- [x] Show page displays all configuration fields, algorithm params, penalty config
- [x] Show page has lazy-loaded Turbo Frame sections for ranked items and ranked lists
- [x] New/Create/Edit/Update forms work with validation error display
- [x] Destroy with confirmation dialog works
- [x] Actions execute successfully:
  - [x] BulkCalculateWeights (index-level, enqueues background job)
  - [x] RefreshRankings (single record, enqueues background job)
- [x] Actions are shared (`Actions::Admin::BulkCalculateWeights`, not music-namespaced)
- [x] Ranked items section shows game title + companies with admin links
- [x] Ranked items controller is now global (not music-scoped)
- [x] Ranked lists controller handles games redirect path
- [x] `Games::RankingConfigurationPolicy` enforces admin/editor/domain access
- [x] Sidebar shows "Rankings" link under Games section
- [x] Authorization prevents non-admin/editor access on games domain
- [x] N+1 queries prevented with eager loading
- [x] Sort column SQL injection prevented with whitelist
- [x] All existing music ranking config tests still pass
- [x] New games ranking config tests pass
- [x] E2E tests pass: full CRUD workflow (create, read, update, delete) for ranking configurations
- [x] E2E tests pass: index page loads with search, table, and New button
- [x] E2E tests pass: show page displays config details and action buttons
- [x] E2E tests pass: sidebar "Rankings" link navigates correctly
- [x] E2E tests confirmed running successfully by agent before completion

### Golden Examples

```text
Input: Admin visits /admin/ranking_configurations on games domain
Output: Index page showing "Global Games Ranking" config with Primary badge, search bar, pagination

Input: Admin clicks "Refresh Rankings" on games ranking config show page
Output: Flash message "Ranking calculation queued for Global Games Ranking.", CalculateRankingsJob enqueued

Input: Ranked items turbo frame loads on games config show page
Output: Table showing games ranked by rank ascending, each with title linked to admin game page and companies listed
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use Rails generators for new controllers (creates test files automatically).
- Refactoring existing music code must not break existing tests.

### Required Outputs
- Shared base controller: `app/controllers/admin/ranking_configurations_controller.rb`
- Refactored music controller: `app/controllers/admin/music/ranking_configurations_controller.rb`
- Games controller: `app/controllers/admin/games/ranking_configurations_controller.rb`
- Games policy: `app/policies/games/ranking_configuration_policy.rb`
- Shared actions: `app/lib/actions/admin/bulk_calculate_weights.rb`, `app/lib/actions/admin/refresh_rankings.rb`
- Moved ranked items controller: `app/controllers/admin/ranked_items_controller.rb`
- Games views: `app/views/admin/games/ranking_configurations/` (index, show, new, edit, _form, _table)
- Extended ranked items view: `app/views/admin/ranked_items/index.html.erb`
- Updated routes: `config/routes.rb`
- Updated sidebar: `app/views/admin/shared/_sidebar.html.erb`
- Updated ranked lists controller: `app/controllers/admin/ranked_lists_controller.rb`
- E2E page object: `e2e/pages/games/admin/ranking-configurations-page.ts`
- E2E test spec: `e2e/tests/games/admin/ranking-configurations-crud.spec.ts`
- Updated E2E fixture: `e2e/fixtures/games-auth.ts` (add `rankingConfigurationsPage`)
- Updated E2E sidebar test: `e2e/tests/games/admin/sidebar-nav.spec.ts` (add Rankings link)
- Passing unit/integration tests for all Acceptance Criteria
- Passing E2E tests confirmed by running `yarn test:e2e` successfully
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) **codebase-pattern-finder** → Collect music ranking config patterns to replicate for games
2) **codebase-analyzer** → Verify Games::RankingConfiguration associations and ranked item/list queries
3) **technical-writer** → Update docs and cross-refs after implementation

### Test Seed / Fixtures
- Existing: `ranking_configurations(:games_global)` in `test/fixtures/ranking_configurations.yml`
- May need: A secondary non-primary games ranking config fixture for testing create/primary validation
- Existing: Games fixtures in `test/fixtures/games/games.yml` (breath_of_the_wild, etc.)
- Existing: Users fixtures `admin_user`, `editor_user`, `regular_user`

### Build Sequence
1. Extract shared base controller + refactor music (run music tests to verify no regression)
2. Extract shared actions (run music tests again)
3. Move ranked items controller to global admin + update routes (run all tests)
4. Create games policy
5. Create games controller
6. Create games views
7. Add games routes + sidebar navigation
8. Extend ranked lists controller redirect path
9. Write games controller tests
10. Write games action tests (or update existing ones for new namespace)
11. Run full unit/integration test suite (`bin/rails test`)
12. Write E2E page object and test spec
13. Update games-auth fixture and sidebar-nav test
14. Run full E2E suite (`yarn test:e2e`) and confirm all tests pass

---

## E2E Testing Requirements

Per project policy, all new user-facing features **must** include E2E tests. See `docs/features/e2e-testing.md` and `docs/testing.md`.

### Infrastructure (already exists)
- Games auth setup: `e2e/auth/games-auth.setup.ts`
- Games fixture: `e2e/fixtures/games-auth.ts`
- Playwright config: `e2e/playwright.config.ts` (games project configured)

### New Page Object Model

**New file**: `e2e/pages/games/admin/ranking-configurations-page.ts`

Follow the existing pattern from `e2e/pages/games/admin/lists-page.ts`:
- `heading` — `page.getByRole('heading', { name: 'Ranking Configurations', exact: true })`
- `searchInput` — search input locator
- `newButton` — `page.getByRole('link', { name: /New/ })`
- `table` — `page.locator('table')`
- `tableRows` — `table.locator('tbody tr')`
- `goto()` — navigates to `/admin/ranking_configurations`

### Update Games Auth Fixture

**Modify**: `e2e/fixtures/games-auth.ts`

Add `rankingConfigurationsPage` fixture (import and register the new POM).

### New E2E Test Spec

**New file**: `e2e/tests/games/admin/ranking-configurations-crud.spec.ts`

Follow the CRUD pattern established in `e2e/tests/games/admin/lists-crud.spec.ts`:

**Tests to implement:**

| # | Test | Description |
|---|------|-------------|
| 1 | Index page loads | Heading visible, table present |
| 2 | Index page shows search and New button | Search input + "New" link visible |
| 3 | Create a new ranking configuration | Fill form, submit, verify show page with new name |
| 4 | Read — show page content | Create config → verify show page sections (Basic Info, Algorithm Config, Penalty Config, Ranked Items, Ranked Lists) |
| 5 | Update an existing configuration | Create → Edit → change name → verify updated name on show page |
| 6 | Delete a configuration | Create → Delete (accept turbo_confirm dialog) → verify redirect to index |
| 7 | Search filters the table | Create config with unique name → search → verify result visible |
| 8 | Show page displays action buttons | Create config → verify "Recalculate List Weights" and "Refresh Rankings" in Actions dropdown |

**Test pattern** (reference — follow `lists-crud.spec.ts`):
- Each mutation test creates its own test data (unique name with `Date.now()`)
- Tests are independent and self-contained
- Use `page.on('dialog', dialog => dialog.accept())` for turbo_confirm dialogs
- Use `page.waitForURL(...)` after navigations

### Cleanup Requirement

**Tests must clean up all records they create.** The E2E test database is shared across runs, so leftover records pollute future test results.

**Pattern**: Every test that creates a ranking configuration (or any associated record like ranked_lists) must delete it before the test ends. Use `test.afterEach` or inline cleanup at the end of each test.

**Recommended approach** — use a shared helper that deletes via the UI:

```typescript
// reference only
async function deleteRankingConfiguration(page: Page) {
  // Assumes we're on the show page of the config to delete
  page.on('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Delete' }).click();
  await page.waitForURL(/\/admin\/ranking_configurations$/);
}
```

**Apply cleanup to each test that creates data:**
- Test 3 (Create): navigate to show page → delete
- Test 4 (Read): delete at end
- Test 5 (Update): delete at end
- Test 7 (Search): navigate to created config → delete
- Test 8 (Action buttons): delete at end

Test 6 (Delete) already cleans up by nature of the test itself.
Tests 1 & 2 (Index page loads) are read-only and don't need cleanup.

### Update Sidebar Navigation Test

**Modify**: `e2e/tests/games/admin/sidebar-nav.spec.ts`

Add test for Rankings sidebar link:
```typescript
// reference only
test('sidebar Rankings link navigates correctly', async ({ page }) => {
  await sidebar(page).getByRole('link', { name: 'Rankings', exact: true }).click();
  await expect(page).toHaveURL(/\/admin\/ranking_configurations/);
  await expect(page.getByRole('heading', { name: 'Ranking Configurations' })).toBeVisible();
});
```

### E2E Verification Requirement

**The implementing agent must**:
1. Start the local dev server for the games domain
2. Run `yarn test:e2e` from `web-app/`
3. Confirm all E2E tests pass (including existing games tests + new ranking config tests)
4. Report pass/fail results in the "Acceptance Results" section of this spec

If E2E tests cannot be run (e.g., no dev server available), the agent must document this in "Deviations From Plan" and note it as a manual verification step.

---

## Implementation Notes (living)
- Approach taken: Followed the spec's build sequence exactly. Extracted shared base controller, refactored music to inherit, moved actions to shared namespace, moved ranked items controller to global admin, created games controller/policy/views.
- Important decisions: Kept music's `authenticate_admin!` override in the music ranking config controller (not in shared base) so each domain controls its own auth. The `policy_class` is now an abstract method on the shared base controller.

### Key Files Touched (paths only)
- `app/controllers/admin/ranking_configurations_controller.rb` (new - shared base)
- `app/controllers/admin/music/ranking_configurations_controller.rb` (refactored)
- `app/controllers/admin/games/ranking_configurations_controller.rb` (new)
- `app/controllers/admin/ranked_items_controller.rb` (moved from music)
- `app/controllers/admin/ranked_lists_controller.rb` (extended)
- `app/policies/games/ranking_configuration_policy.rb` (new)
- `app/lib/actions/admin/bulk_calculate_weights.rb` (moved from music)
- `app/lib/actions/admin/refresh_rankings.rb` (moved from music)
- `app/views/admin/games/ranking_configurations/` (new - 6 files)
- `app/views/admin/ranked_items/index.html.erb` (moved + extended)
- `app/views/admin/shared/_sidebar.html.erb` (extended)
- `config/routes.rb` (extended)

### Challenges & Resolutions
-

### Deviations From Plan
- Ranked items controller auth message changed from domain-specific to global ("Access denied. Admin or editor role required.") since it now inherits from Admin::BaseController instead of Admin::Music::BaseController. Updated the existing test accordingly.
- The old music ranked items controller file and view were deleted (replaced by global versions at admin/ranked_items/).
- Actions moved from `Actions::Admin::Music::` namespace to `Actions::Admin::` namespace (shared). Old files deleted.

## Acceptance Results
- Date: 2026-02-12
- Unit/Integration: 3536 runs, 9325 assertions, 0 failures, 0 errors, 0 skips
- E2E: 113 passed (all existing + 10 new ranking config + 1 new sidebar), 0 failed
- Games ranking config tests: 38 runs, 93 assertions, 0 failures

## Future Improvements
- Movies ranking config admin (same pattern — thin controller + policy + views)
- Books ranking config admin (same pattern)
- Shared view partials/ViewComponents to reduce view duplication across domains
- Checkbox selection UI for bulk actions on index page

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
