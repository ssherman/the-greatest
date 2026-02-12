# Games List Admin CRUD

## Status
- **Status**: Complete
- **Priority**: High
- **Created**: 2026-02-11
- **Started**:
- **Completed**:
- **Developer**: Claude

## Overview
Implement admin CRUD for game lists, list items, and penalties within the games domain (dev.thegreatest.games). This reuses the existing global list infrastructure (STI `List` model, shared `ListItem`/`ListPenalty` controllers) with minimal new code. The key change is extracting a shared base controller from `Admin::Music::ListsController` so both music and games can inherit list CRUD logic.

**Scope**: Games list controller, views, routes, policy, shared base controller extraction, sidebar update, updates to global controllers/components to support games domain, controller tests, E2E tests.

**Non-goals**:
- List wizard / AI import workflow (deferred to later spec)
- Ranking configurations for games (separate spec)
- Public-facing list pages

## Context & Links
- Related tasks: `docs/specs/completed/games-admin-interface.md` (games entity CRUD), `docs/specs/completed/games-data-model.md` (models)
- Existing patterns: `app/controllers/admin/music/lists_controller.rb` (base list CRUD), `app/controllers/admin/music/albums/lists_controller.rb` (concrete subclass)
- Global shared controllers: `app/controllers/admin/list_items_controller.rb`, `app/controllers/admin/list_penalties_controller.rb`
- Existing models: `app/models/games/list.rb` (STI subclass), `app/models/games/penalty.rb` (STI subclass)
- E2E patterns: `docs/features/e2e-testing.md` (architecture), `docs/testing.md` (testing guide)
- Games E2E infrastructure: `e2e/fixtures/games-auth.ts`, `e2e/auth/games-auth.setup.ts`, `e2e/playwright.config.ts`
- Games E2E page objects: `e2e/pages/games/admin/` (existing POMs for dashboard, games, companies, platforms, series)

## Interfaces & Contracts

### Domain Model (no migrations needed)
- `Games::List < List` already exists — STI type `"Games::List"` on shared `lists` table
- `Games::Penalty < Penalty` already exists — STI type `"Games::Penalty"` on shared `penalties` table
- `ListItem` already supports polymorphic `listable` with `Games::Game`
- `ListPenalty` already validates domain compatibility

### Routes

Games list routes within the games domain constraint:

```ruby
# Inside: constraints DomainConstraint.new(Rails.application.config.domains[:games]) do
#   namespace :admin, module: "admin/games", as: "admin_games" do
resources :lists
#   end
# end
```

Route helpers: `admin_games_lists_path`, `admin_games_list_path(list)`, `new_admin_games_list_path`, `edit_admin_games_list_path(list)`

List items and penalties use existing global routes (no changes needed):
- `admin_list_list_items_path(list)` — GET index, POST create
- `admin_list_item_path(item)` — PATCH update, DELETE destroy
- `admin_list_list_penalties_path(list)` — GET index, POST create
- `admin_list_penalty_path(penalty)` — DELETE destroy

### Endpoints

#### Games Lists CRUD
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/lists | List games lists (search + filter + paginate + sort) | q, status, sort, direction, page | admin/editor/games_role |
| GET | /admin/lists/:id | Show list with items, penalties | | admin/editor/games_role |
| GET | /admin/lists/new | New list form | | admin/editor/games_role(write) |
| POST | /admin/lists | Create list | games_list[name, description, status, ...] | admin/editor/games_role(write) |
| GET | /admin/lists/:id/edit | Edit list form | | admin/editor/games_role(write) |
| PATCH | /admin/lists/:id | Update list | games_list[...] | admin/editor/games_role(write) |
| DELETE | /admin/lists/:id | Delete list | | admin/editor/games_role(delete) |

#### List Items (existing global controller — needs redirect_path update)
| Verb | Path | Purpose | Auth |
|---|---|---|---|
| GET | /admin/list/:list_id/list_items | Lazy-load items for show page | admin/editor |
| POST | /admin/list/:list_id/list_items | Add game to list | admin/editor |
| PATCH | /admin/list_items/:id | Update item (position, verified) | admin/editor |
| DELETE | /admin/list_items/:id | Remove item from list | admin/editor |
| DELETE | /admin/list/:list_id/list_items/destroy_all | Remove all items | admin/editor |

#### List Penalties (existing global controller — needs redirect_path update)
| Verb | Path | Purpose | Auth |
|---|---|---|---|
| GET | /admin/list/:list_id/list_penalties | Lazy-load penalties for show page | admin/editor |
| POST | /admin/list/:list_id/list_penalties | Attach penalty to list | admin/editor |
| DELETE | /admin/list_penalties/:id | Detach penalty from list | admin/editor |

### Behaviors (pre/postconditions)

**Preconditions:**
- All endpoints require authentication via `Admin::Games::BaseController#authenticate_admin!`
- Games domain endpoints allow global admin/editor OR users with games domain role
- Write operations require write permission; delete requires delete permission
- List items validate `listable_type` compatibility (`Games::List` only accepts `Games::Game`)

**Postconditions:**
- Creating/deleting lists updates dashboard stats (if dashboard shows list count)
- Deleting a list cascades destroy to `list_items` and `list_penalties`
- Penalty attachment validates domain compatibility (only `Global::Penalty` and `Games::Penalty` allowed on `Games::List`)
- Turbo Stream responses update flash + relevant sections without full page reload

**Edge cases:**
- Empty search results return empty table with appropriate empty state
- Invalid sort parameters default to `lists.name`
- Invalid status filters return all lists (same behavior as music)
- `AttachPenaltyModalComponent` already handles games via `type.split("::").first` logic

### Non-Functionals
- No N+1 queries on index or show pages (use `includes`/`left_joins`)
- Pagination: 25 items per page via Pagy
- All sort columns whitelisted to prevent SQL injection
- Form omits `musicbrainz_series_id` (music-specific field)

## Implementation Todos

### 1. Extract Shared Base Controller
- [ ] Create `Admin::ListsBaseController < Admin::BaseController` extracting all CRUD logic from `Admin::Music::ListsController`
- [ ] Template methods: `list_class`, `lists_path`, `list_path`, `new_list_path`, `edit_list_path`, `param_key`, `items_count_name`, `listable_includes`
- [ ] Update `Admin::Music::ListsController` to inherit from `Admin::ListsBaseController` instead of `Admin::Music::BaseController`
- [ ] Music controller keeps: layout via its own base, policy via `Music::ListPolicy`, music-specific auth
- [ ] Verify all existing music list tests still pass

### 2. Games List Controller
- [ ] Create `Admin::Games::ListsController < Admin::ListsBaseController`
- [ ] Implement template methods: `list_class` → `Games::List`, route helpers → `admin_games_*`, `param_key` → `:games_list`, `items_count_name` → `"games_count"`, `listable_includes` → `[:companies, :platforms, :series]`
- [ ] Override `list_params` to exclude `musicbrainz_series_id`
- [ ] Uses `layout "games/admin"` and games auth from `Admin::Games::BaseController` (resolve inheritance — see Architecture note)

### 3. Games List Policy
- [ ] Create `Games::ListPolicy < ApplicationPolicy` with `domain "games"`
- [ ] Follow same structure as `Music::ListPolicy`

### 4. Update Global Controllers
- [ ] Update `Admin::ListItemsController#redirect_path` to handle `"Games::List"` → `admin_games_list_path(@list)`
- [ ] Update `Admin::ListPenaltiesController#redirect_path` to handle `"Games::List"` → `admin_games_list_path(@list)`

### 5. Update ViewComponents
- [ ] Update `Admin::AddItemToListModalComponent` to handle `Games::List`:
  - `autocomplete_url` → `search_admin_games_games_path`
  - `expected_listable_type` → `"Games::Game"`
  - `item_label` → `"Game"`

### 6. Games List Views
- [ ] `app/views/admin/games/lists/index.html.erb` — Search bar + status filter + sortable table + pagination
- [ ] `app/views/admin/games/lists/_table.html.erb` — Table partial (ID, Name, Status, Year, Games count, Created, Actions)
- [ ] `app/views/admin/games/lists/show.html.erb` — List detail page with: basic info, metadata, flags, games items (turbo frame), penalties (turbo frame), raw data sections
- [ ] `app/views/admin/games/lists/new.html.erb` — New form wrapper
- [ ] `app/views/admin/games/lists/edit.html.erb` — Edit form wrapper
- [ ] `app/views/admin/games/lists/_form.html.erb` — Shared form (same as music but without `musicbrainz_series_id`)
- [ ] Show page: "Games" section instead of "Albums", buttons say "+ Add Game", no "Launch Wizard" button

### 7. Sidebar Update
- [ ] Add "Lists" nav item to games sidebar section (between Categories and the end of the Games section)

### 8. Controller Tests
- [ ] `test/controllers/admin/games/lists_controller_test.rb` — Auth, CRUD, sort, status filter, pagination, search, data import fields
- [ ] Pattern: follow `test/controllers/admin/music/albums/lists_controller_test.rb`
- [ ] Use `host! Rails.application.config.domains[:games]` in setup
- [ ] Test with `Games::List` model, `games_list` param key

### 9. E2E Tests (Playwright)
Full CRUD E2E coverage for games list admin. See `docs/features/e2e-testing.md` for architecture details and `docs/testing.md` for testing guide.

**Page Object:**
- [ ] `e2e/pages/games/admin/lists-page.ts` — Locators: heading, subtitle, searchInput, statusFilter, newListButton, table, tableRows. Methods: `goto()`, `clickFirstList()`

**Test Fixture Update:**
- [ ] Update `e2e/fixtures/games-auth.ts` — Add `listsPage: ListsPage` fixture

**Test Specs:**
- [ ] `e2e/tests/games/admin/lists-crud.spec.ts` — Full CRUD coverage:
  - Index page loads with heading and subtitle
  - Index page shows search input and status filter
  - Index page shows "New List" button
  - Create: click "New List", fill form (name, status, source), submit, verify redirect to show page
  - Read: navigate to show page, verify list name, basic info card, items section, penalties section
  - Update: from show page click Edit, change name, submit, verify updated name on show page
  - Delete: from show page click Delete, confirm dialog, verify redirect to index
  - Search: type in search input, verify table updates
  - Status filter: select a status, verify table updates

**View testability:**
- [ ] Add `data-testid` attributes where needed for stable E2E selectors (e.g., `data-testid="back-button"` on show page back link)

## Acceptance Criteria

- [ ] All games list routes resolve correctly within games domain constraint
- [ ] Full CRUD works for Games::List (create, read, update, delete)
- [ ] Index page supports search by name/source, status filter, sortable columns, pagination (25/page)
- [ ] Show page displays list items (lazy-loaded via turbo frame) and penalties (lazy-loaded via turbo frame)
- [ ] Add/edit/remove game items from list show page via modal
- [ ] Attach/detach penalties from list show page via modal (shows Global + Games penalties)
- [ ] Delete all items button works from show page
- [ ] Form omits musicbrainz_series_id but includes all other shared List fields
- [ ] Show page has no "Launch Wizard" button (deferred)
- [ ] Sidebar shows "Lists" link on games domain
- [ ] `Admin::Music::ListsController` still works identically (no regressions)
- [ ] Pundit policy enforces proper authorization for all actions
- [ ] No N+1 queries on index or show pages
- [ ] All controller tests pass
- [ ] E2E tests pass: index loads, full CRUD (create, read, update, delete), search, status filter
- [ ] All existing tests still pass (3449+ tests)

### Golden Examples

**Games list index with search:**
```
GET /admin/lists?q=best+rpg&status=approved
→ Games::List.search_by_name("best rpg").where(status: :approved)
→ Paginated (25/page), table shows ID, Name, Status, Year, Games count, Created
```

**Add game to list:**
```
POST /admin/list/:list_id/list_items
  { list_item: { listable_id: 42, listable_type: "Games::Game", position: 1 } }
→ Creates ListItem record with listable polymorphism
→ Returns turbo_stream replacing "list_items_list" frame
→ Flash notice: "Item added successfully."
```

**Attach penalty to games list:**
```
POST /admin/list/:list_id/list_penalties
  { list_penalty: { penalty_id: 7 } }
→ Creates ListPenalty (validates Games::Penalty or Global::Penalty compatibility)
→ Returns turbo_stream replacing "list_penalties_list" frame
→ Flash notice: "Penalty attached successfully."
```

---

## Agent Hand-Off

### Architecture Note: Controller Inheritance

The key design decision is the shared base controller extraction. The challenge: `Admin::Music::ListsController` currently inherits from `Admin::Music::BaseController` (which sets layout and auth). After extraction:

```
Admin::BaseController
  ├── Admin::ListsBaseController (shared CRUD logic, template methods)
  │     ├── Admin::Music::Albums::ListsController (was: < Admin::Music::ListsController)
  │     ├── Admin::Music::Songs::ListsController (was: < Admin::Music::ListsController)
  │     └── Admin::Games::ListsController (new)
  ├── Admin::Music::BaseController (music layout + auth)
  └── Admin::Games::BaseController (games layout + auth)
```

The music subclasses need to keep their music layout and auth. Options:
- A) `Admin::ListsBaseController < Admin::BaseController`, then music subclasses set `layout "music/admin"` and call `authorize` with `Music::ListPolicy` explicitly. Games subclasses set `layout "games/admin"` and use `Games::ListPolicy`.
- B) Use a concern instead of inheritance for the shared logic.

Recommendation: Option A is cleanest. The current `Admin::Music::ListsController` already explicitly sets `policy_class: Music::ListPolicy` on every authorize call, so auth is already handled at the subclass level. Layout can be set per subclass.

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (<=40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Music admin must have zero regressions.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect Admin::Music::ListsController patterns, global controller patterns
2) codebase-analyzer → verify route helper naming, policy integration, modal component dependencies
3) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Existing: `test/fixtures/games/games.yml` (5 games), `test/fixtures/users.yml` (admin_user, regular_user)
- Games::List records created in test setup (following music list test pattern)
- No new fixture files needed

---

## Implementation Notes (living)
- Approach taken: Option A from Architecture Note — `Admin::ListsBaseController < Admin::BaseController` with template methods. Music and games subclasses set their own layout, auth, and policy.
- Important decisions:
  - Added `policy_class` and `item_label` as template methods on the base controller (not in original spec but needed for clean extraction)
  - Added `permitted_params` method to base controller returning the shared params array; music controller overrides to add `:musicbrainz_series_id`
  - Flash messages use `item_label` (e.g., "Game list created successfully." / "Album list created successfully.")

### Key Files Touched (paths only)
- `app/controllers/admin/lists_base_controller.rb` (new — extracted from music)
- `app/controllers/admin/music/lists_controller.rb` (refactored to inherit from base)
- `app/controllers/admin/games/lists_controller.rb` (new)
- `app/controllers/admin/list_items_controller.rb` (updated redirect_path)
- `app/controllers/admin/list_penalties_controller.rb` (updated redirect_path)
- `app/components/admin/add_item_to_list_modal_component.rb` (updated for games)
- `app/policies/games/list_policy.rb` (new)
- `app/views/admin/games/lists/` (all view files — new)
- `app/views/admin/shared/_sidebar.html.erb` (updated)
- `config/routes.rb` (updated — add `resources :lists` to games admin)
- `test/controllers/admin/games/lists_controller_test.rb` (new)
- `e2e/pages/games/admin/lists-page.ts` (new — page object)
- `e2e/tests/games/admin/lists-crud.spec.ts` (new — E2E tests)
- `e2e/fixtures/games-auth.ts` (updated — add listsPage fixture)

### Challenges & Resolutions
- The existing `Admin::Music::ListsController` already had template methods making extraction clean
- Music controller's `authenticate_admin!` override needed to be preserved after re-parenting from `Admin::Music::BaseController`

### Deviations From Plan
- Added `policy_class` and `item_label` as additional template methods (not in spec but needed)
- Added `permitted_params` override pattern instead of `list_params` override (cleaner for musicbrainz_series_id exclusion)

## Acceptance Results
- Date: 2026-02-11
- Verifier: Claude
- Full test suite: 3488 tests, 0 failures, 0 errors, 0 skips
- New tests: 39 games list controller tests all passing
- Music regression: 46 album list + 41 song list tests all passing

## Future Improvements
- Add list wizard / AI import workflow for games
- Add ranking configurations for games
- Add music list E2E tests (currently music has no list E2E coverage)
- Consider extracting shared view partials if music and games views diverge minimally

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
