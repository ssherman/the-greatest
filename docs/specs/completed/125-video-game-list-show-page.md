# Video Game List Show Page

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-24
- **Started**: 2026-02-24
- **Completed**: 2026-02-24
- **Developer**: Claude

## Overview
Implement the public-facing show page for video game lists, modeled after the album list show page (`music/albums/lists/show`). The page displays full list metadata, description, weight/penalty info, and a paginated list of games. Additionally: fix RC scoping for games list routes (currently outside the RC scope block), update the games list index to link cards to the show page, and update the game show page to link "Appears On These Lists" entries to the list show page.

A follow-up refactor replaced the initial card-per-row layout with a responsive grid using `Games::CardComponent`, matching the `/video-games` ranked items index.

**Non-goals**: Admin changes, changes to list item models.

## Context & Links
- Model after: `app/views/music/albums/lists/show.html.erb`
- Album list controller: `app/controllers/music/albums/lists_controller.rb`
- Games list controller: `app/controllers/games/lists_controller.rb`
- Games list index view: `app/views/games/lists/index.html.erb`
- Game show view: `app/views/games/games/show.html.erb`
- Routes: `config/routes.rb` (lines 327-343)
- Games default helper: `app/helpers/games/default_helper.rb`
- Penalty partial: `app/views/music/lists/_simple_penalty_summary.html.erb`
- Penalty badge helper: `app/helpers/music/lists_helper.rb`
- CardComponent: `app/components/games/card_component.rb`, `app/components/games/card_component.html.erb`
- E2E tests: `e2e/tests/games/public/lists.spec.ts`

## Interfaces & Contracts

### Domain Model (diffs only)
No model changes needed. `Games::List`, `ListItem`, and `Games::Game` associations already exist.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/lists/:id` (games domain) | Show a video game list with paginated games | `id` (list ID), `page` (optional, default 1) | public |
| GET | `/rc/:ranking_configuration_id/lists/:id` (games domain) | Same, with explicit RC | `ranking_configuration_id`, `id`, `page` | public |

> Source of truth: `config/routes.rb`

### Route Changes
Moved games lists routes **inside** the existing RC scope block:

```ruby
# Current (broken - no RC scoping):
scope as: "games" do
  resources :lists, only: [:index], controller: "games/lists"
end

# Target (inside RC scope, add :show):
scope "(/rc/:ranking_configuration_id)" do
  # ... existing game routes ...
  get "lists",     to: "games/lists#index", as: :games_lists
  get "lists/:id", to: "games/lists#show",  as: :games_list
end
```

Named routes: `games_lists_path`, `games_list_path(list)`.

### Behaviors (pre/postconditions)
- **Preconditions**: List must exist (404 if not found). RC defaults to `Games::RankingConfiguration.default_primary` if not in URL.
- **Postconditions**: Page renders list metadata, description, weight card (if ranked_list exists), and paginated game items with eager-loaded associations.
- **CardComponent** accepts one of `game:`, `ranked_item:`, or `list_item:` (at least one required)
- `show_rank?` returns true when `ranked_item` is present OR `list_item` has a non-nil `position`
- `rank_display` returns `ranked_item.rank` or `list_item.position` (whichever is present)
- `item_game` resolves the game from any of the three sources
- Links from CardComponent include `data-turbo-frame="_top"` to break out of Turbo Frames
- List items ordered by `position ASC NULLS LAST` to handle lists with missing positions
- **Edge cases**:
  - List exists but has no list items → show empty state ("No games in this list")
  - List exists but is not in any ranking config → omit weight card, still show list
  - List item's `listable` is nil (unlinked item) → skip rendering that item
  - Page param out of range → Pagy handles with 404/redirect

### Non-Functionals
- Eager-load game associations to avoid N+1: `listable` → `game_companies` → `company`, `categories`, `platforms`, `primary_image` variant chain
- HTTP caching via `Cacheable` concern: `cache_for_show_page` (24hr public cache)
- Pagy pagination at 100 items/page
- Turbo Frame wrap for paginated section (`turbo_frame_tag "list_items"`)
- Grid responsive: 1 col mobile, 2 col md, 3 col lg, 4 col xl

## Acceptance Criteria

### 1. Route & RC Scoping Fix
- [x] Games list routes moved inside `scope "(/rc/:ranking_configuration_id)"` block
- [x] Both `/lists` (index) and `/lists/:id` (show) support optional RC prefix
- [x] `games_lists_path` and `games_list_path` route helpers work
- [x] `load_ranking_configuration` before_action works for both index and show

### 2. List Show Page - Controller
- [x] `Games::ListsController#show` action added
- [x] Includes `Pagy::Method`
- [x] Loads `@list = Games::List.find(params[:id])`
- [x] Loads `@ranked_list` from `@ranking_configuration.ranked_lists.find_by(list: @list)`
- [x] Paginates list items at 100/page with eager loading
- [x] Uses `cache_for_show_page` before_action
- [x] `load_ranking_configuration` uses `Games::RankingConfiguration` (via `ranking_configuration_class` class method)

### 3. List Show Page - View
- [x] SEO: `page_title` and `meta_description` set from list attributes
- [x] List name as `<h1>`
- [x] Metadata badges: source, year published, item count, number of voters (when present)
- [x] Weight card with penalty summary (when `@ranked_list` present)
- [x] Full description in prose block
- [x] "View Original List" external link button (when URL present)
- [x] Game items rendered via `Games::CardComponent` in responsive grid showing:
  - Position number as rank badge
  - Game title linked to `game_path`
  - Cover image (with fallback)
  - Developer name(s)
  - Release year
  - Category/genre badges (first 3)
- [x] Pagination nav above and below list (when >1 page)
- [x] Empty state when no items

### 4. Index Page → Show Page Links
- [x] Each list card on `games/lists/index` wrapped in `link_to` to `games_list_path`
- [x] RC context preserved via `ranking_configuration_id` param

### 5. Game Show Page → List Links
- [x] "Appears On These Lists" section entries are `link_to` tags linking to `games_list_path`

### 6. Helper Updates
- [x] `Games::DefaultHelper` gains `games_list_path_with_rc(list, rc)` method
- [x] `Games::DefaultHelper` gains `link_to_game_list(list, rc, **options, &block)` method
- [x] Penalty helpers: created `Games::ListsHelper` with same logic as music

### 7. E2E Tests
- [x] Lists index page loads successfully
- [x] Lists index shows list cards
- [x] Clicking a list navigates to list show page
- [x] List show page displays metadata badges
- [x] List show page displays game cards in grid
- [x] List show page game cards have rank badges
- [x] Clicking a game card from list navigates to game show page

### Golden Examples
```text
Input: GET /lists/42 on games domain
Output: Show page for Games::List#42 with default primary RC, paginated game items

Input: GET /rc/5/lists/42 on games domain
Output: Same list but ranked_list loaded from RC#5

Input: GET /lists/42?page=2 on games domain
Output: Page 2 of list items (items 101-200)
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Mirror `music/albums/lists/show.html.erb` structure adapted for game-specific fields.
- Reuse `Games::CardComponent` rather than creating a new component.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → verify album list show page patterns for exact replication
2) codebase-analyzer → verify eager loading chain for Games::Game associations
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- `Games::List` fixtures with associated `ListItem`s pointing to `Games::Game` fixtures
- `Games::RankingConfiguration` fixture with a `RankedList` pointing to the test list
- Fixtures: `test/fixtures/lists.yml`, `test/fixtures/list_items.yml`, `test/fixtures/games/games.yml`

---

## Implementation Notes

### Approach
1. Initial implementation modeled card-per-row layout after music album list show page.
2. Refactored to responsive grid using `Games::CardComponent` for visual consistency with `/video-games`.
3. Extended `Games::CardComponent#initialize` to accept `list_item:` with validation requiring at least one of `game:`, `ranked_item:`, or `list_item:`.
4. Added `rank_display` helper method to abstract rank source (ranked_item vs list_item).
5. Updated ERB template to use `rank_display` instead of `ranked_item.rank`.
6. Added `data-turbo-frame="_top"` to CardComponent link to fix navigation when rendered inside a Turbo Frame.
7. Updated controller ordering to `Arel.sql("list_items.position ASC NULLS LAST")`.
8. Wrote 7 Playwright E2E tests for list index + show pages.

### Key Files Touched
- `config/routes.rb`
- `app/controllers/games/lists_controller.rb`
- `app/views/games/lists/show.html.erb` (new)
- `app/views/games/lists/index.html.erb`
- `app/views/games/games/show.html.erb`
- `app/helpers/games/default_helper.rb`
- `app/helpers/games/lists_helper.rb` (new)
- `app/helpers/lists_helper.rb` (new)
- `app/views/games/lists/_simple_penalty_summary.html.erb` (new)
- `app/components/games/card_component.rb` — Added `list_item:` param, `rank_display` method
- `app/components/games/card_component.html.erb` — Use `rank_display`, add `data-turbo-frame="_top"`
- `test/controllers/games/lists_controller_test.rb`
- `e2e/tests/games/public/lists.spec.ts`
- `e2e/tests/games/public/game-detail.spec.ts` — Fixed flaky developer byline locator

### Challenges & Resolutions
- **Turbo Frame bug**: Cards rendered inside `turbo_frame_tag "list_items"` caused clicks to fail (Turbo looked for a matching frame on the game show page). Fixed by adding `data-turbo-frame="_top"` to the link in CardComponent — harmless when not inside a frame.
- **E2E byline locator**: `text=/^by /` regex failed due to leading whitespace in rendered HTML. Changed to `page.locator('p', { hasText: /by \w/ })`.

### Deviations From Plan
- Used `Games::CardComponent` with responsive grid instead of inline card-per-row HTML (improvement over original plan for visual consistency).
- Added `data-turbo-frame="_top"` to CardComponent link (not in original plan, discovered during testing).
- Platform badges and truncated description not shown in grid card layout (CardComponent shows categories instead — matches existing pattern from ranked items page).

## Acceptance Results
- 2026-02-24: All 12 controller tests pass, all 19 ranked items + component tests pass, all 8 E2E list tests pass (11.5s), all 5 game detail E2E tests pass (12.7s). Full suite: 129 E2E tests passed.

## Future Improvements
- Extract penalty summary partial to shared location (currently duplicated between music and games)
- Extract `penalty_badge_class` helper to a shared module
- Consider shared list show ViewComponent across domains
- Add `data-testid` attributes to list show page elements for more stable E2E selectors

## Related PRs
-

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
