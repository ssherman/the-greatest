# Games Categories Show Page

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-24
- **Started**: 2026-02-24
- **Completed**: 2026-02-24
- **Developer**: Claude (AI)

## Overview
Add a public-facing category show page for video games at `/categories/:id`. Displays all ranked games in a given category, ordered by rank, with Pagy pagination. Uses the same `Games::CardComponent` used on the main games page and list show page. Supports the optional `/rc/:ranking_configuration_id` scope. Cached via the `Cacheable` concern. Includes SEO-friendly title and description.

**Non-goals**: Multi-category filtering, date filters, search within category. These are planned for a future phase.

## Context & Links
- Pattern to follow: `Music::Albums::CategoriesController` (`app/controllers/music/albums/categories_controller.rb`)
- Shared component: `Games::CardComponent` (`app/components/games/card_component.rb`)
- Games main page (similar UI): `app/views/games/ranked_items/index.html.erb`
- Games list show page (similar UI): `app/views/games/lists/show.html.erb`
- Category model: `app/models/games/category.rb` (STI, `Games::Category < ::Category`)
- Caching concern: `app/controllers/concerns/cacheable.rb`
- Routes: `config/routes.rb` (games domain constraint, lines 241-343)
- Spec instructions: `docs/spec-instructions.md`
- Testing guide: `docs/testing.md`

## Interfaces & Contracts

### Domain Model (diffs only)
- No model changes required. `Games::Category` and `CategoryItem` already exist with the correct associations.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `(/rc/:ranking_configuration_id)/categories/:id` | Show ranked games in a category | `id` (category slug), `ranking_configuration_id` (optional), `page` (optional, pagy) | public |

> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)
- **Preconditions**:
  - Category must exist, be a `Games::Category`, be active (`deleted: false`), and be found via FriendlyId slug.
  - If `ranking_configuration_id` param is present, load that config; otherwise use `Games::RankingConfiguration.default_primary`.
- **Postconditions/effects**:
  - Renders paginated grid of games in the category, ranked by `ranked_items.rank` ASC.
  - Each game rendered via `Games::CardComponent.new(ranked_item:, ranking_configuration:)`.
  - Page title set to: `"The Greatest <category.name> Games of All Time | The Greatest Games"`
  - Meta description set to a category-type-aware description (genre vs. theme vs. other).
- **Edge cases & failure modes**:
  - Category not found → 404 (Rails default from `friendly.find`).
  - Category with no ranked games → empty state UI (same pattern as main games page).
  - Invalid `ranking_configuration_id` → 404 (Rails default from `find`).

### Non-Functionals
- **Caching**: `cache_for_index_page` (6h public cache + 1h stale-while-revalidate, session skipped for Cloudflare).
- **N+1 prevention**: `.includes(item: [:categories, :primary_image, {game_companies: :company}])` on the query.
- **Performance**: p95 < 500ms for pages with 100 items. Single SQL query for ranked items + category join.
- **Security/roles**: Public page, no auth required.

## Acceptance Criteria
- [x] `GET /categories/action` returns 200 and renders games in the "Action" category ranked by `rank`.
- [x] Page title is `"The Greatest Action Games of All Time | The Greatest Games"`.
- [x] Meta description is SEO-friendly and category-type-aware (genre, theme, etc.).
- [x] Heading is `"The Greatest <category.name> Games of All Time"`.
- [x] Games are rendered using `Games::CardComponent` with rank badges displayed.
- [x] UI layout matches the main games page: 4-column responsive grid (`grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4`).
- [x] Pagy pagination at 100 items per page, rendered at bottom of page.
- [x] Empty state shown when category has no ranked games.
- [x] `GET /rc/123/categories/action` uses ranking configuration 123.
- [x] `GET /categories/nonexistent` returns 404.
- [x] Page is cached via `cache_for_index_page` (Cacheable concern).
- [x] Controller test covers: success response, correct ranking config loading, 404 for missing category.
- [x] E2E test covers: page loads, title correct, games displayed with ranks, pagination visible if applicable.

### Golden Examples
```text
Input:  GET /categories/action (assuming "Action" is a Games::Category with slug "action", genre type)
Output: 200 OK
  - Page title: "The Greatest Action Games of All Time | The Greatest Games"
  - Meta description: "Discover the greatest Action video games of all time. Our definitive ranking of the top Action games, from legendary classics to modern masterpieces."
  - Heading: "The Greatest Action Games of All Time"
  - Grid of Games::CardComponent cards, each showing rank badge, image, title, developer, categories
  - Pagy pagination at bottom if > 100 games

Input:  GET /categories/role-playing (assuming "Role-Playing" is a Games::Category with slug "role-playing", genre type)
Output: 200 OK
  - Page title: "The Greatest Role-Playing Games of All Time | The Greatest Games"
  - Heading: "The Greatest Role-Playing Games of All Time"
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Model the controller after `Music::Albums::CategoriesController` — same structure, adapted for games.
- Reuse `Games::CardComponent` exactly as-is (pass `ranked_item:` and `ranking_configuration:`).
- Reuse the same grid layout from `app/views/games/ranked_items/index.html.erb`.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect comparable patterns (music albums categories controller, games ranked_items controller)
2) codebase-analyzer → verify data flow & integration points (CategoryItem join, RankedItem query)
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Use existing `Games::Category` fixtures (check `test/fixtures/games/categories.yml`).
- Use existing `Games::Game` and `RankedItem` fixtures.
- May need to add a `CategoryItem` fixture linking a game to a category if one doesn't exist.

### Implementation Checklist
1. **Route**: Add `get "categories/:id", to: "games/categories#show", as: :games_category` inside the existing `scope "(/rc/:ranking_configuration_id)"` block in the games domain constraint.
2. **Controller**: Generate `Games::CategoriesController` (use `rails generate controller Games::Categories show`). Model after `Music::Albums::CategoriesController`:
   - Include `Pagy::Method`, `Cacheable`
   - `layout "games/application"`
   - `before_action :load_ranking_configuration`
   - `before_action :cache_for_index_page, only: [:show]`
   - `def self.ranking_configuration_class` → `Games::RankingConfiguration`
   - `show` action: find category, build ranked items query with category join, paginate at 100.
3. **View**: Create `app/views/games/categories/show.html.erb`:
   - Set `content_for :page_title` and `content_for :meta_description`.
   - Render heading: `"The Greatest <category.name> Games of All Time"`.
   - Render 4-column grid of `Games::CardComponent.new(ranked_item:, ranking_configuration:)`.
   - Empty state matching games page pattern.
   - Pagy pagination at bottom.
4. **Controller test**: `test/controllers/games/categories_controller_test.rb` — test success, rc override, 404.
5. **E2E test**: `web-app/e2e/tests/games/categories.spec.ts` — page loads, title, games displayed.

---

## Implementation Notes (living)
- Approach taken: Followed the `Music::Albums::CategoriesController` pattern exactly, adapted for games domain. Controller generated via `rails generate controller Games::Categories show`, then customized.
- Important decisions:
  - Added `item_type` guard on the `games_games` SQL JOIN (`AND ranked_items.item_type = 'Games::Game'`) — an improvement over the music pattern to prevent cross-domain item bleed from polymorphic ID collisions.
  - No back link on the page (no games category index page exists yet).
  - Minimal header — just the heading text, no category type badge or ranking configuration description.
  - Restructured `Games::CardComponent` from single `<a>` wrapper to `<div>` wrapper with separate links for image, title, and category badges. This avoids invalid nested `<a>` tags and enables clickable category links. Pattern matches `Music::Artists::CardComponent`.
  - Added `link_to_game_category` and `games_category_path_with_rc` helpers to `Games::DefaultHelper`, following the existing `link_to_game` / `link_to_game_list` pattern.
  - Made category badges clickable on both the card component and game show page.
  - All links inside `Games::CardComponent` include `data: { turbo_frame: "_top" }` to ensure correct navigation when cards are rendered inside Turbo Frames (e.g., list show page).

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/controllers/games/categories_controller.rb` (new)
- `app/views/games/categories/show.html.erb` (new)
- `app/helpers/games/default_helper.rb` (added `link_to_game_category`, `games_category_path_with_rc`)
- `app/helpers/games/categories_helper.rb` (new, generated empty)
- `app/components/games/card_component.html.erb` (restructured for clickable category links)
- `app/views/games/games/show.html.erb` (category badges now link to category pages)
- `test/fixtures/category_items.yml` (added games category_items fixtures)
- `test/controllers/games/categories_controller_test.rb` (new, 6 tests)
- `web-app/e2e/tests/games/public/categories.spec.ts` (new, 5 tests)
- `web-app/e2e/tests/games/public/game-detail.spec.ts` (updated locators for new card structure)
- `web-app/e2e/tests/games/public/lists.spec.ts` (updated locators for new card structure)

### Challenges & Resolutions
- **Nested `<a>` tags**: Making category badges clickable required restructuring the card component. The entire card was previously wrapped in a single `<a>` tag, preventing nested links. Resolved by matching the `Music::Artists::CardComponent` pattern — image in its own link, title as a separate link, categories as individual links.
- **Fixture conflicts**: Initial `category_items` fixture for `breath_of_the_wild` + `games_action_genre` conflicted with admin test that calls `CategoryItem.create!` with the same combination. Resolved by using `tears_of_the_kingdom` instead.
- **Turbo Frame navigation**: Links inside the card didn't include `data: { turbo_frame: "_top" }`, causing broken navigation on the list show page (which wraps cards in a turbo frame). Resolved by adding the data attribute to all card links.
- **E2E locator breakage**: Changing the card from `<a class="card">` to `<div class="card">` broke `a.card` locators in existing E2E tests. Updated all affected tests.

### Deviations From Plan
- Card component restructured (not in original spec) to support clickable category links — necessary for valid HTML and follows the existing music artists card pattern.
- Added `link_to_game_category` helper and made categories clickable on game show page (bonus, requested after initial implementation).

## Acceptance Results
- Date: 2026-02-24
- Verifier: Automated tests
- Artifacts:
  - 3962 Minitest runs, 0 failures, 0 errors (full suite)
  - 6 controller tests passing (`test/controllers/games/categories_controller_test.rb`)
  - 135 E2E tests passing (full Playwright suite), including 5 new category tests

## Future Improvements
- Multi-category filtering (AND/OR logic)
- Date range filters (year/decade)
- Category index page listing all game categories
- Breadcrumb navigation

## Related PRs
- #…

## Documentation Updated
- [x] Spec file completed and moved to `docs/specs/completed/`
- [ ] `documentation.md`
- [ ] Class docs
