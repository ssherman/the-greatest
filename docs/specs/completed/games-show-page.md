# Games Show Page

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-23
- **Started**: 2026-02-23
- **Completed**: 2026-02-23
- **Developer**: AI Agent

## Overview
Add a public game detail/show page to the games domain, following the music albums show page pattern. Display all available game metadata: cover art, rank, description, developers/publishers, platforms, categories (genre/theme/game_mode/player_perspective), series & related games, and lists. Make game cards on the ranked items index clickable links to the show page.

**Non-goals**: Company show pages, platform filtering pages, search.

## Context & Links
- Albums show page (pattern to follow): `app/controllers/music/albums_controller.rb`
- Albums show view: `app/views/music/albums/show.html.erb`
- Music helper (link helpers pattern): `app/helpers/music/default_helper.rb`
- Games model: `app/models/games/game.rb`
- Games card component: `app/components/games/card_component.rb`
- Games ranked items controller: `app/controllers/games/ranked_items_controller.rb`
- Games layout: `app/views/layouts/games/application.html.erb`
- Routes: `config/routes.rb`
- Cacheable concern: `app/controllers/concerns/cacheable.rb`
- Prior spec: `docs/specs/completed/games-public-site-redesign.md`

## Interfaces & Contracts

### Domain Model (diffs only)
- No new models or migrations needed. Uses existing `Games::Game`, `Games::RankingConfiguration`, `RankedItem`, and all related models (platforms, companies, categories, series, lists).

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /game/:slug | Show game detail page | slug (FriendlyId) | public |
| GET | /rc/:ranking_configuration_id/game/:slug | Show game with specific RC | slug, ranking_configuration_id | public |
> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)
- **Preconditions**: `Games::RankingConfiguration.default_primary` must exist; game must exist with given slug
- **Postconditions**:
  - Game detail page rendered with all available metadata
  - Categories grouped by `category_type`
  - Developers and publishers displayed separately
  - Platforms displayed with abbreviations
  - Ranked position shown if game appears in current ranking configuration
  - Series and related games shown if game belongs to a series
- **Edge cases**:
  - Non-existent slug -> 404 (ActiveRecord::RecordNotFound via FriendlyId)
  - Game with no primary image -> placeholder displayed
  - Game with no categories/platforms/series -> sections hidden gracefully
  - Remake/remaster game_type -> show game type badge + link to original (if parent_game exists)
  - No ranking configuration -> 404

### Non-Functionals
- Caching: Use `Cacheable` concern (`cache_for_show_page` — 24hr public, session skip for CDN)
- No N+1: eager load `:categories, :platforms, :series, :lists, :primary_image, :child_games, {game_companies: :company}`
- Use `with_primary_image_for_display` scope if available, or deep preload ActiveStorage variants
- Mobile-first responsive design (3-col grid collapses to 1-col)
- DaisyUI "abyss" theme (inherited from games layout)

## Acceptance Criteria

### Show Page
- [x] `GET /game/:slug` renders game detail page
- [x] Cover art displayed (or placeholder if no image)
- [x] Release year badge shown
- [x] Game type badge shown for non-main_game types (remake, remaster, etc.)
- [x] Title displayed as h1
- [x] Developer names shown as byline
- [x] Rank blurb: "The Nth greatest video game of all time" (when ranked)
- [x] Description shown (when present)
- [x] Platforms section with platform name badges
- [x] Publishers section (when publishers differ from developers)
- [x] Categories grouped by type (genre, theme, game_mode, player_perspective)
- [x] Series section with related games (when in a series)
- [x] Lists section showing lists this game appears on
- [x] Page title and meta description set for SEO

### Card Links
- [x] Game cards on ranked items index are now clickable links to show page
- [x] Links respect ranking configuration context (RC-aware URLs)

### Technical
- [x] Controller follows albums controller pattern (Cacheable, load_ranking_configuration)
- [x] 24hr public caching applied via Cacheable concern
- [x] No N+1 queries (all associations eager loaded)
- [x] Controller tests pass (8 tests)
- [x] E2E test for game show page (4 tests)

### Golden Examples
```text
Input: GET /game/the-legend-of-zelda-breath-of-the-wild
Output: 200 OK
  - Title: "The Legend of Zelda: Breath of the Wild"
  - Developer: "Nintendo"
  - Release Year: 2017
  - Platforms: Switch
  - Categories: (genres, themes as available)
  - Page title: "The Legend of Zelda: Breath of the Wild - Nintendo | The Greatest Games"

Input: GET /game/non-existent-game
Output: 404 Not Found
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Follow the albums show page pattern closely.
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder -> already done (albums show page pattern identified)
2) codebase-analyzer -> already done (games model associations mapped)
3) UI Engineer -> build show view and update card component
4) technical-writer -> update docs and cross-refs

### Test Seed / Fixtures
- Existing game fixtures: `breath_of_the_wild`, `resident_evil_4`, `resident_evil_4_remake`, `half_life_2`, `tears_of_the_kingdom` in `test/fixtures/games/games.yml`
- Existing company fixtures: `nintendo`, `capcom`, `valve` in `test/fixtures/games/companies.yml`
- Existing platform fixtures: `switch`, `ps5`, `ps4`, `pc`, `xbox_series` in `test/fixtures/games/platforms.yml`
- Existing series fixtures: `zelda`, `resident_evil` in `test/fixtures/games/series.yml`
- Existing game_companies fixtures in `test/fixtures/games/game_companies.yml`
- Existing game_platforms fixtures in `test/fixtures/games/game_platforms.yml`
- Ranked items fixtures for games in `test/fixtures/ranked_items.yml`

### Files to Create
- `app/controllers/games/games_controller.rb`
- `app/views/games/games/show.html.erb`
- `app/helpers/games/default_helper.rb`
- `test/controllers/games/games_controller_test.rb`
- `e2e/tests/games/public/game-detail.spec.ts`

### Files to Modify
- `config/routes.rb` — add `get "game/:slug"` route inside RC scope
- `app/components/games/card_component.rb` — include helper, add link method
- `app/components/games/card_component.html.erb` — wrap card in `link_to_game`

---

## Implementation Notes (living)
- Approach taken: Followed existing music albums show page pattern closely
- Important decisions:
  - Used `@related_games` loaded in controller to avoid N+1 on `related_games_in_series`
  - DLC game_type rendered as "DLC" (not "Dlc" from titleize)
  - Publishers section only shown when different from developers
  - Cards now wrapped in `link_to_game` helper for clickable navigation
  - Series section links to related games via `link_to_game` (not CardComponent) to keep it lightweight

### Key Files Touched (paths only)
- `app/controllers/games/games_controller.rb` (new)
- `app/views/games/games/show.html.erb` (new)
- `app/helpers/games/default_helper.rb` (modified — added link helpers)
- `config/routes.rb` (modified — added `get "game/:slug"` route)
- `app/components/games/card_component.rb` (modified — included DefaultHelper)
- `app/components/games/card_component.html.erb` (modified — wrapped in link_to_game)
- `test/controllers/games/games_controller_test.rb` (new — 8 tests)
- `e2e/tests/games/public/game-detail.spec.ts` (new — 4 tests)

### Challenges & Resolutions
- N+1 on related_games_in_series: Loaded related games in controller via `@related_games` instead of calling model method in view
- `"dlc".titleize` producing "Dlc": Added explicit check for dlc game_type

### Deviations From Plan
- None

## Acceptance Results
- Date: 2026-02-23
- Verifier: AI Agent
- 3933 unit/integration tests passing (0 failures, 0 errors)
- 8 new controller tests for games show page
- 4 E2E test specs created (game-detail)

## Future Improvements
- Company show pages
- Platform filtering pages
- Game comparison feature
- Child games section (DLC, expansions) on show page

## Related PRs
- #...

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
