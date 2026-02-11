# Games Admin Interface

## Status
- **Status**: Complete (pending E2E test validation against live dev server)
- **Priority**: High
- **Created**: 2026-02-10
- **Started**: 2026-02-10
- **Completed**:
- **Developer**: Claude

## Overview
Build the full admin interface for the games domain (dev.thegreatest.games), covering CRUD for all game entities (Games, Companies, Platforms, Series), join table management (GameCompanies, GamePlatforms), categories, dashboard, and E2E tests. This follows the music admin as a reference implementation but refactors shared code into base controllers where possible.

**Scope**: Admin controllers, views, routes, policies, layout, sidebar, controller tests, E2E tests, and base controller refactoring for shared patterns.

**Non-goals**:
- Admin actions (AI descriptions, merge, import) — deferred to a later spec
- List wizard / ranking configuration UI — deferred
- Public-facing games pages — separate spec
- OpenSearch indexes for companies/platforms/series (use DB search for smaller entities)

## Context & Links
- Related tasks: `docs/specs/completed/games-data-model.md` (foundation — all models exist)
- Source files (authoritative): `web-app/app/models/games/`, `web-app/config/routes.rb`
- Existing patterns: `web-app/app/controllers/admin/music/` (reference implementation)
- E2E patterns: `web-app/e2e/tests/music/admin/`, `web-app/e2e/pages/music/admin/`

## Interfaces & Contracts

### Routes

All games admin routes live within the games domain constraint, mirroring the music pattern:

```ruby
constraints DomainConstraint.new(Rails.application.config.domains[:games]) do
  namespace :admin, module: "admin/games" do
    root to: "dashboard#index"

    resources :games do
      resources :game_companies, only: [:create], shallow: true
      resources :game_platforms, only: [:create], shallow: true
      resources :category_items, only: [:index, :create], controller: "/admin/category_items"
      resources :images, only: [:index, :create], controller: "/admin/images"
      collection do
        get :search
      end
    end

    resources :game_companies, only: [:update, :destroy]
    resources :game_platforms, only: [:destroy]

    resources :companies do
      resources :images, only: [:index, :create], controller: "/admin/images"
      collection do
        get :search
      end
    end

    resources :platforms do
      collection do
        get :search
      end
    end

    resources :series do
      collection do
        get :search
      end
    end

    resources :categories do
      collection do
        get :search
      end
    end
  end
end
```

### Endpoints

#### Games CRUD
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/games | List games (search + paginate + sort) | q, sort, page | admin/editor/games_role |
| GET | /admin/games/:id | Show game with associations | | admin/editor/games_role |
| GET | /admin/games/new | New game form | | admin/editor/games_role(write) |
| POST | /admin/games | Create game | games_game[title, description, release_year, game_type, parent_game_id, series_id] | admin/editor/games_role(write) |
| GET | /admin/games/:id/edit | Edit game form | | admin/editor/games_role(write) |
| PATCH | /admin/games/:id | Update game | games_game[...] | admin/editor/games_role(write) |
| DELETE | /admin/games/:id | Delete game | | admin/editor/games_role(delete) |
| GET | /admin/games/search | Autocomplete JSON | q | admin/editor/games_role |

#### Companies CRUD
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/companies | List companies | q, sort, page | admin/editor/games_role |
| GET | /admin/companies/:id | Show company with games | | admin/editor/games_role |
| GET | /admin/companies/new | New company form | | admin/editor/games_role(write) |
| POST | /admin/companies | Create company | games_company[name, description, country, year_founded] | admin/editor/games_role(write) |
| GET | /admin/companies/:id/edit | Edit company form | | admin/editor/games_role(write) |
| PATCH | /admin/companies/:id | Update company | games_company[...] | admin/editor/games_role(write) |
| DELETE | /admin/companies/:id | Delete company | | admin/editor/games_role(delete) |
| GET | /admin/companies/search | Autocomplete JSON (ILIKE) | q | admin/editor/games_role |

#### Platforms CRUD
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/platforms | List platforms | q, sort, page | admin/editor/games_role |
| GET | /admin/platforms/:id | Show platform with games | | admin/editor/games_role |
| GET | /admin/platforms/new | New platform form | | admin/editor/games_role(write) |
| POST | /admin/platforms | Create platform | games_platform[name, abbreviation, platform_family] | admin/editor/games_role(write) |
| GET | /admin/platforms/:id/edit | Edit platform form | | admin/editor/games_role(write) |
| PATCH | /admin/platforms/:id | Update platform | games_platform[...] | admin/editor/games_role(write) |
| DELETE | /admin/platforms/:id | Delete platform | | admin/editor/games_role(delete) |
| GET | /admin/platforms/search | Autocomplete JSON (ILIKE) | q | admin/editor/games_role |

#### Series CRUD
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /admin/series | List series | q, sort, page | admin/editor/games_role |
| GET | /admin/series/:id | Show series with games | | admin/editor/games_role |
| GET | /admin/series/new | New series form | | admin/editor/games_role(write) |
| POST | /admin/series | Create series | games_series[name, description] | admin/editor/games_role(write) |
| GET | /admin/series/:id/edit | Edit series form | | admin/editor/games_role(write) |
| PATCH | /admin/series/:id | Update series | games_series[...] | admin/editor/games_role(write) |
| DELETE | /admin/series/:id | Delete series | | admin/editor/games_role(delete) |
| GET | /admin/series/search | Autocomplete JSON (ILIKE) | q | admin/editor/games_role |

#### Join Tables (GameCompanies)
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /admin/games/:game_id/game_companies | Add company to game | games_game_company[company_id, developer, publisher] | admin/editor/games_role(write) |
| PATCH | /admin/game_companies/:id | Update roles | games_game_company[developer, publisher] | admin/editor/games_role(write) |
| DELETE | /admin/game_companies/:id | Remove company from game | | admin/editor/games_role(write) |

#### Join Tables (GamePlatforms)
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| POST | /admin/games/:game_id/game_platforms | Add platform to game | games_game_platform[platform_id] | admin/editor/games_role(write) |
| DELETE | /admin/game_platforms/:id | Remove platform from game | | admin/editor/games_role(write) |

### Autocomplete JSON Response Format

```json
[
  { "value": 123, "text": "The Legend of Zelda: Breath of the Wild (2017)" }
]
```

For companies: `{ "value": 1, "text": "Nintendo (JP)" }`
For platforms: `{ "value": 1, "text": "PlayStation 5 (PS5)" }`
For series: `{ "value": 1, "text": "The Legend of Zelda" }`

### Search Strategy

- **Games**: Use existing OpenSearch `Search::Games::Search::GameGeneral` and `GameAutocomplete`
- **Companies, Platforms, Series**: Simple DB-based `ILIKE` search (smaller datasets don't need OpenSearch)

```ruby
# reference only — company search pattern
def search
  companies = Games::Company.where("name ILIKE ?", "%#{params[:q]}%")
    .order(:name).limit(20)
  render json: companies.map { |c| { value: c.id, text: "#{c.name}#{c.country.present? ? " (#{c.country})" : ""}" } }
end
```

### Behaviors (pre/postconditions)

**Preconditions:**
- All admin endpoints require authentication via `Admin::BaseController#authenticate_admin!`
- Games domain endpoints allow global admin/editor OR users with games domain role
- Write operations (create/update) require write permission
- Delete operations require delete permission
- GameCompany create must have at least one of developer/publisher checked

**Postconditions:**
- Creating/updating games triggers SearchIndexable callbacks (OpenSearch re-index)
- Deleting a game cascades destroy to game_companies, game_platforms, identifiers, images, external_links, category_items
- Deleting a company cascades destroy to game_companies
- Deleting a series nullifies series_id on associated games
- Turbo Stream responses update flash + relevant list sections without full page reload

**Edge cases:**
- Empty search results return empty JSON array (guard against `in_order_of` ArgumentError)
- Invalid sort parameters default to name/title
- SQL injection in sort parameters rejected by whitelist

### Non-Functionals
- No N+1 queries on index or show pages (use `includes`/`preload`)
- Pagination: 25 items per page via Pagy
- All sort columns whitelisted to prevent SQL injection
- FriendlyId slugs used for all URL lookups

## Implementation Todos

### 1. Base Controller Refactoring ✅
- [x] Extract shared patterns from `Admin::Music::BaseController` and create a domain-agnostic base pattern
- [x] Create `Admin::Games::BaseController` following the same pattern with `layout "games/admin"` and games domain auth

### 2. Games Admin Layout ✅
- [x] Create `app/views/layouts/games/admin.html.erb` (copy music admin layout, update branding/title to "The Greatest Games")
- [x] Use same drawer + sidebar + navbar pattern
- [x] Reference games-specific CSS/JS: `games` stylesheet, `application` JS

### 3. Domain-Aware Sidebar ✅
- [x] Refactor `app/views/admin/shared/_sidebar.html.erb` to be domain-aware
- [x] On music domain: show music nav items (Artists, Albums, Songs, Lists, Rankings, Categories, AI Chats)
- [x] On games domain: show games nav items (Games, Companies, Platforms, Series, Categories)
- [x] Keep Global section (Penalties, Users, Purge Cache) on both
- [x] Update sidebar logo/title to match current domain ("The Greatest Music" vs "The Greatest Games")

### 4. Pundit Policies ✅
- [x] Create `app/policies/games/game_policy.rb` with `domain "games"`
- [x] Create `app/policies/games/company_policy.rb` with `domain "games"`
- [x] Create `app/policies/games/platform_policy.rb` with `domain "games"`
- [x] Create `app/policies/games/series_policy.rb` with `domain "games"`
- [x] Create `app/policies/games/category_policy.rb` with `domain "games"`
- [x] All follow same structure as `Music::ArtistPolicy` (no custom actions needed for initial CRUD-only scope)

### 5. Dashboard Controller + View ✅
- [x] Create `Admin::Games::DashboardController` with `index` action
- [x] Create dashboard view showing: Total Games, Total Companies, Total Platforms, Total Series stats
- [x] Quick link cards: Games (View All / Add New), Companies, Platforms, Series, Categories
- [x] Recently Added Games table (last 5)
- **Note**: Dashboard shows 4 stat cards (Games, Companies, Platforms, Series) — Categories stat card not included but has quick-link card

### 6. Games Controller (CRUD + Search) ✅
- [x] Create `Admin::Games::GamesController` with full CRUD
- [x] `index`: Search via `Search::Games::Search::GameGeneral` or browse with sort
- [x] `show`: Eager load companies, platforms, series, categories, identifiers, images
- [x] `search`: Autocomplete via `Search::Games::Search::GameAutocomplete`
- [x] Sort whitelist: id, title, release_year, game_type, created_at
- [x] Form fields: title, description, release_year, game_type (select), parent_game (autocomplete, shown when type is remake/remaster/expansion/dlc), series (autocomplete)

### 7. Companies Controller (CRUD + Search) ✅
- [x] Create `Admin::Games::CompaniesController` with full CRUD
- [x] `index`: DB-based `ILIKE` search or browse with sort
- [x] `show`: Eager load game_companies with games, images
- [x] `search`: DB-based `ILIKE` autocomplete endpoint
- [x] Sort whitelist: id, name, country, year_founded, created_at
- [x] Form fields: name, description, country (2-char ISO code), year_founded

### 8. Platforms Controller (CRUD + Search) ✅
- [x] Create `Admin::Games::PlatformsController` with full CRUD
- [x] `index`: DB-based `ILIKE` search or browse with sort
- [x] `show`: Show platform with game count
- [x] `search`: DB-based `ILIKE` autocomplete endpoint
- [x] Sort whitelist: id, name, platform_family, created_at
- [x] Form fields: name, abbreviation, platform_family (select from enum)

### 9. Series Controller (CRUD + Search) ✅
- [x] Create `Admin::Games::SeriesController` with full CRUD
- [x] `index`: DB-based `ILIKE` search or browse with sort
- [x] `show`: Show series with games list
- [x] `search`: DB-based `ILIKE` autocomplete endpoint
- [x] Sort whitelist: id, name, created_at
- [x] Form fields: name, description

### 10. GameCompanies Join Table Controller ✅
- [x] Create `Admin::Games::GameCompaniesController` (create, update, destroy)
- [x] `create`: From game show page, add company with developer/publisher checkboxes
- [x] `update`: Edit developer/publisher role flags on existing association
- [x] `destroy`: Remove company from game
- [x] Turbo Stream responses to update the companies list section in-place
- [x] Context detection: always from game page (unlike music's bidirectional album_artists)

### 11. GamePlatforms Join Table Controller ✅
- [x] Create `Admin::Games::GamePlatformsController` (create, destroy)
- [x] `create`: From game show page, add platform via autocomplete
- [x] `destroy`: Remove platform from game
- [x] Turbo Stream responses to update the platforms list section in-place
- [x] No update needed (platform join has no editable fields beyond the FK)

### 12. Categories Controller ✅
- [x] Create `Admin::Games::CategoriesController` following `Admin::Music::CategoriesController` pattern
- [x] Full CRUD + search endpoint for autocomplete
- [x] Uses existing `Games::Category` model (STI)

### 13. Views — Index Pages ✅
- [x] Games index: search bar + sortable table (Title, Release Year, Type, Developers, Platforms, Actions) + pagination
- [x] Companies index: search bar + sortable table (Name, Country, Founded, Games Count, Actions) + pagination
- [x] Platforms index: search bar + sortable table (Name, Abbreviation, Family, Games Count, Actions) + pagination
- [x] Series index: search bar + sortable table (Name, Games Count, Actions) + pagination
- [x] Categories index: search bar + sortable table (Name, Type, Games Count, Actions) + pagination

### 14. Views — Show Pages ✅
- [x] Game show page with sections (all subsections complete)
- [x] Company show page: Basic info + developed games list + published games list + images + identifiers
- [x] Platform show page: Basic info + games list
- [x] Series show page: Basic info + games list ordered by release_year
- [x] Categories show page: Basic info + child categories + games count + metadata

### 15. Views — Form Pages (New/Edit) ✅
- [x] Game form: title, description (textarea), release_year, game_type (select), parent_game (autocomplete — conditional on type), series (autocomplete)
- [x] Company form: name, description (textarea), country (text input, 2 chars), year_founded
- [x] Platform form: name, abbreviation, platform_family (select from enum)
- [x] Series form: name, description (textarea)
- [x] Categories form: name, category_type (select), parent_id (select), description (textarea)

### 16. Views — Partials ✅
- [x] `_table.html.erb` for each entity type (used in turbo frame for index pagination/sort)
- [x] `_companies_list.html.erb` for game show page (company associations with edit/remove)
- [x] `_platforms_list.html.erb` for game show page (platform associations with remove)
- **Note**: `_games_list.html.erb` is not a separate partial — company/platform/series show pages render games inline

### 17. Routes ✅
- [x] Add games admin routes within games domain constraint in `config/routes.rb`
- [x] Follow shallow nesting pattern from music admin
- [x] Ensure route helpers use games-specific naming (`admin_games_` prefix via `as: "admin_games"`)

### 18. Controller Tests (Minitest) ✅ (94 tests, all passing)
- [x] `test/controllers/admin/games/games_controller_test.rb` — Auth, CRUD, search, sort, empty results (22 tests)
- [x] `test/controllers/admin/games/companies_controller_test.rb` — Auth, CRUD, search (12 tests)
- [x] `test/controllers/admin/games/platforms_controller_test.rb` — Auth, CRUD, search (11 tests)
- [x] `test/controllers/admin/games/series_controller_test.rb` — Auth, CRUD, search (11 tests)
- [x] `test/controllers/admin/games/game_companies_controller_test.rb` — Create, update, destroy (7 tests)
- [x] `test/controllers/admin/games/game_platforms_controller_test.rb` — Create, destroy (5 tests)
- [x] `test/controllers/admin/games/dashboard_controller_test.rb` — Auth, index loads (4 tests)
- [x] `test/controllers/admin/games/categories_controller_test.rb` — Auth, CRUD, soft-delete, search (14 tests)

**All 94 tests passing. Full suite: 3449 runs, 0 failures, 0 errors.**

### 19. E2E Tests (Playwright) ✅
- [x] Update `playwright.config.ts` — added `games` project with `baseURL: https://dev.thegreatest.games`, separate `games-setup` auth project
- [x] Created `e2e/auth/games-auth.setup.ts` — games domain auth setup (Login button + Firebase modal)
- [x] Created `e2e/fixtures/games-auth.ts` — games custom test fixtures with page objects
- [x] `e2e/pages/games/admin/dashboard-page.ts`
- [x] `e2e/pages/games/admin/games-page.ts`
- [x] `e2e/pages/games/admin/companies-page.ts`
- [x] `e2e/pages/games/admin/platforms-page.ts`
- [x] `e2e/pages/games/admin/series-page.ts`
- [x] `e2e/tests/games/admin/dashboard.spec.ts` — Dashboard loads, stats visible, quick links work (4 tests)
- [x] `e2e/tests/games/admin/games-crud.spec.ts` — Index loads, search input, table rows, navigate to show (5 tests)
- [x] `e2e/tests/games/admin/companies-crud.spec.ts` — Index loads, search, table, show page (5 tests)
- [x] `e2e/tests/games/admin/platforms-crud.spec.ts` — Index loads, table, show page (5 tests)
- [x] `e2e/tests/games/admin/series-crud.spec.ts` — Index loads, table, show page (5 tests)
- [x] Added `data-testid="back-button"` to all 5 games show pages for E2E testability

### 20. Fixtures (Additions/Updates) ✅
- [x] Existing games fixtures are sufficient for controller tests
- [x] Series fixtures exist
- [x] game_companies and game_platforms fixtures cover test scenarios

## Acceptance Criteria

- [ ] All games admin routes resolve correctly within games domain constraint
- [ ] Dashboard shows correct stats and navigation works
- [ ] Full CRUD works for Games, Companies, Platforms, Series, Categories
- [ ] Game show page displays companies, platforms, categories, identifiers, images
- [ ] Add/edit/remove company associations from game show page (with developer/publisher checkboxes)
- [ ] Add/remove platform associations from game show page
- [ ] Add category associations via modal with autocomplete
- [ ] Upload/manage images from show pages
- [ ] Autocomplete search works for all entity types
- [ ] Sorting works for all index pages with SQL injection protection
- [ ] Pagination works on all index pages (25 per page)
- [ ] Sidebar is domain-aware: shows games nav on games domain, music nav on music domain
- [ ] Pundit policies enforce proper authorization for all actions
- [ ] No N+1 queries on index or show pages
- [ ] All controller tests pass (auth, CRUD, search, sort)
- [ ] E2E tests pass for dashboard, all CRUD pages, and navigation
- [ ] All existing tests still pass (3335+ tests)

### Golden Examples

**Games index with search:**
```
GET /admin/games?q=Zelda
→ Search::Games::Search::GameGeneral.call("Zelda", size: 1000)
→ Returns games matching "Zelda", preserving search relevance order
→ Paginated (25/page), table shows Title, Year, Type, Developers, Platforms
```

**Add company to game (Turbo Stream):**
```
POST /admin/games/:id/game_companies
  { games_game_company: { company_id: 1, developer: true, publisher: false } }
→ Creates GameCompany record
→ Returns turbo_stream replacing "game_companies_list" frame
→ Flash notice: "Company added successfully."
```

**Company search (DB-based):**
```
GET /admin/companies/search?q=nint
→ Games::Company.where("name ILIKE ?", "%nint%").order(:name).limit(20)
→ JSON: [{ "value": 1, "text": "Nintendo (JP)" }]
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Match Music domain patterns for consistency (see `Admin::Music::*` controllers and views).
- Use Rails generators for controllers (creates test files automatically).
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Controller files in `web-app/app/controllers/admin/games/`
- View files in `web-app/app/views/admin/games/`
- Policy files in `web-app/app/policies/games/`
- Layout file at `web-app/app/views/layouts/games/admin.html.erb`
- Updated sidebar at `web-app/app/views/admin/shared/_sidebar.html.erb`
- Updated routes in `web-app/config/routes.rb`
- Controller tests in `web-app/test/controllers/admin/games/`
- E2E page objects in `web-app/e2e/pages/games/admin/`
- E2E test specs in `web-app/e2e/tests/games/admin/`
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect Admin::Music::* controller patterns for reference
2) codebase-analyzer → verify route helper naming, policy integration points
3) technical-writer → update docs and cross-refs after implementation

### Test Seed / Fixtures
- Existing: `test/fixtures/games/games.yml` (5 games), `companies.yml` (3), `platforms.yml` (5), `series.yml`, `game_companies.yml` (5), `game_platforms.yml` (7)
- May need: additional series fixtures if `test/fixtures/games/series.yml` needs expansion

---

## Implementation Notes (living)
- Approach taken: Modeled entirely after music admin pattern — identical controller structure, view patterns, policies
- Important decisions:
  - Routes use `as: "admin_games"` to namespace route helpers (e.g., `admin_games_games_path`)
  - Series controller uses `@series_collection` for index to avoid Ruby naming conflict with singular `@series`
  - Categories use STI on shared `categories` table (not `games_categories`)
  - Categories controller uses `soft_delete!` instead of hard delete, matching music pattern
  - GameCompanies is unidirectional (only from game context), unlike music's bidirectional AlbumArtists

### Key Files Touched (paths only)
- `app/controllers/admin/games/base_controller.rb`
- `app/controllers/admin/games/dashboard_controller.rb`
- `app/controllers/admin/games/games_controller.rb`
- `app/controllers/admin/games/companies_controller.rb`
- `app/controllers/admin/games/platforms_controller.rb`
- `app/controllers/admin/games/series_controller.rb`
- `app/controllers/admin/games/categories_controller.rb`
- `app/controllers/admin/games/game_companies_controller.rb`
- `app/controllers/admin/games/game_platforms_controller.rb`
- `app/views/layouts/games/admin.html.erb`
- `app/views/admin/shared/_sidebar.html.erb`
- `app/views/admin/games/` (all view files)
- `app/policies/games/` (all policy files)
- `config/routes.rb`
- `test/controllers/admin/games/` (all test files)
- `e2e/pages/games/admin/` (page objects)
- `e2e/tests/games/admin/` (test specs)
- `e2e/fixtures/` (auth fixture updates)
- `e2e/playwright.config.ts` (games project)

### Challenges & Resolutions
- Pagy API mismatch: Views incorrectly used `pagy_nav(@pagy)` (old API) instead of `pagy.series_nav` (current API). **Fixed** in all 5 `_table.html.erb` partials.
- Categories views: Generator created scaffold placeholders for show/new/edit; `_form.html.erb` partial was never created. **Fixed** — all views implemented.
- Categories update test: FriendlyId slug regeneration after name change causes redirect URL mismatch. **Fixed** — moved `@category.reload` before `assert_redirected_to`.
- AddCategoryModalComponent: Did not handle `Games::Game` for `form_url` and `search_url`. **Fixed** — added games cases.

### Deviations From Plan
- Dashboard does not include a Categories stat card (has quick-link card instead)
- `_games_list.html.erb` not created as a separate partial — company/platform/series show pages render games inline

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Add admin actions: AI description generation, merge games, bulk actions
- Add list wizard for games
- Add ranking configurations for games
- Add data import (IGDB, RAWG)
- Add OpenSearch indexes for companies/platforms if dataset grows

## Related PRs
-

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
