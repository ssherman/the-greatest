# IGDB Lookup by ID/URL

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-02-22
- **Started**: 2026-02-23
- **Completed**: 2026-02-23
- **Developer**: AI Agent (Claude)

## Overview
Add a "Link by IGDB ID" action to the games list wizard review step. When IGDB search fails to find a game (e.g., "Pokémon Go" — IGDB's search ranking returns wrong results), the admin can paste an IGDB numeric ID or URL to directly link the game.

**Scope**: New modal + controller logic for parsing IGDB ID/URL input and linking via the existing `link_igdb_game` flow.

**Non-goals**: Fixing IGDB search ranking, modifying the autocomplete search, changing the enrichment pipeline.

## Context & Links
- **Why this is needed**: IGDB's full-text search has ranking issues — searching "Pokémon Go" returns "Let's Go" games instead of the actual mobile game. The `~` (contains) operator is accent-sensitive. The game exists (ID 12515, slug `pokemon-go`) but IGDB's search never surfaces it.
- Existing search modal: `app/views/admin/games/list_items_actions/modals/_search_igdb_games.html.erb`
- Controller: `app/controllers/admin/games/list_items_actions_controller.rb`
- Modal concern: `app/controllers/concerns/list_items_actions.rb` — `modal` action routes `modal_type` to partials
- Existing `link_igdb_game` action (controller lines 44-94) — validates IGDB ID via `find_with_details`, links game to item
- Item row menu: `app/components/admin/games/wizard/item_row_component.rb` — `menu_items` method
- Routes: `config/routes.rb` — games list items section
- GameSearch: `app/lib/games/igdb/search/game_search.rb` — `find_with_details(id)`, `find_by_slug(slug)`, and `find_by_ids`

## Interfaces & Contracts

### Domain Model (diffs only)
No schema/migration changes required.

### Endpoints

| Verb | Path | Purpose | Params/Body | Auth |
|---|---|---|---|---|
| GET | `/admin/games/lists/:list_id/items/:id/modal/link_igdb_id` | Load IGDB ID/URL input modal | `modal_type=link_igdb_id` | admin |
| POST | `/admin/games/lists/:list_id/items/:id/link_igdb_game` | Link item to IGDB game | `igdb_id` (numeric ID or IGDB URL) | admin |

> No new routes needed — `modal/:modal_type` is dynamic, and `link_igdb_game` already exists. Only the controller parsing logic was updated.

### Behaviors (pre/postconditions)

#### Change 1: New modal type `link_igdb_id`
- Added `"link_igdb_id"` to `VALID_MODAL_TYPES` constant
- Created partial `_link_igdb_id.html.erb` with a text input (not autocomplete)
- Form submits to existing `link_igdb_game` action

#### Change 2: Parse IGDB URL in `link_igdb_game` action
Updated `link_igdb_game` to accept both formats via `resolve_igdb_input` private method:
- **Numeric ID**: `12515` → use directly with `find_with_details`
- **IGDB URL**: `https://www.igdb.com/games/pokemon-go` → extract slug via regex → `find_by_slug` → use returned game data

**Parsing logic**:
```text
Input: "12515"           → igdb_id = 12515
Input: "https://www.igdb.com/games/pokemon-go" → slug = "pokemon-go" → query IGDB by slug → igdb_id
Input: "" or nil         → render_modal_error("Please enter an IGDB ID or URL")
Input: "not-a-valid-url" → render_modal_error("Invalid IGDB ID or URL...")
```

**URL regex**: `IGDB_URL_PATTERN = %r{\Ahttps?://(?:www\.)?igdb\.com/games/([a-z0-9][a-z0-9\-]*[a-z0-9])}i`

#### Change 3: New `find_by_slug` method on GameSearch
- Queries IGDB with `where slug = "..."` using the same detail fields as `find_with_details`
- Extracted shared fields into `find_with_details_fields` private method

#### Change 4: Add menu item in `ItemRowComponent`
Added "Link by IGDB ID" option to `menu_items` array, after "Search IGDB Games".

**Preconditions**:
- Admin is on the review step of the games list wizard
- List item exists and is accessible

**Postconditions**:
- Item metadata updated with `igdb_id`, `igdb_name`, `igdb_developer_names`, `igdb_match: true`, `manual_igdb_link: true` (same as existing `link_igdb_game`)
- Item row and review stats updated via Turbo Stream
- If IGDB ID/URL is invalid or game not found: modal stays open with error message

**Edge cases handled**:
- URL with trailing slash: `https://www.igdb.com/games/pokemon-go/` → regex captures slug before `/`
- URL with query params: `https://www.igdb.com/games/pokemon-go?tab=reviews` → regex captures slug before `?`
- HTTP vs HTTPS: both accepted
- Without `www.`: accepted
- Non-IGDB URL: `https://example.com/games/123` → error "Invalid IGDB ID or URL"
- Slug that doesn't exist on IGDB: error "IGDB game not found for slug: ..."
- Whitespace around input: trimmed before parsing

### Non-Functionals
- **Performance**: Slug lookup adds 1 IGDB API call (fast indexed query). No impact on existing flows.
- **Security/roles**: Admin only (inherits from `Admin::Games::BaseController`)
- **UX**: Simple text input with placeholder showing both formats. No autocomplete needed.

## Acceptance Criteria
- [x] New "Link by IGDB ID" menu item appears in the item row dropdown (after "Search IGDB Games")
- [x] Clicking it opens a modal with a text input for IGDB ID or URL
- [x] Entering numeric ID `12515` and submitting links the item to Pokémon Go
- [x] Entering URL `https://www.igdb.com/games/pokemon-go` and submitting links the item to Pokémon Go
- [x] Invalid input (empty, non-numeric non-URL, bad URL domain) shows inline error in modal
- [x] Slug not found on IGDB shows "IGDB game not found" error
- [x] After successful link, item row updates with IGDB badge and game name
- [x] Existing "Search IGDB Games" and "Link IGDB Game" flows are unaffected
- [x] Unit tests for URL/ID parsing logic
- [x] Controller test for slug-based lookup path

### Golden Examples
```text
Input: "12515"
Action: find_with_details(12515)
Result: Links item to "Pokémon Go" (IGDB ID 12515)

Input: "https://www.igdb.com/games/pokemon-go"
Action: Extract slug "pokemon-go" → find_by_slug("pokemon-go") → igdb_id = 12515
Result: Links item to "Pokémon Go" (IGDB ID 12515)

Input: "https://www.igdb.com/games/nonexistent-game-slug"
Action: Extract slug → find_by_slug → no results
Result: Error "IGDB game not found for slug: nonexistent-game-slug"

Input: "not valid"
Result: Error "Invalid IGDB ID or URL. Enter a numeric ID (e.g., 12515) or IGDB URL."
```

---

## Agent Hand-Off

### Constraints
- Follow existing modal patterns exactly (`_search_igdb_games.html.erb`, `_link_game.html.erb`)
- Reuse existing `link_igdb_game` action — extend it, don't create a new action
- Respect snippet budget (<=40 lines per snippet)
- Do not duplicate authoritative code; **link to file paths**

### Required Outputs
- Updated files (paths listed in "Key Files Touched")
- Passing tests demonstrating Acceptance Criteria
- Updated: "Implementation Notes", "Deviations", "Documentation Updated"

### Sub-Agent Plan
1) codebase-pattern-finder → collect modal partial patterns and controller parsing patterns
2) codebase-analyzer → verify route wiring and turbo stream flow
3) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- Existing `games_list` fixture used
- Mocked IGDB API responses for `find_with_details` and `find_by_slug`
- No new fixtures needed

---

## Implementation Notes (living)
- Approach taken: Extended existing `link_igdb_game` action with `resolve_igdb_input` private method that dispatches between numeric ID and URL parsing. Extracted `find_with_details_fields` in GameSearch to share detail fields between `find_with_details` and new `find_by_slug`.
- Important decisions:
  - Used regex `IGDB_URL_PATTERN` for URL validation — captures slug from IGDB URLs while ignoring trailing slashes, query params, and supporting both HTTP/HTTPS with or without `www.`
  - For URL input, `find_by_slug` returns the full game data directly (same fields as `find_with_details`), so we reuse the slug result as the final result instead of making a second API call with the extracted ID
  - Modal uses a plain text input (not autocomplete) since the user is pasting a known ID or URL

### Key Files Touched (paths only)
- `app/controllers/admin/games/list_items_actions_controller.rb` (modified — VALID_MODAL_TYPES, link_igdb_game parsing, resolve_igdb_input)
- `app/views/admin/games/list_items_actions/modals/_link_igdb_id.html.erb` (new)
- `app/components/admin/games/wizard/item_row_component.rb` (modified — menu_items)
- `app/lib/games/igdb/search/game_search.rb` (modified — find_by_slug, find_with_details_fields extraction)
- `test/controllers/admin/games/list_items_actions_controller_test.rb` (new — 16 tests)

### Challenges & Resolutions
- None — straightforward extension of existing patterns

### Deviations From Plan
- Added `find_with_details_fields` extraction in GameSearch to avoid duplicating the field list between `find_with_details` and `find_by_slug` — this was a minor refactor not in the original plan but reduces maintenance burden

## Acceptance Results
- Date: 2026-02-23
- Verifier: AI Agent
- All 16 controller tests pass (numeric ID, URL, edge cases, turbo stream, modal rendering)
- All 16 existing GameSearch tests continue to pass

## Future Improvements
- Add slug-based search as a supplementary tier in `GameSearch#search_by_name` to improve search quality broadly
- Support pasting IGDB game page title along with URL for faster confirmation

## Related PRs
-

## Documentation Updated
- [x] Spec file created and moved to `docs/specs/completed/`
- [ ] `documentation.md`
- [ ] Class docs
