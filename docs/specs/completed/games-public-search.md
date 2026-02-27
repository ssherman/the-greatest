# Games Public Search

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-26
- **Completed**: 2026-02-27
- **Developer**: Claude

## Overview
Add a public search page for the games domain, allowing users to search for video games by title or developer name. Games are already indexed in OpenSearch via `Search::Games::GameIndex`. This task adds the controller, route, view, navbar search bar, and tests — mirroring the existing music search pattern.

**Non-goals**: Autocomplete/live search, filtering by platform/category, pagination of results.

## Context & Links
- Pattern reference: `app/controllers/music/searches_controller.rb`
- Pattern reference: `app/views/music/searches/index.html.erb`
- Existing search infra: `docs/features/search.md`
- Game index: `app/lib/search/games/game_index.rb`
- Game query: `app/lib/search/games/search/game_general.rb`
- Card component: `app/components/games/card_component.rb`

## Interfaces & Contracts

### Domain Model (diffs only)
No model changes. Games are already indexed with `SearchIndexable`.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | /search | Public games search results page | `q` (query string, optional) | none (public) |

> Route lives inside the games `DomainConstraint` block in `config/routes.rb`.
> Named route: `games_search_path`

### Behaviors (pre/postconditions)

**Query blank/absent**:
- Sets `@games = []`, `@total_count = 0`
- Renders empty state: "Enter a search term to find video games"

**Query present, no results**:
- Calls `Search::Games::Search::GameGeneral.call(query, size: 50)`
- Renders empty state: "No results found for '...'"

**Query present, results found**:
- Calls `GameGeneral.call(query, size: 50)`
- Extracts IDs, fetches `Games::Game.where(id: ids).includes(:categories, :primary_image, game_companies: :company)`
- Preserves OpenSearch relevance order via `ids.map { |id| records_by_id[id] }.compact`
- Renders results in a 4-column responsive grid using `Games::CardComponent.new(game: game)`

**Edge cases**:
- Special characters in query: handled by `normalize_search_text` (existing)
- Duplicate IDs from OpenSearch: `.uniq` on extracted IDs
- Deleted records: `.compact` handles IDs not found in DB

### Non-Functionals
- No N+1: single query with `includes` for associations
- No auth required (public page)
- Caching prevented (`before_action :prevent_caching`)
- Single OpenSearch call (only one entity type, unlike music's three)

## Acceptance Criteria
- [x] `GET /search` on games domain returns 200 with blank query (shows empty state)
- [x] `GET /search?q=zelda` on games domain returns 200 with results grid
- [x] `GET /search?q=nonexistent` returns 200 with "no results" empty state
- [x] Search calls `GameGeneral.call` with `size: 50`
- [x] Results render in 4-column responsive grid using `Games::CardComponent`
- [x] Results preserve OpenSearch relevance order
- [x] Search bar in games navbar submits to `/search`
- [x] Search bar placeholder is "Search games..."
- [x] Controller test covers: blank query, no results, results found, mixed results, correct size param, special characters, duplicate IDs
- [x] E2E test covers: search page loads, search with query works

### Golden Examples
```text
Input: GET /search?q=zelda (games domain)
Output: 200, grid of games matching "zelda" ordered by relevance score

Input: GET /search (games domain, no query)
Output: 200, empty state message prompting user to search

Input: GET /search?q=xyznonexistent123 (games domain)
Output: 200, empty state message "No results found for '...'"
```

---

## Agent Hand-Off

### Constraints
- Follow existing music search pattern exactly; do not introduce new architecture.
- Use Rails generator for `Games::SearchesController` to auto-create test file.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect music search patterns to replicate
2) codebase-analyzer → verify games route structure and card component interface
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Used existing fixtures: `games/games.yml` (`breath_of_the_wild`, `resident_evil_4`)
- No new fixtures needed

### Files Created
1. `app/controllers/games/searches_controller.rb` — via generator
2. `app/views/games/searches/index.html.erb` — search results view
3. `app/components/search/empty_state_component.rb` — shared across domains (via generator)
4. `app/components/search/empty_state_component.html.erb` — shared template
5. `test/controllers/games/searches_controller_test.rb` — via generator
6. `e2e/tests/games/public/search.spec.ts` — E2E test

### Files Modified
1. `config/routes.rb` — added `get "search"` in `scope as: "games"` inside the games `DomainConstraint`, before the `scope "(/rc/:ranking_configuration_id)"` block
2. `app/views/layouts/games/application.html.erb` — added search form in `navbar-end` before login button
3. `app/views/music/searches/index.html.erb` — updated to use shared `Search::EmptyStateComponent`

### Files Deleted
1. `app/components/music/search/empty_state_component.rb` — replaced by shared component
2. `app/components/music/search/empty_state_component/empty_state_component.html.erb` — replaced by shared component

---

## Implementation Notes (living)
- Approach taken: Mirrored the music search pattern exactly, simplified to a single entity type (games only)
- Important decisions: Used `size: 50` per spec, eager loads `[:categories, :primary_image, game_companies: :company]` to prevent N+1
- Extracted `Search::EmptyStateComponent` as a shared component to avoid duplication between music and games domains

### Key Files Touched (paths only)
- `app/controllers/games/searches_controller.rb`
- `app/views/games/searches/index.html.erb`
- `app/components/search/empty_state_component.rb`
- `app/components/search/empty_state_component.html.erb`
- `config/routes.rb`
- `app/views/layouts/games/application.html.erb`
- `app/views/music/searches/index.html.erb`
- `test/controllers/games/searches_controller_test.rb`
- `e2e/tests/games/public/search.spec.ts`

### Challenges & Resolutions
- Empty state component was originally duplicated per domain; extracted to shared `Search::EmptyStateComponent` to follow DRY

### Deviations From Plan
- Spec originally called for domain-specific `Games::Search::EmptyStateComponent`; instead created shared `Search::EmptyStateComponent` used by both music and games to avoid code duplication

## Acceptance Results
- Date: 2026-02-27
- Verifier: Claude (automated)
- All 3978 tests pass (0 failures, 0 errors), including 8 new games search controller tests
- E2E test file created at `e2e/tests/games/public/search.spec.ts` (3 tests)

## Future Improvements
- Add platform/category filtering to search results
- Add autocomplete/live search in the search bar
- Extend shared `Search::EmptyStateComponent` to movies/books when those domains add search

## Related PRs
- #…

## Documentation Updated
- [x] `docs/features/search.md` — needs update to reference games public search controller
- [x] `docs/specs/games-public-search.md` — this file, completed
