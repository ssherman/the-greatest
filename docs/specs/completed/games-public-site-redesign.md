# Games Public Site Redesign

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-23
- **Started**: 2026-02-23
- **Completed**: 2026-02-23
- **Developer**: AI Agent

## Overview
Redesign the video games public site to show ranked games as the front page, modeled after the music albums ranked items page. Use the DaisyUI "abyss" theme (dark cyberpunk teal) for the games domain. Simplified nav with two links: "Games" and "Lists". Includes a games lists page and year/decade filter tabs.

**Non-goals**: Game detail/show pages, search functionality, admin changes.

## Context & Links
- Music albums ranked items (pattern followed): `web-app/app/controllers/music/albums/ranked_items_controller.rb`
- Music albums card component: `web-app/app/components/music/albums/card_component.rb`
- Music filter tabs component: `web-app/app/components/music/filter_tabs_component.rb`
- Music lists controller: `web-app/app/controllers/music/lists_controller.rb`
- Games layout: `web-app/app/views/layouts/games/application.html.erb`
- Games model: `web-app/app/models/games/game.rb`
- Games ranking config: `web-app/app/models/games/ranking_configuration.rb`
- Base ranked items controller: `web-app/app/controllers/ranked_items_controller.rb`
- Routes: `web-app/config/routes.rb`

## Interfaces & Contracts

### Domain Model (diffs only)
- No new models or migrations needed. Uses existing `Games::Game`, `Games::RankingConfiguration`, `RankedItem`, `Games::List` models.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | / | Renders ranked games (front page) | - | public |
| GET | /video-games | Ranked games index (all time) | ranking_configuration_id (optional) | public |
| GET | /video-games/:year | Ranked games filtered by decade/year | year (e.g. "1990s") | public |
| GET | /video-games/since/:year | Games since year | year (e.g. "2000") | public |
| GET | /video-games/through/:year | Games through year | year (e.g. "1999") | public |
| GET | /lists | Games lists index | - | public |
> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)
- **Preconditions**: `Games::RankingConfiguration.default_primary` must exist (fixture: `games_global`)
- **Postconditions**:
  - Ranked games displayed ordered by `rank` ASC
  - Pagination at 100 items per page (matching music pattern)
  - Year filter correctly scopes results by `games_games.release_year`
- **Edge cases**:
  - No ranked items → show empty state with appropriate messaging
  - Invalid year format → 404 (handled by route constraints)
  - No ranking configuration → 404 (ActiveRecord::RecordNotFound)

### Non-Functionals
- Caching: Use `Cacheable` concern (6hr cache, Cloudflare-friendly)
- No N+1: eager load `item: [:categories, :primary_image, {game_companies: :company}]`
- Mobile-first responsive design
- DaisyUI "abyss" theme applied via `data-theme="abyss"` on `<html>` tag
- Games CSS includes abyss theme: `@plugin "daisyui" { themes: light --default, dark --prefersdark, abyss; }`

## Acceptance Criteria

### Layout & Theme
- [x] Games layout uses `data-theme="abyss"` (dark teal/cyberpunk theme)
- [x] Navbar has exactly 2 links: "Games" and "Lists"
- [x] Navbar includes domain name with game emoji and login button
- [x] Mobile responsive hamburger menu works
- [x] Footer present with copyright

### Ranked Games Page
- [x] `GET /video-games` shows ranked games in a card grid
- [x] Cards display: rank badge, cover image, title, release year, developer name(s), category badges (up to 3)
- [x] Games are ordered by rank ascending
- [x] Pagination works (100 per page) with DaisyUI-styled paging
- [x] Empty state displayed when no games match filters
- [x] Filter tabs show decades (1980s through 2020s) plus "All Time" and "Custom"
- [x] Decade filter URLs work: `/video-games/1990s`
- [x] Since/through filter URLs work
- [x] Front page (root `/`) routes to ranked games

### Lists Page
- [x] `GET /lists` shows ranked game lists
- [x] Each list card shows: name, weight badge, item count, source, description
- [x] Empty state when no lists exist

### Technical
- [x] Controller inherits from base `RankedItemsController` pattern
- [x] Caching applied via `Cacheable` concern
- [x] No N+1 queries (nested eager loading for game_companies:company, .to_a for categories)
- [x] Controller tests pass (18 tests, 0 failures)
- [x] E2E tests created for games public pages

### E2E Tests
- [x] Games front page loads successfully
- [x] Ranked games are visible with rank badges
- [x] Decade filter navigation works
- [x] Lists page loads successfully
- [x] Navigation links work (Games, Lists)

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Reuse or generalize existing components where possible (FilterTabsComponent pattern).
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → already done (music ranked items pattern identified)
2) web-search-researcher → already done (DaisyUI theme scoping confirmed)
3) UI Engineer → build layout, views, and components
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing fixtures: `games_global` ranking configuration in `ranking_configurations.yml`
- Existing game fixtures: `breath_of_the_wild`, `resident_evil_4`, etc. in `games/games.yml`
- Added ranked_items fixtures for games in `ranked_items.yml`

### Files Created
- `web-app/app/controllers/games/ranked_items_controller.rb`
- `web-app/app/controllers/games/lists_controller.rb`
- `web-app/app/views/games/ranked_items/index.html.erb`
- `web-app/app/views/games/lists/index.html.erb`
- `web-app/app/components/games/card_component.rb`
- `web-app/app/components/games/card_component.html.erb`
- `web-app/app/components/games/filter_tabs_component.rb`
- `web-app/app/components/games/filter_tabs_component.html.erb`
- `web-app/app/helpers/games/ranked_items_helper.rb`
- `web-app/app/assets/stylesheets/games/paging.css`
- `web-app/test/controllers/games/ranked_items_controller_test.rb`
- `web-app/test/controllers/games/lists_controller_test.rb`
- `web-app/e2e/tests/games/public/games-browse.spec.ts`
- `web-app/e2e/tests/games/public/lists.spec.ts`
- `web-app/e2e/tests/games/public/navigation.spec.ts`

### Files Modified
- `web-app/config/routes.rb` — added public games routes
- `web-app/app/views/layouts/games/application.html.erb` — redesigned with abyss theme + simplified nav
- `web-app/app/assets/stylesheets/games/application.css` — added abyss theme config + paging import
- `web-app/test/fixtures/ranked_items.yml` — added game ranked items fixtures
- `web-app/test/controllers/games/default_controller_test.rb` — updated for new root route

---

## Implementation Notes (living)
- Approach taken: Followed existing music albums ranked items pattern closely with agreed simplifications
- Important decisions:
  - Flat namespace (`Games::RankedItemsController`) instead of nested `Games::Games::` since only one rankable entity
  - Simple read-only lists page (no submission form)
  - Filter tabs: 1980s through 2020s (games-appropriate decades)
  - DaisyUI "abyss" theme — required explicit theme config in CSS: `@plugin "daisyui" { themes: light --default, dark --prefersdark, abyss; }`
  - Cards not clickable (no game show pages yet — non-goal)
  - Nav links say "Games" (not "Video Games") and link to root `/`
  - Custom paging.css for DaisyUI-styled pagination on dark theme

### Key Files Touched (paths only)
- `app/controllers/games/ranked_items_controller.rb` (new)
- `app/controllers/games/lists_controller.rb` (new)
- `app/components/games/card_component.rb` (new)
- `app/components/games/card_component.html.erb` (new)
- `app/components/games/filter_tabs_component.rb` (new)
- `app/components/games/filter_tabs_component.html.erb` (new)
- `app/helpers/games/ranked_items_helper.rb` (new)
- `app/assets/stylesheets/games/paging.css` (new)
- `app/assets/stylesheets/games/application.css` (modified)
- `app/views/games/ranked_items/index.html.erb` (new)
- `app/views/games/lists/index.html.erb` (new)
- `app/views/layouts/games/application.html.erb` (modified — abyss theme, simplified nav)
- `config/routes.rb` (modified — public games routes)
- `test/fixtures/ranked_items.yml` (modified — added game ranked items)
- `test/controllers/games/ranked_items_controller_test.rb` (new)
- `test/controllers/games/lists_controller_test.rb` (new)
- `test/controllers/games/default_controller_test.rb` (modified — updated for new root)
- `e2e/tests/games/public/games-browse.spec.ts` (new)
- `e2e/tests/games/public/lists.spec.ts` (new)
- `e2e/tests/games/public/navigation.spec.ts` (new)

### Challenges & Resolutions
- N+1 queries in card component: Fixed by using `game_companies: :company` nested eager loading and `.to_a` for categories
- DaisyUI abyss theme not rendering: Required explicit theme config in games CSS `@plugin "daisyui" { themes: ... abyss; }`
- Pagination unstyled: Created `games/paging.css` with DaisyUI btn classes for dark theme compatibility

### Deviations From Plan
- Used flat `Games::RankedItemsController` instead of spec's nested `Games::Games::RankedItemsController`
- Cards are not links (game show pages are a non-goal)
- Lists page is read-only (no submission form)
- Nav says "Games" instead of "Video Games", links to `/` instead of `/video-games`

## Acceptance Results
- Date: 2026-02-23
- Verifier: AI Agent
- 3925 unit/integration tests passing (0 failures, 0 errors)
- 18 new controller tests for games public pages
- 3 E2E test specs created (games-browse, lists, navigation)

## Future Improvements
- Game detail/show pages
- Search functionality
- Developer/company pages
- Platform filtering

## Related PRs
- #…

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
