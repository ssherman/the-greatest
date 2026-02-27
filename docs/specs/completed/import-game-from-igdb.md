# Import Game from IGDB — Admin Action

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-27
- **Started**: 2026-02-27
- **Completed**: 2026-02-27
- **Developer**: Claude (AI)

## Overview
Add an "Import from IGDB" button to the `/admin/games` index page that opens a modal with **two input methods** (either/or):

1. **Paste IGDB URL** — e.g. `https://www.igdb.com/games/flight-simulator` — resolved via slug lookup (reuses `resolve_igdb_input` from `ListItemsActionsController`)
2. **Search by name** — autocomplete searching IGDB API (reuses `igdb_game_search` logic)

Both submit a resolved IGDB ID to `import_from_igdb`, which calls `DataImporters::Games::Game::Importer` (the same importer used by the list wizard import step) to create the game record, then redirects to the game's show page. Follows the pattern established by `import_from_musicbrainz` on the music artists index page.

**Non-goals**: No background job processing needed (single game import is fast enough synchronously). No changes to the existing IGDB API client, importer, or search infrastructure.

## Context & Links
- Reference pattern: `Admin::Music::ArtistsController#import_from_musicbrainz` (`app/controllers/admin/music/artists_controller.rb:110-130`)
- Reference view: `app/views/admin/music/artists/index.html.erb:58-98` (import modal)
- Existing IGDB search endpoint: `Admin::Games::ListItemsActionsController#igdb_game_search` (`app/controllers/admin/games/list_items_actions_controller.rb:120-156`)
- Existing URL/ID resolution: now in shared concern `IgdbInputResolvable` (`app/controllers/concerns/igdb_input_resolvable.rb`)
- Existing IGDB URL modal: `app/views/admin/games/list_items_actions/modals/_link_igdb_id.html.erb`
- Existing IGDB search modal: `app/views/admin/games/list_items_actions/modals/_search_igdb_games.html.erb`
- Game importer: `app/lib/data_importers/games/game/importer.rb`
- IGDB search service: `app/lib/games/igdb/search/game_search.rb` (`find_by_slug`, `search_by_name`, `find_with_details`)
- AutocompleteComponent: `app/components/autocomplete_component.rb`
- modal-form Stimulus controller: `app/javascript/controllers/modal_form_controller.js`

## Interfaces & Contracts

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/admin/games/games/igdb_search` | JSON autocomplete for IGDB games | `q` (string, min 2 chars) | `import?` (delegates to `manage?`) |
| POST | `/admin/games/games/import_from_igdb` | Import a game by IGDB ID or URL | `igdb_url` (string: IGDB URL or numeric ID) or `igdb_id` (string: autocomplete-selected numeric ID) | `import?` (delegates to `manage?`) |

> Source of truth: `config/routes.rb`

### Behaviors (pre/postconditions)

**`igdb_search` (GET)**:
- Precondition: `params[:q]` present and length >= 2
- Postcondition: Returns JSON array of `{value:, text:, igdb_id:, name:, developers:, release_year:, cover_url:}` (same shape as `ListItemsActionsController#igdb_game_search`)
- Edge case: Empty/short query returns `[]`
- Edge case: IGDB API error returns `[]`

**`import_from_igdb` (POST)**:
- Precondition: `params[:igdb_url]` or `params[:igdb_id]` present. `igdb_url` takes precedence.
- Input resolution (via `IgdbInputResolvable#resolve_igdb_input`):
  - Numeric string (e.g. `"12515"`) → treated as IGDB ID directly
  - IGDB URL (e.g. `"https://www.igdb.com/games/flight-simulator"`) → slug extracted, resolved via `GameSearch#find_by_slug`
  - Otherwise → redirect back with "Invalid IGDB ID or URL" alert
- Postcondition (new game): `DataImporters::Games::Game::Importer.call(igdb_id:)` creates game + companies + platforms + categories + cover art. Redirects to `admin_games_game_path(game)` with success notice.
- Postcondition (existing game): Importer returns existing game via `Finder` (deduplication by `games_igdb_id` identifier). Redirects with "Game already exists" notice.
- Edge case: Missing both params → redirect back with alert
- Edge case: Slug not found on IGDB → redirect back with "Game not found" alert
- Edge case: Importer failure → redirect back with error message from `result.all_errors`

### Non-Functionals
- Auth: Pundit `import?` policy method (delegates to `manage?`, same as music artists)
- View: Button and modal only rendered when `policy(Games::Game).import?` is true
- No N+1: Single importer call, no list rendering affected
- IGDB rate limiting: Handled by existing `Games::Igdb::RateLimiter` (4 req/s)

## Acceptance Criteria

- [x] "Import from IGDB" button appears on `/admin/games` index page (btn-outline, left of "New Game" button)
- [x] Clicking the button opens a DaisyUI `<dialog>` modal with two input methods
- [x] **URL/ID input**: Text field accepts IGDB URL (e.g. `https://www.igdb.com/games/flight-simulator`) or numeric ID (e.g. `12515`)
- [x] **Autocomplete search**: `AutocompleteComponent` searches IGDB API and displays results with game name, developers, and year
- [x] Either input method submits to the same `import_from_igdb` action
- [x] IGDB URL is resolved via slug lookup (`GameSearch#find_by_slug`), then imported via `DataImporters::Games::Game::Importer`
- [x] Autocomplete selection submits the IGDB ID directly, imported via the same importer
- [x] If the game already exists locally (by IGDB identifier), redirects to existing game with appropriate notice
- [x] If `igdb_id` param is missing, redirects back with alert message
- [x] If slug/ID not found on IGDB, redirects back with error message
- [x] If import fails, redirects back with error message
- [x] Modal closes on successful form submission (via `modal-form` Stimulus controller)
- [x] Modal can be closed via Cancel button or clicking backdrop
- [x] Pundit `import?` authorization is enforced
- [x] Integration test covers: URL import, autocomplete import, duplicate detection, invalid input, and missing param cases

### Golden Examples

```text
Input: User pastes "https://www.igdb.com/games/flight-simulator" into URL field, clicks Import
→ Slug "flight-simulator" extracted via IGDB_URL_PATTERN regex
→ GameSearch#find_by_slug("flight-simulator") returns IGDB data with id
→ DataImporters::Games::Game::Importer.call(igdb_id: <resolved_id>) runs
→ Creates Games::Game with title, description, release_year, game_type, companies, platforms, categories, cover
→ Redirects to /admin/games/games/:id with "Game imported successfully"

Input: User searches "The Legend of Zelda" via autocomplete, selects a result, clicks Import
→ AutocompleteComponent sets hidden field to IGDB ID (e.g. 7346)
→ DataImporters::Games::Game::Importer.call(igdb_id: 7346) runs
→ Redirects to /admin/games/games/:id with "Game imported successfully"

Input: User imports a game that already exists (same IGDB ID)
→ Importer's Finder returns existing record, provider_results is empty
→ Redirects to /admin/games/games/:id with "Game already exists"

Input: User pastes "https://www.igdb.com/games/nonexistent-slug"
→ GameSearch#find_by_slug returns no results
→ Redirects back with "IGDB game not found for slug: nonexistent-slug"
```

---

## Agent Hand-Off

### Constraints
- Follow existing `import_from_musicbrainz` pattern exactly; do not introduce new architecture.
- Reuse existing `DataImporters::Games::Game::Importer` — no modifications needed.
- Reuse `resolve_igdb_input` logic from `ListItemsActionsController` for URL/ID parsing (extract to shared concern or duplicate minimally).
- IGDB search logic should be extracted/shared from `ListItemsActionsController#igdb_game_search` (DRY).
- Respect snippet budget (<=40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests for the Acceptance Criteria.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → confirm `import_from_musicbrainz` pattern details
2) codebase-analyzer → verify `DataImporters::Games::Game::Importer.call` interface and return shape
3) technical-writer → update docs and cross-refs

### Implementation Checklist

1. **Route**: Add `collection` routes to `resources :games` in `config/routes.rb`:
   - `post :import_from_igdb`
   - `get :igdb_search`

2. **Policy**: Add `def import?; manage?; end` to `Games::GamePolicy` (mirrors `Music::ArtistPolicy#import?`)

3. **Controller** (`app/controllers/admin/games/games_controller.rb`):
   - Add `import_from_igdb` action — accepts `params[:igdb_url]` or `params[:igdb_id]`, resolves via slug if URL, then calls `DataImporters::Games::Game::Importer.call(igdb_id:)`
   - Add `igdb_search` action (extracts/reuses logic from `ListItemsActionsController#igdb_game_search`)
   - Extract `resolve_igdb_input`, `IGDB_URL_PATTERN`, and `format_igdb_game_for_autocomplete` to shared `IgdbInputResolvable` concern

4. **View** (`app/views/admin/games/games/index.html.erb`):
   - Add "Import from IGDB" button (btn-outline) next to "New Game", guarded by `policy(Games::Game).import?`
   - Add `<dialog>` modal with two input sections:
     - **IGDB URL/ID field**: Plain text input `name="igdb_url"` (placeholder: `e.g., https://www.igdb.com/games/flight-simulator or 12515`)
     - **OR search by name**: `AutocompleteComponent` with `name="igdb_id"` for IGDB autocomplete
   - URL field takes precedence over autocomplete (no extra JS needed)
   - Form uses `modal-form` Stimulus controller for close-on-success

5. **Tests**: Integration test for `import_from_igdb` (URL, numeric ID, autocomplete ID, duplicate, invalid input, missing param, slug not found, URL precedence) and `igdb_search` (results, short query, blank query, API failure)

### Test Seed / Fixtures
- Existing games fixtures suffice
- Mock `Games::Igdb::Search::GameSearch` and `DataImporters::Games::Game::Importer` in tests

---

## Implementation Notes (living)
- Approach taken: Followed the `import_from_musicbrainz` pattern on music artists exactly. Extracted shared IGDB logic into a new `IgdbInputResolvable` concern to DRY up code between `GamesController` and `ListItemsActionsController`.
- Important decisions:
  - Used separate param names (`igdb_url` for the text field, `igdb_id` for the autocomplete hidden field) instead of sharing a single `name="igdb_id"` — avoids HTML form conflicts with duplicate name attributes.
  - URL field takes precedence over autocomplete value — simple, no extra JavaScript needed.
  - `igdb_search` endpoint uses `import?` authorization (not `index?`) for least-privilege, since it only serves the import workflow.
  - Button and modal are conditionally rendered via `policy(Games::Game).import?` so editors who can view the index but can't import don't see non-functional UI.
  - Extracted `format_igdb_game_for_autocomplete` into the shared concern to eliminate duplicate JSON formatting logic between the two controllers.

### Key Files Touched (paths only)
- `config/routes.rb`
- `app/policies/games/game_policy.rb`
- `app/controllers/concerns/igdb_input_resolvable.rb` (new)
- `app/controllers/admin/games/games_controller.rb`
- `app/controllers/admin/games/list_items_actions_controller.rb`
- `app/views/admin/games/games/index.html.erb`
- `test/controllers/admin/games/games_controller_test.rb`

### Challenges & Resolutions
- Ruby constant resolution within `Admin::Games` test module resolved `Games::Igdb` as `Admin::Games::Igdb`. Fixed by using fully qualified `::Games::Igdb::Search::GameSearch` in tests.
- Concern extraction required changing `resolve_igdb_input` return signature from rendering errors directly to returning `[nil, error_message]`, so each caller can handle errors in its own way (redirects vs modal error rendering).

### Deviations From Plan
- Spec suggested both inputs share `name="igdb_id"` — changed to separate names (`igdb_url` / `igdb_id`) to avoid HTML form conflicts.
- Spec did not mention policy guard on the view button/modal — added `policy(Games::Game).import?` check to prevent showing non-functional UI to unauthorized users.
- Spec suggested `igdb_search` uses generic admin auth — implemented with `import?` policy for least-privilege.
- Created `IgdbInputResolvable` concern with three shared methods (`resolve_igdb_input`, `format_igdb_game_for_autocomplete`, `IGDB_URL_PATTERN`) instead of just the URL resolution.

## Acceptance Results
- Date: 2026-02-27
- Verifier: Automated tests (40 tests, 102 assertions, 0 failures, 0 errors)
- All 229 admin games controller tests pass including 12 new import/search tests

## Future Improvements
- Bulk import: paste multiple IGDB IDs/URLs to import several games at once

## Related PRs
- #…

## Documentation Updated
- [x] Spec file updated with implementation notes, deviations, and acceptance results
- [ ] `documentation.md`
- [ ] Class docs
